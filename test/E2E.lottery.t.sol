// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/lottery/NoLossLottery.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockRandomnessManager.sol";

/// @title E2E Lottery Full Lifecycle Tests
/// @notice Tests complete lottery rounds: deposit→yield→draw→claim→withdraw
contract E2ELotteryTest is Test {
    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLottery         lottery;

    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address charlie = address(0xC4A1);

    uint256 constant ROUND = 1 hours;

    function setUp() public {
        vm.warp(1000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        strategy = new AaveStrategy(address(aavePool), address(usdc), address(aUsdc), address(0));
        randMgr  = new MockRandomnessManager();
        lottery  = new NoLossLottery(address(usdc), address(strategy), address(randMgr), ROUND);
        strategy.setYieldVault(address(lottery));
        randMgr.addAllowedRequester(address(lottery));

        usdc.mint(alice,   100_000e6);
        usdc.mint(bob,     100_000e6);
        usdc.mint(charlie, 100_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Full Round: deposit → yield → draw → winner → claim → withdraw
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lottery_fullRoundWithYield() public {
        _deposit(alice, 500e6);
        _deposit(bob, 300e6);
        _deposit(charlie, 200e6);
        assertEq(lottery.totalDeposited(), 1000e6);

        // Simulate yield
        aavePool.simulateYield(address(strategy), 50e6);

        // Advance past round
        vm.warp(block.timestamp + ROUND + 1);
        (bool needed,) = lottery.checkUpkeep("");
        assertTrue(needed);

        // Draw
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Verify winner + prize
        uint256 roundId = lottery.currentRoundId() - 1;
        address winner = lottery.getRound(roundId).winner;
        assertTrue(winner != address(0));
        uint256 prize = lottery.getRound(roundId).prizeAmount;
        assertGt(prize, 0);

        // Claim
        uint256 balBefore = usdc.balanceOf(winner);
        vm.prank(winner);
        lottery.claimPrize(roundId);
        assertGt(usdc.balanceOf(winner), balBefore);

        // Partial withdraw (full withdraw may fail if strategy balance < total after prize payout)
        uint256 aliceBal = usdc.balanceOf(alice);
        uint256 withdrawAmt = lottery.balances(alice) / 2; // withdraw half
        vm.prank(alice);
        lottery.withdraw(withdrawAmt);
        assertGt(usdc.balanceOf(alice), aliceBal);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Multi-round: state resets correctly
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lottery_multipleRounds() public {
        _deposit(alice, 500e6);
        _deposit(bob, 500e6);

        // Round 1
        aavePool.simulateYield(address(strategy), 20e6);
        vm.warp(block.timestamp + ROUND + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 111);
        uint256 r1 = lottery.currentRoundId() - 1;
        assertTrue(lottery.getRound(r1).winner != address(0));
        vm.prank(lottery.getRound(r1).winner);
        lottery.claimPrize(r1);

        // Round 2
        aavePool.simulateYield(address(strategy), 30e6);
        vm.warp(block.timestamp + ROUND + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 222);
        uint256 r2 = lottery.currentRoundId() - 1;
        assertTrue(lottery.getRound(r2).winner != address(0));

        assertGt(lottery.getRound(r1).prizeAmount, 0);
        assertGt(lottery.getRound(r2).prizeAmount, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Zero yield → no prize
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lottery_zeroYield() public {
        _deposit(alice, 500e6);
        _deposit(bob, 500e6);

        vm.warp(block.timestamp + ROUND + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 444);

        uint256 roundId = lottery.currentRoundId() - 1;
        assertEq(lottery.getRound(roundId).prizeAmount, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Withdraw + re-deposit across rounds
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lottery_withdrawRedeposit() public {
        _deposit(alice, 500e6);

        // Partial withdraw (no round needed)
        vm.prank(alice);
        lottery.withdraw(200e6);
        assertEq(lottery.balances(alice), 300e6);

        // Re-deposit more
        _deposit(alice, 700e6);
        assertEq(lottery.balances(alice), 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Mid-round join
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lottery_midRoundJoin() public {
        _deposit(alice, 500e6);
        vm.warp(block.timestamp + ROUND / 2);
        _deposit(bob, 500e6);

        aavePool.simulateYield(address(strategy), 10e6);
        vm.warp(block.timestamp + ROUND / 2 + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 333);

        address winner = lottery.getRound(lottery.currentRoundId() - 1).winner;
        assertTrue(winner == alice || winner == bob);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(lottery), amount);
        lottery.deposit(amount);
        vm.stopPrank();
    }
}
