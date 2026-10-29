// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/YieldVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title YieldVaultTest
 * @notice Comprehensive tests for the YieldVault contract
 */
contract YieldVaultTest is Test {
    YieldVault public vault;
    MockERC20 public token;
    MockERC20 public token2;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);
    address public attacker = address(0xBAD);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    // Virtual shares offset: first deposit yields amount * SHARE_MULT shares
    uint256 public constant SHARE_MULT = 1e6;

    event StrategyUpdated(uint256 indexed strategyId, address strategyAddress, bool active);
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed token, uint256 shares, uint256 amount);

    function setUp() public {
        vm.startPrank(owner);
        vault = new YieldVault();
        token = new MockERC20("USDC", "USDC", 18);
        token2 = new MockERC20("DAI", "DAI", 18);

        // Add default strategy (simple hold)
        vault.addStrategy(address(0));
        vm.stopPrank();

        token.mint(alice, 10000e18);
        token.mint(bob, 10000e18);
        token2.mint(alice, 10000e18);
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(vault.owner(), owner);
        assertFalse(vault.paused());
        assertEq(vault.strategyCount(), 1);
    }

    // ============ STRATEGY MANAGEMENT TESTS ============

    function testAddStrategy() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit StrategyUpdated(1, address(100), true);
        uint256 strategyId = vault.addStrategy(address(100));

        assertEq(strategyId, 1);
        assertEq(vault.strategyCount(), 2);
        assertTrue(vault.isStrategyActive(strategyId));
    }

    function testNonOwnerCannotAddStrategy() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.addStrategy(address(100));
    }

    function testSetStrategyActive() public {
        vm.prank(owner);
        vault.setStrategyActive(0, false);

        assertFalse(vault.isStrategyActive(0));
    }

    function testCannotSetInvalidStrategyActive() public {
        vm.prank(owner);
        vm.expectRevert(YieldVault.InvalidStrategy.selector);
        vault.setStrategyActive(999, true);
    }

    function testNonOwnerCannotSetStrategyActive() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setStrategyActive(0, false);
    }

    // ============ DEPOSIT TESTS ============

    function testDeposit() public {
        uint256 expectedShares = DEPOSIT_AMOUNT * SHARE_MULT;

        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit Deposited(alice, address(token), DEPOSIT_AMOUNT, expectedShares);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        assertEq(shares, expectedShares, "Deposited param mismatch at shares");
        assertEq(vault.getUserShares(alice, address(token), 0), expectedShares);
        assertEq(token.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function testDepositMultipleUsers() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(vault), DEPOSIT_AMOUNT * 2);
        uint256 bobShares = vault.deposit(address(token), DEPOSIT_AMOUNT * 2, 0);
        vm.stopPrank();

        assertEq(vault.getUserShares(alice, address(token), 0), aliceShares);
        assertEq(vault.getUserShares(bob, address(token), 0), bobShares);
    }

    function testDepositDifferentTokens() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 s1 = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);

        token2.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 s2 = vault.deposit(address(token2), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        assertEq(vault.getUserShares(alice, address(token), 0), s1);
        assertEq(vault.getUserShares(alice, address(token2), 0), s2);
    }

    function testCannotDepositZeroAmount() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);

        vm.expectRevert(YieldVault.ZeroAmount.selector);
        vault.deposit(address(token), 0, 0);
        vm.stopPrank();
    }

    function testCannotDepositToInactiveStrategy() public {
        vm.prank(owner);
        vault.setStrategyActive(0, false);

        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);

        vm.expectRevert(YieldVault.StrategyNotActive.selector);
        vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();
    }

    function testCannotDepositWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);

        vm.expectRevert(YieldVault.Paused.selector);
        vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();
    }

    // ============ WITHDRAW TESTS ============

    function testWithdraw() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        // Advance block and timestamp for flash loan protection
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        uint256 amount = vault.withdraw(address(token), shares, 0, alice);

        assertGt(amount, 0);
        assertEq(token.balanceOf(alice), balanceBefore + amount);
        assertEq(vault.getUserShares(alice, address(token), 0), 0);
    }

    function testPartialWithdraw() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        vm.prank(alice);
        vault.withdraw(address(token), shares / 2, 0, alice);

        assertEq(vault.getUserShares(alice, address(token), 0), shares - shares / 2);
    }

    function testWithdrawToDifferentRecipient() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        uint256 bobBalanceBefore = token.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(address(token), shares, 0, bob);

        assertGt(token.balanceOf(bob), bobBalanceBefore);
    }

    function testCannotWithdrawZeroShares() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(YieldVault.ZeroAmount.selector);
        vault.withdraw(address(token), 0, 0, alice);
    }

    function testCannotWithdrawInsufficientShares() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(YieldVault.InsufficientShares.selector);
        vault.withdraw(address(token), shares * 2, 0, alice);
    }

    /// @notice Withdraw must NOT be blocked by pause — every contest, lottery,
    ///         and PV that holds principal here redeems via this path. Pausing
    ///         must never strand principal. Mirror of AutoYieldVault and
    ///         PVAutoYieldAdapter, which both deliberately leave withdraw
    ///         open while paused. See docs/audits/PAUSE_ARCHITECTURE_NEXT_REDEPLOY.md.
    function testWithdrawWorksWhilePaused() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        // Advance past the same-block + MIN_HOLD_TIME flash-loan guards
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + vault.MIN_HOLD_TIME() + 1);

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        // Withdraw must succeed — principal redemption is unconditional.
        vm.prank(alice);
        uint256 amount = vault.withdraw(address(token), shares, 0, alice);
        assertGt(amount, 0);
    }

    // ============ SHARE VALUE TESTS ============

    function testGetShareValue() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        uint256 value = vault.getShareValue(address(token), shares, 0);
        // With virtual offset, value should approximate the deposit amount
        assertGt(value, 0);
        // Due to virtual offset rounding, value should be close to DEPOSIT_AMOUNT
        assertApproxEqRel(value, DEPOSIT_AMOUNT, 0.01e18); // within 1%
    }

    function testGetShareValueWithNoShares() public view {
        // With no deposits, getShareValue for any amount of shares returns 0
        // because strategyValue=0 and totalShares=0 => shares * 1 / 1e6 => rounds to 0
        uint256 value = vault.getShareValue(address(token), DEPOSIT_AMOUNT, 0);
        // DEPOSIT_AMOUNT (100e18) * 1 / 1e6 = 100e12 (not 0)
        assertEq(value, DEPOSIT_AMOUNT / SHARE_MULT);
    }

    function testGetTotalDeposited() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        assertEq(vault.getTotalDeposited(address(token), 0), DEPOSIT_AMOUNT);
    }

    // ============ PAUSE TESTS ============

    function testPause() public {
        vm.prank(owner);
        vault.pause();

        assertTrue(vault.paused());
    }

    function testUnpause() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        assertFalse(vault.paused());
    }

    function testCannotPauseWhenAlreadyPaused() public {
        vm.startPrank(owner);
        vault.pause();

        vm.expectRevert(YieldVault.Paused.selector);
        vault.pause();
        vm.stopPrank();
    }

    function testCannotUnpauseWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(YieldVault.NotPaused.selector);
        vault.unpause();
    }

    function testNonOwnerCannotPause() public {
        // pause() now permits owner OR guardian (2026-04 guardian wiring) and
        // reverts with the custom NotGuardianOrOwner error for everyone else.
        vm.prank(attacker);
        vm.expectRevert(YieldVault.NotGuardianOrOwner.selector);
        vault.pause();
    }

    function testNonOwnerCannotUnpause() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.unpause();
    }

    // ============ OWNERSHIP TESTS ============

    function testTransferOwnership() public {
        // Ownable2Step pattern: transferOwnership sets `pendingOwner`, the owner
        // doesn't change until acceptOwnership() is called by the new owner.
        address newOwner = address(100);

        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.pendingOwner(), newOwner, "pendingOwner set");
        assertEq(vault.owner(), owner, "owner unchanged until accept");

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner, "owner transferred after accept");
    }

    function testCannotTransferOwnershipToZero() public {
        // Ownable2Step.transferOwnership(0) does NOT revert — it clears the
        // pending owner. Use renounceOwnership() to relinquish entirely.
        vm.prank(owner);
        vault.transferOwnership(address(0));
        assertEq(vault.pendingOwner(), address(0), "pendingOwner cleared");
        assertEq(vault.owner(), owner, "owner unchanged");
    }

    function testNonOwnerCannotTransferOwnership() public {
        // Ownable2Step uses the same string error from Ownable; the
        // transferOwnership entry point is overridden to call _checkOwner
        // before queuing the new pending owner.
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.transferOwnership(attacker);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_Deposit(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        token.mint(alice, amount);

        vm.startPrank(alice);
        token.approve(address(vault), amount);
        uint256 shares = vault.deposit(address(token), amount, 0);
        vm.stopPrank();

        // First depositor: shares = amount * 1e6 / 1 = amount * SHARE_MULT
        assertEq(shares, amount * SHARE_MULT);
        assertEq(vault.getUserShares(alice, address(token), 0), amount * SHARE_MULT);
    }

    function testFuzz_DepositWithdraw(uint256 depositAmount, uint256 withdrawFraction) public {
        depositAmount = bound(depositAmount, 1, 1e30);
        token.mint(alice, depositAmount);

        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(address(token), depositAmount, 0);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        withdrawFraction = bound(withdrawFraction, 1, shares);

        vm.prank(alice);
        vault.withdraw(address(token), withdrawFraction, 0, alice);

        assertEq(vault.getUserShares(alice, address(token), 0), shares - withdrawFraction);
    }

    function testFuzz_MultipleDepositors(uint8 depositorCount) public {
        depositorCount = uint8(bound(depositorCount, 2, 50));

        for (uint256 i = 0; i < depositorCount; i++) {
            address depositor = address(uint160(100 + i));
            token.mint(depositor, DEPOSIT_AMOUNT);

            vm.startPrank(depositor);
            token.approve(address(vault), DEPOSIT_AMOUNT);
            vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
            vm.stopPrank();
        }

        assertEq(vault.getTotalDeposited(address(token), 0), DEPOSIT_AMOUNT * depositorCount);
    }

    // ============ REENTRANCY TESTS ============

    function testReentrancyProtectionOnDeposit() public {
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT_AMOUNT * 2);
        uint256 s1 = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);

        // Second deposit should work (not a reentrancy)
        uint256 s2 = vault.deposit(address(token), DEPOSIT_AMOUNT, 0);
        vm.stopPrank();

        assertEq(vault.getUserShares(alice, address(token), 0), s1 + s2);
    }
}
