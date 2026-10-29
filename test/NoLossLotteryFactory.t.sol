// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/lottery/NoLossLotteryV3.sol";
import "../src/lottery/NoLossLotteryFactory.sol";
import "../src/lottery/LotteryReceiptToken.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockRandomnessManager.sol";

/**
 * @title NoLossLotteryFactoryTest
 * @notice Tests for factory deployment and wiring of lottery pools.
 */
contract NoLossLotteryFactoryTest is Test {
    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    MockRandomnessManager randMgr;
    NoLossLotteryV3       impl;
    NoLossLotteryFactory  factory;

    address owner    = address(this);
    address alice    = address(0xA11CE);
    address treasury = address(0x7EA5);

    function setUp() public {
        vm.warp(1000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        randMgr  = new MockRandomnessManager();

        // Deploy implementation (constructor disables initializers)
        impl = new NoLossLotteryV3();

        // Deploy factory
        factory = new NoLossLotteryFactory(
            address(impl),
            address(randMgr),
            treasury,
            200, // 2% default fee
            address(aavePool),
            address(0) // no data provider
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  FACTORY DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_factory_constructor() public view {
        assertEq(factory.lotteryImplementation(), address(impl));
        assertEq(address(factory.randomnessManager()), address(randMgr));
        assertEq(factory.protocolFeeRecipient(), treasury);
        assertEq(factory.defaultProtocolFeeBps(), 200);
        assertEq(factory.aavePool(), address(aavePool));
        assertEq(factory.poolCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CREATE WEEKLY POOL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createPool_weekly() public {
        NoLossLotteryFactory.PoolConfig memory config = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 7 days,
            numberOfTiers: 2,
            tierBps:       [uint256(7500), uint256(2500), uint256(0), uint256(0), uint256(0)],
            poolType:      0,
            receiptName:   "MindYield Weekly USDC",
            receiptSymbol: "myWeeklyUSDC"
        });

        address lottery = factory.createPool(config);

        // Verify lottery was deployed
        assertTrue(lottery != address(0));
        assertEq(factory.poolCount(), 1);

        // Verify lottery is initialized correctly
        NoLossLotteryV3 lotteryContract = NoLossLotteryV3(lottery);
        assertEq(address(lotteryContract.depositToken()), address(usdc));
        assertEq(lotteryContract.roundDuration(), 7 days);
        assertEq(lotteryContract.protocolFeeBps(), 200);
        assertEq(lotteryContract.numberOfTiers(), 2);
        assertEq(lotteryContract.poolType(), 0);
        assertEq(lotteryContract.currentRoundId(), 1);

        // Verify receipt token
        LotteryReceiptToken receipt = lotteryContract.receiptToken();
        assertEq(receipt.name(), "MindYield Weekly USDC");
        assertEq(receipt.symbol(), "myWeeklyUSDC");
        assertEq(receipt.decimals(), 6); // matches USDC
        assertEq(receipt.owner(), lottery); // lottery can mint/burn

        // Verify strategy wiring
        AaveStrategy strat = lotteryContract.aaveStrategy();
        assertEq(strat.yieldVault(), lottery);

        // Pool ownership stays with the factory post-creation. The factory's
        // own owner (the deployer EOA, later the Timelock per the relaunch
        // runbook) is the ultimate authority — pool ownership transfers happen
        // via factory governance, not at createPool time.
        assertEq(lotteryContract.owner(), address(factory));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CREATE MONTHLY POOL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createPool_monthly() public {
        NoLossLotteryFactory.PoolConfig memory config = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 30 days,
            numberOfTiers: 1,
            tierBps:       [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)],
            poolType:      1,
            receiptName:   "MindYield Monthly USDC",
            receiptSymbol: "myMonthlyUSDC"
        });

        address lottery = factory.createPool(config);

        NoLossLotteryV3 lotteryContract = NoLossLotteryV3(lottery);
        assertEq(lotteryContract.roundDuration(), 30 days);
        assertEq(lotteryContract.numberOfTiers(), 1);
        assertEq(lotteryContract.poolType(), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MULTIPLE POOLS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createPool_multiplePools() public {
        // Weekly
        NoLossLotteryFactory.PoolConfig memory weekly = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 7 days,
            numberOfTiers: 2,
            tierBps:       [uint256(7500), uint256(2500), uint256(0), uint256(0), uint256(0)],
            poolType:      0,
            receiptName:   "MindYield Weekly USDC",
            receiptSymbol: "myWeeklyUSDC"
        });

        // Monthly
        NoLossLotteryFactory.PoolConfig memory monthly = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 30 days,
            numberOfTiers: 1,
            tierBps:       [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)],
            poolType:      1,
            receiptName:   "MindYield Monthly USDC",
            receiptSymbol: "myMonthlyUSDC"
        });

        address weeklyAddr  = factory.createPool(weekly);
        address monthlyAddr = factory.createPool(monthly);

        assertEq(factory.poolCount(), 2);
        assertTrue(weeklyAddr != monthlyAddr);

        // Each has its own strategy
        NoLossLotteryV3 weeklyLottery  = NoLossLotteryV3(weeklyAddr);
        NoLossLotteryV3 monthlyLottery = NoLossLotteryV3(monthlyAddr);
        assertTrue(address(weeklyLottery.aaveStrategy()) != address(monthlyLottery.aaveStrategy()));

        // Each has its own receipt token
        assertTrue(address(weeklyLottery.receiptToken()) != address(monthlyLottery.receiptToken()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  POOL USABILITY (end-to-end deposit after factory deploy)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createPool_depositable() public {
        NoLossLotteryFactory.PoolConfig memory config = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 7 days,
            numberOfTiers: 1,
            tierBps:       [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)],
            poolType:      0,
            receiptName:   "Test Pool",
            receiptSymbol: "TEST"
        });

        address lotteryAddr = factory.createPool(config);
        NoLossLotteryV3 lotteryContract = NoLossLotteryV3(lotteryAddr);

        // Fund alice and deposit
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(lotteryAddr, type(uint256).max);
        vm.prank(alice);
        lotteryContract.deposit(1000e6);

        assertEq(lotteryContract.totalDeposited(), 1000e6);
        assertTrue(lotteryContract.isParticipant(alice));
        assertEq(lotteryContract.receiptToken().balanceOf(alice), 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createPool_onlyOwner() public {
        NoLossLotteryFactory.PoolConfig memory config = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 7 days,
            numberOfTiers: 1,
            tierBps:       [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)],
            poolType:      0,
            receiptName:   "Test",
            receiptSymbol: "TEST"
        });

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.createPool(config);
    }

    function test_createPool_invalidTokenReverts() public {
        NoLossLotteryFactory.PoolConfig memory config = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(0), // invalid
            aToken:        address(aUsdc),
            roundDuration: 7 days,
            numberOfTiers: 1,
            tierBps:       [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)],
            poolType:      0,
            receiptName:   "Test",
            receiptSymbol: "TEST"
        });

        vm.expectRevert(NoLossLotteryFactory.InvalidConfig.selector);
        factory.createPool(config);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setDefaultProtocolFee() public {
        factory.setDefaultProtocolFee(500);
        assertEq(factory.defaultProtocolFeeBps(), 500);
    }

    function test_setDefaultProtocolFee_tooHighReverts() public {
        vm.expectRevert("Factory: fee too high");
        factory.setDefaultProtocolFee(1001);
    }

    function test_setLotteryImplementation() public {
        NoLossLotteryV3 newImpl = new NoLossLotteryV3();
        factory.setLotteryImplementation(address(newImpl));
        assertEq(factory.lotteryImplementation(), address(newImpl));
    }

    function test_setLotteryImplementation_zeroReverts() public {
        vm.expectRevert(NoLossLotteryFactory.InvalidImplementation.selector);
        factory.setLotteryImplementation(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DEPLOYED POOL TRACKING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getPool_returnsCorrectInfo() public {
        NoLossLotteryFactory.PoolConfig memory config = NoLossLotteryFactory.PoolConfig({
            depositToken:  address(usdc),
            aToken:        address(aUsdc),
            roundDuration: 7 days,
            numberOfTiers: 2,
            tierBps:       [uint256(7500), uint256(2500), uint256(0), uint256(0), uint256(0)],
            poolType:      0,
            receiptName:   "Test",
            receiptSymbol: "TEST"
        });

        address lotteryAddr = factory.createPool(config);

        NoLossLotteryFactory.DeployedPool memory pool = factory.getPool(0);
        assertEq(pool.lottery, lotteryAddr);
        assertEq(pool.poolType, 0);
        assertEq(pool.roundDuration, 7 days);
        assertTrue(pool.strategy != address(0));
        assertTrue(pool.receiptToken != address(0));
        assertEq(pool.deployedAt, block.timestamp);
    }
}
