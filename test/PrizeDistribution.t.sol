// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/libraries/PrizeDistribution.sol";

/// @title PrizeDistributionTest
/// @notice Pure-function tests for the PrizeDistribution library.
///         Decoupled from ContestV2 so they can run quickly and verify the
///         math in isolation. Integration tests for the full VRF flow live in
///         a separate file (ContestV2.prizeModels.v21.t.sol).
contract PrizeDistributionTest is Test {
    using PrizeDistribution for PrizeDistribution.Eligible[];

    // Thin external wrappers so vm.expectRevert can catch library asserts.
    // Inlined internal library reverts happen at the same stack depth as the
    // test function, which Foundry's expectRevert cheatcode can't intercept.
    function _callValidateSplits(uint16[] memory s) external pure {
        PrizeDistribution.validateSplits(s);
    }

    function _callTopNRanked(
        PrizeDistribution.Eligible[] memory es,
        uint256 pool,
        uint16[] memory s
    ) external pure {
        PrizeDistribution.distributeTopNRanked(es, pool, s);
    }

    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant CHARLIE = address(0xC4A1E);
    address constant DAVE    = address(0xDA7E);
    address constant EVE     = address(0xE7E);

    // ─────────────────────────────────────────────────────────────────────
    //  validateSplits
    // ─────────────────────────────────────────────────────────────────────

    function test_validateSplits_validSum() public pure {
        uint16[] memory s = new uint16[](3);
        s[0] = 7500; s[1] = 2000; s[2] = 500;
        PrizeDistribution.validateSplits(s); // no revert
    }

    function test_validateSplits_singleHundred() public pure {
        uint16[] memory s = new uint16[](1);
        s[0] = 10000;
        PrizeDistribution.validateSplits(s);
    }

    function test_validateSplits_emptyReverts() public {
        uint16[] memory s = new uint16[](0);
        vm.expectRevert(PrizeDistribution.InvalidSplits.selector);
        this._callValidateSplits(s);
    }

    function test_validateSplits_wrongSumReverts() public {
        uint16[] memory s = new uint16[](2);
        s[0] = 5000; s[1] = 4000; // sums to 9000, not 10000
        vm.expectRevert(PrizeDistribution.InvalidSplits.selector);
        this._callValidateSplits(s);
    }

    function testFuzz_validateSplits_acceptsAnyValidSum(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 50));
        uint16[] memory s = new uint16[](n);
        // Distribute exactly 10000 across n slots pseudo-randomly.
        uint256 remaining = 10_000;
        for (uint256 i = 0; i < n - 1; i++) {
            uint256 share = uint256(keccak256(abi.encode(seed, i))) % (remaining / (n - i) + 1);
            s[i] = uint16(share);
            remaining -= share;
        }
        s[n - 1] = uint16(remaining);
        // Should not revert.
        PrizeDistribution.validateSplits(s);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  PROPORTIONAL
    // ─────────────────────────────────────────────────────────────────────

    function test_proportional_basic() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](3);
        es[0] = PrizeDistribution.Eligible(ALICE, 50);
        es[1] = PrizeDistribution.Eligible(BOB,   30);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 20);
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeProportional(es, 1000);
        assertEq(winners.length, 3);
        assertEq(amts[0], 500); // 1000 * 50/100
        assertEq(amts[1], 300);
        assertEq(amts[2], 200);
        assertEq(winners[0], ALICE);
    }

    function test_proportional_emptyReturnsEmpty() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](0);
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeProportional(es, 1000);
        assertEq(winners.length, 0);
        assertEq(amts.length, 0);
    }

    function test_proportional_zeroPoolReturnsEmpty() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](2);
        es[0] = PrizeDistribution.Eligible(ALICE, 50);
        es[1] = PrizeDistribution.Eligible(BOB,   50);
        (address[] memory winners,) =
            PrizeDistribution.distributeProportional(es, 0);
        assertEq(winners.length, 0);
    }

    function test_proportional_zeroScoresReturnsEmpty() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](2);
        es[0] = PrizeDistribution.Eligible(ALICE, 0);
        es[1] = PrizeDistribution.Eligible(BOB,   0);
        (address[] memory winners,) =
            PrizeDistribution.distributeProportional(es, 1000);
        assertEq(winners.length, 0);
    }

    function testFuzz_proportional_dustNeverNegative(uint256 pool, uint8 n, uint256 seed) public pure {
        pool = bound(pool, 0, type(uint128).max);
        n = uint8(bound(n, 1, 100));
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](n);
        for (uint256 i = 0; i < n; i++) {
            es[i] = PrizeDistribution.Eligible(
                address(uint160(i + 1)),
                (uint256(keccak256(abi.encode(seed, i))) % 100) + 1 // 1-100
            );
        }
        (, uint256[] memory amts) = PrizeDistribution.distributeProportional(es, pool);

        uint256 distributed;
        for (uint256 i = 0; i < amts.length; i++) distributed += amts[i];
        // Always rounds down — never overpays the pool.
        assertLe(distributed, pool);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SINGLE_TOP
    // ─────────────────────────────────────────────────────────────────────

    function test_singleTop_uniqueWinner() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](3);
        es[0] = PrizeDistribution.Eligible(ALICE, 50);
        es[1] = PrizeDistribution.Eligible(BOB,   90);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 30);
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeSingleTop(es, 1000);
        assertEq(winners.length, 1);
        assertEq(winners[0], BOB);
        assertEq(amts[0], 1000);
    }

    function test_singleTop_threeWayTieSplits() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](4);
        es[0] = PrizeDistribution.Eligible(ALICE,   90);
        es[1] = PrizeDistribution.Eligible(BOB,     90);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 90);
        es[3] = PrizeDistribution.Eligible(DAVE,    50);
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeSingleTop(es, 999);
        assertEq(winners.length, 3);
        assertEq(amts[0], 333);
        assertEq(amts[1], 333);
        assertEq(amts[2], 333);
    }

    function test_singleTop_zeroMaxScoreReturnsEmpty() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](2);
        es[0] = PrizeDistribution.Eligible(ALICE, 0);
        es[1] = PrizeDistribution.Eligible(BOB,   0);
        (address[] memory winners,) = PrizeDistribution.distributeSingleTop(es, 1000);
        assertEq(winners.length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TOP_N_RANKED
    // ─────────────────────────────────────────────────────────────────────

    function test_topNRanked_basicSplits() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](5);
        es[0] = PrizeDistribution.Eligible(ALICE,   90);
        es[1] = PrizeDistribution.Eligible(BOB,     80);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 70);
        es[3] = PrizeDistribution.Eligible(DAVE,    60);
        es[4] = PrizeDistribution.Eligible(EVE,     50);
        uint16[] memory s = new uint16[](3);
        s[0] = 7500; s[1] = 2000; s[2] = 500;
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRanked(es, 1000, s);
        assertEq(winners.length, 3);
        assertEq(winners[0], ALICE);
        assertEq(winners[1], BOB);
        assertEq(winners[2], CHARLIE);
        assertEq(amts[0], 750);
        assertEq(amts[1], 200);
        assertEq(amts[2], 50);
    }

    function test_topNRanked_cutoffTieSplits() public pure {
        // Three voters tied at score 60 for the rank-3 cutoff.
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](5);
        es[0] = PrizeDistribution.Eligible(ALICE,   90);
        es[1] = PrizeDistribution.Eligible(BOB,     80);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 60);
        es[3] = PrizeDistribution.Eligible(DAVE,    60);
        es[4] = PrizeDistribution.Eligible(EVE,     60);
        uint16[] memory s = new uint16[](3);
        s[0] = 7500; s[1] = 2000; s[2] = 500;
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRanked(es, 1000, s);
        // Alice + Bob get clean ranks; 3 tied voters share rank-3 share equally.
        assertEq(winners.length, 5);
        assertEq(amts[0], 750);
        assertEq(amts[1], 200);
        // Tied voters share floor(50/3) = 16 each, dust = 2.
        assertEq(amts[2], 16);
        assertEq(amts[3], 16);
        assertEq(amts[4], 16);
    }

    function test_topNRanked_fewerEligiblesThanSlots() public pure {
        // Only 2 eligibles for 3-way splits — should pay top 2 their own slots,
        // tail bps becomes dust (caller tracks).
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](2);
        es[0] = PrizeDistribution.Eligible(ALICE, 90);
        es[1] = PrizeDistribution.Eligible(BOB,   60);
        uint16[] memory s = new uint16[](3);
        s[0] = 7500; s[1] = 2000; s[2] = 500;
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRanked(es, 1000, s);
        assertEq(winners.length, 2);
        // effectiveN = 2; cutoff = sorted[1] = 60; cutoffStart = 1; tieBps = 2000.
        assertEq(winners[0], ALICE);
        assertEq(winners[1], BOB);
        assertEq(amts[0], 750);
        assertEq(amts[1], 200);
    }

    /// @notice Regression — when all eligibles tie at the cutoff score (i.e. the
    ///         cutoff is pushed all the way to rank 0), every tied voter must
    ///         share the full pool. Prior tieCount math only counted voters at
    ///         index effectiveN-1, so voters above that index were dropped.
    function test_topNRanked_allEligiblesTiedSharesFullPool() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](3);
        es[0] = PrizeDistribution.Eligible(ALICE,   100);
        es[1] = PrizeDistribution.Eligible(BOB,     100);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 100);
        uint16[] memory s = new uint16[](3);
        s[0] = 6000; s[1] = 3000; s[2] = 1000;
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRanked(es, 999, s);
        // All three voters tied at cutoff → totalWinners = 3, each gets 333.
        assertEq(winners.length, 3, "three winners expected");
        assertEq(amts[0], 333);
        assertEq(amts[1], 333);
        assertEq(amts[2], 333);
    }

    /// @notice Regression — fewer eligibles than splits slots AND all tied.
    function test_topNRanked_fewerEligiblesAllTied() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](2);
        es[0] = PrizeDistribution.Eligible(ALICE, 100);
        es[1] = PrizeDistribution.Eligible(BOB,   100);
        uint16[] memory s = new uint16[](3);
        s[0] = 6000; s[1] = 3000; s[2] = 1000;
        // effectiveN=2, cutoffStart pushed down to 0, tie share = all of splits[0..1] = 9000bps
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRanked(es, 1000, s);
        assertEq(winners.length, 2, "two tied winners");
        assertEq(amts[0], 450); // (1000 * 9000 / 10000) / 2
        assertEq(amts[1], 450);
    }

    function test_topNRanked_invalidSplitsReverts() public {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](3);
        es[0] = PrizeDistribution.Eligible(ALICE, 50);
        es[1] = PrizeDistribution.Eligible(BOB,   30);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 20);
        uint16[] memory s = new uint16[](2);
        s[0] = 5000; s[1] = 4000; // sums to 9000
        vm.expectRevert(PrizeDistribution.InvalidSplits.selector);
        this._callTopNRanked(es, 1000, s);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SINGLE_RANDOM
    // ─────────────────────────────────────────────────────────────────────

    function test_singleRandom_uniformPicksValidIndex() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](4);
        es[0] = PrizeDistribution.Eligible(ALICE,   10);
        es[1] = PrizeDistribution.Eligible(BOB,     20);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 30);
        es[3] = PrizeDistribution.Eligible(DAVE,    40);
        // Random word 12345 % 4 = 1 → BOB
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeSingleRandom(es, 1000, 12345, false);
        assertEq(winners.length, 1);
        assertEq(winners[0], BOB);
        assertEq(amts[0], 1000);
    }

    function test_singleRandom_weightedPicksByScore() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](3);
        es[0] = PrizeDistribution.Eligible(ALICE,   10);
        es[1] = PrizeDistribution.Eligible(BOB,     20);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 70);
        // Random word 50; totalScore=100; target=50 → Charlie (cumulative 10→30→100)
        (address[] memory winners,) =
            PrizeDistribution.distributeSingleRandom(es, 1000, 50, true);
        assertEq(winners[0], CHARLIE);
    }

    function test_singleRandom_weightedZeroScoresFallsBackUniform() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](3);
        es[0] = PrizeDistribution.Eligible(ALICE,   0);
        es[1] = PrizeDistribution.Eligible(BOB,     0);
        es[2] = PrizeDistribution.Eligible(CHARLIE, 0);
        (address[] memory winners,) =
            PrizeDistribution.distributeSingleRandom(es, 1000, 1, true);
        assertEq(winners[0], BOB); // 1 % 3 = 1
    }

    function testFuzz_singleRandom_alwaysPicksFromEligibles(
        uint256 randomWord,
        uint8 n,
        bool weighted
    ) public pure {
        n = uint8(bound(n, 1, 50));
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](n);
        for (uint256 i = 0; i < n; i++) {
            es[i] = PrizeDistribution.Eligible(address(uint160(i + 1)), i + 1);
        }
        (address[] memory winners,) =
            PrizeDistribution.distributeSingleRandom(es, 1000, randomWord, weighted);
        assertEq(winners.length, 1);
        // Verify winner address is one of the eligibles.
        bool found;
        for (uint256 i = 0; i < n; i++) {
            if (es[i].voter == winners[0]) { found = true; break; }
        }
        assertTrue(found);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  TOP_N_RANDOM
    // ─────────────────────────────────────────────────────────────────────

    function test_topNRandom_picksDistinctEligibles() public pure {
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](5);
        for (uint256 i = 0; i < 5; i++) {
            es[i] = PrizeDistribution.Eligible(address(uint160(i + 1)), 100);
        }
        uint16[] memory s = new uint16[](3);
        s[0] = 7500; s[1] = 2000; s[2] = 500;
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRandom(es, 1000, s, 0xDEADBEEF, false);
        assertEq(winners.length, 3);
        // Verify all distinct.
        assertTrue(winners[0] != winners[1]);
        assertTrue(winners[0] != winners[2]);
        assertTrue(winners[1] != winners[2]);
        assertEq(amts[0], 750);
        assertEq(amts[1], 200);
        assertEq(amts[2], 50);
    }

    function test_topNRandom_fewerEligiblesThanSlots() public pure {
        // 2 eligibles, 3 slots: all 2 win, only top 2 splits used (slot[2] becomes dust).
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](2);
        es[0] = PrizeDistribution.Eligible(ALICE, 100);
        es[1] = PrizeDistribution.Eligible(BOB,   100);
        uint16[] memory s = new uint16[](3);
        s[0] = 7500; s[1] = 2000; s[2] = 500;
        (address[] memory winners, uint256[] memory amts) =
            PrizeDistribution.distributeTopNRandom(es, 1000, s, 12345, false);
        assertEq(winners.length, 2);
        // Both win; slot 0 and slot 1 splits paid; slot 2 unpaid (dust).
        assertEq(amts[0], 750);
        assertEq(amts[1], 200);
    }

    function testFuzz_topNRandom_winnersAlwaysDistinct(uint256 randomWord, uint8 n, uint8 k) public pure {
        n = uint8(bound(n, 2, 30));
        k = uint8(bound(k, 1, n)); // never request more than available
        PrizeDistribution.Eligible[] memory es = new PrizeDistribution.Eligible[](n);
        for (uint256 i = 0; i < n; i++) {
            es[i] = PrizeDistribution.Eligible(address(uint160(i + 1)), 100);
        }
        // Build equal-weight splits.
        uint16[] memory s = new uint16[](k);
        uint256 each = 10_000 / k;
        uint256 remainder = 10_000 - (each * k);
        for (uint256 i = 0; i < k; i++) {
            s[i] = uint16(each + (i == 0 ? remainder : 0));
        }
        (address[] memory winners,) =
            PrizeDistribution.distributeTopNRandom(es, 1000, s, randomWord, false);
        assertEq(winners.length, k);

        // O(k²) distinct check — fine for k <= 30.
        for (uint256 i = 0; i < winners.length; i++) {
            for (uint256 j = i + 1; j < winners.length; j++) {
                assertTrue(winners[i] != winners[j], "duplicate winner");
            }
        }
    }
}
