// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/interfaces/IAutoYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/**
 * @title RoundingStrategy
 * @notice Strategy that returns slightly less than expected on withdraw (simulates
 *         rounding losses in real DeFi protocols like Aave/Compound).
 */
contract RoundingStrategy is IAutoYieldStrategy {
    MockERC20 public token;
    uint256 public totalDeposited;
    uint256 public roundingLoss; // wei lost per withdraw

    constructor(address _token, uint256 _roundingLoss) {
        token = MockERC20(_token);
        roundingLoss = _roundingLoss;
    }

    function deposit(uint256 amount) external override {
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        totalDeposited += amount;
    }

    function withdraw(uint256 /* sharesToBurn */) external override returns (uint256 amountOut) {
        amountOut = totalDeposited > roundingLoss ? totalDeposited - roundingLoss : 0;
        totalDeposited = 0;
        if (amountOut > 0) {
            require(token.transfer(msg.sender, amountOut), "transfer failed");
        }
    }

    function withdrawAmount(uint256 tokenAmount) external override returns (uint256 actualOut) {
        actualOut = tokenAmount > roundingLoss ? tokenAmount - roundingLoss : 0;
        if (actualOut > totalDeposited) actualOut = totalDeposited;
        totalDeposited -= actualOut;
        if (actualOut > 0) {
            require(token.transfer(msg.sender, actualOut), "transfer failed");
        }
    }

    function getTotalValue() external view override returns (uint256) {
        return totalDeposited;
    }

    function getEstimatedAPY() external pure override returns (uint256) {
        return 300;
    }

    function harvestYield() external pure override returns (uint256) {
        return 0;
    }

    function strategyName() external pure override returns (string memory) {
        return "Rounding Strategy";
    }

    function protocolName() external pure override returns (string memory) {
        return "Rounding";
    }
}

/**
 * @title AutoYieldVaultManipulationTest
 * @notice Manipulation, race condition, and adversarial scenario tests for AutoYieldVault.
 */
