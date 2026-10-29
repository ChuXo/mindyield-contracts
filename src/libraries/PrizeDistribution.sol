// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PrizeDistribution
/// @notice Pure-function library implementing all five voter prize distribution
///         models for ContestV2. Extracted from ContestV2 for bytecode size and
///         to enable focused unit testing.
///
///         Models:
///           - PROPORTIONAL:    pool * voter.score / totalScore for every eligible
///           - SINGLE_TOP:      100% to highest-score voter; ties split pro-rata
///           - SINGLE_RANDOM:   VRF picks one eligible (uniform or score-weighted)
///           - TOP_N_RANKED:    splitsBps to top N by score; cutoff ties split pro-rata
///           - TOP_N_RANDOM:    VRF picks N eligibles (uniform or score-weighted)
///
///         All functions return (winners[], amounts[]) arrays the caller writes
///         into the voterRewards mapping. Sum of amounts equals (pool - rounding
///         dust); caller tracks dust separately.
library PrizeDistribution {
    /// @notice Eligible voter passed in by the caller. Caller filters by
    ///         (hasRevealed && score >= eligibilityThreshold) before invoking
    ///         any distribution function.
    struct Eligible {
        address voter;
        uint256 score;
    }

    /// @notice Mirror of ContestV2.PrizeModel — duplicated here so the library
    ///         can be unit-tested in isolation and so the dispatch entrypoint
    ///         doesn't import ContestV2.
    enum Model { PROPORTIONAL, SINGLE_TOP, SINGLE_RANDOM, TOP_N_RANKED, TOP_N_RANDOM, STAKE_WEIGHTED }

    error InvalidSplits();
    error EmptyEligibles();
    error TopNExceedsEligibles();
    error InvalidPrizeConfig();
    error RandomnessManagerRequired();
    error UnsupportedModel();

    // ─────────────────────────────────────────────────────────────────────
    //  CONFIG VALIDATION (extracted from ContestV2 to save bytecode)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Validate prize config at contest initialization. Reverts on bad input.
    /// @param model            The chosen prize model (cast from ContestV2.PrizeModel).
    /// @param splitsBps        Per-rank split array; must be empty for non-TOP_N
    ///                         models, must sum to exactly 10_000 for TOP_N models.
    /// @param maxParticipants  Caller's MAX_PARTICIPANTS_CAP — used as the upper
    ///                         bound on splitsBps.length for TOP_N models.
    /// @param randomnessManager Address of the RM the contest is bound to. Must
    ///                         be non-zero for *_RANDOM models.
    function validateConfig(
        uint8 model,
        uint16[] calldata splitsBps,
        uint256 maxParticipants,
        address randomnessManager
    ) external pure {
        bool isRandom = model == uint8(Model.SINGLE_RANDOM) || model == uint8(Model.TOP_N_RANDOM);
        bool isTopN = model == uint8(Model.TOP_N_RANKED) || model == uint8(Model.TOP_N_RANDOM);

        if (isRandom && randomnessManager == address(0)) revert RandomnessManagerRequired();

        if (isTopN) {
            uint256 len = splitsBps.length;
            if (len == 0 || len > maxParticipants) revert InvalidPrizeConfig();
            uint256 sum;
            for (uint256 i = 0; i < len; ) {
                sum += splitsBps[i];
                unchecked { ++i; }
            }
            if (sum != 10_000) revert InvalidPrizeConfig();
        } else if (splitsBps.length != 0) {
            revert InvalidPrizeConfig();
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  DISPATCH (single entrypoint for ContestV2 — saves the in-contract if/else)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Execute the configured distribution model and return winners + amounts.
    /// @dev Caller passes pre-built `eligibles` and `pool`. For STAKE_WEIGHTED the
    ///      caller MUST pre-rewrite each eligible's `score` field with the voter's
    ///      stake (depositReceived) before calling — this library can't read storage.
    function distribute(
        uint8 model,
        Eligible[] memory eligibles,
        uint256 pool,
        uint16[] memory splitsBps,
        uint256 randomWord,
        bool weightedByScore
    ) external pure returns (address[] memory winners, uint256[] memory amounts) {
        if (pool == 0) {
            return (new address[](0), new uint256[](0));
        }

        if (model == uint8(Model.PROPORTIONAL) || model == uint8(Model.STAKE_WEIGHTED)) {
            return distributeProportional(eligibles, pool);
        }
        if (model == uint8(Model.SINGLE_TOP)) {
            return distributeSingleTop(eligibles, pool);
        }
        if (model == uint8(Model.TOP_N_RANKED)) {
            return distributeTopNRanked(eligibles, pool, splitsBps);
        }
        if (model == uint8(Model.SINGLE_RANDOM)) {
            return distributeSingleRandom(eligibles, pool, randomWord, weightedByScore);
        }
        if (model == uint8(Model.TOP_N_RANDOM)) {
            return distributeTopNRandom(eligibles, pool, splitsBps, randomWord, weightedByScore);
        }
        revert UnsupportedModel();
    }

    // ─────────────────────────────────────────────────────────────────────
    //  VALIDATION
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Validate that splitsBps is non-empty and sums to exactly 10000.
    /// @dev Reverts on invalid splits. Caller should call once at config time
    ///      (factory.createContest) AND defensively here.
    function validateSplits(uint16[] memory splitsBps) internal pure {
        uint256 len = splitsBps.length;
        if (len == 0) revert InvalidSplits();
        uint256 sum;
        for (uint256 i = 0; i < len; ) {
            sum += splitsBps[i];
            unchecked { ++i; }
        }
        if (sum != 10_000) revert InvalidSplits();
    }

    // ─────────────────────────────────────────────────────────────────────
    //  PROPORTIONAL
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Distribute the pool proportionally to every eligible voter's
    ///         score. Returns one entry per eligible.
    /// @dev If totalScore == 0 returns empty arrays (caller treats whole
    ///      pool as undistributed dust).
    function distributeProportional(
        Eligible[] memory eligibles,
        uint256 pool
    ) internal pure returns (address[] memory winners, uint256[] memory amounts) {
        uint256 n = eligibles.length;
        if (n == 0 || pool == 0) {
            return (new address[](0), new uint256[](0));
        }

        uint256 totalScore;
        for (uint256 i = 0; i < n; ) {
            totalScore += eligibles[i].score;
            unchecked { ++i; }
        }
        if (totalScore == 0) {
            return (new address[](0), new uint256[](0));
        }

        winners = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ) {
            winners[i] = eligibles[i].voter;
            // Solidity integer division rounds toward zero (favors the vault).
            amounts[i] = (pool * eligibles[i].score) / totalScore;
            unchecked { ++i; }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SINGLE TOP (deterministic)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pay 100% of pool to the highest-scoring voter.
    ///         If multiple voters tie for the top score, split the pool
    ///         pro-rata equally between them (each gets pool / tieCount).
    function distributeSingleTop(
        Eligible[] memory eligibles,
        uint256 pool
    ) internal pure returns (address[] memory winners, uint256[] memory amounts) {
        uint256 n = eligibles.length;
        if (n == 0 || pool == 0) {
            return (new address[](0), new uint256[](0));
        }

        // Find max score.
        uint256 maxScore;
        for (uint256 i = 0; i < n; ) {
            if (eligibles[i].score > maxScore) maxScore = eligibles[i].score;
            unchecked { ++i; }
        }
        if (maxScore == 0) {
            return (new address[](0), new uint256[](0));
        }

        // Count ties at top.
        uint256 tieCount;
        for (uint256 i = 0; i < n; ) {
            if (eligibles[i].score == maxScore) {
                unchecked { ++tieCount; }
            }
            unchecked { ++i; }
        }

        winners = new address[](tieCount);
        amounts = new uint256[](tieCount);
        uint256 share = pool / tieCount;
        uint256 cursor;
        for (uint256 i = 0; i < n; ) {
            if (eligibles[i].score == maxScore) {
                winners[cursor] = eligibles[i].voter;
                amounts[cursor] = share;
                unchecked { ++cursor; }
            }
            unchecked { ++i; }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TOP-N RANKED (deterministic)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pay splitsBps[i] of pool to the i-th ranked voter.
    ///         If voters tie at the cutoff (rank N-1), all tied voters share
    ///         the cutoff slot's allocation pro-rata. This means the returned
    ///         array may be longer than splitsBps.length when ties exist.
    /// @dev    Caller must have called validateSplits(splitsBps) at config time.
    ///         Defensive validation here keeps the library safe in isolation.
    function distributeTopNRanked(
        Eligible[] memory eligibles,
        uint256 pool,
        uint16[] memory splitsBps
    ) internal pure returns (address[] memory winners, uint256[] memory amounts) {
        validateSplits(splitsBps);

        uint256 n = eligibles.length;
        uint256 topN = splitsBps.length;
        if (n == 0 || pool == 0) {
            return (new address[](0), new uint256[](0));
        }

        // Sort eligibles by score descending (insertion sort — same pattern as
        // ContestV2._determineWinners, gas-efficient for small N; eligible
        // counts in practice are bounded by participantList <= 10_000).
        Eligible[] memory sorted = _sortByScoreDesc(eligibles);

        // Trim to actual top-N consideration set, but include all voters tied
        // with sorted[topN-1] so they share that rank's allocation.
        uint256 effectiveN = topN > n ? n : topN;
        uint256 cutoffScore = sorted[effectiveN - 1].score;

        // If cutoff score is zero, only voters with score > 0 are eligible —
        // collapse effectiveN to the count of positive-score voters.
        if (cutoffScore == 0) {
            uint256 positiveCount;
            for (uint256 i = 0; i < n; ) {
                if (sorted[i].score > 0) {
                    unchecked { ++positiveCount; }
                }
                unchecked { ++i; }
            }
            if (positiveCount == 0) {
                return (new address[](0), new uint256[](0));
            }
            // Reduce effectiveN to positiveCount (cutoff now positive).
            if (positiveCount < effectiveN) {
                effectiveN = positiveCount;
                cutoffScore = sorted[effectiveN - 1].score;
            }
        }

        // Determine where the cutoff "starts" (first index with cutoffScore in
        // the top-N window). Voters before that index get their own splitsBps
        // slot deterministically; voters at cutoffScore share the remaining bps.
        uint256 cutoffStart = effectiveN - 1;
        while (cutoffStart > 0 && sorted[cutoffStart - 1].score == cutoffScore) {
            unchecked { --cutoffStart; }
        }

        // Count voters at cutoff score (tie expansion). Count from cutoffStart
        // forward so that when the tie extends above effectiveN-1 (i.e. the
        // cutoff was pushed down), the expanded set is counted correctly.
        // Because `sorted` is desc-sorted and cutoffStart is the first index
        // at cutoffScore, every index in [cutoffStart, n) with matching score
        // is contiguous from cutoffStart; a non-matching entry terminates.
        uint256 tieCount;
        for (uint256 i = cutoffStart; i < n; ) {
            if (sorted[i].score == cutoffScore) {
                unchecked { ++tieCount; }
            } else {
                break;
            }
            unchecked { ++i; }
        }

        // Total bps allocated to the tie slot(s):
        // sum of splitsBps[cutoffStart .. effectiveN-1] (inclusive)
        uint256 tieBps;
        for (uint256 i = cutoffStart; i < effectiveN; ) {
            tieBps += splitsBps[i];
            unchecked { ++i; }
        }

        // Total winners: cutoffStart (clean ranks) + tieCount (tied at cutoff)
        uint256 totalWinners = cutoffStart + tieCount;
        winners = new address[](totalWinners);
        amounts = new uint256[](totalWinners);

        // Clean (non-tied) top ranks.
        for (uint256 i = 0; i < cutoffStart; ) {
            winners[i] = sorted[i].voter;
            amounts[i] = (pool * splitsBps[i]) / 10_000;
            unchecked { ++i; }
        }

        // Tied voters at the cutoff share tieBps equally.
        if (tieCount > 0) {
            uint256 tiePool = (pool * tieBps) / 10_000;
            uint256 tieShare = tiePool / tieCount;
            for (uint256 i = 0; i < tieCount; ) {
                winners[cutoffStart + i] = sorted[cutoffStart + i].voter;
                amounts[cutoffStart + i] = tieShare;
                unchecked { ++i; }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SINGLE RANDOM (VRF)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pay 100% of pool to one VRF-selected eligible voter.
    /// @param weighted If true, selection probability is proportional to
    ///                 voter score. If false, all eligibles have equal odds.
    function distributeSingleRandom(
        Eligible[] memory eligibles,
        uint256 pool,
        uint256 randomWord,
        bool weighted
    ) internal pure returns (address[] memory winners, uint256[] memory amounts) {
        uint256 n = eligibles.length;
        if (n == 0 || pool == 0) {
            return (new address[](0), new uint256[](0));
        }

        uint256 idx;
        if (weighted) {
            uint256 totalScore;
            for (uint256 i = 0; i < n; ) {
                totalScore += eligibles[i].score;
                unchecked { ++i; }
            }
            if (totalScore == 0) {
                // Fallback to uniform when no weights are positive.
                idx = randomWord % n;
            } else {
                idx = _weightedPick(eligibles, totalScore, randomWord);
            }
        } else {
            idx = randomWord % n;
        }

        winners = new address[](1);
        amounts = new uint256[](1);
        winners[0] = eligibles[idx].voter;
        amounts[0] = pool;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TOP-N RANDOM (VRF)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice VRF-pick splitsBps.length eligibles (without replacement),
    ///         pay each per the corresponding splitsBps slot.
    /// @dev Uses Fisher-Yates partial shuffle with keccak-derived per-step
    ///      randomness from the single VRF word. Guarantees uniform (or
    ///      weighted) selection without replacement.
    function distributeTopNRandom(
        Eligible[] memory eligibles,
        uint256 pool,
        uint16[] memory splitsBps,
        uint256 randomWord,
        bool weighted
    ) internal pure returns (address[] memory winners, uint256[] memory amounts) {
        validateSplits(splitsBps);

        uint256 n = eligibles.length;
        uint256 k = splitsBps.length;
        if (n == 0 || pool == 0) {
            return (new address[](0), new uint256[](0));
        }
        // If fewer eligibles than slots, shrink k and reuse same splits prefix —
        // unused tail bps becomes undistributed dust (caller tracks).
        if (k > n) k = n;

        winners = new address[](k);
        amounts = new uint256[](k);

        // Work on a mutable copy so we can swap-and-shrink without touching
        // caller storage.
        Eligible[] memory pool_ = new Eligible[](n);
        for (uint256 i = 0; i < n; ) {
            pool_[i] = eligibles[i];
            unchecked { ++i; }
        }
        uint256 remaining = n;

        // Pre-compute total score for weighted mode (decremented as we pick).
        uint256 totalScore;
        if (weighted) {
            for (uint256 i = 0; i < n; ) {
                totalScore += pool_[i].score;
                unchecked { ++i; }
            }
            // If all weights zero, fall back to uniform.
            if (totalScore == 0) weighted = false;
        }

        for (uint256 slot = 0; slot < k; ) {
            // Derive fresh per-step randomness from the single VRF word.
            uint256 stepRandom = uint256(keccak256(abi.encode(randomWord, slot)));

            uint256 pickIdx;
            if (weighted && totalScore > 0) {
                pickIdx = _weightedPickInRange(pool_, remaining, totalScore, stepRandom);
                // Decrement totalScore by the picked voter's weight before
                // the swap-remove below.
                totalScore -= pool_[pickIdx].score;
            } else {
                // Audit M-03: weights collapsed mid-loop (all remaining
                // eligibles have score == 0). Fall back to uniform pick to
                // avoid `mod 0` revert in _weightedPickInRange.
                pickIdx = stepRandom % remaining;
            }

            winners[slot] = pool_[pickIdx].voter;
            amounts[slot] = (pool * splitsBps[slot]) / 10_000;

            // Swap-remove: replace picked slot with last active element,
            // decrement remaining. O(1) per pick, total O(k).
            unchecked { --remaining; }
            if (pickIdx != remaining) {
                pool_[pickIdx] = pool_[remaining];
            }

            unchecked { ++slot; }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Insertion sort by score descending. Returns a new array — caller's
    ///      input is not mutated. O(n²) acceptable for n <= MAX_PARTICIPANTS_CAP
    ///      (10_000), and typical eligible counts are far smaller.
    function _sortByScoreDesc(Eligible[] memory src) private pure returns (Eligible[] memory) {
        uint256 n = src.length;
        Eligible[] memory out = new Eligible[](n);
        for (uint256 i = 0; i < n; ) {
            out[i] = src[i];
            unchecked { ++i; }
        }
        for (uint256 i = 1; i < n; ) {
            Eligible memory key = out[i];
            uint256 j = i;
            while (j > 0 && out[j - 1].score < key.score) {
                out[j] = out[j - 1];
                unchecked { --j; }
            }
            out[j] = key;
            unchecked { ++i; }
        }
        return out;
    }

    /// @dev Linear-scan weighted pick across the full eligibles array.
    ///      O(n). Returns the index of the picked element.
    function _weightedPick(
        Eligible[] memory eligibles,
        uint256 totalScore,
        uint256 randomWord
    ) private pure returns (uint256) {
        uint256 target = randomWord % totalScore;
        uint256 cumulative;
        uint256 n = eligibles.length;
        for (uint256 i = 0; i < n; ) {
            cumulative += eligibles[i].score;
            if (target < cumulative) return i;
            unchecked { ++i; }
        }
        // Unreachable (totalScore is sum of all weights), but Solidity needs
        // a return on every path. Fall back to last index.
        return n - 1;
    }

    /// @dev Same as _weightedPick but only considers the first `activeLen`
    ///      elements of the array (used during Fisher-Yates partial shuffle
    ///      where the suffix has been swapped out).
    function _weightedPickInRange(
        Eligible[] memory pool_,
        uint256 activeLen,
        uint256 totalScore,
        uint256 randomWord
    ) private pure returns (uint256) {
        uint256 target = randomWord % totalScore;
        uint256 cumulative;
        for (uint256 i = 0; i < activeLen; ) {
            cumulative += pool_[i].score;
            if (target < cumulative) return i;
            unchecked { ++i; }
        }
        return activeLen - 1;
    }
}
