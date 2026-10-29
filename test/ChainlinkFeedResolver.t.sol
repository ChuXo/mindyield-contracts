// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/resolvers/ChainlinkFeedResolver.sol";
import "../src/interfaces/IResolver.sol";

/// @dev Minimal mock of an IAggregatorV3 feed. Tests drive answer/updatedAt
///      directly to exercise stale-data handling without wall-clock waits.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public immutable override decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    bool private _reverts;

    constructor(uint8 _dec) {
        decimals = _dec;
    }

    function setAnswer(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function setReverts(bool v) external {
        _reverts = v;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(!_reverts, "feed reverts");
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

contract ChainlinkFeedResolverTest is Test {
    ChainlinkFeedResolver public resolver;
    MockAggregatorV3 public feed;

    address constant FACTORY = address(0xF4C70); // ≈ "factory"
    bytes32 constant CID_1 = keccak256("contest-1");
    bytes32 constant YES = keccak256("YES");
    bytes32 constant NO = keccak256("NO");

    uint64 constant CUTOFF = 1_800_000_000; // some future unix timestamp
    uint32 constant STALE_AFTER = 1 hours;
    int256 constant THRESHOLD = 100_000 * 1e8; // e.g. $100k ETH with 8-dec feed

    function setUp() public {
        vm.warp(CUTOFF - 1 days);
        resolver = new ChainlinkFeedResolver(FACTORY);
        feed = new MockAggregatorV3(8);
    }

    // ─── register() ─────────────────────────────────────────────────────────

    function _defaultParams() internal view returns (bytes memory) {
        return abi.encode(address(feed), THRESHOLD, CUTOFF, STALE_AFTER, YES, NO);
    }

    function test_register_succeeds() public {
        vm.prank(FACTORY);
        resolver.register(CID_1, _defaultParams());

        (
            IAggregatorV3 storedFeed,
            uint64 cutoff,
            uint32 staleAfter,
            bytes32 yesOption,
            bytes32 noOption,
            int256 threshold
        ) = resolver.configs(CID_1);

        assertEq(address(storedFeed), address(feed));
        assertEq(cutoff, CUTOFF);
        assertEq(staleAfter, STALE_AFTER);
        assertEq(yesOption, YES);
        assertEq(noOption, NO);
        assertEq(threshold, THRESHOLD);
    }

    function test_register_revertsWhenNotFactory() public {
        vm.expectRevert(ChainlinkFeedResolver.NotAuthorized.selector);
        resolver.register(CID_1, _defaultParams());
    }

    function test_register_revertsOnDuplicate() public {
        vm.startPrank(FACTORY);
        resolver.register(CID_1, _defaultParams());
        vm.expectRevert(ChainlinkFeedResolver.AlreadyRegistered.selector);
        resolver.register(CID_1, _defaultParams());
        vm.stopPrank();
    }

    function test_register_revertsOnZeroFeed() public {
        bytes memory params = abi.encode(
            address(0), THRESHOLD, CUTOFF, STALE_AFTER, YES, NO
        );
        vm.prank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, params);
    }

    function test_register_revertsOnPastCutoff() public {
        bytes memory params = abi.encode(
            address(feed), THRESHOLD, uint64(block.timestamp - 1), STALE_AFTER, YES, NO
        );
        vm.prank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, params);
    }

    function test_register_revertsOnZeroStaleAfter() public {
        bytes memory params = abi.encode(
            address(feed), THRESHOLD, CUTOFF, uint32(0), YES, NO
        );
        vm.prank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, params);
    }

    function test_register_revertsOnStaleAfterAboveCap() public {
        bytes memory params = abi.encode(
            address(feed), THRESHOLD, CUTOFF, uint32(6 hours + 1), YES, NO
        );
        vm.prank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, params);
    }

    function test_register_revertsOnZeroOption() public {
        bytes memory p1 = abi.encode(address(feed), THRESHOLD, CUTOFF, STALE_AFTER, bytes32(0), NO);
        bytes memory p2 = abi.encode(address(feed), THRESHOLD, CUTOFF, STALE_AFTER, YES, bytes32(0));
        vm.startPrank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, p1);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, p2);
        vm.stopPrank();
    }

    function test_register_revertsOnSameYesNo() public {
        bytes memory params = abi.encode(address(feed), THRESHOLD, CUTOFF, STALE_AFTER, YES, YES);
        vm.prank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, params);
    }

    // ─── resolve() ──────────────────────────────────────────────────────────

    function _register() internal {
        vm.prank(FACTORY);
        resolver.register(CID_1, _defaultParams());
    }

    function test_resolve_returnsNotReadyBeforeCutoff() public {
        _register();
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertFalse(ready);
        assertEq(winner, bytes32(0));
    }

    function test_resolve_yesWhenAtOrAboveThreshold() public {
        _register();
        vm.warp(CUTOFF);
        feed.setAnswer(THRESHOLD, CUTOFF);
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES, "== threshold should be YES (>=)");
    }

    function test_resolve_yesWhenAbove() public {
        _register();
        vm.warp(CUTOFF);
        feed.setAnswer(THRESHOLD + 1, CUTOFF);
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES);
    }

    function test_resolve_noWhenBelow() public {
        _register();
        vm.warp(CUTOFF);
        feed.setAnswer(THRESHOLD - 1, CUTOFF);
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, NO);
    }

    function test_resolve_notReadyOnStaleAnswer() public {
        _register();
        // Feed last updated 2h before cutoff; staleAfter is 1h.
        // Audit M-02: stale data must surface as not-ready (not revert) so the
        // caller waits / retries instead of cancelling the contest.
        uint256 staleTs = CUTOFF - 2 hours;
        feed.setAnswer(THRESHOLD + 1, staleTs);
        vm.warp(CUTOFF);
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertFalse(ready);
        assertEq(winner, bytes32(0));
    }

    function test_resolve_notReadyOnZeroUpdatedAt() public {
        _register();
        // updatedAt == 0 means the round was never written.
        feed.setAnswer(THRESHOLD + 1, 0);
        vm.warp(CUTOFF);
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertFalse(ready);
        assertEq(winner, bytes32(0));
    }

    function test_resolve_revertsWhenUnregistered() public {
        vm.expectRevert(ChainlinkFeedResolver.NotRegistered.selector);
        resolver.resolve(keccak256("never-registered"));
    }

    function test_resolve_negativeAnswerIsBelow() public {
        _register();
        vm.warp(CUTOFF);
        feed.setAnswer(-1, CUTOFF);
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, NO);
    }

    // ─── requestSettlement() — sync resolver is no-op ──────────────────────

    function test_requestSettlement_isNoOpReturningFalse() public {
        _register();
        bool triggered = resolver.requestSettlement(CID_1);
        assertFalse(triggered);
    }

    // ─── Metadata ───────────────────────────────────────────────────────────

    function test_settlementTimeout_is24h() public view {
        assertEq(resolver.settlementTimeout(), 24 hours);
    }

    function test_resolverType_isStableKeccak() public view {
        assertEq(resolver.resolverType(), keccak256("ChainlinkFeedResolver.v1"));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────────

    function testFuzz_resolveThresholdDecision(int128 answerFuzz) public {
        _register();
        vm.warp(CUTOFF);
        int256 answer = int256(answerFuzz);
        feed.setAnswer(answer, CUTOFF);

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        if (answer >= THRESHOLD) {
            assertEq(winner, YES);
        } else {
            assertEq(winner, NO);
        }
    }

    function testFuzz_registerRejectsOutOfBoundsStale(uint32 staleAfterFuzz) public {
        vm.assume(staleAfterFuzz == 0 || staleAfterFuzz > 6 hours);
        bytes memory params = abi.encode(
            address(feed), THRESHOLD, CUTOFF, staleAfterFuzz, YES, NO
        );
        vm.prank(FACTORY);
        vm.expectRevert(ChainlinkFeedResolver.InvalidParams.selector);
        resolver.register(CID_1, params);
    }
}
