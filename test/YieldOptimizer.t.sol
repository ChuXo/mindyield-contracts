// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/optimizers/YieldOptimizer.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title YieldOptimizerTest
 * @notice Unit tests for the upgraded 3-action YieldOptimizer + AutoYieldVault integration.
 *
 * Tests cover:
 *   - Admin: addVault, removeVault, setSwitchThreshold, setMinSwitchInterval, setMinHarvestAmount
 *   - QUEUE_SWITCH action: threshold check, cooldown, already-pending guard
 *   - EXECUTE_SWITCH action: timelock verification, lastSwitchTime tracking
 *   - HARVEST action: threshold, performUpkeep dispatch
 *   - Priority ordering: EXECUTE > HARVEST > QUEUE
 *   - Manual triggers: triggerSwitch, executeSwitch, manualHarvest
 *   - Vault integration: operator permissions, view functions
 */
contract YieldOptimizerTest is Test {

    MockERC20             usdc;
    MockAutoYieldStrategy strategy1; // low APY (300 bps = 3%)
    MockAutoYieldStrategy strategy2; // high APY (600 bps = 6%)
    AutoYieldVault        vault;
    YieldOptimizer        optimizer;

    address owner   = address(1);
    address alice   = address(2);
    address nobody  = address(3);

    uint256 constant DEP = 1_000e6;

    function setUp() public {
        vm.startPrank(owner);

        usdc      = new MockERC20("Test USDC", "USDC", 6);
        strategy1 = new MockAutoYieldStrategy(address(usdc)); // 300 bps default
        strategy2 = new MockAutoYieldStrategy(address(usdc)); // will be set to 600 bps
        strategy2.setEstimatedAPY(600);

        vault = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy1), "Strategy 1");
        vault.addStrategy(address(strategy2), "Strategy 2");

        // Deploy optimizer through UUPS proxy
        YieldOptimizer impl = new YieldOptimizer();
        bytes memory initData = abi.encodeWithSelector(
            YieldOptimizer.initialize.selector,
            uint256(50),   // switchThresholdBps
            uint256(0),    // minSwitchInterval (0 for most tests)
            uint256(10e6)  // minHarvestAmount
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        optimizer = YieldOptimizer(address(proxy));

        optimizer.addVault(address(vault));

        // Set optimizer as vault operator
        vault.setOperator(address(optimizer));

        vm.stopPrank();

        usdc.mint(alice, DEP * 10); // generous balance for multiple tests
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _queueAndExecuteSwitch(uint256 toIndex) internal {
        vm.prank(owner);
        vault.queueStrategySwitchTo(toIndex);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(toIndex);
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    function test_deployment() public {
        assertEq(optimizer.managedVaultCount(), 1);
        assertEq(optimizer.managedVaults(0),    address(vault));
        assertEq(optimizer.switchThresholdBps(), 50);
        assertEq(optimizer.minSwitchInterval(),  0); // set in initialize
        assertEq(optimizer.minHarvestAmount(),   10e6);
        assertTrue(optimizer.isManagedVault(address(vault)));
    }

    // =========================================================================
    // addVault / removeVault
    // =========================================================================

    function test_addVault_owner() public {
        vm.startPrank(owner);
        MockERC20 usdt    = new MockERC20("USDT", "USDT", 6);
        AutoYieldVault v2 = new AutoYieldVault(address(usdt), "USDT");
        optimizer.addVault(address(v2));
        vm.stopPrank();
        assertEq(optimizer.managedVaultCount(), 2);
    }

    function test_addVault_revertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(YieldOptimizer.InvalidVault.selector);
        optimizer.addVault(address(0));
    }

    function test_addVault_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.addVault(address(vault));
    }

    function test_removeVault_owner() public {
        vm.prank(owner);
        optimizer.removeVault(0);
        assertEq(optimizer.managedVaultCount(), 0);
    }

    function test_removeVault_revertsIfInvalidIndex() public {
        vm.prank(owner);
        vm.expectRevert(YieldOptimizer.InvalidIndex.selector);
        optimizer.removeVault(5);
    }

    // =========================================================================
    // checkUpkeep — QUEUE_SWITCH
    // =========================================================================

    /**
     * strategy1 = 300 bps, strategy2 = 600 bps (active = strategy1)
     * Difference = 300 bps > threshold (50 bps) -> upkeep needed
     */
    function test_checkUpkeep_needsSwitch() public {
        _deposit(alice, DEP);

        (bool needed, bytes memory data) = optimizer.checkUpkeep("");
        assertTrue(needed, "should need upkeep");

        (YieldOptimizer.ActionType action, address vaultAddr, uint256 newIndex) =
            abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action), uint8(YieldOptimizer.ActionType.QUEUE_SWITCH));
        assertEq(vaultAddr, address(vault));
        assertEq(newIndex, 1); // strategy2 is at index 1
    }

    /**
     * Both strategies same APY -> no switch needed
     */
    function test_checkUpkeep_noSwitchNeeded_sameAPY() public {
        _deposit(alice, DEP);

        // Set strategy2 APY equal to strategy1
        strategy2.setEstimatedAPY(300);

        (bool needed, ) = optimizer.checkUpkeep("");
        assertFalse(needed, "should not need upkeep with same APY");
    }

    /**
     * Difference is 40 bps, threshold is 50 -> no switch
     */
    function test_checkUpkeep_noSwitchNeeded_belowThreshold() public {
        _deposit(alice, DEP);

        strategy2.setEstimatedAPY(340); // 340 - 300 = 40 bps < 50 threshold

        (bool needed, ) = optimizer.checkUpkeep("");
        assertFalse(needed, "40 bps gain below 50 bps threshold");
    }

    /**
     * Already on best strategy -> checkUpkeep = false
     */
    function test_checkUpkeep_alreadyOnBestStrategy() public {
        _deposit(alice, DEP);
        _queueAndExecuteSwitch(1);

        (bool needed, ) = optimizer.checkUpkeep("");
        assertFalse(needed, "already on best strategy");
    }

    /**
     * Pending switch exists -> QUEUE_SWITCH skipped
     */
    function test_checkUpkeep_skipQueueIfPendingSwitchExists() public {
        _deposit(alice, DEP);

        // Queue a switch manually
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);

        // checkUpkeep should return EXECUTE_SWITCH (not ready yet) or nothing
        // Since timelock hasn't passed, EXECUTE won't trigger
        // And QUEUE is skipped because pending exists
        // So only HARVEST check remains (no yield yet = false)
        // But wait — timelock not passed, so EXECUTE won't trigger.
        // Let me check: pendingTs > 0 && block.timestamp >= pendingTs
        // pendingTs = now + 24h, so block.timestamp < pendingTs -> skip
        (bool needed, ) = optimizer.checkUpkeep("");
        assertFalse(needed, "pending switch exists but timelock not reached");
    }

    // =========================================================================
    // checkUpkeep — Switch Cooldown
    // =========================================================================

    function test_checkUpkeep_respectsCooldown() public {
        _deposit(alice, DEP);

        // Set a 7-day cooldown
        vm.prank(owner);
        optimizer.setMinSwitchInterval(7 days);

        // Simulate that a switch just happened
        // We do a full queue+execute via optimizer to set lastSwitchTime
        (bool needed1, bytes memory data1) = optimizer.checkUpkeep("");
        assertTrue(needed1);
        optimizer.performUpkeep(data1);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        optimizer.executeSwitch(address(vault), 1);

        // Now switch back strategy APYs so strategy1 is better
        strategy1.setEstimatedAPY(900);
        strategy2.setEstimatedAPY(300);

        // Should NOT trigger because cooldown hasn't elapsed
        (bool needed2, ) = optimizer.checkUpkeep("");
        assertFalse(needed2, "cooldown period should prevent new switch");

        // Warp past cooldown
        vm.warp(block.timestamp + 7 days + 1);

        (bool needed3, bytes memory data3) = optimizer.checkUpkeep("");
        assertTrue(needed3, "should trigger after cooldown");

        (YieldOptimizer.ActionType action3,,) =
            abi.decode(data3, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action3), uint8(YieldOptimizer.ActionType.QUEUE_SWITCH));
    }

    // =========================================================================
    // checkUpkeep — EXECUTE_SWITCH
    // =========================================================================

    function test_checkUpkeep_executePendingSwitch() public {
        _deposit(alice, DEP);

        // Queue a switch
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);

        // Before timelock: no execute
        (bool needed1, ) = optimizer.checkUpkeep("");
        assertFalse(needed1, "timelock not yet elapsed");

        // Warp past timelock
        vm.warp(block.timestamp + 24 hours + 1);

        (bool needed2, bytes memory data2) = optimizer.checkUpkeep("");
        assertTrue(needed2, "should detect executable pending switch");

        (YieldOptimizer.ActionType action, address vaultAddr, uint256 idx) =
            abi.decode(data2, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action), uint8(YieldOptimizer.ActionType.EXECUTE_SWITCH));
        assertEq(vaultAddr, address(vault));
        assertEq(idx, 1);
    }

    // =========================================================================
    // performUpkeep — EXECUTE_SWITCH
    // =========================================================================

    function test_performUpkeep_executesSwitch() public {
        _deposit(alice, DEP);

        assertEq(vault.activeStrategyIndex(), 0);

        // Queue switch
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);

        // Warp past timelock
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        // Execute via performUpkeep
        (, bytes memory data) = optimizer.checkUpkeep("");
        optimizer.performUpkeep(data);

        assertEq(vault.activeStrategyIndex(), 1, "should have switched to strategy2");
        assertEq(optimizer.lastSwitchTime(address(vault)), block.timestamp);
    }

    function test_performUpkeep_executeSwitch_revertsIfTimelockNotPassed() public {
        _deposit(alice, DEP);

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);

        // Don't warp — timelock not elapsed
        bytes memory data = abi.encode(YieldOptimizer.ActionType.EXECUTE_SWITCH, address(vault), uint256(1));
        vm.expectRevert(YieldOptimizer.ConditionsNotMet.selector);
        optimizer.performUpkeep(data);
    }

    // =========================================================================
    // checkUpkeep — HARVEST
    // =========================================================================

    function test_checkUpkeep_harvestAboveThreshold() public {
        _deposit(alice, DEP);

        // Switch to best strategy first so no QUEUE_SWITCH triggers
        _queueAndExecuteSwitch(1);

        // Simulate yield on strategy2 above threshold (10 USDC)
        strategy2.simulateYield(15e6); // 15 USDC

        (bool needed, bytes memory data) = optimizer.checkUpkeep("");
        assertTrue(needed, "should need harvest");

        (YieldOptimizer.ActionType action,,) =
            abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action), uint8(YieldOptimizer.ActionType.HARVEST));
    }

    function test_checkUpkeep_noHarvestBelowThreshold() public {
        _deposit(alice, DEP);

        // Switch to best strategy first
        _queueAndExecuteSwitch(1);

        // Simulate yield below threshold
        strategy2.simulateYield(5e6); // 5 USDC < 10 USDC threshold

        (bool needed, ) = optimizer.checkUpkeep("");
        assertFalse(needed, "yield below threshold should not trigger harvest");
    }

    // =========================================================================
    // performUpkeep — HARVEST
    // =========================================================================

    function test_performUpkeep_harvests() public {
        _deposit(alice, DEP);

        // Switch to best first
        _queueAndExecuteSwitch(1);

        // Simulate yield
        strategy2.simulateYield(20e6);

        (, bytes memory data) = optimizer.checkUpkeep("");
        optimizer.performUpkeep(data);

        // Yield should now be in vault as idleAssets
        assertGt(vault.idleAssets(), 0, "vault should have harvested idle assets");
    }

    function test_performUpkeep_harvest_revertsIfBelowThreshold() public {
        _deposit(alice, DEP);
        _queueAndExecuteSwitch(1);

        // No yield simulated — force a HARVEST action
        bytes memory data = abi.encode(YieldOptimizer.ActionType.HARVEST, address(vault), uint256(0));
        vm.expectRevert(YieldOptimizer.ConditionsNotMet.selector);
        optimizer.performUpkeep(data);
    }

    // =========================================================================
    // Priority ordering: EXECUTE > HARVEST > QUEUE
    // =========================================================================

    function test_priorityOrder_executeTakesPrecedenceOverHarvest() public {
        _deposit(alice, DEP);

        // Queue a switch
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);

        // Simulate yield on strategy1 (currently active)
        strategy1.simulateYield(20e6);

        // Warp past timelock — both EXECUTE and HARVEST conditions are true
        vm.warp(block.timestamp + 24 hours + 1);

        (bool needed, bytes memory data) = optimizer.checkUpkeep("");
        assertTrue(needed);

        (YieldOptimizer.ActionType action,,) =
            abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action), uint8(YieldOptimizer.ActionType.EXECUTE_SWITCH),
            "EXECUTE should take priority over HARVEST");
    }

    function test_priorityOrder_harvestTakesPrecedenceOverQueue() public {
        _deposit(alice, DEP);

        // Simulate yield on strategy1 above threshold
        strategy1.simulateYield(20e6);

        // strategy2 has higher APY (QUEUE_SWITCH would trigger)
        // But HARVEST should take priority

        (bool needed, bytes memory data) = optimizer.checkUpkeep("");
        assertTrue(needed);

        (YieldOptimizer.ActionType action,,) =
            abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action), uint8(YieldOptimizer.ActionType.HARVEST),
            "HARVEST should take priority over QUEUE_SWITCH");
    }

    // =========================================================================
    // Full lifecycle: Queue -> Execute -> Harvest
    // =========================================================================

    function test_fullLifecycle() public {
        _deposit(alice, DEP);

        // Step 1: checkUpkeep returns QUEUE_SWITCH
        (bool needed1, bytes memory data1) = optimizer.checkUpkeep("");
        assertTrue(needed1);
        (YieldOptimizer.ActionType action1,,) =
            abi.decode(data1, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action1), uint8(YieldOptimizer.ActionType.QUEUE_SWITCH));

        // Step 2: Execute queue
        optimizer.performUpkeep(data1);
        assertGt(vault.pendingSwitchTimestamp(), 0, "switch should be queued");

        // Step 3: Warp past timelock, checkUpkeep returns EXECUTE_SWITCH
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        (bool needed2, bytes memory data2) = optimizer.checkUpkeep("");
        assertTrue(needed2);
        (YieldOptimizer.ActionType action2,,) =
            abi.decode(data2, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action2), uint8(YieldOptimizer.ActionType.EXECUTE_SWITCH));

        // Step 4: Execute switch
        optimizer.performUpkeep(data2);
        assertEq(vault.activeStrategyIndex(), 1, "should be on strategy2");

        // Step 5: Simulate yield, checkUpkeep returns HARVEST
        strategy2.simulateYield(15e6);

        (bool needed3, bytes memory data3) = optimizer.checkUpkeep("");
        assertTrue(needed3);
        (YieldOptimizer.ActionType action3,,) =
            abi.decode(data3, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action3), uint8(YieldOptimizer.ActionType.HARVEST));

        // Step 6: Harvest
        optimizer.performUpkeep(data3);
        assertGt(vault.idleAssets(), 0, "should have harvested");
    }

    // =========================================================================
    // performUpkeep — QUEUE_SWITCH (old flow, updated encoding)
    // =========================================================================

    function test_performUpkeep_queuesThenExecutesSwitch() public {
        _deposit(alice, DEP);

        assertEq(vault.activeStrategyIndex(), 0);

        // performUpkeep queues the switch
        (, bytes memory data) = optimizer.checkUpkeep("");
        optimizer.performUpkeep(data);

        // Warp past the 24-hour timelock and execute
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        optimizer.executeSwitch(address(vault), 1);

        assertEq(vault.activeStrategyIndex(), 1, "should have switched to strategy2");
    }

    function test_performUpkeep_revertsIfConditionsNotMet() public {
        _deposit(alice, DEP);

        // Encode stale data: QUEUE_SWITCH to index 0 (already active)
        bytes memory staleData = abi.encode(
            YieldOptimizer.ActionType.QUEUE_SWITCH, address(vault), uint256(0)
        );
        vm.expectRevert(YieldOptimizer.ConditionsNotMet.selector);
        optimizer.performUpkeep(staleData);
    }

    function test_performUpkeep_revertsOnInvalidAction() public {
        bytes memory data = abi.encode(
            YieldOptimizer.ActionType.NONE, address(vault), uint256(0)
        );
        vm.expectRevert(YieldOptimizer.ConditionsNotMet.selector);
        optimizer.performUpkeep(data);
    }

    function test_performUpkeep_revertsOnNonManagedVault() public {
        // Create an unmanaged vault
        address fakeVault = address(0xdead);
        bytes memory data = abi.encode(
            YieldOptimizer.ActionType.HARVEST, fakeVault, uint256(0)
        );
        vm.expectRevert(YieldOptimizer.VaultNotManaged.selector);
        optimizer.performUpkeep(data);
    }

    function test_addVault_revertsDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(YieldOptimizer.VaultAlreadyManaged.selector);
        optimizer.addVault(address(vault));
    }

    // =========================================================================
    // Manual triggers
    // =========================================================================

    function test_triggerSwitch_ownerCanForceSwitch() public {
        _deposit(alice, DEP);

        // triggerSwitch queues; must warp + execute to complete
        vm.prank(owner);
        optimizer.triggerSwitch(address(vault), 1);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        optimizer.executeSwitch(address(vault), 1);

        assertEq(vault.activeStrategyIndex(), 1);
    }

    function test_triggerSwitch_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.triggerSwitch(address(vault), 1);
    }

    function test_manualHarvest_owner() public {
        _deposit(alice, DEP);
        strategy1.simulateYield(20e6);

        vm.prank(owner);
        optimizer.manualHarvest(address(vault));

        assertGt(vault.idleAssets(), 0, "should have harvested");
    }

    function test_manualHarvest_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.manualHarvest(address(vault));
    }

    // =========================================================================
    // Vault operator permissions
    // =========================================================================

    function test_vault_operatorCanSwitch() public {
        _deposit(alice, DEP);

        // Optimizer is the operator — performUpkeep queues the switch
        (, bytes memory data) = optimizer.checkUpkeep("");
        optimizer.performUpkeep(data);

        // Warp past timelock and execute
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        optimizer.executeSwitch(address(vault), 1);

        assertEq(vault.activeStrategyIndex(), 1);
    }

    function test_vault_nonOperatorCannotSwitch() public {
        _deposit(alice, DEP);

        vm.prank(nobody);
        vm.expectRevert(AutoYieldVault.NotAuthorized.selector);
        vault.switchStrategy(1);
    }

    function test_vault_ownerCanAlwaysSwitch() public {
        _deposit(alice, DEP);
        _queueAndExecuteSwitch(1);
        assertEq(vault.activeStrategyIndex(), 1);
    }

    // =========================================================================
    // Admin setters
    // =========================================================================

    function test_setSwitchThreshold_owner() public {
        vm.prank(owner);
        optimizer.setSwitchThreshold(100);
        assertEq(optimizer.switchThresholdBps(), 100);
    }

    function test_setSwitchThreshold_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.setSwitchThreshold(100);
    }

    function test_setMinSwitchInterval_owner() public {
        vm.prank(owner);
        optimizer.setMinSwitchInterval(14 days);
        assertEq(optimizer.minSwitchInterval(), 14 days);
    }

    function test_setMinSwitchInterval_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.setMinSwitchInterval(14 days);
    }

    function test_setMinHarvestAmount_owner() public {
        vm.prank(owner);
        optimizer.setMinHarvestAmount(50e6);
        assertEq(optimizer.minHarvestAmount(), 50e6);
    }

    function test_setMinHarvestAmount_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.setMinHarvestAmount(50e6);
    }

    // =========================================================================
    // getHarvestableYield (external view)
    // =========================================================================

    function test_getHarvestableYield_returnsCorrectAmount() public {
        _deposit(alice, DEP);

        // No yield yet
        assertEq(optimizer.getHarvestableYield(address(vault)), 0);

        // Simulate 25 USDC of yield
        strategy1.simulateYield(25e6);
        assertEq(optimizer.getHarvestableYield(address(vault)), 25e6);
    }

    function test_getHarvestableYield_returnsZeroForEmptyVault() public {
        assertEq(optimizer.getHarvestableYield(address(vault)), 0);
    }

    // =========================================================================
    // Vault views
    // =========================================================================

    function test_vault_getStrategyAPYs() public {
        uint256[] memory apys = vault.getStrategyAPYs();
        assertEq(apys.length, 2);
        assertEq(apys[0], 300); // strategy1
        assertEq(apys[1], 600); // strategy2
    }

    function test_vault_getBestStrategyIndex() public {
        (uint256 bestIndex, uint256 bestAPY) = vault.getBestStrategyIndex();
        assertEq(bestIndex, 1);
        assertEq(bestAPY,  600);
    }

    // =========================================================================
    // executeSwitch updates lastSwitchTime
    // =========================================================================

    function test_executeSwitch_updatesLastSwitchTime() public {
        _deposit(alice, DEP);

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 1);

        uint256 expectedTime = block.timestamp;
        vm.prank(owner);
        optimizer.executeSwitch(address(vault), 1);

        assertEq(optimizer.lastSwitchTime(address(vault)), expectedTime);
    }

    function test_executeSwitch_revertsIfNotOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        optimizer.executeSwitch(address(vault), 1);
    }

    function test_cancelSwitch_owner() public {
        _deposit(alice, DEP);

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        assertGt(vault.pendingSwitchTimestamp(), 0);

        vm.prank(owner);
        optimizer.cancelSwitch(address(vault));
        assertEq(vault.pendingSwitchTimestamp(), 0);
    }
}
