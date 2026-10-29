// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/**
 * @title ContestV2TypesTest
 * @notice Tests for all 5 contest types (VOTE, RANK, RATE, PREDICT, PAIRWISE)
 *         covering vote processing, winner determination, scoring, and full lifecycle.
 */
contract ContestV2TypesTest is ContestV2TestBase {

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Run a full contest lifecycle with heterogeneous votes.
    ///      Each element of `voteDatas` corresponds to `voters[i]`.
    function _runContest(
        address contestAddr,
        address[] memory voters,
        bytes[] memory voteDatas
    ) internal {
        bytes32[] memory salts = new bytes32[](voters.length);

        // Deposit + Commit
        for (uint256 i = 0; i < voters.length; i++) {
            _deposit(voters[i], contestAddr);
            salts[i] = keccak256(abi.encodePacked("salt", voters[i], i));
            _commitVote(voters[i], contestAddr, voteDatas[i], salts[i]);
        }

        // Advance to REVEAL_OPEN
        _advancePastLock(contestAddr);

        // Reveal
        for (uint256 i = 0; i < voters.length; i++) {
            _revealVote(voters[i], contestAddr, voteDatas[i], salts[i]);
        }

        // Advance past reveal and resolve
        _advancePastReveal(contestAddr);
        vm.prank(creator);
        ContestV2(contestAddr).resolveContest();
    }

    /// @dev Convenience: build address[] from 2 addresses.
    function _arr2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr3(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _arr4(address a, address b, address c, address d) internal pure returns (address[] memory r) {
        r = new address[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _arr5(address a, address b, address c, address d, address e_) internal pure returns (address[] memory r) {
        r = new address[](5);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
        r[4] = e_;
    }

    function _bytes2(bytes memory a, bytes memory b) internal pure returns (bytes[] memory r) {
        r = new bytes[](2);
        r[0] = a;
        r[1] = b;
    }

    function _bytes3(bytes memory a, bytes memory b, bytes memory c) internal pure returns (bytes[] memory r) {
        r = new bytes[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _bytes4(bytes memory a, bytes memory b, bytes memory c, bytes memory d) internal pure returns (bytes[] memory r) {
        r = new bytes[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _bytes5(bytes memory a, bytes memory b, bytes memory c, bytes memory d, bytes memory e_) internal pure returns (bytes[] memory r) {
        r = new bytes[](5);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
        r[4] = e_;
    }

    /// @dev Build a bytes32[] ranking from 4 options in given order.
    function _ranking4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _ranking2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](2);
        r[0] = a;
        r[1] = b;
    }

    /// @dev Build (options, ratings) arrays for RATE votes.
    function _rateArrays4(
        uint256 rA, uint256 rB, uint256 rC, uint256 rD
    ) internal view returns (bytes32[] memory opts, uint256[] memory ratings) {
        opts = new bytes32[](4);
        opts[0] = OPT_A;
        opts[1] = OPT_B;
        opts[2] = OPT_C;
        opts[3] = OPT_D;
        ratings = new uint256[](4);
        ratings[0] = rA;
        ratings[1] = rB;
        ratings[2] = rC;
        ratings[3] = rD;
    }

    /// @dev Build pairwise choices array.
    function _pairwise3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _pairwise1(bytes32 a) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = a;
    }

    // =====================================================================
    //  VOTE TYPE TESTS
    // =====================================================================

    function test_vote_simplePlurality() public {
        // 3 vote A, 2 vote B -> A wins
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes memory vB = _makeVoteData_VOTE(OPT_B);

        _runContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(vA, vA, vA, vB, vB));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_A, "OPT_A should win");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 3);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 2);
    }

    function test_vote_unanimous() public {
        // All vote same option
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);

        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(vA, vA, vA));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_A);
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 3);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 0);
    }

    function test_vote_tiedVote_firstOptionWins() public {
        // A gets 1 vote, B gets 1 vote -> tie. Bubble sort is stable for equal
        // scores, so the first option in the options array (OPT_A) keeps position 0.
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes memory vB = _makeVoteData_VOTE(OPT_B);

        _runContest(c, _arr2(alice, bob), _bytes2(vA, vB));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        // Tied scores: bubble sort only swaps when scores[j] > scores[i],
        // so original order preserved -> OPT_A stays at index 0.
        assertEq(res.winningOption, OPT_A, "First option wins tie");
    }

    function test_vote_singleVoter() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        bytes memory vB = _makeVoteData_VOTE(OPT_B);

        // Need at least 2 participants for quorum. Both deposit, but use
        // minParticipants=2 from defaults. Both must reveal.
        _runContest(c, _arr2(alice, bob), _bytes2(vB, vB));

        assertEq(ContestV2(c).getResults().winningOption, OPT_B);
    }

    function test_vote_eachVoterDifferentOption() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _runContest(c,
            _arr4(alice, bob, charlie, dave),
            _bytes4(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            )
        );

        assertEq(ContestV2(c).getOptionVotes(OPT_A), 1);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 1);
        assertEq(ContestV2(c).getOptionVotes(OPT_C), 1);
        assertEq(ContestV2(c).getOptionVotes(OPT_D), 1);
    }

    function test_vote_fullLifecycleWithPrincipalWithdraw() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);

        _runContest(c, _arr2(alice, bob), _bytes2(vA, vA));

        assertEq(_getState(c), STATE_FINALIZED);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        uint256 balAfter = usdc.balanceOf(alice);
        assertEq(balAfter - balBefore, DEFAULT_DEPOSIT_AMOUNT, "Principal returned");
    }

    function test_vote_winnerGetsReward_loserGetsNothing() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice votes A (will win), Bob votes B (will lose)
        _runContest(c, _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_B)));

        // In mock vault with no yield, rewards pool is 0. Check scores instead.
        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);
        assertEq(pAlice.score, 100, "Winner score = 100");
        assertEq(pBob.score, 0, "Loser score = 0");
    }

    // =====================================================================
    //  RANK TYPE TESTS
    // =====================================================================

    function test_rank_bordaCountAccumulated() public {
        // With 4 options ranked [A,B,C,D], Borda points: A=4, B=3, C=2, D=1
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);
        bytes memory ranking = _makeVoteData_RANK(_ranking4(OPT_A, OPT_B, OPT_C, OPT_D));

        _runContest(c, _arr2(alice, bob), _bytes2(ranking, ranking));

        // Each voter gives A=4, B=3, C=2, D=1. Two voters -> A=8, B=6, C=4, D=2
        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_A, "A wins Borda");
        // optionTotalScore tracks cumulative Borda points
        assertEq(ContestV2(c).optionTotalScore(OPT_A), 8);
        assertEq(ContestV2(c).optionTotalScore(OPT_B), 6);
        assertEq(ContestV2(c).optionTotalScore(OPT_C), 4);
        assertEq(ContestV2(c).optionTotalScore(OPT_D), 2);
    }

    function test_rank_threeVotersDifferentRankings() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);

        // Alice: A>B>C>D  -> A=4,B=3,C=2,D=1
        // Bob:   B>A>D>C  -> B=4,A=3,D=2,C=1
        // Charlie: A>C>B>D -> A=4,C=3,B=2,D=1
        // Total: A=11, B=9, C=6, D=4
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_RANK(_ranking4(OPT_A, OPT_B, OPT_C, OPT_D)),
                _makeVoteData_RANK(_ranking4(OPT_B, OPT_A, OPT_D, OPT_C)),
                _makeVoteData_RANK(_ranking4(OPT_A, OPT_C, OPT_B, OPT_D))
            )
        );

        assertEq(ContestV2(c).optionTotalScore(OPT_A), 11);
        assertEq(ContestV2(c).optionTotalScore(OPT_B), 9);
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
    }

    function test_rank_unanimousRanking() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);
        bytes memory ranking = _makeVoteData_RANK(_ranking4(OPT_C, OPT_A, OPT_D, OPT_B));

        _runContest(c, _arr2(alice, bob), _bytes2(ranking, ranking));

        assertEq(ContestV2(c).getResults().winningOption, OPT_C);
        // C=4*2=8, A=3*2=6, D=2*2=4, B=1*2=2
        assertEq(ContestV2(c).optionTotalScore(OPT_C), 8);
    }

    function test_rank_twoOptionsOnly() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);
        // Ranking must cover all 4 options. Test that swapping top 2 creates a tie.
        // Alice: A>B>C>D -> A=4, B=3, C=2, D=1
        // Bob:   B>A>C>D -> B=4, A=3, C=2, D=1
        // Total: A=7, B=7, C=4, D=2 -> tie between A and B
        bytes memory r1 = _makeVoteData_RANK(_ranking4(OPT_A, OPT_B, OPT_C, OPT_D));
        bytes memory r2 = _makeVoteData_RANK(_ranking4(OPT_B, OPT_A, OPT_C, OPT_D));

        _runContest(c, _arr2(alice, bob), _bytes2(r1, r2));

        // A: 4+3=7, B: 3+4=7 -> tie
        assertEq(ContestV2(c).optionTotalScore(OPT_A), 7);
        assertEq(ContestV2(c).optionTotalScore(OPT_B), 7);
    }

    function test_rank_fullLifecycleRankedOptions() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);
        bytes memory ranking = _makeVoteData_RANK(_ranking4(OPT_D, OPT_C, OPT_B, OPT_A));

        _runContest(c, _arr2(alice, bob), _bytes2(ranking, ranking));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.rankedOptions[0], OPT_D, "D first");
        assertEq(res.rankedOptions[1], OPT_C, "C second");
        assertEq(res.rankedOptions[2], OPT_B, "B third");
        assertEq(res.rankedOptions[3], OPT_A, "A fourth");
        assertTrue(res.isResolved);
    }

    function test_rank_perfectRankingMatchGetsScore100() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);
        // Both vote identically -> result ranking = their ranking -> perfect Spearman
        bytes memory ranking = _makeVoteData_RANK(_ranking4(OPT_A, OPT_B, OPT_C, OPT_D));

        _runContest(c, _arr2(alice, bob), _bytes2(ranking, ranking));

        ContestV2.Participant memory p = ContestV2(c).getParticipant(alice);
        assertEq(p.score, 100, "Perfect ranking match = 100");
    }

    function test_rank_voterScoreSpearmanCorrelation() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_VOTER_REWARDS);

        // Alice matches consensus, Bob reverses it
        // Alice: A>B>C>D, Bob: A>B>C>D (same as Alice for this test, both get 100)
        // To test non-perfect: Alice A>B>C>D, Bob D>C>B>A
        // Result: A=4+1=5, B=3+2=5, C=2+3=5, D=1+4=5 -> all tied, original order preserved: A,B,C,D
        // Alice ranked A,B,C,D -> matches result -> score 100
        // Bob ranked D,C,B,A -> fully reversed
        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RANK(_ranking4(OPT_A, OPT_B, OPT_C, OPT_D)),
                _makeVoteData_RANK(_ranking4(OPT_D, OPT_C, OPT_B, OPT_A))
            )
        );

        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);
        // Alice matches result perfectly
        assertEq(pAlice.score, 100, "Alice perfect match");
        // Bob fully reversed -> low score
        assertTrue(pBob.score < pAlice.score, "Bob lower than Alice");
    }

    // =====================================================================
    //  RATE TYPE TESTS
    // =====================================================================

    function test_rate_averageRatingCalculated() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        // Alice rates: A=10, B=5, C=3, D=1
        // Bob rates:   A=8,  B=7, C=3, D=1
        // Averages:    A=9,  B=6, C=3, D=1 -> A wins
        (bytes32[] memory opts1, uint256[] memory r1) = _rateArrays4(10, 5, 3, 1);
        (bytes32[] memory opts2, uint256[] memory r2) = _rateArrays4(8, 7, 3, 1);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(opts1, r1),
                _makeVoteData_RATE(opts2, r2)
            )
        );

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_A, "A has highest average");
    }

    function test_rate_multipleRatersVaryingRatings() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        // Alice: A=2, B=8, C=5, D=5
        // Bob:   A=4, B=10, C=3, D=1
        // Charlie: A=3, B=6, C=7, D=2
        // Averages: A=3, B=8, C=5, D=2.67 -> B wins
        (bytes32[] memory o1, uint256[] memory r1) = _rateArrays4(2, 8, 5, 5);
        (bytes32[] memory o2, uint256[] memory r2) = _rateArrays4(4, 10, 3, 1);
        (bytes32[] memory o3, uint256[] memory r3) = _rateArrays4(3, 6, 7, 2);

        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_RATE(o1, r1),
                _makeVoteData_RATE(o2, r2),
                _makeVoteData_RATE(o3, r3)
            )
        );

        assertEq(ContestV2(c).getResults().winningOption, OPT_B, "B highest avg");
    }

    function test_rate_allSameRatings_firstOptionWins() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        // Both rate everything the same -> all averages equal -> first in options wins
        (bytes32[] memory o1, uint256[] memory r1) = _rateArrays4(5, 5, 5, 5);
        (bytes32[] memory o2, uint256[] memory r2) = _rateArrays4(5, 5, 5, 5);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(o1, r1),
                _makeVoteData_RATE(o2, r2)
            )
        );

        // All averages = 5, tie -> first option in array wins
        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "First option wins tie");
    }

    function test_rate_singleRater() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        // Single rater (need 2 for quorum). Both rate same.
        (bytes32[] memory o1, uint256[] memory r1) = _rateArrays4(1, 9, 3, 7);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(o1, r1),
                _makeVoteData_RATE(o1, r1)
            )
        );

        // B has highest rating of 9
        assertEq(ContestV2(c).getResults().winningOption, OPT_B);
    }

    function test_rate_fullLifecycleCorrectWinner() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        (bytes32[] memory o1, uint256[] memory r1) = _rateArrays4(3, 2, 10, 1);
        (bytes32[] memory o2, uint256[] memory r2) = _rateArrays4(1, 4, 8, 2);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(o1, r1),
                _makeVoteData_RATE(o2, r2)
            )
        );

        // Avg: A=2, B=3, C=9, D=1 -> C wins
        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_C, "C highest avg");
        assertTrue(res.isResolved);
        assertEq(_getState(c), STATE_FINALIZED);
    }

    function test_rate_voterScoreCorrelation() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        // Both rate identically -> each voter's ratings match the average perfectly
        (bytes32[] memory o1, uint256[] memory r1) = _rateArrays4(10, 5, 3, 1);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(o1, r1),
                _makeVoteData_RATE(o1, r1)
            )
        );

        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        // Perfect match with average -> score should be 100
        assertEq(pAlice.score, 100, "Perfect rating correlation = 100");
    }

    function test_rate_scoresFrom0to100() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_VOTER_REWARDS);

        // Alice rates close to avg, Bob rates very differently
        (bytes32[] memory o1, uint256[] memory r1) = _rateArrays4(10, 1, 1, 1);
        (bytes32[] memory o2, uint256[] memory r2) = _rateArrays4(1, 10, 10, 10);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(o1, r1),
                _makeVoteData_RATE(o2, r2)
            )
        );

        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);

        // Both should have scores in [0, 100]
        assertTrue(pAlice.score <= 100, "Alice score <= 100");
        assertTrue(pBob.score <= 100, "Bob score <= 100");
    }

    // =====================================================================
    //  PREDICT TYPE TESTS
    // =====================================================================

    function test_predict_confidenceStoredInScore() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes memory v1 = _makeVoteData_PREDICT(OPT_A, 80);
        bytes memory v2 = _makeVoteData_PREDICT(OPT_A, 50);

        // Deposit + commit (need to check score after reveal, before resolve)
        bytes32 s1 = keccak256("s1");
        bytes32 s2 = keccak256("s2");

        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, v1, s1);
        _commitVote(bob, c, v2, s2);

        _advancePastLock(c);

        _revealVote(alice, c, v1, s1);
        _revealVote(bob, c, v2, s2);

        // After reveal but before resolve, score holds confidence
        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        assertEq(pAlice.score, 80, "Alice confidence = 80");
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);
        assertEq(pBob.score, 50, "Bob confidence = 50");
    }

    function test_predict_majorityPredictionWins() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // 2 predict A, 1 predicts B -> A wins
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PREDICT(OPT_A, 70),
                _makeVoteData_PREDICT(OPT_A, 60),
                _makeVoteData_PREDICT(OPT_B, 90)
            )
        );

        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 2);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 1);
    }

    function test_predict_confidenceMultiplierAffectsScore() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice: correct (A), confidence 80
        // Bob: correct (A), confidence 10
        // With confidenceMultiplier = 5000 (50%):
        //   Alice: 100 * (10000 + 80*5000/100) / 10000 = 100 * (10000+4000)/10000 = 140
        //   Bob:   100 * (10000 + 10*5000/100) / 10000 = 100 * (10000+500)/10000 = 105
        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PREDICT(OPT_A, 80),
                _makeVoteData_PREDICT(OPT_A, 10)
            )
        );

        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);
        assertTrue(pAlice.score > pBob.score, "Higher confidence -> higher score");
        assertEq(pAlice.score, 140, "Alice boosted score");
        assertEq(pBob.score, 105, "Bob boosted score");
    }

    function test_predict_fullLifecycle() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PREDICT(OPT_C, 50),
                _makeVoteData_PREDICT(OPT_C, 75)
            )
        );

        assertEq(_getState(c), STATE_FINALIZED);
        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertTrue(res.isResolved);
        assertEq(res.winningOption, OPT_C);
    }

    function test_predict_correctOutcomeGetsScore100Plus() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice predicts correct (A), Bob predicts wrong (B)
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PREDICT(OPT_A, 50),
                _makeVoteData_PREDICT(OPT_B, 50),
                _makeVoteData_PREDICT(OPT_A, 50)
            )
        );

        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        // Correct with confidence 50: 100 * (10000 + 50*5000/100) / 10000 = 100 * 12500/10000 = 125
        assertTrue(pAlice.score >= 100, "Correct prediction >= 100");
    }

    function test_predict_wrongPredictionGetsScore0() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // A wins (2 votes). Bob predicts B.
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PREDICT(OPT_A, 90),
                _makeVoteData_PREDICT(OPT_B, 90),
                _makeVoteData_PREDICT(OPT_A, 80)
            )
        );

        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);
        assertEq(pBob.score, 0, "Wrong prediction = 0");
    }

    function test_predict_highConfidenceCorrectGetsBonusScore() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice high confidence correct, Charlie low confidence correct
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PREDICT(OPT_A, 100),
                _makeVoteData_PREDICT(OPT_A, 1),
                _makeVoteData_PREDICT(OPT_A, 50)
            )
        );

        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);

        // Alice confidence=100: 100*(10000+100*50)/10000 = 100*15000/10000 = 150
        // Bob confidence=1:     100*(10000+1*50)/10000   = 100*10050/10000 = 100
        assertEq(pAlice.score, 150, "High confidence bonus");
        assertTrue(pAlice.score > pBob.score, "High confidence > low confidence");
    }

    // =====================================================================
    //  PAIRWISE TYPE TESTS
    // =====================================================================

    function test_pairwise_choicesTallied() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice chooses A, B, A in 3 pairwise matchups
        // Bob chooses A, A, C
        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PAIRWISE(_pairwise3(OPT_A, OPT_B, OPT_A)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_A, OPT_A, OPT_C))
            )
        );

        // A: 2+2=4, B: 1+0=1, C: 0+1=1
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 4);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 1);
        assertEq(ContestV2(c).getOptionVotes(OPT_C), 1);
    }

    function test_pairwise_multipleVotersDifferentChoices() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // 3 matchups each. Alice prefers B, Bob prefers C, Charlie prefers B
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PAIRWISE(_pairwise3(OPT_B, OPT_B, OPT_B)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_C, OPT_C, OPT_C)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_B, OPT_B, OPT_A))
            )
        );

        // B: 3+0+2=5, C: 0+3+0=3, A: 0+0+1=1
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 5);
        assertEq(ContestV2(c).getOptionVotes(OPT_C), 3);
        assertEq(ContestV2(c).getResults().winningOption, OPT_B);
    }

    function test_pairwise_mostChosenOptionWins() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PAIRWISE(_pairwise3(OPT_D, OPT_D, OPT_D)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_D, OPT_A, OPT_A))
            )
        );

        // D: 3+1=4, A: 0+2=2
        assertEq(ContestV2(c).getResults().winningOption, OPT_D, "D wins with most choices");
    }

    function test_pairwise_fullLifecycle() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PAIRWISE(_pairwise3(OPT_A, OPT_B, OPT_C)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_B, OPT_B, OPT_A))
            )
        );

        assertEq(_getState(c), STATE_FINALIZED);
        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertTrue(res.isResolved);
        // A: 1+1=2, B: 1+2=3, C: 1+0=1 -> B wins
        assertEq(res.winningOption, OPT_B);
    }

    function test_pairwise_unanimousAllChooseSame() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Everyone picks C in all matchups
        _runContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PAIRWISE(_pairwise3(OPT_C, OPT_C, OPT_C)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_C, OPT_C, OPT_C)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_C, OPT_C, OPT_C))
            )
        );

        assertEq(ContestV2(c).getOptionVotes(OPT_C), 9);
        assertEq(ContestV2(c).getResults().winningOption, OPT_C);
    }

    function test_pairwise_singleChoice() public {
        // Each voter makes only 1 pairwise choice
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PAIRWISE(_pairwise1(OPT_A)),
                _makeVoteData_PAIRWISE(_pairwise1(OPT_B))
            )
        );

        assertEq(ContestV2(c).getOptionVotes(OPT_A), 1);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 1);
    }

    function test_pairwise_verifyOptionVotesMatchTotalChoices() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice: 3 choices, Bob: 3 choices -> total 6 individual choice events
        _runContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PAIRWISE(_pairwise3(OPT_A, OPT_B, OPT_C)),
                _makeVoteData_PAIRWISE(_pairwise3(OPT_A, OPT_D, OPT_D))
            )
        );

        uint256 totalVotes = ContestV2(c).getOptionVotes(OPT_A)
            + ContestV2(c).getOptionVotes(OPT_B)
            + ContestV2(c).getOptionVotes(OPT_C)
            + ContestV2(c).getOptionVotes(OPT_D);

        // 6 total individual choices across both voters
        assertEq(totalVotes, 6, "Total choices = 6");
    }
}
