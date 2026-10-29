// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IRandomnessManager.sol";

/**
 * @title RandomnessManager
 * @notice Manages VRF randomness requests for contests and lotteries.
 * @dev Integrates with Chainlink VRF V2.5 (used on Base mainnet and Base Sepolia).
 *
 * VRF Callback Flow (production):
 *   1. Contest/Lottery calls requestRandomness() → we call coordinator.requestRandomWords()
 *   2. Chainlink VRF node generates proof off-chain
 *   3. Coordinator calls our rawFulfillRandomWords(vrfRequestId, randomWords)
 *   4. We look up our internal request via vrfRequestId → internal mapping
 *   5. We call the requester's fulfillRandomness(randomWord) callback
 *
 * Local/Test Fallback:
 *   - Owner can call manualFulfill() to deliver randomness without VRF infrastructure
 *   - Used on Anvil and as emergency recovery on testnet/mainnet ONLY after
 *     manualFulfillDelay + VRF_TIMEOUT (≥3h) have elapsed.
 *
 * Decentralization notes:
 *   - vrfCoordinator is immutable: cannot be rugged by owner key. Migrating to a new
 *     coordinator requires deploying a new RandomnessManager.
 *   - subscriptionId is immutable (post-2026-04-28 hardening): cannot be zeroed by
 *     owner to force every request into the manual-fulfill path. Migrating to a new
 *     Chainlink subscription requires deploying a new RandomnessManager.
 *   - manualFulfillDelay is a hardcoded constant (1h): cannot be tightened by an owner
 *     to enable instant manual override.
 *   - callbackGasLimit and requestConfirmations are bounded by hard caps so a
 *     compromised owner cannot grief VRF by setting them to absurd values.
 *   - Prototype-mode owner-pick-winner functions have been removed.
 */
