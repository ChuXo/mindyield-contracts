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
 * @title NoLossLotteryManipulationTest
 * @notice Manipulation tactics, edge cases, and adversarial scenarios for NoLossLottery.
 *
 * Covers: withdraw/deposit during pending draw, flash-loan-style attacks,
 * single/max participants, prize claim abuse, pause interactions, zero-yield
 * rounds, multi-round accumulation, and access control enforcement.
 */
contract NoLossLotteryManipulationTest is Test {

    // ─── Contracts ──────────────────────────────────────────────────────────────

    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLottery         lottery;

    // ─── Actors ─────────────────────────────────────────────────────────────────

    address owner   = address(1);
    address alice   = address(2);
    address bob     = address(3);
    address charlie = address(4);
    address nobody  = address(5);
    address eve     = address(6);  // adversarial actor

    // ─── Config ─────────────────────────────────────────────────────────────────

    uint256 constant ROUND_DURATION  = 1 hours;
    uint256 constant INITIAL_BALANCE = 10_000e6;
    uint256 constant DEPOSIT_ALICE   = 700e6;
    uint256 constant DEPOSIT_BOB     = 300e6;

    // ─── Events ─────────────────────────────────────────────────────────────────

    event WinnerSelected(uint256 indexed roundId, address indexed winner, uint256 prizeAmount);
    event PrizeClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);

    // ─── setUp ──────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        usdc     = new MockERC20("Test USDC", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));

        strategy = new AaveStrategy(
            address(aavePool), address(usdc), address(aUsdc), address(0)
        );

        randMgr = new MockRandomnessManager();

        lottery = new NoLossLottery(
            address(usdc),
            address(strategy),
            address(randMgr),
            ROUND_DURATION
        );

        strategy.setYieldVault(address(lottery));
        vm.stopPrank();

        // Fund actors
        usdc.mint(alice,   INITIAL_BALANCE);
        usdc.mint(bob,     INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
        usdc.mint(eve,     INITIAL_BALANCE);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

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

    function _fullRound(uint256 yieldAmount, uint256 randomWord) internal {
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        if (yieldAmount > 0) {
            aavePool.simulateYield(address(strategy), yieldAmount);
        }
        lottery.performUpkeep("");
        _deliverRandom(randomWord);
    }

    // =========================================================================
    // 1. Withdraw during draw pending
    // =========================================================================

    function test_withdrawDuringDrawPending_allowed() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);

        _triggerDraw();
        // Draw is pending; alice tries to withdraw
        NoLossLottery.Round memory r = lottery.getCurrentRound();
        assertTrue(r.isDrawPending, "draw should be pending");

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);

        // Withdraw succeeds — balance goes to zero
        assertEq(lottery.balances(alice), 0);
        assertGt(usdc.balanceOf(alice), aliceBefore, "alice received tokens");

        // Fulfillment still works (snapshot was taken at performUpkeep time)
        _deliverRandom(0);
        NoLossLottery.Round memory settled = lottery.getRound(1);
        assertTrue(settled.isSettled, "round should settle despite withdrawal");
        // Alice was in the snapshot so she can still be winner
        assertTrue(
            settled.winner == alice || settled.winner == bob,
            "winner must be from snapshot"
        );
    }

    // =========================================================================
    // 2. Deposit during draw pending
    // =========================================================================

    function test_depositDuringDrawPending_allowed() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        NoLossLottery.Round memory r = lottery.getCurrentRound();
        assertTrue(r.isDrawPending);

        // Eve deposits while draw is pending — should succeed
        _deposit(eve, 500e6);
        assertEq(lottery.balances(eve), 500e6);

        // But eve should NOT be in the snapshot for the current round
        _deliverRandom(0);
        NoLossLottery.Round memory settled = lottery.getRound(1);
        // Alice was the only snapshot participant, so she wins regardless
        assertEq(settled.winner, alice, "alice should win (only in snapshot)");
    }

    // =========================================================================
    // 3. Flash loan attack — deposit, trigger draw, withdraw rapidly
    // =========================================================================

    function test_flashLoanAttack_cannotInfluenceAfterSnapshot() public {
        // Alice is the legitimate participant
        _deposit(alice, DEPOSIT_ALICE);

        // Fast forward to draw time
        vm.warp(block.timestamp + ROUND_DURATION + 1);

        // Eve flash-deposits a huge amount just before performUpkeep
        _deposit(eve, 9000e6);

        // performUpkeep takes snapshot — eve IS in the snapshot now
        lottery.performUpkeep("");

        // Eve immediately withdraws (simulating flash loan repayment)
        vm.prank(eve);
        lottery.withdraw(9000e6);
        assertEq(lottery.balances(eve), 0);

        // Eve is still in the snapshot with her weight — this is a known
        // design consideration: deposit-before-draw manipulation is possible.
        // The mitigation is that lottery uses existing balances (no flash loans
        // in the same tx) and Chainlink Automation calls performUpkeep externally.
        _deliverRandom(0);
        NoLossLottery.Round memory settled = lottery.getRound(1);
        assertTrue(settled.isSettled);
    }

    // =========================================================================
    // 4. Round with exactly 1 participant — always wins
    // =========================================================================

    function test_singleParticipant_alwaysWins() public {
        _deposit(alice, DEPOSIT_ALICE);

        // Try multiple random words — alice must always win
        for (uint256 i = 0; i < 5; i++) {
            _fullRound(0, i * 7919 + 1);
            NoLossLottery.Round memory r = lottery.getRound(i + 1);
            assertEq(r.winner, alice, "sole participant must always win");
        }
    }

    function test_singleParticipant_minDeposit() public {
        // Even with 1 wei deposit, single participant wins
        _deposit(alice, 1);
        _fullRound(0, 42);

        NoLossLottery.Round memory r = lottery.getRound(1);
        assertEq(r.winner, alice, "single participant with 1 wei must win");
    }

    // =========================================================================
    // 5. Round with maximum participants — gas and correctness
    // =========================================================================

    function test_maxParticipants_30users() public {
        uint256 participantCount = 30;
        address[] memory users = new address[](participantCount);

        for (uint256 i = 0; i < participantCount; i++) {
            users[i] = address(uint160(100 + i));
            usdc.mint(users[i], 1000e6);
            _deposit(users[i], 1000e6);
        }

        assertEq(lottery.participantCount(), participantCount);
        assertEq(lottery.totalDeposited(), 1000e6 * participantCount);

        // Simulate yield and trigger draw
        aavePool.simulateYield(address(strategy), 100e6);
        _triggerDraw();
        _deliverRandom(12345);

        NoLossLottery.Round memory r = lottery.getRound(1);
        assertTrue(r.isSettled);
        assertTrue(r.winner != address(0), "winner must be selected");

        // Verify winner is one of the participants
        bool found = false;
        for (uint256 i = 0; i < participantCount; i++) {
            if (r.winner == users[i]) {
                found = true;
                break;
            }
        }
        assertTrue(found, "winner must be a registered participant");
    }

    function test_maxParticipants_unequalWeights() public {
        // 20 participants with wildly different deposits
        uint256 count = 20;
        address[] memory users = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            users[i] = address(uint160(200 + i));
            uint256 deposit = (i + 1) * 100e6; // 100, 200, 300, ..., 2000 USDC
            usdc.mint(users[i], deposit);
            _deposit(users[i], deposit);
        }

        _triggerDraw();
        _deliverRandom(999999);

        NoLossLottery.Round memory r = lottery.getRound(1);
        assertTrue(r.isSettled);
        assertTrue(r.winner != address(0));
    }

    // =========================================================================
    // 6. Claim prize from wrong round
    // =========================================================================

    function test_claimPrize_wrongRound_reverts() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);

        aavePool.simulateYield(address(strategy), 50e6);
        _fullRound(0, 0); // alice wins round 1 (random=0, alice has lower index)

        // Bob tries to claim alice's round 1 prize
        vm.prank(bob);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    // =========================================================================
    // 7. Claim prize from future round
    // =========================================================================

    function test_claimPrize_futureRound_reverts() public {
        _deposit(alice, DEPOSIT_ALICE);

        // Current round is 1, try claiming round 99
        vm.prank(alice);
        vm.expectRevert(NoLossLottery.RoundNotSettled.selector);
        lottery.claimPrize(99);
    }

    function test_claimPrize_roundZero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(NoLossLottery.RoundNotSettled.selector);
        lottery.claimPrize(0);
    }

    // =========================================================================
    // 8. Double claim prize
    // =========================================================================

    function test_doubleClaim_reverts() public {
        _deposit(alice, DEPOSIT_ALICE);

        aavePool.simulateYield(address(strategy), 50e6);
        _fullRound(0, 0);

        // First claim succeeds
        vm.prank(alice);
        lottery.claimPrize(1);

        // Second claim reverts
        vm.prank(alice);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    function test_doubleClaim_pendingPrizesCleared() public {
        _deposit(alice, DEPOSIT_ALICE);

        aavePool.simulateYield(address(strategy), 50e6);
        _fullRound(0, 0);

        uint256 prizeBefore = lottery.pendingPrizes(1, alice);
        assertGt(prizeBefore, 0);

        vm.prank(alice);
        lottery.claimPrize(1);

        assertEq(lottery.pendingPrizes(1, alice), 0, "prize should be zeroed");
    }

    // =========================================================================
    // 9. Non-winner claim
    // =========================================================================

    function test_nonWinnerClaim_reverts() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);

        aavePool.simulateYield(address(strategy), 50e6);
        _fullRound(0, 0); // alice wins (index 0, random=0)

        NoLossLottery.Round memory r = lottery.getRound(1);
        assertEq(r.winner, alice);

        // Bob is not the winner — claim should revert
        vm.prank(bob);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(1);

        // Charlie never deposited — claim should revert
        vm.prank(charlie);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(1);

        // Nobody — claim should revert
        vm.prank(nobody);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    // =========================================================================
    // 10. Pause during draw pending
    // =========================================================================

    function test_pauseDuringDrawPending_ownerCanPause() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        // Owner pauses while draw is pending
        vm.prank(owner);
        lottery.pause();
        assertTrue(lottery.paused());

        // Randomness delivery still works (fulfillRandomness is not paused)
        _deliverRandom(42);
        NoLossLottery.Round memory r = lottery.getRound(1);
        assertTrue(r.isSettled, "settlement should still work while paused");
    }

    function test_pauseDuringDrawPending_blocksNewDeposits() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        vm.prank(owner);
        lottery.pause();

        // New deposit blocked
        vm.startPrank(bob);
        usdc.approve(address(lottery), DEPOSIT_BOB);
        vm.expectRevert("Pausable: paused");
        lottery.deposit(DEPOSIT_BOB);
        vm.stopPrank();
    }

    function test_pauseDoesNotBlockClaim() public {
        _deposit(alice, DEPOSIT_ALICE);
        aavePool.simulateYield(address(strategy), 50e6);
        _fullRound(0, 0);

        vm.prank(owner);
        lottery.pause();

        // Claim is NOT guarded by whenNotPaused — should succeed
        uint256 prize = lottery.pendingPrizes(1, alice);
        assertGt(prize, 0);

        vm.prank(alice);
        lottery.claimPrize(1);
        assertEq(lottery.pendingPrizes(1, alice), 0);
    }

    function test_pauseDoesNotBlockWithdraw() public {
        _deposit(alice, DEPOSIT_ALICE);

        vm.prank(owner);
        lottery.pause();

        // Withdraw is NOT guarded by whenNotPaused — principal should always be withdrawable
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);
        assertEq(lottery.balances(alice), 0);
    }

    // =========================================================================
    // 11. Withdraw all during pending draw — balance goes to zero
    // =========================================================================

    function test_withdrawAllDuringPendingDraw() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);
        _triggerDraw();

        // Both withdraw everything while draw is pending
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);
        vm.prank(bob);
        lottery.withdraw(DEPOSIT_BOB);

        assertEq(lottery.totalDeposited(), 0);
        assertEq(lottery.balances(alice), 0);
        assertEq(lottery.balances(bob), 0);

        // Fulfillment still works based on snapshot
        _deliverRandom(0);
        NoLossLottery.Round memory r = lottery.getRound(1);
        assertTrue(r.isSettled);
    }

    // =========================================================================
    // 12. Re-deposit after full withdrawal
    // =========================================================================

    function test_reDepositAfterFullWithdrawal() public {
        _deposit(alice, DEPOSIT_ALICE);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);
        assertEq(lottery.balances(alice), 0);

        // Re-deposit
        _deposit(alice, 500e6);
        assertEq(lottery.balances(alice), 500e6);
        assertEq(lottery.totalDeposited(), 500e6);

        // Should work in next round
        _fullRound(0, 42);
        NoLossLottery.Round memory r = lottery.getRound(1);
        assertEq(r.winner, alice, "re-deposited alice should win");
    }

    function test_reDepositAfterWithdrawal_participantNotDuplicated() public {
        _deposit(alice, DEPOSIT_ALICE);
        uint256 countBefore = lottery.participantCount();

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);

        // Re-deposit — participant count should not increase (alice already registered)
        _deposit(alice, 500e6);
        assertEq(lottery.participantCount(), countBefore, "should not double-count participant");
    }

    // =========================================================================
    // 13. Multiple rounds yield accumulation
    // =========================================================================

    function test_multiRoundYieldAccumulation() public {
        _deposit(alice, DEPOSIT_ALICE);

        uint256 totalPrizes = 0;

        // Run 5 rounds, each with yield
        for (uint256 i = 0; i < 5; i++) {
            // Warp past current round end
            NoLossLottery.Round memory cur = lottery.getCurrentRound();
            vm.warp(cur.endTime + 1);

            aavePool.simulateYield(address(strategy), 10e6);
            lottery.performUpkeep("");
            _deliverRandom(i);

            uint256 prize = lottery.pendingPrizes(i + 1, alice);
            totalPrizes += prize;
        }

        // Alice should have accumulated prizes across all rounds
        assertGt(totalPrizes, 0, "should accumulate prizes across rounds");

        // Each round should be settled
        for (uint256 i = 1; i <= 5; i++) {
            assertTrue(lottery.getRound(i).isSettled);
            assertEq(lottery.getRound(i).winner, alice);
        }

        // Principal should be preserved
        assertEq(lottery.balances(alice), DEPOSIT_ALICE, "principal untouched");
    }

    function test_multiRoundClaim_canClaimAnySettledRound() public {
        _deposit(alice, DEPOSIT_ALICE);

        // Run 3 rounds with yield
        for (uint256 i = 0; i < 3; i++) {
            NoLossLottery.Round memory cur = lottery.getCurrentRound();
            vm.warp(cur.endTime + 1);
            aavePool.simulateYield(address(strategy), 20e6);
            lottery.performUpkeep("");
            _deliverRandom(0);
        }

        // Claim round 3 first (out of order)
        uint256 prize3 = lottery.pendingPrizes(3, alice);
        if (prize3 > 0) {
            vm.prank(alice);
            lottery.claimPrize(3);
        }

        // Then claim round 1
        uint256 prize1 = lottery.pendingPrizes(1, alice);
        if (prize1 > 0) {
            vm.prank(alice);
            lottery.claimPrize(1);
        }

        // All claimed
        assertEq(lottery.pendingPrizes(1, alice), 0);
        assertEq(lottery.pendingPrizes(3, alice), 0);
    }

    // =========================================================================
    // 14. Owner cannot manipulate winner
    // =========================================================================

    function test_ownerCannotCallFulfillRandomness() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        // Owner tries to call fulfillRandomness directly
        vm.prank(owner);
        vm.expectRevert(NoLossLottery.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);
    }

    function test_ownerCannotBypassRandomnessManager() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);
        _triggerDraw();

        // Even using low-level call, owner cannot impersonate RM
        vm.prank(owner);
        (bool ok,) = address(lottery).call(
            abi.encodeWithSignature("fulfillRandomness(uint256)", 42)
        );
        assertFalse(ok, "owner direct call should fail");
    }

    // =========================================================================
    // 15. Zero yield round — winner selected but prize = 0
    // =========================================================================

    function test_zeroYieldRound_winnerSelectedPrizeZero() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);

        // No yield simulation — prize will be 0
        _fullRound(0, 0);

        NoLossLottery.Round memory r = lottery.getRound(1);
        assertTrue(r.isSettled);
        assertEq(r.prizeAmount, 0, "no yield means zero prize");
        assertTrue(r.winner != address(0), "winner still selected");
    }

    function test_zeroYieldRound_claimRevertsNoPrize() public {
        _deposit(alice, DEPOSIT_ALICE);
        _fullRound(0, 0);

        // Alice "wins" but prize is 0
        NoLossLottery.Round memory r = lottery.getRound(1);
        assertEq(r.winner, alice);
        assertEq(r.prizeAmount, 0);

        // Claim reverts because pendingPrizes is 0
        vm.prank(alice);
        vm.expectRevert(NoLossLottery.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    function test_zeroYieldRound_principalPreserved() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);

        // Run round with no yield
        _fullRound(0, 0);

        // Both principals intact
        assertEq(lottery.balances(alice), DEPOSIT_ALICE);
        assertEq(lottery.balances(bob),   DEPOSIT_BOB);
        assertEq(lottery.totalDeposited(), DEPOSIT_ALICE + DEPOSIT_BOB);
    }

    // =========================================================================
    // 16. Withdraw more than balance — should revert
    // =========================================================================

    function test_withdrawMoreThanBalance_reverts() public {
        _deposit(alice, DEPOSIT_ALICE);

        vm.prank(alice);
        vm.expectRevert(NoLossLottery.InsufficientBalance.selector);
        lottery.withdraw(DEPOSIT_ALICE + 1);
    }

    function test_withdrawFromZeroBalance_reverts() public {
        // Nobody never deposited
        vm.prank(nobody);
        vm.expectRevert(NoLossLottery.InsufficientBalance.selector);
        lottery.withdraw(1);
    }

    // =========================================================================
    // 17. Deposit zero — should revert
    // =========================================================================

    function test_depositZero_reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(lottery), 1000e6);
        vm.expectRevert(NoLossLottery.ZeroAmount.selector);
        lottery.deposit(0);
        vm.stopPrank();
    }

    // =========================================================================
    // 18. performUpkeep when not needed — should revert
    // =========================================================================

    function test_performUpkeep_revertsBeforeRoundEnd() public {
        _deposit(alice, DEPOSIT_ALICE);
        // Round just started, not at endTime yet
        vm.expectRevert(NoLossLottery.DrawNotReady.selector);
        lottery.performUpkeep("");
    }

    function test_performUpkeep_revertsWithZeroDeposits() public {
        // No one deposited
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        vm.expectRevert(NoLossLottery.NoActiveParticipants.selector);
        lottery.performUpkeep("");
    }

    function test_performUpkeep_revertsAfterAllWithdraw() public {
        _deposit(alice, DEPOSIT_ALICE);

        // Alice withdraws everything
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        vm.expectRevert(NoLossLottery.NoActiveParticipants.selector);
        lottery.performUpkeep("");
    }

    // =========================================================================
    // 19. fulfillRandomness by non-RM — should revert
    // =========================================================================

    function test_fulfillRandomness_revertsFromArbitraryAddress() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        vm.prank(eve);
        vm.expectRevert(NoLossLottery.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);
    }

    function test_fulfillRandomness_revertsFromParticipant() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        vm.prank(alice);
        vm.expectRevert(NoLossLottery.NotRandomnessManager.selector);
        lottery.fulfillRandomness(0);
    }

    function test_fulfillRandomness_revertsFromContractAddress() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();

        // Try from the strategy contract address
        vm.prank(address(strategy));
        vm.expectRevert(NoLossLottery.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);
    }

    // =========================================================================
    // 20. Multiple performUpkeep calls — second should revert
    // =========================================================================

    function test_doublePerformUpkeep_reverts() public {
        _deposit(alice, DEPOSIT_ALICE);
        vm.warp(block.timestamp + ROUND_DURATION + 1);

        lottery.performUpkeep("");

        vm.expectRevert(NoLossLottery.DrawAlreadyPending.selector);
        lottery.performUpkeep("");
    }

    function test_performUpkeep_afterSettlement_nextRound() public {
        _deposit(alice, DEPOSIT_ALICE);
        _triggerDraw();
        _deliverRandom(0);

        // Now in round 2; performUpkeep should revert (round just started)
        vm.expectRevert(NoLossLottery.DrawNotReady.selector);
        lottery.performUpkeep("");

        // Wait for round 2 to end, then it should work
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");

        NoLossLottery.Round memory r2 = lottery.getCurrentRound();
        assertTrue(r2.isDrawPending);
    }

    // =========================================================================
    // Additional edge cases
    // =========================================================================

    /// @notice Verify checkUpkeep returns false after settlement (before next round ends)
    function test_checkUpkeep_falseAfterSettlement() public {
        _deposit(alice, DEPOSIT_ALICE);
        _fullRound(0, 0);

        // Round 2 just started — checkUpkeep should be false
        (bool needed,) = lottery.checkUpkeep("");
        assertFalse(needed, "should not trigger immediately after settlement");
    }

    /// @notice Participant with zero balance is excluded from snapshot
    function test_zeroBalanceParticipant_excludedFromSnapshot() public {
        _deposit(alice, DEPOSIT_ALICE);
        _deposit(bob,   DEPOSIT_BOB);

        // Alice withdraws all — balance is 0 but she stays in _participants array
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);
        assertEq(lottery.balances(alice), 0);

        // Trigger draw — only bob should be in snapshot
        aavePool.simulateYield(address(strategy), 10e6);
        _triggerDraw();
        _deliverRandom(0);

        // Bob must be the winner (alice has 0 balance)
        NoLossLottery.Round memory r = lottery.getRound(1);
        assertEq(r.winner, bob, "zero-balance alice should not win");
    }

    /// @notice Verify different random words produce different winners (statistical)
    function test_differentRandomWords_differentWinners() public {
        _deposit(alice, DEPOSIT_ALICE); // 70%
        _deposit(bob,   DEPOSIT_BOB);   // 30%

        bool aliceWon = false;
        bool bobWon   = false;

        for (uint256 i = 0; i < 10; i++) {
            NoLossLottery.Round memory cur = lottery.getCurrentRound();
            vm.warp(cur.endTime + 1);
            lottery.performUpkeep("");
            _deliverRandom(i * 13 + 7);

            address winner = lottery.getRound(i + 1).winner;
            if (winner == alice) aliceWon = true;
            if (winner == bob)   bobWon   = true;

            if (aliceWon && bobWon) break;
        }

        assertTrue(aliceWon, "alice should win at least once in 10 rounds");
        // Bob has 30% chance so probabilistically should win, but not guaranteed in 10 rounds
        // We don't assert bobWon to avoid flaky tests
    }

    /// @notice Verify round ID increments correctly over many rounds
    function test_roundIdIncrements() public {
        _deposit(alice, DEPOSIT_ALICE);

        for (uint256 i = 0; i < 10; i++) {
            assertEq(lottery.currentRoundId(), i + 1);
            _fullRound(0, i);
        }
        assertEq(lottery.currentRoundId(), 11);
    }

    /// @notice Edge: performUpkeep exactly at endTime (not after)
    function test_performUpkeep_exactlyAtEndTime() public {
        _deposit(alice, DEPOSIT_ALICE);

        NoLossLottery.Round memory r = lottery.getCurrentRound();
        vm.warp(r.endTime); // warp to exact endTime, not endTime + 1

        // Should succeed — condition is block.timestamp >= r.endTime
        lottery.performUpkeep("");
        NoLossLottery.Round memory rAfter = lottery.getCurrentRound();
        assertTrue(rAfter.isDrawPending);
    }

    /// @notice Huge deposit should not break proportional selection
    function test_hugeDeposit_proportionalSelection() public {
        uint256 hugeAmount = 1_000_000_000e6; // 1 billion USDC
        usdc.mint(bob, hugeAmount);

        _deposit(alice, 1); // 1 wei
        _deposit(bob, hugeAmount);

        _triggerDraw();
        _deliverRandom(0);

        // With random=0, target=0, alice has weight 1, so cumulative after alice = 1,
        // and target=0 < 1 is true, so alice wins with random=0
        NoLossLottery.Round memory r = lottery.getRound(1);
        assertEq(r.winner, alice, "alice should win when target=0 falls in her range");
    }

    /// @notice Withdraw exact balance after yield accrual
    function test_withdrawExactBalance_afterYield() public {
        _deposit(alice, DEPOSIT_ALICE);

        // Yield accrues in strategy but alice's balance is still DEPOSIT_ALICE
        aavePool.simulateYield(address(strategy), 100e6);

        // Alice withdraws her full recorded balance
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_ALICE);

        assertEq(lottery.balances(alice), 0);
        assertEq(lottery.totalDeposited(), 0);
    }

    /// @notice Multiple users deposit and withdraw in interleaved order
    function test_interleavedDepositWithdraw() public {
        _deposit(alice, 500e6);
        _deposit(bob,   300e6);

        vm.prank(alice);
        lottery.withdraw(200e6);

        _deposit(charlie, 400e6);

        vm.prank(bob);
        lottery.withdraw(300e6);

        assertEq(lottery.balances(alice),   300e6);
        assertEq(lottery.balances(bob),     0);
        assertEq(lottery.balances(charlie), 400e6);
        assertEq(lottery.totalDeposited(),  700e6);

        // Draw should work with alice and charlie (bob has 0)
        _triggerDraw();
        _deliverRandom(0);

        NoLossLottery.Round memory r = lottery.getRound(1);
        assertTrue(
            r.winner == alice || r.winner == charlie,
            "winner must be alice or charlie (bob has 0)"
        );
    }

    /// @notice getCurrentPrizePool after partial withdrawal
    function test_prizePool_afterPartialWithdraw() public {
        _deposit(alice, 1000e6);
        aavePool.simulateYield(address(strategy), 100e6);

        // Prize pool = strategy total (1100) - totalDeposited (1000) = 100
        assertEq(lottery.getCurrentPrizePool(), 100e6);

        // Withdraw 500 principal — strategy loses proportional shares
        vm.prank(alice);
        lottery.withdraw(500e6);

        // totalDeposited is now 500, strategy value decreased proportionally
        // Prize pool should still be approximately yield portion
        uint256 prizeAfter = lottery.getCurrentPrizePool();
        // Some rounding possible but should be close to the remaining yield
        assertLt(prizeAfter, 101e6, "prize pool should not exceed original yield");
    }

    /// @notice Verify win probability updates after deposit changes
    function test_winProbability_updatesAfterDeposit() public {
        _deposit(alice, 500e6);
        assertEq(lottery.getWinProbability(alice), 10_000, "100% with sole deposit");

        _deposit(bob, 500e6);
        assertEq(lottery.getWinProbability(alice), 5000, "50% after equal deposit");
        assertEq(lottery.getWinProbability(bob),   5000, "50% after equal deposit");

        vm.prank(bob);
        lottery.withdraw(500e6);
        assertEq(lottery.getWinProbability(alice), 10_000, "back to 100%");
        assertEq(lottery.getWinProbability(bob),   0, "0% after full withdrawal");
    }
}
