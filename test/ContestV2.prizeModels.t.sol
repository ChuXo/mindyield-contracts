// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/**
 * @title ContestV2PrizeModelsTest
 * @notice Tests for the three untested prize models:
 *         SINGLE_WINNER, TOP_N, PROPORTIONAL.
 *
 * @dev The ContestV2 contract stores `prizeModel` in config but currently
 *      uses a unified resolution path (voter-reward based scoring).
 *      These tests verify that contests created with each prize model
 *      correctly:
 *        - Initialize with the right config
 *        - Progress through the full lifecycle
 *        - Distribute yield / voter rewards
 *        - Handle edge cases (zero yield, ties, rounding)
 *        - Allow principal + reward withdrawal
 *
 *      To test yield distribution, we simulate yield by:
 *        1. Minting extra USDC to the YieldVault
 *        2. Using vm.store to bump strategies[0].totalDeposited
 *      This makes the vault return more tokens than were deposited,
 *      simulating real DeFi yield.
 */
contract ContestV2PrizeModelsTest is ContestV2TestBase {

    // Re-declare events for vm.expectEmit
    event ContestResolved(bytes32 winningOption, uint256 totalYield);
    event PrincipalWithdrawn(address indexed participant, uint256 amount);
    event RewardClaimed(address indexed participant, uint256 amount);

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Run a full contest lifecycle with heterogeneous votes.
    function _runContest(
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

    /// @dev Simulate yield by minting USDC to the vault and bumping
    ///      strategies[0].totalDeposited via vm.store.
    ///
    ///      YieldVault inherits Ownable2Step + ReentrancyGuard, so the storage
    ///      layout starts at slot 3 for the contract's own state. Verified via
    ///      `forge inspect YieldVault storage-layout`:
    ///        slot 0: Ownable._owner
    ///        slot 1: Ownable2Step._pendingOwner
    ///        slot 2: ReentrancyGuard._status
    ///        slot 3: paused
    ///        slot 4: strategies mapping (uint256 => Strategy)
    ///        slot 5: strategyCount
    ///        slot 6: userShares mapping
    ///        slot 7: tokenDeposits mapping (address => mapping(uint256 => uint256))
    ///
    ///      strategies[0] base = keccak256(abi.encode(0, 4))
    ///        base+0: strategyAddress | active  (packed)
    ///        base+1: totalShares
    ///        base+2: totalDeposited
    function _simulateYield(uint256 yieldAmount) internal {
        // Mint extra USDC to the vault so it has tokens to distribute
        usdc.mint(address(yieldVault), yieldAmount);

        // Calculate storage slot for strategies[0].totalDeposited (slot 4 base)
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);

        uint256 currentTotalDeposited = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(currentTotalDeposited + yieldAmount));

        // tokenDeposits[usdc][0] — outer mapping at slot 7
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));

        uint256 currentTokenDeposits = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(currentTokenDeposits + yieldAmount));
    }

    /// @dev Run a contest and inject yield before resolution.
    function _runContestWithYield(
        address contestAddr,
        address[] memory voters,
        bytes[] memory voteDatas,
        uint256 yieldAmount
    ) internal {
        bytes32[] memory salts = new bytes32[](voters.length);

        for (uint256 i = 0; i < voters.length; i++) {
            _deposit(voters[i], contestAddr);
            salts[i] = keccak256(abi.encodePacked("salt", voters[i], i));
            _commitVote(voters[i], contestAddr, voteDatas[i], salts[i]);
        }

        // Inject yield before resolution (simulates DeFi yield accrual)
        _simulateYield(yieldAmount);

        _advancePastLock(contestAddr);

        for (uint256 i = 0; i < voters.length; i++) {
            _revealVote(voters[i], contestAddr, voteDatas[i], salts[i]);
        }

        _advancePastReveal(contestAddr);
        vm.prank(creator);
        ContestV2(contestAddr).resolveContest();
    }

    /// @dev Create a contest with custom prize model param (v2.1: prizeModelParam
    ///      no longer exists — for legacy callers we treat it as splits[0]
    ///      when the model is TOP_N_*, otherwise it's ignored. voterRewardPct
    ///      is also gone in v2.1 — kept in signature for source compat but
    ///      ignored at the contract level (always 100%).
    function _createContestWithParam(
        uint8 contestType,
        uint8 winnerMethod,
        uint8 prizeModel,
        uint256 prizeModelParam,
        uint256 /*voterRewardPct*/
    ) internal returns (address contestAddr) {
        uint256 t = block.timestamp;
        uint256 nonce = _contestNonce++;

        ContestV2.ContestConfig memory cfg = ContestV2.ContestConfig({
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
            requiresOracle:          false,
            metadataHash:            keccak256(abi.encodePacked("test-prize-model-", t, nonce)),
            metadataUri:             "ipfs://prize-test"
        });

        // Build PrizeConfig: for TOP_N_* models, build N-way splits where N = prizeModelParam.
        ContestV2.PrizeModel model = ContestV2.PrizeModel(prizeModel);
        uint16[] memory splits;
        if (model == ContestV2.PrizeModel.TOP_N_RANKED || model == ContestV2.PrizeModel.TOP_N_RANDOM) {
            uint256 n = prizeModelParam == 0 ? 3 : prizeModelParam;
            splits = new uint16[](n);
            uint256 each = 10_000 / n;
            uint256 dust = 10_000 - (each * n);
            for (uint256 i = 0; i < n; i++) {
                splits[i] = uint16(each + (i == 0 ? dust : 0));
            }
        } else {
            splits = new uint16[](0);
        }
        ContestV2.PrizeConfig memory prizeCfg = ContestV2.PrizeConfig({
            model: model,
            splitsBps: splits,
            eligibilityThreshold: 0,
            weightedByScore: false
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0,
            topPercentile:        2500,
            confidenceMultiplier: 5000,
            earlyVoterBonus:      0
        });

        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig({
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
        (, contestAddr) = factory.createCustomContest(cfg, prizeCfg, scoring, subCfg, address(0), opts, 0);
        vm.label(contestAddr, "PrizeModelContest");
    }

    // Address/bytes array helpers
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
    //  SINGLE_WINNER TESTS (~15 tests)
    // =====================================================================

    /// @notice Contest with SINGLE_WINNER prize model initializes correctly
    function test_singleWinner_configStoredCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        // v2.1: prizeModel moved to PrizeConfig; legacy PRIZE_SINGLE_WINNER alias = PRIZE_SINGLE_TOP
        ContestV2.PrizeConfig memory prize = ContestV2(c).getPrizeConfig();
        assertEq(uint8(prize.model), PRIZE_SINGLE_TOP, "prize model should be SINGLE_TOP (was SINGLE_WINNER)");
    }

    /// @notice SINGLE_WINNER: Full lifecycle resolves to FINALIZED
    function test_singleWinner_fullLifecycleResolves() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);

        _runContest(c, _arr2(alice, bob), _bytes2(vA, vA));

        assertEq(_getState(c), STATE_FINALIZED, "should be FINALIZED");
        assertTrue(ContestV2(c).getResults().isResolved, "should be resolved");
    }

    /// @notice SINGLE_WINNER: Winning option is determined by plurality
    function test_singleWinner_winnerDeterminedByPlurality() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        // Alice and Bob vote A, Charlie votes B -> A wins
        _runContest(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            )
        );

        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "OPT_A should win");
    }

    /// @notice SINGLE_WINNER: Winner gets voter reward, loser gets zero
    function test_singleWinner_winnerGetsReward_loserGetsZero() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_B)),
            10e6 // 10 USDC yield
        );

        // Alice voted for winner (OPT_A), should have score 100; Bob score 0
        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);
        assertEq(pAlice.score, 100, "Winner score = 100");
        assertEq(pBob.score, 0, "Loser score = 0");

        // Alice gets all voter rewards since she's the only one with score > 0
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);
        assertGt(aliceReward, 0, "Winner should have reward");
        assertEq(bobReward, 0, "Loser should have no reward");
    }

    /// @notice SINGLE_WINNER: With single participant (min=2 deposit, one winner)
    function test_singleWinner_twoParticipantsOneVotesCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes memory vB = _makeVoteData_VOTE(OPT_B);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(vA, vB),
            6e6
        );

        // Tied votes: A=1, B=1. Bubble sort preserves order -> OPT_A wins
        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "First option wins tie");

        // Alice voted A (winner) -> gets all rewards
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        assertGt(aliceReward, 0, "Alice should get reward for correct vote");
    }

    /// @notice SINGLE_WINNER: Multiple participants, one clear winner
    function test_singleWinner_multipleParticipantsOneWinner() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        // 3 vote B, 2 vote A -> B wins
        _runContestWithYield(c,
            _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_A)
            ),
            20e6
        );

        assertEq(ContestV2(c).getResults().winningOption, OPT_B, "OPT_B wins with 3 votes");

        // Voters of B (bob, charlie, dave) should have scores > 0
        assertEq(ContestV2(c).getParticipant(bob).score, 100);
        assertEq(ContestV2(c).getParticipant(charlie).score, 100);
        assertEq(ContestV2(c).getParticipant(dave).score, 100);

        // Voters of A should have score 0
        assertEq(ContestV2(c).getParticipant(alice).score, 0);
        assertEq(ContestV2(c).getParticipant(eve).score, 0);
    }

    /// @notice SINGLE_WINNER: Tied votes -- first option in array wins (tiebreaker)
    function test_singleWinner_tiedVotesTiebreaker() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        // Alice votes A, Bob votes B -> tie. OPT_A is first in options array -> wins
        _runContest(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_B))
        );

        assertEq(ContestV2(c).getResults().winningOption, OPT_A, "First option wins tie");
    }

    /// @notice SINGLE_WINNER: Zero yield scenario -- no rewards distributed
    function test_singleWinner_zeroYield_noRewardsDistributed() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        // No yield injection
        _runContest(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A))
        );

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.totalYield, 0, "No yield with mock vault");
        assertEq(res.voterRewardsPool, 0, "No voter rewards pool");
        // optionRewardsPool field removed in 2026-04 slim-down (was always 0).
        assertEq(ContestV2(c).getVoterReward(alice), 0, "Alice reward = 0");
        assertEq(ContestV2(c).getVoterReward(bob), 0, "Bob reward = 0");
    }

    /// @notice SINGLE_WINNER: Winner can withdraw principal after finalization
    function test_singleWinner_winnerWithdrawsPrincipal() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        _runContest(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A))
        );

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balAfter - balBefore, DEFAULT_DEPOSIT_AMOUNT, "Should receive principal back");
    }

    /// @notice SINGLE_WINNER: Non-winner can also withdraw principal
    function test_singleWinner_nonWinnerWithdrawsPrincipal() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        _runContest(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            )
        );

        // Charlie voted for loser B, but should still get principal back
        uint256 balBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        ContestV2(c).withdrawPrincipal();
        uint256 balAfter = usdc.balanceOf(charlie);

        assertEq(balAfter - balBefore, DEFAULT_DEPOSIT_AMOUNT, "Loser should get principal back");
    }

    /// @notice SINGLE_WINNER: Winner can claim voter reward with yield
    function test_singleWinner_winnerClaimsVoterReward() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        uint256 yieldAmount = 10e6;

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_B)),
            yieldAmount
        );

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        assertGt(aliceReward, 0, "Winner should have claimable reward");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).claimVoterReward();
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balAfter - balBefore, aliceReward, "Should receive exact reward amount");
    }

    /// @notice SINGLE_WINNER: Non-winner cannot claim reward
    function test_singleWinner_nonWinnerCannotClaimReward() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_B)),
            10e6
        );

        // Bob voted for loser, should have 0 reward
        vm.prank(bob);
        vm.expectRevert(ContestV2.NoReward.selector);
        ContestV2(c).claimVoterReward();
    }

    /// @notice SINGLE_WINNER: Yield is split correctly between voter/option pools
    function test_singleWinner_yieldSplitCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        uint256 yieldAmount = 100e6; // 100 USDC yield

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            yieldAmount
        );

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        // totalYield is yield AFTER protocol fee deduction (2% default)
        uint256 expectedNet = (yieldAmount * 9800) / 10000; // 98% after 2% fee
        assertApproxEqAbs(res.totalYield, expectedNet, 10, "Total yield should approx match net after fee");
        // v2.1: 100% of yield flows to voters; option pool is permanently 0.
        assertApproxEqAbs(res.voterRewardsPool, res.totalYield, 1, "Voter pool = 100% of yield");
        // optionRewardsPool field removed in 2026-04 slim-down (was always 0).
    }

    /// @notice SINGLE_WINNER: All participants can withdraw principal + reward cycle
    function test_singleWinner_fullWithdrawalCycle() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        uint256 yieldAmount = 10e6;

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ),
            yieldAmount
        );

        // All three withdraw principal
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
        vm.prank(charlie);
        ContestV2(c).withdrawPrincipal();

        // Winners (alice, bob) claim voter rewards
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);
        if (aliceReward > 0) {
            vm.prank(alice);
            ContestV2(c).claimVoterReward();
        }
        if (bobReward > 0) {
            vm.prank(bob);
            ContestV2(c).claimVoterReward();
        }

        // Verify rewards were equal (both scored 100)
        assertEq(aliceReward, bobReward, "Equal scores should yield equal rewards");
    }

    /// @notice SINGLE_WINNER: Cannot claim reward twice
    function test_singleWinner_cannotClaimRewardTwice() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_B)),
            10e6
        );

        vm.prank(alice);
        ContestV2(c).claimVoterReward();

        vm.prank(alice);
        vm.expectRevert(ContestV2.AlreadyClaimed.selector);
        ContestV2(c).claimVoterReward();
    }

    /// @notice SINGLE_WINNER: Ranked options array is sorted by score
    function test_singleWinner_rankedOptionsAreSorted() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);

        // A gets 3 votes, B gets 1, C gets 1, D gets 0
        _runContest(c,
            _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_C)
            )
        );

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertEq(res.rankedOptions[0], OPT_A, "A should be first with 3 votes");
        // B and C tied at 1, D at 0 -- verify descending order
        assertTrue(res.optionScores[0] >= res.optionScores[1], "Scores should be descending");
        assertTrue(res.optionScores[1] >= res.optionScores[2], "Scores should be descending");
        assertTrue(res.optionScores[2] >= res.optionScores[3], "Scores should be descending");
    }

    // =====================================================================
    //  TOP_N TESTS (~15 tests)
    // =====================================================================

    /// @notice TOP_N: Config stored correctly with splits (v2.1 — was prizeModelParam)
    function test_topN_configStoredCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        ContestV2.PrizeConfig memory prize = ContestV2(c).getPrizeConfig();
        // PRIZE_TOP_N legacy alias maps to PRIZE_TOP_N_RANKED (index 3); test base
        // helper provides default 60/30/10 splits for TOP_N_* models.
        assertEq(uint8(prize.model), PRIZE_TOP_N_RANKED, "prize model should be TOP_N_RANKED");
        assertEq(prize.splitsBps.length, 3, "default splits should have 3 ranks");
    }

    /// @notice TOP_N: Full lifecycle resolves successfully
    function test_topN_fullLifecycleResolves() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContest(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            )
        );

        assertEq(_getState(c), STATE_FINALIZED, "should be FINALIZED");
    }

    /// @notice TOP_N: Top 3 voters who voted for winner split yield
    function test_topN_top3VotersShareYield() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        // All 3 vote for A -> all have score 100 -> all share rewards
        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            30e6
        );

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);
        uint256 charlieReward = ContestV2(c).getVoterReward(charlie);

        // All have same score -> equal split of voterRewardsPool
        assertEq(aliceReward, bobReward, "Equal scores -> equal rewards");
        assertEq(bobReward, charlieReward, "Equal scores -> equal rewards");
        assertGt(aliceReward, 0, "Should have non-zero reward");
    }

    /// @notice TOP_N with N > participants: all participants get rewards
    function test_topN_nGreaterThanParticipants() public {
        // prizeModelParam = 3 but only 2 participants, both vote correctly
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            20e6
        );

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);

        assertGt(aliceReward, 0, "Alice should get reward");
        assertGt(bobReward, 0, "Bob should get reward");
        assertEq(aliceReward, bobReward, "Equal split for same score");
    }

    /// @notice TOP_N: Equal scores yield equal reward split
    function test_topN_equalScoresEqualSplit() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        uint256 yieldAmount = 100e6;

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            yieldAmount
        );

        uint256 voterPool = ContestV2(c).getResults().voterRewardsPool;
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);

        // 3 voters each with score 100: each gets voterPool * 100 / 300
        assertEq(aliceReward, voterPool / 3, "Each gets 1/3 of pool");
    }

    /// @notice TOP_N: Exact N participants, all vote correctly
    function test_topN_exactNParticipants() public {
        // N=3, 3 participants
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B),
                _makeVoteData_VOTE(OPT_B)
            ),
            15e6
        );

        // All 3 voted correctly -> all get rewards
        assertGt(ContestV2(c).getVoterReward(alice), 0);
        assertGt(ContestV2(c).getVoterReward(bob), 0);
        assertGt(ContestV2(c).getVoterReward(charlie), 0);
    }

    /// @notice TOP_N with N=1: equivalent to single winner
    function test_topN_topOneEquivalentToSingleWinner() public {
        address c = _createContestWithParam(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N, 1, DEFAULT_VOTER_REWARD_PCT);

        // Alice votes A (winner), Bob and Charlie vote B (loser)
        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ),
            30e6
        );

        // Both alice and bob voted for winner -> both get rewards
        // The prizeModelParam doesn't affect the current voter reward distribution
        // since _distributeVoterRewards uses scores not topN
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);
        uint256 charlieReward = ContestV2(c).getVoterReward(charlie);

        assertGt(aliceReward, 0, "Winner voters get reward");
        assertEq(charlieReward, 0, "Loser gets no reward");
        assertEq(aliceReward, bobReward, "Same score -> same reward");
    }

    /// @notice TOP_N: Yield rounding with odd splits
    function test_topN_yieldRoundingWithOddSplits() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        uint256 yieldAmount = 7e6; // 7 USDC -- not evenly divisible by 3

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            yieldAmount
        );

        uint256 voterPool = ContestV2(c).getResults().voterRewardsPool;
        uint256 totalRewards = ContestV2(c).getVoterReward(alice)
            + ContestV2(c).getVoterReward(bob)
            + ContestV2(c).getVoterReward(charlie);

        // Rounding may leave dust
        assertLe(totalRewards, voterPool, "Distributed <= pool (rounding down)");
        uint256 dust = voterPool - totalRewards;
        assertLe(dust, 2, "Rounding dust should be minimal (max 2 wei for 3-way split)");

        // Undistributed rewards tracked
        assertEq(ContestV2(c).undistributedRewards(), dust, "Dust tracked as undistributed");
    }

    /// @notice TOP_N: All top N can withdraw principal + rewards
    function test_topN_allTopNWithdraw() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            30e6
        );

        // All withdraw principal
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < 3; i++) {
            uint256 balBefore = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            ContestV2(users[i] == alice ? c : c).withdrawPrincipal();
            assertEq(usdc.balanceOf(users[i]) - balBefore, DEFAULT_DEPOSIT_AMOUNT, "Principal returned");
        }

        // All claim voter rewards
        for (uint256 i = 0; i < 3; i++) {
            uint256 reward = ContestV2(c).getVoterReward(users[i]);
            if (reward > 0) {
                uint256 balBefore = usdc.balanceOf(users[i]);
                vm.prank(users[i]);
                ContestV2(c).claimVoterReward();
                assertEq(usdc.balanceOf(users[i]) - balBefore, reward, "Reward claimed correctly");
            }
        }
    }

    /// @notice TOP_N: Zero yield means no rewards for anyone
    function test_topN_zeroYield_noRewards() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContest(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            )
        );

        assertEq(ContestV2(c).getResults().totalYield, 0);
        assertEq(ContestV2(c).getVoterReward(alice), 0);
        assertEq(ContestV2(c).getVoterReward(bob), 0);
        assertEq(ContestV2(c).getVoterReward(charlie), 0);
    }

    /// @notice TOP_N: Mixed winners and losers -- only winners get rewards
    function test_topN_mixedWinnersAndLosers() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        // Alice, Bob vote A (winners), Charlie votes B (loser)
        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ),
            20e6
        );

        assertGt(ContestV2(c).getVoterReward(alice), 0, "Winner gets reward");
        assertGt(ContestV2(c).getVoterReward(bob), 0, "Winner gets reward");
        assertEq(ContestV2(c).getVoterReward(charlie), 0, "Loser gets no reward");
    }

    /// @notice TOP_N: Winning option identified correctly with 5 participants
    function test_topN_winnerIdentifiedWith5Participants() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContest(c,
            _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_C),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            )
        );

        assertEq(ContestV2(c).getResults().winningOption, OPT_C, "C wins with 3 votes");
    }

    /// @notice TOP_N: Creator can claim undistributed rewards (rounding dust)
    function test_topN_creatorClaimsUndistributedRewards() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            7e6 // Causes rounding dust with 3-way split
        );

        uint256 dust = ContestV2(c).undistributedRewards();
        if (dust > 0) {
            uint256 creatorBal = usdc.balanceOf(creator);
            vm.prank(creator);
            ContestV2(c).claimUndistributedRewards();
            assertEq(usdc.balanceOf(creator) - creatorBal, dust, "Creator receives dust");
            assertEq(ContestV2(c).undistributedRewards(), 0, "Dust cleared");
        }
    }

    /// @notice TOP_N: voterRewardPercentage set to 100 means all yield goes to voters
    function test_topN_100PercentVoterReward() public {
        address c = _createContestWithParam(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N, 3, 100);
        uint256 yieldAmount = 30e6;

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            yieldAmount
        );

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        // totalYield is net of 2% protocol fee; voterRewardPercentage = 100%
        uint256 expectedNet = (yieldAmount * 9800) / 10000;
        assertApproxEqAbs(res.voterRewardsPool, expectedNet, 10, "100% of yield to voters (net of fee)");
        // optionRewardsPool field removed in 2026-04 slim-down (was always 0).
    }

    /// @notice v2.1: voterRewardPercentage is deprecated — 100% always flows to
    ///         voters regardless of the legacy param. Retained as a regression
    ///         test to document the behavior change.
    function test_topN_0PercentVoterReward() public {
        address c = _createContestWithParam(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N, 3, 0);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            20e6
        );

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        uint256 expectedNet = (20e6 * 9800) / 10000;
        // v2.1 ignores the legacy percentage — entire pool flows to voters.
        assertApproxEqAbs(res.voterRewardsPool, expectedNet, 10, "100% of yield to voters in v2.1");
        // optionRewardsPool field removed in 2026-04 slim-down (was always 0).
        assertGt(ContestV2(c).getVoterReward(alice), 0, "Alice still gets reward");
    }

    // =====================================================================
    //  PROPORTIONAL TESTS (~15 tests)
    // =====================================================================

    /// @notice PROPORTIONAL: Config stored correctly (v2.1 — uses getPrizeConfig)
    function test_proportional_configStoredCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        ContestV2.PrizeConfig memory prize = ContestV2(c).getPrizeConfig();
        assertEq(uint8(prize.model), PRIZE_PROPORTIONAL, "prize model should be PROPORTIONAL");
    }

    /// @notice PROPORTIONAL: Full lifecycle resolves
    function test_proportional_fullLifecycleResolves() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        _runContest(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A))
        );

        assertEq(_getState(c), STATE_FINALIZED, "should be FINALIZED");
    }

    /// @notice PROPORTIONAL: Rewards proportional to voter score
    function test_proportional_rewardsProportionalToScore() public {
        // Use PREDICT type where different confidence levels create different scores
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        // Both predict correctly (OPT_A wins), but with different confidence
        // Alice: confidence=80 -> score = 100 * (10000 + 80*50) / 10000 = 140
        // Bob:   confidence=20 -> score = 100 * (10000 + 20*50) / 10000 = 110
        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PREDICT(OPT_A, 80),
                _makeVoteData_PREDICT(OPT_A, 20)
            ),
            100e6
        );

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);

        // Alice has higher score -> higher reward
        assertGt(aliceReward, bobReward, "Higher score -> higher proportional reward");
        assertGt(bobReward, 0, "Lower score still gets some reward");
    }

    /// @notice PROPORTIONAL: All equal scores yield equal split
    function test_proportional_allEqualScoresEqualSplit() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            30e6
        );

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);
        uint256 charlieReward = ContestV2(c).getVoterReward(charlie);

        assertEq(aliceReward, bobReward, "Equal scores -> equal rewards");
        assertEq(bobReward, charlieReward, "Equal scores -> equal rewards");
    }

    /// @notice PROPORTIONAL: One dominant score gets majority of rewards
    function test_proportional_oneDominantScore() public {
        // PREDICT type: one high confidence correct, one low confidence correct
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        // Alice: confidence=100 -> score = 100*(10000+5000)/10000 = 150
        // Bob:   confidence=1   -> score = 100*(10000+50)/10000 = 100
        // Total: 250. Alice gets 150/250 = 60%, Bob gets 100/250 = 40%
        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(
                _makeVoteData_PREDICT(OPT_A, 100),
                _makeVoteData_PREDICT(OPT_A, 1)
            ),
            100e6
        );

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);

        // Alice should get significantly more
        assertGt(aliceReward, bobReward, "Dominant score gets more");
        // Verify approximate ratio: 150/250 = 60% for Alice
        uint256 voterPool = ContestV2(c).getResults().voterRewardsPool;
        assertApproxEqAbs(aliceReward, (voterPool * 150) / 250, 1, "Alice ~60% of pool");
    }

    /// @notice PROPORTIONAL: Many participants with varying scores
    function test_proportional_manyParticipantsVaryingScores() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        // 4 predict OPT_A (winner), 1 predicts OPT_B (loser)
        _runContestWithYield(c,
            _arr5(alice, bob, charlie, dave, eve),
            _bytes5(
                _makeVoteData_PREDICT(OPT_A, 90),
                _makeVoteData_PREDICT(OPT_A, 50),
                _makeVoteData_PREDICT(OPT_A, 30),
                _makeVoteData_PREDICT(OPT_A, 10),
                _makeVoteData_PREDICT(OPT_B, 80)
            ),
            50e6
        );

        // Eve predicted wrong -> score 0 -> no reward
        assertEq(ContestV2(c).getVoterReward(eve), 0, "Wrong predictor gets nothing");

        // Others get rewards proportional to their scores
        uint256 aliceR = ContestV2(c).getVoterReward(alice);
        uint256 bobR = ContestV2(c).getVoterReward(bob);
        uint256 charlieR = ContestV2(c).getVoterReward(charlie);
        uint256 daveR = ContestV2(c).getVoterReward(dave);

        // Higher confidence -> higher score -> higher reward
        assertGt(aliceR, bobR, "Alice > Bob (90 vs 50 confidence)");
        assertGt(bobR, charlieR, "Bob > Charlie (50 vs 30)");
        assertGt(charlieR, daveR, "Charlie > Dave (30 vs 10)");
    }

    /// @notice PROPORTIONAL: Zero score participants get nothing
    function test_proportional_zeroScoreParticipantsGetNothing() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        // Alice and Bob vote A (winner with 2 votes), Charlie votes B (loser with 1 vote)
        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_B)
            ),
            30e6
        );

        // Charlie voted wrong -> score 0 -> no reward
        assertEq(ContestV2(c).getVoterReward(charlie), 0, "Wrong voter gets nothing");

        // Alice and Bob get voter rewards (both with score > 0)
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);
        assertGt(aliceReward, 0, "Correct voter gets reward");
        assertEq(aliceReward, bobReward, "Equal scores -> equal rewards");
    }

    /// @notice PROPORTIONAL: Rounding dust handling
    function test_proportional_roundingDustHandling() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        // 3 participants with different scores -> odd division
        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_PREDICT(OPT_A, 70),
                _makeVoteData_PREDICT(OPT_A, 40),
                _makeVoteData_PREDICT(OPT_A, 10)
            ),
            11e6 // Prime-ish amount for maximum rounding
        );

        uint256 voterPool = ContestV2(c).getResults().voterRewardsPool;
        uint256 totalDistributed = ContestV2(c).getVoterReward(alice)
            + ContestV2(c).getVoterReward(bob)
            + ContestV2(c).getVoterReward(charlie);
        uint256 dust = ContestV2(c).undistributedRewards();

        // distributed + dust = voterPool
        assertEq(totalDistributed + dust, voterPool, "Distributed + dust = pool");
        assertLe(dust, 2, "Minimal rounding dust");
    }

    /// @notice PROPORTIONAL: Full withdrawal cycle
    function test_proportional_fullWithdrawalCycle() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            20e6
        );

        // Both withdraw principal
        uint256 alicePrincipalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - alicePrincipalBefore, DEFAULT_DEPOSIT_AMOUNT);

        uint256 bobPrincipalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(bob) - bobPrincipalBefore, DEFAULT_DEPOSIT_AMOUNT);

        // Both claim voter rewards
        uint256 aliceRewardBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).claimVoterReward();
        assertGt(usdc.balanceOf(alice) - aliceRewardBefore, 0, "Alice claimed reward");

        uint256 bobRewardBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        ContestV2(c).claimVoterReward();
        assertGt(usdc.balanceOf(bob) - bobRewardBefore, 0, "Bob claimed reward");
    }

    /// @notice PROPORTIONAL: Zero yield means no rewards
    function test_proportional_zeroYield_noRewards() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        _runContest(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A))
        );

        assertEq(ContestV2(c).getResults().totalYield, 0);
        assertEq(ContestV2(c).getVoterReward(alice), 0);
        assertEq(ContestV2(c).getVoterReward(bob), 0);
    }

    /// @notice PROPORTIONAL: Rewards sum to voterRewardsPool (minus dust)
    function test_proportional_rewardsSumToPool() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        uint256 yieldAmount = 100e6;

        _runContestWithYield(c,
            _arr3(alice, bob, charlie),
            _bytes3(
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A),
                _makeVoteData_VOTE(OPT_A)
            ),
            yieldAmount
        );

        uint256 voterPool = ContestV2(c).getResults().voterRewardsPool;
        uint256 totalRewards = ContestV2(c).getVoterReward(alice)
            + ContestV2(c).getVoterReward(bob)
            + ContestV2(c).getVoterReward(charlie);

        uint256 dust = ContestV2(c).undistributedRewards();
        assertEq(totalRewards + dust, voterPool, "Rewards + dust = pool");
    }

    /// @notice PROPORTIONAL: Non-revealer gets no reward
    function test_proportional_nonRevealerGetsNothing() public {
        // Create contest, alice deposits + commits + reveals, bob deposits + commits but doesn't reveal
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes32 sAlice = keccak256("alice-salt");
        bytes32 sBob = keccak256("bob-salt");

        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, vA, sAlice);
        _commitVote(bob, c, vA, sBob);

        _simulateYield(20e6);

        _advancePastLock(c);

        // Only alice reveals
        _revealVote(alice, c, vA, sAlice);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        // Alice gets all rewards since she's the only revealer with a score
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        assertGt(aliceReward, 0, "Revealer gets reward");

        // Bob didn't reveal -> no reward
        assertEq(ContestV2(c).getVoterReward(bob), 0, "Non-revealer gets nothing");

        // Bob should not be able to claim
        vm.prank(bob);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).claimVoterReward();
    }

    /// @notice PROPORTIONAL with RANK type: scores based on ranking correlation
    function test_proportional_rankType_correlationScores() public {
        address c = _createContest(TYPE_RANK, WINNER_BORDA_COUNT, PRIZE_PROPORTIONAL);

        bytes32[] memory r1 = new bytes32[](4);
        r1[0] = OPT_A; r1[1] = OPT_B; r1[2] = OPT_C; r1[3] = OPT_D;

        bytes32[] memory r2 = new bytes32[](4);
        r2[0] = OPT_D; r2[1] = OPT_C; r2[2] = OPT_B; r2[3] = OPT_A;

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RANK(r1),
                _makeVoteData_RANK(r2)
            ),
            20e6
        );

        // Alice's ranking should be closer to result -> higher score
        ContestV2.Participant memory pAlice = ContestV2(c).getParticipant(alice);
        ContestV2.Participant memory pBob = ContestV2(c).getParticipant(bob);

        // Rewards should differ based on correlation scores
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);

        if (pAlice.score > pBob.score) {
            assertGt(aliceReward, bobReward, "Better correlation -> more reward");
        } else if (pBob.score > pAlice.score) {
            assertGt(bobReward, aliceReward, "Better correlation -> more reward");
        } else {
            assertEq(aliceReward, bobReward, "Equal correlation -> equal reward");
        }
    }

    /// @notice PROPORTIONAL with RATE type: rewards proportional to rating accuracy
    function test_proportional_rateType_proportionalRewards() public {
        address c = _createContest(TYPE_RATE, WINNER_WEIGHTED_AVERAGE, PRIZE_PROPORTIONAL);

        bytes32[] memory opts = new bytes32[](4);
        opts[0] = OPT_A; opts[1] = OPT_B; opts[2] = OPT_C; opts[3] = OPT_D;

        uint256[] memory r1 = new uint256[](4);
        r1[0] = 10; r1[1] = 5; r1[2] = 3; r1[3] = 1;

        uint256[] memory r2 = new uint256[](4);
        r2[0] = 10; r2[1] = 5; r2[2] = 3; r2[3] = 1;

        // Both rate identically -> both get perfect score -> equal rewards
        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(
                _makeVoteData_RATE(opts, r1),
                _makeVoteData_RATE(opts, r2)
            ),
            20e6
        );

        assertEq(
            ContestV2(c).getVoterReward(alice),
            ContestV2(c).getVoterReward(bob),
            "Identical ratings -> equal rewards"
        );
    }

    /// @notice PROPORTIONAL: Large yield amount distributes correctly
    function test_proportional_largeYieldDistribution() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        uint256 yieldAmount = 1_000_000e6; // 1M USDC yield

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            yieldAmount
        );

        uint256 voterPool = ContestV2(c).getResults().voterRewardsPool;
        // v2.1: 100% of net yield flows to voters (option pool removed).
        uint256 expectedNet = (yieldAmount * 9800) / 10000;
        assertApproxEqAbs(voterPool, expectedNet, 100_000, "100% of net yield");

        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);

        // Each gets half of voterPool
        assertEq(aliceReward, voterPool / 2, "Equal split of large pool");
        assertEq(aliceReward, bobReward, "Equal rewards");
    }

    /// @notice PROPORTIONAL: Cancelled contest has no yield distribution
    function test_proportional_cancelledContestNoYield() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        _deposit(alice, c);
        _deposit(bob, c);

        _simulateYield(20e6);

        // Advance past YieldVault MIN_HOLD_TIME (15s) so cancel can withdraw from vault
        vm.warp(block.timestamp + 61);
        _advanceBlock();

        vm.prank(creator);
        ContestV2(c).cancel("testing cancel");

        assertEq(_getState(c), STATE_CANCELLED);

        // Principal still withdrawable
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - balBefore, DEFAULT_DEPOSIT_AMOUNT, "Principal returned on cancel");
    }

    /// @notice PROPORTIONAL: Contest with minimum 2 participants resolves
    function test_proportional_minimumParticipantsResolves() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);

        _runContestWithYield(c,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_B), _makeVoteData_VOTE(OPT_B)),
            10e6
        );

        assertEq(_getState(c), STATE_FINALIZED);
        assertEq(ContestV2(c).getResults().winningOption, OPT_B);
    }

    // =====================================================================
    //  CROSS-MODEL COMPARISON TESTS (bonus, 5 tests)
    // =====================================================================

    /// @notice All prize models produce same yield split with identical participants
    function test_crossModel_sameYieldSplitAcrossModels() public {
        uint256 yieldAmount = 60e6;

        // SINGLE_WINNER
        address c1 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        _runContestWithYield(c1,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            yieldAmount
        );

        // TOP_N
        address c2 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        _runContestWithYield(c2,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            yieldAmount
        );

        // PROPORTIONAL
        address c3 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        _runContestWithYield(c3,
            _arr2(alice, bob),
            _bytes2(_makeVoteData_VOTE(OPT_A), _makeVoteData_VOTE(OPT_A)),
            yieldAmount
        );

        // All should have approximately same yield split (small rounding differences
        // from ERC-4626 virtual shares offset when vault state differs between contests)
        assertApproxEqAbs(
            ContestV2(c1).getResults().totalYield,
            ContestV2(c2).getResults().totalYield,
            100,
            "Same yield across models"
        );
        assertApproxEqAbs(
            ContestV2(c2).getResults().totalYield,
            ContestV2(c3).getResults().totalYield,
            100,
            "Same yield across models"
        );
        assertApproxEqAbs(
            ContestV2(c1).getResults().voterRewardsPool,
            ContestV2(c2).getResults().voterRewardsPool,
            100,
            "Same voter pool across models"
        );
    }

    /// @notice All models allow principal withdrawal after finalization
    function test_crossModel_allModelsAllowPrincipalWithdrawal() public {
        bytes memory vA = _makeVoteData_VOTE(OPT_A);

        address c1 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        _runContest(c1, _arr2(alice, bob), _bytes2(vA, vA));

        address c2 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        _runContest(c2, _arr2(alice, bob), _bytes2(vA, vA));

        address c3 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        _runContest(c3, _arr2(alice, bob), _bytes2(vA, vA));

        // Withdraw from all three
        uint256 bal;
        bal = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c1).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - bal, DEFAULT_DEPOSIT_AMOUNT, "SINGLE_WINNER principal");

        bal = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c2).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - bal, DEFAULT_DEPOSIT_AMOUNT, "TOP_N principal");

        bal = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c3).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice) - bal, DEFAULT_DEPOSIT_AMOUNT, "PROPORTIONAL principal");
    }

    /// @notice All models handle zero yield gracefully
    function test_crossModel_allModelsHandleZeroYield() public {
        bytes memory vA = _makeVoteData_VOTE(OPT_A);

        address c1 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        _runContest(c1, _arr2(alice, bob), _bytes2(vA, vA));

        address c2 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        _runContest(c2, _arr2(alice, bob), _bytes2(vA, vA));

        address c3 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        _runContest(c3, _arr2(alice, bob), _bytes2(vA, vA));

        assertEq(ContestV2(c1).getResults().totalYield, 0, "SINGLE_WINNER no yield");
        assertEq(ContestV2(c2).getResults().totalYield, 0, "TOP_N no yield");
        assertEq(ContestV2(c3).getResults().totalYield, 0, "PROPORTIONAL no yield");
    }

    /// @notice All models correctly identify winning option
    function test_crossModel_allModelsIdentifyCorrectWinner() public {
        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes memory vB = _makeVoteData_VOTE(OPT_B);

        address c1 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_WINNER);
        _runContest(c1, _arr3(alice, bob, charlie), _bytes3(vA, vA, vB));

        address c2 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N);
        _runContest(c2, _arr3(alice, bob, charlie), _bytes3(vA, vA, vB));

        address c3 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL);
        _runContest(c3, _arr3(alice, bob, charlie), _bytes3(vA, vA, vB));

        assertEq(ContestV2(c1).getResults().winningOption, OPT_A, "SINGLE_WINNER: A wins");
        assertEq(ContestV2(c2).getResults().winningOption, OPT_A, "TOP_N: A wins");
        assertEq(ContestV2(c3).getResults().winningOption, OPT_A, "PROPORTIONAL: A wins");
    }

    /// @notice (v2.1) Replaces test_crossModel_prizeModelParamStoredForAll —
    ///         the legacy `prizeModelParam` field was removed; per-rank splits
    ///         live in `PrizeConfig.splitsBps` and only apply to TOP_N_* modes.
    function test_crossModel_splitsStoredForTopNOnly() public {
        // SINGLE_TOP — empty splits (math is implicit)
        address c1 = _createContestWithParam(TYPE_VOTE, WINNER_PLURALITY, PRIZE_SINGLE_TOP, 0, 50);
        // TOP_N_RANKED — 5-way equal splits (2000 each)
        address c2 = _createContestWithParam(TYPE_VOTE, WINNER_PLURALITY, PRIZE_TOP_N_RANKED, 5, 50);
        // PROPORTIONAL — empty splits
        address c3 = _createContestWithParam(TYPE_VOTE, WINNER_PLURALITY, PRIZE_PROPORTIONAL, 0, 50);

        assertEq(ContestV2(c1).getPrizeConfig().splitsBps.length, 0, "SINGLE_TOP: no splits");
        assertEq(ContestV2(c2).getPrizeConfig().splitsBps.length, 5, "TOP_N_RANKED: 5-way splits");
        assertEq(ContestV2(c3).getPrizeConfig().splitsBps.length, 0, "PROPORTIONAL: no splits");
    }
}