contract RandomnessManager is IRandomnessManager, Ownable2Step {
    /// @notice Chainlink VRF coordinator. Immutable to remove the master-key rug vector.
    address public immutable vrfCoordinator;

    /// @notice Chainlink VRF subscription. Immutable to prevent the owner from
    ///         disabling VRF (subscriptionId=0 ⇒ no VRF call, every request must
    ///         go through manualFulfill). Migration requires redeploying.
    uint256 public immutable subscriptionId;

    bytes32 public keyHash;
    uint32  public callbackGasLimit;
    uint16  public requestConfirmations;
    uint32  public numWords;

    /// @notice Hard caps on owner-tunable VRF parameters. Chainlink's own
    ///         per-request limits are 2.5M gas and 200 confirmations; we
    ///         match those so the owner cannot set values outside the
    ///         coordinator's accepted range (which would silently fail every
    ///         request and force the manual-fulfill fallback).
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;

    // ─── VRF V2.5 ExtraArgs encoding ─────────────────────────────────────────
    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    /// @dev See RandomnessManagerV2.RandomWordsRequest for full history.
    ///      Short version: `abi.encodeWithSignature("...((...))", a, b, c, ...)`
    ///      encodes the args flat, not as a tuple — coordinator's ABI decoder
    ///      then jumps out of bounds. Fix is to pass a struct value through
    ///      abi.encodeWithSelector so Solidity wraps it correctly.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16  requestConfirmations;
        uint32  callbackGasLimit;
        uint32  numWords;
        bytes   extraArgs;
    }

    bytes4 private constant REQUEST_RANDOM_WORDS_SELECTOR = 0x9b1c385e;

    /// @notice Hardcoded manual-fulfill delay; cannot be tightened by owner.
    uint256 public constant MANUAL_FULFILL_DELAY = 1 hours;
    /// @notice Additional VRF timeout: manual fulfill requires both MANUAL_FULFILL_DELAY
    ///         AND VRF_TIMEOUT to have elapsed, ensuring VRF has genuinely timed out.
    uint256 public constant VRF_TIMEOUT = 2 hours;

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

    // Retry tracking per contestId to prevent infinite retry abuse
    mapping(bytes32 => uint256) public retryCount;
    uint256 public constant MAX_RETRIES = 5;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotVRFCoordinator();
    error NotAllowedRequester();
    error NotAuthorized();
    error RequestAlreadyExists();
    error RequestNotFound();
    error AlreadyFulfilled();
    error ManualFulfillTooEarly();
    error CallbackGasLimitTooHigh();
    error RequestConfirmationsTooHigh();

    // ─── Events ──────────────────────────────────────────────────────────────

    event AllowedRequesterAdded(address indexed requester, address indexed addedBy);
    event AllowedRequesterRemoved(address indexed requester);
    event FactoryAuthorizationChanged(address indexed factory, bool authorized);
    event VRFConfigUpdated(bytes32 keyHash, uint256 subscriptionId, uint32 callbackGasLimit);
    event VRFRequestSent(uint256 indexed internalId, uint256 indexed vrfRequestId);
    event VRFRequestFailed(uint256 indexed internalId, bytes32 indexed contestId);
    event ManualFulfillment(uint256 indexed requestId, uint256 randomWord);
    event CallbackFailed(uint256 indexed requestId, bytes32 indexed contestId, bytes reason);

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
        require(_vrfCoordinator != address(0), "RM: zero coordinator");
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

    /**
     * @notice Request randomness for a contest (single word).
     */
    function requestRandomness(bytes32 contestId)
        external
        override
        onlyAllowedRequester
        returns (uint256 requestId)
    {
        return _requestVRF(contestId, numWords);
    }

    /**
     * @notice Request randomness with a specific number of words.
     */
    function requestRandomnessMulti(bytes32 contestId, uint32 _numWords)
        external
        override
        onlyAllowedRequester
        returns (uint256 requestId)
    {
        require(_numWords > 0 && _numWords <= 10, "RM: invalid numWords");
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
            // Encode extraArgs for V2.5: pay with LINK (nativePayment = false)
            bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false);

            RandomWordsRequest memory req = RandomWordsRequest({
                keyHash:              keyHash,
                subId:                subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit:     callbackGasLimit,
                numWords:             _numWords,
                extraArgs:            extraArgs
            });

            // Struct must be passed by value (not spread) so Solidity emits
            // the tuple-offset prefix the coordinator expects. See struct
            // NatSpec above for history.
            (bool success, bytes memory returnData) = vrfCoordinator.call(
                abi.encodeWithSelector(REQUEST_RANDOM_WORDS_SELECTOR, req)
            );

            if (success && returnData.length >= 32) {
                uint256 vrfRequestId = abi.decode(returnData, (uint256));
                vrfToInternalId[vrfRequestId] = requestId;
                emit VRFRequestSent(requestId, vrfRequestId);
            } else if (!success) {
                emit VRFRequestFailed(requestId, contestId);
            }
        }

        emit RandomnessRequested(requestId, msg.sender, contestId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VRF CALLBACK (Chainlink VRF V2.5)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by the VRF Coordinator to deliver randomness.
     * @dev This is the function Chainlink VRF actually calls (not fulfillRandomWords directly).
     *      Implements the VRFConsumerBaseV2Plus pattern without inheriting the base contract.
     */
    function rawFulfillRandomWords(uint256 vrfRequestId, uint256[] memory randomWords) external {
        if (msg.sender != vrfCoordinator) revert NotVRFCoordinator();

        uint256 internalId = vrfToInternalId[vrfRequestId];
        require(internalId != 0, "RM: unknown VRF request");

        _fulfillInternal(internalId, randomWords);
    }

    /**
     * @notice Manual fulfillment for testing and emergency fallback (owner only).
     * @dev Works on any environment. Used on Anvil (local) and as emergency on testnet/mainnet
     *      after MANUAL_FULFILL_DELAY + VRF_TIMEOUT (≥3h) have elapsed since the request was
     *      created. The constants are not owner-tunable.
     */
    function manualFulfill(uint256 requestId, uint256 randomWord) external onlyOwner {
        RandomnessRequest storage request = requests[requestId];
        if (!request.exists) revert RequestNotFound();
        if (block.timestamp < request.requestedAt + MANUAL_FULFILL_DELAY + VRF_TIMEOUT) revert ManualFulfillTooEarly();

        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        _fulfillInternal(requestId, words);

        emit ManualFulfillment(requestId, randomWord);
    }

    /**
     * @dev Internal fulfillment logic shared by all callback paths.
     */
    function _fulfillInternal(uint256 requestId, uint256[] memory randomWords) internal {
        require(randomWords.length > 0, "RandomnessManager: empty randomWords");
        RandomnessRequest storage request = requests[requestId];
        if (!request.exists) revert RequestNotFound();
        if (request.fulfilled) revert AlreadyFulfilled();

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
     * @notice Reset a failed request so a new one can be made for the same contestId.
     */
    function resetFailedRequest(bytes32 contestId) external {
        uint256 requestId = contestRequests[contestId];
        require(requestId != 0, "RM: no request");
        require(
            msg.sender == owner() || msg.sender == requests[requestId].requester,
            "RM: not authorized"
        );
        require(retryCount[contestId] < MAX_RETRIES, "RM: max retries exceeded");
        // Audit H-01: prevent re-rolling an in-flight VRF request. The request must be
        // demonstrably failed — not yet fulfilled, and old enough that VRF has had time
        // to deliver. Mirrors the freshness floor used by manualFulfill.
        RandomnessRequest storage request = requests[requestId];
        require(!request.fulfilled, "RM: already fulfilled");
        require(block.timestamp >= request.requestedAt + VRF_TIMEOUT, "RM: still fresh");
        retryCount[contestId]++;
        delete contestRequests[contestId];
        delete requests[requestId];
        delete contestRandomWords[contestId];
        delete contestRandomWordsArray[contestId];
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
     * @notice Update VRF configuration. Should be routed through TimelockController.
     * @dev coordinator address AND subscriptionId are immutable; only the gas params
     *      and keyHash (= which VRF lane) can be tuned here. Both gas params are
     *      hard-capped so a compromised owner cannot set them outside Chainlink's
     *      accepted range (which would silently fail every request).
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
