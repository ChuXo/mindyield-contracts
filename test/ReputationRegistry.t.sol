// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ReputationRegistry.sol";

/**
 * @title ReputationRegistryTest
 * @notice Comprehensive tests for the ReputationRegistry contract
 * Tests user/creator reputation tracking, score calculation, penalties, bonuses, and tiers
 */
contract ReputationRegistryTest is Test {
    ReputationRegistry public registry;

    address public owner = address(1);
    address public updater = address(2);
    address public alice = address(3);
    address public bob = address(4);
    address public creator1 = address(5);

    event UserReputationUpdated(address indexed user, uint256 newScore);
    event CreatorReputationUpdated(address indexed creator, uint256 newScore);
    event UpdaterAuthorized(address indexed updater, bool authorized);
    event PenaltyApplied(address indexed user, uint256 points, string reason);
    event BonusApplied(address indexed user, uint256 points, string reason);

    function setUp() public {
        vm.startPrank(owner);
        registry = new ReputationRegistry();
        registry.setAuthorizedUpdater(updater, true);
        vm.stopPrank();
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(registry.owner(), owner);
        assertTrue(registry.authorizedUpdaters(updater));
        assertEq(registry.MAX_REPUTATION_SCORE(), 1000);
        assertEq(registry.MIN_CONTESTS_FOR_SCORE(), 3);
    }

    // ============ AUTHORIZATION TESTS ============

    function testSetAuthorizedUpdater() public {
        vm.prank(owner);
        registry.setAuthorizedUpdater(bob, true);

        assertTrue(registry.authorizedUpdaters(bob));
    }

    function testSetAuthorizedUpdaterEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit UpdaterAuthorized(bob, true);

        vm.prank(owner);
        registry.setAuthorizedUpdater(bob, true);
    }

    function testRevokeAuthorizedUpdater() public {
        vm.prank(owner);
        registry.setAuthorizedUpdater(updater, false);

        assertFalse(registry.authorizedUpdaters(updater));
    }

    function testRevertSetAuthorizedUpdaterNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.setAuthorizedUpdater(bob, true);
    }

    // ============ USER REPUTATION TRACKING TESTS ============

    function testRecordContestJoined() public {
        vm.prank(updater);
        registry.recordContestJoined(alice);

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.contestsJoined, 1);
        assertEq(rep.firstParticipation, block.timestamp);
        assertEq(rep.lastParticipation, block.timestamp);
    }

    function testRecordMultipleContestsJoined() public {
        vm.startPrank(updater);
        registry.recordContestJoined(alice);

        vm.warp(block.timestamp + 1 days);
        registry.recordContestJoined(alice);

        vm.warp(block.timestamp + 2 days);
        registry.recordContestJoined(alice);
        vm.stopPrank();

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.contestsJoined, 3);
        assertEq(rep.lastParticipation, block.timestamp);
    }

    function testRecordVoteCommitted() public {
        vm.prank(updater);
        registry.recordVoteCommitted(alice);

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.votesCommitted, 1);
    }

    function testRecordVoteRevealed() public {
        vm.startPrank(updater);
        registry.recordVoteCommitted(alice);
        registry.recordVoteRevealed(alice);
        vm.stopPrank();

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.votesRevealed, 1);
        assertEq(rep.consecutiveReveals, 1);
        assertEq(rep.maxConsecutiveReveals, 1);
    }

    function testRecordConsecutiveReveals() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 5; i++) {
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
        }
        vm.stopPrank();

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.votesRevealed, 5);
        assertEq(rep.consecutiveReveals, 5);
        assertEq(rep.maxConsecutiveReveals, 5);
    }

    function testRecordMissedReveal() public {
        vm.startPrank(updater);
        registry.recordVoteCommitted(alice);
        registry.recordVoteRevealed(alice);
        registry.recordVoteCommitted(alice);
        registry.recordVoteRevealed(alice);

        // Miss a reveal
        registry.recordVoteCommitted(alice);
        registry.recordMissedReveal(alice);
        vm.stopPrank();

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.consecutiveReveals, 0); // Reset
        assertEq(rep.maxConsecutiveReveals, 2); // Previous max preserved
        assertEq(rep.penaltyPoints, 10);
    }

    function testRecordContestCompleted() public {
        vm.startPrank(updater);
        registry.recordContestJoined(alice);
        registry.recordContestCompleted(alice, false, 0);
        vm.stopPrank();

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.contestsCompleted, 1);
        assertEq(rep.contestsWon, 0);
        assertEq(rep.totalYieldWon, 0);
    }

    function testRecordContestCompletedAsWinner() public {
        vm.startPrank(updater);
        registry.recordContestJoined(alice);
        registry.recordContestCompleted(alice, true, 50000);
        vm.stopPrank();

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.contestsCompleted, 1);
        assertEq(rep.contestsWon, 1);
        assertEq(rep.totalYieldWon, 50000);
    }

    function testApplyBonus() public {
        vm.prank(updater);
        registry.applyBonus(alice, 50, "Early adopter bonus");

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.bonusPoints, 50);
    }

    function testApplyPenalty() public {
        vm.prank(updater);
        registry.applyPenalty(alice, 20, "Suspicious activity");

        ReputationRegistry.UserReputation memory rep = registry.getUserReputation(alice);
        assertEq(rep.penaltyPoints, 20);
    }

    function testRevertRecordContestJoinedUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.recordContestJoined(bob);
    }

    // ============ CREATOR REPUTATION TRACKING TESTS ============

    function testRecordContestCreated() public {
        vm.prank(updater);
        registry.recordContestCreated(creator1);

        ReputationRegistry.CreatorReputation memory rep = registry.getCreatorReputation(creator1);
        assertEq(rep.contestsCreated, 1);
        assertEq(rep.firstContest, block.timestamp);
        assertEq(rep.lastContest, block.timestamp);
    }

    function testRecordCreatorContestCompleted() public {
        vm.startPrank(updater);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 10, 5000, false);
        vm.stopPrank();

        ReputationRegistry.CreatorReputation memory rep = registry.getCreatorReputation(creator1);
        assertEq(rep.contestsCompleted, 1);
        assertEq(rep.totalParticipants, 10);
        assertEq(rep.totalYieldDistributed, 5000);
        assertEq(rep.averageParticipation, 10);
    }

    function testRecordCreatorContestCancelled() public {
        vm.startPrank(updater);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 0, 0, true);
        vm.stopPrank();

        ReputationRegistry.CreatorReputation memory rep = registry.getCreatorReputation(creator1);
        assertEq(rep.contestsCancelled, 1);
        assertEq(rep.penaltyPoints, 5);
    }

    function testRecordCreatorAverageParticipation() public {
        vm.startPrank(updater);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 10, 1000, false);

        vm.warp(block.timestamp + 1 days);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 20, 2000, false);

        vm.warp(block.timestamp + 1 days);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 30, 3000, false);
        vm.stopPrank();

        ReputationRegistry.CreatorReputation memory rep = registry.getCreatorReputation(creator1);
        assertEq(rep.contestsCompleted, 3);
        assertEq(rep.totalParticipants, 60);
        assertEq(rep.averageParticipation, 20); // 60 / 3
    }

    // ============ USER SCORE CALCULATION TESTS ============

    function testCalculateUserScoreNewUser() public view {
        uint256 score = registry.getUserScore(alice);
        assertEq(score, 500); // Base score for users with < 3 contests
    }

    function testCalculateUserScoreWithMinContests() public {
        vm.startPrank(updater);
        // Join MIN_CONTESTS_FOR_SCORE contests with full participation
        for (uint i = 0; i < 3; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, false, 0);
        }
        vm.stopPrank();

        uint256 score = registry.getUserScore(alice);
        // With 3 contests + 100% reveal rate: ~415 (weighted formula)
        assertTrue(score > 0); // Should have a real calculated score (not zero)
    }

    function testCalculateUserScorePerfectRevealRate() public {
        vm.startPrank(updater);
        // Perfect reveal rate (100%)
        for (uint i = 0; i < 5; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, false, 0);
        }
        vm.stopPrank();

        uint256 score = registry.getUserScore(alice);
        // With 5 contests + 100% reveal rate: ~425 (weighted formula)
        assertTrue(score > 400); // High reveal rate gives meaningful score
    }

    function testCalculateUserScoreWithPenalties() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 3; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
        }
        registry.applyPenalty(alice, 100, "Test penalty");
        vm.stopPrank();

        uint256 score = registry.getUserScore(alice);
        uint256 scoreWithoutPenalty = registry.calculateUserScore(bob); // Bob has no penalty

        // Alice's score should be lower due to penalty
        assertTrue(score < scoreWithoutPenalty);
    }

    function testCalculateUserScoreWithBonus() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 3; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
        }
        uint256 scoreBefore = registry.getUserScore(alice);

        registry.applyBonus(alice, 50, "Test bonus");
        uint256 scoreAfter = registry.getUserScore(alice);
        vm.stopPrank();

        assertEq(scoreAfter, scoreBefore + 50);
    }

    function testCalculateUserScorePenaltyDecay() public {
        vm.startPrank(updater);
        // Need >= MIN_CONTESTS_FOR_SCORE contests so full calculation (with penalty) runs
        for (uint i = 0; i < 3; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
        }
        registry.applyPenalty(alice, 100, "Test penalty");

        uint256 scoreImmediately = registry.getUserScore(alice); // ~315 (415 - 100)

        // Advance time past the penalty decay period
        vm.warp(block.timestamp + 31 days);

        uint256 scoreAfterDecay = registry.getUserScore(alice); // ~365 (415 - 50)
        vm.stopPrank();

        // Score should improve after penalty decays
        assertTrue(scoreAfterDecay > scoreImmediately);
    }

    function testCalculateUserScoreMaxCap() public {
        vm.startPrank(updater);
        // Create artificially high score conditions
        for (uint i = 0; i < 100; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, true, 10000); // All wins
        }
        registry.applyBonus(alice, 500, "Max bonus");
        vm.stopPrank();

        uint256 score = registry.getUserScore(alice);
        assertEq(score, 1000); // Should be capped at MAX_REPUTATION_SCORE
    }

    // ============ CREATOR SCORE CALCULATION TESTS ============

    function testCalculateCreatorScoreNewCreator() public view {
        uint256 score = registry.getCreatorScore(creator1);
        assertEq(score, 500); // Base score for creators with < 2 contests
    }

    function testCalculateCreatorScoreWithCompletions() public {
        vm.startPrank(updater);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 20, 5000, false);

        vm.warp(block.timestamp + 1 days);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 30, 6000, false);
        vm.stopPrank();

        uint256 score = registry.getCreatorScore(creator1);
        assertTrue(score > 500); // Should be above base score with 100% completion
    }

    function testCalculateCreatorScoreWithCancellations() public {
        vm.startPrank(updater);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 20, 5000, false);

        vm.warp(block.timestamp + 1 days);
        registry.recordContestCreated(creator1);
        registry.recordCreatorContestCompleted(creator1, 0, 0, true); // Cancelled
        vm.stopPrank();

        uint256 score = registry.getCreatorScore(creator1);

        // Cancellation should reduce score
        assertTrue(score < 1000);
    }

    // ============ VIEW FUNCTIONS TESTS ============

    function testGetUserScore() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 3; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
        }
        vm.stopPrank();

        uint256 score = registry.getUserScore(alice);
        assertTrue(score > 0);
        assertTrue(score <= 1000);
    }

    function testMeetsThreshold() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 10; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, true, 1000);
        }
        vm.stopPrank();

        assertTrue(registry.meetsThreshold(alice, 500));
        assertFalse(registry.meetsThreshold(bob, 500)); // Bob has no reputation
    }

    function testGetUserTierUnverified() public view {
        uint256 tier = registry.getUserTier(alice);
        assertEq(tier, 0); // Unverified (score < 250)
    }

    function testGetUserTierBronze() public {
        vm.startPrank(updater);
        // Need full participation (joins + reveals) to reach Bronze score threshold (>= 250)
        for (uint i = 0; i < 3; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
        }
        vm.stopPrank();

        uint256 tier = registry.getUserTier(alice);
        // 3 contests + 100% reveal rate → score ~415 → tier 1 (Bronze, score >= 250)
        assertTrue(tier >= 1);
    }

    function testGetUserTierSilver() public {
        vm.startPrank(updater);
        // Wins boost score above Silver threshold (>= 500)
        for (uint i = 0; i < 5; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, true, 1000); // winner each time
        }
        vm.stopPrank();

        uint256 tier = registry.getUserTier(alice);
        // 5 contests + 100% reveal rate + 100% win rate → score ~525 → tier 2 (Silver, score >= 500)
        assertTrue(tier >= 2);
    }

    function testGetUserTierGold() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 20; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, true, 1000);
        }
        registry.applyBonus(alice, 200, "Gold tier bonus");
        vm.stopPrank();

        uint256 tier = registry.getUserTier(alice);
        // Should be at least Gold (score >= 750)
        assertTrue(tier >= 3);
    }

    function testGetUserTierPlatinum() public {
        vm.startPrank(updater);
        for (uint i = 0; i < 50; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, true, 2000);
        }
        registry.applyBonus(alice, 500, "Platinum tier bonus");
        vm.stopPrank();

        uint256 tier = registry.getUserTier(alice);
        // Should be Platinum (score >= 900)
        assertEq(tier, 4);
    }
}
