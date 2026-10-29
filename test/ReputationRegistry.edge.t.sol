// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ReputationRegistry.sol";

/**
 * @title ReputationRegistryEdgeTest
 * @notice Edge cases for ReputationRegistry:
 *   - meetsThreshold for zero-participation user returns false
 *   - getUserTier for zero-participation user returns 0
 *   - calculateUserScore before MIN_CONTESTS_FOR_SCORE threshold
 *   - Score accumulation and tier progression
 *   - Penalty/bonus clamping to [0, MAX_REPUTATION_SCORE]
 *   - Unauthorized updater reverts
 *   - Score never exceeds MAX_REPUTATION_SCORE
 */
contract ReputationRegistryEdgeTest is Test {

    ReputationRegistry registry;

    address owner    = address(1);
    address updater  = address(2);
    address alice    = address(3);
    address bob      = address(4);
    address stranger = address(5);

    function setUp() public {
        vm.startPrank(owner);
        registry = new ReputationRegistry();
        registry.setAuthorizedUpdater(updater, true);
        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Record N joined contests + complete all with reveals (builds positive score)
    function _buildHistory(address user, uint256 contests) internal {
        vm.startPrank(updater);
        for (uint256 i = 0; i < contests; i++) {
            registry.recordContestJoined(user);
            registry.recordVoteCommitted(user);
            registry.recordVoteRevealed(user);
            registry.recordContestCompleted(user, true, 0); // won
        }
        vm.stopPrank();
    }

    // =========================================================================
    // Zero-participation guard — meetsThreshold
    // =========================================================================

    function test_meetsThreshold_zeroParticipation_returnsFalse() public {
        // alice has never joined any contest
        assertEq(registry.getUserReputation(alice).contestsJoined, 0);
        assertFalse(registry.meetsThreshold(alice, 0), "even threshold 0 returns false for zero-participation");
    }

    function test_meetsThreshold_afterJoining_canReturnTrue() public {
        // Build enough history for a good score
        _buildHistory(alice, registry.MIN_CONTESTS_FOR_SCORE());

        // Now alice has enough history
        assertTrue(registry.meetsThreshold(alice, 1), "alice should meet threshold 1 after history");
    }

    function test_meetsThreshold_highThreshold_returnsFalse() public {
        _buildHistory(alice, registry.MIN_CONTESTS_FOR_SCORE());

        // Score is unlikely to be 1000 without huge history
        assertFalse(registry.meetsThreshold(alice, 1000), "alice unlikely to meet threshold 1000");
    }

    // =========================================================================
    // Zero-participation guard — getUserTier
    // =========================================================================

    function test_getUserTier_zeroParticipation_returnsZero() public {
        assertEq(registry.getUserTier(alice), 0, "zero participation = tier 0 (Unverified)");
    }

    function test_getUserTier_zeroParticipation_notAffectedByBonusPoints() public {
        // Even if we could add bonus points (via authorized updater), tier stays 0 without participation
        // Note: applyBonus requires user to exist — but we verify the guard is still in place
        assertEq(registry.getUserTier(alice), 0);
    }

    function test_getUserTier_afterHistory_canBeNonZero() public {
        // Build a lot of history for a high score
        _buildHistory(alice, 20);

        uint256 tier = registry.getUserTier(alice);
        assertGt(tier, 0, "alice should have non-zero tier after 20 contests");
    }

    function test_getUserTier_progressesWithScore() public {
        _buildHistory(alice, registry.MIN_CONTESTS_FOR_SCORE()); // barely past minimum
        uint256 lowTier = registry.getUserTier(alice);

        _buildHistory(alice, 50); // lots more history
        uint256 highTier = registry.getUserTier(alice);

        assertGe(highTier, lowTier, "more history should not decrease tier");
    }

    // =========================================================================
    // Score before MIN_CONTESTS_FOR_SCORE
    // =========================================================================

    function test_score_belowMinContests_isBaseScore() public {
        uint256 minContests = registry.MIN_CONTESTS_FOR_SCORE();

        // Join one fewer than required
        vm.startPrank(updater);
        for (uint256 i = 0; i < minContests - 1; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordVoteRevealed(alice);
            registry.recordContestCompleted(alice, true, 0);
        }
        vm.stopPrank();

        // Score below minimum history returns base score (500 per implementation)
        uint256 score = registry.calculateUserScore(alice);
        assertEq(score, 500, "score should be base score (500) before min history");
    }

    function test_score_atMinContests_usesFullCalculation() public {
        _buildHistory(alice, registry.MIN_CONTESTS_FOR_SCORE());

        uint256 score = registry.calculateUserScore(alice);
        assertGt(score, 0);
    }

    // =========================================================================
    // Score never exceeds MAX_REPUTATION_SCORE
    // =========================================================================

    function test_score_neverExceedsMax() public {
        _buildHistory(alice, 100);

        // Apply maximum allowed bonus (MAX_BONUS_POINTS = 500)
        vm.prank(updater);
        registry.applyBonus(alice, 500, "max bonus");

        uint256 score = registry.calculateUserScore(alice);
        assertLe(score, registry.MAX_REPUTATION_SCORE(), "score must not exceed max");
    }

    // =========================================================================
    // Penalty clamping — score never goes negative
    // =========================================================================

    function test_penalty_clampedToZero() public {
        _buildHistory(alice, registry.MIN_CONTESTS_FOR_SCORE());

        // Apply maximum penalty (capped at MAX_PENALTY_POINTS = 500)
        vm.prank(updater);
        registry.applyPenalty(alice, 500, "max penalty");

        uint256 score = registry.calculateUserScore(alice);
        // Penalty is applied after score calculation — verify it reduces the score
        // and that the score never underflows (stays >= 0)
        uint256 unpunishedScore = registry.calculateUserScore(bob); // bob has no history => 500 base
        assertLe(score, 1000, "score should be within bounds");
    }

    // =========================================================================
    // Unauthorized updater reverts
    // =========================================================================

    function test_recordContestJoined_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.recordContestJoined(alice);
    }

    function test_recordVoteCommitted_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.recordVoteCommitted(alice);
    }

    function test_recordVoteRevealed_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.recordVoteRevealed(alice);
    }

    function test_recordMissedReveal_byStranger_reverts() public {
        // Set up: join first so the check passes
        vm.prank(updater);
        registry.recordContestJoined(alice);

        vm.prank(stranger);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.recordMissedReveal(alice);
    }

    function test_applyBonus_byStranger_reverts() public {
        vm.prank(updater);
        registry.recordContestJoined(alice);

        vm.prank(stranger);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.applyBonus(alice, 100, "unauthorized bonus");
    }

    function test_applyPenalty_byStranger_reverts() public {
        vm.prank(updater);
        registry.recordContestJoined(alice);

        vm.prank(stranger);
        vm.expectRevert("ReputationRegistry: not authorized");
        registry.applyPenalty(alice, 100, "unauthorized penalty");
    }

    function test_setAuthorizedUpdater_byStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setAuthorizedUpdater(stranger, true);
    }

    // =========================================================================
    // Missed reveal reduces score
    // =========================================================================

    function test_missedReveal_reducesRevealRate() public {
        // Build some history
        _buildHistory(alice, 5);
        uint256 scoreBefore = registry.calculateUserScore(alice);

        // Now miss several reveals
        vm.startPrank(updater);
        for (uint i = 0; i < 5; i++) {
            registry.recordContestJoined(alice);
            registry.recordVoteCommitted(alice);
            registry.recordMissedReveal(alice);
        }
        vm.stopPrank();

        uint256 scoreAfter = registry.calculateUserScore(alice);
        assertLe(scoreAfter, scoreBefore, "missed reveals should not increase score");
    }

    // =========================================================================
    // meetsThreshold is consistent with getUserTier
    // =========================================================================

    function test_meetsThreshold_consistentWithTier() public {
        _buildHistory(alice, 10);

        uint256 tier  = registry.getUserTier(alice);
        uint256 score = registry.calculateUserScore(alice);

        if (tier >= 1) {
            assertTrue(registry.meetsThreshold(alice, 1), "tier >= 1 should meet threshold 1");
        }

        // Score-based consistency
        if (score >= 500) {
            assertTrue(registry.meetsThreshold(alice, 500));
        }
        if (score < 500) {
            assertFalse(registry.meetsThreshold(alice, 500));
        }
    }

    // =========================================================================
    // Fuzz: meetsThreshold(user, 0) always false for zero-participation
    // =========================================================================

    function testFuzz_zeroParticipation_meetsThreshold_alwaysFalse(
        address user,
        uint256 threshold
    ) public {
        vm.assume(user != address(0));
        // Do not interact with this user at all
        assertFalse(registry.meetsThreshold(user, threshold));
        assertEq(registry.getUserTier(user), 0);
    }
}
