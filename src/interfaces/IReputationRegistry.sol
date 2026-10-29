// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReputationRegistry
 * @notice Interface for the MindYield Reputation Registry
 */
interface IReputationRegistry {
    // ============ User Reputation ============

    function recordContestJoined(address user) external;
    function recordVoteCommitted(address user) external;
    function recordVoteRevealed(address user) external;
    function recordMissedReveal(address user) external;
    function recordContestCompleted(address user, bool isWinner, uint256 yieldWon) external;

    function applyBonus(address user, uint256 points, string calldata reason) external;
    function applyPenalty(address user, uint256 points, string calldata reason) external;

    // ============ Creator Reputation ============

    function recordContestCreated(address creator) external;
    function recordCreatorContestCompleted(
        address creator,
        uint256 participantCount,
        uint256 yieldDistributed,
        bool wasCancelled
    ) external;

    // ============ Score Queries ============

    function getUserScore(address user) external view returns (uint256);
    function getCreatorScore(address creator) external view returns (uint256);
    function calculateUserScore(address user) external view returns (uint256);
    function calculateCreatorScore(address creator) external view returns (uint256);

    // ============ Utility ============

    function meetsThreshold(address user, uint256 minScore) external view returns (bool);
    function getUserTier(address user) external view returns (uint256 tier);

    // ============ Admin ============

    function setAuthorizedUpdater(address updater, bool authorized) external;
}
