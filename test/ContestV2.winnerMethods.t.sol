// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/**
 * @title ContestV2WinnerMethodsTest
 * @notice Tests for the 5 untested winner determination methods:
 *         MAJORITY, RANKED_CHOICE, ORACLE, THRESHOLD, CONSENSUS.
 *
 * @dev The on-chain _determineWinners() uses a single scoring + sort algorithm
 *      for all methods. These tests verify that contests configured with each
 *      method complete their lifecycle correctly, that vote tallies are accurate,
 *      and that oracle-specific access control works as expected.
 */
contract ContestV2WinnerMethodsTest is ContestV2TestBase {

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Run a full VOTE-type contest lifecycle with heterogeneous votes.
    function _runVoteContest(
        address contestAddr,
        address[] memory voters,
        bytes[] memory voteDatas
    ) internal {
        bytes32[] memory salts = new bytes32[](voters.length);

        for (uint256 i = 0; i < voters.length; i++) {
            _deposit(voters[i], contestAddr);
            salts[i] = keccak256(abi.encodePacked("salt", voters[i], i));
            _commitVote(voters[i], contestAddr, voteDatas[i], salts[i]);
        }

        _advancePastLock(contestAddr);

        for (uint256 i = 0; i < voters.length; i++) {
            _revealVote(voters[i], contestAddr, voteDatas[i], salts[i]);
        }

        _advancePastReveal(contestAddr);
        vm.prank(creator);
        ContestV2(contestAddr).resolveContest();
    }

    /// @dev Create a contest with oracle support enabled.
    function _createOracleContest(
        uint8 contestType,
        uint8 winnerMethod,
        uint8 prizeModel,
        address oracleAddr
    ) internal returns (address contestAddr) {
        uint256 t = block.timestamp;
        uint256 nonce = _contestNonce++;

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           DEFAULT_DEPOSIT_AMOUNT,
            minParticipants:         DEFAULT_MIN_PARTICIPANTS,
            maxParticipants:         DEFAULT_MAX_PARTICIPANTS,
            depositStart:            t,
            depositEnd:              t + DEFAULT_DEPOSIT_DURATION,
            lockEnd:                 t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION,
            revealEnd:               t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION + DEFAULT_REVEAL_DURATION,
            contestType:             ContestV2.ContestType(contestType),
            winnerDetermination:     ContestV2.WinnerDetermination(winnerMethod),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        DEFAULT_QUORUM_PERCENTAGE,
            requiresOracle:          true,
            metadataHash:            keccak256(abi.encodePacked("oracle-contest-", t, nonce)),
            metadataUri:             "ipfs://oracle-test"
        });
        ContestV2.PrizeConfig memory prizeCfg = _defaultPrizeConfigForModel(ContestV2.PrizeModel(prizeModel));

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0,
            topPercentile:        2500,
            confidenceMultiplier: 5000,
            earlyVoterBonus:      0
        });

        ContestV2.SubmissionConfig memory subConfig = ContestV2.SubmissionConfig({
            enabled:                 false,
            submissionStart:         0,
            submissionEnd:           0,
            maxPerUser:              0,
            requiresModeration:      false,
            paymentModel:            ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0,
            minSubmissions:          0,
            maxTotalSubmissions:     0
        });

        bytes32[] memory opts = _defaultOptions();

        vm.prank(creator);
        (, contestAddr) = factory.createCustomContest(
            config,
            prizeCfg,
            scoring,
            subConfig,
            oracleAddr,
            opts,
            0
        );

        vm.label(contestAddr, "OracleContest");
    }

    // --- Array helpers ---

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

    // =====================================================================
    //  MAJORITY TESTS (WinnerDetermination.MAJORITY)
    // =====================================================================

    /// @notice A candidate with >50% of votes wins under MAJORITY.
    function test_majority_clearMajorityWins() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes memory vB = _makeVoteData_VOTE(OPT_B);

        // 3 vote A, 2 vote B -> A has 60% majority
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(vA, vA, vA, vB, vB));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_A, "A should win with >50%");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 3);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 2);
    }

    /// @notice When no candidate gets >50%, the highest vote count still wins
    ///         (on-chain resolution uses plurality sorting regardless of method).
    function test_majority_noMajorityHighestVotesWins() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        // A=2, B=1, C=1, D=1 -> no majority (40%), but A highest
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            ));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.winningOption, OPT_A, "A wins with most votes even without majority");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 2);
    }

    /// @notice Exact 50% is not a majority (need >50%). Tests the boundary.
    function test_majority_exact50PercentEdgeCase() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        // A=2, B=2 -> 50% each, tie -> first option in array wins
        _runVoteContest(c, _arr4(alice, bob, charlie, dave),
            _bytes4(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B)
            ));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        // Tied -> bubble sort preserves original order -> OPT_A at index 0
        assertEq(res.winningOption, OPT_A, "Tie at 50% -> first option wins");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 2);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 2);
    }

    /// @notice Multiple candidates with one clear majority among many.
    function test_majority_multipleCandidatesClearMajority() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        // B=3, A=1, C=1 -> B has 60% majority
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_B, "B wins with 60% majority");
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 3);
    }

    /// @notice Unanimous vote is a strong majority.
    function test_majority_unanimousVote() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_C)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_C, "Unanimous -> C wins");
        assertEq(ContestV2(c).getOptionVotes(OPT_C), 3);
    }

    /// @notice With 2 voters, 1 vote each is a tie; verify resolution.
    function test_majority_twoVotersTied() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ));

        // Tied: bubble sort preserves order -> OPT_A
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
    }

    /// @notice Full lifecycle finalizes correctly with MAJORITY method.
    function test_majority_fullLifecycleFinalizesCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_D),
                _makeVoteData_VOTE(OPT_D)
            ));

        assertEq(_getState(c), STATE_FINALIZED);
        assertTrue(ContestV2(c).getResults().isResolved);
    }

    /// @notice Winner voters score 100, losers score 0 under MAJORITY.
    function test_majority_winnerVoterGetsScore100() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ));

        assertEq(ContestV2(c).getParticipant(alice).score, 100, "Winner voter gets 100");
        assertEq(ContestV2(c).getParticipant(charlie).score, 0, "Loser voter gets 0");
    }

    /// @notice Ranked options are sorted by vote count under MAJORITY.
    function test_majority_rankedOptionsSortedCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        // A=3, B=1, C=1 -> ranked: A, B (or C), C (or B)
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C)
            ));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.rankedOptions[0], OPT_A, "A should be first");
        // B and C tied at 1, D at 0
        assertTrue(res.optionScores[0] > res.optionScores[1], "First score > second score");
    }

    /// @notice Principal withdrawal works after MAJORITY contest.
    function test_majority_principalWithdrawalAfterFinalization() public {
        address c = _createContest(TYPE_VOTE, WINNER_MAJORITY, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ));

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - balBefore, DEFAULT_DEPOSIT_AMOUNT);
    }

    // =====================================================================
    //  RANKED_CHOICE TESTS (WinnerDetermination.RANKED_CHOICE)
    // =====================================================================

    /// @notice Basic ranked choice with VOTE type: highest votes wins.
    function test_rankedChoice_basicFirstRoundWinner() public {
        address c = _createContest(TYPE_VOTE, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        // A=3 out of 5 -> >50% on first round
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "A wins first round");
    }

    /// @notice With RANK type, Borda scores determine winner under RANKED_CHOICE.
    function test_rankedChoice_bordaScoreWithRankType() public {
        address c = _createContest(TYPE_RANK, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        bytes32[] memory ranking = new bytes32[](4);
        ranking[0] = OPT_B;
        ranking[1] = OPT_A;
        ranking[2] = OPT_C;
        ranking[3] = OPT_D;

        bytes memory rankData = _makeVoteData_RANK(ranking);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(rankData, rankData));

        // B=4*2=8, A=3*2=6, C=2*2=4, D=1*2=2
        assertEq(ContestV2(c).getResults().winningOption, OPT_B, "B wins Borda under RCV");
        assertEq(ContestV2(c).optionTotalScore(OPT_B), 8);
    }

    /// @notice Multi-voter with varied rankings under RANKED_CHOICE.
    function test_rankedChoice_multiVoterVariedRankings() public {
        address c = _createContest(TYPE_RANK, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        bytes32[] memory r1 = new bytes32[](4);
        r1[0] = OPT_A; r1[1] = OPT_B; r1[2] = OPT_C; r1[3] = OPT_D;

        bytes32[] memory r2 = new bytes32[](4);
        r2[0] = OPT_C; r2[1] = OPT_A; r2[2] = OPT_B; r2[3] = OPT_D;

        bytes32[] memory r3 = new bytes32[](4);
        r3[0] = OPT_A; r3[1] = OPT_C; r3[2] = OPT_D; r3[3] = OPT_B;

        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_RANK(r1),
                _makeVoteData_RANK(r2),
                _makeVoteData_RANK(r3)
            ));

        // A: 4+3+4=11, B: 3+2+1=6, C: 2+4+3=9, D: 1+1+2=4
        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "A wins with 11 Borda points");
        assertEq(ContestV2(c).optionTotalScore(OPT_A), 11);
        assertEq(ContestV2(c).optionTotalScore(OPT_C), 9);
    }

    /// @notice Tie in Borda scores under RANKED_CHOICE -> first option wins.
    function test_rankedChoice_tiedBordaScoresFirstOptionWins() public {
        address c = _createContest(TYPE_RANK, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        // Opposite rankings -> all options tied
        bytes32[] memory r1 = new bytes32[](4);
        r1[0] = OPT_A; r1[1] = OPT_B; r1[2] = OPT_C; r1[3] = OPT_D;

        bytes32[] memory r2 = new bytes32[](4);
        r2[0] = OPT_D; r2[1] = OPT_C; r2[2] = OPT_B; r2[3] = OPT_A;

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RANK(r1),
                _makeVoteData_RANK(r2)
            ));

        // All options: 4+1=5 or 3+2=5 -> all tied at 5
        // Bubble sort preserves original order -> OPT_A
        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "Tie -> first option wins");
    }

    /// @notice Single plurality vote wins under RANKED_CHOICE with VOTE type.
    function test_rankedChoice_singlePluralityVote() public {
        address c = _createContest(TYPE_VOTE, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_D),
                _makeVoteData_VOTE(OPT_D)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_D, "D wins unanimously");
    }

    /// @notice Full lifecycle with RANKED_CHOICE finalized correctly.
    function test_rankedChoice_fullLifecycleFinalized() public {
        address c = _createContest(TYPE_VOTE, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B)
            ));

        assertEq(_getState(c), STATE_FINALIZED);
        assertTrue(ContestV2(c).getResults().isResolved);
    }

    /// @notice Voter scoring works correctly under RANKED_CHOICE with VOTE type.
    function test_rankedChoice_voterScoreCorrectForWinnerLoser() public {
        address c = _createContest(TYPE_VOTE, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_C)
            ));

        assertEq(ContestV2(c).getParticipant(alice).score, 100, "Winner voter = 100");
        assertEq(ContestV2(c).getParticipant(charlie).score, 0, "Loser voter = 0");
    }

    /// @notice Voter ranking score (Spearman) under RANKED_CHOICE with RANK type.
    function test_rankedChoice_spearmanScoreForPerfectRanking() public {
        address c = _createContest(TYPE_RANK, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        bytes32[] memory ranking = new bytes32[](4);
        ranking[0] = OPT_A; ranking[1] = OPT_B; ranking[2] = OPT_C; ranking[3] = OPT_D;

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RANK(ranking),
                _makeVoteData_RANK(ranking)
            ));

        assertEq(ContestV2(c).getParticipant(alice).score, 100, "Perfect ranking match = 100");
    }

    /// @notice Three-way split with one plurality winner under RANKED_CHOICE.
    function test_rankedChoice_threeWaySplitPluralityWins() public {
        address c = _createContest(TYPE_VOTE, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        // A=2, B=1, C=1, D=1
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "A wins plurality");
    }

    /// @notice Principal withdrawal after RANKED_CHOICE contest.
    function test_rankedChoice_principalWithdrawalWorks() public {
        address c = _createContest(TYPE_VOTE, WINNER_RANKED_CHOICE, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ));

        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(bob) - balBefore, DEFAULT_DEPOSIT_AMOUNT);
    }

    // ORACLE TESTS removed: legacy submitOracleData() path was deleted in favor
    // of the IResolver interface (PolymarketRelayResolver, ChainlinkFeedResolver).
    // Resolver-path coverage lives in PolymarketRelayResolver.t.sol /
    // ChainlinkFeedResolver.t.sol and the ContestV2 mirror tests.

    // =====================================================================
    //  THRESHOLD TESTS (WinnerDetermination.THRESHOLD)
    // =====================================================================

    /// @notice All entries meet threshold (highest votes option wins on-chain).
    function test_threshold_allEntriesAboveThresholdHighestWins() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        // A=3, B=2 -> both have votes, A wins
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
    }

    /// @notice No entries get any votes (all vote for one) -> that one wins.
    function test_threshold_singleOptionGetsAllVotes() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 2);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 0);
    }

    /// @notice Mixed results: some options above threshold, some below.
    function test_threshold_mixedVoteDistribution() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        // A=2, B=1, C=1, D=1 -> A wins
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 2);
    }

    /// @notice Exactly at threshold boundary with equal votes.
    function test_threshold_exactBoundaryTiedVotes() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        // All options get 1 vote each -> all tied -> first in array wins
        _runVoteContest(c, _arr4(alice, bob, charlie, dave),
            _bytes4(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            ));

        // Tied -> first option in array (OPT_A) wins
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
    }

    /// @notice With RATE type, average ratings determine threshold winner.
    function test_threshold_rateTypeAverageRating() public {
        address c = _createContest(TYPE_RATE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        bytes32[] memory opts = new bytes32[](4);
        opts[0] = OPT_A; opts[1] = OPT_B; opts[2] = OPT_C; opts[3] = OPT_D;

        uint256[] memory r1 = new uint256[](4);
        r1[0] = 9; r1[1] = 3; r1[2] = 7; r1[3] = 1;

        uint256[] memory r2 = new uint256[](4);
        r2[0] = 7; r2[1] = 5; r2[2] = 9; r2[3] = 2;

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(opts, r1),
                _makeVoteData_RATE(opts, r2)
            ));

        // Avg: A=8, B=4, C=8, D=1 -> A and C tied at 8, A first
        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "A wins with highest avg (tied with C)");
    }

    /// @notice Full lifecycle finalized under THRESHOLD.
    function test_threshold_fullLifecycleFinalized() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_C)
            ));

        assertEq(_getState(c), STATE_FINALIZED);
        assertTrue(ContestV2(c).getResults().isResolved);
    }

    /// @notice Voter scores work under THRESHOLD: correct voter gets 100.
    function test_threshold_winnerVoterGetsScore100() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_A)
            ));

        assertEq(ContestV2(c).getParticipant(alice).score, 100);
        assertEq(ContestV2(c).getParticipant(charlie).score, 0);
    }

    /// @notice Ranked options ordered correctly under THRESHOLD.
    function test_threshold_rankedOptionsOrderedByScore() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        // A=3, B=1, C=1
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C)
            ));

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.rankedOptions[0], OPT_A);
        assertTrue(res.optionScores[0] >= res.optionScores[1]);
        assertTrue(res.optionScores[1] >= res.optionScores[2]);
    }

    /// @notice Principal withdrawal after THRESHOLD finalization.
    function test_threshold_principalWithdrawalWorks() public {
        address c = _createContest(TYPE_VOTE, WINNER_THRESHOLD, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ));

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - balBefore, DEFAULT_DEPOSIT_AMOUNT);
    }

    // =====================================================================
    //  CONSENSUS TESTS (WinnerDetermination.CONSENSUS)
    // =====================================================================

    /// @notice Perfect consensus: everyone votes for the same option.
    function test_consensus_perfectConsensusUnanimous() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "Perfect consensus -> A wins");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 5);
    }

    /// @notice Near-consensus (supermajority): one dissenter.
    function test_consensus_nearConsensusOneDissenter() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        // 4 vote A, 1 votes B -> near consensus
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "A wins with 80% consensus");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 4);
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 1);
    }

    /// @notice No consensus: evenly split votes.
    function test_consensus_noConsensusEvenSplit() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        // A=1, B=1, C=1, D=1 -> no consensus, first option wins
        _runVoteContest(c, _arr4(alice, bob, charlie, dave),
            _bytes4(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            ));

        // All tied -> first option in array wins
        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "Tie -> first option wins");
    }

    /// @notice Two-way split: 50/50 with no consensus.
    function test_consensus_twoWaySplit5050() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr4(alice, bob, charlie, dave),
            _bytes4(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B)
            ));

        // Tied -> OPT_A (first in array)
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);
    }

    /// @notice Consensus with rank-type Borda scores.
    function test_consensus_rankTypeBordaScores() public {
        address c = _createContest(TYPE_RANK, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        bytes32[] memory ranking = new bytes32[](4);
        ranking[0] = OPT_C; ranking[1] = OPT_A; ranking[2] = OPT_B; ranking[3] = OPT_D;

        // Both rank identically -> full consensus
        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RANK(ranking),
                _makeVoteData_RANK(ranking)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_C, "C wins with Borda consensus");
        assertEq(ContestV2(c).optionTotalScore(OPT_C), 8); // 4*2
    }

    /// @notice Full lifecycle with CONSENSUS finalized correctly.
    function test_consensus_fullLifecycleFinalized() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_D),
                _makeVoteData_VOTE(OPT_D)
            ));

        assertEq(_getState(c), STATE_FINALIZED);
        assertTrue(ContestV2(c).getResults().isResolved);
    }

    /// @notice Winner voter gets score 100 under CONSENSUS.
    function test_consensus_winnerVoterScored100() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ));

        assertEq(ContestV2(c).getParticipant(alice).score, 100);
        assertEq(ContestV2(c).getParticipant(charlie).score, 0);
    }

    /// @notice Dissenter gets score 0 under CONSENSUS.
    function test_consensus_dissenterGetsScore0() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        // 4 vote A, 1 votes B
        _runVoteContest(c, _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ));

        assertEq(ContestV2(c).getParticipant(eve).score, 0, "Dissenter score = 0");
        assertEq(ContestV2(c).getParticipant(alice).score, 100, "Consensus voter = 100");
    }

    /// @notice Principal withdrawal after CONSENSUS finalization.
    function test_consensus_principalWithdrawalWorks() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        _runVoteContest(c, _arr2(alice, bob),
            _bytes2(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ));

        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(bob) - balBefore, DEFAULT_DEPOSIT_AMOUNT);
    }

    /// @notice Three-voter supermajority under CONSENSUS.
    function test_consensus_threeVoterSupermajority() public {
        address c = _createContest(TYPE_VOTE, WINNER_CONSENSUS, PRIZE_VOTER_REWARDS);

        // 2 out of 3 -> ~67% consensus
        _runVoteContest(c, _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_D)
            ));

        assertEq(ContestV2(c).getResults().winningOption, OPT_C, "C wins with 67% consensus");
    }
}
