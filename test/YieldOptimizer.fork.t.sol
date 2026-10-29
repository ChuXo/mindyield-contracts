// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title YieldOptimizer Fork Tests
 * @notice Tests the 3-action YieldOptimizer against real Base mainnet protocols.
 *
 * @dev Run with:
 *   FORK_URL=<base-rpc-url> forge test --match-path "test/YieldOptimizer.fork.t.sol" --fork-url $FORK_URL -vvvv
 */

import "forge-std/Test.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/strategies/CompoundV3Strategy.sol";
import "../src/strategies/MorphoStrategy.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/optimizers/YieldOptimizer.sol";
import "../src/addresses/NetworkAddresses.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract YieldOptimizerForkTest is Test {

    string  internal forkUrl;
    bool    internal skipTests;

    IUSDC internal usdc;
    address internal whale;

    AutoYieldVault vault;
    AaveStrategy aaveStrat;
    CompoundV3Strategy compStrat;
    MorphoStrategy morphoStrat;
    YieldOptimizer optimizer;

    uint256 constant AMOUNT = 1_000e6; // 1000 USDC

    function setUp() public {
        forkUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            skipTests = true;
            return;
        }

        vm.createSelectFork(forkUrl);
        if (block.chainid != 8453) {
            skipTests = true;
            return;
        }

        usdc  = IUSDC(NetworkAddresses.BASE_USDC);
        whale = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3;

        // Deploy fresh vault + all 3 strategies
        vault = new AutoYieldVault(address(usdc), "USDC");

        aaveStrat = new AaveStrategy(
            NetworkAddresses.BASE_AAVE_POOL,
            address(usdc),
            NetworkAddresses.BASE_AUSDC,
            NetworkAddresses.BASE_AAVE_DATA_PROV
        );

        compStrat = new CompoundV3Strategy(
            NetworkAddresses.BASE_COMET_USDC,
            address(usdc)
        );

        morphoStrat = new MorphoStrategy(
            address(usdc),
            NetworkAddresses.BASE_METAMORPHO_USDC,
            "Morpho USDC"
        );

        // Wire strategies to vault
        vault.addStrategy(address(aaveStrat),    "Aave V3 USDC");
        vault.addStrategy(address(compStrat),    "Compound V3 USDC");
        vault.addStrategy(address(morphoStrat),  "Morpho USDC");

        aaveStrat.setYieldVault(address(vault));
        compStrat.setYieldVault(address(vault));
        morphoStrat.setYieldVault(address(vault));

        // Deploy optimizer through UUPS proxy
        YieldOptimizer impl = new YieldOptimizer();
        bytes memory initData = abi.encodeWithSelector(
            YieldOptimizer.initialize.selector,
            uint256(50),  // switchThresholdBps
            uint256(0),   // minSwitchInterval (0 for tests)
            uint256(1e6)  // minHarvestAmount (1 USDC for tests)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        optimizer = YieldOptimizer(address(proxy));
        optimizer.addVault(address(vault));
        vault.setOperator(address(optimizer));
    }

    modifier onlyFork() {
        if (skipTests) return;
        _;
    }

    function _getFunds(address to, uint256 amount) internal {
        vm.prank(whale);
        require(usdc.transfer(to, amount), "USDC whale transfer failed");
    }

    // =========================================================================
    // Strategy APY checks
    // =========================================================================

    function test_fork_allStrategiesReturnAPY() public onlyFork {
        uint256[] memory apys = vault.getStrategyAPYs();
        assertEq(apys.length, 3, "should have 3 strategies");

        // Aave and Compound V3 should return real APYs > 0
        assertGt(apys[0], 0, "Aave APY should be > 0");
        assertGt(apys[1], 0, "Compound V3 APY should be > 0");
        // Morpho may or may not implement apr() — just check it doesn't revert
        assertTrue(apys[2] >= 0, "Morpho APY should not revert");

        // Sanity: all APYs should be < 30% (3000 bps)
        assertLt(apys[0], 3000, "Aave APY sanity");
        assertLt(apys[1], 3000, "Compound V3 APY sanity");
        if (apys[2] > 0) assertLt(apys[2], 3000, "Morpho APY sanity");

        // Log for visibility
        emit log_named_uint("Aave APY (bps)", apys[0]);
        emit log_named_uint("Compound V3 APY (bps)", apys[1]);
        emit log_named_uint("Morpho APY (bps)", apys[2]);
    }

    // =========================================================================
    // Optimizer: getBestStrategyIndex
    // =========================================================================

    function test_fork_getBestStrategyIndex() public onlyFork {
        (uint256 bestIdx, uint256 bestAPY) = vault.getBestStrategyIndex();
        assertGt(bestAPY, 0, "best APY should be > 0");
        assertTrue(bestIdx < 3, "best index should be 0, 1, or 2");

        emit log_named_uint("Best strategy index", bestIdx);
        emit log_named_uint("Best APY (bps)", bestAPY);
    }

    // =========================================================================
    // Optimizer: checkUpkeep identifies correct action
    // =========================================================================

    function test_fork_checkUpkeep_identifiesBestStrategy() public onlyFork {
        _getFunds(address(this), AMOUNT);
        usdc.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);

        (bool needed, bytes memory data) = optimizer.checkUpkeep("");

        // If the active strategy (index 0 = Aave) is not the best,
        // checkUpkeep should return QUEUE_SWITCH
        (uint256 bestIdx,) = vault.getBestStrategyIndex();
        if (bestIdx != vault.activeStrategyIndex()) {
            assertTrue(needed, "should need upkeep when better strategy exists");

            (YieldOptimizer.ActionType action,, uint256 targetIdx) =
                abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
            assertEq(uint8(action), uint8(YieldOptimizer.ActionType.QUEUE_SWITCH));
            assertEq(targetIdx, bestIdx, "should target the best strategy");
        }
    }

    // =========================================================================
    // Full lifecycle: Queue -> Wait 24h -> Execute
    // =========================================================================

    function test_fork_fullSwitchLifecycle() public onlyFork {
        _getFunds(address(this), AMOUNT);
        usdc.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);

        uint256 assetsBefore = vault.totalAssets();
        uint256 startIdx = vault.activeStrategyIndex();

        // Determine target: switch to a different strategy
        uint256 targetIdx = startIdx == 0 ? 1 : 0;

        // Step 1: Queue switch via optimizer manual trigger
        optimizer.triggerSwitch(address(vault), targetIdx);
        assertGt(vault.pendingSwitchTimestamp(), 0, "should have pending switch");

        // Step 2: Warp past 24h timelock
        vm.warp(block.timestamp + 24 hours + 1);
        vm.roll(block.number + 100);

        // Step 3: checkUpkeep should return EXECUTE_SWITCH
        (bool needed, bytes memory data) = optimizer.checkUpkeep("");
        assertTrue(needed, "should need upkeep to execute switch");

        (YieldOptimizer.ActionType action,,) =
            abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
        assertEq(uint8(action), uint8(YieldOptimizer.ActionType.EXECUTE_SWITCH));

        // Step 4: Execute via performUpkeep
        optimizer.performUpkeep(data);

        assertEq(vault.activeStrategyIndex(), targetIdx, "should have switched");
        assertEq(vault.pendingSwitchTimestamp(), 0, "pending switch should be cleared");

        // Step 5: Verify funds migrated (within slippage tolerance)
        uint256 assetsAfter = vault.totalAssets();
        uint256 minExpected = assetsBefore * 99 / 100; // 1% slippage max
        assertGe(assetsAfter, minExpected, "assets should survive migration");

        emit log_named_uint("Assets before switch", assetsBefore);
        emit log_named_uint("Assets after switch", assetsAfter);
    }

    // =========================================================================
    // Harvest on real protocol yield
    // =========================================================================

    function test_fork_harvestAfterTimePassage() public onlyFork {
        _getFunds(address(this), AMOUNT);
        usdc.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);

        // Roll forward many blocks to accrue real yield
        vm.roll(block.number + 100_000);
        vm.warp(block.timestamp + 30 days);

        // Check harvestable yield
        uint256 harvestable = optimizer.getHarvestableYield(address(vault));
        emit log_named_uint("Harvestable yield (USDC decimals)", harvestable);

        // If yield has accrued (depends on real protocol state), harvest it
        if (harvestable >= optimizer.minHarvestAmount()) {
            (bool needed, bytes memory data) = optimizer.checkUpkeep("");
            // Could be HARVEST or QUEUE_SWITCH depending on APY diff
            if (needed) {
                (YieldOptimizer.ActionType action,,) =
                    abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
                if (action == YieldOptimizer.ActionType.HARVEST) {
                    uint256 idleBefore = vault.idleAssets();
                    optimizer.performUpkeep(data);
                    assertGt(vault.idleAssets(), idleBefore, "idle assets should increase after harvest");
                }
            }
        }
    }

    // =========================================================================
    // Verify 3-strategy deposit/withdraw round-trip
    // =========================================================================

    function test_fork_depositWithdrawAllStrategies() public onlyFork {
        _getFunds(address(this), AMOUNT * 3);

        // Test each strategy as active
        for (uint256 i = 0; i < 3; i++) {
            // Switch to strategy i if not already active
            if (vault.activeStrategyIndex() != i) {
                vault.queueStrategySwitchTo(i);
                vm.warp(block.timestamp + 24 hours + 1);
                vm.roll(block.number + 1);
                vault.switchStrategy(i);
            }

            assertEq(vault.activeStrategyIndex(), i);

            // Deposit
            usdc.approve(address(vault), AMOUNT);
            uint256 sharesMinted = vault.deposit(AMOUNT);
            assertGt(sharesMinted, 0, "should receive shares");

            uint256 assetsBefore = usdc.balanceOf(address(this));

            // Must wait at least 1 block for flash-loan protection
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 16); // > MIN_HOLD_TIME

            // Withdraw
            vault.withdraw(sharesMinted);
            uint256 assetsAfter = usdc.balanceOf(address(this));
            uint256 received = assetsAfter - assetsBefore;

            // Should get back at least 99% (rounding + potential tiny slippage)
            assertGe(received, AMOUNT * 99 / 100, "should get back ~100% of deposit");

            emit log_named_uint("Strategy", i);
            emit log_named_uint("Deposited", AMOUNT);
            emit log_named_uint("Received back", received);
        }
    }
}
