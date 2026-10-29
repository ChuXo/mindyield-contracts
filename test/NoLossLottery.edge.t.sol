// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/lottery/NoLossLottery.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockRandomnessManager.sol";

/**
 * @title NoLossLotteryEdgeTest
 * @notice Edge cases for NoLossLottery:
 *   - Multi-round end-to-end (participants stay across rounds)
 *   - Non-winner claimPrize reverts
 *   - Deposit after round end goes to new round's accounting
 *   - Withdraw mid-round reduces probability correctly
 *   - Withdraw entire balance removes participant
 *   - Multiple winners over multiple rounds
 *   - Round duration change takes effect on next round
 *   - DrawAlreadyPending / RoundAlreadySettled guards
 */
contract NoLossLotteryEdgeTest is Test {

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLottery         lottery;

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner   = address(1);
    address alice   = address(2);
    address bob     = address(3);
    address charlie = address(4);
    address dave    = address(5);
    address nobody  = address(6);

    // ─── Config ───────────────────────────────────────────────────────────────

    uint256 constant ROUND_DURATION  = 1 hours;
    uint256 constant INITIAL_BALANCE = 10_000e6;

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        usdc     = new MockERC20("Test USDC", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        strategy = new AaveStrategy(address(aavePool), address(usdc), address(aUsdc), address(0));
        randMgr  = new MockRandomnessManager();

        lottery = new NoLossLottery(
            address(usdc),
            address(strategy),
            address(randMgr),
            ROUND_DURATION
        );
        strategy.setYieldVault(address(lottery));

        vm.stopPrank();

        usdc.mint(alice,   INITIAL_BALANCE);
        usdc.mint(bob,     INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
        usdc.mint(dave,    INITIAL_BALANCE);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(lottery), amount);
        lottery.deposit(amount);
        vm.stopPrank();
    }

    function _triggerDraw() internal {
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
    }

    function _deliverRandom(uint256 word) internal {
        randMgr.deliverRandomness(address(lottery), word);
    }

    /// @dev Run a full round: trigger draw, deliver randomness, return winner
    function _settleRound(uint256 randomWord) internal returns (address winner) {
        _triggerDraw();
        _deliverRandom(randomWord);
        uint256 roundId = lottery.currentRoundId() - 1; // settled round
        NoLossLottery.Round memory r = lottery.getRound(roundId);
        winner = r.winner;
    }

    // =========================================================================
    // Multi-round: participants persist across rounds
    // =========================================================================

    function test_multiRound_participantsStay() public {
        _deposit(alice, 700e6);
        _deposit(bob,   300e6);

        // Round 1
        _settleRound(12345);
        assertEq(lottery.currentRoundId(), 2);

        // Balances unchanged after round ends (no withdrawal)
        assertEq(lottery.balances(alice), 700e6);
        assertEq(lottery.balances(bob),   300e6);
        assertEq(lottery.participantCount(), 2);
        assertEq(lottery.totalDeposited(), 1_000e6);
    }

    function test_multiRound_newParticipantCanJoinAfterRound() public {
        _deposit(alice, 500e6);

        _settleRound(99999);

        // Charlie joins in round 2
        _deposit(charlie, 400e6);

        assertEq(lottery.participantCount(), 2, "alice + charlie");
        assertEq(lottery.totalDeposited(), 900e6);
    }

    function test_multiRound_twoConsecutiveRounds() public {
        _deposit(alice, 600e6);
        _deposit(bob,   400e6);

        // Round 1 settle
        uint256 r1 = lottery.currentRoundId();
        _settleRound(111);
        NoLossLottery.Round memory round1 = lottery.getRound(r1);
        assertTrue(round1.isSettled);

        // Round 2 settle
        uint256 r2 = lottery.currentRoundId();
        assertEq(r2, r1 + 1);
        _settleRound(222);
        NoLossLottery.Round memory round2 = lottery.getRound(r2);
        assertTrue(round2.isSettled);

        assertEq(lottery.currentRoundId(), r1 + 2);
    }

    function test_multiRound_participantWinsTwice() public {
        // Alice has 100% of the pool — always wins
        _deposit(alice, 1_000e6);

        uint256 r1 = lottery.currentRoundId();
        _settleRound(0);
        NoLossLottery.Round memory round1 = lottery.getRound(r1);
        assertEq(round1.winner, alice);

        uint256 r2 = lottery.currentRoundId();
        _settleRound(0);
        NoLossLottery.Round memory round2 = lottery.getRound(r2);
        assertEq(round2.winner, alice);
    }

    // =========================================================================
    // Non-winner claimPrize reverts
    // =========================================================================

    function test_claimPrize_nonWinner_reverts() public {
        _deposit(alice, 1_000e6); // alice = 100% chance of winning

        uint256 roundId = lottery.currentRoundId();
        _settleRound(0); // alice wins with random word 0

        // Bob tries to claim prize
        vm.prank(bob);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(roundId);
    }

    function test_claimPrize_undeposited_user_reverts() public {
        _deposit(alice, 500e6);

        uint256 roundId = lottery.currentRoundId();
        _settleRound(42);

        // nobody was never a participant
        vm.prank(nobody);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(roundId);
    }

    function test_claimPrize_unsettledRound_reverts() public {
        _deposit(alice, 500e6);

        uint256 roundId = lottery.currentRoundId();
        // Don't settle — still in current round

        vm.prank(alice);
        vm.expectRevert(NoLossLottery.RoundNotSettled.selector);
        lottery.claimPrize(roundId);
    }

    function test_claimPrize_doubleClaim_reverts() public {
        _deposit(alice, 1_000e6);

        uint256 roundId = lottery.currentRoundId();
        aavePool.simulateYield(address(strategy), 50e6);
        _settleRound(0);

        // alice claims once (she won)
        NoLossLottery.Round memory r = lottery.getRound(roundId);
        if (r.winner == alice && r.prizeAmount > 0) {
            vm.prank(alice);
            lottery.claimPrize(roundId);

            // Double claim must revert
            vm.prank(alice);
            vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
            lottery.claimPrize(roundId);
        }
    }

    // =========================================================================
    // Deposit after round end
    // =========================================================================

    function test_deposit_afterRoundEnds_countedInNewRound() public {
        _deposit(alice, 500e6);

        uint256 r1 = lottery.currentRoundId();
        _triggerDraw();         // round 1 draw requested
        _deliverRandom(0);     // round 1 settled → round 2 starts

        assertEq(lottery.currentRoundId(), r1 + 1);

        // Bob deposits in round 2
        _deposit(bob, 300e6);

        // Bob should be visible in current totals
        assertEq(lottery.balances(bob), 300e6);
        assertEq(lottery.totalDeposited(), 500e6 + 300e6);
    }

    // =========================================================================
    // Withdraw mid-round removes participant from pool
    // =========================================================================

    function test_withdraw_entireBalance_zeroesBalance() public {
        _deposit(alice, 700e6);
        _deposit(bob,   300e6);

        // Alice fully withdraws
        vm.prank(alice);
        lottery.withdraw(700e6);

        assertEq(lottery.balances(alice), 0);
        assertEq(lottery.totalDeposited(), 300e6);
        // After the security fix, full withdrawal removes participant via swap-and-pop
        assertEq(lottery.participantCount(), 1);
        // Alice has 0% win probability
        assertEq(lottery.getWinProbability(alice), 0);
    }

    function test_withdraw_partial_keepParticipant() public {
        _deposit(alice, 700e6);

        vm.prank(alice);
        lottery.withdraw(200e6);

        assertEq(lottery.balances(alice), 500e6);
        assertEq(lottery.participantCount(), 1);
    }

    // =========================================================================
    // DrawAlreadyPending guard
    // =========================================================================

    function test_performUpkeep_whenPending_reverts() public {
        _deposit(alice, 500e6);

        _triggerDraw(); // sets drawPending = true

        // Second performUpkeep must fail
        vm.expectRevert(NoLossLottery.DrawAlreadyPending.selector);
        lottery.performUpkeep("");
    }

    // =========================================================================
    // NoActiveParticipants guard
    // =========================================================================

    function test_performUpkeep_noParticipants_reverts() public {
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        vm.expectRevert(NoLossLottery.NoActiveParticipants.selector);
        lottery.performUpkeep("");
    }

    function test_performUpkeep_afterFullWithdraw_reverts() public {
        _deposit(alice, 500e6);

        vm.prank(alice);
        lottery.withdraw(500e6);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        vm.expectRevert(NoLossLottery.NoActiveParticipants.selector);
        lottery.performUpkeep("");
    }

    // =========================================================================
    // Round duration change
    // =========================================================================

    function test_roundDuration_changeTakesEffectNextRound() public {
        _deposit(alice, 500e6);

        uint256 newDuration = 7 days;
        vm.prank(owner);
        lottery.setRoundDuration(newDuration);

        // Current round still uses old duration
        assertEq(lottery.roundDuration(), newDuration, "updated immediately");

        // Settle current round with original timing
        _settleRound(1);

        // New round should use new duration
        NoLossLottery.Round memory r = lottery.getCurrentRound();
        assertEq(r.endTime - r.startTime, newDuration, "new round uses new duration");
    }

    function test_roundDuration_tooShort_reverts() public {
        vm.prank(owner);
        vm.expectRevert("NoLossLottery: too short");
        lottery.setRoundDuration(30 minutes - 1);
    }

    function test_roundDuration_byNonOwner_reverts() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setRoundDuration(2 hours);
    }

    // =========================================================================
    // Win probability
    // =========================================================================

    function test_winProbability_proportional() public {
        _deposit(alice, 7_500e6);
        _deposit(bob,   2_500e6);

        uint256 aliceChance = lottery.getWinProbability(alice);
        uint256 bobChance   = lottery.getWinProbability(bob);

        // alice 75% = 7500 bps, bob 25% = 2500 bps (BASIS_POINTS = 10_000)
        assertEq(aliceChance, 7_500, "alice should have 7500 bps (75%)");
        assertEq(bobChance,   2_500, "bob should have 2500 bps (25%)");
    }

    function test_winProbability_afterWithdraw_updates() public {
        _deposit(alice, 600e6);
        _deposit(bob,   400e6);

        vm.prank(alice);
        lottery.withdraw(600e6);

        // Now bob has 100% = 10_000 bps
        uint256 bobChance   = lottery.getWinProbability(bob);
        uint256 aliceChance = lottery.getWinProbability(alice);

        assertEq(bobChance,   10_000, "bob should have 100%");
        assertEq(aliceChance, 0,      "alice has 0% after full withdraw");
    }

    // =========================================================================
    // Prize with yield
    // =========================================================================

    function test_prizeAmount_reflectsYield() public {
        _deposit(alice, 1_000e6);

        uint256 roundId = lottery.currentRoundId();
        uint256 yieldAmt = 100e6;
        aavePool.simulateYield(address(strategy), yieldAmt);

        _settleRound(0); // alice wins (100% probability)

        NoLossLottery.Round memory r = lottery.getRound(roundId);
        assertEq(r.winner, alice, "alice should win");
        assertApproxEqAbs(r.prizeAmount, yieldAmt, 1, "prize equals yield");
    }

    function test_prizeAmount_zeroWithNoYield() public {
        _deposit(alice, 500e6);

        uint256 roundId = lottery.currentRoundId();
        _settleRound(0);

        NoLossLottery.Round memory r = lottery.getRound(roundId);
        assertEq(r.prizeAmount, 0, "no yield = no prize");
    }

    // =========================================================================
    // fulfillRandomness — only randomness manager can call
    // =========================================================================

    function test_fulfillRandomness_byNonManager_reverts() public {
        _deposit(alice, 500e6);
        _triggerDraw();

        vm.prank(nobody);
        vm.expectRevert(NoLossLottery.NotRandomnessManager.selector);
        lottery.fulfillRandomness(12345);
    }

    // =========================================================================
    // Fuzz: multi-deposit, settle, winner is always a participant
    // =========================================================================

    function testFuzz_multiDeposit_winnerAlwaysParticipant(
        uint256[4] memory amounts,
        uint256 randomWord
    ) public {
        address[4] memory users = [alice, bob, charlie, dave];

        uint256 totalDeposit;
        for (uint i = 0; i < 4; i++) {
            amounts[i] = bound(amounts[i], 1e6, INITIAL_BALANCE);
            _deposit(users[i], amounts[i]);
            totalDeposit += amounts[i];
        }

        uint256 roundId = lottery.currentRoundId();
        _settleRound(randomWord);

        NoLossLottery.Round memory r = lottery.getRound(roundId);
        assertTrue(r.isSettled);

        // Winner must be one of the depositors
        address winner = r.winner;
        bool isParticipant = (winner == alice || winner == bob || winner == charlie || winner == dave);
        assertTrue(isParticipant, "winner must be a participant");
    }
}
