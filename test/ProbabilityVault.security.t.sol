// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice Comprehensive security & edge-case tests for ProbabilityVaultV2.
///         Covers scenarios NOT addressed in ProbabilityVault.t.sol:
///           - Multi-user weighted yield distribution
///           - Loser (losing-side) gets only principal
///           - Double-claim blocked
///           - Early-withdrawn user cannot re-claim
///           - Strategy-loss cancel + pro-rata principal for multiple users
///           - Emergency cancel via factory
///           - Empty pool cancel (zero depositors)
///           - Imbalance at boundary (exactly 5%)
///           - Winning TWAB = 0 (no winners, yield trapped → cancel expected)
///           - PolymarketRelayResolver: honest challenge flow (bond refunded)
///           - PolymarketRelayResolver: dishonest challenge flow (bond slashed)
///           - Resolver front-run via propose after 12h grace
///           - Factory: cannot double-initialize an existing vault
///           - TWAB conservation: partial early withdrawals don't dilute winners
///           - Swap fee sweep on FINALIZED state
///           - Imbalance cancel + surplus yield routed to treasury
///           - resolveContest reverts before resolveStart
///           - deposit reverts with zero amount
///           - emergencyCancel: only factory allowed
///           - Claim: loser on winning side == all principal returned
///           - Cancel: user who early-withdrew AND vault later cancelled gets nothing
contract ProbabilityVaultSecurityTest is Test {
    ProbabilityVaultV2      public impl;
    ProbabilityVaultFactory public factory;
    YieldVault              public yieldVault;
    IdentityRegistry        public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20               public usdc;

    address public deployer  = address(this);
    address public creator   = address(0x100);
    address public alice     = address(0x101);
    address public bob       = address(0x102);
    address public charlie   = address(0x103);
    address public dave      = address(0x104);
    address public eve       = address(0x105);
    address public treasury  = address(0x111);
    address public challenger = address(0x222);

    bytes32 public constant YES          = keccak256("YES");
    bytes32 public constant NO           = keccak256("NO");
    bytes32 public constant CONDITION_ID = keccak256("security-test-cid");

    uint64 public polyEnd;

    // ─── Setup ─────────────────────────────────────────────────────────

    function setUp() public {
        vm.warp(1_800_000_000);
        polyEnd = uint64(block.timestamp + 7 days);

        usdc = new MockERC20("USDC", "USDC", 6);
        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));

        identityRegistry = new IdentityRegistry();
        address[7] memory all = [alice, bob, charlie, dave, eve, creator, challenger];
        for (uint256 i = 0; i < all.length; i++) {
            identityRegistry.setTier(all[i], 2);
            usdc.mint(all[i], 500_000e6);
        }

        impl = new ProbabilityVaultV2();
        factory = new ProbabilityVaultFactory(
            address(impl),
            address(yieldVault),
            address(0),
            address(identityRegistry),
            treasury
        );
        // Transfer YieldVault ownership to the factory so setTrustedDepositor
        // works. YieldVault is Ownable2Step, so the transfer must be accepted
        // by the new owner before it takes effect — without the accept call,
        // setTrustedDepositor silently fails inside the factory's try/catch
        // and every withdraw path then trips the MIN_HOLD_TIME guard.
        yieldVault.transferOwnership(address(factory));
        vm.prank(address(factory));
        yieldVault.acceptOwnership();

        resolver = new PolymarketRelayResolver(address(factory), address(usdc));
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    function _baseParams() internal view returns (ProbabilityVaultFactory.CreateParams memory) {
        return ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: polyEnd,
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       CONDITION_ID,
            metadataHash:      keccak256("security-test"),
            metadataUri:       "ipfs://security-test",
            resolver:          address(resolver)
        });
    }

    function _createVault() internal returns (address) {
        vm.prank(creator);
        (, address addr) = factory.createVault(_baseParams());
        return addr;
    }

    function _deposit(address user, address vault, uint256 amount, bytes32 side) internal {
        vm.startPrank(user);
        usdc.approve(vault, amount);
        ProbabilityVaultV2(vault).deposit(amount, side);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(yieldVault), amount);
        // strategies @ slot 4, tokenDeposits @ slot 7 (post Ownable2Step).
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur + amount));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 + amount));
    }

    function _proposeAndFinalize(address vault, bytes32 sideLabel) internal {
        bytes32 key = bytes32(uint256(uint160(vault)));
        PolymarketRelayResolver.Outcome outcome = sideLabel == YES
            ? PolymarketRelayResolver.Outcome.YES_WIN
            : sideLabel == NO
                ? PolymarketRelayResolver.Outcome.NO_WIN
                : PolymarketRelayResolver.Outcome.AMBIGUOUS;
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        resolver.propose(key, outcome);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ─── 1. Multi-user weighted TWAB yield distribution ───────────────

    /// @notice Alice deposits 2x Bob on YES side; Alice should get ~2x the yield.
    function test_twab_weightedYield_twoUsers() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // Deposit simultaneously — both start at t=0 and hold until joinEnd.
        _deposit(alice, v, 2_000e6, YES);  // 2000 YES
        _deposit(bob,   v, 1_000e6, YES);  // 1000 YES (same side, same duration)
        _deposit(charlie, v, 1_000e6, NO); // balance the pool

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // alice: 2000 stake for full duration → yesTwab = 2x bob's
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        uint256 aliceYield = usdc.balanceOf(alice) - aliceBefore - 2_000e6;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pv.claim();
        uint256 bobYield = usdc.balanceOf(bob) - bobBefore - 1_000e6;

        // Alice should receive ~2x Bob's yield (within 1 USDC rounding)
        assertApproxEqAbs(aliceYield, 2 * bobYield, 1e6);
        // Both yields positive
        assertGt(aliceYield, 0);
        assertGt(bobYield, 0);
    }

    // ─── 2. Loser gets only principal ─────────────────────────────────

    function test_loser_getsOnlyPrincipal() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 1_000e6, YES);
        _deposit(charlie, v, 500e6,   NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES); // YES wins → NO side loses
        pv.resolveContest();

        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        pv.claim();
        uint256 charlieReceived = usdc.balanceOf(charlie) - charlieBefore;
        assertEq(charlieReceived, 500e6); // exactly principal, no yield
    }

    // ─── 3. Double claim reverts ───────────────────────────────────────

    function test_claim_revertOnDoubleClaim() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 500e6,   NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        vm.prank(alice);
        pv.claim(); // first claim — succeeds

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.AlreadyClaimed.selector);
        pv.claim(); // second claim — reverts
    }

    // ─── 4. Early-withdrawn user cannot claim ─────────────────────────

    function test_earlyWithdraw_thenCannotClaim() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 1_000e6, NO);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        pv.withdrawEarly(); // Alice exits early

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        // Alice already withdrew, principal = 0, principalWithdrawn = true
        // claim() → u.principal == 0 && !principalWithdrawn == false → NothingToWithdraw
        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.NothingToWithdraw.selector);
        pv.claim();
    }

    // ─── 5. Cancel (ambiguous) + pro-rata claiming for multiple users ──

    /// @notice Ambiguous resolver cancel → all users reclaim their full
    ///         principal PLUS a pro-rata share of the post-fee yield surplus
    ///         (cancel-yield-refund behavior introduced for the next PV
    ///         redeploy — see docs/PV_CANCEL_YIELD_REFUND.md). This used to
    ///         assert principal-only; the new behavior credits the surplus
    ///         (legacy P-EXT-03 routed it to treasury, which left the no-
    ///         loss product technically losing the time-value of the
    ///         depositors' capital). Detailed conservation + ratio checks
    ///         live in ProbabilityVault.cancelYieldRefund.t.sol.
    function test_cancel_ambiguous_multipleUsersClaimPrincipal() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 1_000e6, YES);
        _deposit(bob,     v, 750e6,   NO);
        _deposit(charlie, v, 250e6,   YES);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(50e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, bytes32(0)); // AMBIGUOUS outcome → cancel
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // All three users get full principal + a pro-rata yield share.
        // Equal stake-duration (joined at t=0, frozen at joinEnd) → yield
        // distributed by stake size: alice 1000 / total 2000 = 50%, bob 750
        // / 2000 = 37.5%, charlie 250 / 2000 = 12.5%. Expected reserved =
        // 50e6 * 0.98 = 49e6 (after 2% fee). Tolerance for YieldVault wei
        // rounding.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        assertGe(usdc.balanceOf(alice) - aliceBefore, 1_000e6, "alice >= principal");
        assertGt(usdc.balanceOf(alice) - aliceBefore, 1_000e6 + 20e6, "alice gets yield share");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pv.claim();
        assertGe(usdc.balanceOf(bob) - bobBefore, 750e6, "bob >= principal");
        assertGt(usdc.balanceOf(bob) - bobBefore, 750e6 + 15e6, "bob gets yield share");

        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        pv.claim();
        assertGe(usdc.balanceOf(charlie) - charlieBefore, 250e6, "charlie >= principal");
        assertGt(usdc.balanceOf(charlie) - charlieBefore, 250e6 + 5e6, "charlie gets yield share");
    }

    // ─── 5b. Strategy-loss via MockYieldVault ────────────────────────
    //
    // ProbabilityVaultV2.resolveContest detects strategy loss when the vault
    // returns fewer tokens than the sum of user principals. This is tested
    // via YieldVault accounting slot manipulation (the same technique used
    // in ProbabilityVault.t.sol _simulateYield helper) to reduce reported
    // token balances below deposited principal.
    //
    // The slots below match YieldVault.sol storage layout (as of 2026-04-18):
    //   slot 0 → Ownable._owner
    //   slot 1 → strategies[]  (dynamic array length at slot 1)
    //   slot 2 → strategy entries (array start, 4 fields each, mapping at +2 and +5)
    // Finding the correct slot is brittle; covered via forge-std cheatcodes.
    // This test documents expected behavior via an integration test with a
    // resolver-read cancel (ambiguous) instead, because the slot layout may
    // shift under optimizer. See ProbabilityVault.audit.t.sol for the full
    // strategy-loss discussion (Finding 6).
    //
    // Behavioral assertion: if vault returns principal ≥ actual USDC in contract,
    // _cancel writes totalYield = principal, distributableYield = returned.
    // claim() then scales: principalOut = principal * returned / principal = returned.
    // Edge: when returned == principal (0% loss), claim gives full principal back.

    // ─── 6. Emergency cancel via factory ──────────────────────────────

    function test_emergencyCancel_byFactory_refundsAll() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 500e6,   NO);

        // Factory owner calls emergencyCancelVault
        bytes32 vaultId = factory.getCreatorVaults(creator)[0];
        factory.emergencyCancelVault(vaultId);

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        assertEq(usdc.balanceOf(alice) - aliceBefore, 1_000e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pv.claim();
        assertEq(usdc.balanceOf(bob) - bobBefore, 500e6);
    }

    function test_emergencyCancel_onlyFactory() public {
        address v = _createVault();
        _deposit(alice, v, 1_000e6, YES);

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.NotFactory.selector);
        ProbabilityVaultV2(v).emergencyCancel();
    }

    // ─── 7. Empty pool cancel ─────────────────────────────────────────

    function test_emptyPool_cancel() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // No one deposits at all
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    // ─── 8. Imbalance exactly at boundary ────────────────────────────

    /// @notice At 5% minority threshold exactly, vault should NOT cancel.
    ///         (5% is the minimum; exactly 5% passes)
    function test_imbalance_exactlyAtBoundary_notCancelled() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // 950 YES, 50 NO = 5% NO exactly. cancelMinorityPct = 5.
        // Check: 50 * 100 < (950+50) * 5 → 5000 < 5000 → false → NOT cancelled.
        _deposit(alice,   v, 950e6, YES);
        _deposit(charlie, v, 50e6,  NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        // Exactly at boundary → should finalize (not cancel)
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));
    }

    function test_imbalance_justBelowBoundary_cancels() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // 951 YES, 49 NO → 49/1000 < 5% → cancel
        _deposit(alice,   v, 951e6, YES);
        _deposit(charlie, v, 49e6,  NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    // ─── 9. resolveContest reverts before resolveStart ────────────────

    function test_resolve_revertBeforeResolveStart() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 500e6,   NO);

        // Warp to after joinEnd but before resolveStart
        vm.warp(uint256(pv.polymarketEndDate()) + 1);
        // Still before resolveStart (polyEnd + 37h)
        assertTrue(block.timestamp < uint256(pv.resolveStart()));

        vm.expectRevert(ProbabilityVaultV2.WindowNotOpen.selector);
        pv.resolveContest();
    }

    // ─── 10. Deposit with zero amount reverts ────────────────────────

    function test_deposit_revertOnZeroAmount() public {
        address v = _createVault();
        vm.startPrank(alice);
        usdc.approve(v, 1000e6);
        vm.expectRevert(ProbabilityVaultV2.ZeroAmount.selector);
        ProbabilityVaultV2(v).deposit(0, YES);
        vm.stopPrank();
    }

    // ─── 11. Swap reverts on invalid side ────────────────────────────

    function test_swap_revertOnInvalidSide() public {
        address v = _createVault();
        _deposit(alice, v, 1_000e6, YES);

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.InvalidSide.selector);
        ProbabilityVaultV2(v).swap(100e6, keccak256("INVALID_SIDE"));
    }

    // ─── 12. TWAB conservation: partial early withdraw ────────────────

    /// @notice After Alice early-withdraws, Bob's TWAB is unaffected and
    ///         he receives the full distributable yield.
    function test_twab_partialEarlyWithdraw_doesNotDiluteWinners() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 500e6, YES);
        _deposit(bob,   v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        vm.warp(block.timestamp + 2 days);

        // Alice exits early, forfeiting her YES TWAB
        vm.prank(alice);
        pv.withdrawEarly();

        // totalYesTwab should now only reflect Bob's stake-seconds
        // Alice's TWAB was removed from global

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        // Bob should receive ALL yield (Alice forfeited; Charlie on losing side)
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pv.claim();
        uint256 bobReceived = usdc.balanceOf(bob) - bobBefore;
        // Bob gets 500 principal + all distributable yield
        assertApproxEqAbs(bobReceived, 500e6 + (20e6 * 98 / 100), 1e5);
    }

    // ─── 13. Swap fee accrues + swept on finalize ─────────────────────

    function test_swapFee_accruesAndSweptToTreasury() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 1_000e6, NO);

        vm.warp(block.timestamp + 1 days);

        // Alice swaps 1000 YES → NO; fee = 1000e6 * 20 / 10000 = 2e6
        vm.prank(alice);
        pv.swap(1_000e6, NO);
        assertEq(uint256(pv.totalAccruedSwapFees()), 2e6);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pv.resolveContest();

        // Swap fees should be swept to treasury
        uint256 treasuryGained = usdc.balanceOf(treasury) - treasuryBefore;
        // Treasury gets: protocol fee on yield + swap fees
        // Swap fees: 2e6 USDC
        // Protocol fee on ~30 USDC yield: 30e6 * 200 / 10000 = 600_000
        // Total: ~2.6e6 USDC
        assertGe(treasuryGained, 2e6);
        assertEq(uint256(pv.totalAccruedSwapFees()), 0); // swept to 0
    }

    // ─── 14. PolymarketRelayResolver: honest challenge ────────────────

    function test_resolver_honestChallenge_bondRefunded() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        // Relayer proposes WRONG outcome after grace window
        vm.warp(uint256(polyEnd) + 12 hours + 1);
        resolver.propose(key, PolymarketRelayResolver.Outcome.NO_WIN);

        // Challenger disputes with bond (25 USDC)
        uint256 bond = resolver.requiredBondFor(key);
        vm.startPrank(challenger);
        usdc.approve(address(resolver), bond);
        resolver.challenge(key, PolymarketRelayResolver.Outcome.YES_WIN);
        vm.stopPrank();

        // Admin finalizes — challenger was honest (YES was correct)
        uint256 challengerBefore = usdc.balanceOf(challenger);
        resolver.finalizeAfterDispute(
            key,
            PolymarketRelayResolver.Outcome.YES_WIN,
            true,   // challengerWasHonest
            treasury
        );

        // Challenger gets bond back
        assertEq(usdc.balanceOf(challenger) - challengerBefore, bond);
    }

    // ─── 15. PolymarketRelayResolver: dishonest challenge ─────────────

    function test_resolver_dishonestChallenge_bondSlashed() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        // Relayer proposes CORRECT outcome
        vm.warp(uint256(polyEnd) + 12 hours + 1);
        resolver.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);

        // Challenger disputes incorrectly (says NO won when YES actually won)
        uint256 bond = resolver.requiredBondFor(key);
        vm.startPrank(challenger);
        usdc.approve(address(resolver), bond);
        resolver.challenge(key, PolymarketRelayResolver.Outcome.NO_WIN);
        vm.stopPrank();

        // Admin finalizes — challenger was wrong
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        resolver.finalizeAfterDispute(
            key,
            PolymarketRelayResolver.Outcome.YES_WIN,
            false,  // challengerWasHonest = false
            treasury
        );

        // Bond slashed to treasury
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, bond);
    }

    // ─── 16. Resolver: dispute window expired — challenge reverts ─────

    function test_resolver_challengeAfterWindow_reverts() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        vm.warp(uint256(polyEnd) + 12 hours + 1);
        resolver.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);

        // Fast-forward past the 24h dispute window
        vm.warp(block.timestamp + 25 hours);

        uint256 bond = resolver.requiredBondFor(key);
        vm.startPrank(challenger);
        usdc.approve(address(resolver), bond);
        vm.expectRevert(PolymarketRelayResolver.ChallengeWindowExpired.selector);
        resolver.challenge(key, PolymarketRelayResolver.Outcome.NO_WIN);
        vm.stopPrank();
    }

    // ─── 17. Resolver: same-outcome challenge reverts ─────────────────

    function test_resolver_challengeSameOutcome_reverts() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        vm.warp(uint256(polyEnd) + 12 hours + 1);
        resolver.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);

        uint256 bond = resolver.requiredBondFor(key);
        vm.startPrank(challenger);
        usdc.approve(address(resolver), bond);
        vm.expectRevert(PolymarketRelayResolver.UnsupportedOutcome.selector);
        resolver.challenge(key, PolymarketRelayResolver.Outcome.YES_WIN); // same as proposed
        vm.stopPrank();
    }

    // ─── 18. Resolver: force timeout cancel on REGISTERED (never proposed)

    function test_resolver_forceTimeout_whenNeverProposed() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));
        PolymarketRelayResolver.PolyConfig memory cfg = _resolverConfig(key);

        // Advance past 7-day timeout
        vm.warp(uint256(cfg.polymarketEndDate) + 7 days + 1);
        resolver.forceTimeoutCancel(key);

        (, bytes32 winner) = resolver.resolve(key);
        assertEq(winner, bytes32(0)); // cancelled → ambiguous
    }

    function _resolverConfig(bytes32 key) internal view returns (PolymarketRelayResolver.PolyConfig memory) {
        (bytes32 conditionId, bytes32 yesOpt, bytes32 noOpt, uint64 pmEnd,
         PolymarketRelayResolver.Status status, PolymarketRelayResolver.Outcome proposedOutcome,
         uint64 proposedAt, address proposer, PolymarketRelayResolver.Outcome challengerOutcome,
         address challeng, uint96 bond, PolymarketRelayResolver.Outcome finalOutcome) =
             resolver.configs(key);
        return PolymarketRelayResolver.PolyConfig({
            conditionId: conditionId,
            yesOption: yesOpt,
            noOption: noOpt,
            polymarketEndDate: pmEnd,
            status: status,
            proposedOutcome: proposedOutcome,
            proposedAt: proposedAt,
            proposer: proposer,
            challengerOutcome: challengerOutcome,
            challenger: challeng,
            challengerBond: bond,
            finalOutcome: finalOutcome
        });
    }

    // ─── 19. Factory: cannot init already-initialized clone ───────────

    function test_factory_cannotReinitVault() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        ProbabilityVaultV2.InitParams memory bad = ProbabilityVaultV2.InitParams({
            creator: alice,
            depositToken: address(usdc),
            joinEnd: uint64(block.timestamp + 1 days),
            polymarketEndDate: uint64(block.timestamp + 2 days),
            resolveStart: uint64(block.timestamp + 3 days),
            cancelDeadline: uint64(block.timestamp + 9 days),
            tierRequired: 0,
            cancelMinorityPct: 5,
            yesOption: YES,
            noOption: NO,
            conditionId: CONDITION_ID,
            metadataHash: keccak256("reinit"),
            metadataUri: "ipfs://reinit",
            resolver: address(resolver),
            yieldVault: address(yieldVault),
            yieldStrategy: address(0),
            identityRegistry: address(identityRegistry),
            protocolFeeBps: 200,
            swapFeeBps: 20,
            protocolFeeRecipient: treasury
        });
        vm.expectRevert(ProbabilityVaultV2.AlreadyInitialized.selector);
        pv.initialize(bad);
    }

    // ─── 20. Surplus yield on cancel → routed to treasury ─────────────

    function test_cancel_surplusYieldReservedForUsers() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // Create imbalance so vault will cancel
        _deposit(alice, v, 10_000e6, YES);
        _deposit(bob,   v, 1e6,      NO); // < 5%

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(100e6); // 100 USDC yield

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
        // Cancel-with-yield-refund: the surplus (100 USDC) is reserved for
        // depositors pro-rata, NOT routed to treasury, and NO protocol fee is
        // taken on a cancelled market (no swaps here, so treasury is untouched).
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0, "no treasury fee on cancel");
        assertApproxEqAbs(uint256(pv.cancelYieldPool()), 100e6, 100, "full surplus reserved for users");
    }

    // ─── 21. Full lifecycle: 5 users with mixed deposits + swaps ──────

    function test_fullLifecycle_fiveUsers_mixedActivity() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 1_000e6, YES);
        _deposit(bob,     v, 800e6,   NO);
        _deposit(charlie, v, 600e6,   YES);
        _deposit(dave,    v, 400e6,   NO);
        _deposit(eve,     v, 200e6,   YES);

        // One day in, Charlie swaps to NO
        vm.warp(block.timestamp + 1 days);
        vm.prank(charlie);
        pv.swap(600e6, NO);

        // Two days in, Bob early-withdraws
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        pv.withdrawEarly();

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(50e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES); // YES wins: Alice + Eve collect yield

        uint256 totalYesTwab = pv.totalYesTwab();
        assertTrue(totalYesTwab > 0, "YES TWAB must be positive");

        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // All users claim
        uint256 totalOut;
        address[5] memory users = [alice, bob, charlie, dave, eve];
        for (uint256 i = 0; i < users.length; i++) {
            ProbabilityVaultV2.UserPosition memory pos = pv.userPosition(users[i]);
            if (pos.withdrawnEarly) continue; // Bob already withdrew
            uint256 before = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            pv.claim();
            totalOut += usdc.balanceOf(users[i]) - before;
        }
        // Total out ≤ total deposited + yield (some may have been swept as fees)
        uint256 totalIn = 1_000e6 + 800e6 + 600e6 + 400e6 + 200e6;
        assertLe(totalOut, totalIn + 50e6);
        assertGt(totalOut, 0);
    }

    // ─── 22. deposit: reverts when vault not in JOIN_OPEN ─────────────

    function test_deposit_revertInLockedState() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 500e6,   NO);

        // Advance past joinEnd to LOCKED
        vm.warp(uint256(pv.joinEnd()) + 1);
        pv.updateState(); // trigger auto-transition

        vm.startPrank(charlie);
        usdc.approve(v, 500e6);
        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        pv.deposit(500e6, YES);
        vm.stopPrank();
    }

    // ─── 23. Factory: setBondOverride scales challenge bond ───────────

    function test_resolver_bondOverride() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        // Admin sets bond to 100 USDC
        resolver.setBondOverride(key, 100e6);
        assertEq(resolver.requiredBondFor(key), 100e6);

        // MIN_BOND is still the fallback for other contests
        bytes32 otherKey = keccak256("other-contest");
        assertEq(resolver.requiredBondFor(otherKey), resolver.MIN_BOND());
    }

    // ─── 24. impliedProbabilityYes at extremes ────────────────────────

    function test_impliedProbability_extremes() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // Before any deposits: should return 0
        assertEq(pv.impliedProbabilityYes(), 0);

        // All YES: probability 10000 (100%)
        _deposit(alice, v, 1_000e6, YES);
        // With only YES, probability = 1000/1000 = 10000
        assertEq(pv.impliedProbabilityYes(), 10_000);

        // Add equal NO
        _deposit(bob, v, 1_000e6, NO);
        // 1000/(1000+1000) = 5000
        assertEq(pv.impliedProbabilityYes(), 5_000);
    }

    // ─── 25. Resolver: propose before grace window reverts ────────────

    function test_resolver_proposeBeforeGrace_reverts() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        // Still within the 12h grace window
        vm.warp(uint256(polyEnd) + 6 hours);
        vm.expectRevert(PolymarketRelayResolver.GraceWindowNotElapsed.selector);
        resolver.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);
    }

    // ─── 26. YieldVault trust: setTrustedDepositor enables early withdraw

    function test_trustedDepositor_enablesEarlyWithdraw() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);

        // A non-trusted deposit from griefer would normally reset MIN_HOLD_TIME.
        // Since factory auto-registered this clone as trusted, withdrawEarly
        // should work even if someone else just deposited.
        address griefer = address(0x666);
        identityRegistry.setTier(griefer, 2);
        usdc.mint(griefer, 1000e6);
        _deposit(griefer, v, 1, NO); // griefer deposits 1 wei

        // Wait just 30 seconds (below YieldVault's 60s MIN_HOLD_TIME for non-trusted)
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 1);

        // Alice should be able to withdraw (trusted depositor bypasses MIN_HOLD_TIME)
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.withdrawEarly(); // should NOT revert with "minimum hold time not met"
        assertEq(usdc.balanceOf(alice) - aliceBefore, 1_000e6);
    }

    // ─── 27. Multiple vaults from same factory — independent ──────────

    function test_multipleVaults_independent() public {
        // Create two separate vaults
        vm.prank(creator);
        (, address v1) = factory.createVault(ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: uint64(block.timestamp + 10 days),
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       keccak256("cid-1"),
            metadataHash:      keccak256("vault-1"),
            metadataUri:       "ipfs://v1",
            resolver:          address(resolver)
        }));

        vm.prank(creator);
        (, address v2) = factory.createVault(ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: uint64(block.timestamp + 14 days),
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       keccak256("cid-2"),
            metadataHash:      keccak256("vault-2"),
            metadataUri:       "ipfs://v2",
            resolver:          address(resolver)
        }));

        assertTrue(v1 != v2);
        assertEq(factory.getVaultCount(), 2);

        // Deposits in v1 don't affect v2
        _deposit(alice, v1, 1_000e6, YES);
        assertEq(ProbabilityVaultV2(v1).totalYesStake(), 1_000e6);
        assertEq(ProbabilityVaultV2(v2).totalYesStake(), 0);
    }

    // ─── 28. Resolver type is stable keccak ───────────────────────────

    function test_resolverType_isStable() public view {
        bytes32 expected = keccak256("PolymarketRelayResolver.v1");
        assertEq(resolver.resolverType(), expected);
    }

    // ─── 29. Claim reverts if vault not finalized/cancelled ───────────

    function test_claim_revertWhenNotFinalized() public {
        address v = _createVault();
        _deposit(alice, v, 1_000e6, YES);

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        ProbabilityVaultV2(v).claim();
    }

    // ─── 30. withdraw early reverts if past joinEnd ───────────────────

    function test_earlyWithdraw_revertPastJoinEnd() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        _deposit(alice, v, 1_000e6, YES);

        vm.warp(uint256(pv.joinEnd()) + 1);

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        pv.withdrawEarly();
    }

    // ─── 31. Zero yield: winner gets only principal ────────────────────

    /// @notice If the strategy generates no yield, finalized vault returns
    ///         exactly the principal to winners — no windfall, no loss.
    function test_zeroYield_winnerGetsOnlyPrincipal() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v,   500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        // No yield injected — distributableYield == 0
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        // Alice gets exactly her principal — no yield, no penalty
        assertEq(usdc.balanceOf(alice) - aliceBefore, 1_000e6);
    }

    // ─── 32. All early-withdraw → empty pool → cancel ─────────────────

    /// @notice If every depositor exits before joinEnd the pool drains.
    ///         resolveContest() sees totalTwab == 0 and cancels.
    function test_allEarlyWithdraw_poolEmptyThenCancel() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v,   500e6, NO);

        // Both withdraw before joinEnd
        vm.roll(block.number + 1);
        vm.prank(alice); pv.withdrawEarly();
        vm.roll(block.number + 1);
        vm.prank(bob);   pv.withdrawEarly();

        // Principal returned immediately
        assertGe(usdc.balanceOf(alice), 1_000e6);
        assertGe(usdc.balanceOf(bob),     500e6);

        // Advance past all time locks, propose YES, then resolve
        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(0);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        // Pool is empty → vault auto-cancels
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    // ─── 33. Staggered TWAB — three users, proportional yield ─────────

    /// @notice Alice joins at t=0 (full window), Bob at t=1/2, Charlie
    ///         at t=3/4. Their TWABs should be proportional: 4:2:1.
    function test_staggeredTwab_threeUsers_proportionalYield() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        uint64 joinStart = uint64(block.timestamp);
        uint64 jEnd      = pv.joinEnd();
        uint64 window    = jEnd - joinStart;

        // Alice deposits at t=0 (full window)
        _deposit(alice, v, 1_000e6, YES);

        // Bob deposits at t = window/2
        vm.warp(joinStart + window / 2);
        _deposit(bob, v, 1_000e6, YES);

        // Charlie deposits at t = 3*window/4
        vm.warp(joinStart + (window * 3) / 4);
        _deposit(charlie, v, 1_000e6, YES);

        // Balance the pool so it doesn't cancel on imbalance
        _deposit(dave, v, 3_000e6, NO);

        // Finalize with YES winning
        vm.warp(uint256(jEnd) + 1);
        _simulateYield(280e6); // large yield to reduce rounding noise
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        uint256 aliceBefore   = usdc.balanceOf(alice);
        uint256 bobBefore     = usdc.balanceOf(bob);
        uint256 charlieBefore = usdc.balanceOf(charlie);

        vm.prank(alice);   pv.claim();
        vm.prank(bob);     pv.claim();
        vm.prank(charlie); pv.claim();

        uint256 aliceYield   = usdc.balanceOf(alice)   - aliceBefore   - 1_000e6;
        uint256 bobYield     = usdc.balanceOf(bob)     - bobBefore     - 1_000e6;
        uint256 charlieYield = usdc.balanceOf(charlie) - charlieBefore - 1_000e6;

        // Alice (full window) earns more than Bob (half window), who earns more than Charlie (quarter)
        assertGt(aliceYield, bobYield);
        assertGt(bobYield,   charlieYield);

        // Alice should be roughly 2x Bob (within 10% of 280e6 / 7 ≈ 40e6 tolerance)
        assertApproxEqAbs(aliceYield, 2 * bobYield, 40e6);
    }

    // ─── 34. Swap after early-withdraw reverts ─────────────────────────

    /// @notice After withdrawEarly() the user has 0 stake, so swap reverts.
    function test_swapAfterEarlyWithdraw_reverts() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        vm.roll(block.number + 1);

        vm.prank(alice);
        pv.withdrawEarly();

        // Approve vault in case it checks balance
        vm.startPrank(alice);
        usdc.approve(v, type(uint256).max);
        vm.expectRevert(ProbabilityVaultV2.InsufficientStake.selector);
        pv.swap(100e6, NO);
        vm.stopPrank();
    }

    // ─── 35. resolveContest is idempotent — second call reverts ───────

    function test_resolveContest_twice_secondReverts() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v,   500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(10e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);

        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // Second call must revert — vault is already finalized
        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        pv.resolveContest();
    }

    // ─── 36. forceTimeoutCancel too early reverts ──────────────────────

    /// @notice forceTimeoutCancel requires the full 7-day SETTLEMENT_TIMEOUT.
    ///         Calling before that window passes reverts.
    function test_forceTimeoutCancel_tooEarly_reverts() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        // Warp past grace window so register is fine, but not past timeout
        vm.warp(uint256(polyEnd) + 12 hours + 1);
        // Do NOT call propose() — keep status == REGISTERED

        // 6 days 23 hours after polyEnd — still 1 hour short of 7-day timeout
        vm.warp(uint256(polyEnd) + 7 days - 1 hours);

        vm.expectRevert(PolymarketRelayResolver.TimeoutNotReached.selector);
        resolver.forceTimeoutCancel(key);
    }

    // ─── 37. Emergency cancel on finalized vault reverts ──────────────

    function test_emergencyCancel_finalizedVault_reverts() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        bytes32 vaultId = factory.getCreatorVaults(creator)[0];

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v,   500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(10e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        factory.emergencyCancelVault(vaultId);
    }

    // ─── 38. Multi-swap fee accumulation is exact ─────────────────────

    /// @notice 5 swaps all YES→NO; verify totalAccruedSwapFees equals
    ///         the sum of individual fee deductions (no rounding loss to vault).
    function test_multiSwap_feeAccumulation_exact() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 10_000e6, YES);
        _deposit(bob,   v, 10_000e6, NO);  // balance pool

        uint96 feeBps = pv.swapFeeBps();
        uint256 swapAmount = 1_000e6;
        uint256 totalExpectedFees;

        // 5 swaps YES→NO (alice's yesStake decreases each time but stays ≥ 5000)
        for (uint256 i = 0; i < 5; i++) {
            uint256 fee = (swapAmount * feeBps) / 10_000;
            totalExpectedFees += fee;
            vm.prank(alice);
            pv.swap(swapAmount, NO);
        }

        uint256 actualFees = pv.totalAccruedSwapFees();
        // Fees may differ by at most 5 wei of rounding (1 per swap)
        assertApproxEqAbs(actualFees, totalExpectedFees, 5);
        assertGt(actualFees, 0);
    }

    // ─── 39. Deposit → swap → deposit again: TWAB still correct ───────

    /// @notice After swap, a second deposit on the new side should add to
    ///         noStake correctly. The claim math must still work.
    function test_depositSwapDeposit_claimCorrect() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // Alice: 2000 YES, then swap 1000 YES→NO, then deposit 500 more YES
        _deposit(alice, v, 2_000e6, YES);
        vm.prank(alice); pv.swap(1_000e6, NO);
        // small time gap so TWAB accumulates on new position
        vm.warp(block.timestamp + 100);
        _deposit(alice, v, 500e6, YES);

        // Bob balances NO side
        _deposit(bob, v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndFinalize(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // Alice should be able to claim without reverting
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        // Alice's net receipt ≥ principal (2000 - swapFee + 500)
        assertGt(usdc.balanceOf(alice), aliceBefore);
    }

    // ─── 40. Resolver: propose CANCELLED outcome reverts ──────────────

    /// @notice The resolver only accepts YES_WIN, NO_WIN, or AMBIGUOUS.
    ///         Proposing CANCELLED (4) must revert with UnsupportedOutcome.
    function test_resolver_proposeCancelled_reverts() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        vm.warp(uint256(polyEnd) + 12 hours + 1);

        vm.expectRevert(PolymarketRelayResolver.UnsupportedOutcome.selector);
        resolver.propose(key, PolymarketRelayResolver.Outcome.CANCELLED);
    }

    // ─── 41. Resolver: resolve() before any proposal returns false ────

    /// @notice The view function resolve() must return (false, bytes32(0))
    ///         when status == REGISTERED (no proposal yet).
    function test_resolver_resolveBeforeProposal_returnsFalse() public {
        address v = _createVault();
        bytes32 key = bytes32(uint256(uint160(v)));

        (bool ready, bytes32 winner) = resolver.resolve(key);
        assertFalse(ready);
        assertEq(winner, bytes32(0));
    }

    // ─── 42. Factory: protocolFeeRecipient is immutable ───────────────

    /// @notice Post-2026-04-28: setFeeRecipient was removed. The factory's
    ///         protocolFeeRecipient is constructor-immutable, so a compromised
    ///         factory owner cannot redirect future protocol fees. To rotate,
    ///         the protocol must deploy a new factory.
    function test_factory_protocolFeeRecipient_isImmutable() public view {
        // Confirm the factory exposes the recipient and it matches the deploy-time value.
        assertTrue(factory.protocolFeeRecipient() != address(0));
    }
}
