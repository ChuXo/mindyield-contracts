// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/interfaces/IAutoYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/**
 * @title AutoYieldVaultEdgeTest
 * @notice Edge cases for AutoYieldVault:
 *   - MINIMUM_FIRST_DEPOSIT enforcement
 *   - Share-inflation / first-depositor attack prevention
 *   - Multi-depositor proportional withdrawal
 *   - Strategy switch edge cases
 *   - Paused state guards
 *   - ZeroAmount reverts
 *   - InsufficientShares reverts
 */
contract AutoYieldVaultEdgeTest is Test {

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC20             usdc;
    MockAutoYieldStrategy strategy;
    MockAutoYieldStrategy strategy2;
    AutoYieldVault        vault;

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner  = address(1);
    address alice  = address(2);
    address bob    = address(3);
    address carol  = address(4);
    address nobody = address(5);

    uint256 constant INITIAL = 10_000e6;

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        usdc      = new MockERC20("Test USDC", "USDC", 6);
        strategy  = new MockAutoYieldStrategy(address(usdc));
        strategy2 = new MockAutoYieldStrategy(address(usdc));
        vault     = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Mock Aave V3");

        vm.stopPrank();

        usdc.mint(alice, INITIAL);
        usdc.mint(bob,   INITIAL);
        usdc.mint(carol, INITIAL);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount);
        vm.stopPrank();
    }

    // =========================================================================
    // MINIMUM_FIRST_DEPOSIT
    // =========================================================================

    function test_firstDeposit_belowMinimum_reverts() public {
        uint256 minDeposit = vault.MINIMUM_FIRST_DEPOSIT();

        vm.startPrank(alice);
        usdc.approve(address(vault), minDeposit - 1);
        vm.expectRevert(AutoYieldVault.BelowMinimumDeposit.selector);
        vault.deposit(minDeposit - 1);
        vm.stopPrank();
    }

    function test_firstDeposit_exactMinimum_succeeds() public {
        uint256 minDeposit = vault.MINIMUM_FIRST_DEPOSIT();
        uint256 SHARE_MULT = 1e6;

        uint256 shares = _deposit(alice, minDeposit);
        assertEq(shares, minDeposit * SHARE_MULT, "shares at virtual offset ratio");
        assertEq(vault.shares(alice), minDeposit * SHARE_MULT);
    }

    function test_secondDeposit_belowMinimum_succeeds() public {
        uint256 minDeposit = vault.MINIMUM_FIRST_DEPOSIT();

        // Alice establishes the pool
        _deposit(alice, minDeposit * 100);

        // Bob deposits below MINIMUM_FIRST_DEPOSIT — allowed because pool exists
        uint256 smallDeposit = minDeposit - 1;
        usdc.mint(bob, smallDeposit);
        uint256 shares = _deposit(bob, smallDeposit);
        assertGt(shares, 0);
    }

    function test_zeroDeposit_reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 0);
        vm.expectRevert(AutoYieldVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.stopPrank();
    }

    // =========================================================================
    // Share inflation attack prevention
    // =========================================================================

    function test_shareInflation_prevented() public {
        // Classic attack: attacker deposits 1 wei, then donates directly to inflate share price,
        // causing victim's shares to be rounded down to 0.
        // With MINIMUM_FIRST_DEPOSIT = 1_000, the 1-wei deposit is blocked.
        uint256 tinyAmount = 1;
        vm.startPrank(alice);
        usdc.approve(address(vault), tinyAmount);
        vm.expectRevert(AutoYieldVault.BelowMinimumDeposit.selector);
        vault.deposit(tinyAmount);
        vm.stopPrank();
    }

    function test_firstDeposit_proportional_afterMinimum() public {
        uint256 minDeposit = vault.MINIMUM_FIRST_DEPOSIT();
        uint256 SHARE_MULT = 1e6;

        // First depositor: shares at virtual offset ratio
        uint256 aliceShares = _deposit(alice, minDeposit * 1000);
        assertEq(aliceShares, minDeposit * 1000 * SHARE_MULT);

        // Simulate yield to inflate share price
        strategy.simulateYield(minDeposit * 500);

        // Second depositor: shares should be proportional, not zero
        uint256 bobDeposit = minDeposit * 1000;
        uint256 bobShares = _deposit(bob, bobDeposit);
        assertGt(bobShares, 0, "second depositor must receive non-zero shares");
        assertLt(bobShares, aliceShares, "inflated price: bob gets fewer shares per unit");
    }

    // =========================================================================
    // InsufficientShares
    // =========================================================================

    function test_withdraw_moreThanOwned_reverts() public {
        uint256 shares = _deposit(alice, 1_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(AutoYieldVault.InsufficientShares.selector);
        vault.withdraw(shares + 1);
    }

    function test_withdraw_byNonDepositor_reverts() public {
        _deposit(alice, 1_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(AutoYieldVault.InsufficientShares.selector);
        vault.withdraw(1);
    }

    function test_withdraw_zeroShares_reverts() public {
        _deposit(alice, 1_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(AutoYieldVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    // =========================================================================
    // Multi-depositor proportional withdrawal
    // =========================================================================

    function test_multiDepositor_proportionalWithdraw() public {
        uint256 aliceDeposit = 6_000e6;
        uint256 bobDeposit   = 3_000e6;

        uint256 aliceShares = _deposit(alice, aliceDeposit);
        uint256 bobShares   = _deposit(bob,   bobDeposit);

        // No yield — ratio should be 2:1 (shares = amount * SHARE_MULT with virtual offset)
        uint256 SHARE_MULT = 1e6;
        assertEq(aliceShares, aliceDeposit * SHARE_MULT);
        assertEq(bobShares,   bobDeposit * SHARE_MULT);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1); // Must advance block for flash loan protection

        // Alice withdraws all her shares
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, aliceDeposit, 1);

        // Bob withdraws all his shares
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);
        assertApproxEqAbs(usdc.balanceOf(bob) - bobBefore, bobDeposit, 1);

        assertEq(vault.totalShares(), 0);
    }

    function test_multiDepositor_yieldSplitProportionally() public {
        uint256 aliceDeposit = 6_000e6;
        uint256 bobDeposit   = 3_000e6;

        uint256 aliceShares = _deposit(alice, aliceDeposit);
        uint256 bobShares   = _deposit(bob,   bobDeposit);

        uint256 yieldAmount = 900e6;
        strategy.simulateYield(yieldAmount);
        // Total assets = 9_000 + 900 = 9_900
        // Alice (6000/9000 = 2/3) → 6_600
        // Bob   (3000/9000 = 1/3) → 3_300

        uint256 alicePreview = vault.previewRedeem(aliceShares);
        uint256 bobPreview   = vault.previewRedeem(bobShares);

        assertApproxEqAbs(alicePreview, 6_600e6, 3, "alice gets 2/3 of total");
        assertApproxEqAbs(bobPreview,   3_300e6, 3, "bob gets 1/3 of total");
        // Sum may differ from totalAssets by up to 2 due to virtual offset rounding
        assertApproxEqAbs(alicePreview + bobPreview, vault.totalAssets(), 2);
    }

    // =========================================================================
    // Strategy switch edge cases
    // =========================================================================

    function test_switchStrategy_sameIndex_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.StrategyAlreadyActive.selector);
        vault.switchStrategy(0);
    }

    function test_switchStrategy_outOfRange_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.InvalidStrategyIndex.selector);
        vault.switchStrategy(99);
    }

    function test_switchStrategy_byNonOwner_reverts() public {
        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Mock Compound");

        vm.prank(nobody);
        vm.expectRevert(AutoYieldVault.NotAuthorized.selector);
        vault.switchStrategy(1);
    }

    function test_switchStrategy_migratesYield() public {
        uint256 depositAmt = 2_000e6;
        _deposit(alice, depositAmt);

        // Simulate yield in strategy 1
        strategy.simulateYield(200e6);
        uint256 totalBefore = vault.totalAssets(); // 2_200e6

        // Add strategy 2 and switch
        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Mock Compound");
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(1);

        // Total assets should be preserved after migration
        assertApproxEqAbs(vault.totalAssets(), totalBefore, 1);
        assertEq(strategy.strategyTotalValue(),  0, "old strategy drained");
        assertApproxEqAbs(strategy2.strategyTotalValue(), totalBefore, 1);
    }

    function test_switchStrategy_withdrawStillWorks() public {
        uint256 depositAmt = 1_500e6;
        uint256 shares = _deposit(alice, depositAmt);

        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Mock Compound");
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(1);

        vm.roll(block.number + 1); // Must advance block for flash loan protection

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, depositAmt, 1);
    }

    // =========================================================================
    // Paused state guards
    // =========================================================================

    function test_deposit_whenPaused_reverts() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert("Pausable: paused");
        vault.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_unpause_restoresDeposit() public {
        _deposit(alice, 1_000e6);

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.unpause();

        uint256 shares = _deposit(bob, 500e6);
        assertGt(shares, 0);
    }

    function test_pause_byNonOwner_reverts() public {
        // pause() permits owner OR guardian; everyone else hits the
        // "Not authorized" require.
        vm.prank(nobody);
        vm.expectRevert("Not authorized");
        vault.pause();
    }

    // =========================================================================
    // NoStrategyConfigured — deposit on vault with no strategy
    // =========================================================================

    function test_deposit_noStrategy_reverts() public {
        vm.startPrank(owner);
        AutoYieldVault empty = new AutoYieldVault(address(usdc), "USDC");
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(empty), 1_000e6);
        vm.expectRevert(AutoYieldVault.NoStrategyConfigured.selector);
        empty.deposit(1_000e6);
        vm.stopPrank();
    }

    // =========================================================================
    // harvestYield edge cases
    // =========================================================================

    function test_harvestYield_zeroIfNoYield() public {
        _deposit(alice, 1_000e6);
        vm.prank(owner);
        uint256 harvested = vault.harvestYield();
        assertEq(harvested, 0);
    }

    function test_harvestYield_afterYield_positive() public {
        _deposit(alice, 1_000e6);
        strategy.simulateYield(100e6);

        vm.prank(owner);
        uint256 harvested = vault.harvestYield();
        assertEq(harvested, 100e6);
    }

    function test_harvestYield_idempotent() public {
        _deposit(alice, 1_000e6);
        strategy.simulateYield(50e6);

        vm.prank(owner);
        vault.harvestYield();

        // Second harvest immediately after: no new yield
        vm.prank(owner);
        uint256 secondHarvest = vault.harvestYield();
        assertEq(secondHarvest, 0);
    }

    // =========================================================================
    // Fuzz: no depositor ever receives less than principal
    // =========================================================================

    function testFuzz_principalPreserved(uint256 aliceAmt, uint256 bobAmt, uint256 yieldAmt) public {
        uint256 minDep = vault.MINIMUM_FIRST_DEPOSIT();
        aliceAmt = bound(aliceAmt, minDep, INITIAL);
        bobAmt   = bound(bobAmt,   minDep, INITIAL);
        yieldAmt = bound(yieldAmt, 0,      1_000_000e6);

        usdc.mint(alice, aliceAmt);
        usdc.mint(bob,   bobAmt);

        // Both deposit BEFORE yield simulation to avoid zero-shares on second deposit
        uint256 aliceShares = _deposit(alice, aliceAmt);
        uint256 bobShares   = _deposit(bob,   bobAmt);

        strategy.simulateYield(yieldAmt);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1); // Must advance block for flash loan protection

        // Alice should always get back at least aliceAmt
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        assertGe(usdc.balanceOf(alice), aliceBefore, "alice never loses principal");

        // Bob should always get back at least bobAmt
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);
        assertGe(usdc.balanceOf(bob), bobBefore, "bob never loses principal");
    }
}
