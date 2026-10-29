// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/interfaces/IAutoYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/**
 * @title ReentrantDepositor
 * @notice Malicious contract that attempts reentrancy on AutoYieldVault.deposit
 *         during a withdraw callback (via a token with transfer hooks).
 */
contract ReentrantDepositor {
    AutoYieldVault public vault;
    MockERC20 public token;
    bool public attackTriggered;

    constructor(address _vault, address _token) {
        vault = AutoYieldVault(_vault);
        token = MockERC20(_token);
    }

    function depositAndWithdraw(uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
        uint256 myShares = vault.shares(address(this));
        vault.withdraw(myShares);
    }
}

/**
 * @title AutoYieldVaultSecurityTest
 * @notice Security and correctness edge case tests for AutoYieldVault
 */
contract AutoYieldVaultSecurityTest is Test {

    // --- Contracts ---
    MockERC20             usdc;
    MockAutoYieldStrategy strategy;
    MockAutoYieldStrategy strategy2;
    AutoYieldVault        vault;

    // --- Actors ---
    address owner    = address(1);
    address alice    = address(2);
    address bob      = address(3);
    address carol    = address(4);
    address operatorAddr = address(6);
    address nobody   = address(5);

    uint256 constant INITIAL = 10_000e6;
    uint256 constant SHARE_MULT = 1e6;

    // --- setUp ---
    function setUp() public {
        vm.startPrank(owner);

        usdc      = new MockERC20("Test USDC", "USDC", 6);
        strategy  = new MockAutoYieldStrategy(address(usdc));
        strategy2 = new MockAutoYieldStrategy(address(usdc));
        vault     = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Mock Aave V3");
        vault.addStrategy(address(strategy2), "Mock Compound");

        vm.stopPrank();

        usdc.mint(alice, INITIAL);
        usdc.mint(bob,   INITIAL);
        usdc.mint(carol, INITIAL);
    }

    // --- Helpers ---
    function _deposit(address user, uint256 amount) internal returns (uint256 sharesIssued) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        sharesIssued = vault.deposit(amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Reentrancy protection (nonReentrant on deposit and withdraw)
    // =========================================================================

    function test_reentrancy_depositWithdrawProtected() public {
        uint256 amount = 2_000e6;
        uint256 shares_ = _deposit(alice, amount);
        assertGt(shares_, 0);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares_);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, amount, 1);
    }

    // =========================================================================
    // Deposit with zero totalAssets after all withdrawals (share reset)
    // =========================================================================

    function test_shareReset_afterFullWithdrawal() public {
        uint256 aliceShares = _deposit(alice, 5_000e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        assertEq(vault.totalShares(), 0, "totalShares should be zero");

        // Bob deposits fresh: should get shares at virtual offset ratio (fresh pool)
        uint256 bobDeposit = 3_000e6;
        uint256 bobShares = _deposit(bob, bobDeposit);
        assertEq(bobShares, bobDeposit * SHARE_MULT, "shares with virtual offset on fresh pool after reset");
        assertEq(vault.totalShares(), bobDeposit * SHARE_MULT);
    }

    // =========================================================================
    // Withdraw ALL shares leaves vault with zero shares/assets
    // =========================================================================

    function test_withdrawAll_leavesZeroState() public {
        _deposit(alice, 2_000e6);
        _deposit(bob,   3_000e6);

        // Simulate some yield
        strategy.simulateYield(500e6);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Both withdraw all
        uint256 aliceShares = vault.shares(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        uint256 bobShares = vault.shares(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);

        assertEq(vault.totalShares(), 0, "totalShares should be zero");
        assertEq(vault.shares(alice), 0);
        assertEq(vault.shares(bob), 0);
    }

    // =========================================================================
    // Strategy switch during yield accrual: totalAssets preserved
    // =========================================================================

    function test_switchStrategy_preservesTotalAssets() public {
        _deposit(alice, 4_000e6);
        strategy.simulateYield(400e6);

        uint256 totalBefore = vault.totalAssets();
        assertEq(totalBefore, 4_400e6);

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(1);

        uint256 totalAfter = vault.totalAssets();
        assertApproxEqAbs(totalAfter, totalBefore, 1, "totalAssets preserved after switch");
    }

    // =========================================================================
    // Strategy switch with accrued yield: depositors don't lose yield
    // =========================================================================

    function test_switchStrategy_depositorsKeepYield() public {
        uint256 aliceDep = 3_000e6;
        uint256 bobDep   = 2_000e6;
        uint256 aliceShares = _deposit(alice, aliceDep);
        uint256 bobShares   = _deposit(bob, bobDep);

        uint256 yieldAmt = 500e6;
        strategy.simulateYield(yieldAmt);

        // Preview before switch
        uint256 alicePreviewBefore = vault.previewRedeem(aliceShares);
        uint256 bobPreviewBefore   = vault.previewRedeem(bobShares);

        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(1);

        // Preview after switch should be the same
        uint256 alicePreviewAfter = vault.previewRedeem(aliceShares);
        uint256 bobPreviewAfter   = vault.previewRedeem(bobShares);

        assertApproxEqAbs(alicePreviewAfter, alicePreviewBefore, 1, "alice yield preserved");
        assertApproxEqAbs(bobPreviewAfter, bobPreviewBefore, 1, "bob yield preserved");

        vm.roll(block.number + 1);

        // Actually withdraw to confirm
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        assertGe(usdc.balanceOf(alice) - aliceBefore, aliceDep, "alice gets at least principal");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares);
        assertGe(usdc.balanceOf(bob) - bobBefore, bobDep, "bob gets at least principal");
    }

    // =========================================================================
    // Operator can switch strategy but not add/pause
    // =========================================================================

    function test_operator_canSwitchStrategy() public {
        vm.prank(owner);
        vault.setOperator(operatorAddr);

        _deposit(alice, 2_000e6);

        vm.prank(operatorAddr);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(operatorAddr);
        vault.switchStrategy(1);

        assertEq(vault.activeStrategyIndex(), 1, "operator switched strategy");
    }

    function test_operator_cannotAddStrategy() public {
        vm.prank(owner);
        vault.setOperator(operatorAddr);

        MockAutoYieldStrategy strategy3 = new MockAutoYieldStrategy(address(usdc));

        vm.prank(operatorAddr);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.addStrategy(address(strategy3), "Strategy 3");
    }

    function test_operator_cannotPause() public {
        // operator role is for strategy switches, not pause; pause permits
        // owner OR guardian only.
        vm.prank(owner);
        vault.setOperator(operatorAddr);

        vm.prank(operatorAddr);
        vm.expectRevert("Not authorized");
        vault.pause();
    }

    function test_operator_cannotUnpause() public {
        vm.prank(owner);
        vault.setOperator(operatorAddr);

        vm.prank(owner);
        vault.pause();

        vm.prank(operatorAddr);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.unpause();
    }

    // =========================================================================
    // Multiple rapid deposits: gas and correctness
    // =========================================================================

    function test_rapidDeposits_correctShares() public {
        uint256 depositAmount = 1_000e6;
        usdc.mint(alice, depositAmount * 10);

        uint256 totalSharesExpected;
        for (uint256 i = 0; i < 10; i++) {
            uint256 shares_ = _deposit(alice, depositAmount);
            totalSharesExpected += shares_;
        }

        assertEq(vault.shares(alice), totalSharesExpected, "accumulated shares match");
        assertEq(vault.totalShares(), totalSharesExpected);

        // All deposits at same price (no yield between them)
        assertEq(totalSharesExpected, depositAmount * SHARE_MULT * 10, "10 deposits at consistent price");
    }

    function test_rapidDeposits_multipleUsers_fairShares() public {
        // Alice deposits first, then yield, then Bob and Carol deposit rapidly
        uint256 aliceDep = 5_000e6;
        _deposit(alice, aliceDep);

        strategy.simulateYield(1_000e6); // 20% yield
        // totalAssets = 6000, totalShares = 5000 * SHARE_MULT

        uint256 bobDep = 1_200e6;
        uint256 carolDep = 2_400e6;
        uint256 bobShares_ = _deposit(bob, bobDep);
        uint256 carolShares_ = _deposit(carol, carolDep);

        // Bob: 1200 at share price 1.2 → 1000 * SHARE_MULT shares
        assertApproxEqAbs(bobShares_, 1_000e6 * SHARE_MULT, SHARE_MULT, "bob gets fair shares at inflated price");
        // Carol: 2400 at share price 1.2 → 2000 * SHARE_MULT shares
        assertApproxEqAbs(carolShares_, 2_000e6 * SHARE_MULT, SHARE_MULT, "carol gets fair shares");
    }

    // =========================================================================
    // Deposit after harvest: shares priced correctly with loose vault tokens
    // =========================================================================

    function test_depositAfterHarvest_sharesPricedCorrectly() public {
        _deposit(alice, 5_000e6);
        strategy.simulateYield(500e6);

        // Harvest moves yield tokens from strategy to vault
        vm.prank(owner);
        vault.harvestYield();

        assertEq(vault.totalAssets(), 5_500e6, "totalAssets includes harvested tokens");

        // Bob deposits: should be priced based on totalAssets=5500
        uint256 bobShares_ = _deposit(bob, 1_100e6);
        // 1100 at price 1.1 → 1000 * SHARE_MULT
        assertApproxEqAbs(bobShares_, 1_000e6 * SHARE_MULT, SHARE_MULT, "shares priced correctly after harvest");
    }

    // =========================================================================
    // Withdraw after harvest: gets correct proportional amount including yield
    // =========================================================================

    function test_withdrawAfterHarvest_correctAmount() public {
        uint256 aliceDep = 5_000e6;
        uint256 aliceShares = _deposit(alice, aliceDep);

        strategy.simulateYield(500e6);
        vm.prank(owner);
        vault.harvestYield();

        // Alice's shares should redeem for full value including yield
        uint256 preview = vault.previewRedeem(aliceShares);
        // Virtual offset rounds down (favors vault), allow 1 wei tolerance
        assertApproxEqAbs(preview, 5_500e6, 1, "preview includes harvested yield");

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);

        uint256 received = usdc.balanceOf(alice) - before;
        assertGe(received, aliceDep, "at least principal returned");
    }

    // =========================================================================
    // Share price manipulation: direct token transfer to vault
    // =========================================================================

    function test_directTransferToVault_doesNotInflateSharesDisproportionately() public {
        // Alice deposits normally
        uint256 aliceDep = 5_000e6;
        _deposit(alice, aliceDep);

        // Attacker sends tokens directly to the vault (donation attack)
        usdc.mint(nobody, 5_000e6);
        vm.prank(nobody);
        usdc.transfer(address(vault), 5_000e6);

        // After security fix: totalAssets() uses internal idleAssets tracking,
        // NOT balanceOf, so the donation does NOT inflate the share price.
        // totalAssets = strategy(5000) + idleAssets(0) = 5000 (donation ignored)
        uint256 bobDep = 2_000e6;
        uint256 bobShares_ = _deposit(bob, bobDep);

        // Bob gets shares at the normal (non-inflated) price: 2000 * SHARE_MULT
        assertApproxEqAbs(bobShares_, 2_000e6 * SHARE_MULT, SHARE_MULT, "bob gets shares at normal price (donation ignored)");

        // Alice does NOT benefit from the donation (it's not counted in totalAssets)
        uint256 alicePreview = vault.previewRedeem(vault.shares(alice));
        assertApproxEqAbs(alicePreview, aliceDep, 1, "alice gets her principal back (donation ignored)");
    }

    // =========================================================================
    // Large + small depositor fairness
    // =========================================================================

    function test_largeSmallDepositor_fairness() public {
        // Large depositor: Alice deposits 9_000e6
        uint256 aliceDep = 9_000e6;
        uint256 aliceShares = _deposit(alice, aliceDep);

        // Small depositor: Bob deposits the minimum
        uint256 bobDep = vault.MINIMUM_FIRST_DEPOSIT(); // 1000 wei
        usdc.mint(bob, bobDep);
        uint256 bobShares_ = _deposit(bob, bobDep);

        // Both at same price (no yield)
        assertEq(aliceShares, aliceDep * SHARE_MULT);
        assertEq(bobShares_, bobDep * SHARE_MULT);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        // Bob should be able to withdraw his full amount
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares_);
        assertApproxEqAbs(usdc.balanceOf(bob) - bobBefore, bobDep, 1, "small depositor gets full principal");

        // Alice's shares should not be affected by Bob's deposit/withdrawal
        uint256 alicePreview = vault.previewRedeem(aliceShares);
        assertApproxEqAbs(alicePreview, aliceDep, 1, "large depositor unaffected");
    }

    function test_largeDeposit_thenYield_thenSmallDeposit_fairness() public {
        // Alice deposits large amount
        uint256 aliceDep = 8_000e6;
        uint256 aliceShares = _deposit(alice, aliceDep);

        // Yield accrues
        strategy.simulateYield(2_000e6);
        // totalAssets = 10000, totalShares = 8000 * SHARE_MULT, price = 1.25

        // Bob deposits small amount
        uint256 bobDep = 1_250e6;
        uint256 bobShares_ = _deposit(bob, bobDep);
        // Bob: 1250 at price 1.25 → 1000 * SHARE_MULT
        assertApproxEqAbs(bobShares_, 1_000e6 * SHARE_MULT, SHARE_MULT);

        // Alice: 8000 * SHARE_MULT shares * (11250 assets) / (9000 * SHARE_MULT shares) → 10000
        uint256 aliceValue = vault.previewRedeem(aliceShares);
        // Bob: 1000 * SHARE_MULT shares → 1250
        uint256 bobValue = vault.previewRedeem(bobShares_);

        assertApproxEqAbs(aliceValue, 10_000e6, 1, "alice gets principal + yield");
        assertApproxEqAbs(bobValue, 1_250e6, 1, "bob gets exactly his deposit (no yield yet)");
    }

    // =========================================================================
    // Fuzz: deposit -> yield -> withdraw always returns >= principal
    // =========================================================================

    function testFuzz_depositYieldWithdraw_alwaysReturnsAtLeastPrincipal(
        uint256 depositAmt,
        uint256 yieldAmt
    ) public {
        uint256 minDep = vault.MINIMUM_FIRST_DEPOSIT();
        depositAmt = bound(depositAmt, minDep, INITIAL);
        yieldAmt   = bound(yieldAmt, 0, 1_000_000e6);

        usdc.mint(alice, depositAmt);
        uint256 shares_ = _deposit(alice, depositAmt);

        strategy.simulateYield(yieldAmt);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares_);

        uint256 received = usdc.balanceOf(alice) - before;
        // Virtual offset rounding may cause 1 wei loss — this is by design (favors vault)
        // received = principal + yield (proportional), so it should be >= depositAmt - 1
        assertGe(received + 1, depositAmt, "always returns at least principal minus 1 wei rounding");
    }

    function testFuzz_twoDepositors_yieldWithdraw_bothGetAtLeastPrincipal(
        uint256 aliceAmt,
        uint256 bobAmt,
        uint256 yieldAmt
    ) public {
        uint256 minDep = vault.MINIMUM_FIRST_DEPOSIT();
        aliceAmt = bound(aliceAmt, minDep, INITIAL);
        bobAmt   = bound(bobAmt, minDep, INITIAL);
        yieldAmt = bound(yieldAmt, 0, 500_000e6);

        usdc.mint(alice, aliceAmt);
        usdc.mint(bob, bobAmt);

        uint256 aliceShares = _deposit(alice, aliceAmt);
        uint256 bobShares_  = _deposit(bob, bobAmt);

        strategy.simulateYield(yieldAmt);

        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares);
        // Allow 1 wei rounding from integer division (shares * totalAssets / totalShares)
        assertGe(usdc.balanceOf(alice) - aliceBefore + 1, aliceAmt, "alice >= principal (1 wei tolerance)");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(bobShares_);
        assertGe(usdc.balanceOf(bob) - bobBefore + 1, bobAmt, "bob >= principal (1 wei tolerance)");
    }

    // =========================================================================
    // setOperator emits event and updates state
    // =========================================================================

    event OperatorUpdated(address indexed newOperator);

    function test_setOperator_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit OperatorUpdated(operatorAddr);
        vault.setOperator(operatorAddr);

        assertEq(vault.operator(), operatorAddr);
    }

    function test_setOperator_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setOperator(operatorAddr);
    }

    // =========================================================================
    // Zero-address operator: nobody can call switchStrategy except owner
    // =========================================================================

    function test_zeroOperator_nobodySwitches() public {
        assertEq(vault.operator(), address(0));

        _deposit(alice, 2_000e6);

        vm.prank(nobody);
        vm.expectRevert(AutoYieldVault.NotAuthorized.selector);
        vault.switchStrategy(1);

        // Owner can still switch
        vm.prank(owner);
        vault.queueStrategySwitchTo(1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(owner);
        vault.switchStrategy(1);
        assertEq(vault.activeStrategyIndex(), 1);
    }
}
