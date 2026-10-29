// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ContestScoring
/// @notice Library for contest vote scoring calculations, extracted to reduce ContestV2 bytecode size.
/// @dev    Public-facing scoring functions (`calculateRankingScore`,
///         `calculateRatingScore`, `determineWinners`) are `external` so the
///         library deploys as a separate contract and ContestV2 delegatecalls
///         into it. This shrinks ContestV2's runtime bytecode below the EIP-170
///         24,576-byte limit. Internal helpers stay `internal` since they're
///         only called from within the library and don't need a separate dispatch.
library ContestScoring {
    /// @notice Mirror of ContestV2.ContestType — duplicated so the library can be
    ///         compiled in isolation without importing ContestV2 (which would create
    ///         a cyclic dependency through ContestV2 → PrizeDistribution → ContestScoring).
    enum ContestType { VOTE, RANK, RATE, PREDICT, PAIRWISE }

    /// @notice Sort options by vote/score, return the ranked array, scores array,
    ///         and the winning option. Pure — caller passes raw votes/totals from
    ///         storage, library does the math, caller writes results back.
    /// @param contestType  Cast from ContestV2.ContestType (uint8 to avoid the import).
    /// @param votes        Per-option vote counts (parallel to options).
    /// @param totals       Per-option total scores (parallel to options) — used for
    ///                     RANK (Borda counts) and RATE (sum of ratings).
    /// @return ranked      Options sorted descending by computed score.
    /// @return scores      The computed score for each entry in `ranked` (parallel).
    /// @return winningOption  ranked[0]. Returned separately for cheaper callers.
    function determineWinners(
        bytes32[] memory options,
        uint8 contestType,
        uint256[] memory votes,
        uint256[] memory totals
    ) external pure returns (bytes32[] memory ranked, uint256[] memory scores, bytes32 winningOption) {
        uint256 n = options.length;
        ranked = new bytes32[](n);
        scores = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            ranked[i] = options[i];
            if (contestType == uint8(ContestType.RATE)) {
                if (votes[i] > 0) {
                    scores[i] = totals[i] / votes[i];
                }
            } else if (contestType == uint8(ContestType.RANK)) {
                scores[i] = totals[i];
            } else {
                scores[i] = votes[i];
            }
        }

        // Insertion sort by score descending — gas-efficient for small arrays.
        for (uint256 i = 1; i < n; i++) {
            uint256 keyScore = scores[i];
            bytes32 keyOption = ranked[i];
            uint256 j = i;
            while (j > 0 && scores[j - 1] < keyScore) {
                scores[j] = scores[j - 1];
                ranked[j] = ranked[j - 1];
                j--;
            }
            scores[j] = keyScore;
            ranked[j] = keyOption;
        }

        if (n > 0) {
            winningOption = ranked[0];
        }
    }

    /// @notice Calculate Spearman ranking correlation score (0-100)
    function calculateRankingScore(
        bytes32[] memory voterRanking,
        bytes32[] memory actualRanking
    ) external pure returns (uint256) {
        uint256 n = voterRanking.length < actualRanking.length ? voterRanking.length : actualRanking.length;
        if (n < 2) return 0;

        uint256 dSquaredSum = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 actualRank = findRank(actualRanking, voterRanking[i]);
            uint256 diff = i > actualRank ? i - actualRank : actualRank - i;
            dSquaredSum += diff * diff;
        }

        // Spearman: 1 - (6 * Σd²) / (n * (n² - 1)), scaled to 0-100
        uint256 maxDSquared = n * (n * n - 1) / 6;
        if (dSquaredSum >= maxDSquared) return 0;

        return 100 * (maxDSquared - dSquaredSum) / maxDSquared;
    }

    /// @notice Find index of an item in a ranking array
    function findRank(bytes32[] memory ranking, bytes32 item) internal pure returns (uint256) {
        for (uint256 i = 0; i < ranking.length; i++) {
            if (ranking[i] == item) return i;
        }
        return ranking.length;
    }

    /// @notice Calculate rating correlation score (0-100)
    function calculateRatingScore(
        bytes32[] memory optionIds,
        uint256[] memory ratings,
        mapping(bytes32 => uint256) storage optionVotes,
        mapping(bytes32 => uint256) storage optionTotalScore
    ) internal view returns (uint256) {
        uint256 totalDiff = 0;
        uint256 maxDiff = 0;

        for (uint256 i = 0; i < optionIds.length; i++) {
            uint256 avgRating = optionVotes[optionIds[i]] > 0
                ? optionTotalScore[optionIds[i]] / optionVotes[optionIds[i]]
                : 0;

            uint256 diff = ratings[i] > avgRating ? ratings[i] - avgRating : avgRating - ratings[i];
            totalDiff += diff;
            maxDiff += 10; // Assuming 1-10 rating scale
        }

        if (maxDiff == 0) return 0;
        return 100 * (maxDiff - totalDiff) / maxDiff;
    }
}
