// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TwabController
 * @notice Time-Weighted Average Balance tracking inspired by PoolTogether V5.
 *
 * Maintains a 64-slot ring buffer of (timestamp, cumulativeBalance) observations
 * per user. The cumulative balance grows by `balance * elapsed` each time a new
 * observation is recorded, enabling O(log n) TWAB queries over arbitrary ranges
 * via binary search.
 *
 * Design decisions:
 *  - 64 slots ≈ 64 balance-change events before oldest is overwritten.
 *  - Observations are only written on balance changes (deposit / withdraw / delegate).
 *  - getTwab(user, start, end) returns the time-weighted average balance across the range.
 *  - A global (total supply) TWAB is maintained in parallel for proportional odds.
 */
contract TwabController {
    // ─── Constants ──────────────────────────────────────────────────────────────

    uint16 public constant MAX_CARDINALITY = 256;

    // ─── Types ──────────────────────────────────────────────────────────────────

    struct Observation {
        uint64  timestamp;
        uint96  balance;
        uint256 cumulativeBalance;  // Σ(balance_i × dt_i) at this observation
    }

    struct AccountDetails {
        uint96  balance;
        uint16  nextIndex;       // next write position in the ring buffer
        uint16  cardinality;     // number of populated slots (≤ MAX_CARDINALITY)
    }

    // ─── Storage ────────────────────────────────────────────────────────────────

    /// @dev user → ring buffer of observations
    mapping(address => Observation[MAX_CARDINALITY]) internal _observations;
    mapping(address => AccountDetails)               internal _accounts;

    /// @dev Global (total supply) TWAB tracked via sentinel address(0)

    // ─── Events ─────────────────────────────────────────────────────────────────

    event ObservationRecorded(
        address indexed user,
        uint96  balance,
        uint256 cumulativeBalance,
        uint64  timestamp
    );

    // ─── External View ──────────────────────────────────────────────────────────

    /**
     * @notice Time-weighted average balance for `user` over [start, end).
     * @param user  The account to query.
     * @param start Start timestamp (inclusive).
     * @param end   End timestamp (exclusive).
     * @return The TWAB across the given period.
     */
    function getTwab(address user, uint64 start, uint64 end) external view returns (uint256) {
        require(end > start, "TwabController: end <= start");
        return _getTwab(user, start, end);
    }

    /**
     * @notice Total-supply TWAB over [start, end).
     */
    function getTotalSupplyTwab(uint64 start, uint64 end) external view returns (uint256) {
        require(end > start, "TwabController: end <= start");
        return _getTwab(address(0), start, end);
    }

    /**
     * @notice Current balance for a user.
     */
    function balanceOf(address user) external view returns (uint96) {
        return _accounts[user].balance;
    }

    /**
     * @notice Current total supply.
     */
    function totalSupply() external view returns (uint96) {
        return _accounts[address(0)].balance;
    }

    /**
     * @notice Number of observations recorded for a user.
     */
    function getObservationCount(address user) external view returns (uint16) {
        return _accounts[user].cardinality;
    }

    // ─── Internal Mutation ──────────────────────────────────────────────────────

    /**
     * @dev Increase a user's balance and record observations.
     *      Called by NoLossLotteryV2 on deposit / delegation-in.
     */
    function _increaseBalance(address user, uint96 amount) internal {
        AccountDetails storage acct = _accounts[user];
        uint96 newBalance = acct.balance + amount;
        acct.balance = newBalance;
        _recordObservation(user, newBalance);

        // Update total supply TWAB
        AccountDetails storage totalAcct = _accounts[address(0)];
        uint96 newTotal = totalAcct.balance + amount;
        totalAcct.balance = newTotal;
        _recordObservation(address(0), newTotal);
    }

    /**
     * @dev Decrease a user's balance and record observations.
     *      Called by NoLossLotteryV2 on withdraw / delegation-out.
     */
    function _decreaseBalance(address user, uint96 amount) internal {
        AccountDetails storage acct = _accounts[user];
        require(acct.balance >= amount, "TwabController: insufficient balance");
        uint96 newBalance = acct.balance - amount;
        acct.balance = newBalance;
        _recordObservation(user, newBalance);

        // Update total supply TWAB
        AccountDetails storage totalAcct = _accounts[address(0)];
        uint96 newTotal = totalAcct.balance - amount;
        totalAcct.balance = newTotal;
        _recordObservation(address(0), newTotal);
    }

    // ─── Internal Observation Logic ─────────────────────────────────────────────

    function _recordObservation(address user, uint96 newBalance) internal {
        AccountDetails storage acct = _accounts[user];
        Observation[MAX_CARDINALITY] storage obs = _observations[user];

        uint64 now_ = uint64(block.timestamp);
        uint256 cumulative = 0;

        if (acct.cardinality > 0) {
            // Index of the most recent observation
            uint16 prevIndex = (acct.nextIndex + MAX_CARDINALITY - 1) % MAX_CARDINALITY;
            Observation storage prev = obs[prevIndex];

            // If same block, just update the balance (no new slot consumed)
            if (prev.timestamp == now_) {
                prev.balance = newBalance;
                return;
            }

            uint64 elapsed = now_ - prev.timestamp;
            cumulative = prev.cumulativeBalance + uint256(prev.balance) * elapsed;
        }

        // Write new observation at nextIndex
        obs[acct.nextIndex] = Observation({
            timestamp:         now_,
            balance:           newBalance,
            cumulativeBalance: cumulative
        });

        emit ObservationRecorded(user, newBalance, cumulative, now_);

        acct.nextIndex = (acct.nextIndex + 1) % MAX_CARDINALITY;
        if (acct.cardinality < MAX_CARDINALITY) {
            acct.cardinality++;
        }
    }

    // ─── Internal TWAB Query ────────────────────────────────────────────────────

    function _getTwab(address user, uint64 start, uint64 end) internal view returns (uint256) {
        AccountDetails storage acct = _accounts[user];
        if (acct.cardinality == 0) return 0;

        uint256 startCumulative = _getCumulativeAt(user, start);
        uint256 endCumulative   = _getCumulativeAt(user, end);

        if (endCumulative <= startCumulative) return 0;
        return (endCumulative - startCumulative) / uint256(end - start);
    }

    /**
     * @dev Interpolate the cumulative balance at a given timestamp.
     *      Uses binary search over the ring buffer to find the surrounding observations.
     */
    function _getCumulativeAt(address user, uint64 target) internal view returns (uint256) {
        AccountDetails storage acct = _accounts[user];
        Observation[MAX_CARDINALITY] storage obs = _observations[user];
        uint16 card = acct.cardinality;

        if (card == 0) return 0;

        // Oldest and newest indices
        uint16 oldestIdx = card < MAX_CARDINALITY ? 0 : acct.nextIndex;
        uint16 newestIdx = (acct.nextIndex + MAX_CARDINALITY - 1) % MAX_CARDINALITY;

        Observation storage oldest = obs[oldestIdx];
        Observation storage newest = obs[newestIdx];

        // Before any observations → 0
        if (target <= oldest.timestamp) return 0;

        // After newest → extrapolate from newest
        if (target >= newest.timestamp) {
            uint64 elapsedSinceNewest = target - newest.timestamp;
            return newest.cumulativeBalance + uint256(newest.balance) * elapsedSinceNewest;
        }

        // Binary search within the ring buffer
        uint16 lo = 0;
        uint16 hi = card - 1;

        while (lo < hi) {
            uint16 mid = lo + (hi - lo + 1) / 2;
            uint16 midIdx = (oldestIdx + mid) % MAX_CARDINALITY;
            if (obs[midIdx].timestamp <= target) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        uint16 foundIdx = (oldestIdx + lo) % MAX_CARDINALITY;
        Observation storage before = obs[foundIdx];

        // Interpolate
        uint64 elapsed = target - before.timestamp;
        return before.cumulativeBalance + uint256(before.balance) * elapsed;
    }
}
