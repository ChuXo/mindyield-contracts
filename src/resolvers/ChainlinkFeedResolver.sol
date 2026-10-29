// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IResolver.sol";

// Minimal Chainlink AggregatorV3 interface — inlined so we don't have to add
// the Chainlink npm package as a foundry submodule just for one function.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title ChainlinkFeedResolver
/// @notice Binary "above/below threshold at cutoff time" resolver backed by
///         a Chainlink Data Feed. Synchronous — resolve() reads the feed
///         directly on-chain and does not require a settlement trigger.
/// @dev    One instance serves many contests. Storage is keyed by contestId.
///         The factory (authorizedFactory) is the only caller allowed to
///         register new contests. Configs are immutable once written.
contract ChainlinkFeedResolver is IResolver {
    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error NotAuthorized();
    error AlreadyRegistered();
    error NotRegistered();
    error InvalidParams();
    error StaleAnswer();
    error CutoffNotReached();

    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    /// @dev Packed into a single storage struct for O(1) register/resolve.
    struct FeedConfig {
        IAggregatorV3 feed;     // Chainlink price feed (address(0) == unregistered)
        uint64 cutoff;          // Unix timestamp; resolve() rejects earlier reads
        uint32 staleAfter;      // Reject answers older than this many seconds
        bytes32 yesOption;      // optionId returned when answer >= threshold
        bytes32 noOption;       // optionId returned when answer <  threshold
        int256 threshold;       // In feed.decimals() units
    }

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------

    /// @notice 24-hour settlement timeout — data feeds update continuously,
    ///         so any contest hitting this means the feed is unhealthy.
    uint64 public constant SETTLEMENT_TIMEOUT = 24 hours;

    /// @notice Hard cap on staleAfter to prevent misconfigured contests
    ///         reading feeds that are hours out of date. Chainlink's
    ///         strictest feeds update every ~30 min; 6h is a safe ceiling.
    uint32 public constant MAX_STALE_AFTER = 6 hours;

    // ---------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------

    /// @notice Factory allowed to call register(). Set at construction.
    address public immutable authorizedFactory;

    /// @notice Per-contest configuration. Zero feed == unregistered.
    mapping(bytes32 => FeedConfig) public configs;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event ContestRegistered(
        bytes32 indexed contestId,
        address indexed feed,
        int256 threshold,
        uint64 cutoff,
        bytes32 yesOption,
        bytes32 noOption
    );

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    constructor(address _authorizedFactory) {
        if (_authorizedFactory == address(0)) revert InvalidParams();
        authorizedFactory = _authorizedFactory;
    }

    // ---------------------------------------------------------------
    // IResolver
    // ---------------------------------------------------------------

    /// @notice Register a contest.
    /// @param params ABI-encoded (address feed, int256 threshold,
    ///        uint64 cutoff, uint32 staleAfter, bytes32 yesOption,
    ///        bytes32 noOption).
    function register(bytes32 contestId, bytes calldata params) external {
        if (msg.sender != authorizedFactory) revert NotAuthorized();
        if (configs[contestId].feed != IAggregatorV3(address(0))) revert AlreadyRegistered();

        (
            address feed,
            int256 threshold,
            uint64 cutoff,
            uint32 staleAfter,
            bytes32 yesOption,
            bytes32 noOption
        ) = abi.decode(params, (address, int256, uint64, uint32, bytes32, bytes32));

        if (feed == address(0)) revert InvalidParams();
        if (cutoff <= block.timestamp) revert InvalidParams();
        if (staleAfter == 0 || staleAfter > MAX_STALE_AFTER) revert InvalidParams();
        if (yesOption == bytes32(0) || noOption == bytes32(0)) revert InvalidParams();
        if (yesOption == noOption) revert InvalidParams();

        // Sanity check: feed must respond. decimals() is view and cheap;
        // a revert here catches typoed addresses at registration rather
        // than months later at resolution.
        IAggregatorV3(feed).decimals();

        configs[contestId] = FeedConfig({
            feed: IAggregatorV3(feed),
            cutoff: cutoff,
            staleAfter: staleAfter,
            yesOption: yesOption,
            noOption: noOption,
            threshold: threshold
        });

        emit ContestRegistered(contestId, feed, threshold, cutoff, yesOption, noOption);
    }

    /// @notice No-op for synchronous resolvers — resolve() reads the feed
    ///         directly. Present so callers can treat all resolvers
    ///         uniformly.
    function requestSettlement(bytes32 /* contestId */) external pure returns (bool) {
        return false;
    }

    /// @notice Read the feed and decide yes/no based on threshold comparison.
    /// @dev    Pure view so callers can invoke without reentrancy concerns.
    ///         Reverts on stale data so the caller can distinguish "not
    ///         ready" (cutoff not reached) from "feed is broken" (stale).
    function resolve(bytes32 contestId)
        external
        view
        returns (bool ready, bytes32 winningOption)
    {
        FeedConfig memory cfg = configs[contestId];
        if (address(cfg.feed) == address(0)) revert NotRegistered();

        // Not time yet → return not-ready. Caller should wait, not cancel.
        if (block.timestamp < cfg.cutoff) return (false, bytes32(0));

        (
            , /* roundId */
            int256 answer,
            , /* startedAt */
            uint256 updatedAt,
            /* answeredInRound */
        ) = cfg.feed.latestRoundData();

        // Audit M-02: stale data is a transient infrastructure issue, not a
        // permanent failure — return (false, 0) so the caller waits and
        // retries instead of cancelling the entire contest. ContestV2's try/catch
        // around resolve() previously triggered _cancel on revert; with the
        // not-ready signal it routes through the resolver-not-ready path
        // instead. After SETTLEMENT_TIMEOUT the caller may force a cancel.
        if (updatedAt == 0) return (false, bytes32(0));
        if (block.timestamp > updatedAt + cfg.staleAfter) return (false, bytes32(0));

        winningOption = answer >= cfg.threshold ? cfg.yesOption : cfg.noOption;
        ready = true;
    }

    function settlementTimeout() external pure returns (uint64) {
        return SETTLEMENT_TIMEOUT;
    }

    function resolverType() external pure returns (bytes32) {
        return keccak256("ChainlinkFeedResolver.v1");
    }
}
