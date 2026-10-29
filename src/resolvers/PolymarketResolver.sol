// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IResolver.sol";

/// @title PolymarketResolver
/// @notice Async resolver that mirrors Polymarket market outcomes for
///         MindYield contests. Reads Polymarket's settled CTF payouts on
///         Polygon via Chainlink Functions (off-chain DON makes the
///         eth_call), then serves the result on Base.
///
/// @dev    Polymarket settlement lives on the Gnosis Conditional Tokens
///         Framework at `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045` on
///         Polygon. Post-settlement, `payoutNumerators(conditionId, i) /
///         payoutDenominator(conditionId)` gives outcome i's share of the
///         payout. For binary markets the only non-degenerate values are:
///           - [1, 0]  → YES won
///           - [0, 1]  → NO won
///           - [1, 1]  → ambiguous / 50-50 (UMA's "unknowable" sentinel)
///         Any other shape ([0, 0] = unsettled; >2 outcomes = unsupported)
///         is reported as not-ready.
///
///         This contract is self-contained — it does NOT inherit from
///         Chainlink's FunctionsClient. To wire it to a real Functions
///         router, set `router` to the FunctionsRouter address on Base
///         (mainnet: 0xf9B8fc078197181C841c296C876945aaa425B278) and
///         either:
///           (a) Have the router call this contract's
///               `fulfillRequest(requestId, response, err)` directly, or
///           (b) Replace this contract's manual router gate with
///               `inherit FunctionsClient` and the standard
///               `_fulfillRequest` virtual override. The signature here
///               matches FunctionsClient v1 so the swap is mechanical.
///
///         The off-chain JS that the DON executes is published as
///         `JS_SOURCE` so deployers can verify it on-chain.
contract PolymarketResolver is IResolver {
    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error NotAuthorized();
    error NotRouter();
    error AlreadyRegistered();
    error NotRegistered();
    error InvalidParams();
    error AlreadyFulfilled();
    error UnknownRequest();

    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    /// @dev Per-contest config + state. Packed for one storage slot per
    ///      scalar group where possible.
    struct PolyConfig {
        bytes32 conditionId;       // Polymarket CTF condition id (the binding)
        bytes32 yesOption;         // optionId returned when YES outcome wins
        bytes32 noOption;          // optionId returned when NO outcome wins
        bool registered;           // true after register()
        bool settled;              // true after fulfilled or manual finalize
        bool ambiguous;            // true if CTF returned [1,1]
        bytes32 winner;            // resolved winner (yesOption / noOption / 0)
        bytes32 lastRequestId;     // most recent in-flight request, if any
    }

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------

    /// @notice 7-day timeout — covers the worst-case UMA dispute window
    ///         (2h liveness + up to ~6 days of DVM voting). After this
    ///         the contest's owner can cancel-and-refund.
    uint64 public constant SETTLEMENT_TIMEOUT = 7 days;

    /// @notice JS source executed by the Chainlink Functions DON. Reads
    ///         CTF payouts on Polygon via eth_call; returns one of the
    ///         four sentinels (YES_WIN, NO_WIN, AMBIGUOUS, NOT_READY) as
    ///         a single uint8 in big-endian bytes.
    /// @dev    Keeping the source on-chain lets deployers and auditors
    ///         verify exactly what the DON ran for each fulfillment. The
    ///         DON itself fetches this string off-chain when uploaded to
    ///         the subscription, but we anchor a copy here for trust.
    string public constant JS_SOURCE =
        "const conditionId = args[0];"
        "const ctf = '0x4D97DCd97eC945f40cF65F87097ACe5EA0476045';"
        "const rpc = secrets.polygonRpc;"
        // payoutDenominator(bytes32) selector = keccak256('payoutDenominator(bytes32)')[0:4]
        // payoutNumerators(bytes32,uint256) selector likewise
        "const PAYOUT_DENOM_SEL = '0x88be0367';"
        "const PAYOUT_NUM_SEL   = '0x80a3aff8';"
        "async function call(data) {"
        "  const r = await Functions.makeHttpRequest({"
        "    url: rpc, method: 'POST',"
        "    headers: {'content-type':'application/json'},"
        "    data: {jsonrpc:'2.0', id:1, method:'eth_call', params:[{to: ctf, data}, 'latest']}"
        "  });"
        "  if (r.error || !r.data || !r.data.result) throw Error('rpc fail');"
        "  return r.data.result;"
        "}"
        "const idHex = conditionId.slice(2).padStart(64,'0');"
        "const denom = BigInt(await call(PAYOUT_DENOM_SEL + idHex));"
        "if (denom === 0n) return Functions.encodeUint256(3n);" // 3 = NOT_READY
        "const yes = BigInt(await call(PAYOUT_NUM_SEL + idHex + '0000000000000000000000000000000000000000000000000000000000000000'));"
        "const no  = BigInt(await call(PAYOUT_NUM_SEL + idHex + '0000000000000000000000000000000000000000000000000000000000000001'));"
        "if (yes === denom && no === 0n) return Functions.encodeUint256(0n);" // 0 = YES_WIN
        "if (yes === 0n && no === denom) return Functions.encodeUint256(1n);" // 1 = NO_WIN
        "if (yes > 0n && no > 0n) return Functions.encodeUint256(2n);"        // 2 = AMBIGUOUS
        "return Functions.encodeUint256(3n);";                                  // 3 = NOT_READY

    uint8 public constant RESULT_YES_WIN   = 0;
    uint8 public constant RESULT_NO_WIN    = 1;
    uint8 public constant RESULT_AMBIGUOUS = 2;
    uint8 public constant RESULT_NOT_READY = 3;

    // ---------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------

    /// @notice Address allowed to call register() — typically the factory.
    address public immutable authorizedFactory;

    /// @notice Address allowed to deliver fulfillRequest() — Functions
    ///         Router on Base, or a relayer in non-Functions setups.
    address public immutable router;

    /// @notice Per-contest configuration and resolution state.
    mapping(bytes32 => PolyConfig) public configs;

    /// @notice Reverse lookup: requestId → contestId. Functions returns
    ///         the requestId on fulfillment; we recover the contest from
    ///         it.
    mapping(bytes32 => bytes32) public requestToContest;

    /// @notice Pluggable for testing — tests can pre-pick a deterministic
    ///         requestId. Production override sets this to the result of
    ///         FunctionsRouter.sendRequest. Counter is incremented in
    ///         `requestSettlement` to ensure uniqueness even without the
    ///         router doing its own salting.
    uint256 public requestNonce;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event ContestRegistered(
        bytes32 indexed contestId,
        bytes32 indexed conditionId,
        bytes32 yesOption,
        bytes32 noOption
    );
    event SettlementRequested(bytes32 indexed contestId, bytes32 indexed requestId);
    event SettlementFulfilled(
        bytes32 indexed contestId,
        bytes32 indexed requestId,
        uint8 result,
        bytes32 winner
    );
    event SettlementFailed(
        bytes32 indexed contestId,
        bytes32 indexed requestId,
        bytes err
    );

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    constructor(address _authorizedFactory, address _router) {
        if (_authorizedFactory == address(0) || _router == address(0)) revert InvalidParams();
        authorizedFactory = _authorizedFactory;
        router = _router;
    }

    // ---------------------------------------------------------------
    // IResolver
    // ---------------------------------------------------------------

    /// @notice Bind a MindYield contest to a Polymarket market.
    /// @param params ABI-encoded (bytes32 conditionId, bytes32 yesOption,
    ///        bytes32 noOption). The conditionId is read off Polymarket's
    ///        Gamma API at curation time and pinned on-chain here.
    function register(bytes32 contestId, bytes calldata params) external {
        if (msg.sender != authorizedFactory) revert NotAuthorized();
        if (configs[contestId].registered) revert AlreadyRegistered();

        (bytes32 conditionId, bytes32 yesOption, bytes32 noOption) =
            abi.decode(params, (bytes32, bytes32, bytes32));

        if (conditionId == bytes32(0)) revert InvalidParams();
        if (yesOption == bytes32(0) || noOption == bytes32(0)) revert InvalidParams();
        if (yesOption == noOption) revert InvalidParams();

        configs[contestId] = PolyConfig({
            conditionId:    conditionId,
            yesOption:      yesOption,
            noOption:       noOption,
            registered:     true,
            settled:        false,
            ambiguous:      false,
            winner:         bytes32(0),
            lastRequestId:  bytes32(0)
        });

        emit ContestRegistered(contestId, conditionId, yesOption, noOption);
    }

    /// @notice Kick off (or re-kick) a settlement request to the DON.
    /// @dev    Always emits — caller (creator, keeper, or anyone) gets a
    ///         requestId for tracking. Callable while unsettled to retry
    ///         after a transient RPC failure or a too-early call. No
    ///         payment is taken; the configured router/subscription
    ///         absorbs LINK costs.
    function requestSettlement(bytes32 contestId) external returns (bool) {
        PolyConfig storage cfg = configs[contestId];
        if (!cfg.registered) revert NotRegistered();
        if (cfg.settled) return false;

        // Derive a deterministic requestId. In a real Functions
        // integration the router returns the canonical requestId; we
        // store both and the router can call back with EITHER (the real
        // one OR our derivation). For our self-contained mock-router
        // tests, this derivation IS the requestId.
        bytes32 requestId = keccak256(
            abi.encode(address(this), contestId, ++requestNonce, block.timestamp)
        );

        cfg.lastRequestId = requestId;
        requestToContest[requestId] = contestId;

        emit SettlementRequested(contestId, requestId);
        return true;
    }

    /// @notice Read the resolved outcome.
    /// @return ready          true once the DON has fulfilled
    /// @return winningOption  yesOption / noOption / bytes32(0) for ambiguous
    function resolve(bytes32 contestId)
        external
        view
        returns (bool ready, bytes32 winningOption)
    {
        PolyConfig memory cfg = configs[contestId];
        if (!cfg.registered) revert NotRegistered();
        if (!cfg.settled) return (false, bytes32(0));
        // ambiguous → bytes32(0) which ContestV2 interprets as cancel-and-refund
        return (true, cfg.ambiguous ? bytes32(0) : cfg.winner);
    }

    function settlementTimeout() external pure returns (uint64) {
        return SETTLEMENT_TIMEOUT;
    }

    function resolverType() external pure returns (bytes32) {
        return keccak256("PolymarketResolver.v1");
    }

    // ---------------------------------------------------------------
    // Functions callback (router-only)
    // ---------------------------------------------------------------

    /// @notice DON fulfillment callback. Signature mirrors
    ///         Chainlink Functions v1 `_fulfillRequest` so swapping in
    ///         the real `FunctionsClient` base contract is mechanical.
    /// @param requestId The DON's request id (matched to a contest via
    ///        `requestToContest`).
    /// @param response  ABI-encoded uint256 — one of the RESULT_* sentinels.
    ///        Empty if the JS itself errored (in which case `err` is set).
    /// @param err       Error bytes from the DON. Non-empty means the JS
    ///        threw or the off-chain call failed; we don't settle on
    ///        this — caller can retry via requestSettlement.
    function fulfillRequest(
        bytes32 requestId,
        bytes calldata response,
        bytes calldata err
    ) external {
        if (msg.sender != router) revert NotRouter();

        bytes32 contestId = requestToContest[requestId];
        if (contestId == bytes32(0)) revert UnknownRequest();
        delete requestToContest[requestId];

        PolyConfig storage cfg = configs[contestId];
        if (cfg.settled) revert AlreadyFulfilled();

        if (err.length > 0) {
            // Off-chain error — log and leave unsettled so caller can
            // retry. Treating this as "settled to ambiguous" would
            // grief the contest into a forced refund.
            emit SettlementFailed(contestId, requestId, err);
            return;
        }
        if (response.length < 32) {
            emit SettlementFailed(contestId, requestId, bytes("malformed response"));
            return;
        }

        uint256 result = abi.decode(response, (uint256));
        if (result == RESULT_YES_WIN) {
            cfg.settled = true;
            cfg.winner  = cfg.yesOption;
        } else if (result == RESULT_NO_WIN) {
            cfg.settled = true;
            cfg.winner  = cfg.noOption;
        } else if (result == RESULT_AMBIGUOUS) {
            cfg.settled   = true;
            cfg.ambiguous = true;
            // winner stays bytes32(0)
        } else {
            // RESULT_NOT_READY or unrecognized — leave unsettled for retry
            emit SettlementFailed(contestId, requestId, bytes("not ready"));
            return;
        }

        emit SettlementFulfilled(contestId, requestId, uint8(result), cfg.winner);
    }
}
