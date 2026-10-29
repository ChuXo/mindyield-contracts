// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IRandomnessManager.sol";

/**
 * @title RandomnessManagerV2
 * @notice Manages VRF randomness requests for contests and lotteries.
 * @dev Integrates with Chainlink VRF V2.5 (used on Base mainnet and Base Sepolia).
 *
 * Differences from V1 (`RandomnessManager.sol`):
 *
 *   1. **`manualFulfill` is removed.** V1 let the contract owner pick any
 *      `randomWord` for any pending request after a 3h delay. Even with
 *      ownership behind a 48h Timelock, this was a residual rigging vector.
 *      In V2 the owner can never pick a random word.
 *
 *   2. **`retryRequest(bytes32 contestId)` added — permissionless.** Anyone
 *      can re-fire `requestRandomWords` on the VRF coordinator after
 *      `VRF_TIMEOUT` (2h) elapsed since the last attempt, up to
 *      `MAX_RETRIES` (5) times. The randomness still comes from Chainlink —
 *      never a human-picked value. This is the safe replacement for
 *      `manualFulfill` and covers both the success=false-at-coordinator
 *      case (Round #1 incident) and the VRF-stalled case.
 *
 *   3. **`MANUAL_FULFILL_DELAY` constant removed.** Was only used by
 *      `manualFulfill`.
 *
 * Other behaviour identical to V1 — drop-in replacement for consumers
 * (NoLossLotteryV3, ContestV2 et al.) that call `requestRandomness(bytes32)`
 * and receive `fulfillRandomness(uint256)` callbacks.
 *
 * VRF Callback Flow:
 *   1. Contest/Lottery calls `requestRandomness()` → we call `coordinator.requestRandomWords()`
 *   2. Chainlink VRF node generates proof off-chain
 *   3. Coordinator calls our `rawFulfillRandomWords(vrfRequestId, randomWords)`
 *   4. We look up our internal request via `vrfToInternalId`
 *   5. We call the requester's `fulfillRandomness(randomWord)` callback
 *
 * Stuck-request Recovery:
 *   - If the original `vrfCoordinator.requestRandomWords` reverted with
 *     `success=false` (e.g. sub had no LINK headroom), the request slot
 *     exists in `requests` but no `vrfToInternalId` entry was created.
 *     Anyone can call `retryRequest(contestId)` after `VRF_TIMEOUT` to
 *     re-fire the coordinator call.
 *   - If the coordinator accepted but VRF stalled, `retryRequest` re-fires
 *     anyway. Both old and new `vrfRequestId` map to the same internal
 *     request; whichever VRF callback arrives first wins, the other
 *     short-circuits in `_fulfillInternal` on `request.fulfilled`.
 *
 * Decentralization notes (unchanged from V1):
 *   - `vrfCoordinator` is immutable.
 *   - `subscriptionId` is immutable.
 *   - `callbackGasLimit` and `requestConfirmations` are bounded by hard caps.
 *   - No prototype-mode / owner-pick-winner functions.
 */
