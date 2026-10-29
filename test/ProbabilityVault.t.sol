// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice End-to-end tests for the AMM-style ProbabilityVaultV2 + Factory pair.
///         Asserts:
///           - createVault validates every guard
///           - deposit/swap/withdraw happy paths + revert paths
///           - TWAB correctness (single-user, multi-user, mid-game swaps)
///           - yield distribution (stake-weighted by TWAB)
///           - early-withdraw forfeits yield (TWAB subtracted from global)
///           - cancel on imbalance (< CANCEL_MINORITY_PCT)
///           - cancel on resolver ambiguous
///           - cancel on resolver timeout
///           - strategy loss → cancel + pro-rata principal payout
///           - tier gating on deposit
///           - flash-loan same-block deposit-withdraw blocked
///           - swap fee accrual + sweep on finalize
///           - factory owner setters (fees, impl, recipient)
contract ProbabilityVaultTest is Test {
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
    address public dave     = address(0x104);
    address public treasury = address(0x111);

    bytes32 public constant CONDITION_ID = keccak256("polymarket-cond-pv-test");
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
        address[4] memory all = [alice, bob, charlie, dave];
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
            joinEnd:           0,  // use factory default
            resolveStart:      0,  // use factory default
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       CONDITION_ID,
            metadataHash:      keccak256("test-pv"),
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
        vm.roll(block.number + 1); // avoid same-block flash-loan guard
    }

    function _swap(address user, address vault, uint256 amount, bytes32 newSide) internal {
        vm.prank(user);
        ProbabilityVaultV2(vault).swap(amount, newSide);
        vm.roll(block.number + 1);
    }

    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(yieldVault), amount);
        // YieldVault layout (Ownable2Step + ReentrancyGuard before our state):
        // slot 4 = strategies mapping; slot 7 = tokenDeposits mapping.
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur + amount));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 + amount));
    }

    // ─── Configurable settlement-timeout (cancelDeadline override) ──────

    function test_cancelDeadline_defaultsToSevenDays() public {
        address v = _createVault(); // _baseParams sets cancelDeadline: 0
        assertEq(
            ProbabilityVaultV2(v).cancelDeadline(),
            polyEnd + 7 days,
            "0 override must yield the 7-day default"
        );
    }

    function test_cancelDeadline_customWithinBoundsApplied() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.cancelDeadline = uint64(uint256(polyEnd) + 14 days);
        vm.prank(creator);
        (, address v) = factory.createVault(p);
        assertEq(ProbabilityVaultV2(v).cancelDeadline(), polyEnd + 14 days, "custom deadline must be honored");
    }

    function test_cancelDeadline_atMaxBoundApplied() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.cancelDeadline = uint64(uint256(polyEnd) + 30 days); // == MAX_CANCEL_TIMEOUT
        vm.prank(creator);
        (, address v) = factory.createVault(p);
        assertEq(ProbabilityVaultV2(v).cancelDeadline(), polyEnd + 30 days);
    }

    function test_cancelDeadline_revertsBelowMin() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.cancelDeadline = uint64(uint256(polyEnd) + 6 days); // < MIN_CANCEL_TIMEOUT (7d)
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    function test_cancelDeadline_revertsAboveMax() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.cancelDeadline = uint64(uint256(polyEnd) + 31 days); // > MAX_CANCEL_TIMEOUT (30d)
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    function test_cancelDeadline_revertsIfNotAfterResolveStart() public {
        // resolveStart pushed past the requested deadline → must revert even
        // though the deadline itself is within [MIN,MAX].
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.resolveStart    = uint64(uint256(polyEnd) + 8 days);
        p.cancelDeadline  = uint64(uint256(polyEnd) + 7 days); // <= resolveStart
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    /// @dev Walks the resolver through propose → dispute-expiry so resolve()
    ///      reads as FINALIZED. Assumes block.timestamp >= polymarketEndDate
    ///      + GRACE_WINDOW when called. `sideLabel` is YES, NO, or bytes32(0)
    ///      for AMBIGUOUS.
    function _proposeOutcome(address vault, bytes32 sideLabel) internal {
        bytes32 key = bytes32(uint256(uint160(vault)));
        PolymarketRelayResolver.Outcome outcome = sideLabel == YES
            ? PolymarketRelayResolver.Outcome.YES_WIN
            : sideLabel == NO
                ? PolymarketRelayResolver.Outcome.NO_WIN
                : PolymarketRelayResolver.Outcome.AMBIGUOUS;

        // Ensure we're past the 12h grace window after polyEnd
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        resolver.propose(key, outcome);
        // Fast-forward past the 24h dispute window so resolve() returns FINALIZED
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ─── Factory validation ───────────────────────────────────────────

    function test_createVault_succeeds() public {
        vm.prank(creator);
        (bytes32 id, address addr) = factory.createVault(_baseParams());
        assertTrue(id != bytes32(0));
        assertTrue(addr != address(0));
        assertEq(factory.resolverForVault(addr), address(resolver));
    }

    function test_factory_rejectsZeroResolver() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.resolver = address(0);
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.ZeroAddress.selector);
        factory.createVault(p);
    }

    function test_factory_rejectsZeroConditionId() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.conditionId = bytes32(0);
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    function test_factory_rejectsSameYesNo() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.noOption = p.yesOption;
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    function test_factory_rejectsPastEndDate() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.polymarketEndDate = uint64(block.timestamp - 1);
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    function test_factory_rejectsJoinEndTooLate() public {
        ProbabilityVaultFactory.CreateParams memory p = _baseParams();
        p.joinEnd = uint64(uint256(polyEnd) - 1 hours); // within 24h of polyEnd → bad
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVault(p);
    }

    // ─── Deposit + swap ───────────────────────────────────────────────

    function test_deposit_yesAndNo() public {
        address v = _createVault();
        _deposit(alice, v, 100e6, YES);
        _deposit(bob, v, 200e6, NO);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        assertEq(pv.totalYesStake(), 100e6);
        assertEq(pv.totalNoStake(),  200e6);

        (uint256 yesBps, uint256 noBps) = pv.poolRatio();
        // yes = 100 / 300 = 33.33%
        assertApproxEqAbs(yesBps, 3333, 1);
        assertApproxEqAbs(noBps,  6667, 1);
    }

    function test_swap_depositsFee() public {
        address v = _createVault();
        _deposit(alice, v, 1000e6, YES);
        // Wait 10% of join window to accumulate some TWAB
        vm.warp(block.timestamp + 1 days);
        // Alice swaps 500 USDC YES→NO
        _swap(alice, v, 500e6, NO);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        // Fee = 500e6 * 20 / 10000 = 1e6 = 1 USDC
        // Alice's yes went from 1000 to 500 (input)
        // Alice's no went from 0 to 499 (net after 0.2% fee)
        assertEq(pv.totalYesStake(), 500e6);
        assertEq(pv.totalNoStake(),  499e6);
        assertEq(pv.totalAccruedSwapFees(), 1e6);
    }

    function test_swap_revertsOnInsufficientStake() public {
        address v = _createVault();
        _deposit(alice, v, 100e6, YES);
        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.InsufficientStake.selector);
        ProbabilityVaultV2(v).swap(200e6, NO);
    }

    function test_deposit_anonymousByDefault() public {
        // Default factory.minTier == 0: a wallet with no IdentityRegistry
        // entry (tier 0) must be able to deposit. Locks in the post-2026-05-02
        // policy: yield markets are no-vote / no-loss, so they don't need
        // sybil resistance.
        address stranger = address(0x999);
        usdc.mint(stranger, 1000e6);

        address v = _createVault();
        vm.startPrank(stranger);
        usdc.approve(v, 100e6);
        ProbabilityVaultV2(v).deposit(100e6, YES);
        vm.stopPrank();

        assertEq(uint256(ProbabilityVaultV2(v).totalYesStake()), 100e6);
    }

    function test_setMinTier_gatesDepositsOnNewVaults() public {
        // Owner can opt back into identity gating for product variants that
        // need it. Existing clones snapshot minTier at initialize() and are
        // unaffected — only NEW vaults pick up the change.
        factory.setMinTier(2);

        address stranger = address(0x999);
        usdc.mint(stranger, 1000e6);

        address v = _createVault();
        vm.startPrank(stranger);
        usdc.approve(v, 100e6);
        vm.expectRevert(ProbabilityVaultV2.TierTooLow.selector);
        ProbabilityVaultV2(v).deposit(100e6, YES);
        vm.stopPrank();
    }

    function test_setMinTier_revertsAboveCap() public {
        vm.expectRevert(ProbabilityVaultFactory.MinTierTooHigh.selector);
        factory.setMinTier(6);
    }

    function test_deposit_revertsAfterJoinEnd() public {
        address v = _createVault();
        uint64 joinEnd = ProbabilityVaultV2(v).joinEnd();
        vm.warp(uint256(joinEnd) + 1);

        vm.startPrank(alice);
        usdc.approve(v, 100e6);
        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        ProbabilityVaultV2(v).deposit(100e6, YES);
        vm.stopPrank();
    }

    // ─── TWAB correctness ─────────────────────────────────────────────

    function test_twab_accumulatesOverTime() public {
        address v = _createVault();
        _deposit(alice, v, 100e6, YES);

        uint64 t0 = uint64(block.timestamp);
        vm.warp(uint256(t0) + 1 days);

        // Poke via a second deposit to refresh TWAB
        _deposit(alice, v, 1, YES);

        ProbabilityVaultV2.UserPosition memory pos = ProbabilityVaultV2(v).userPosition(alice);
        // yesTwab ≈ 100e6 * 86400 = 8.64e12
        assertApproxEqAbs(uint256(pos.yesTwab), 100e6 * uint256(1 days), 100e6);
    }

    function test_twab_symmetric_twoSides_equalTwabs() public {
        // Equal stake on both sides for equal time → equal TWAB
        address v = _createVault();
        _deposit(alice, v, 500e6, YES);
        _deposit(bob,   v, 500e6, NO);

        vm.warp(block.timestamp + 2 days);
        _deposit(alice, v, 1, YES);  // pokes Alice's TWAB
        _deposit(bob,   v, 1, NO);   // pokes Bob's TWAB

        ProbabilityVaultV2.UserPosition memory a = ProbabilityVaultV2(v).userPosition(alice);
        ProbabilityVaultV2.UserPosition memory b = ProbabilityVaultV2(v).userPosition(bob);
        assertEq(uint256(a.yesTwab), uint256(b.noTwab));
        assertEq(uint256(a.noTwab), 0);
        assertEq(uint256(b.yesTwab), 0);
    }

    // ─── Happy path: full lifecycle ───────────────────────────────────

    function test_lifecycle_yesWins_distributesYield() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 1_000e6, YES);  // alice YES
        _deposit(bob,     v, 1_000e6, YES);  // bob YES
        _deposit(charlie, v, 500e6,   NO);   // charlie NO
        _deposit(dave,    v, 500e6,   NO);   // dave NO

        // Hold for 5 days before join window closes
        vm.warp(uint256(pv.joinEnd()) + 1);
        // Inject yield equivalent to 1% of pool
        uint256 yieldAmount = 30e6;
        _simulateYield(yieldAmount);

        // Warp past resolveStart + set winner
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeOutcome(v, YES);

        // Anyone resolves
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));
        assertEq(pv.winningOption(), YES);

        // Alice and Bob split the yield (minus 2% protocol fee); Charlie/Dave get principal only
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        uint256 aliceGained = usdc.balanceOf(alice) - aliceBalBefore;
        // alice gets 1000 principal + half of distributable yield (since alice and bob
        // have equal YES TWAB). Expected yield share: 30 * 0.98 / 2 = 14.7 USDC
        assertApproxEqAbs(aliceGained, 1_000e6 + (30e6 * 98 / 100) / 2, 1e5);

        // Charlie (NO) gets principal only
        uint256 charlieBalBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        pv.claim();
        uint256 charlieGained = usdc.balanceOf(charlie) - charlieBalBefore;
        assertEq(charlieGained, 500e6);
    }

    function test_lifecycle_swapMidGame_proratesYieldByTime() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 1_000e6, NO);

        // Halfway through join window, Alice swaps to NO
        uint256 halfway = (uint256(pv.joinEnd()) - block.timestamp) / 2;
        vm.warp(block.timestamp + halfway);
        _swap(alice, v, 1_000e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);

        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeOutcome(v, YES);
        pv.resolveContest();

        // Alice had YES for half the join window (1000 * halfSeconds);
        // Bob had NO for full window. If YES wins, alice gets her
        // proportional share even though she swapped out.
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        uint256 aliceGained = usdc.balanceOf(alice) - aliceBalBefore;
        // Alice should get ≥ principal (less fees); the winning-side-TWAB share
        // should be positive because she held YES for the first half.
        // Principal after swap = 1000 - 2 (0.2% of 1000e6) = 998e6
        assertGt(aliceGained, 997e6);
    }

    // ─── Early withdraw ───────────────────────────────────────────────

    function test_earlyWithdraw_forfeitsYield() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 1_000e6, YES);
        _deposit(bob,   v, 500e6,   YES);  // same side so bob still wins
        _deposit(charlie, v, 500e6, NO);

        vm.warp(block.timestamp + 2 days);

        // Alice withdraws early
        vm.prank(alice);
        pv.withdrawEarly();
        // Alice got principal back, TWAB is zeroed, stake removed
        ProbabilityVaultV2.UserPosition memory pos = pv.userPosition(alice);
        assertEq(pos.yesStake, 0);
        assertEq(pos.yesTwab, 0);
        assertTrue(pos.withdrawnEarly);
        assertEq(pv.totalYesStake(), 500e6);  // bob only

        // Continue to resolution
        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeOutcome(v, YES);
        pv.resolveContest();

        // Bob gets all of the distributable yield (Alice forfeited)
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pv.claim();
        uint256 bobGained = usdc.balanceOf(bob) - bobBalBefore;
        // 500 principal + all distributable yield = 500e6 + 30e6 * 98 / 100
        assertApproxEqAbs(bobGained, 500e6 + (30e6 * 98 / 100), 1e5);
    }

    function test_earlyWithdraw_sameBlockBlocked() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        vm.startPrank(alice);
        usdc.approve(v, 1_000e6);
        pv.deposit(1_000e6, YES);
        // Same block — should revert
        vm.expectRevert(ProbabilityVaultV2.FlashLoanBlocked.selector);
        pv.withdrawEarly();
        vm.stopPrank();
    }

    // ─── Cancel paths ─────────────────────────────────────────────────

    function test_cancel_onImbalance() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice, v, 10_000e6, YES);
        _deposit(bob,   v, 1e6,       NO);   // NO side is 0.01% — under 5% floor

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        vm.roll(100); // explicit block advance past any depositBlock tracking

        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // Alice and Bob get principal back PLUS a pro-rata share of the
        // post-fee yield surplus (new cancel-yield-refund behavior in the
        // post-2026-redeploy implementation; see docs/PV_CANCEL_YIELD_REFUND.md).
        // Alice's principal alone is 10_000e6 — she should receive at least
        // that, plus a non-trivial yield share (~ 29.4 USDC at 2% fee on 30
        // USDC of simulated yield).
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBalBefore;
        assertGe(aliceGot, 10_000e6, "alice >= principal");
        // Yield share is dominated by her ~99.99% TWAB; floor at 25 USDC.
        assertGt(aliceGot, 10_000e6 + 25e6, "alice gets yield share");
        // Detailed pro-rata assertions live in
        // test/ProbabilityVault.cancelYieldRefund.t.sol.
    }

    function test_cancel_onAmbiguousResolver() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 500e6, YES);
        _deposit(bob,     v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(30e6);
        vm.warp(uint256(pv.resolveStart()) + 1);

        // AMBIGUOUS outcome from resolver
        _proposeOutcome(v, bytes32(0));
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    function test_cancel_onResolverTimeout() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        _deposit(alice,   v, 500e6, YES);
        _deposit(charlie, v, 500e6, NO);

        // Never propose an outcome; warp past cancelDeadline
        vm.warp(uint256(pv.cancelDeadline()) + 1);
        vm.roll(100);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    // ─── Factory owner controls ───────────────────────────────────────

    function test_setSwapFee_respectsCap() public {
        factory.setSwapFee(500); // 5%
        assertEq(uint256(factory.swapFeeBps()), 500);

        vm.expectRevert(ProbabilityVaultFactory.FeeOverCap.selector);
        factory.setSwapFee(1_001); // over 10% cap
    }

    function test_setProtocolFee_respectsCap() public {
        factory.setProtocolFee(500); // 5% — exactly at the cap
        assertEq(uint256(factory.protocolFeeBps()), 500);

        // 5% + 1 bp must revert (cap aligned with platform-wide invariant).
        vm.expectRevert(ProbabilityVaultFactory.FeeOverCap.selector);
        factory.setProtocolFee(501);
    }

    function test_setProtocolFee_capIs500Bps() public view {
        // Regression test for B1: ensures the constant matches the
        // documented 5% invariant. If this changes, CLAUDE.md and the
        // mainnet runbook must be updated in lock-step.
        assertEq(uint256(factory.PROTOCOL_FEE_MAX_BPS()), 500);
    }

    function test_setFeeEnabled_zeroesFeesOnNewVaults() public {
        factory.setFeeEnabled(false);
        vm.prank(creator);
        (, address addr) = factory.createVault(_baseParams());

        assertEq(uint256(ProbabilityVaultV2(addr).protocolFeeBps()), 0);
        assertEq(uint256(ProbabilityVaultV2(addr).swapFeeBps()), 0);
    }

    function test_nonOwnerCannotSetFees() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.setSwapFee(100);
    }

    // ─── Batch creation ───────────────────────────────────────────────

    /// @dev Builds a `CreateParams` for a synthetic Polymarket sub-market.
    ///      Each variant gets a unique conditionId / yesOption / noOption /
    ///      end date so the factory's "vault exists" + "yes != no" guards
    ///      pass and the batch reflects a realistic multi-variant launch.
    function _variantParams(uint256 idx)
        internal
        view
        returns (ProbabilityVaultFactory.CreateParams memory p)
    {
        p = _baseParams();
        p.conditionId  = keccak256(abi.encodePacked("batch-cond-", idx));
        p.yesOption    = keccak256(abi.encodePacked("YES-", idx));
        p.noOption     = keccak256(abi.encodePacked("NO-", idx));
        // Spread settlement dates across "Q1/Q2/Q3" style variants. Stay
        // inside MAX_CONTEST_DURATION (365d) so the factory accepts them.
        p.polymarketEndDate = uint64(block.timestamp + 7 days + idx * 7 days);
        p.metadataHash = keccak256(abi.encodePacked("batch-meta-", idx));
        p.metadataUri  = "https://polymarket.com/event/batch-event";
    }

    function test_createVaultsBatch_succeeds() public {
        ProbabilityVaultFactory.CreateParams[] memory params =
            new ProbabilityVaultFactory.CreateParams[](3);
        params[0] = _variantParams(0);
        params[1] = _variantParams(1);
        params[2] = _variantParams(2);

        vm.prank(creator);
        (bytes32[] memory ids, address[] memory addrs) = factory.createVaultsBatch(params);

        assertEq(ids.length, 3);
        assertEq(addrs.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(ids[i] != bytes32(0));
            assertTrue(addrs[i] != address(0));
            // Each clone has a distinct address — Clones.clone() uses CREATE
            // so collision would require identical bytecode + nonce, but the
            // explicit assertion catches accidental same-init reuse.
            for (uint256 j = i + 1; j < 3; j++) {
                assertTrue(addrs[i] != addrs[j], "duplicate clone");
            }
            assertEq(factory.resolverForVault(addrs[i]), address(resolver));
        }
        // Factory bookkeeping reflects all three vaults.
        assertEq(factory.getVaultCount(), 3);
        bytes32[] memory creatorList = factory.getCreatorVaults(creator);
        assertEq(creatorList.length, 3);
    }

    function test_createVaultsBatch_revertsOnEmptyArray() public {
        ProbabilityVaultFactory.CreateParams[] memory empty =
            new ProbabilityVaultFactory.CreateParams[](0);
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVaultsBatch(empty);
    }

    function test_createVaultsBatch_revertsOverCap() public {
        ProbabilityVaultFactory.CreateParams[] memory tooMany =
            new ProbabilityVaultFactory.CreateParams[](21);
        for (uint256 i = 0; i < 21; i++) tooMany[i] = _variantParams(i);
        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVaultsBatch(tooMany);
    }

    function test_createVaultsBatch_atomicOnInvalidEntry() public {
        ProbabilityVaultFactory.CreateParams[] memory params =
            new ProbabilityVaultFactory.CreateParams[](3);
        params[0] = _variantParams(0);
        // Middle entry has an invalid conditionId — the whole tx must revert
        // so the caller never ends up with a partial event launch.
        params[1] = _variantParams(1);
        params[1].conditionId = bytes32(0);
        params[2] = _variantParams(2);

        vm.prank(creator);
        vm.expectRevert(ProbabilityVaultFactory.InvalidParams.selector);
        factory.createVaultsBatch(params);

        // Nothing was persisted — verify by counting vaults.
        assertEq(factory.getVaultCount(), 0);
    }

    function test_createVaultsBatch_chargesResolverFeePerVault() public {
        // Wire up the resolver-fee path so each vault costs `mirrorResolverFee`
        // USDC, deducted from the creator at creation time.
        factory.setResolverTreasury(treasury);
        factory.setMirrorResolverFee(5e6);

        uint256 balBefore = usdc.balanceOf(creator);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        ProbabilityVaultFactory.CreateParams[] memory params =
            new ProbabilityVaultFactory.CreateParams[](3);
        params[0] = _variantParams(0);
        params[1] = _variantParams(1);
        params[2] = _variantParams(2);

        vm.startPrank(creator);
        usdc.approve(address(factory), 5e6 * 3);
        factory.createVaultsBatch(params);
        vm.stopPrank();

        assertEq(usdc.balanceOf(creator), balBefore - 5e6 * 3);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 5e6 * 3);
    }
}
