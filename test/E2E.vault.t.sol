// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/strategies/CompoundV3Strategy.sol";
import "../src/optimizers/YieldOptimizer.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockCompoundV3.sol";

/// @title E2E Vault Full Lifecycle Tests
/// @notice Tests AutoYieldVault deposit→yield→harvest→strategy-switch→withdraw
contract E2EVaultTest is Test {
    MockERC20        usdc;
    MockAToken       aUsdc;
    MockAavePool     aavePool;
    MockCompoundV3   comet;
    AaveStrategy     aaveStrat;
    CompoundV3Strategy c3Strat;
    AutoYieldVault   vault;
    YieldOptimizer   optimizer;

    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address charlie = address(0xC4A1);

    function setUp() public {
        vm.warp(1000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        comet    = new MockCompoundV3(address(usdc));

        vault = new AutoYieldVault(address(usdc), "USDC");

        aaveStrat = new AaveStrategy(address(aavePool), address(usdc), address(aUsdc), address(0));
        aaveStrat.setYieldVault(address(vault));
        vault.addStrategy(address(aaveStrat), "Aave V3");

        c3Strat = new CompoundV3Strategy(address(comet), address(usdc));
        c3Strat.setYieldVault(address(vault));
        vault.addStrategy(address(c3Strat), "Compound V3");

        YieldOptimizer optImpl = new YieldOptimizer();
        bytes memory optInit = abi.encodeWithSelector(
            YieldOptimizer.initialize.selector, uint256(50), uint256(0), uint256(10e6)
        );
        ERC1967Proxy optProxy = new ERC1967Proxy(address(optImpl), optInit);
        optimizer = YieldOptimizer(address(optProxy));
        optimizer.addVault(address(vault));
        vault.setOperator(address(optimizer));

        usdc.mint(alice,   1_000_000e6);
        usdc.mint(bob,     1_000_000e6);
        usdc.mint(charlie, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Full lifecycle: deposit → yield → harvest → withdraw with profit
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_vault_depositYieldWithdraw() public {
        // 1. Deposits
        _deposit(alice, 10_000e6);
        _deposit(bob, 5_000e6);

        uint256 totalBefore = vault.totalAssets();
        assertGe(totalBefore, 14_999e6); // ~15000 minus possible rounding

        // 2. Simulate yield on Aave
        aavePool.simulateYield(address(aaveStrat), 500e6); // 500 USDC yield

        // 3. Harvest yield
        uint256 harvested = vault.harvestYield();
        assertGt(harvested, 0, "Should harvest yield");

        // 4. Total assets should increase
        assertGt(vault.totalAssets(), totalBefore, "Total assets should grow after yield");

        // 5. Advance block for hold time
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        // 6. Alice withdraws — should get principal + proportional yield
        uint256 aliceShares = vault.shares(alice);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBefore;
        assertGt(aliceReceived, 10_000e6, "Alice should receive principal + yield share");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Strategy switch via YieldOptimizer
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_vault_strategySwitch() public {
        _deposit(alice, 10_000e6);

        // Verify starting strategy is Aave (index 0)
        assertEq(vault.activeStrategyIndex(), 0);

        // Advance time for hold
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        // Queue strategy switch via optimizer, wait for timelock, then execute
        optimizer.triggerSwitch(address(vault), 1);
        vm.warp(block.timestamp + 24 hours + 1); // wait for STRATEGY_SWITCH_DELAY
        vault.switchStrategy(1);
        assertEq(vault.activeStrategyIndex(), 1);

        // Simulate yield on Compound
        comet.simulateYield(address(c3Strat), 200e6);

        // Harvest
        uint256 harvested = vault.harvestYield();
        assertGt(harvested, 0, "Should harvest Compound yield");

        // Advance and withdraw
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        uint256 aliceShares = vault.shares(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        assertGt(usdc.balanceOf(alice) - balBefore, 10_000e6, "Should get principal + Compound yield");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Multi-depositor proportional withdrawal
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_vault_proportionalYieldSplit() public {
        // Alice deposits 2x more than Bob
        _deposit(alice, 20_000e6);
        _deposit(bob, 10_000e6);

        // Yield accrues
        aavePool.simulateYield(address(aaveStrat), 300e6);
        vault.harvestYield();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        // Both withdraw
        uint256 aliceShares = vault.shares(alice);
        uint256 bobShares = vault.shares(bob);

        vm.prank(alice);
        vault.withdraw(aliceShares);
        uint256 aliceGot = usdc.balanceOf(alice) - (1_000_000e6 - 20_000e6);

        vm.prank(bob);
        vault.withdraw(bobShares);
        uint256 bobGot = usdc.balanceOf(bob) - (1_000_000e6 - 10_000e6);

        // Alice should get ~2x Bob's yield (proportional to deposit)
        // Allow 5% tolerance for rounding
        assertGt(aliceGot, bobGot, "Alice (2x deposit) should get more");
        assertApproxEqRel(aliceGot, bobGot * 2, 0.05e18, "Alice should get ~2x Bob (5% tolerance)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Pause and resume
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_vault_pauseResume() public {
        _deposit(alice, 5_000e6);

        // Pause
        vault.pause();

        // Deposit should fail while paused
        vm.startPrank(bob);
        usdc.approve(address(vault), 5_000e6);
        vm.expectRevert();
        vault.deposit(5_000e6);
        vm.stopPrank();

        // Unpause
        vault.unpause();

        // Deposit should work now
        _deposit(bob, 5_000e6);
        assertGt(vault.shares(bob), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helper
    // ═══════════════════════════════════════════════════════════════════════════

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}
