// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestScoring.sol";

/// @title ContestScoring Library Tests
/// @notice Tests for the extracted scoring functions used by ContestV2
contract ContestScoringTest is Test {

    // ─── calculateRankingScore Tests ─────────────────────────────────────────────

    function test_rankingScore_perfectMatch() public pure {
        bytes32[] memory voter = new bytes32[](3);
        bytes32[] memory actual = new bytes32[](3);
        voter[0] = bytes32("A"); voter[1] = bytes32("B"); voter[2] = bytes32("C");
        actual[0] = bytes32("A"); actual[1] = bytes32("B"); actual[2] = bytes32("C");

        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        assertEq(score, 100, "Perfect match should score 100");
    }

    function test_rankingScore_completelyReversed() public pure {
        bytes32[] memory voter = new bytes32[](3);
        bytes32[] memory actual = new bytes32[](3);
        voter[0] = bytes32("C"); voter[1] = bytes32("B"); voter[2] = bytes32("A");
        actual[0] = bytes32("A"); actual[1] = bytes32("B"); actual[2] = bytes32("C");

        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        // Completely reversed ranking should score 0
        assertEq(score, 0, "Reversed ranking should score 0");
    }

    function test_rankingScore_partialMatch() public pure {
        bytes32[] memory voter = new bytes32[](4);
        bytes32[] memory actual = new bytes32[](4);
        voter[0] = bytes32("A"); voter[1] = bytes32("C"); voter[2] = bytes32("B"); voter[3] = bytes32("D");
        actual[0] = bytes32("A"); actual[1] = bytes32("B"); actual[2] = bytes32("C"); actual[3] = bytes32("D");

        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        // Should be between 0 and 100
        assertGt(score, 0, "Partial match should score > 0");
        assertLt(score, 100, "Partial match should score < 100");
    }

    function test_rankingScore_singleItem() public pure {
        bytes32[] memory voter = new bytes32[](1);
        bytes32[] memory actual = new bytes32[](1);
        voter[0] = bytes32("A");
        actual[0] = bytes32("A");

        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        assertEq(score, 0, "Single item ranking returns 0 (n < 2)");
    }

    function test_rankingScore_emptyArrays() public pure {
        bytes32[] memory voter = new bytes32[](0);
        bytes32[] memory actual = new bytes32[](0);

        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        assertEq(score, 0, "Empty arrays should score 0");
    }

    function test_rankingScore_differentLengths() public pure {
        bytes32[] memory voter = new bytes32[](3);
        bytes32[] memory actual = new bytes32[](2);
        voter[0] = bytes32("A"); voter[1] = bytes32("B"); voter[2] = bytes32("C");
        actual[0] = bytes32("A"); actual[1] = bytes32("B");

        // Should use min(voter.length, actual.length)
        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        assertEq(score, 100, "Matching subset should score 100");
    }

    // ─── findRank Tests ──────────────────────────────────────────────────────────

    function test_findRank_found() public pure {
        bytes32[] memory ranking = new bytes32[](3);
        ranking[0] = bytes32("A"); ranking[1] = bytes32("B"); ranking[2] = bytes32("C");

        assertEq(ContestScoring.findRank(ranking, bytes32("A")), 0);
        assertEq(ContestScoring.findRank(ranking, bytes32("B")), 1);
        assertEq(ContestScoring.findRank(ranking, bytes32("C")), 2);
    }

    function test_findRank_notFound() public pure {
        bytes32[] memory ranking = new bytes32[](3);
        ranking[0] = bytes32("A"); ranking[1] = bytes32("B"); ranking[2] = bytes32("C");

        // Should return ranking.length when not found
        assertEq(ContestScoring.findRank(ranking, bytes32("D")), 3);
    }

    function test_findRank_emptyArray() public pure {
        bytes32[] memory ranking = new bytes32[](0);
        assertEq(ContestScoring.findRank(ranking, bytes32("A")), 0);
    }

    // ─── Fuzz Tests ──────────────────────────────────────────────────────────────

    function testFuzz_rankingScore_bounded(uint8 n) public pure {
        vm.assume(n >= 2 && n <= 20);

        bytes32[] memory ranking = new bytes32[](n);
        for (uint8 i = 0; i < n; i++) {
            ranking[i] = bytes32(uint256(i));
        }

        uint256 score = ContestScoring.calculateRankingScore(ranking, ranking);
        assertEq(score, 100, "Identical rankings should always score 100");
    }

    function testFuzz_rankingScore_neverExceeds100(bytes32 a, bytes32 b, bytes32 c) public pure {
        bytes32[] memory voter = new bytes32[](3);
        bytes32[] memory actual = new bytes32[](3);
        voter[0] = a; voter[1] = b; voter[2] = c;
        actual[0] = a; actual[1] = c; actual[2] = b;

        uint256 score = ContestScoring.calculateRankingScore(voter, actual);
        assertLe(score, 100, "Score should never exceed 100");
    }
}
