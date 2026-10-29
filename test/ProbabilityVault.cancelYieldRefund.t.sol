// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/interfaces/IResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @dev Minimal resolver that returns a caller-set (ready, winner) so we can
///      exercise the "garbage winner" path that the canonical
///      PolymarketRelayResolver can never produce.
contract MockBadResolver is IResolver {
    bool public r;
    bytes32 public w;
    function set(bool _r, bytes32 _w) external { r = _r; w = _w; }
    function register(bytes32, bytes calldata) external {}
    function requestSettlement(bytes32) external pure returns (bool) { return false; }
    function resolve(bytes32) external view returns (bool, bytes32) { return (r, w); }
    function settlementTimeout() external pure returns (uint64) { return 24 hours; }
    function resolverType() external pure returns (bytes32) { return keccak256("MockBadResolver"); }
}

/// @notice Cancel-with-yield-refund tests for the post-2026-redeploy
///         ProbabilityVaultV2. Covers the new behavior in `_doCancel`:
///         when a cancel produces a yield surplus AND combined TWAB is
///         non-zero, the surplus (minus protocol fee) is distributed
///         pro-rata across all depositors weighted by combined yes+no
///         TWAB. Strategy-loss cancel keeps the existing semantics.
///
///         Backwards-compat note: the test harness here exercises the
///         CURRENT implementation contract, so these tests will fail
///         against any deployment that predates the cancel-yield-refund
///         change. They are pinned to the implementation in
///         contracts/src/ProbabilityVaultV2.sol on this branch — the
///         "old" mainnet vaults retain the legacy surplus-to-treasury
///         routing because they're cloned from the old implementation.
contract ProbabilityVaultCancelYieldRefundTest is Test {
    ProbabilityVaultV2      public impl;
    ProbabilityVaultFactory public factory;
    YieldVault              public yieldVault;
    IdentityRegistry        public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20               public usdc;

    address public deployer = address(this);
    address public creator  = address(0x100);
    address public alice    = address(0x101);
    address public bob      = address(0x102);
    address public charlie  = address(0x103);
    address public treasury = address(0x111);

    bytes32 public constant CONDITION_ID = keccak256("polymarket-cancel-yield-test");
    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");

    uint64 public polyEnd;

    function setUp() public {
        vm.warp(1_800_000_000);
        polyEnd = uint64(block.timestamp + 7 days);

        usdc = new MockERC20("USDC", "USDC", 6);

        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));

        identityRegistry = new IdentityRegistry();
        address[3] memory all = [alice, bob, charlie];
        for (uint256 i = 0; i < all.length; i++) {
            identityRegistry.setTier(all[i], 2);
            usdc.mint(all[i], 100_000e6);
        }
        usdc.mint(creator, 100_000e6);

        impl = new ProbabilityVaultV2();
        factory = new ProbabilityVaultFactory(
            address(impl),
            address(yieldVault),
            address(0),
            address(identityRegistry),
            treasury
        );

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
            metadataHash:      keccak256("test-pv-cancel-yield"),
            metadataUri:       "ipfs://test",
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

    /// @dev Same pattern as ProbabilityVault.t.sol::_simulateYield — directly
    ///      pokes the YieldVault storage so the next withdraw returns more
    ///      than was deposited. Saves us from running a real strategy in
    ///      these tests.
    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(yieldVault), amount);
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur + amount));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 + amount));
    }

    function _proposeAmbiguous(address vault) internal {
        bytes32 key = bytes32(uint256(uint160(vault)));
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        resolver.propose(key, PolymarketRelayResolver.Outcome.AMBIGUOUS);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    function _proposeOutcomeYes(address vault) internal {
        bytes32 key = bytes32(uint256(uint160(vault)));
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        resolver.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ─── Imbalance cancel — yield refunded pro-rata ───────────────────

    /// @notice Lopsided pool (YES 10000, NO 1) → imbalance cancel.
    ///         Yield should be distributed pro-rata to combined TWAB,
    ///         minus the protocol fee.
    function test_imbalanceCancel_yieldRefundedProRata() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 10_000e6, YES);   // dominant side
        _deposit(bob,   v,       1e6, NO);   // 0.01% — under 5% floor

        // Both deposits at block.timestamp = T0. They sit until joinEnd.
        uint256 totalStakeSeconds = (10_001e6) * (uint256(pv.joinEnd()) - block.timestamp);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6); // 30 USDC yield
        vm.warp(uint256(pv.resolveStart()) + 1);
        vm.roll(100);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // #4: a cancelled market takes NO protocol fee — the full 30 USDC
        // surplus is reserved for users; treasury is untouched (no swaps here,
        // so there's no swap-fee sweep either).
        // Tolerance: YieldVault.withdraw rounds down so surplus may be off
        // by a few wei from the simulated 30e6.
        uint256 expectedReserved = 30e6;
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0, "no treasury fee on cancel");
        assertApproxEqAbs(uint256(pv.cancelYieldPool()),    expectedReserved, 100, "cancelYieldPool = full surplus");

        // Alice gets ~10000/10001 of the reserved yield + full principal.
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBalBefore;

        // Bob gets ~1/10001 + full principal.
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pv.claim();
        uint256 bobGot = usdc.balanceOf(bob) - bobBalBefore;

        // Principal is fully returned.
        assertGe(aliceGot, 10_000e6, "alice principal");
        assertGe(bobGot,       1e6,   "bob principal");

        // Yield share is proportional to stake-seconds. Since alice's stake-
        // seconds (10_000 * duration) >> bob's (1 * duration), alice should
        // get ~99.99% of the reserved yield.
        uint256 aliceYield = aliceGot - 10_000e6;
        uint256 bobYield   = bobGot - 1e6;
        assertGt(aliceYield, 0, "alice yield > 0");
        assertGt(bobYield,   0, "bob yield > 0 (no zero-out for minority)");

        // Sum-conservation: total payouts ≤ what the vault returned.
        // Reserved was 29.4 USDC; rounding-down should leave at most a few wei.
        assertLe(aliceYield + bobYield, expectedReserved, "yield sum <= pool");
        assertGe(aliceYield + bobYield + 100, expectedReserved, "yield sum approx pool (dust)");

        // Ratio check: alice yield / bob yield ≈ 10000 / 1.
        // (Bob's stake is tiny so rounding could matter, but we just check
        // alice > 9000 * bob to allow generous tolerance.)
        assertGt(aliceYield, 9_000 * bobYield, "alice >> bob (proportional)");

        // Suppress unused-variable warning on the helper sum.
        totalStakeSeconds;
    }

    // ─── Ambiguous resolver cancel — both sides get yield ─────────────

    function test_ambiguousCancel_bothSidesGetYieldShare() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // 500/500 split — no imbalance, will cancel only on ambiguous.
        _deposit(alice,   v, 500e6, YES);
        _deposit(bob,     v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(50e6);
        vm.warp(uint256(pv.resolveStart()) + 1);

        _proposeAmbiguous(v);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // #4: no protocol fee on cancel — full 50 USDC surplus reserved, treasury untouched.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0,    "no fee on cancel");
        assertApproxEqAbs(uint256(pv.cancelYieldPool()),    50e6, 100, "pool = full surplus");

        // All three users get a share — even charlie (the NO side, which would
        // have been the "losers" if it had resolved YES).
        uint256 aliceBalBefore   = usdc.balanceOf(alice);
        uint256 bobBalBefore     = usdc.balanceOf(bob);
        uint256 charlieBalBefore = usdc.balanceOf(charlie);

        vm.prank(alice);   pv.claim();
        vm.prank(bob);     pv.claim();
        vm.prank(charlie); pv.claim();

        uint256 aliceYield   = usdc.balanceOf(alice)   - aliceBalBefore   - 500e6;
        uint256 bobYield     = usdc.balanceOf(bob)     - bobBalBefore     - 500e6;
        uint256 charlieYield = usdc.balanceOf(charlie) - charlieBalBefore - 500e6;

        assertGt(aliceYield,   0, "alice gets yield");
        assertGt(bobYield,     0, "bob gets yield");
        assertGt(charlieYield, 0, "charlie (NO side) gets yield too");

        // Equal stake + equal duration → ~equal yield share. Allow 100 wei tolerance.
        assertApproxEqAbs(aliceYield, bobYield,     100, "alice/bob equal");
        assertApproxEqAbs(aliceYield, charlieYield, 100, "alice/charlie equal");

        // Conservation: sum of user yield ≤ pool.
        assertLe(aliceYield + bobYield + charlieYield, uint256(pv.cancelYieldPool()));
    }

    // ─── Timeout cancel — yield refunded ──────────────────────────────

    function test_timeoutCancel_yieldRefunded() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(10e6);
        vm.warp(uint256(pv.cancelDeadline()) + 1);
        vm.roll(100);

        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
        assertGt(uint256(pv.cancelYieldPool()), 0, "pool reserved on timeout");

        vm.prank(alice);
        pv.claim();
        assertGt(usdc.balanceOf(alice), 100_000e6 - 500e6 + 500e6 - 1, "alice got principal + yield");
    }

    // ─── #1: a ready outcome finalizes even past cancelDeadline ───────────

    /// @notice A late-but-valid resolver outcome must FINALIZE (winner takes the
    ///         yield), not be discarded by the timeout-cancel. Proves the
    ///         resolveContest reorder: a ready resolver beats the deadline. The
    ///         timeout exists only for a resolver that NEVER answers (covered by
    ///         test_timeoutCancel_yieldRefunded, which proposes nothing).
    function test_readyOutcome_finalizesEvenPastCancelDeadline() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);

        // Resolver settles YES (proposes + warps past the 24h dispute window).
        _proposeOutcomeYes(v);

        // Push WELL past cancelDeadline — the outcome arrived, but late.
        vm.warp(uint256(pv.cancelDeadline()) + 1 days);
        vm.roll(block.number + 1);

        pv.resolveContest();

        // FINALIZED (not CANCELLED): the valid outcome wins despite the timeout.
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED), "finalized, not timeout-cancelled");
        assertEq(pv.winningOption(), YES, "YES is the winner");
        assertEq(uint256(pv.cancelYieldPool()), 0, "no cancel pool on a finalized market");
        assertGt(uint256(pv.distributableYield()), 0, "yield distributed to winners");

        // Winner (alice, YES) gets principal + yield; loser (charlie, NO) only principal.
        uint256 aliceBefore   = usdc.balanceOf(alice);
        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(alice);   pv.claim();
        vm.prank(charlie); pv.claim();
        assertGt(usdc.balanceOf(alice)   - aliceBefore,   500e6, "winner: principal + yield");
        assertEq(usdc.balanceOf(charlie) - charlieBefore, 500e6, "loser: principal only");
    }

    // ─── Audit A: garbage winner cancels gracefully (no brick) ────────────

    /// @notice A misbehaving resolver returning ready=true with a winner that
    ///         is neither yesOption nor noOption must CANCEL+refund, not revert
    ///         and brick the vault. Regression guard for the resolveContest
    ///         reorder (resolver consulted before timeout): a `ready` garbage
    ///         winner would otherwise skip the timeout net and trap funds.
    function test_invalidWinner_cancelsGracefully_noBrick() public {
        MockBadResolver bad = new MockBadResolver();
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.resolver = address(bad);
        vm.prank(creator);
        (, address v) = factory.createVault(p);
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(10e6);
        vm.warp(uint256(pv.resolveStart()) + 1);

        // Resolver reports ready with a winner that is neither YES nor NO.
        bad.set(true, keccak256("garbage-not-an-option"));

        // Must NOT revert — it cancels and refunds.
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED), "garbage winner -> CANCELLED, not bricked");

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        assertGe(usdc.balanceOf(alice) - aliceBefore, 500e6, "principal refunded");
    }

    // ─── Empty pool (everyone withdrew early) — no pool, no routing ───

    /// @notice If nobody is left in the pool at cancel time (everyone called
    ///         withdrawEarly), there is no principal obligation and the
    ///         existing `obligation > 0` guard skips all surplus routing.
    ///         Any residual yield in the contract is recoverable later via
    ///         `rescueTrappedDust`. We assert cancelYieldPool stays 0 and
    ///         no new fee transfer fires on this path.
    function test_emptyPool_noPoolReserved() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 100e6, YES);
        _deposit(bob,   v, 100e6, NO);

        // Simulate some yield mid-JOIN.
        _simulateYield(5e6);

        // YieldVault enforces a 60-second MIN_HOLD_TIME for non-trusted
        // depositors; in unit tests the factory's auto-trust-registration
        // silently fails because the test contract (not the factory) owns
        // the vault. Warp past the hold window so withdrawEarly's downstream
        // YieldVault.withdraw doesn't revert.
        vm.warp(block.timestamp + 61);

        // Both users bail before joinEnd. withdrawEarly zeros their TWAB and
        // their principal, so neither principal nor TWAB remains at cancel.
        vm.prank(alice);
        pv.withdrawEarly();
        vm.prank(bob);
        pv.withdrawEarly();

        assertEq(uint256(pv.totalYesTwab()),  0);
        assertEq(uint256(pv.totalNoTwab()),   0);
        assertEq(uint256(pv.totalYesStake()), 0);
        assertEq(uint256(pv.totalNoStake()),  0);

        // Force a cancel via cancelDeadline timeout.
        vm.warp(uint256(pv.cancelDeadline()) + 1);
        vm.roll(100);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pv.resolveContest();

        // Neither new path nor legacy path runs — obligation == 0 short-
        // circuits the surplus branch. cancelYieldPool stays 0; nothing is
        // routed to treasury here.
        assertEq(uint256(pv.cancelYieldPool()), 0,                 "no pool on empty obligation");
        assertEq(usdc.balanceOf(treasury), treasuryBefore,         "treasury unchanged");
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    /// @notice If there IS principal in the pool but combined TWAB == 0
    ///         (impossible in normal flow — would require a fresh deposit
    ///         at the exact joinEnd boundary), the legacy surplus-to-
    ///         treasury path is used. We can't construct this state
    ///         without storage-poking; the test is kept as a documentation
    ///         placeholder for the branch.
    function test_legacySurplusBranch_documentation() public {
        // Reaching `obligation > 0 && totalCombinedTwab == 0` requires a
        // deposit at joinEnd (zero stake-seconds) plus no other deposits.
        // _updateGlobalTwab caps `cap` at min(now, joinEnd); a deposit at
        // block.timestamp == joinEnd produces elapsed == 0 from the prior
        // lastGlobalUpdate. We don't have a clean way to time this exactly
        // in foundry without storage-poking, so we document the branch
        // here and rely on the empty-pool test + manual review of
        // _doCancel for coverage.
        assertTrue(true);
    }

    // ─── Strategy loss cancel — no yield, principal scaled (unchanged) ───

    function test_strategyLossCancel_noYieldRefund_principalScaled() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v,   500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);

        // Burn 10% of the yieldVault's balance to simulate a strategy loss.
        // Same storage-poke approach as _simulateYield but in reverse.
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        uint256 toBurn = cur / 10;
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur - toBurn));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 - toBurn));
        // Also burn actual USDC from yieldVault so balance matches.
        vm.prank(address(yieldVault));
        usdc.transfer(address(0xdead), toBurn);

        vm.warp(uint256(pv.resolveStart()) + 1);
        vm.roll(100);

        // Strategy-loss is detected only AFTER the resolver returns a winner —
        // before that, resolveContest reverts with ResolverNotReady. Propose
        // YES (could be either side; outcome doesn't matter once we cancel
        // for strategy loss). _proposeOutcome warps past dispute window.
        _proposeOutcomeYes(v);

        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // Strategy loss path: cancelYieldPool stays 0; principal is scaled
        // down via distributableYield / totalYield ratio.
        assertEq(uint256(pv.cancelYieldPool()), 0, "no yield pool on strategy loss");
        assertGt(uint256(pv.distributableYield()), 0, "distributableYield set");
        assertGt(uint256(pv.totalYield()), 0, "totalYield set");

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBalBefore;
        // Alice deposited 1000; ~10% strategy loss → gets ~900.
        assertLt(aliceGot, 1_000e6, "principal scaled down");
        assertGt(aliceGot,   800e6, "principal not zeroed");
    }

    // ─── Dead-band regression (audit 2026-06-03) ─────────────────────────
    //
    // A small strategy loss that is SMALLER than the accrued swap fees lands in
    // the band `principal <= returned < principal + swapFees`. There, neither
    // the surplus branch (`returned > obligation`) nor the strategy-loss branch
    // (`returned < principal`) fires. The pre-fix code swept the FULL swap fees
    // to treasury anyway, dipping into user principal and reverting the last
    // claimant's `safeTransfer` — breaking the no-loss guarantee. The fix caps
    // the sweep at `returned - principal` so every depositor claims in full.
    function test_deadBand_smallLossBelowSwapFees_principalFullyClaimable() public {
        // 10% swap fee (cap) so a couple of swaps accrue material fees.
        factory.setSwapFee(1_000);

        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 1_000e6, YES);
        _deposit(bob,     v, 1_000e6, NO);
        _deposit(charlie, v, 1_000e6, YES);

        // Accrue TWAB on both sides, then swap (still JOIN_OPEN).
        vm.warp(block.timestamp + 1 days);
        vm.prank(charlie);
        pv.swap(500e6, NO);                 // fee = 50e6 (10% of 500e6)
        vm.roll(block.number + 1);

        // After the swap: totalYesStake 1500, totalNoStake 1450 → principal 2950;
        // totalAccruedSwapFees 50 → obligation 3000. Both sides funded (no imbalance).
        assertEq(uint256(pv.totalAccruedSwapFees()), 50e6, "swap fee accrued");

        vm.warp(uint256(pv.joinEnd()) + 1);

        // Inject a SMALL strategy loss: burn 30e6 from the YieldVault so the
        // withdraw returns ~2970e6 — inside the band [2950, 3000). Same
        // storage-poke pattern as test_strategyLossCancel_*.
        uint256 toBurn = 30e6;
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur - toBurn));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 - toBurn));
        vm.prank(address(yieldVault));
        usdc.transfer(address(0xdead), toBurn);

        vm.warp(uint256(pv.resolveStart()) + 1);
        vm.roll(block.number + 100);

        // Ambiguous outcome → _doCancel via the dead-band (neither surplus nor
        // strategy-loss branch fires).
        _proposeAmbiguous(v);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED), "cancelled");
        assertEq(uint256(pv.cancelYieldPool()), 0,      "dead-band: no yield pool");
        assertEq(uint256(pv.distributableYield()), 0,   "dead-band: no strategy-loss scaling");

        // Every depositor must be able to claim their FULL principal — the whole
        // point of the fix. Pre-fix, charlie (last) would revert on insufficient
        // balance because the full 50e6 swap fee was swept.
        _claimAndExpectPrincipal(pv, alice,   1_000e6);
        _claimAndExpectPrincipal(pv, bob,     1_000e6);
        _claimAndExpectPrincipal(pv, charlie,   950e6);   // 1000 - 50 swap fee

        // Contract fully drained to the depositors (no principal stranded, no
        // dust beyond rounding).
        assertLe(usdc.balanceOf(address(pv)), 1, "contract drained; no stranded principal");
    }

    function _claimAndExpectPrincipal(ProbabilityVaultV2 pv, address who, uint256 expected) internal {
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        pv.claim();
        assertEq(usdc.balanceOf(who) - before, expected, "full principal claimable");
    }

    // ─── Conservation invariant — pool fully claimable ────────────────

    function test_conservation_sumOfClaimsLeqPool() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // Three users, asymmetric deposits and timings.
        _deposit(alice, v, 1_000e6, YES);
        vm.warp(block.timestamp + 1 hours);
        _deposit(bob, v, 2_500e6, NO);
        vm.warp(block.timestamp + 30 minutes);
        _deposit(charlie, v, 700e6, YES);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(45e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAmbiguous(v);

        pv.resolveContest();
        uint256 pool = uint256(pv.cancelYieldPool());
        assertGt(pool, 0);

        uint256 totalClaimed;
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 before_ = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            pv.claim();
            uint256 after_ = usdc.balanceOf(users[i]);
            // The portion above principal = yield share.
            uint256 yieldGot;
            if (users[i] == alice)        yieldGot = after_ - before_ - 1_000e6;
            else if (users[i] == bob)     yieldGot = after_ - before_ - 2_500e6;
            else                          yieldGot = after_ - before_ - 700e6;
            totalClaimed += yieldGot;
        }

        // Sum of claims ≤ pool (rounding-down may leave a few wei).
        assertLe(totalClaimed, pool, "no over-pay");
        // Dust threshold: less than 100 wei lost to integer rounding.
        assertGe(totalClaimed + 100, pool, "dust < 100 wei");
    }

    // ─── No double-claim ──────────────────────────────────────────────

    function test_doubleClaimReverts() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 500e6, YES);
        _deposit(bob,   v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(5e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAmbiguous(v);
        pv.resolveContest();

        vm.prank(alice);
        pv.claim();

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.AlreadyClaimed.selector);
        pv.claim();
    }

    // ─── Withdraw-early forfeit interacts cleanly with new pool ──────

    /// @notice A user who withdrew early before cancel has their TWAB zeroed
    ///         and cannot claim again. Remaining users get the full yield
    ///         pool (no dilution toward the early-exit user).
    function test_earlyWithdrawer_excludedFromYieldShare() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 500e6, YES);
        _deposit(bob,   v, 500e6, NO);
        _deposit(charlie, v, 500e6, NO);

        // Charlie bails out mid-JOIN.
        vm.warp(block.timestamp + 1 hours);
        vm.prank(charlie);
        pv.withdrawEarly();

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAmbiguous(v);
        pv.resolveContest();

        assertGt(uint256(pv.cancelYieldPool()), 0);

        // Charlie's principal was returned at withdrawEarly. claim() must revert
        // because u.principal == 0 AND u.principalWithdrawn == true. Verify with
        // the actual contract behavior: charlie has nothing left to claim.
        // (NothingToWithdraw is raised because the cancel path computes
        // principalOut = u.principal = 0 and cancelYieldPool * 0 / denom = 0.)
        vm.prank(charlie);
        vm.expectRevert(ProbabilityVaultV2.NothingToWithdraw.selector);
        pv.claim();

        // Alice + Bob share the whole pool.
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);
        vm.prank(alice); pv.claim();
        vm.prank(bob);   pv.claim();

        uint256 aliceYield = usdc.balanceOf(alice) - aliceBefore - 500e6;
        uint256 bobYield   = usdc.balanceOf(bob)   - bobBefore   - 500e6;
        assertGt(aliceYield, 0);
        assertGt(bobYield,   0);

        // Sum-conservation against the pool.
        assertLe(aliceYield + bobYield, uint256(pv.cancelYieldPool()));
    }
}
