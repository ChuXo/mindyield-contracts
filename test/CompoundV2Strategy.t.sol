// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/strategies/CompoundStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockCompoundV2.sol";

/**
 * @title CompoundV2StrategyTest
 * @notice Unit tests for the fixed CompoundStrategy (Compound V2 / cToken).
 *
 * Stack: MockERC20 → MockCompoundV2 → CompoundStrategy
 */
contract CompoundV2StrategyTest is Test {

    MockERC20        usdc;
    MockCompoundV2   cUsdc;
    CompoundStrategy strategy;

    address owner  = address(1);
    address vault  = address(2);
    address nobody = address(3);

    uint256 constant INITIAL = 10_000e6;
    uint256 constant DEP1    = 1_000e6;
    uint256 constant DEP2    =   500e6;

    function setUp() public {
        vm.startPrank(owner);
        usdc     = new MockERC20("Test USDC", "USDC", 6);
        cUsdc    = new MockCompoundV2(address(usdc));
        strategy = new CompoundStrategy(address(usdc), address(cUsdc));
        strategy.setYieldVault(vault);
        vm.stopPrank();

        usdc.mint(vault,          INITIAL);
        usdc.mint(address(cUsdc), INITIAL); // pool needs liquidity
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(vault);
        usdc.approve(address(strategy), amount);
        strategy.deposit(amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    function test_deployment() public {
        assertEq(address(strategy.underlyingToken()), address(usdc));
        assertEq(address(strategy.cToken()),          address(cUsdc));
        assertEq(strategy.yieldVault(),               vault);
        assertEq(strategy.totalShares(),              0);
        assertEq(strategy.totalDeposited(),           0);
    }

    function test_strategyName_and_protocolName() public {
        assertEq(strategy.strategyName(), "Compound V2");
        assertEq(strategy.protocolName(), "Compound");
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_firstDeposit_oneToOneShares() public {
        _deposit(DEP1);
        // With virtual offset: shares = DEP1 * (0 + 1e6) / (0 + 1) = DEP1 * 1e6
        uint256 expectedShares = DEP1 * 1e6;
        assertEq(strategy.totalShares(),    expectedShares);
        assertEq(strategy.totalDeposited(), DEP1);
        assertApproxEqAbs(strategy.getTotalValue(), DEP1, 1);
    }

    function test_deposit_secondDeposit_proportionalShares() public {
        _deposit(DEP1);
        uint256 firstShares = strategy.totalShares();
        _deposit(DEP2);
        // secondShares = DEP2 * (firstShares + 1e6) / (DEP1 + 1)
        uint256 expectedSecondShares = (DEP2 * (firstShares + 1e6)) / (DEP1 + 1);
        assertEq(strategy.totalShares(),    firstShares + expectedSecondShares);
        assertEq(strategy.totalDeposited(), DEP1 + DEP2);
    }

    function test_deposit_bugFix1_sharesUseCurrentValue() public {
        _deposit(DEP1);
        uint256 firstShares = strategy.totalShares();
        // Simulate yield
        cUsdc.simulateYield(100e6);
        uint256 valueBefore = strategy.getTotalValue();
        assertGt(valueBefore, DEP1);

        _deposit(DEP2);

        // With virtual offset: newShares = DEP2 * (firstShares + 1e6) / (valueBefore + 1)
        uint256 expectedNewShares = (DEP2 * (firstShares + 1e6)) / (valueBefore + 1);
        assertApproxEqAbs(strategy.totalShares(), firstShares + expectedNewShares, 1);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(vault);
        vm.expectRevert("CompoundStrategy: zero amount");
        strategy.deposit(0);
    }

    function test_deposit_revertsIfNotVault() public {
        usdc.mint(nobody, DEP1);
        vm.startPrank(nobody);
        usdc.approve(address(strategy), DEP1);
        vm.expectRevert("BaseStrategy: not authorized");
        strategy.deposit(DEP1);
        vm.stopPrank();
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_fullShares() public {
        _deposit(DEP1);
        uint256 totalShares = strategy.totalShares();
        uint256 vaultBefore = usdc.balanceOf(vault);

        vm.prank(vault);
        uint256 amountOut = strategy.withdraw(totalShares);

        assertApproxEqAbs(amountOut, DEP1, 1);
        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, DEP1, 1);
        assertEq(strategy.totalShares(), 0);
    }

    function test_withdraw_bugFix2_principalDecrement() public {
        _deposit(DEP1);
        cUsdc.simulateYield(100e6);

        uint256 halfShares = strategy.totalShares() / 2;
        vm.prank(vault);
        strategy.withdraw(halfShares);

        assertApproxEqAbs(strategy.totalDeposited(), DEP1 / 2, 1);
    }

    function test_withdraw_revertsOnInsufficientShares() public {
        _deposit(DEP1);
        uint256 totalShares = strategy.totalShares();
        vm.prank(vault);
        vm.expectRevert("CompoundStrategy: insufficient shares");
        strategy.withdraw(totalShares + 1);
    }

    // =========================================================================
    // harvestYield
    // =========================================================================

    function test_harvestYield_harvestsOnlyYield() public {
        _deposit(DEP1);
        cUsdc.simulateYield(50e6);

        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        uint256 harvested = strategy.harvestYield();

        assertApproxEqAbs(harvested, 50e6, 1);
        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, 50e6, 1);
    }

    function test_harvestYield_zeroIfNoYield() public {
        _deposit(DEP1);
        vm.prank(vault);
        uint256 harvested = strategy.harvestYield();
        assertEq(harvested, 0);
    }

    // =========================================================================
    // getEstimatedAPY
    // =========================================================================

    function test_getEstimatedAPY_nonZero() public {
        uint256 apy = strategy.getEstimatedAPY();
        assertGt(apy, 0, "APY should be > 0 with default supply rate");
    }

    function test_getEstimatedAPY_calculatesCorrectly() public {
        // supplyRatePerBlock = 11_415_525_115 (default ≈ 3% APY)
        uint256 BLOCKS = 2_628_000;
        uint256 expectedApyBps = (11_415_525_115 * BLOCKS * 10_000) / 1e18;
        assertApproxEqAbs(strategy.getEstimatedAPY(), expectedApyBps, 5);
    }

    // =========================================================================
    // withdrawAmount
    // =========================================================================

    function test_withdrawAmount_convertsCorrectly() public {
        _deposit(DEP1);
        cUsdc.simulateYield(100e6);

        uint256 target      = 100e6;
        uint256 vaultBefore = usdc.balanceOf(vault);

        vm.prank(vault);
        uint256 actualOut = strategy.withdrawAmount(target);

        assertApproxEqAbs(actualOut, target, 2);
        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, target, 2);
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_depositWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(vault, amount);

        _deposit(amount);

        uint256 totalShares = strategy.totalShares(); // read before prank (Foundry pitfall)
        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        strategy.withdraw(totalShares);

        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, amount, 2);
    }
}