contract RandomnessManagerV2 is IRandomnessManager, Ownable2Step {
    /// @notice Chainlink VRF coordinator. Immutable to remove the master-key rug vector.
    address public immutable vrfCoordinator;

    /// @notice Chainlink VRF subscription. Immutable so the owner cannot zero
    ///         it to force every request through a fallback path that no
    ///         longer exists in V2 anyway.
    uint256 public immutable subscriptionId;

    bytes32 public keyHash;
    uint32  public callbackGasLimit;
    uint16  public requestConfirmations;
    uint32  public numWords;

    /// @notice Hard caps on owner-tunable VRF parameters. Match Chainlink's
    ///         per-request limits (2.5M gas, 200 confirmations) so the
    ///         owner cannot grief VRF by setting values outside the
    ///         coordinator's accepted range.
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;

    // ─── VRF V2.5 ExtraArgs encoding ─────────────────────────────────────────
    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    /// @dev Mirrors Chainlink VRF V2.5's `RandomWordsRequest` calldata tuple.
    ///      Declared locally so we don't take a hard dependency on the
    ///      Chainlink SDK. Used by `_fireVRF` so the coordinator sees a
    ///      properly tuple-wrapped calldata (offset 0x20 prefix).
    ///
    ///      Previous implementation used
    ///        abi.encodeWithSignature("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))", a, b, c, d, e, f)
    ///      which encodes a..f as six flat top-level args instead of one tuple
    ///      argument. The coordinator's ABI decoder then read keyHash as the
    ///      struct offset, jumped out of bounds, and reverted at ~295 gas.
    ///      The bug silently broke every VRF request from this contract
    ///      (subscription reqCount never advanced). Fixed by passing the
    ///      struct value through abi.encodeCall, which Solidity encodes as
    ///      a proper tuple param.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16  requestConfirmations;
        uint32  callbackGasLimit;
        uint32  numWords;
        bytes   extraArgs;
    }

    /// @dev Function selector for VRFCoordinatorV2Plus.requestRandomWords(RandomWordsRequest).
    ///      Locked in so a typo in the signature string can't reintroduce the
    ///      encoding bug. Equivalent to:
    ///        bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"))
    bytes4 private constant REQUEST_RANDOM_WORDS_SELECTOR = 0x9b1c385e;

    /// @notice Cool-down between consecutive `retryRequest` calls for the
    ///         same contest. Mirrors V1's VRF_TIMEOUT — gives Chainlink a
    ///         fair chance to deliver before a retry is allowed, and
    ///         limits griefing of the VRF subscription.
    uint256 public constant VRF_TIMEOUT = 2 hours;

    /// @notice Cap on retries per contestId so a permanently-broken
    ///         coordinator can't be used to drain the subscription.
    uint256 public constant MAX_RETRIES = 5;

    struct RandomnessRequest {
        bytes32 contestId;
        address requester;
        uint256 randomWord;
        bool fulfilled;
        bool exists;
        uint256 requestedAt;
    }

    // internal requestId => request data
    mapping(uint256 => RandomnessRequest) public requests;

    // contestId => internal requestId
    mapping(bytes32 => uint256) public contestRequests;

    // VRF coordinator requestId => our internal requestId
    mapping(uint256 => uint256) public vrfToInternalId;

    // contestId => randomWord (after fulfillment) — first word for backwards compat
    mapping(bytes32 => uint256) public contestRandomWords;

    // contestId => all random words (for multi-word requests)
    mapping(bytes32 => uint256[]) public contestRandomWordsArray;

    // Allowed contest contracts that can request randomness
    mapping(address => bool) public allowedRequesters;

    // Authorized factories that can register contests as allowed requesters
    mapping(address => bool) public authorizedFactories;

    uint256 private _requestCounter;

    // Retry tracking per contestId
    mapping(bytes32 => uint256) public retryCount;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotVRFCoordinator();
    error NotAllowedRequester();
    error NotAuthorized();
    error RequestAlreadyExists();
    error RequestNotFound();
    error AlreadyFulfilled();
    error CallbackGasLimitTooHigh();
    error RequestConfirmationsTooHigh();
    /// @dev `retryRequest` may only fire `VRF_TIMEOUT` after the last attempt.
    error RequestStillFresh();
    /// @dev `retryRequest` may only fire `MAX_RETRIES` times per contestId.
    error MaxRetriesExceeded();
    /// @dev `retryRequest` requires a real subscription to re-fire against.
    error SubscriptionMissing();

    // ─── Events ──────────────────────────────────────────────────────────────

    event AllowedRequesterAdded(address indexed requester, address indexed addedBy);
    event AllowedRequesterRemoved(address indexed requester);
    event FactoryAuthorizationChanged(address indexed factory, bool authorized);
    event VRFConfigUpdated(bytes32 keyHash, uint256 subscriptionId, uint32 callbackGasLimit);
    event VRFRequestSent(uint256 indexed internalId, uint256 indexed vrfRequestId);
    event VRFRequestFailed(uint256 indexed internalId, bytes32 indexed contestId);
    event CallbackFailed(uint256 indexed requestId, bytes32 indexed contestId, bytes reason);
    /// @notice Emitted by `retryRequest` on a successful coordinator re-fire.
    /// @param internalId   Internal request id (unchanged across retries).
    /// @param vrfRequestId New coordinator request id mapped to `internalId`.
    /// @param attempt      Current value of `retryCount[contestId]` (1-indexed).
    event VRFRequestRetried(uint256 indexed internalId, uint256 indexed vrfRequestId, uint256 attempt);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner() && !authorizedFactories[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier onlyAllowedRequester() {
        if (!allowedRequesters[msg.sender]) revert NotAllowedRequester();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subscriptionId
    ) Ownable() {
        require(_vrfCoordinator != address(0), "RMv2: zero coordinator");
        vrfCoordinator = _vrfCoordinator;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = 200_000; // sufficient for lottery prize distribution
        requestConfirmations = 3;
        numWords = 1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════════════

    function addAllowedRequester(address requester) external onlyOwnerOrFactory {
        allowedRequesters[requester] = true;
        emit AllowedRequesterAdded(requester, msg.sender);
    }

    function removeAllowedRequester(address requester) external onlyOwner {
        allowedRequesters[requester] = false;
        emit AllowedRequesterRemoved(requester);
    }

    function setAuthorizedFactory(address factory, bool authorized) external onlyOwner {
        authorizedFactories[factory] = authorized;
        emit FactoryAuthorizationChanged(factory, authorized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  REQUEST RANDOMNESS
    // ═══════════════════════════════════════════════════════════════════════════

    function requestRandomness(bytes32 contestId)
        external
        override
        onlyAllowedRequester
        returns (uint256 requestId)
    {
        return _requestVRF(contestId, numWords);
    }

    function requestRandomnessMulti(bytes32 contestId, uint32 _numWords)
        external
        override
        onlyAllowedRequester
        returns (uint256 requestId)
    {
        require(_numWords > 0 && _numWords <= 10, "RMv2: invalid numWords");
        return _requestVRF(contestId, _numWords);
    }

    /**
     * @dev Internal: create request record and call VRF coordinator.
     */
    function _requestVRF(bytes32 contestId, uint32 _numWords) internal returns (uint256 requestId) {
        if (contestRequests[contestId] != 0) revert RequestAlreadyExists();

        requestId = ++_requestCounter;

        requests[requestId] = RandomnessRequest({
            contestId: contestId,
            requester: msg.sender,
            randomWord: 0,
            fulfilled: false,
            exists: true,
            requestedAt: block.timestamp
        });

        contestRequests[contestId] = requestId;

        if (subscriptionId != 0) {
            _fireVRF(contestId, requestId, _numWords, false);
        }

        emit RandomnessRequested(requestId, msg.sender, contestId);
    }

    /**
     * @notice Permissionless retry of a stuck VRF request.
     *
     * Eligible when:
     *   - the request exists and is not fulfilled
     *   - at least `VRF_TIMEOUT` has elapsed since the last attempt
     *   - retry count is below `MAX_RETRIES`
     *   - this contract has a real subscription configured
     *
     * Effect:
     *   - Re-fires `vrfCoordinator.requestRandomWords` with the configured
     *     gas / confirmations / numWords for this RM.
     *   - Maps the new `vrfRequestId` to the same internal `requestId`. The
     *     old `vrfRequestId` mapping (if any) stays — whichever coordinator
     *     callback arrives first wins, the other emits `CallbackFailed`.
     *   - Bumps `retryCount[contestId]` and resets `requestedAt` so the next
     *     retry respects `VRF_TIMEOUT` from this attempt.
     *
     * @param contestId The contest/lottery key originally used in `requestRandomness`.
     */
    function retryRequest(bytes32 contestId) external {
        if (subscriptionId == 0) revert SubscriptionMissing();

        uint256 requestId = contestRequests[contestId];
        if (requestId == 0) revert RequestNotFound();

        RandomnessRequest storage request = requests[requestId];
        if (request.fulfilled) revert AlreadyFulfilled();
        if (block.timestamp < request.requestedAt + VRF_TIMEOUT) revert RequestStillFresh();
        if (retryCount[contestId] >= MAX_RETRIES) revert MaxRetriesExceeded();

        // Determine numWords from the existing array length (defaults to numWords=1
        // for legacy single-word requests where the array was never populated).
        uint32 _numWords = uint32(contestRandomWordsArray[contestId].length);
        if (_numWords == 0) _numWords = numWords;

        retryCount[contestId]++;
        request.requestedAt = block.timestamp;

        _fireVRF(contestId, requestId, _numWords, true);
    }

    /**
     * @dev Single coordinator-call code path used by both initial requests
     *      and retries. `isRetry` only changes which event is emitted on
     *      success.
     */
    function _fireVRF(bytes32 contestId, uint256 requestId, uint32 _numWords, bool isRetry) internal {
        bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false);

        RandomWordsRequest memory req = RandomWordsRequest({
            keyHash:              keyHash,
            subId:                subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit:     callbackGasLimit,
            numWords:             _numWords,
            extraArgs:            extraArgs
        });

        // IMPORTANT: passing the struct by value here (rather than spreading
        // its fields as separate args) is what gives the coordinator its
        // expected tuple-encoded calldata. See RandomWordsRequest NatSpec
        // above for the history.
        (bool success, bytes memory returnData) = vrfCoordinator.call(
            abi.encodeWithSelector(REQUEST_RANDOM_WORDS_SELECTOR, req)
        );

        if (success && returnData.length >= 32) {
            uint256 vrfRequestId = abi.decode(returnData, (uint256));
            vrfToInternalId[vrfRequestId] = requestId;
            if (isRetry) {
                emit VRFRequestRetried(requestId, vrfRequestId, retryCount[contestId]);
            } else {
                emit VRFRequestSent(requestId, vrfRequestId);
            }
        } else if (!success) {
            emit VRFRequestFailed(requestId, contestId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VRF CALLBACK (Chainlink VRF V2.5)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by the VRF Coordinator to deliver randomness.
     */
    function rawFulfillRandomWords(uint256 vrfRequestId, uint256[] memory randomWords) external {
        if (msg.sender != vrfCoordinator) revert NotVRFCoordinator();

        uint256 internalId = vrfToInternalId[vrfRequestId];
        require(internalId != 0, "RMv2: unknown VRF request");

        _fulfillInternal(internalId, randomWords);
    }

    /**
     * @dev Internal fulfillment. Called by `rawFulfillRandomWords`. If the
     *      request was already fulfilled by an earlier callback (e.g. the
     *      original VRF request landed AFTER a retry's request), short-
     *      circuit with `CallbackFailed` so the second callback is a benign
     *      no-op rather than a revert that the coordinator would log as
     *      "consumer reverted".
     */
    function _fulfillInternal(uint256 requestId, uint256[] memory randomWords) internal {
        require(randomWords.length > 0, "RMv2: empty randomWords");
        RandomnessRequest storage request = requests[requestId];
        if (!request.exists) revert RequestNotFound();
        if (request.fulfilled) {
            // Double-callback (e.g. retry race): swallow gracefully so the
            // VRF coordinator doesn't log this as a consumer revert.
            emit CallbackFailed(requestId, request.contestId, "already fulfilled");
            return;
        }

        (bool success, bytes memory returnData) = request.requester.call(
            abi.encodeWithSignature(
                "fulfillRandomness(uint256)",
                randomWords[0]
            )
        );

        if (success) {
            request.randomWord = randomWords[0];
            contestRandomWords[request.contestId] = randomWords[0];
            contestRandomWordsArray[request.contestId] = randomWords;
            request.fulfilled = true;
            emit RandomnessFulfilled(requestId, request.contestId, randomWords[0]);
        } else {
            emit CallbackFailed(requestId, request.contestId, returnData);
        }
    }

    /**
     * @notice Reset a failed request so a new `requestRandomness` can be made
     *         for the same `contestId`. Callable by the original requester
     *         (lottery / contest contract) or this RM's owner.
     *
     *         Used by `NoLossLotteryV3.cancelDraw` / `cancelDrawPublic` when
     *         the round needs to be unstuck without settling.
     */
    function resetFailedRequest(bytes32 contestId) external {
        uint256 requestId = contestRequests[contestId];
        require(requestId != 0, "RMv2: no request");
        require(
            msg.sender == owner() || msg.sender == requests[requestId].requester,
            "RMv2: not authorized"
        );
        // V1 audit H-01: require the request be demonstrably failed before allowing reset
        // — not yet fulfilled, and old enough that VRF has had time to deliver.
        //
        // NOTE: this escape hatch is intentionally NOT gated by MAX_RETRIES. The
        // earlier version shared `retryCount` with `retryRequest` and blocked reset
        // once retries were exhausted — which permanently bricked a consumer's
        // contestId (e.g. NoLossLottery.cancelDraw could never clear the slot, so
        // every future performUpkeep reverted RequestAlreadyExists). Reset clears
        // the slot AND zeroes `retryCount` so a fresh request for the same
        // contestId starts with a clean retry budget.
        RandomnessRequest storage request = requests[requestId];
        require(!request.fulfilled, "RMv2: already fulfilled");
        require(block.timestamp >= request.requestedAt + VRF_TIMEOUT, "RMv2: still fresh");
        delete contestRequests[contestId];
        delete requests[requestId];
        delete contestRandomWords[contestId];
        delete contestRandomWordsArray[contestId];
        delete retryCount[contestId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getRandomWord(bytes32 contestId) external view override returns (uint256) {
        return contestRandomWords[contestId];
    }

    function getRandomWords(bytes32 contestId) external view override returns (uint256[] memory) {
        return contestRandomWordsArray[contestId];
    }

    function isRequestPending(bytes32 contestId) external view override returns (bool) {
        uint256 requestId = contestRequests[contestId];
        return requestId != 0 && !requests[requestId].fulfilled;
    }

    function isRequestFulfilled(bytes32 contestId) external view override returns (bool) {
        uint256 requestId = contestRequests[contestId];
        return requestId != 0 && requests[requestId].fulfilled;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update VRF gas / confirmations / lane (keyHash).
     * @dev    Coordinator address AND subscriptionId are immutable; only gas
     *         params and keyHash can be tuned. Both gas params are hard-capped
     *         so a compromised owner cannot set values outside Chainlink's
     *         accepted range (which would silently fail every request).
     */
    function updateVRFConfig(
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyOwner {
        if (_callbackGasLimit > MAX_CALLBACK_GAS_LIMIT) revert CallbackGasLimitTooHigh();
        if (_requestConfirmations > MAX_REQUEST_CONFIRMATIONS) revert RequestConfirmationsTooHigh();
        keyHash = _keyHash;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        emit VRFConfigUpdated(_keyHash, subscriptionId, _callbackGasLimit);
    }
}
