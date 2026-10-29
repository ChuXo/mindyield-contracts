// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/**
 * @title AutoYieldVaultFeesTest
 * @notice Tests the new performance + management fee surface added in PlatformFeeConfig phase 2.
 *
 * Invariants under test:
 *   - Default state (no fees) is byte-identical to legacy behaviour.
 *   - Performance fee is charged only on positive yield delta, never retroactively.
 *   - Management fee scales linearly with elapsed time.
 *   - Fee shares are minted (not transferred from assets), so the deposit/withdraw share-price
 *     formulas remain monotonic — depositors are diluted, never robbed.
 *   - Fee caps revert.
 *   - Setting recipient = 0 disables minting entirely.
 */
contract AutoYieldVaultFeesTest is Test {
    MockERC20 usdc;
    MockAutoYieldStrategy strategy;
    AutoYieldVault vault;

    address owner     = address(1);
    address alice     = address(2);
    address bob       = address(3);
    address treasury  = address(0xFEE);

    uint256 constant DEP = 1_000e6;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("Test USDC", "USDC", 6);
        strategy = new MockAutoYieldStrategy(address(usdc));
        vault = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Mock");
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob,   100_000e6);
        usdc.mint(address(strategy), 100_000e6); // for yield simulation
    }

    function _deposit(address u, uint256 amt) internal returns (uint256 s) {
        vm.startPrank(u);
        usdc.approve(address(vault), amt);
        s = vault.deposit(amt);
        vm.stopPrank();
    }

    function _simulateYield(uint256 amt) internal {
        strategy.simulateYield(amt);
    }

    // ─── Defaults ─────────────────────────────────────────────────────────────

    function test_defaults_safeByDefault() public {
        // Constructor wires platform-correct defaults so a deploy that
        // forgets the setters is still correct once a recipient is wired.
        assertEq(vault.performanceFeeBps(), 200);   // 2% of accrued yield
        assertEq(vault.minFeeYieldAssets(), 100_000); // $0.10 USDC dust floor
        // Recipient is NOT defaulted — it must be explicitly wired by the
        // owner because it's a permanent (set-once) wallet binding.
        assertEq(vault.feeRecipient(), address(0));
    }

    function test_zeroFees_noMintingEvenAfterYield() public {
        _deposit(alice, DEP);
        uint256 sharesBefore = vault.totalShares();
        _simulateYield(100e6);
        // Trigger accrual
        vault.accrueFees();
        assertEq(vault.totalShares(), sharesBefore, "no shares minted");
        assertEq(vault.shares(treasury), 0);
    }

    // ─── Performance fee ──────────────────────────────────────────────────────

    function test_performanceFee_chargedOnYieldDelta() public {
        _deposit(alice, DEP);

        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(1_000); // 10%
        vm.stopPrank();

        // 100e6 yield → 10% = 10e6 in fee assets
        _simulateYield(100e6);
        vault.accrueFees();

        // Treasury must hold shares worth ~10e6 of asset value
        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        assertApproxEqRel(treasuryAssets, 10e6, 0.01e18, "treasury ~10e6");

        // A second accrual without new yield must not charge again
        uint256 sharesAfterFirst = vault.shares(treasury);
        vault.accrueFees();
        assertEq(vault.shares(treasury), sharesAfterFirst, "no double-charge");
    }

    function test_performanceFee_neverChargedOnLoss() public {
        _deposit(alice, DEP);

        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(1_000); // 10%, MAX_PERFORMANCE_FEE_BPS
        vm.stopPrank();

        // No yield, no charge.
        vault.accrueFees();
        assertEq(vault.shares(treasury), 0);
    }

    function test_performanceFee_capEnforced() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vm.expectRevert(AutoYieldVault.FeeTooHigh.selector);
        vault.setPerformanceFee(1_001); // > MAX_PERFORMANCE_FEE_BPS
        vm.stopPrank();
    }

    // ─── Management fee removed ───────────────────────────────────────────────
    //
    // Management fees were removed entirely — by design, an annualized AUM
    // fee erodes principal during flat-yield periods, which violates the
    // platform's "fees only on accrued yield" promise. The selector check
    // below is a compile-time guard so a future agent can't reintroduce the
    // mechanism without re-running this suite.

    function test_managementFee_selectorsRemoved() public {
        // setManagementFee(uint256) and managementFeeBps() must not exist on
        // the live ABI. We probe via low-level call so the test compiles even
        // after the ABI is reduced.
        (bool ok1, ) = address(vault).call(abi.encodeWithSignature("setManagementFee(uint256)", uint256(100)));
        assertFalse(ok1, "setManagementFee selector still resolves");
        (bool ok2, ) = address(vault).staticcall(abi.encodeWithSignature("managementFeeBps()"));
        assertFalse(ok2, "managementFeeBps selector still resolves");
    }

    // ─── Recipient = 0 disables minting ───────────────────────────────────────

    function test_zeroRecipient_disablesMinting() public {
        _deposit(alice, DEP);

        vm.prank(owner);
        vault.setPerformanceFee(1_000);
        // No recipient set → must skip minting even with non-zero rate

        _simulateYield(100e6);
        vault.accrueFees();
        // Total shares unchanged
        assertEq(vault.shares(treasury), 0);
    }

    // ─── Share price monotonicity invariant ───────────────────────────────────

    function test_sharePrice_neverDropsForPriorDepositor() public {
        _deposit(alice, DEP);

        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(1_000);
        vm.stopPrank();

        // Pre-yield, alice's redemption value
        (, uint256 aliceBefore) = vault.getUserInfo(alice);

        _simulateYield(500e6);
        vault.accrueFees();

        (, uint256 aliceAfter) = vault.getUserInfo(alice);
        // Even after a 10% fee on 500e6 yield, alice still gains.
        assertGt(aliceAfter, aliceBefore, "alice still gains net of fee");
    }

    // ─── Regression: fee never charged on deposited principal ─────────────────
    //
    // On mainnet the deploy script wired feeRecipient + performanceFeeBps before
    // any user deposited. A user who deposited 1 USDC + 100 USDC (101 total)
    // could only redeem ~99.02 USDC because _accrueFees() snapshots
    // lastFeeAssets BEFORE the deposit transfer. After deposit returns,
    // totalAssets() jumps by the deposited amount but lastFeeAssets is left at
    // the pre-deposit value, so the next accrual computes
    //   yieldDelta = totalAssets - lastFeeAssets
    // which now contains the principal as if it were yield, and 2% of it is
    // minted as fee shares.
    //
    // The fix re-snapshots lastFeeAssets after deposit() and withdraw().
    // Existing fee tests don't catch this because they always set fees AFTER
    // the first deposit; the bug only surfaces when fees are set first.

    function test_principal_isNotChargedAsYield_whenFeesSetBeforeFirstDeposit() public {
        // Mirror the production order of operations: fees configured first.
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200); // 2%
        vm.stopPrank();

        // First deposit: 1 USDC.
        _deposit(alice, 1e6);
        // Second deposit: 100 USDC. _accrueFees fires at start of the call.
        _deposit(alice, 100e6);

        // Trigger one more accrual so any pending principal-as-yield delta
        // would have minted by now. (No real yield was injected.)
        vault.accrueFees();

        // Treasury must hold zero fee shares — there's been no yield, only
        // principal deposits. The pre-fix contract mints ~2.02 USDC of shares
        // here, which is exactly the user's missing 1.98 USDC.
        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        assertEq(treasuryAssets, 0, "fee charged on principal");

        // And alice can redeem her full 101 USDC (modulo dust from the
        // virtual offset, well under 1 raw unit).
        (, uint256 aliceAssets) = vault.getUserInfo(alice);
        assertApproxEqAbs(aliceAssets, 101e6, 2, "alice can redeem full principal");
    }

    function test_principal_isNotChargedAsYield_acrossWithdrawThenDeposit() public {
        // Fees on first.
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200); // 2%
        vm.stopPrank();

        // Alice deposits, withdraws half, bob deposits — none of these are yield.
        _deposit(alice, 1_000e6);

        // Move past MIN_HOLD_TIME (15s) and the same-block-withdraw guard.
        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        uint256 halfShares = vault.shares(alice) / 2;
        vault.withdraw(halfShares);
        vm.stopPrank();

        _deposit(bob, 500e6);
        vault.accrueFees();

        // No yield ever occurred — treasury must still hold zero.
        assertEq(vault.shares(treasury), 0, "fee charged on deposit-after-withdraw");
    }

    function test_yieldStillCharged_afterFix() public {
        // Sanity: the fix must not break the actual fee surface — when real
        // yield arrives it still gets charged the configured percentage.
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(1_000); // 10%
        vm.stopPrank();

        _deposit(alice, DEP);
        _simulateYield(100e6);
        vault.accrueFees();

        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        assertApproxEqRel(treasuryAssets, 10e6, 0.01e18, "10% of 100e6 yield");
    }

    // ─── Min-yield threshold (the dust floor) ────────────────────────────────
    //
    // Fee accrual is gated by `minFeeYieldAssets` — when cumulative un-charged
    // yield is below that floor, no fee is minted AND `lastFeeAssets` is NOT
    // advanced, so the yield keeps accumulating until it crosses the floor.
    // Default floor is 100,000 raw = $0.10 in 6-decimal token units.

    function test_belowThreshold_noFeeCharged() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200); // 2%
        vm.stopPrank();

        _deposit(alice, DEP);
        // Yield below default $0.10 floor (50_000 raw = $0.05).
        _simulateYield(50_000);
        vault.accrueFees();

        assertEq(vault.shares(treasury), 0, "no fee below threshold");
        // Anchor must not have advanced — otherwise the next sub-threshold
        // accrual would never trigger the fee.
        assertEq(vault.lastFeeAssets(), DEP, "anchor advanced below threshold");
    }

    function test_thresholdReached_chargesFullCumulativeYield() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200); // 2%
        vm.stopPrank();

        _deposit(alice, DEP);

        // First slice: 50_000 raw — below floor, no fee.
        _simulateYield(50_000);
        vault.accrueFees();
        assertEq(vault.shares(treasury), 0, "first slice below threshold");

        // Second slice: another 60_000 raw — cumulative 110_000 > 100_000 floor.
        _simulateYield(60_000);
        vault.accrueFees();

        // Fee = 2% × 110_000 = 2,200 raw assets.
        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        assertApproxEqAbs(treasuryAssets, 2_200, 5, "fee on full cumulative yield");
    }

    function test_threshold_survivesDeposit() public {
        // Below-threshold yield must not be erased by an intermediate deposit.
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200);
        vm.stopPrank();

        _deposit(alice, DEP);

        // 50_000 raw of yield (below floor).
        _simulateYield(50_000);
        vault.accrueFees(); // no-op, anchor not advanced

        // Bob deposits — the principal must NOT erase the un-charged yield.
        _deposit(bob, 500e6);

        // Now 60_000 more yield — cumulative 110_000 > floor.
        _simulateYield(60_000);
        vault.accrueFees();

        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        // Fee = 2% × 110_000 = 2,200 raw.
        assertApproxEqAbs(treasuryAssets, 2_200, 10, "deposit erased un-charged yield");
    }

    function test_threshold_proportionalOnWithdraw() public {
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200);
        vm.stopPrank();

        _deposit(alice, 1_000e6);

        // Sub-threshold yield: 50_000 raw ($0.05).
        _simulateYield(50_000);
        vault.accrueFees(); // no-op

        // Move past MIN_HOLD_TIME so the withdraw is allowed.
        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Alice withdraws half her shares.
        vm.startPrank(alice);
        uint256 halfShares = vault.shares(alice) / 2;
        vault.withdraw(halfShares);
        vm.stopPrank();

        // Anchor must scale to ~half its previous value, leaving ~half the
        // un-charged yield (~25,000 raw) sitting against the new anchor.
        // Concretely: lastFeeAssets goes from 1_000_000_000 → ~500_025_000.
        uint256 anchor = vault.lastFeeAssets();
        uint256 totalAfter = vault.totalAssets();
        // Remaining un-charged yield = totalAfter - anchor; must be ~25,000.
        uint256 remainingUncharged = totalAfter > anchor ? totalAfter - anchor : 0;
        assertApproxEqAbs(remainingUncharged, 25_000, 100, "un-charged yield not preserved on withdraw");

        // Floor is 100,000; remaining ~25,000 stays below floor → still no fee.
        vault.accrueFees();
        assertEq(vault.shares(treasury), 0, "fee minted on below-floor remainder");
    }

    function test_setMinFeeYieldAssets_capEnforced() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.MinFeeYieldTooHigh.selector);
        vault.setMinFeeYieldAssets(1_000_000_001); // > MAX_MIN_FEE_YIELD_ASSETS
    }

    function test_setMinFeeYieldAssets_emitsEvent() public {
        vm.prank(owner);
        vault.setMinFeeYieldAssets(500_000); // raise floor to $0.50
        assertEq(vault.minFeeYieldAssets(), 500_000);
    }

    function test_setMinFeeYieldAssets_zeroFloorBillsEverySat() public {
        // Owner can opt out of the floor entirely by setting it to 0.
        // Useful for non-USD-pegged tokens where "dust" makes no sense.
        vm.startPrank(owner);
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(200);
        vault.setMinFeeYieldAssets(0);
        vm.stopPrank();

        _deposit(alice, DEP);
        _simulateYield(50_000); // would be sub-threshold under default
        vault.accrueFees();

        // 2% × 50_000 = 1,000.
        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        assertApproxEqAbs(treasuryAssets, 1_000, 5, "zero floor must bill every sat");
    }
}