contract AutoYieldVaultManipulationTest is Test {

    // --- Contracts ---
    MockERC20             usdc;
    MockAutoYieldStrategy strategy;
    MockAutoYieldStrategy strategy2;
    MockAutoYieldStrategy strategy3;
    AutoYieldVault        vault;

    // --- Actors ---
    address owner       = address(1);
    address alice       = address(2);
    address bob         = address(3);
    address carol       = address(4);
    address attacker    = address(5);
    address operatorA   = address(6);
    address operatorB   = address(7);
    address nobody      = address(8);

    uint256 constant INITIAL = 100_000e6;
    uint256 constant SHARE_MULT = 1e6;

    // --- Events ---
    event Deposited(address indexed user, uint256 assets, uint256 sharesIssued);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 assetsReturned);
    event StrategySwitched(uint256 fromIndex, uint256 toIndex, uint256 fundsMigrated);
    event OperatorUpdated(address indexed newOperator);

    // --- setUp ---
    function setUp() public {
        vm.startPrank(owner);

        usdc      = new MockERC20("Test USDC", "USDC", 6);
        strategy  = new MockAutoYieldStrategy(address(usdc));
        strategy2 = new MockAutoYieldStrategy(address(usdc));
        strategy3 = new MockAutoYieldStrategy(address(usdc));
        vault     = new AutoYieldVault(address(usdc), "USDC");

        vault.addStrategy(address(strategy),  "Strategy A");
        vault.addStrategy(address(strategy2), "Strategy B");
        vault.addStrategy(address(strategy3), "Strategy C");

        vm.stopPrank();

        usdc.mint(alice,    INITIAL);
        usdc.mint(bob,      INITIAL);
        usdc.mint(carol,    INITIAL);
        usdc.mint(attacker, INITIAL);
    }

    // --- Helpers ---
    function _deposit(address user, uint256 amount) internal returns (uint256 sharesIssued) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        sharesIssued = vault.deposit(amount);
        vm.stopPrank();
    }

    function _queueAndSwitch(address caller, uint256 newIndex) internal {
        vm.prank(caller);
        vault.queueStrategySwitchTo(newIndex);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(caller);
        vault.switchStrategy(newIndex);
    }

    // =========================================================================
    // 1. Front-running strategy switch
    // =========================================================================

    function test_frontRunStrategySwitch_noUnfairYieldCapture() public {
        _deposit(alice, 10_000e6);
        strategy.simulateYield(1_000e6);

        uint256 attackerShares = _deposit(attacker, 11_000e6);
        assertApproxEqAbs(attackerShares, 10_000e6 * SHARE_MULT, SHARE_MULT, "attacker gets shares at current inflated price");

        _queueAndSwitch(owner, 1);

        strategy2.simulateYield(2_200e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 attackerBal = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.withdraw(attackerShares);
        uint256 attackerReceived = usdc.balanceOf(attacker) - attackerBal;

        uint256 aliceShares = vault.shares(alice);
        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBal;

        assertApproxEqAbs(attackerReceived, aliceReceived, 2,
            "equal shares get equal payouts - no front-run advantage");
    }

    // =========================================================================
    // 2. Sandwich attack on strategy switch
    // =========================================================================

    function test_sandwichStrategySwitch_noProfit() public {
        _deposit(alice, 10_000e6);
        strategy.simulateYield(500e6);

        uint256 attackerDeposit = 10_500e6;
        uint256 attackerShares = _deposit(attacker, attackerDeposit);

        _queueAndSwitch(owner, 1);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 attackerBal = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.withdraw(attackerShares);
        uint256 attackerReceived = usdc.balanceOf(attacker) - attackerBal;

        assertLe(attackerReceived, attackerDeposit,
            "sandwich attacker cannot profit from strategy switch");

        uint256 alicePreview = vault.previewRedeem(vault.shares(alice));
        assertGe(alicePreview, 10_000e6, "alice retains at least principal after sandwich");
    }

    // =========================================================================
    // 3. Many depositors (50+)
    // =========================================================================

    function test_manyDepositors_correctnessAtScale() public {
        uint256 numDepositors = 50;
        uint256 depositEach = 2_000e6;
        address[] memory users = new address[](numDepositors);
        uint256[] memory sharesList = new uint256[](numDepositors);

        for (uint256 i = 0; i < numDepositors; i++) {
            users[i] = address(uint160(100 + i));
            usdc.mint(users[i], depositEach);
            sharesList[i] = _deposit(users[i], depositEach);
        }

        assertEq(vault.totalShares(), depositEach * SHARE_MULT * numDepositors,
            "totalShares equals sum of all deposits (no yield yet)");

        uint256 yieldAmount = 10_000e6;
        strategy.simulateYield(yieldAmount);

        uint256 expectedTotal = depositEach * numDepositors + yieldAmount;
        assertEq(vault.totalAssets(), expectedTotal, "totalAssets correct after yield");

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 totalWithdrawn;
        for (uint256 i = 0; i < numDepositors; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            vault.withdraw(sharesList[i]);
            uint256 received = usdc.balanceOf(users[i]) - bal;
            totalWithdrawn += received;

            // Virtual offset rounding accumulates over many depositors; allow up to 6 wei
            assertApproxEqAbs(received, depositEach + (yieldAmount / numDepositors), 6,
                "each depositor gets proportional yield");
        }

        assertEq(vault.totalShares(), 0, "all shares burned");
        assertApproxEqAbs(totalWithdrawn, expectedTotal, numDepositors,
            "total withdrawn matches total assets (within rounding)");
    }

    // =========================================================================
    // 4. Withdraw all then re-deposit
    // =========================================================================

    function test_withdrawAllThenRedeposit_sharesResetCleanly() public {
        uint256 aliceShares = _deposit(alice, 5_000e6);
        strategy.simulateYield(500e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        assertEq(vault.totalShares(), 0);

        // After full drain with yield, there may be residual value in the strategy
        // (rounding dust or unharvested yield). This is expected — the next depositor's
        // shares are calculated against this residual, which effectively donates it to them.
        uint256 residualAssets = vault.totalAssets();

        uint256 newShares = _deposit(bob, 3_000e6);
        assertGt(newShares, 0, "bob gets non-zero shares on fresh pool");
        assertEq(vault.totalShares(), newShares);
        assertEq(vault.shares(bob), newShares);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        uint256 bobBal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(newShares);
        // Bob gets his deposit + any residual dust from alice's rounding
        assertGe(usdc.balanceOf(bob) - bobBal, 3_000e6 - 1, "bob gets at least principal minus rounding");
        residualAssets; // suppress warning
    }

    function test_multipleRoundsOfDrainAndRefill() public {
        for (uint256 round = 0; round < 5; round++) {
            uint256 amount = 2_000e6 + round * 1_000e6;

            uint256 shares_ = _deposit(alice, amount);

            strategy.simulateYield(100e6 * (round + 1));

            vm.warp(block.timestamp + 16);
            vm.roll(block.number + 1);

            uint256 bal = usdc.balanceOf(alice);
            vm.prank(alice);
            vault.withdraw(shares_);

            assertGe(usdc.balanceOf(alice) - bal, amount, "principal preserved each round");
            assertEq(vault.totalShares(), 0, "pool fully drained each round");
        }
    }

    // =========================================================================
    // 5. Alternating deposits and withdrawals
    // =========================================================================

    function test_interleavedDepositsWithdrawals_invariantsMaintained() public {
        uint256 aliceShares = _deposit(alice, 4_000e6);
        uint256 bobShares = _deposit(bob, 2_000e6);

        strategy.simulateYield(600e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Alice partially withdraws (half her shares)
        uint256 aliceHalf = aliceShares / 2;
        vm.prank(alice);
        vault.withdraw(aliceHalf);

        // Carol deposits
        uint256 carolShares = _deposit(carol, 3_300e6);
        // After alice withdraw: totalAssets ~= 4400, totalShares adjusted
        // Carol: 3300 at price ~1.1 → ~3000 * SHARE_MULT
        // Carol's shares: 3300 at ~1.1 price. Virtual offset introduces more rounding at scale.
        assertApproxEqAbs(carolShares, 3_000e6 * SHARE_MULT, 2 * SHARE_MULT, "carol shares correct after interleaved ops");

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Bob withdraws all
        uint256 bobBal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);
        uint256 bobReceived = usdc.balanceOf(bob) - bobBal;
        assertGe(bobReceived, 2_000e6, "bob gets at least principal");

        // Remaining: alice (half shares) + carol shares
        assertEq(vault.totalShares(), aliceShares - aliceHalf + carolShares,
            "totalShares consistent after interleaved ops");

        uint256 sumShares = vault.shares(alice) + vault.shares(bob) + vault.shares(carol);
        assertEq(sumShares, vault.totalShares(), "share accounting invariant holds");
    }

    // =========================================================================
    // 6. Share price after many yield cycles
    // =========================================================================

    function test_sharePriceAfterManyYieldCycles() public {
        _deposit(alice, 10_000e6);

        uint256 cumulativeYield;

        for (uint256 i = 0; i < 20; i++) {
            uint256 yieldThisCycle = 50e6;
            strategy.simulateYield(yieldThisCycle);
            cumulativeYield += yieldThisCycle;

            vm.prank(owner);
            vault.harvestYield();

            if (i % 5 == 0) {
                usdc.mint(bob, 1_000e6);
                _deposit(bob, 1_000e6);
            }
        }

        uint256 aliceShares = vault.shares(alice);
        uint256 aliceValue = vault.previewRedeem(aliceShares);
        assertGt(aliceValue, 10_000e6, "alice share value appreciated over 20 cycles");

        uint256 totalDeposits = 10_000e6 + (4 * 1_000e6);
        uint256 expectedTotal = totalDeposits + cumulativeYield;
        assertApproxEqAbs(vault.totalAssets(), expectedTotal, 20,
            "totalAssets matches deposits + cumulative yield");
    }

    function test_compoundingSharePriceNeverDecreases() public {
        uint256 aliceShares = _deposit(alice, 5_000e6);

        uint256 prevValue = vault.previewRedeem(aliceShares);

        for (uint256 i = 0; i < 10; i++) {
            strategy.simulateYield(100e6);

            uint256 currentValue = vault.previewRedeem(aliceShares);
            assertGe(currentValue, prevValue, "share value never decreases with yield");
            prevValue = currentValue;
        }
    }

    // =========================================================================
    // 7. Strategy returns less than expected (rounding)
    // =========================================================================

    function test_strategyReturnsLess_vaultHandlesGracefully() public {
        vm.startPrank(owner);
        RoundingStrategy roundingStrat = new RoundingStrategy(address(usdc), 1);
        AutoYieldVault roundingVault = new AutoYieldVault(address(usdc), "USDC");
        roundingVault.addStrategy(address(roundingStrat), "Rounding");
        vm.stopPrank();

        uint256 depositAmt = 5_000e6;
        usdc.mint(alice, depositAmt);

        vm.startPrank(alice);
        usdc.approve(address(roundingVault), depositAmt);
        uint256 shares_ = roundingVault.deposit(depositAmt);
        vm.stopPrank();

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 returned = roundingVault.withdraw(shares_);

        assertEq(returned, depositAmt - 1, "vault uses actual amount from strategy");
        assertEq(usdc.balanceOf(alice) - aliceBal, depositAmt - 1);
    }

    function test_strategyReturnsLess_largerRounding() public {
        vm.startPrank(owner);
        RoundingStrategy roundingStrat = new RoundingStrategy(address(usdc), 100);
        AutoYieldVault roundingVault = new AutoYieldVault(address(usdc), "USDC");
        roundingVault.addStrategy(address(roundingStrat), "Rounding");
        vm.stopPrank();

        uint256 depositAmt = 1_000e6;
        usdc.mint(alice, depositAmt);

        vm.startPrank(alice);
        usdc.approve(address(roundingVault), depositAmt);
        uint256 shares_ = roundingVault.deposit(depositAmt);
        vm.stopPrank();

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 returned = roundingVault.withdraw(shares_);

        assertEq(returned, depositAmt - 100);
        assertEq(usdc.balanceOf(alice) - aliceBal, depositAmt - 100);
    }

    // =========================================================================
    // 8. Dust amount deposits
    // =========================================================================

    function test_dustDeposit_minimumPlusOne() public {
        uint256 minDep = vault.MINIMUM_FIRST_DEPOSIT();
        uint256 dustAmount = minDep + 1;

        usdc.mint(alice, dustAmount);
        uint256 shares_ = _deposit(alice, dustAmount);
        assertEq(shares_, dustAmount * SHARE_MULT, "shares at virtual offset ratio for dust first deposit");

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares_);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBal, dustAmount, 1);
    }

    function test_dustDeposit_protectedByVirtualOffset() public {
        // Large first deposit
        _deposit(alice, 10_000e6);

        // Simulate yield to inflate share price
        strategy.simulateYield(5_000e6);
        // totalAssets = 15000e6, totalShares = 10000e6 * SHARE_MULT

        // With virtual offset, even a 1-wei deposit gets non-zero shares
        // (the inflation attack is mitigated)
        usdc.mint(bob, 1);
        uint256 bobShares = _deposit(bob, 1);
        assertGt(bobShares, 0, "virtual offset prevents zero-share deposit");
    }

    function test_dustDeposit_smallButNonZeroShares() public {
        _deposit(alice, 10_000e6);

        // Small yield to inflate price slightly
        strategy.simulateYield(1e6);

        // With virtual offset, tiny deposits get proportionally more shares
        usdc.mint(bob, 2);
        uint256 bobShares = _deposit(bob, 2);
        assertGt(bobShares, 0, "tiny deposit gets non-zero shares with virtual offset");

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Bob can withdraw his shares
        uint256 bobBal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);
        uint256 received = usdc.balanceOf(bob) - bobBal;
        assertGe(received, 0, "does not revert");
    }

    // =========================================================================
    // 9. Maximum deposit (overflow protection)
    // =========================================================================

    function test_maxDeposit_largeAmount() public {
        uint256 largeAmount = 1_000_000_000e6; // 1 billion USDC
        usdc.mint(alice, largeAmount);

        uint256 shares_ = _deposit(alice, largeAmount);
        assertEq(shares_, largeAmount * SHARE_MULT, "large first deposit gets shares at virtual offset ratio");

        strategy.simulateYield(10_000_000e6);

        uint256 aliceValue = vault.previewRedeem(shares_);
        // Virtual offset rounding: allow 1 wei tolerance at any scale
        assertApproxEqAbs(aliceValue, largeAmount + 10_000_000e6, 1);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares_);
        assertGe(usdc.balanceOf(alice) - aliceBal, largeAmount);
    }

    function test_twoLargeDeposits_noOverflow() public {
        uint256 largeA = 500_000_000e6;
        uint256 largeB = 500_000_000e6;

        usdc.mint(alice, largeA);
        usdc.mint(bob, largeB);

        uint256 aliceShares = _deposit(alice, largeA);
        uint256 bobShares = _deposit(bob, largeB);

        strategy.simulateYield(100_000_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        uint256 bobBal = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);

        assertGe(usdc.balanceOf(alice) - aliceBal, largeA, "alice principal safe at large scale");
        assertGe(usdc.balanceOf(bob) - bobBal, largeB, "bob principal safe at large scale");
    }

    // =========================================================================
    // 10. Harvest when strategy has no yield
    // =========================================================================

    function test_harvestNoYield_returnsZero() public {
        _deposit(alice, 5_000e6);

        vm.prank(owner);
        uint256 harvested = vault.harvestYield();
        assertEq(harvested, 0, "no yield to harvest");

        assertEq(vault.totalAssets(), 5_000e6);
    }

    function test_harvestNoYield_emptyVault_returnsZero() public {
        uint256 shares_ = _deposit(alice, 5_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.withdraw(shares_);

        vm.prank(owner);
        uint256 harvested = vault.harvestYield();
        assertEq(harvested, 0);
    }

    // =========================================================================
    // 11. Multiple harvests between deposits
    // =========================================================================

    function test_multipleHarvestsBetweenDeposits() public {
        _deposit(alice, 10_000e6);

        strategy.simulateYield(100e6);
        vm.prank(owner);
        uint256 h1 = vault.harvestYield();
        assertEq(h1, 100e6);

        strategy.simulateYield(200e6);
        vm.prank(owner);
        uint256 h2 = vault.harvestYield();
        assertEq(h2, 200e6);

        strategy.simulateYield(300e6);
        vm.prank(owner);
        uint256 h3 = vault.harvestYield();
        assertEq(h3, 300e6);

        assertEq(vault.totalAssets(), 10_600e6, "totalAssets reflects all harvested yield");

        uint256 bobShares = _deposit(bob, 1_060e6);
        // 1060 at price 1.06 → 1000 * SHARE_MULT
        assertApproxEqAbs(bobShares, 1_000e6 * SHARE_MULT, SHARE_MULT, "bob shares priced correctly after multiple harvests");
    }

    function test_harvestTwiceInRow_secondIsZero() public {
        _deposit(alice, 5_000e6);
        strategy.simulateYield(200e6);

        vm.prank(owner);
        uint256 h1 = vault.harvestYield();
        assertEq(h1, 200e6);

        vm.prank(owner);
        uint256 h2 = vault.harvestYield();
        assertEq(h2, 0, "second consecutive harvest returns 0");
    }

    // =========================================================================
    // 12. Switch strategy back and forth (A -> B -> A)
    // =========================================================================

    function test_switchBackAndForth_preservesValue() public {
        _deposit(alice, 8_000e6);
        strategy.simulateYield(800e6);

        uint256 totalBefore = vault.totalAssets();

        _queueAndSwitch(owner, 1);
        assertApproxEqAbs(vault.totalAssets(), totalBefore, 1, "value preserved A->B");

        strategy2.simulateYield(400e6);

        _queueAndSwitch(owner, 0);

        uint256 totalAfterSwitch = vault.totalAssets();
        assertGt(totalAfterSwitch, 8_000e6, "more than principal preserved");

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceShares = vault.shares(alice);
        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        uint256 received = usdc.balanceOf(alice) - aliceBal;

        assertGe(received, 8_000e6, "principal preserved after A->B->A");
    }

    function test_switchThreeWay_ABC_preservesValue() public {
        _deposit(alice, 6_000e6);

        _queueAndSwitch(owner, 1);
        assertApproxEqAbs(vault.totalAssets(), 6_000e6, 1, "value preserved A->B");

        strategy2.simulateYield(300e6);

        _queueAndSwitch(owner, 2);
        assertApproxEqAbs(vault.totalAssets(), 6_300e6, 1, "value preserved B->C");

        strategy3.simulateYield(200e6);

        _queueAndSwitch(owner, 0);

        uint256 totalAfter = vault.totalAssets();
        assertGt(totalAfter, 6_000e6, "more than original principal preserved");
    }

    function test_switchEmptyVault_backAndForth() public {
        _queueAndSwitch(owner, 1);
        assertEq(vault.activeStrategyIndex(), 1);

        _queueAndSwitch(owner, 0);
        assertEq(vault.activeStrategyIndex(), 0);
    }

    // =========================================================================
    // 13. Operator rotation
    // =========================================================================

    function test_operatorRotation_oldLosesAccess() public {
        _deposit(alice, 5_000e6);

        vm.prank(owner);
        vault.setOperator(operatorA);

        _queueAndSwitch(operatorA, 1);
        assertEq(vault.activeStrategyIndex(), 1);

        vm.prank(owner);
        vault.setOperator(operatorB);

        vm.prank(operatorA);
        vm.expectRevert(AutoYieldVault.NotAuthorized.selector);
        vault.queueStrategySwitchTo(0);

        _queueAndSwitch(operatorB, 0);
        assertEq(vault.activeStrategyIndex(), 0);
    }

    function test_operatorRotation_toZeroAddress() public {
        vm.prank(owner);
        vault.setOperator(operatorA);

        vm.prank(owner);
        vault.setOperator(address(0));

        vm.prank(operatorA);
        vm.expectRevert(AutoYieldVault.NotAuthorized.selector);
        vault.queueStrategySwitchTo(1);

        _queueAndSwitch(owner, 1);
    }

    function test_operatorCannotSetOperator() public {
        vm.prank(owner);
        vault.setOperator(operatorA);

        vm.prank(operatorA);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setOperator(operatorB);
    }

    // =========================================================================
    // 14. Deposit correctness around strategy switch boundaries
    // =========================================================================

    function test_depositBeforeAndAfterSwitch_correctShares() public {
        uint256 aliceShares = _deposit(alice, 5_000e6);

        strategy.simulateYield(500e6);

        _queueAndSwitch(owner, 1);

        uint256 bobShares = _deposit(bob, 5_500e6);
        // Bob: 5500 at price 1.1 → 5000 * SHARE_MULT
        assertApproxEqAbs(bobShares, 5_000e6 * SHARE_MULT, SHARE_MULT, "bob shares priced correctly after switch");

        assertApproxEqAbs(vault.shares(alice), vault.shares(bob), SHARE_MULT, "equal shares");
        assertApproxEqAbs(
            vault.previewRedeem(vault.shares(alice)),
            vault.previewRedeem(vault.shares(bob)),
            1,
            "equal values"
        );
    }

    function test_depositImmediatelyAfterSwitch_noValueLeak() public {
        _deposit(alice, 10_000e6);
        strategy.simulateYield(1_000e6);

        _queueAndSwitch(owner, 1);

        _deposit(bob, 11_000e6);

        assertApproxEqAbs(vault.totalAssets(), 22_000e6, 2,
            "totalAssets is sum of both deposits + yield");
    }

    // =========================================================================
    // 15. Withdrawal correctness around strategy switch boundaries
    // =========================================================================

    function test_withdrawImmediatelyAfterSwitch_valueAvailable() public {
        _deposit(alice, 8_000e6);
        strategy.simulateYield(800e6);

        _queueAndSwitch(owner, 1);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceShares = vault.shares(alice);
        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        uint256 received = usdc.balanceOf(alice) - aliceBal;

        assertGe(received, 8_000e6, "at least principal returned after switch");
    }

    function test_partialWithdrawThenSwitch_thenWithdrawRest() public {
        uint256 aliceShares = _deposit(alice, 10_000e6);
        strategy.simulateYield(1_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Partial withdraw: half shares
        uint256 halfShares = aliceShares / 2;
        vm.prank(alice);
        uint256 firstReceived = vault.withdraw(halfShares);
        // Virtual offset rounding: allow 2 wei tolerance
        assertApproxEqAbs(firstReceived, 5_500e6, 2);

        _queueAndSwitch(owner, 1);

        uint256 remainingShares = vault.shares(alice);
        assertEq(remainingShares, halfShares);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(remainingShares);
        uint256 secondReceived = usdc.balanceOf(alice) - aliceBal;

        // Virtual offset rounding: allow 2 wei tolerance
        assertApproxEqAbs(secondReceived, 5_500e6, 2,
            "second withdraw returns full proportional assets after switch");
    }

    // =========================================================================
    // Bonus: Yield accrual timing attack
    // =========================================================================

    function test_yieldTimingAttack_dilutedByExistingDepositors() public {
        _deposit(alice, 10_000e6);
        _deposit(attacker, 10_000e6);

        strategy.simulateYield(2_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 attackerShares = vault.shares(attacker);
        uint256 attackerBal = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.withdraw(attackerShares);
        uint256 attackerReceived = usdc.balanceOf(attacker) - attackerBal;

        // Virtual offset rounding: allow 2 wei tolerance
        assertApproxEqAbs(attackerReceived, 11_000e6, 2,
            "attacker only gets proportional yield, diluted by alice");

        uint256 aliceShares = vault.shares(alice);
        uint256 alicePreview = vault.previewRedeem(aliceShares);
        assertApproxEqAbs(alicePreview, 11_000e6, 2,
            "alice gets equal proportional yield");
    }

    // =========================================================================
    // Bonus: Complex interleaving with yield
    // =========================================================================

    function test_complexInterleaving_accountingInvariant() public {
        uint256 aliceShares = _deposit(alice, 5_000e6);

        strategy.simulateYield(250e6);

        uint256 bobShares = _deposit(bob, 5_250e6);

        strategy.simulateYield(500e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Alice partial withdraw (half shares)
        uint256 aliceHalf = aliceShares / 2;
        vm.prank(alice);
        vault.withdraw(aliceHalf);

        // Carol deposits
        uint256 carolShares = _deposit(carol, 4_125e6);
        assertApproxEqAbs(carolShares, 3_750e6 * SHARE_MULT, SHARE_MULT);

        uint256 expectedTotal = vault.shares(alice) + vault.shares(bob) + vault.shares(carol);
        assertEq(vault.totalShares(), expectedTotal, "share accounting invariant");

        uint256 sumPreviews = vault.previewRedeem(vault.shares(alice))
            + vault.previewRedeem(vault.shares(bob))
            + vault.previewRedeem(vault.shares(carol));
        assertApproxEqAbs(sumPreviews, vault.totalAssets(), 3,
            "preview sum equals totalAssets");
    }

    // =========================================================================
    // Bonus: Repeated strategy switches under load
    // =========================================================================

    function test_repeatedSwitchesUnderLoad_noValueDrift() public {
        _deposit(alice, 10_000e6);
        _deposit(bob, 5_000e6);

        uint256 initialTotal = vault.totalAssets();

        uint256 ts = block.timestamp;
        for (uint256 i = 0; i < 10; i++) {
            uint256 target = (vault.activeStrategyIndex() == 0) ? 1 : 0;
            vm.prank(owner);
            vault.queueStrategySwitchTo(target);
            ts += 24 hours + 1;
            vm.warp(ts);
            vm.prank(owner);
            vault.switchStrategy(target);
        }

        assertApproxEqAbs(vault.totalAssets(), initialTotal, 10,
            "no value drift after 10 strategy switches");
    }

    // =========================================================================
    // Bonus: getStrategyAPYs and getBestStrategyIndex
    // =========================================================================

    function test_getBestStrategyIndex_afterAPYChange() public {
        strategy.setEstimatedAPY(300);
        strategy2.setEstimatedAPY(500);
        strategy3.setEstimatedAPY(200);

        (uint256 bestIdx, uint256 bestAPY) = vault.getBestStrategyIndex();
        assertEq(bestIdx, 1, "strategy B has highest APY");
        assertEq(bestAPY, 500);

        strategy3.setEstimatedAPY(700);

        (bestIdx, bestAPY) = vault.getBestStrategyIndex();
        assertEq(bestIdx, 2, "strategy C now has highest APY");
        assertEq(bestAPY, 700);
    }

    // =========================================================================
    // Fuzz: interleaved deposit-withdraw preserves invariants
    // =========================================================================

    function testFuzz_depositWithdrawInterleaved_sharesInvariant(
        uint256 aliceAmt,
        uint256 bobAmt,
        uint256 yieldAmt,
        uint256 withdrawFraction
    ) public {
        uint256 minDep = vault.MINIMUM_FIRST_DEPOSIT();
        aliceAmt = bound(aliceAmt, minDep, INITIAL / 2);
        bobAmt   = bound(bobAmt, minDep, INITIAL / 2);
        yieldAmt = bound(yieldAmt, 0, 100_000e6);
        withdrawFraction = bound(withdrawFraction, 1, 100);

        usdc.mint(alice, aliceAmt);
        usdc.mint(bob, bobAmt);

        uint256 aliceShares = _deposit(alice, aliceAmt);
        uint256 bobShares   = _deposit(bob, bobAmt);

        strategy.simulateYield(yieldAmt);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Alice partially withdraws
        uint256 aliceWithdrawShares = (aliceShares * withdrawFraction) / 100;
        if (aliceWithdrawShares > 0) {
            vm.prank(alice);
            vault.withdraw(aliceWithdrawShares);
        }

        // Invariant: shares(alice) + shares(bob) == totalShares
        uint256 sumShares = vault.shares(alice) + vault.shares(bob);
        assertEq(sumShares, vault.totalShares(), "share invariant holds under fuzz");
    }
}
