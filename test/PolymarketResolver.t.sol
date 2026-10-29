// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/resolvers/PolymarketResolver.sol";

contract PolymarketResolverTest is Test {
    PolymarketResolver public resolver;

    address constant FACTORY = address(0xF4C70);
    address constant ROUTER  = address(0xC0DE); // mock "router"

    bytes32 constant CID_1 = keccak256("contest-1");
    bytes32 constant POLY_COND = keccak256("poly-condition-id");
    bytes32 constant YES = keccak256("YES");
    bytes32 constant NO  = keccak256("NO");

    function setUp() public {
        resolver = new PolymarketResolver(FACTORY, ROUTER);
    }

    // ─── register() ─────────────────────────────────────────────────────────

    function _params() internal pure returns (bytes memory) {
        return abi.encode(POLY_COND, YES, NO);
    }

    function test_register_succeeds() public {
        vm.prank(FACTORY);
        resolver.register(CID_1, _params());

        (
            bytes32 conditionId,
            bytes32 yesOption,
            bytes32 noOption,
            bool registered,
            bool settled,
            bool ambiguous,
            bytes32 winner,
            bytes32 lastRequestId
        ) = resolver.configs(CID_1);

        assertEq(conditionId, POLY_COND);
        assertEq(yesOption, YES);
        assertEq(noOption, NO);
        assertTrue(registered);
        assertFalse(settled);
        assertFalse(ambiguous);
        assertEq(winner, bytes32(0));
        assertEq(lastRequestId, bytes32(0));
    }

    function test_register_revertsWhenNotFactory() public {
        vm.expectRevert(PolymarketResolver.NotAuthorized.selector);
        resolver.register(CID_1, _params());
    }

    function test_register_revertsOnDuplicate() public {
        vm.startPrank(FACTORY);
        resolver.register(CID_1, _params());
        vm.expectRevert(PolymarketResolver.AlreadyRegistered.selector);
        resolver.register(CID_1, _params());
        vm.stopPrank();
    }

    function test_register_revertsOnZeroConditionId() public {
        bytes memory bad = abi.encode(bytes32(0), YES, NO);
        vm.prank(FACTORY);
        vm.expectRevert(PolymarketResolver.InvalidParams.selector);
        resolver.register(CID_1, bad);
    }

    function test_register_revertsOnSameYesNo() public {
        bytes memory bad = abi.encode(POLY_COND, YES, YES);
        vm.prank(FACTORY);
        vm.expectRevert(PolymarketResolver.InvalidParams.selector);
        resolver.register(CID_1, bad);
    }

    function test_register_revertsOnZeroOption() public {
        bytes memory bad1 = abi.encode(POLY_COND, bytes32(0), NO);
        bytes memory bad2 = abi.encode(POLY_COND, YES, bytes32(0));
        vm.startPrank(FACTORY);
        vm.expectRevert(PolymarketResolver.InvalidParams.selector);
        resolver.register(CID_1, bad1);
        vm.expectRevert(PolymarketResolver.InvalidParams.selector);
        resolver.register(CID_1, bad2);
        vm.stopPrank();
    }

    // ─── requestSettlement() ────────────────────────────────────────────────

    function _register() internal {
        vm.prank(FACTORY);
        resolver.register(CID_1, _params());
    }

    function test_requestSettlement_emitsAndReturnsTrue() public {
        _register();
        vm.recordLogs();
        bool triggered = resolver.requestSettlement(CID_1);
        assertTrue(triggered);

        (, , , , , , , bytes32 lastReqId) = resolver.configs(CID_1);
        assertTrue(lastReqId != bytes32(0));
        assertEq(resolver.requestToContest(lastReqId), CID_1);
    }

    function test_requestSettlement_returnsFalseAfterSettled() public {
        _register();
        resolver.requestSettlement(CID_1);
        (, , , , , , , bytes32 reqId) = resolver.configs(CID_1);

        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, abi.encode(uint256(0)), ""); // YES_WIN

        bool triggered = resolver.requestSettlement(CID_1);
        assertFalse(triggered);
    }

    function test_requestSettlement_revertsWhenUnregistered() public {
        vm.expectRevert(PolymarketResolver.NotRegistered.selector);
        resolver.requestSettlement(keccak256("unknown"));
    }

    function test_requestSettlement_canBeRetried() public {
        _register();
        resolver.requestSettlement(CID_1);
        (, , , , , , , bytes32 firstReq) = resolver.configs(CID_1);

        // Retry → new requestId; old one is orphaned (still in mapping
        // but harmless; test for the new one).
        resolver.requestSettlement(CID_1);
        (, , , , , , , bytes32 secondReq) = resolver.configs(CID_1);

        assertTrue(firstReq != secondReq, "retry should issue a new requestId");
        assertEq(resolver.requestToContest(secondReq), CID_1);
    }

    // ─── fulfillRequest() ───────────────────────────────────────────────────

    function _requestAndGetId() internal returns (bytes32) {
        _register();
        resolver.requestSettlement(CID_1);
        ( , , , , , , , bytes32 reqId) = resolver.configs(CID_1);
        return reqId;
    }

    function test_fulfill_yesWin() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, abi.encode(uint256(0)), "");

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES);
    }

    function test_fulfill_noWin() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, abi.encode(uint256(1)), "");

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, NO);
    }

    function test_fulfill_ambiguousReturnsZeroSentinel() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, abi.encode(uint256(2)), "");

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready, "ambiguous IS settled");
        assertEq(winner, bytes32(0), "ambiguous returns sentinel for cancel-and-refund");
    }

    function test_fulfill_notReadyLeavesUnsettled() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, abi.encode(uint256(3)), ""); // NOT_READY

        (bool ready, ) = resolver.resolve(CID_1);
        assertFalse(ready, "not-ready must NOT settle the resolver");
    }

    function test_fulfill_errorBytesLeavesUnsettled() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, "", "rpc fail");

        (bool ready, ) = resolver.resolve(CID_1);
        assertFalse(ready, "DON error must leave resolver unsettled (caller retries)");
    }

    function test_fulfill_revertsWhenNotRouter() public {
        bytes32 reqId = _requestAndGetId();
        vm.expectRevert(PolymarketResolver.NotRouter.selector);
        resolver.fulfillRequest(reqId, abi.encode(uint256(0)), "");
    }

    function test_fulfill_revertsOnUnknownRequest() public {
        _register();
        vm.prank(ROUTER);
        vm.expectRevert(PolymarketResolver.UnknownRequest.selector);
        resolver.fulfillRequest(keccak256("never-issued"), abi.encode(uint256(0)), "");
    }

    function test_fulfill_revertsOnDoubleFulfill() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        resolver.fulfillRequest(reqId, abi.encode(uint256(0)), "");

        vm.prank(ROUTER);
        vm.expectRevert(PolymarketResolver.UnknownRequest.selector);
        // requestToContest cleared after first fulfill → second sees zero
        resolver.fulfillRequest(reqId, abi.encode(uint256(1)), "");
    }

    function test_fulfill_malformedShortResponseLeavesUnsettled() public {
        bytes32 reqId = _requestAndGetId();
        vm.prank(ROUTER);
        // Less than 32 bytes — malformed.
        resolver.fulfillRequest(reqId, hex"01", "");

        (bool ready, ) = resolver.resolve(CID_1);
        assertFalse(ready);
    }

    // ─── resolve() ──────────────────────────────────────────────────────────

    function test_resolve_revertsWhenUnregistered() public {
        vm.expectRevert(PolymarketResolver.NotRegistered.selector);
        resolver.resolve(keccak256("nope"));
    }

    function test_resolve_returnsNotReadyBeforeFulfillment() public {
        _register();
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertFalse(ready);
        assertEq(winner, bytes32(0));
    }

    // ─── Metadata ───────────────────────────────────────────────────────────

    function test_settlementTimeout_is7Days() public view {
        assertEq(resolver.settlementTimeout(), 7 days);
    }

    function test_resolverType_isStableKeccak() public view {
        assertEq(resolver.resolverType(), keccak256("PolymarketResolver.v1"));
    }

    function test_jsSourceIsNonEmpty() public view {
        assertGt(bytes(resolver.JS_SOURCE()).length, 100);
    }
}
