// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/interfaces/IAutoYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/**
 * @title AutoYieldVaultTest
 * @notice Full unit-test suite for AutoYieldVault.sol
 *
 * Stack under test:
 *   MockERC20 (USDC) <- MockAutoYieldStrategy <- AutoYieldVault
 */
contract AutoYieldVaultTest is Test {

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC20            usdc;
    MockAutoYieldStrategy strategy;
    MockAutoYieldStrategy strategy2;   // for switchStrategy tests
    AutoYieldVault       vault;

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner   = address(1);
    address alice   = address(2);
    address bob     = address(3);
    address nobody  = address(4);

    // ─── Config ───────────────────────────────────────────────────────────────

    uint256 constant INITIAL_BALANCE = 10_000e6;
    uint256 constant DEP_ALICE       = 1_000e6;
    uint256 constant DEP_BOB         = 500e6;

    /// @dev Virtual shares/assets ratio — first deposit yields amount * SHARE_MULT shares
    uint256 constant SHARE_MULT = 1e6;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 assets, uint256 sharesIssued);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 assetsReturned);
    event YieldHarvested(uint256 harvested, uint256 newTotalAssets);
    event StrategyAdded(uint256 indexed index, address strategy, string name);
    event StrategySwitched(uint256 fromIndex, uint256 toIndex, uint256 fundsMigrated);

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        usdc      = new MockERC20("Test USDC", "USDC", 6);
        strategy  = new MockAutoYieldStrategy(address(usdc));
        strategy2 = new MockAutoYieldStrategy(address(usdc));
        vault     = new AutoYieldVault(address(usdc), "USDC");

        // Register first strategy (auto-activated)
        vault.addStrategy(address(strategy), "Mock Aave V3");

        vm.stopPrank();

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob,   INITIAL_BALANCE);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal returns (uint256 sharesIssued) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        sharesIssued = vault.deposit(amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    function test_deployment() public {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(vault.tokenSymbol(), "USDC");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.activeStrategyIndex(), 0);
        assertEq(vault.strategyCount(), 1);
    }

    function test_deployment_noStrategy_revert() public {
        vm.startPrank(owner);
        AutoYieldVault empty = new AutoYieldVault(address(usdc), "USDC");
        vm.stopPrank();

        vm.startPrank(alice);
        usdc.approve(address(empty), DEP_ALICE);
        vm.expectRevert(AutoYieldVault.NoStrategyConfigured.selector);
        empty.deposit(DEP_ALICE);
        vm.stopPrank();
    }

    // =========================================================================
    // Deposit
    // =========================================================================

    function test_deposit_firstDeposit_sharesWithVirtualOffset() public {
        vm.prank(alice);
        usdc.approve(address(vault), DEP_ALICE);

        uint256 expectedShares = DEP_ALICE * SHARE_MULT;

        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, DEP_ALICE, expectedShares);

        vm.prank(alice);
        uint256 shares_ = vault.deposit(DEP_ALICE);

        assertEq(shares_, expectedShares, "shares with virtual offset on first deposit");
        assertEq(vault.shares(alice), expectedShares);
        assertEq(vault.totalShares(), expectedShares);
    }

    function test_deposit_secondDeposit_proportionalShares() public {
        _deposit(alice, DEP_ALICE);
        uint256 bobShares = _deposit(bob, DEP_BOB);

        // No yield → shares = amount * SHARE_MULT for all deposits
        assertEq(bobShares, DEP_BOB * SHARE_MULT);
        assertEq(vault.totalShares(), (DEP_ALICE + DEP_BOB) * SHARE_MULT);
    }

    function test_deposit_revertsOnZero() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), DEP_ALICE);
        vm.expectRevert(AutoYieldVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), DEP_ALICE);
        vm.expectRevert("Pausable: paused");
        vault.deposit(DEP_ALICE);
        vm.stopPrank();
    }

    function test_deposit_tokensForwardedToStrategy() public {
        _deposit(alice, DEP_ALICE);
        assertEq(strategy.strategyTotalValue(), DEP_ALICE, "tokens in strategy");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no tokens after deposit");
    }

    // =========================================================================
    // Flash loan protection: same-block deposit-withdraw
    // =========================================================================

    function test_withdraw_revertsOnSameBlock() public {
        _deposit(alice, DEP_ALICE);
        uint256 aliceShares = vault.shares(alice);

        vm.prank(alice);
        vm.expectRevert(AutoYieldVault.SameBlockWithdraw.selector);
        vault.withdraw(aliceShares);
    }

    // =========================================================================
    // Withdraw
    // =========================================================================

    function test_withdraw_fullShares() public {
        _deposit(alice, DEP_ALICE);
        uint256 aliceShares = vault.shares(alice);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 before = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, aliceShares, DEP_ALICE);

        vm.prank(alice);
        uint256 returned = vault.withdraw(aliceShares);

        assertEq(returned, DEP_ALICE);
        assertEq(usdc.balanceOf(alice) - before, DEP_ALICE);
        assertEq(vault.shares(alice), 0);
        assertEq(vault.totalShares(), 0);
    }

    function test_withdraw_partialShares() public {
        _deposit(alice, DEP_ALICE);
        uint256 halfShares = vault.shares(alice) / 2;

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        vm.prank(alice);
        uint256 returned = vault.withdraw(halfShares);

        assertEq(returned, DEP_ALICE / 2);
        assertEq(vault.shares(alice), halfShares);
    }

    function test_withdraw_revertsOnZero() public {
        _deposit(alice, DEP_ALICE);
        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(AutoYieldVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    function test_withdraw_revertsOnInsufficient() public {
        _deposit(alice, DEP_ALICE);
        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        uint256 aliceShares = vault.shares(alice);
        vm.prank(alice);
        vm.expectRevert(AutoYieldVault.InsufficientShares.selector);
        vault.withdraw(aliceShares + 1);
    }

    // =========================================================================
    // Share accounting — yield appreciation
    // =========================================================================

    function test_shareValue_increasesWithYield() public {
        _deposit(alice, DEP_ALICE);

        // Inject 100 USDC yield — totalAssets increases, totalShares stays same
        strategy.simulateYield(100e6);

        uint256 aliceShares = vault.shares(alice);
        uint256 totalAssets_ = vault.totalAssets(); // DEP_ALICE + 100e6

        // previewRedeem should reflect yield
        uint256 preview = vault.previewRedeem(aliceShares);
        // Virtual offset causes preview to be up to 1 wei less than totalAssets (rounds down)
        assertApproxEqAbs(preview, totalAssets_, 1, "preview should equal total assets for sole depositor");

        // Actual withdraw returns more than deposited
        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        uint256 received = usdc.balanceOf(alice) - before;

        assertGe(received, DEP_ALICE, "should receive at least principal");
    }

    function test_shareValue_twoDepositors_proportional() public {
        _deposit(alice, DEP_ALICE); // 1000 shares * SHARE_MULT
        _deposit(bob,   DEP_BOB);   // 500 shares * SHARE_MULT

        strategy.simulateYield(150e6); // 10% yield

        uint256 aliceShares = vault.shares(alice);
        uint256 bobShares_  = vault.shares(bob);

        uint256 alicePreview = vault.previewRedeem(aliceShares);
        uint256 bobPreview   = vault.previewRedeem(bobShares_);

        // Virtual offset rounding causes sum to differ from totalAssets by up to 2
        assertApproxEqAbs(alicePreview + bobPreview, vault.totalAssets(), 2, "previews sum to total");
        assertGt(alicePreview, bobPreview, "alice has more shares, more assets");
    }

    // =========================================================================
    // previewRedeem
    // =========================================================================

    function test_previewRedeem_zeroShares() public {
        assertEq(vault.previewRedeem(1000), 0, "no shares means 0 preview");
    }

    function test_previewRedeem_afterDeposit() public {
        _deposit(alice, DEP_ALICE);
        uint256 shares_ = vault.shares(alice);
        assertEq(vault.previewRedeem(shares_), DEP_ALICE);
    }

    // =========================================================================
    // getUserInfo
    // =========================================================================

    function test_getUserInfo_afterDeposit() public {
        _deposit(alice, DEP_ALICE);
        (uint256 userShares, uint256 userAssets) = vault.getUserInfo(alice);
        assertEq(userShares, DEP_ALICE * SHARE_MULT);
        assertEq(userAssets, DEP_ALICE);
    }

    function test_getUserInfo_afterYield() public {
        _deposit(alice, DEP_ALICE);
        strategy.simulateYield(100e6);
        (, uint256 userAssets) = vault.getUserInfo(alice);
        // Virtual offset causes tiny rounding loss (rounds down, favoring vault)
        assertApproxEqAbs(userAssets, DEP_ALICE + 100e6, 1, "user assets include yield");
    }

    // =========================================================================
    // harvestYield
    // =========================================================================

    function test_harvestYield_sendsToVault() public {
        _deposit(alice, DEP_ALICE);
        strategy.simulateYield(50e6);

        // After harvest, yield moves from strategy->vault; totalAssets stays the same
        uint256 expectedTotal = vault.totalAssets();
        vm.expectEmit(false, false, false, true);
        emit YieldHarvested(50e6, expectedTotal);

        vm.prank(owner);
        uint256 harvested = vault.harvestYield();
        assertEq(harvested, 50e6, "harvested amount should match yield");
    }

    function test_harvestYield_zeroIfNone() public {
        _deposit(alice, DEP_ALICE);
        vm.prank(owner);
        uint256 harvested = vault.harvestYield();
        assertEq(harvested, 0);
    }

    // =========================================================================
    // getCurrentAPY
    // =========================================================================

    function test_getCurrentAPY() public {
        assertEq(vault.getCurrentAPY(), MockAutoYieldStrategy(address(strategy)).ESTIMATED_APY());
    }

    // =========================================================================
    // addStrategy
    // =========================================================================

    function test_addStrategy_owner() public {
        vm.expectEmit(true, false, false, true);
        emit StrategyAdded(1, address(strategy2), "Mock Compound");

        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Mock Compound");

        assertEq(vault.strategyCount(), 2);
    }

    function test_addStrategy_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.InvalidStrategy.selector);
        vault.addStrategy(address(0), "Bad");
    }

    function test_addStrategy_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.addStrategy(address(strategy2), "X");
    }

    // =========================================================================
    // switchStrategy
    // =========================================================================

    function test_switchStrategy_migratesFunds() public {
        _deposit(alice, DEP_ALICE);

        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Mock Compound");

        uint256 before2 = strategy2.strategyTotalValue();
        assertEq(before2, 0);

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectEmit(false, false, false, true);
        emit StrategySwitched(0, 1, DEP_ALICE);

        vm.prank(owner);
        vault.switchStrategy(1);

        assertEq(vault.activeStrategyIndex(), 1);
        assertEq(strategy.strategyTotalValue(), 0,        "old strategy empty");
        assertEq(strategy2.strategyTotalValue(), DEP_ALICE, "new strategy has all funds");
    }

    function test_switchStrategy_userCanStillWithdraw() public {
        _deposit(alice, DEP_ALICE);

        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Mock Compound");

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(1);

        vm.roll(block.number + 1);

        uint256 aliceShares = vault.shares(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, DEP_ALICE, 1);
    }

    function test_switchStrategy_revertsOnSameIndex() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.StrategyAlreadyActive.selector);
        vault.switchStrategy(0);
    }

    function test_switchStrategy_revertsOnInvalidIndex() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.InvalidStrategyIndex.selector);
        vault.switchStrategy(99);
    }

    function test_switchStrategy_revertsIfNotOwner() public {
        vm.prank(owner);
        vault.addStrategy(address(strategy2), "Y");
        vm.prank(nobody);
        vm.expectRevert(AutoYieldVault.NotAuthorized.selector);
        vault.switchStrategy(1);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_pause_owner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_unpause_owner() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
    }

    function test_pause_revertsIfNotOwner() public {
        // pause() is callable by owner OR guardian; everyone else hits the
        // "Not authorized" require.
        vm.prank(nobody);
        vm.expectRevert("Not authorized");
        vault.pause();
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, vault.MINIMUM_FIRST_DEPOSIT(), INITIAL_BALANCE);
        usdc.mint(alice, amount);
        uint256 shares_ = _deposit(alice, amount);
        assertEq(shares_, amount * SHARE_MULT, "shares = amount * SHARE_MULT on first deposit");
    }

    function testFuzz_depositWithdraw(uint256 amount) public {
        amount = bound(amount, vault.MINIMUM_FIRST_DEPOSIT(), INITIAL_BALANCE);

        uint256 shares_ = _deposit(alice, amount);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares_);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, amount, 1, "principal returned");
    }

    function testFuzz_yieldNeverLosesDepositor(uint256 amount, uint256 yield_) public {
        amount = bound(amount, 1e6, INITIAL_BALANCE);
        yield_  = bound(yield_, 0, 1_000_000e6);

        _deposit(alice, amount);
        strategy.simulateYield(yield_);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceShares = vault.shares(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        assertGe(usdc.balanceOf(alice), before, "yield never reduces balance");
    }

}
