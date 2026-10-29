// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice ERC20 that reverts on transfer to a designated blocklisted address.
///         Models USDC's blacklist behavior so we can verify the vault's
///         try/catch wrapper around `executeProtocolFeeTransfer` actually
///         skips (rather than reverts) when the treasury can't receive.
contract _BlacklistToken {
    string public constant name = "BlacklistUSDC";
    string public constant symbol = "bUSDC";
    uint8  public constant decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlacklisted;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setBlacklisted(address who, bool flag) external {
        isBlacklisted[who] = flag;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!isBlacklisted[to], "blacklisted");
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!isBlacklisted[to], "blacklisted");
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title E2EYieldPredictionMarketTest
/// @notice Consolidated end-to-end test suite for the latest yield-prediction-
///         market product (ProbabilityVaultV2 + Factory + PolymarketRelayResolver).
///
///         Companion to E2E.allContestTypes.t.sol (contests) and E2E.lottery.t.sol
///         (no-loss lottery). Walks every full lifecycle from createVault →
///         deposit/swap/withdraw → resolve/cancel → claim, asserting the load-
///         bearing economic invariants at each step.
///
///         Coverage matrix:
///           ① Happy path: multi-user deposit, mid-game swap, late deposit, YES wins
///           ② Mirror happy path: NO wins
///           ③ Cancel via resolver-ambiguous outcome
///           ④ Cancel via resolver-relayer 7-day no-propose timeout
///           ⑤ Cancel via vault cancelDeadline (resolveContest after 7-day timeout)
///           ⑥ Cancel via imbalance (minority side below 5% TWAB floor)
///           ⑦ Cancel via empty pool (zero deposits)
///           ⑧ Cancel via factory emergencyCancel
///           ⑨ Early-withdraw forfeits yield, remaining winners receive full pool
///           ⑩ Lazy resolver finalization (24h dispute window auto-finalize)
///           ⑪ Permissionless updateState() auto-transitions JOIN_OPEN → LOCKED
///           ⑫ Late-second deposit at joinEnd-1 still claims
///           ⑬ impliedProbability tracks live pool through the lifecycle
///           ⑭ Blacklisted treasury → ProtocolFeeSkipped, finalize still succeeds
///           ⑮ Conservation invariant: principal + simulated yield == sum of all
///              participant + treasury net balance changes (no tokens trapped)
///           ⑯ Double-claim blocked
///           ⑰ Multiple parallel vaults resolve independently
contract E2EYieldPredictionMarketTest is Test {
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

    bytes32 public constant YES          = keccak256("YES");
    bytes32 public constant NO           = keccak256("NO");
    bytes32 public constant CONDITION_ID = keccak256("e2e-ypm-cid");

    uint64 public polyEnd;

    /// @dev Snapshot struct keeps balance reads off the stack — using locals
    ///      directly inside the long E2E flows hits via_ir's stack-too-deep
    ///      ceiling on Solc 0.8.20.
    struct Snap {
        uint256 alice;
        uint256 bob;
        uint256 charlie;
        uint256 dave;
        uint256 treasury;
    }

    function _snap() internal view returns (Snap memory s) {
        s.alice    = usdc.balanceOf(alice);
        s.bob      = usdc.balanceOf(bob);
        s.charlie  = usdc.balanceOf(charlie);
        s.dave     = usdc.balanceOf(dave);
        s.treasury = usdc.balanceOf(treasury);
    }

    function _delta(uint256 nowBal, uint256 startBal) internal pure returns (int256) {
        return int256(nowBal) - int256(startBal);
    }

    // ─── Setup ─────────────────────────────────────────────────────────

    function setUp() public {
        vm.warp(1_800_000_000);
        polyEnd = uint64(block.timestamp + 7 days);

        usdc = new MockERC20("USDC", "USDC", 6);
        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));

        identityRegistry = new IdentityRegistry();
        address[6] memory all = [alice, bob, charlie, dave, eve, creator];
        for (uint256 i = 0; i < all.length; i++) {
            identityRegistry.setTier(all[i], 2);
            usdc.mint(all[i], 1_000_000e6);
        }

        impl = new ProbabilityVaultV2();
        factory = new ProbabilityVaultFactory(
            address(impl),
            address(yieldVault),
            address(0),
            address(identityRegistry),
            treasury
        );
        // Factory needs YieldVault ownership to register clones as trusted
        // depositors (audit H-01 mitigation — see ProbabilityVaultFactory L249).
        // YieldVault is Ownable2Step so the transfer must be accepted by the
        // factory before it takes effect.
        yieldVault.transferOwnership(address(factory));
        vm.prank(address(factory));
        yieldVault.acceptOwnership();

        resolver = new PolymarketRelayResolver(address(factory), address(usdc));
    }

    // ─── Shared helpers ────────────────────────────────────────────────

    function _baseParams()
        internal
        view
        returns (ProbabilityVaultFactory.CreateParams memory)
    {
        return ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: polyEnd,
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       CONDITION_ID,
            metadataHash:      keccak256("e2e-ypm"),
            metadataUri:       "ipfs://e2e-ypm",
            resolver:          address(resolver)
        });
    }

    function _createVault() internal returns (address vault) {
        vm.prank(creator);
        (, vault) = factory.createVault(_baseParams());
    }

    function _deposit(address user, address vault, uint256 amount, bytes32 side) internal {
        vm.startPrank(user);
        usdc.approve(vault, amount);
        ProbabilityVaultV2(vault).deposit(amount, side);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _swap(address user, address vault, uint256 amount, bytes32 newSide) internal {
        vm.prank(user);
        ProbabilityVaultV2(vault).swap(amount, newSide);
        vm.roll(block.number + 1);
    }

    /// @dev Mints `amount` USDC to the YieldVault and patches its strategy
    ///      accounting so subsequent withdraws return principal + yield. Mirrors
    ///      the helper in ProbabilityVault.t.sol / .security.t.sol.
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

    function _proposeAndPassWindow(address vault, PolymarketRelayResolver.Outcome outcome)
        internal
    {
        bytes32 key = bytes32(uint256(uint160(vault)));
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        resolver.propose(key, outcome);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ════════════════════════════════════════════════════════════════════
    // ① Full lifecycle — YES wins (multi-user, mid-game swap, late deposit)
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_fullCycle_yesWins_multiUser_swapsAndLateDeposit() public {
        address vault = _createVault();
        Snap memory startSnap = _snap();

        _runFullCycleYesPath(vault);
        _assertFullCycleYesPath(vault, startSnap);
    }

    function _runFullCycleYesPath(address vault) internal {
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        // T0: alice 5000 YES, bob 3000 NO, charlie 2000 YES → 70% implied YES.
        _deposit(alice,   vault, 5_000e6, YES);
        _deposit(bob,     vault, 3_000e6, NO);
        _deposit(charlie, vault, 2_000e6, YES);
        assertEq(pv.impliedProbabilityYes(), 7000);

        // T+2d: bob swaps 1000 NO → YES (0.2% fee → bob principal -2 USDC).
        vm.warp(block.timestamp + 2 days);
        _swap(bob, vault, 1_000e6, YES);
        assertEq(pv.userPosition(bob).principal, 3_000e6 - 2e6);
        // YES = 7000 + 998 = 7998, NO = 3000 - 1000 = 2000 → 7998/9998 ≈ 7999 bps.
        assertApproxEqAbs(pv.impliedProbabilityYes(), 8000, 1);

        // T+4d: dave joins late on NO; T+joinEnd-1: charlie tops up YES.
        vm.warp(block.timestamp + 2 days);
        _deposit(dave, vault, 3_000e6, NO);
        vm.warp(uint256(pv.joinEnd()) - 1);
        _deposit(charlie, vault, 1_000e6, YES);

        // Yield + resolve.
        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(100e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));
        assertEq(pv.winningOption(), YES);
        assertEq(uint256(pv.distributableYield()), 98e6); // 100e6 × 0.98

        // Claims.
        vm.prank(alice);   pv.claim();
        vm.prank(bob);     pv.claim();
        vm.prank(charlie); pv.claim();
        vm.prank(dave);    pv.claim();
    }

    function _assertFullCycleYesPath(address vault, Snap memory s) internal view {
        // Dave (NO loser) walked out with exactly principal returned.
        assertEq(usdc.balanceOf(dave), s.dave);

        // Alice + Charlie (YES winners) profited.
        assertGt(usdc.balanceOf(alice),   s.alice);
        assertGt(usdc.balanceOf(charlie), s.charlie);

        // Bob hedged 2/6 days into the contest (1000 NO→YES, 2 USDC swap fee).
        // His YES TWAB ≈ 998 × 4 days vs total YES TWAB ≈ 3.94B stake-seconds
        // → bob gets ~8.6% of the 98 USDC distributable yield, minus 2 USDC
        // swap fee = +6.6 USDC net. Allow a wide ±15 USDC band so the assertion
        // is robust to minor TWAB-rounding shifts.
        int256 bobDelta = _delta(usdc.balanceOf(bob), s.bob);
        assertLt(bobDelta,  int256(15e6));
        assertGt(bobDelta, -int256(15e6));
        // But bob must net out positive (he held a winning YES position).
        assertGt(bobDelta, int256(0));

        // Treasury gained protocol fee (2 USDC) + swap fee (2 USDC) = 4 USDC.
        // Tolerate 1 wei share-rounding noise.
        assertApproxEqAbs(usdc.balanceOf(treasury) - s.treasury, 4e6, 1);

        // Conservation: sum of all deltas == simulated yield (100 USDC).
        int256 sumDeltas =
            _delta(usdc.balanceOf(alice),   s.alice)   +
            _delta(usdc.balanceOf(bob),     s.bob)     +
            _delta(usdc.balanceOf(charlie), s.charlie) +
            _delta(usdc.balanceOf(dave),    s.dave)    +
            _delta(usdc.balanceOf(treasury), s.treasury);
        assertApproxEqAbs(sumDeltas, int256(100e6), 2);

        // Up to a few wei may remain in the vault from share-rounding residue.
        assertLe(usdc.balanceOf(vault), 2);
    }

    // ════════════════════════════════════════════════════════════════════
    // ② Mirror happy path — NO wins
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_fullCycle_noWins_mirroredHappyPath() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 2_000e6, YES);
        _deposit(bob,   vault, 4_000e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(60e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.NO_WIN);
        pv.resolveContest();

        assertEq(pv.winningOption(), NO);
        // 60e6 yield × 98% = 58.8e6 distributable.
        assertEq(uint256(pv.distributableYield()), 58_800_000);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        // Alice on YES (lost) gets exactly principal.
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, 2_000e6);

        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        // Bob is the only NO holder → gets principal + entire distributable yield.
        assertEq(usdc.balanceOf(bob) - bobBalBefore, 4_000e6 + 58_800_000);
    }

    // ════════════════════════════════════════════════════════════════════
    // ③ Cancel — ambiguous resolver outcome
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_cancel_ambiguousOutcome_allRefunded() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 1_000e6, YES);
        _deposit(bob,   vault, 1_000e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(40e6); // surplus exists but no winner can be picked
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.AMBIGUOUS);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // Cancel-with-yield-refund: the orphan yield (40 USDC) is reserved for
        // depositors pro-rata — NOT routed to treasury — and no protocol fee is
        // taken on a cancelled market.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0, "no treasury fee on cancel");
        assertApproxEqAbs(uint256(pv.cancelYieldPool()), 40e6, 100, "full surplus reserved");

        // Equal stake + equal duration → each walks away with principal + ~half
        // the surplus (~20 USDC).
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;
        assertGe(aliceGot, 1_000e6, "alice principal");
        assertApproxEqAbs(aliceGot, 1_000e6 + 20e6, 1e6, "alice principal + ~half surplus");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        uint256 bobGot = usdc.balanceOf(bob) - bobBefore;
        assertGe(bobGot, 1_000e6, "bob principal");
        assertApproxEqAbs(bobGot, 1_000e6 + 20e6, 1e6, "bob principal + ~half surplus");
    }

    // ════════════════════════════════════════════════════════════════════
    // ④ Cancel — resolver 7-day timeout (relayer never proposes)
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_cancel_resolverNeverProposes_forceTimeoutThenVaultRefunds() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 1_500e6, YES);
        _deposit(bob,   vault, 1_500e6, NO);

        // Advance past the resolver's 7-day SETTLEMENT_TIMEOUT and force-cancel.
        bytes32 key = bytes32(uint256(uint160(vault)));
        vm.warp(uint256(polyEnd) + 7 days + 1);
        resolver.forceTimeoutCancel(key);

        // Now warp inside the vault's own (longer) cancelDeadline so the
        // resolver-cancel propagates as bytes32(0) → vault cancels-and-refunds.
        // But we're already past polyEnd + 7d == cancelDeadline. Vault will
        // hit the `block.timestamp >= cancelDeadline` branch first → cancel
        // by vault timeout. Either way the user-visible behavior is the same.
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        assertEq(usdc.balanceOf(alice) - aliceBefore, 1_500e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        assertEq(usdc.balanceOf(bob) - bobBefore, 1_500e6);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑤ Cancel — vault cancelDeadline before resolver responds
    // ════════════════════════════════════════════════════════════════════
    //
    // Distinct from ④: nobody proposes anything, but resolveContest is called
    // exactly at cancelDeadline. The vault's own timeout branch fires first.

    function test_e2e_cancel_vaultDeadline_resolverSilent() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 800e6, YES);
        _deposit(bob,   vault, 700e6, NO);

        // Warp past cancelDeadline (= polyEnd + CANCEL_TIMEOUT = polyEnd + 7d).
        vm.warp(uint256(pv.cancelDeadline()) + 1);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        assertEq(usdc.balanceOf(alice) - aliceBefore, 800e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        assertEq(usdc.balanceOf(bob) - bobBefore, 700e6);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑥ Cancel — imbalance below 5% minority floor
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_cancel_imbalanceBelowFloor_allRefunded() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        // 96% YES, 4% NO → minority below 5% floor → cancel.
        _deposit(alice, vault, 9_600e6, YES);
        _deposit(bob,   vault, 400e6,   NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        // Imbalance cancel refunds principal in full PLUS each side's pro-rata
        // share of the 20 USDC surplus (cancel-yield-refund, no fee). By
        // combined TWAB: alice 96% → ~19.2 USDC, bob 4% → ~0.8 USDC.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;
        assertGe(aliceGot, 9_600e6, "alice principal");
        assertApproxEqAbs(aliceGot, 9_600e6 + 19_200_000, 100_000, "alice principal + 96% surplus");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        uint256 bobGot = usdc.balanceOf(bob) - bobBefore;
        assertGe(bobGot, 400e6, "bob principal");
        assertApproxEqAbs(bobGot, 400e6 + 800_000, 100_000, "bob principal + 4% surplus");
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑦ Cancel — empty pool (no deposits)
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_cancel_emptyPool_finalizesAsCancelled() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑧ Cancel — factory emergencyCancelVault
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_emergencyCancel_factoryRefundsAllParticipants() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 2_000e6, YES);
        _deposit(bob,   vault, 1_000e6, NO);

        bytes32 vaultId = factory.getCreatorVaults(creator)[0];
        factory.emergencyCancelVault(vaultId);
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pv.claim();
        assertEq(usdc.balanceOf(alice) - aliceBefore, 2_000e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        assertEq(usdc.balanceOf(bob) - bobBefore, 1_000e6);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑨ Early-withdraw forfeits yield → remaining winners receive full pool
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_earlyWithdraw_forfeitsYield_remainingWinnerKeepsAll() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice,   vault, 500e6, YES);
        _deposit(bob,     vault, 500e6, YES);
        _deposit(charlie, vault, 500e6, NO);

        // T+2d: alice exits early, forfeiting her YES TWAB.
        vm.warp(block.timestamp + 2 days);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pv.withdrawEarly();
        assertEq(usdc.balanceOf(alice) - aliceBefore, 500e6);

        // Alice cannot claim afterwards.
        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(50e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.NothingToWithdraw.selector);
        pv.claim();

        // Bob (only remaining YES winner) gets principal + ~all distributable yield.
        // distributable = 50e6 * 0.98 = 49e6. Bob holds 100% of YES TWAB post-withdraw.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        assertApproxEqAbs(usdc.balanceOf(bob) - bobBefore, 500e6 + 49e6, 1e5);

        // Charlie on losing side gets exactly principal.
        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(charlie); pv.claim();
        assertEq(usdc.balanceOf(charlie) - charlieBefore, 500e6);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑩ Lazy resolver finalization — no explicit finalize tx required
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_lazyFinalize_disputeWindowExpiresWithoutDispute() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 1_000e6, YES);
        _deposit(bob,   vault, 1_000e6, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);

        // Propose YES *exactly* at the grace boundary, then warp past dispute
        // window. No `finalize` call is made — the resolver's `resolve()` view
        // lazy-finalizes inside resolveContest.
        bytes32 key = bytes32(uint256(uint160(vault)));
        vm.warp(uint256(polyEnd) + 12 hours + 1);
        resolver.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);
        // Advance past dispute window AND vault resolveStart simultaneously.
        vm.warp(block.timestamp + 24 hours + 1);
        if (block.timestamp < uint256(pv.resolveStart())) {
            vm.warp(uint256(pv.resolveStart()) + 1);
        }

        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));
        assertEq(pv.winningOption(), YES);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑪ Permissionless updateState() auto-transitions JOIN_OPEN → LOCKED
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_permissionlessUpdateState_lockJoinAtJoinEnd() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 1_000e6, YES);
        _deposit(bob,   vault, 1_000e6, NO);

        // Pre-joinEnd: state is JOIN_OPEN.
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.JOIN_OPEN));

        vm.warp(uint256(pv.joinEnd()) + 1);

        // A random EOA pokes updateState() — vault auto-transitions to LOCKED.
        vm.prank(eve);
        pv.updateState();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.LOCKED));

        // Deposits now revert. Note: the state guard (InvalidState) fires
        // before the time guard (WindowClosed) because the auto-transition
        // already moved state to LOCKED.
        vm.startPrank(alice);
        usdc.approve(vault, 100e6);
        vm.expectRevert(ProbabilityVaultV2.InvalidState.selector);
        pv.deposit(100e6, YES);
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑫ Late-second deposit at joinEnd-1
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_lateDeposit_oneSecondBeforeJoinEnd_succeeds() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 1_000e6, YES);

        vm.warp(uint256(pv.joinEnd()) - 1);
        _deposit(bob, vault, 1_000e6, NO);

        // Bob's TWAB is tiny (1 second) but his principal is locked in.
        ProbabilityVaultV2.UserPosition memory bobPos = pv.userPosition(bob);
        assertEq(bobPos.principal, 1_000e6);
        assertEq(bobPos.noStake, 1_000e6);

        // Going forward he can still claim principal even on the losing side.
        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        // Bob's 1-second TWAB is far below the 5% floor → the market cancels on
        // imbalance. He gets his full principal back PLUS a negligible pro-rata
        // share of the surplus proportional to that tiny TWAB (cancel-yield-
        // refund). Principal is never lost; the yield dust is sub-USDC.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); pv.claim();
        uint256 bobGot = usdc.balanceOf(bob) - bobBefore;
        assertGe(bobGot, 1_000e6, "principal returned in full");
        assertApproxEqAbs(bobGot, 1_000e6, 1e6, "principal + negligible TWAB-weighted dust");
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑬ Implied-probability oracle reads track live pool
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_impliedProbability_tracksLivePoolThroughLifecycle() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        // Empty pool → 0.
        assertEq(pv.impliedProbabilityYes(), 0);

        _deposit(alice, vault, 7_000e6, YES);
        _deposit(bob,   vault, 3_000e6, NO);
        assertEq(pv.impliedProbabilityYes(), 7000); // 70%
        (uint256 yBps, uint256 nBps) = pv.poolRatio();
        assertEq(yBps, 7000);
        assertEq(nBps, 3000);

        // Bob hedges → ratio shifts.
        vm.warp(block.timestamp + 1 days);
        _swap(bob, vault, 1_500e6, YES);
        // YES gained 1500 * 0.998 = 1497, NO lost 1500. New ratio:
        // (7000 + 1497) / (7000 + 1497 + 3000 - 1500) = 8497 / 9997 ≈ 8499
        uint256 implied = pv.impliedProbabilityYes();
        assertGe(implied, 8400);
        assertLe(implied, 8600);

        // After joinEnd the ratio freezes (no more deposits).
        vm.warp(uint256(pv.joinEnd()) + 1);
        uint256 frozenRatio = pv.impliedProbabilityYes();
        vm.warp(uint256(pv.resolveStart()) + 1);
        assertEq(pv.impliedProbabilityYes(), frozenRatio);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑭ Blacklisted treasury — fee transfer skipped, finalize still succeeds
    // ════════════════════════════════════════════════════════════════════

    /// @dev Holder for the fresh blacklist-token-wired deployment so the test
    ///      function itself stays tiny (avoids stack-too-deep under via_ir).
    struct BlacklistRig {
        _BlacklistToken bToken;
        YieldVault yv;
        ProbabilityVaultFactory fac;
        PolymarketRelayResolver res;
        address vault;
    }

    function _deployBlacklistRig() internal returns (BlacklistRig memory r) {
        r.bToken = new _BlacklistToken();
        r.bToken.mint(alice,   100_000e6);
        r.bToken.mint(bob,     100_000e6);
        r.bToken.mint(creator, 1_000e6);

        r.yv = new YieldVault();
        r.yv.addStrategy(address(0));

        IdentityRegistry idr2 = new IdentityRegistry();
        idr2.setTier(alice, 2);
        idr2.setTier(bob,   2);
        idr2.setTier(creator, 2);

        ProbabilityVaultV2 impl2 = new ProbabilityVaultV2();
        r.fac = new ProbabilityVaultFactory(
            address(impl2), address(r.yv), address(0), address(idr2), treasury
        );
        r.yv.transferOwnership(address(r.fac));
        vm.prank(address(r.fac));
        r.yv.acceptOwnership();
        r.res = new PolymarketRelayResolver(address(r.fac), address(r.bToken));

        ProbabilityVaultFactory.CreateParams memory p =
            ProbabilityVaultFactory.CreateParams({
                depositToken:      address(r.bToken),
                polymarketEndDate: polyEnd,
                joinEnd:           0,
                resolveStart:      0,
                cancelDeadline:    0,
                yesOption:         YES,
                noOption:          NO,
                conditionId:       keccak256("blacklist-treasury-test"),
                metadataHash:      keccak256("blt"),
                metadataUri:       "ipfs://blt",
                resolver:          address(r.res)
            });
        vm.prank(creator);
        (, r.vault) = r.fac.createVault(p);
    }

    function _depositBlacklist(BlacklistRig memory r, address user, uint256 amt, bytes32 side)
        internal
    {
        vm.startPrank(user);
        r.bToken.approve(r.vault, amt);
        ProbabilityVaultV2(r.vault).deposit(amt, side);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _patchYieldVault(YieldVault yv, address token, uint256 amount) internal {
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yv), totalDepositedSlot));
        vm.store(address(yv), totalDepositedSlot, bytes32(cur + amount));
        bytes32 innerSlot = keccak256(abi.encode(token, uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yv), tokenDepositSlot));
        vm.store(address(yv), tokenDepositSlot, bytes32(cur2 + amount));
    }

    function _sawProtocolFeeSkipped() internal returns (bool) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 skipTopic = keccak256("ProtocolFeeSkipped(uint256,address,string)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == skipTopic) return true;
        }
        return false;
    }

    function test_e2e_blacklistedTreasury_protocolFeeSkipped_finalizationSucceeds()
        public
    {
        BlacklistRig memory r = _deployBlacklistRig();
        // After this point, every ERC20.transfer to `treasury` reverts — the
        // vault's try/catch must catch it and emit ProtocolFeeSkipped without
        // aborting finalization.
        r.bToken.setBlacklisted(treasury, true);

        _depositBlacklist(r, alice, 5_000e6, YES);
        _depositBlacklist(r, bob,   5_000e6, NO);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(r.vault);
        // Mint + patch yield directly into the fresh YieldVault.
        r.bToken.mint(address(r.yv), 100e6);
        _patchYieldVault(r.yv, address(r.bToken), 100e6);

        vm.warp(uint256(pv.joinEnd()) + 1);
        vm.warp(uint256(pv.resolveStart()) + 1);

        bytes32 key = bytes32(uint256(uint160(r.vault)));
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        r.res.propose(key, PolymarketRelayResolver.Outcome.YES_WIN);
        vm.warp(block.timestamp + 24 hours + 1);

        // Resolve — protocol fee transfer reverts; vault catches and finalizes.
        vm.recordLogs();
        pv.resolveContest();
        assertTrue(
            _sawProtocolFeeSkipped(),
            "ProtocolFeeSkipped should fire on blacklisted treasury"
        );
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // Alice (winner) still claims principal + her share of yield.
        // Crucially: claim does not revert — finalization survived the catch.
        uint256 aliceBalBefore = r.bToken.balanceOf(alice);
        vm.prank(alice);
        pv.claim();
        assertGe(r.bToken.balanceOf(alice) - aliceBalBefore, 5_000e6);
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑮ Conservation invariant — explicit single-test assertion
    // ════════════════════════════════════════════════════════════════════
    //
    // Stronger version of the embedded check in test ① — runs with even
    // distribution and asserts to-the-wei conservation.

    function test_e2e_conservation_invariant_yesPath_noSwapFees() public {
        address vault = _createVault();
        Snap memory s = _snap();

        _runConservationYesPath(vault);

        // No swap fees this run; conservation must hold to the wei except for
        // TWAB integer-division residue (≤ #winners wei).
        int256 sumDelta =
            _delta(usdc.balanceOf(alice),    s.alice)    +
            _delta(usdc.balanceOf(bob),      s.bob)      +
            _delta(usdc.balanceOf(charlie),  s.charlie)  +
            _delta(usdc.balanceOf(treasury), s.treasury);
        assertApproxEqAbs(sumDelta, int256(200e6), 2);
        // Up to a few wei may remain in the vault from share-rounding residue.
        assertLe(usdc.balanceOf(vault), 2);
    }

    function _runConservationYesPath(address vault) internal {
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice,   vault, 4_000e6, YES);
        _deposit(bob,     vault, 4_000e6, NO);
        _deposit(charlie, vault, 2_000e6, YES);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(200e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        vm.prank(alice);   pv.claim();
        vm.prank(bob);     pv.claim();
        vm.prank(charlie); pv.claim();
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑯ Double-claim blocked
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_doubleClaim_blocked() public {
        address vault = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(alice, vault, 1_000e6, YES);
        _deposit(bob,   vault, 1_000e6, NO);
        vm.warp(uint256(pv.joinEnd()) + 1);
        _simulateYield(20e6);
        vm.warp(uint256(pv.resolveStart()) + 1);
        _proposeAndPassWindow(vault, PolymarketRelayResolver.Outcome.YES_WIN);
        pv.resolveContest();

        vm.prank(alice); pv.claim();
        vm.prank(alice);
        vm.expectRevert(ProbabilityVaultV2.AlreadyClaimed.selector);
        pv.claim();
    }

    // ════════════════════════════════════════════════════════════════════
    // ⑰ Multiple parallel vaults — independent lifecycles
    // ════════════════════════════════════════════════════════════════════

    function test_e2e_multipleVaults_parallelLifecycles_independent() public {
        // Vault A (default condition).
        address vaultA = _createVault();

        // Vault B with a distinct conditionId (factory requires uniqueness only
        // at the vaultId level — unique creator+timestamp+nonce — so two vaults
        // backing the same Polymarket market are fine in principle, but
        // distinct condition makes the resolver behavior unambiguous).
        ProbabilityVaultFactory.CreateParams memory pB = _baseParams();
        pB.conditionId   = keccak256("e2e-ypm-cid-B");
        pB.metadataHash  = keccak256("e2e-ypm-B");
        vm.prank(creator);
        (, address vaultB) = factory.createVault(pB);

        ProbabilityVaultV2 pvA = ProbabilityVaultV2(vaultA);
        ProbabilityVaultV2 pvB = ProbabilityVaultV2(vaultB);

        // Different deposit profiles per vault.
        _deposit(alice,   vaultA, 1_000e6, YES);
        _deposit(bob,     vaultA, 1_000e6, NO);
        _deposit(charlie, vaultB, 2_000e6, YES);
        _deposit(dave,    vaultB, 2_000e6, NO);

        vm.warp(uint256(pvA.joinEnd()) + 1);
        _simulateYield(50e6); // shared yield-vault accrues for both

        // Both resolvers can be proposed once we're past polyEnd + GRACE_WINDOW
        // (12h). Propose first, then advance through the dispute window AND
        // through pvA.resolveStart() so resolveContest reads as final.
        bytes32 keyA = bytes32(uint256(uint160(vaultA)));
        bytes32 keyB = bytes32(uint256(uint160(vaultB)));
        vm.warp(uint256(polyEnd) + 12 hours + 1);
        resolver.propose(keyA, PolymarketRelayResolver.Outcome.YES_WIN);
        resolver.propose(keyB, PolymarketRelayResolver.Outcome.NO_WIN);
        // Skip the 24h dispute window AND past pvA.resolveStart (= polyEnd+37h+1).
        vm.warp(uint256(pvA.resolveStart()) + 1);

        pvA.resolveContest();
        pvB.resolveContest();

        assertEq(pvA.winningOption(), YES);
        assertEq(pvB.winningOption(), NO);

        // Independent claims — alice (vaultA YES) and dave (vaultB NO) both win.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); pvA.claim();
        assertGt(usdc.balanceOf(alice) - aliceBefore, 1_000e6); // principal + yield share

        uint256 daveBefore = usdc.balanceOf(dave);
        vm.prank(dave); pvB.claim();
        assertGt(usdc.balanceOf(dave) - daveBefore, 2_000e6); // principal + yield share
    }
}
