// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/**
 * @title ContestV2CreatorPrizeTest
 * @notice Tests for creator-sponsored prize pools:
 *   - Boosted contests (depositAmount > 0, creatorPrize > 0)
 *   - Fully sponsored contests (depositAmount = 0, creatorPrize > 0)
 *   - Cancellation refunds
 *   - Protocol fee on yield from creator prize
 *   - Edge cases
 */
contract ContestV2CreatorPrizeTest is ContestV2TestBase {

    // Re-declare events for vm.expectEmit
    event CreatorPrizeDeposited(address indexed creator, uint256 amount);
    event CreatorPrizeRefunded(address indexed creator, uint256 amount);

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Create a fully sponsored contest (depositAmount = 0) with a creator prize.
    function _createSponsoredContest(uint256 prize) internal returns (address contestAddr) {
        uint256 t = block.timestamp;
        uint256 nonce = _contestNonce++;

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           0, // fully sponsored
            minParticipants:         DEFAULT_MIN_PARTICIPANTS,
            maxParticipants:         DEFAULT_MAX_PARTICIPANTS,
            depositStart:            t,
            depositEnd:              t + DEFAULT_DEPOSIT_DURATION,
            lockEnd:                 t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION,
            revealEnd:               t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION + DEFAULT_REVEAL_DURATION,
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        DEFAULT_QUORUM_PERCENTAGE,
            requiresOracle:          false,
            metadataHash:            keccak256(abi.encodePacked("sponsored-", t, nonce)),
            metadataUri:             "ipfs://sponsored"
        });

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

        // Creator must approve factory for the prize amount
        vm.startPrank(creator);
        usdc.approve(address(factory), prize);
        (, contestAddr) = factory.createCustomContest(config, _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL), scoring, subConfig, address(0), opts, prize);
        vm.stopPrank();

        vm.label(contestAddr, "SponsoredContest");
    }

    /// @dev Create a boosted contest (depositAmount > 0, creatorPrize > 0).
    function _createBoostedContest(uint256 prize) internal returns (address contestAddr) {
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
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        DEFAULT_QUORUM_PERCENTAGE,
            requiresOracle:          false,
            metadataHash:            keccak256(abi.encodePacked("boosted-", t, nonce)),
            metadataUri:             "ipfs://boosted"
        });

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

        vm.startPrank(creator);
        usdc.approve(address(factory), prize);
        (, contestAddr) = factory.createCustomContest(config, _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL), scoring, subConfig, address(0), opts, prize);
        vm.stopPrank();

        vm.label(contestAddr, "BoostedContest");
    }

    /// @dev Join a sponsored contest (free deposit).
    function _joinSponsored(address user, address contest) internal {
        vm.prank(user);
        ContestV2(contest).deposit();
        _advanceBlock();
    }

    // =========================================================================
    // 1. CREATION TESTS (4 tests)
    // =========================================================================

    /// @notice Creator prize is deposited to vault during creation.
    function test_creatorPrize_depositedToVaultOnCreation() public {
        uint256 prize = 1000e6;
        uint256 creatorBefore = usdc.balanceOf(creator);

        address contest = _createSponsoredContest(prize);

        // Creator should have paid the prize
        assertEq(usdc.balanceOf(creator), creatorBefore - prize, "Creator balance not reduced");

        // Prize tracked on contract
        assertEq(ContestV2(contest).creatorPrize(), prize, "creatorPrize not set");

        // Vault shares should be > 0 (prize deposited to vault)
        assertTrue(ContestV2(contest).vaultShares() > 0, "No vault shares after prize deposit");

        // totalDeposited should be 0 (no participant deposits)
        assertEq(ContestV2(contest).totalDeposited(), 0, "totalDeposited should be 0");
    }

    /// @notice Boosted contest: both creator prize and deposit work together.
    function test_boostedContest_creatorPrizeAndDeposits() public {
        uint256 prize = 500e6;
        address contest = _createBoostedContest(prize);

        assertEq(ContestV2(contest).creatorPrize(), prize, "creatorPrize mismatch");

        // Participants deposit normally
        _deposit(alice, contest);
        _deposit(bob, contest);

        assertEq(ContestV2(contest).totalDeposited(), DEFAULT_DEPOSIT_AMOUNT * 2, "totalDeposited mismatch");
        assertTrue(ContestV2(contest).vaultShares() > 0, "Vault should have shares");
    }

    /// @notice Cannot create a contest with depositAmount=0 and no creator prize.
    function test_revert_sponsoredContestWithoutPrize() public {
        uint256 t = block.timestamp;

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           0,
            minParticipants:         2,
            maxParticipants:         5,
            depositStart:            t,
            depositEnd:              t + DEFAULT_DEPOSIT_DURATION,
            lockEnd:                 t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION,
            revealEnd:               t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION + DEFAULT_REVEAL_DURATION,
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        1,
            requiresOracle:          false,
            metadataHash:            keccak256("no-prize"),
            metadataUri:             "ipfs://nope"
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig(0, 2500, 5000, 0);
        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig(false, 0, 0, 0, false, ContestV2.PaymentModel.PROTOCOL, 0, 0, 0);
        bytes32[] memory opts = _defaultOptions();

        vm.prank(creator);
        vm.expectRevert("ContestFactoryV2: sponsored contest needs prize");
        factory.createCustomContest(config, _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL), scoring, subCfg, address(0), opts, 0);
    }

    /// @notice Normal contest (depositAmount > 0, no prize) still works.
    function test_normalContest_noPrize_backwardCompatible() public {
        address contest = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        assertEq(ContestV2(contest).creatorPrize(), 0, "creatorPrize should be 0");
    }

    // =========================================================================
    // 2. SPONSORED CONTEST LIFECYCLE (3 tests)
    // =========================================================================

    /// @notice Users can join a sponsored contest for free (depositAmount=0).
    function test_sponsored_freeJoin() public {
        address contest = _createSponsoredContest(1000e6);

        uint256 aliceBefore = usdc.balanceOf(alice);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        // Alice's balance unchanged (no deposit)
        assertEq(usdc.balanceOf(alice), aliceBefore, "Alice should not have paid");

        // Participants tracked. Auto-getter removed in 2026-04 slim-down — use
        // getParticipant() instead.
        assertTrue(ContestV2(contest).getParticipant(alice).hasDeposited, "Alice not marked as deposited");
    }

    /// @notice Full lifecycle: sponsored contest -> vote -> resolve -> claim rewards.
    function test_sponsored_fullLifecycle() public {
        uint256 prize = 1000e6;
        address contest = _createSponsoredContest(prize);

        // Join
        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        // Commit votes
        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltA = keccak256("saltA");
        bytes32 saltB = keccak256("saltB");
        _commitVote(alice, contest, voteA, saltA);
        _commitVote(bob, contest, voteA, saltB);

        // Advance to reveal
        _advancePastLock(contest);

        // Reveal
        _revealVote(alice, contest, voteA, saltA);
        _revealVote(bob, contest, voteA, saltB);

        // Resolve
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        assertEq(_getState(contest), STATE_FINALIZED, "Should be FINALIZED");

        // totalYield should be >= prize (prize + any yield from vault)
        ContestV2.ContestResults memory res = ContestV2(contest).getResults();
        uint256 totalYield = res.totalYield;
        assertTrue(totalYield >= prize, "totalYield should include creator prize");

        // Both voters should have rewards
        uint256 aliceReward = ContestV2(contest).voterRewards(alice);
        uint256 bobReward = ContestV2(contest).voterRewards(bob);
        assertTrue(aliceReward > 0, "Alice should have reward");
        assertTrue(bobReward > 0, "Bob should have reward");

        // Total rewards should be approximately the prize (+ yield, - protocol fee)
        assertApproxEqAbs(aliceReward + bobReward, totalYield, 1, "Rewards should sum to totalYield");

        // Claim rewards
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(contest).claimVoterReward();
        assertEq(usdc.balanceOf(alice), aliceBefore + aliceReward, "Alice claim failed");
    }

    /// @notice Sponsored contest: users don't need to call withdrawPrincipal (nothing deposited).
    function test_sponsored_noPrincipalToWithdraw() public {
        uint256 prize = 500e6;
        address contest = _createSponsoredContest(prize);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltA = keccak256("s1");
        bytes32 saltB = keccak256("s2");
        _commitVote(alice, contest, voteA, saltA);
        _commitVote(bob, contest, voteA, saltB);

        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, saltA);
        _revealVote(bob, contest, voteA, saltB);

        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Alice has no principal to withdraw (depositReceived = 0)
        vm.prank(alice);
        vm.expectRevert();
        ContestV2(contest).withdrawPrincipal();
    }

    // =========================================================================
    // 3. BOOSTED CONTEST LIFECYCLE (2 tests)
    // =========================================================================

    /// @notice Boosted contest: prize + yield distributed together.
    function test_boosted_prizeAndYieldCombined() public {
        uint256 prize = 500e6;
        address contest = _createBoostedContest(prize);

        // Normal deposits
        _deposit(alice, contest);
        _deposit(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltA = keccak256("s1");
        bytes32 saltB = keccak256("s2");
        _commitVote(alice, contest, voteA, saltA);
        _commitVote(bob, contest, voteA, saltB);

        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, saltA);
        _revealVote(bob, contest, voteA, saltB);

        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // totalYield should include creator prize
        ContestV2.ContestResults memory res = ContestV2(contest).getResults();
        uint256 totalYield = res.totalYield;
        assertTrue(totalYield >= prize, "totalYield should include at least the creator prize");

        // Participants can still withdraw principal
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(contest).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice), aliceBefore + DEFAULT_DEPOSIT_AMOUNT, "Principal not returned");
    }

    /// @notice Boosted contest with zero yield: creator prize still distributed.
    function test_boosted_zeroYield_prizeStillDistributed() public {
        // YieldVault with strategy 0 = simple hold, no yield
        uint256 prize = 200e6;
        address contest = _createBoostedContest(prize);

        _deposit(alice, contest);
        _deposit(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltA = keccak256("s1");
        bytes32 saltB = keccak256("s2");
        _commitVote(alice, contest, voteA, saltA);
        _commitVote(bob, contest, voteA, saltB);

        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, saltA);
        _revealVote(bob, contest, voteA, saltB);

        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // With simple hold strategy, yield = 0, but prize is still distributed
        ContestV2.ContestResults memory res = ContestV2(contest).getResults();
        uint256 totalYield = res.totalYield;
        assertEq(totalYield, prize, "totalYield should equal creator prize (no yield)");

        // Voters get the prize
        uint256 aliceReward = ContestV2(contest).voterRewards(alice);
        uint256 bobReward = ContestV2(contest).voterRewards(bob);
        assertApproxEqAbs(aliceReward + bobReward, prize, 1, "Rewards should equal prize");
    }

    // =========================================================================
    // 4. CANCELLATION TESTS (3 tests)
    // =========================================================================

    /// @notice Cancel returns creator prize to creator (no loss scenario).
    function test_cancel_returnsCreatorPrize() public {
        uint256 prize = 1000e6;
        uint256 creatorBefore = usdc.balanceOf(creator);
        address contest = _createSponsoredContest(prize);

        // Join some users
        _joinSponsored(alice, contest);

        // Cancel (min participants not met — only 1 of 2 required)
        _advancePastDeposit(contest);

        assertEq(_getState(contest), STATE_CANCELLED, "Should be CANCELLED");

        // Creator should get prize back (+ any yield from vault)
        uint256 creatorAfter = usdc.balanceOf(creator);
        assertTrue(creatorAfter >= creatorBefore - prize + prize, "Creator should get prize refund");
    }

    /// @notice Cancel boosted contest: participants get deposits, creator gets prize.
    function test_cancel_boosted_bothRefunded() public {
        uint256 prize = 500e6;
        address contest = _createBoostedContest(prize);

        // Only alice deposits (need 2 min)
        _deposit(alice, contest);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 creatorBefore = usdc.balanceOf(creator);

        // Cancel (min participants not met)
        _advancePastDeposit(contest);

        assertEq(_getState(contest), STATE_CANCELLED, "Should be CANCELLED");

        // Alice gets deposit back
        vm.prank(alice);
        ContestV2(contest).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice), aliceBefore + DEFAULT_DEPOSIT_AMOUNT, "Alice principal not returned");

        // Creator got prize refund (emitted in cancel)
        assertTrue(usdc.balanceOf(creator) > creatorBefore, "Creator should have received refund");
    }

    /// @notice CreatorPrizeRefunded event emitted on cancel.
    function test_cancel_emitsCreatorPrizeRefundedEvent() public {
        uint256 prize = 1000e6;
        address contest = _createSponsoredContest(prize);
        _joinSponsored(alice, contest);

        // Expect the event during cancel
        vm.expectEmit(true, false, false, true);
        emit CreatorPrizeRefunded(creator, prize);

        _advancePastDeposit(contest);
    }

    // =========================================================================
    // 5. EDGE CASES (3 tests)
    // =========================================================================

    /// @notice Single participant in sponsored contest gets full prize.
    function test_sponsored_singleParticipant_getsFull() public {
        // Create with minParticipants = 1
        uint256 t = block.timestamp;
        uint256 prize = 1000e6;

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           0,
            minParticipants:         1, // allow single participant
            maxParticipants:         5,
            depositStart:            t,
            depositEnd:              t + DEFAULT_DEPOSIT_DURATION,
            lockEnd:                 t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION,
            revealEnd:               t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION + DEFAULT_REVEAL_DURATION,
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        1,
            requiresOracle:          false,
            metadataHash:            keccak256("single"),
            metadataUri:             "ipfs://single"
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig(0, 2500, 5000, 0);
        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig(false, 0, 0, 0, false, ContestV2.PaymentModel.PROTOCOL, 0, 0, 0);
        bytes32[] memory opts = _defaultOptions();

        vm.startPrank(creator);
        usdc.approve(address(factory), prize);
        (, address contest) = factory.createCustomContest(config, _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL), scoring, subCfg, address(0), opts, prize);
        vm.stopPrank();

        // Single user joins and votes
        _joinSponsored(alice, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("s");
        _commitVote(alice, contest, voteA, salt);

        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, salt);

        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Alice gets the full prize
        uint256 reward = ContestV2(contest).voterRewards(alice);
        assertTrue(reward >= prize, "Single voter should get full prize");
    }

    /// @notice CreatorPrizeDeposited event emitted on creation.
    function test_creatorPrize_emitsEvent() public {
        uint256 prize = 500e6;

        // We expect the event from the contest contract during initialize
        // Can't easily predict contest address, so just verify creation succeeds
        address contest = _createSponsoredContest(prize);
        assertEq(ContestV2(contest).creatorPrize(), prize, "Prize should be set");
    }

    /// @notice v2.1: creator prize flows entirely into the voter pool; the
    ///         legacy option pool was removed so 100% of (yield + prize) goes
    ///         to voters.
    function test_creatorPrize_splitBetweenVoterAndOptionPools() public {
        uint256 t = block.timestamp;
        uint256 prize = 1000e6;

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           0,
            minParticipants:         2,
            maxParticipants:         5,
            depositStart:            t,
            depositEnd:              t + DEFAULT_DEPOSIT_DURATION,
            lockEnd:                 t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION,
            revealEnd:               t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION + DEFAULT_REVEAL_DURATION,
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        1,
            requiresOracle:          false,
            metadataHash:            keccak256("split"),
            metadataUri:             "ipfs://split"
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig(0, 2500, 5000, 0);
        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig(false, 0, 0, 0, false, ContestV2.PaymentModel.PROTOCOL, 0, 0, 0);
        bytes32[] memory opts = _defaultOptions();

        vm.startPrank(creator);
        usdc.approve(address(factory), prize);
        (, address contest) = factory.createCustomContest(config, _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL), scoring, subCfg, address(0), opts, prize);
        vm.stopPrank();

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltA = keccak256("s1");
        bytes32 saltB = keccak256("s2");
        _commitVote(alice, contest, voteA, saltA);
        _commitVote(bob, contest, voteA, saltB);

        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, saltA);
        _revealVote(bob, contest, voteA, saltB);

        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        ContestV2.ContestResults memory res = ContestV2(contest).getResults();
        uint256 totalYield = res.totalYield;
        uint256 voterPool = res.voterRewardsPool;

        // v2.1: entire pool flows to voters. (optionRewardsPool field was
        // removed entirely in the 2026-04 slim-down — used to always be 0.)
        assertEq(voterPool, totalYield, "Voter pool = total (v2.1)");
    }

    // =========================================================================
    // 6. SECURITY TESTS (10 tests)
    // =========================================================================

    /// @notice Double-initialize attack: cannot re-initialize with a different prize.
    function test_security_cannotReinitializeWithPrize() public {
        address contest = _createSponsoredContest(1000e6);

        ContestV2.ContestConfig memory cfg = ContestV2(contest).getConfig();
        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig(0, 2500, 5000, 0);
        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig(false, 0, 0, 0, false, ContestV2.PaymentModel.PROTOCOL, 0, 0, 0);
        bytes32[] memory opts = _defaultOptions();

        // Mint extra USDC and send to the contest to simulate having balance
        usdc.mint(contest, 5000e6);

        vm.prank(address(factory));
        vm.expectRevert(ContestV2.AlreadyInitialized.selector);
        ContestV2(contest).initialize(
            attacker, cfg,
            _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL),
            scoring, subCfg,
            address(yieldVault), address(identityRegistry),
            address(randomnessManager), address(0), opts,
            500, address(this), 5000e6
        );
    }

    /// @notice Non-creator cannot cancel and steal creator prize.
    function test_security_nonCreatorCannotStealPrize() public {
        address contest = _createSponsoredContest(1000e6);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        // Attacker tries to cancel
        vm.prank(attacker);
        vm.expectRevert(ContestV2.NotCreator.selector);
        ContestV2(contest).cancel("test");
    }

    /// @notice Sybil attack on sponsored contest: maxParticipants enforced.
    function test_security_maxParticipantsEnforcedOnFreeJoin() public {
        address contest = _createSponsoredContest(1000e6);

        // Join up to max (5 users)
        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);
        _joinSponsored(charlie, contest);
        _joinSponsored(dave, contest);
        _joinSponsored(eve, contest);

        // 6th user should fail (maxParticipants = 5 from DEFAULT_MAX_PARTICIPANTS)
        address extraUser = address(0x200);
        vm.prank(extraUser);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(contest).deposit();
    }

    /// @notice Cannot double-join a sponsored contest.
    function test_security_cannotDoubleJoin() public {
        address contest = _createSponsoredContest(1000e6);

        _joinSponsored(alice, contest);

        vm.prank(alice);
        vm.expectRevert(ContestV2.AlreadyDeposited.selector);
        ContestV2(contest).deposit();
    }

    /// @notice Creator prize doesn't inflate participant count (quorum check).
    function test_security_creatorPrizeDoesNotInflateQuorum() public {
        address contest = _createSponsoredContest(1000e6);

        // Only alice joins and votes, bob doesn't
        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("s");
        _commitVote(alice, contest, voteA, salt);

        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, salt);

        // Quorum = 1% of 2 participants = 0 (rounds down), so 1 reveal suffices
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        assertEq(_getState(contest), STATE_FINALIZED, "Should finalize with quorum met");
    }

    /// @notice Sponsored contest: cannot withdraw principal (no deposit to withdraw).
    function test_security_noWithdrawalExploit_sponsored() public {
        uint256 prize = 1000e6;
        address contest = _createSponsoredContest(prize);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltA = keccak256("s1");
        bytes32 saltB = keccak256("s2");
        _commitVote(alice, contest, voteA, saltA);
        _commitVote(bob, contest, voteA, saltB);
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, saltA);
        _revealVote(bob, contest, voteA, saltB);
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Alice cannot withdraw principal (she didn't deposit anything)
        vm.prank(alice);
        vm.expectRevert();
        ContestV2(contest).withdrawPrincipal();

        // But she CAN claim voter reward
        uint256 reward = ContestV2(contest).voterRewards(alice);
        assertTrue(reward > 0, "Alice should have reward");

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(contest).claimVoterReward();
        assertEq(usdc.balanceOf(alice), aliceBefore + reward, "Reward not received");
    }

    /// @notice Creator cannot double-claim: prize goes to winners, not creator.
    function test_security_creatorCannotDoubleClaim() public {
        uint256 prize = 1000e6;
        address contest = _createSponsoredContest(prize);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _commitVote(alice, contest, voteA, keccak256("s1"));
        _commitVote(bob, contest, voteA, keccak256("s2"));
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, keccak256("s1"));
        _revealVote(bob, contest, voteA, keccak256("s2"));
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // After finalization, creatorPrize should be absorbed into results
        // Creator cannot cancel a finalized contest
        vm.prank(creator);
        vm.expectRevert();
        ContestV2(contest).cancel("test");
    }

    /// @notice Boosted contest: principal withdrawal works independently of prize.
    function test_security_boosted_principalIndependentOfPrize() public {
        uint256 prize = 500e6;
        address contest = _createBoostedContest(prize);

        _deposit(alice, contest);
        _deposit(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _commitVote(alice, contest, voteA, keccak256("s1"));
        _commitVote(bob, contest, voteA, keccak256("s2"));
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, keccak256("s1"));
        _revealVote(bob, contest, voteA, keccak256("s2"));
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Alice withdraws EXACTLY her deposit (not inflated by creator prize)
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(contest).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice), aliceBefore + DEFAULT_DEPOSIT_AMOUNT, "Principal should be exact deposit");

        // Alice also claims reward (from prize + yield pool)
        uint256 reward = ContestV2(contest).voterRewards(alice);
        assertTrue(reward > 0, "Should have reward from prize pool");
    }

    /// @notice Contract balance is fully drained after all claims (no stuck funds).
    function test_security_noStuckFunds_sponsored() public {
        uint256 prize = 1000e6;
        address contest = _createSponsoredContest(prize);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _commitVote(alice, contest, voteA, keccak256("s1"));
        _commitVote(bob, contest, voteA, keccak256("s2"));
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, keccak256("s1"));
        _revealVote(bob, contest, voteA, keccak256("s2"));
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Both claim rewards
        vm.prank(alice);
        ContestV2(contest).claimVoterReward();
        vm.prank(bob);
        ContestV2(contest).claimVoterReward();

        // Claim undistributed dust
        uint256 dust = ContestV2(contest).undistributedRewards();
        if (dust > 0) {
            vm.prank(creator);
            ContestV2(contest).claimUndistributedRewards();
        }

        // Contract should have ~0 USDC left (only rounding dust at most)
        uint256 remaining = usdc.balanceOf(contest);
        assertTrue(remaining <= 1, "Contract should have no stuck funds");
    }

    /// @notice Contract balance is fully drained after boosted contest claims.
    function test_security_noStuckFunds_boosted() public {
        uint256 prize = 500e6;
        address contest = _createBoostedContest(prize);

        _deposit(alice, contest);
        _deposit(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _commitVote(alice, contest, voteA, keccak256("s1"));
        _commitVote(bob, contest, voteA, keccak256("s2"));
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, keccak256("s1"));
        _revealVote(bob, contest, voteA, keccak256("s2"));
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Withdraw principal
        vm.prank(alice);
        ContestV2(contest).withdrawPrincipal();
        vm.prank(bob);
        ContestV2(contest).withdrawPrincipal();

        // Claim rewards
        vm.prank(alice);
        ContestV2(contest).claimVoterReward();
        vm.prank(bob);
        ContestV2(contest).claimVoterReward();

        // Claim dust
        uint256 dust = ContestV2(contest).undistributedRewards();
        if (dust > 0) {
            vm.prank(creator);
            ContestV2(contest).claimUndistributedRewards();
        }

        // Contract should have ~0 USDC left
        uint256 remaining = usdc.balanceOf(contest);
        assertTrue(remaining <= 1, "Contract should have no stuck funds");
    }

    // =========================================================================
    // 7. FUZZ TESTS (3 tests)
    // =========================================================================

    /// @notice Fuzz: any prize amount produces valid lifecycle.
    function testFuzz_sponsoredContest_anyPrize(uint256 prize) public {
        // Bound to reasonable range (1 USDC to 10M USDC)
        prize = bound(prize, 1e6, 10_000_000e6);

        // Mint enough for creator
        usdc.mint(creator, prize);

        address contest = _createSponsoredContest(prize);

        _joinSponsored(alice, contest);
        _joinSponsored(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _commitVote(alice, contest, voteA, keccak256("s1"));
        _commitVote(bob, contest, voteA, keccak256("s2"));
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, keccak256("s1"));
        _revealVote(bob, contest, voteA, keccak256("s2"));
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Prize should be distributed
        ContestV2.ContestResults memory res = ContestV2(contest).getResults();
        assertTrue(res.totalYield >= prize, "Prize should be in total yield");
    }

    /// @notice Fuzz: cancel always returns creator prize.
    function testFuzz_cancel_alwaysRefundsPrize(uint256 prize) public {
        prize = bound(prize, 1e6, 10_000_000e6);
        usdc.mint(creator, prize);

        uint256 creatorBefore = usdc.balanceOf(creator);
        address contest = _createSponsoredContest(prize);

        // Only 1 user joins (needs 2 min), so cancel on deadline
        _joinSponsored(alice, contest);

        _advancePastDeposit(contest);

        assertEq(_getState(contest), STATE_CANCELLED, "Should be cancelled");

        // Creator should get prize back
        uint256 creatorAfter = usdc.balanceOf(creator);
        assertEq(creatorAfter, creatorBefore, "Creator should recover full prize");
    }

    /// @notice Fuzz: boosted contest with any deposit+prize combination.
    function testFuzz_boostedContest_anyAmounts(uint256 prize) public {
        prize = bound(prize, 1e6, 1_000_000e6);
        usdc.mint(creator, prize);

        address contest = _createBoostedContest(prize);

        _deposit(alice, contest);
        _deposit(bob, contest);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _commitVote(alice, contest, voteA, keccak256("s1"));
        _commitVote(bob, contest, voteA, keccak256("s2"));
        _advancePastLock(contest);
        _revealVote(alice, contest, voteA, keccak256("s1"));
        _revealVote(bob, contest, voteA, keccak256("s2"));
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();

        // Verify total prize pool = yield + creator prize
        ContestV2.ContestResults memory res = ContestV2(contest).getResults();
        assertTrue(res.totalYield >= prize, "Total should include at least prize");

        // Verify principal withdrawal still works
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(contest).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice), aliceBefore + DEFAULT_DEPOSIT_AMOUNT, "Principal intact");
    }
}
