// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

contract PolymarketRelayResolverTest is Test {
    PolymarketRelayResolver public resolver;
    MockERC20 public usdc;

    address constant FACTORY  = address(0xF4C70);
    address constant TREASURY = address(0x7E4);
    address constant RELAYER  = address(0xBEEF);
    address constant ALICE    = address(0xA11CE);
    address constant BOB      = address(0xB0B);
    address constant ADMIN    = address(0xAD);

    bytes32 constant CID_1 = keccak256("contest-1");
    bytes32 constant POLY_COND = keccak256("poly-condition-id");
    bytes32 constant YES = keccak256("YES");
    bytes32 constant NO  = keccak256("NO");

    uint64 polymarketEnd;

    function setUp() public {
        vm.warp(1_800_000_000);
        polymarketEnd = uint64(block.timestamp + 7 days);

        usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(ADMIN);
        resolver = new PolymarketRelayResolver(FACTORY, address(usdc));

        // Mint USDC to challenger and treasury.
        usdc.mint(BOB,   100_000e6);
        usdc.mint(ALICE, 100_000e6);
    }

    function _params() internal view returns (bytes memory) {
        return abi.encode(POLY_COND, YES, NO, polymarketEnd);
    }

    function _register() internal {
        vm.prank(FACTORY);
        resolver.register(CID_1, _params());
    }

    function _approve(address user, uint256 amount) internal {
        vm.prank(user);
        usdc.approve(address(resolver), amount);
    }

    // ─── register() ─────────────────────────────────────────────────────────

    function test_register_succeeds() public {
        _register();

        (
            bytes32 conditionId,
            bytes32 yesOpt,
            bytes32 noOpt,
            uint64 endDate,
            PolymarketRelayResolver.Status status,
            , // proposedOutcome
            , // proposedAt
            , // proposer
            , // challengerOutcome
            , // challenger
            , // challengerBond
              // finalOutcome
        ) = resolver.configs(CID_1);

        assertEq(conditionId, POLY_COND);
        assertEq(yesOpt, YES);
        assertEq(noOpt, NO);
        assertEq(endDate, polymarketEnd);
        assertEq(uint8(status), uint8(PolymarketRelayResolver.Status.REGISTERED));
    }

    function test_register_revertsWhenNotFactory() public {
        vm.expectRevert(PolymarketRelayResolver.NotAuthorizedFactory.selector);
        resolver.register(CID_1, _params());
    }

    function test_register_revertsOnDuplicate() public {
        _register();
        vm.prank(FACTORY);
        vm.expectRevert(PolymarketRelayResolver.AlreadyRegistered.selector);
        resolver.register(CID_1, _params());
    }

    function test_register_revertsOnPastEndDate() public {
        bytes memory bad = abi.encode(POLY_COND, YES, NO, uint64(block.timestamp - 1));
        vm.prank(FACTORY);
        vm.expectRevert(PolymarketRelayResolver.InvalidParams.selector);
        resolver.register(CID_1, bad);
    }

    // ─── propose() — grace window ──────────────────────────────────────────

    function test_propose_revertsBeforeGraceWindow() public {
        _register();
        // Warp to just before polymarketEnd + GRACE
        vm.warp(uint256(polymarketEnd) + uint256(resolver.GRACE_WINDOW()) - 1);
        vm.prank(RELAYER);
        vm.expectRevert(PolymarketRelayResolver.GraceWindowNotElapsed.selector);
        resolver.propose(CID_1, PolymarketRelayResolver.Outcome.YES_WIN);
    }

    function test_propose_succeedsAfterGraceWindow() public {
        _register();
        vm.warp(uint256(polymarketEnd) + uint256(resolver.GRACE_WINDOW()));
        vm.prank(RELAYER);
        resolver.propose(CID_1, PolymarketRelayResolver.Outcome.YES_WIN);

        (, , , , PolymarketRelayResolver.Status status,
         PolymarketRelayResolver.Outcome proposedOutcome,
         uint64 proposedAt, address proposer, , , , ) = resolver.configs(CID_1);

        assertEq(uint8(status), uint8(PolymarketRelayResolver.Status.PROPOSED));
        assertEq(uint8(proposedOutcome), uint8(PolymarketRelayResolver.Outcome.YES_WIN));
        assertEq(proposer, RELAYER);
        assertEq(proposedAt, uint64(block.timestamp));
    }

    function test_propose_revertsOnUnsupportedOutcome() public {
        _register();
        vm.warp(uint256(polymarketEnd) + uint256(resolver.GRACE_WINDOW()));
        vm.prank(RELAYER);
        vm.expectRevert(PolymarketRelayResolver.UnsupportedOutcome.selector);
        resolver.propose(CID_1, PolymarketRelayResolver.Outcome.CANCELLED);
    }

    function test_propose_revertsWhenNotRegistered() public {
        vm.warp(uint256(polymarketEnd) + uint256(resolver.GRACE_WINDOW()));
        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolymarketRelayResolver.NotInState.selector,
                PolymarketRelayResolver.Status.REGISTERED
            )
        );
        resolver.propose(CID_1, PolymarketRelayResolver.Outcome.YES_WIN);
    }

    // ─── resolve() — auto-finalize after challenge window ──────────────────

    function _registerAndPropose(PolymarketRelayResolver.Outcome outcome) internal {
        _register();
        vm.warp(uint256(polymarketEnd) + uint256(resolver.GRACE_WINDOW()));
        vm.prank(RELAYER);
        resolver.propose(CID_1, outcome);
    }

    function test_resolve_returnsNotReadyDuringDisputeWindow() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        // Still inside DISPUTE_WINDOW
        (bool ready, ) = resolver.resolve(CID_1);
        assertFalse(ready);
    }

    function test_resolve_yesWinAutoFinalizesAfterWindow() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES);
    }

    function test_resolve_noWinAutoFinalizesAfterWindow() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.NO_WIN);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, NO);
    }

    function test_resolve_ambiguousAutoFinalizesAsZero() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.AMBIGUOUS);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, bytes32(0), "ambiguous returns sentinel for cancel-and-refund");
    }

    function test_resolve_revertsWhenUnregistered() public {
        vm.expectRevert(PolymarketRelayResolver.NotRegistered.selector);
        resolver.resolve(keccak256("never"));
    }

    // ─── challenge() ─────────────────────────────────────────────────────

    function test_challenge_succeeds() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);

        uint96 expectedBond = resolver.requiredBondFor(CID_1);
        assertEq(expectedBond, resolver.MIN_BOND());

        _approve(BOB, expectedBond);
        vm.prank(BOB);
        resolver.challenge(CID_1, PolymarketRelayResolver.Outcome.NO_WIN);

        (, , , , PolymarketRelayResolver.Status status, , , ,
         PolymarketRelayResolver.Outcome challengerOutcome,
         address challenger,
         uint96 challengerBond, ) = resolver.configs(CID_1);

        assertEq(uint8(status), uint8(PolymarketRelayResolver.Status.DISPUTED));
        assertEq(uint8(challengerOutcome), uint8(PolymarketRelayResolver.Outcome.NO_WIN));
        assertEq(challenger, BOB);
        assertEq(challengerBond, expectedBond);
        assertEq(usdc.balanceOf(address(resolver)), expectedBond);
    }

    /// @notice After audit fix P-MIRROR-02 the bond is set by admin
    ///         override (not caller-supplied) so it scales with TVL only
    ///         when the admin configures it.
    function test_challenge_bondOverrideAppliesAtChallengeTime() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);

        // Admin sets a 1000 USDC bond override for this contest.
        vm.prank(ADMIN);
        resolver.setBondOverride(CID_1, 1000e6);

        uint96 bond = resolver.requiredBondFor(CID_1);
        assertEq(bond, 1000e6);

        _approve(BOB, bond);
        vm.prank(BOB);
        resolver.challenge(CID_1, PolymarketRelayResolver.Outcome.NO_WIN);

        assertEq(usdc.balanceOf(address(resolver)), bond);
    }

    function test_challenge_revertsAfterWindow() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        _approve(BOB, 25e6);
        vm.prank(BOB);
        vm.expectRevert(PolymarketRelayResolver.ChallengeWindowExpired.selector);
        resolver.challenge(CID_1, PolymarketRelayResolver.Outcome.NO_WIN);
    }

    function test_challenge_revertsOnSameOutcomeAsProposal() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        _approve(BOB, 25e6);
        vm.prank(BOB);
        vm.expectRevert(PolymarketRelayResolver.UnsupportedOutcome.selector);
        resolver.challenge(CID_1, PolymarketRelayResolver.Outcome.YES_WIN);
    }

    function test_challenge_revertsBeforeProposal() public {
        _register();
        _approve(BOB, 25e6);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolymarketRelayResolver.NotInState.selector,
                PolymarketRelayResolver.Status.PROPOSED
            )
        );
        resolver.challenge(CID_1, PolymarketRelayResolver.Outcome.NO_WIN);
    }

    function test_challenge_revertsWithoutAllowance() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        // No approve() call — transferFrom should fail
        vm.prank(BOB);
        vm.expectRevert();
        resolver.challenge(CID_1, PolymarketRelayResolver.Outcome.NO_WIN);
    }

    /// @notice Audit-fix regression test (P-MIRROR-01): once the dispute
    ///         window has elapsed without a challenge, forceTimeoutCancel
    ///         must NOT overwrite the lazy-finalized winner with CANCELLED.
    ///         Instead it persists the proposed outcome to storage.
    function test_forceTimeout_persistsLazyFinalizedOutcome() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);

        // Walk past dispute window — outcome is lazy-finalized.
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()) + 1);

        // resolve() lazy-finalizes
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES);

        // Even after the 7-day hard timeout fires, forceTimeoutCancel
        // must finalize to YES_WIN, not CANCELLED.
        vm.warp(uint256(polymarketEnd) + uint256(resolver.SETTLEMENT_TIMEOUT_VAL()) + 1);
        resolver.forceTimeoutCancel(CID_1);

        (ready, winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES, "lazy-finalized YES_WIN must be persisted, not overwritten");
    }

    // ─── finalizeAfterDispute (admin) ────────────────────────────────────

    function _disputeWith(PolymarketRelayResolver.Outcome alt) internal returns (uint96 bond) {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        bond = resolver.requiredBondFor(CID_1);
        _approve(BOB, bond);
        vm.prank(BOB);
        resolver.challenge(CID_1, alt);
    }

    function test_finalize_honestChallengerGetsBondBack() public {
        uint96 bond = _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);

        uint256 bobBefore = usdc.balanceOf(BOB);

        // Admin agrees with challenger.
        vm.prank(ADMIN);
        resolver.finalizeAfterDispute(
            CID_1,
            PolymarketRelayResolver.Outcome.NO_WIN,
            true,
            TREASURY
        );

        assertEq(usdc.balanceOf(BOB), bobBefore + bond);
        assertEq(usdc.balanceOf(TREASURY), 0);

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, NO);
    }

    function test_finalize_dishonestChallengerLosesBond() public {
        uint96 bond = _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);

        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        // Admin sides with the original proposal (challenger wrong).
        vm.prank(ADMIN);
        resolver.finalizeAfterDispute(
            CID_1,
            PolymarketRelayResolver.Outcome.YES_WIN,
            false,
            TREASURY
        );

        assertEq(usdc.balanceOf(TREASURY), treasuryBefore + bond);

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, YES);
    }

    function test_finalize_revertsWhenNotOwner() public {
        _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);
        vm.prank(BOB);
        vm.expectRevert(); // Ownable
        resolver.finalizeAfterDispute(
            CID_1, PolymarketRelayResolver.Outcome.YES_WIN, false, TREASURY
        );
    }

    function test_finalize_revertsOnHonestClaimWithMismatchedOutcome() public {
        _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);
        // Admin claims challenger was honest but provides wrong outcome (YES).
        vm.prank(ADMIN);
        vm.expectRevert(PolymarketRelayResolver.InvalidParams.selector);
        resolver.finalizeAfterDispute(
            CID_1, PolymarketRelayResolver.Outcome.YES_WIN, true, TREASURY
        );
    }

    function test_finalize_canFinalizeAsCancelled() public {
        _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);
        vm.prank(ADMIN);
        resolver.finalizeAfterDispute(
            CID_1, PolymarketRelayResolver.Outcome.CANCELLED, false, TREASURY
        );
        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, bytes32(0), "CANCELLED also returns sentinel for refund");
    }

    function test_finalize_revertsOnSlashWithoutTreasury() public {
        _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);
        vm.prank(ADMIN);
        vm.expectRevert(PolymarketRelayResolver.InvalidParams.selector);
        resolver.finalizeAfterDispute(
            CID_1, PolymarketRelayResolver.Outcome.YES_WIN, false, address(0)
        );
    }

    // ─── forceTimeoutCancel ─────────────────────────────────────────────

    function test_forceTimeout_cancelsAfterSettlementTimeout() public {
        _register(); // never proposed
        vm.warp(uint256(polymarketEnd) + uint256(resolver.SETTLEMENT_TIMEOUT_VAL()));

        resolver.forceTimeoutCancel(CID_1);

        (bool ready, bytes32 winner) = resolver.resolve(CID_1);
        assertTrue(ready);
        assertEq(winner, bytes32(0), "timed-out contests cancel");
    }

    function test_forceTimeout_revertsBeforeTimeout() public {
        _register();
        vm.warp(uint256(polymarketEnd) + uint256(resolver.SETTLEMENT_TIMEOUT_VAL()) - 1);
        vm.expectRevert(PolymarketRelayResolver.TimeoutNotReached.selector);
        resolver.forceTimeoutCancel(CID_1);
    }

    function test_forceTimeout_refundsChallengerBond() public {
        uint96 bond = _disputeWith(PolymarketRelayResolver.Outcome.NO_WIN);
        // Admin never resolves; warp past timeout.
        vm.warp(uint256(polymarketEnd) + uint256(resolver.SETTLEMENT_TIMEOUT_VAL()));

        uint256 bobBefore = usdc.balanceOf(BOB);
        resolver.forceTimeoutCancel(CID_1);
        assertEq(usdc.balanceOf(BOB), bobBefore + bond, "bond refunded on timeout");
    }

    function test_forceTimeout_revertsWhenAlreadyFinalized() public {
        _registerAndPropose(PolymarketRelayResolver.Outcome.YES_WIN);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        // resolve() lazy-finalizes. Force a real finalization via admin path.
        // Simpler: move further into time and try forceTimeoutCancel.
        vm.warp(uint256(polymarketEnd) + uint256(resolver.SETTLEMENT_TIMEOUT_VAL()));

        // Status is still PROPOSED (no admin call). resolve() returns final
        // via lazy logic but status field says PROPOSED. forceTimeoutCancel
        // will succeed since status != FINALIZED. Then a second call should
        // revert AlreadySettled.
        resolver.forceTimeoutCancel(CID_1);
        vm.expectRevert(PolymarketRelayResolver.AlreadySettled.selector);
        resolver.forceTimeoutCancel(CID_1);
    }

    // ─── Bond override ──────────────────────────────────────────────────

    function test_bondOverride_appliesWhenSet() public {
        _register();
        vm.prank(ADMIN);
        resolver.setBondOverride(CID_1, 500e6); // 500 USDC fixed bond
        assertEq(resolver.requiredBondFor(CID_1), 500e6);
    }

    function test_bondOverride_revertsWhenNotOwner() public {
        vm.prank(BOB);
        vm.expectRevert(); // Ownable
        resolver.setBondOverride(CID_1, 500e6);
    }

    function test_bondOverride_revertsAboveMaxBondOverride() public {
        _register();
        uint96 tooHigh = resolver.MAX_BOND_OVERRIDE() + 1;
        vm.prank(ADMIN);
        vm.expectRevert(PolymarketRelayResolver.BondOverrideTooHigh.selector);
        resolver.setBondOverride(CID_1, tooHigh);
    }

    function test_bondOverride_acceptsExactlyMaxBondOverride() public {
        _register();
        uint96 maxBond = resolver.MAX_BOND_OVERRIDE();
        vm.prank(ADMIN);
        resolver.setBondOverride(CID_1, maxBond);
        assertEq(resolver.requiredBondFor(CID_1), maxBond);
    }

    function test_bondOverride_zeroClearsToMinBond() public {
        _register();
        vm.startPrank(ADMIN);
        resolver.setBondOverride(CID_1, 500e6);
        assertEq(resolver.requiredBondFor(CID_1), 500e6);
        resolver.setBondOverride(CID_1, 0);
        assertEq(resolver.requiredBondFor(CID_1), resolver.MIN_BOND());
        vm.stopPrank();
    }

    // ─── Factory authorization (owner-rotatable) ───────────────────────

    function test_constructorSeedsIsAuthorizedFactory() public view {
        assertTrue(resolver.isAuthorizedFactory(FACTORY));
        assertEq(resolver.authorizedFactory(), FACTORY);
    }

    function test_setAuthorizedFactory_ownerCanAddNewFactory() public {
        address newFactory = address(0xF001);
        assertFalse(resolver.isAuthorizedFactory(newFactory));

        vm.prank(ADMIN);
        resolver.setAuthorizedFactory(newFactory, true);

        assertTrue(resolver.isAuthorizedFactory(newFactory));
        assertEq(resolver.authorizedFactory(), newFactory, "legacy getter tracks last-added");

        // Old factory still works — both can coexist during rotation.
        assertTrue(resolver.isAuthorizedFactory(FACTORY));
    }

    function test_setAuthorizedFactory_ownerCanRevoke() public {
        vm.prank(ADMIN);
        resolver.setAuthorizedFactory(FACTORY, false);

        assertFalse(resolver.isAuthorizedFactory(FACTORY));
        // Old FACTORY should no longer be able to register.
        vm.prank(FACTORY);
        vm.expectRevert(PolymarketRelayResolver.NotAuthorizedFactory.selector);
        resolver.register(keccak256("post-revoke"), _params());
    }

    function test_setAuthorizedFactory_newlyAuthorizedFactoryCanRegister() public {
        address newFactory = address(0xF001);
        vm.prank(ADMIN);
        resolver.setAuthorizedFactory(newFactory, true);

        // Brand-new contest id, called from the new factory — should succeed.
        bytes32 cid = keccak256("contest-from-new-factory");
        vm.prank(newFactory);
        resolver.register(cid, _params());

        (bytes32 conditionId, , , , PolymarketRelayResolver.Status status, , , , , , , ) =
            resolver.configs(cid);
        assertEq(conditionId, POLY_COND);
        assertEq(uint8(status), uint8(PolymarketRelayResolver.Status.REGISTERED));
    }

    function test_setAuthorizedFactory_revertsOnZeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(PolymarketRelayResolver.InvalidParams.selector);
        resolver.setAuthorizedFactory(address(0), true);
    }

    function test_setAuthorizedFactory_revertsWhenNotOwner() public {
        vm.prank(BOB);
        vm.expectRevert(); // Ownable
        resolver.setAuthorizedFactory(address(0xF001), true);
    }

    // ─── IResolver metadata ─────────────────────────────────────────────

    function test_settlementTimeout_is7Days() public view {
        assertEq(resolver.settlementTimeout(), 7 days);
    }

    function test_resolverType_isStableKeccak() public view {
        assertEq(resolver.resolverType(), keccak256("PolymarketRelayResolver.v1"));
    }

    function test_requestSettlement_isNoOp() public view {
        assertFalse(resolver.requestSettlement(CID_1));
    }
}
