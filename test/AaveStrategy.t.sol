// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";

/**
 * @title AaveStrategyTest
 * @notice Unit tests for the fixed AaveStrategy (Bugs 1-3).
 *
 * Stack: MockERC20 → MockAToken → MockAavePool → AaveStrategy
 */
contract AaveStrategyTest is Test {

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC20    usdc;
    MockAToken   aUsdc;
    MockAavePool aavePool;
    AaveStrategy strategy;

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner  = address(1);
    address vault  = address(2); // simulates AutoYieldVault
    address nobody = address(3);

    // ─── Config ───────────────────────────────────────────────────────────────

    uint256 constant INITIAL = 10_000e6;
    uint256 constant DEP1    = 1_000e6;
    uint256 constant DEP2    =   500e6;

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);
        usdc     = new MockERC20("Test USDC", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        // dataProvider = address(0) → local/mock mode
        strategy = new AaveStrategy(address(aavePool), address(usdc), address(aUsdc), address(0));
        strategy.setYieldVault(vault);
        vm.stopPrank();

        usdc.mint(vault, INITIAL);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

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
        assertEq(address(strategy.aavePool()),        address(aavePool));
        assertEq(address(strategy.underlyingToken()),  address(usdc));
        assertEq(address(strategy.aToken()),           address(aUsdc));
        assertEq(strategy.yieldVault(),                vault);
        assertEq(strategy.totalDeposited(),            0);
        assertEq(strategy.totalShares(),               0);
    }

    function test_strategyName_and_protocolName() public {
        assertEq(strategy.protocolName(), "Aave");
        // name includes "Aave V3" prefix
        assertTrue(
            bytes(strategy.strategyName()).length > 0,
            "strategyName should not be empty"
        );
    }

    function test_constructor_revertsOnTokenMismatch() public {
        vm.startPrank(owner);
        MockERC20  other  = new MockERC20("Other", "OTH", 6);
        MockAToken aOther = new MockAToken(address(other));
        // aOther underlying ≠ usdc → should revert
        vm.expectRevert("AaveStrategy: token mismatch");
        new AaveStrategy(address(aavePool), address(usdc), address(aOther), address(0));
        vm.stopPrank();
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_deposit_firstDeposit_oneToOneShares() public {
        _deposit(DEP1);
        // With virtual offset: shares = DEP1 * (0 + 1e6) / (0 + 1) = DEP1 * 1e6
        uint256 expectedShares = DEP1 * 1e6;
        assertEq(strategy.totalShares(),        expectedShares);
        assertEq(strategy.shares(vault),        expectedShares);
        assertEq(strategy.totalDeposited(),     DEP1);
        assertEq(strategy.getTotalValue(),      DEP1);
    }

    function test_deposit_secondDeposit_proportionalShares() public {
        _deposit(DEP1);
        uint256 firstShares = strategy.totalShares();
        _deposit(DEP2);

        // No yield → shares proportional with virtual offset
        // secondShares = DEP2 * (firstShares + 1e6) / (DEP1 + 1)
        uint256 expectedSecondShares = (DEP2 * (firstShares + 1e6)) / (DEP1 + 1);
        assertEq(strategy.totalShares(),    firstShares + expectedSecondShares);
        assertEq(strategy.totalDeposited(), DEP1 + DEP2);
    }

    /**
     * BUG FIX 1 VERIFICATION:
     * After yield accrual, new deposit should compute shares using current value
     * (not totalDeposited).  With the old buggy formula:
     *   sharesIssued = amount * totalShares / totalDeposited
     * …a depositor after yield would get MORE shares than deserved (diluting existing holders).
     * With the fix:
     *   sharesIssued = amount * totalShares / getTotalValue()
     * …proportional dilution is correct.
     */
    function test_deposit_bugFix1_sharesUseCurrentValue() public {
        _deposit(DEP1); // vault gets DEP1 shares

        // Simulate 100 USDC yield → totalValue = DEP1 + 100e6
        aavePool.simulateYield(address(strategy), 100e6);
        assertEq(strategy.getTotalValue(), DEP1 + 100e6);

        // Deposit DEP2 after yield
        _deposit(DEP2);

        // Expected shares with virtual offset = DEP2 * (firstShares + 1e6) / (priorValue + 1)
        uint256 firstShares = (DEP1 * (0 + 1e6)) / (0 + 1); // DEP1 * 1e6
        uint256 priorValue = DEP1 + 100e6;
        uint256 expectedNewShares = (DEP2 * (firstShares + 1e6)) / (priorValue + 1);
        uint256 totalExpected     = firstShares + expectedNewShares;

        assertEq(strategy.totalShares(), totalExpected);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(vault);
        vm.expectRevert("AaveStrategy: zero amount");
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

    function test_withdraw_returnsCorrectAmount() public {
        _deposit(DEP1);
        uint256 totalShares = strategy.totalShares();
        uint256 vaultBefore = usdc.balanceOf(vault);

        vm.prank(vault);
        uint256 amountOut = strategy.withdraw(totalShares);

        assertApproxEqAbs(amountOut, DEP1, 1);
        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, DEP1, 1);
        assertEq(strategy.totalShares(),    0);
        assertEq(strategy.totalDeposited(), 0);
    }

    /**
     * BUG FIX 2 VERIFICATION:
     * After yield, withdraw should only decrement totalDeposited by the proportional principal.
     * With the old buggy formula: totalDeposited -= amountWithdrawn (includes yield → underflow).
     */
    function test_withdraw_bugFix2_principalOnlyDecrement() public {
        _deposit(DEP1);

        // Simulate yield: totalValue = DEP1 + 100e6
        aavePool.simulateYield(address(strategy), 100e6);

        // Withdraw half of all shares
        uint256 halfShares = strategy.totalShares() / 2;
        vm.prank(vault);
        strategy.withdraw(halfShares);

        // totalDeposited should be DEP1 / 2 (not DEP1 - amountWithdrawn which would include yield)
        assertApproxEqAbs(strategy.totalDeposited(), DEP1 / 2, 1);
    }

    function test_withdraw_revertsOnInsufficientShares() public {
        _deposit(DEP1);
        uint256 totalShares = strategy.totalShares();
        vm.prank(vault);
        vm.expectRevert("AaveStrategy: insufficient shares");
        strategy.withdraw(totalShares + 1);
    }

    function test_withdraw_revertsOnZero() public {
        _deposit(DEP1);
        vm.prank(vault);
        vm.expectRevert("AaveStrategy: zero shares");
        strategy.withdraw(0);
    }

    // =========================================================================
    // withdrawAmount
    // =========================================================================

    function test_withdrawAmount_convertsCorrectly() public {
        _deposit(DEP1);

        // Simulate 10% yield
        aavePool.simulateYield(address(strategy), 100e6);

        uint256 withdrawTarget = 100e6; // withdraw 100 USDC
        uint256 vaultBefore    = usdc.balanceOf(vault);

        vm.prank(vault);
        uint256 actualOut = strategy.withdrawAmount(withdrawTarget);

        // actual should be close to target (integer division may cause small diff)
        assertApproxEqAbs(actualOut, withdrawTarget, 2);
        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, withdrawTarget, 2);
    }

    // =========================================================================
    // harvestYield
    // =========================================================================

    function test_harvestYield_harvestsOnlyYield() public {
        _deposit(DEP1);
        aavePool.simulateYield(address(strategy), 50e6);

        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        uint256 harvested = strategy.harvestYield();

        assertEq(harvested, 50e6);
        assertEq(usdc.balanceOf(vault) - vaultBefore, 50e6);
        // totalValue should now equal totalDeposited (yield harvested)
        assertEq(strategy.getTotalValue(), strategy.totalDeposited());
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

    /**
     * BUG FIX 3 VERIFICATION:
     * With dataProvider == address(0), APY should be 0 (not hardcoded 300).
     */
    function test_getEstimatedAPY_zeroInLocalMode() public {
        assertEq(strategy.getEstimatedAPY(), 0);
    }

    // =========================================================================
    // getTotalValue
    // =========================================================================

    function test_getTotalValue_reflectsATokenBalance() public {
        _deposit(DEP1);
        assertEq(strategy.getTotalValue(), DEP1);

        aavePool.simulateYield(address(strategy), 100e6);
        assertEq(strategy.getTotalValue(), DEP1 + 100e6);
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

        // Should get back the full amount (no fees in mock)
        assertApproxEqAbs(usdc.balanceOf(vault) - vaultBefore, amount, 1);
    }

    function testFuzz_yieldNeverReducesPrincipal(uint256 amount, uint256 yield) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        yield  = bound(yield, 0, 10_000_000e6);
        usdc.mint(vault, amount);

        _deposit(amount);
        aavePool.simulateYield(address(strategy), yield);

        uint256 totalShares = strategy.totalShares(); // read before prank (Foundry pitfall)
        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        strategy.withdraw(totalShares);

        assertGe(usdc.balanceOf(vault) - vaultBefore, amount, "should receive at least principal");
    }
}
