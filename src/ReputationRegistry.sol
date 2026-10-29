// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IReputationRegistry.sol";

/**
 * @title ReputationRegistry
 * @notice On-chain reputation tracking for MindYield participants
 * @dev Tracks participation history, reveal rates, and calculates reputation scores
 */
contract ReputationRegistry is IReputationRegistry, Ownable2Step {
    using Math for uint256;

    // ============ Structs ============

    struct UserReputation {
        uint256 contestsJoined;
        uint256 contestsCompleted;
        uint256 votesCommitted;
        uint256 votesRevealed;
        uint256 contestsWon;
        uint256 totalYieldWon;
        uint256 firstParticipation;
        uint256 lastParticipation;
        uint256 consecutiveReveals;
        uint256 maxConsecutiveReveals;
        uint256 penaltyPoints;
        uint256 bonusPoints;
    }

    struct CreatorReputation {
        uint256 contestsCreated;
        uint256 contestsCompleted;
        uint256 contestsCancelled;
        uint256 totalParticipants;
        uint256 totalYieldDistributed;
        uint256 averageParticipation;
        uint256 firstContest;
        uint256 lastContest;
        uint256 penaltyPoints;
        uint256 bonusPoints;
    }

    // ============ State Variables ============

    mapping(address => UserReputation) public userReputations;
    mapping(address => CreatorReputation) public creatorReputations;
    mapping(address => bool) public authorizedUpdaters;

    // Score calculation weights (basis points, 10000 = 100%)
    uint256 public constant REVEAL_RATE_WEIGHT = 4000; // 40%
    uint256 public constant PARTICIPATION_WEIGHT = 2000; // 20%
    uint256 public constant LONGEVITY_WEIGHT = 1500; // 15%
    uint256 public constant CONSISTENCY_WEIGHT = 1500; // 15%
    uint256 public constant WIN_RATE_WEIGHT = 1000; // 10%

    uint256 public constant MIN_CONTESTS_FOR_SCORE = 3;
    uint256 public constant MAX_REPUTATION_SCORE = 1000;
    uint256 public constant PENALTY_DECAY_PERIOD = 30 days;
    uint256 private constant DECAY_PER_PERIOD = 50;
    uint256 public constant MAX_PENALTY_POINTS = 500;
    uint256 public constant MAX_BONUS_POINTS = 500;
    uint256 public constant MAX_CREATOR_PENALTY_POINTS = 500;

    // ============ Events ============

    event UserReputationUpdated(address indexed user, uint256 newScore);
    event CreatorReputationUpdated(address indexed creator, uint256 newScore);
    event UpdaterAuthorized(address indexed updater, bool authorized);
    event PenaltyApplied(address indexed user, uint256 points, string reason);
    event BonusApplied(address indexed user, uint256 points, string reason);

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        require(
            authorizedUpdaters[msg.sender] || msg.sender == owner(),
            "ReputationRegistry: not authorized"
        );
        _;
    }

    // ============ Constructor ============

    constructor() Ownable() {}

    // ============ Admin Functions ============

    /**
     * @notice Authorize an address to update reputations
     * @param updater Address to authorize
     * @param authorized Whether to authorize or revoke
     */
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        authorizedUpdaters[updater] = authorized;
        emit UpdaterAuthorized(updater, authorized);
    }

    // ============ User Reputation Functions ============

    /**
     * @notice Record a user joining a contest
     * @param user User address
     */
    function recordContestJoined(address user) external onlyAuthorized {
        UserReputation storage rep = userReputations[user];
        rep.contestsJoined++;

        if (rep.firstParticipation == 0) {
            rep.firstParticipation = block.timestamp;
        }
        rep.lastParticipation = block.timestamp;

        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    /**
     * @notice Record a vote commitment
     * @param user User address
     */
    function recordVoteCommitted(address user) external onlyAuthorized {
        userReputations[user].votesCommitted++;
        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    /**
     * @notice Record a vote reveal
     * @param user User address
     */
    function recordVoteRevealed(address user) external onlyAuthorized {
        UserReputation storage rep = userReputations[user];
        rep.votesRevealed++;
        rep.consecutiveReveals++;

        if (rep.consecutiveReveals > rep.maxConsecutiveReveals) {
            rep.maxConsecutiveReveals = rep.consecutiveReveals;
        }

        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    /**
     * @notice Record a missed reveal (penalize)
     * @param user User address
     */
    function recordMissedReveal(address user) external onlyAuthorized {
        UserReputation storage rep = userReputations[user];
        rep.consecutiveReveals = 0;
        if (rep.penaltyPoints + 10 > MAX_PENALTY_POINTS) {
            rep.penaltyPoints = MAX_PENALTY_POINTS;
        } else {
            rep.penaltyPoints += 10;
        }

        emit PenaltyApplied(user, 10, "Missed reveal deadline");
        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    /**
     * @notice Record contest completion
     * @param user User address
     * @param isWinner Whether user won
     * @param yieldWon Amount of yield won
     */
    function recordContestCompleted(
        address user,
        bool isWinner,
        uint256 yieldWon
    ) external onlyAuthorized {
        UserReputation storage rep = userReputations[user];
        rep.contestsCompleted++;

        if (isWinner) {
            rep.contestsWon++;
            rep.totalYieldWon += yieldWon;
        }

        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    /**
     * @notice Apply a manual bonus
     * @param user User address
     * @param points Bonus points
     * @param reason Reason for bonus
     */
    function applyBonus(
        address user,
        uint256 points,
        string calldata reason
    ) external onlyAuthorized {
        require(bytes(reason).length <= 256, "ReputationRegistry: reason too long");
        UserReputation storage rep = userReputations[user];
        require(rep.bonusPoints + points <= MAX_BONUS_POINTS, "bonus cap exceeded");
        rep.bonusPoints += points;
        emit BonusApplied(user, points, reason);
        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    /**
     * @notice Apply a manual penalty
     * @param user User address
     * @param points Penalty points
     * @param reason Reason for penalty
     */
    function applyPenalty(
        address user,
        uint256 points,
        string calldata reason
    ) external onlyAuthorized {
        require(bytes(reason).length <= 256, "ReputationRegistry: reason too long");
        UserReputation storage rep = userReputations[user];
        if (rep.penaltyPoints + points > MAX_PENALTY_POINTS) {
            rep.penaltyPoints = MAX_PENALTY_POINTS;
        } else {
            rep.penaltyPoints += points;
        }
        emit PenaltyApplied(user, points, reason);
        emit UserReputationUpdated(user, calculateUserScore(user));
    }

    // ============ Creator Reputation Functions ============

    /**
     * @notice Record a contest creation
     * @param creator Creator address
     */
    function recordContestCreated(address creator) external onlyAuthorized {
        CreatorReputation storage rep = creatorReputations[creator];
        rep.contestsCreated++;

        if (rep.firstContest == 0) {
            rep.firstContest = block.timestamp;
        }
        rep.lastContest = block.timestamp;

        emit CreatorReputationUpdated(creator, calculateCreatorScore(creator));
    }

    /**
     * @notice Record a contest completion
     * @param creator Creator address
     * @param participantCount Number of participants
     * @param yieldDistributed Total yield distributed
     * @param wasCancelled Whether contest was cancelled
     */
    function recordCreatorContestCompleted(
        address creator,
        uint256 participantCount,
        uint256 yieldDistributed,
        bool wasCancelled
    ) external onlyAuthorized {
        CreatorReputation storage rep = creatorReputations[creator];

        if (wasCancelled) {
            rep.contestsCancelled++;
            if (rep.penaltyPoints + 5 > MAX_CREATOR_PENALTY_POINTS) {
                rep.penaltyPoints = MAX_CREATOR_PENALTY_POINTS;
            } else {
                rep.penaltyPoints += 5;
            }
        } else {
            rep.contestsCompleted++;
            rep.totalParticipants += participantCount;
            rep.totalYieldDistributed += yieldDistributed;

            // Update average participation
            if (rep.contestsCompleted > 0) {
                rep.averageParticipation = rep.totalParticipants / rep.contestsCompleted;
            }
        }

        emit CreatorReputationUpdated(creator, calculateCreatorScore(creator));
    }

    // ============ Score Calculation Functions ============

    /**
     * @notice Calculate user reputation score
     * @param user User address
     * @return score Score from 0-1000
     */
    function calculateUserScore(address user) public view returns (uint256 score) {
        UserReputation storage rep = userReputations[user];

        if (rep.contestsJoined < MIN_CONTESTS_FOR_SCORE) {
            // Not enough history - return base score
            return 500;
        }

        // 1. Reveal Rate Score (0-1000)
        uint256 revealScore = 0;
        if (rep.votesCommitted > 0) {
            revealScore = (rep.votesRevealed * 1000) / rep.votesCommitted;
        }

        // 2. Participation Score (based on number of contests)
        uint256 participationScore = rep.contestsJoined.min(100) * 10;

        // 3. Longevity Score (time since first participation)
        uint256 longevityScore = 0;
        if (rep.firstParticipation > 0) {
            uint256 daysActive = (block.timestamp - rep.firstParticipation) / 1 days;
            longevityScore = daysActive.min(365) * 1000 / 365;
        }

        // 4. Consistency Score (consecutive reveals)
        uint256 consistencyScore = rep.maxConsecutiveReveals.min(50) * 20;

        // 5. Win Rate Score
        uint256 winScore = 0;
        if (rep.contestsCompleted > 0) {
            winScore = (rep.contestsWon * 1000) / rep.contestsCompleted;
        }

        // Calculate weighted score
        score = (revealScore * REVEAL_RATE_WEIGHT +
                 participationScore * PARTICIPATION_WEIGHT +
                 longevityScore * LONGEVITY_WEIGHT +
                 consistencyScore * CONSISTENCY_WEIGHT +
                 winScore * WIN_RATE_WEIGHT) / 10000;

        // Apply bonuses and penalties
        score += rep.bonusPoints;

        // Decay penalties over time (linear decay: 50 points per period)
        uint256 effectivePenalty = rep.penaltyPoints;
        if (rep.lastParticipation > 0) {
            uint256 timeSinceActive = block.timestamp - rep.lastParticipation;
            if (timeSinceActive > PENALTY_DECAY_PERIOD) {
                uint256 decayedPeriods = timeSinceActive / PENALTY_DECAY_PERIOD;
                // Cap decayedPeriods to prevent overflow in multiplication
                // MAX_PENALTY_POINTS / DECAY_PER_PERIOD is the max meaningful periods (10)
                uint256 maxMeaningfulPeriods = MAX_PENALTY_POINTS / DECAY_PER_PERIOD;
                if (decayedPeriods > maxMeaningfulPeriods) {
                    decayedPeriods = maxMeaningfulPeriods;
                }
                effectivePenalty = effectivePenalty > (decayedPeriods * DECAY_PER_PERIOD) ? effectivePenalty - (decayedPeriods * DECAY_PER_PERIOD) : 0;
            }
        }

        if (score > effectivePenalty) {
            score -= effectivePenalty;
        } else {
            score = 0;
        }

        return score.min(MAX_REPUTATION_SCORE);
    }

    /**
     * @notice Calculate creator reputation score
     * @param creator Creator address
     * @return score Score from 0-1000
     */
    function calculateCreatorScore(address creator) public view returns (uint256 score) {
        CreatorReputation storage rep = creatorReputations[creator];

        if (rep.contestsCreated < 2) {
            return 500;
        }

        // 1. Completion Rate (50%)
        uint256 completionScore = 0;
        if (rep.contestsCreated > 0) {
            completionScore = (rep.contestsCompleted * 1000) / rep.contestsCreated;
        }

        // 2. Average Participation (30%)
        uint256 participationScore = rep.averageParticipation.min(200) * 5;

        // 3. Longevity (20%)
        uint256 longevityScore = 0;
        if (rep.firstContest > 0) {
            uint256 daysActive = (block.timestamp - rep.firstContest) / 1 days;
            longevityScore = daysActive.min(365) * 1000 / 365;
        }

        // Calculate weighted score
        score = (completionScore * 5000 +
                 participationScore * 3000 +
                 longevityScore * 2000) / 10000;

        // Apply penalties
        uint256 cancellationPenalty = rep.contestsCancelled * 50;
        score = score + rep.bonusPoints;

        if (score > cancellationPenalty + rep.penaltyPoints) {
            score -= (cancellationPenalty + rep.penaltyPoints);
        } else {
            score = 0;
        }

        return score.min(MAX_REPUTATION_SCORE);
    }

    // ============ View Functions ============

    /**
     * @notice Get user reputation score
     * @param user User address
     * @return Current reputation score
     */
    function getUserScore(address user) external view returns (uint256) {
        return calculateUserScore(user);
    }

    /**
     * @notice Get creator reputation score
     * @param creator Creator address
     * @return Current reputation score
     */
    function getCreatorScore(address creator) external view returns (uint256) {
        return calculateCreatorScore(creator);
    }

    /**
     * @notice Get full user reputation data
     * @param user User address
     * @return Reputation struct
     */
    function getUserReputation(address user) external view returns (UserReputation memory) {
        return userReputations[user];
    }

    /**
     * @notice Get full creator reputation data
     * @param creator Creator address
     * @return Reputation struct
     */
    function getCreatorReputation(address creator) external view returns (CreatorReputation memory) {
        return creatorReputations[creator];
    }

    /**
     * @notice Check if user meets minimum reputation threshold
     * @param user User address
     * @param minScore Minimum score required
     * @return Whether user meets threshold
     */
    function meetsThreshold(address user, uint256 minScore) external view returns (bool) {
        // Users with zero participation have no established reputation
        if (userReputations[user].contestsJoined == 0) return false;
        return calculateUserScore(user) >= minScore;
    }

    /**
     * @notice Get user tier based on reputation score
     * @param user User address
     * @return tier 0 = Unverified, 1 = Bronze, 2 = Silver, 3 = Gold, 4 = Platinum
     */
    function getUserTier(address user) external view returns (uint256 tier) {
        // Users with no participation are always Unverified regardless of base score
        if (userReputations[user].contestsJoined == 0) return 0;

        uint256 score = calculateUserScore(user);

        if (score >= 900) return 4; // Platinum
        if (score >= 750) return 3; // Gold
        if (score >= 500) return 2; // Silver
        if (score >= 250) return 1; // Bronze
        return 0; // Unverified
    }
}
