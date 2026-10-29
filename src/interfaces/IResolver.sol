// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IResolver
/// @notice Pluggable outcome source for contests that resolve against external
///         ground truth (price feeds, prediction-market mirrors, UMA requests,
///         etc.). Synchronous resolvers (e.g. Chainlink Data Feeds) implement
///         resolve() as a pure view; asynchronous resolvers (e.g. Polymarket
///         via Chainlink Functions) dispatch off-chain work in
///         requestSettlement() and then serve the stored answer from resolve().
interface IResolver {
    /// @notice Bind a contest to this resolver with the parameters it needs.
    /// @dev    Called once by the factory right after the contest clone is
    ///         initialized. MUST revert on duplicate registration or invalid
    ///         params. Auth is the resolver's responsibility — typical
    ///         pattern is to whitelist the factory.
    /// @param contestId Opaque identifier chosen by the factory. Resolvers
    ///        key their storage off this value.
    /// @param params    ABI-encoded resolver-specific config. Each resolver
    ///        documents its own schema.
    function register(bytes32 contestId, bytes calldata params) external;

    /// @notice Optional trigger that dispatches off-chain settlement work.
    /// @dev    No-op for synchronous resolvers — they read fresh on-chain
    ///         state in resolve() directly. Async resolvers use this hook
    ///         to kick off a Functions request / UMA propose / etc.
    ///         Callable by anyone so stalled contests can always be nudged.
    /// @return triggered true iff this call dispatched new work (useful for
    ///         idempotency / double-spend protection in callers).
    function requestSettlement(bytes32 contestId) external returns (bool triggered);

    /// @notice Fetch the settled outcome for a contest.
    /// @dev    MUST be pure view so ContestV2.resolveContest() can call it
    ///         without reentrancy concerns. Async resolvers return
    ///         (false, 0) until their callback populates storage.
    /// @return ready          true iff settlement is complete
    /// @return winningOption  the winning option id. The sentinel bytes32(0)
    ///         means "ambiguous / unresolvable" (e.g. UMA 50/50 outcome) and
    ///         instructs the contest to cancel and refund rather than pick
    ///         a winner.
    function resolve(bytes32 contestId) external view returns (bool ready, bytes32 winningOption);

    /// @notice Maximum time a contest should wait for this resolver before
    ///         cancelling and refunding. 24h for price-feed resolvers,
    ///         7 days for Polymarket/UMA-backed resolvers (accounts for
    ///         the 2h–6d dispute window).
    function settlementTimeout() external pure returns (uint64);

    /// @notice Stable identifier for off-chain tooling and indexer filters.
    ///         Typical value: keccak256("ChainlinkFeedResolver.v1").
    function resolverType() external pure returns (bytes32);
}
