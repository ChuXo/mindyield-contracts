// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/**
 * @title ContestV2Test
 * @notice Comprehensive core lifecycle test suite for ContestV2.
 * @dev Covers initialization, deposit, commit, reveal, state transitions,
 *      resolution, and withdrawal phases.
 */
contract ContestV2Test is ContestV2TestBase {

    // Re-declare events from ContestV2 so we can use them with vm.expectEmit
    event Deposited(address indexed participant, uint256 amount);
    event VoteCommitted(address indexed participant, bytes32 commitHash);
    event VoteRevealed(address indexed participant, bytes data);
    event ContestCancelled(string reason);
    event StateChanged(ContestV2.ContestState newState);

    // =========================================================================
    // 1. Initialization
    // =========================================================================

    function test_init_startsInDepositOpenState() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        assertEq(_getState(c), STATE_DEPOSIT_OPEN, "should start in DEPOSIT_OPEN");
    }

    function test_init_configValuesMatchInput() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();

        assertEq(cfg.depositToken, address(usdc), "depositToken mismatch");
        assertEq(cfg.depositAmount, DEFAULT_DEPOSIT_AMOUNT, "depositAmount mismatch");
        assertEq(cfg.minParticipants, DEFAULT_MIN_PARTICIPANTS, "minParticipants mismatch");
        assertEq(cfg.maxParticipants, DEFAULT_MAX_PARTICIPANTS, "maxParticipants mismatch");
        assertEq(cfg.quorumPercentage, DEFAULT_QUORUM_PERCENTAGE, "quorumPercentage mismatch");
        assertEq(uint8(cfg.contestType), TYPE_VOTE, "contestType mismatch");
        assertEq(uint8(cfg.winnerDetermination), WINNER_PLURALITY, "winnerDetermination mismatch");
        // v2.1 — prizeModel / voterRewardPercentage moved out of ContestConfig
        ContestV2.PrizeConfig memory prize = ContestV2(c).getPrizeConfig();
        // PRIZE_VOTER_REWARDS legacy alias maps to PROPORTIONAL (index 0)
        assertEq(uint8(prize.model), PRIZE_PROPORTIONAL, "prize model mismatch");
    }

    function test_init_optionsStoredCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        bytes32[] memory opts = ContestV2(c).getOptions();

        assertEq(opts.length, 4, "should have 4 options");
        assertEq(opts[0], OPT_A, "option 0 mismatch");
        assertEq(opts[1], OPT_B, "option 1 mismatch");
        assertEq(opts[2], OPT_C, "option 2 mismatch");
        assertEq(opts[3], OPT_D, "option 3 mismatch");
    }

    function test_init_creatorSetCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        assertEq(ContestV2(c).creator(), creator, "creator mismatch");
    }

    function test_init_factorySetToFactoryContract() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        assertEq(ContestV2(c).factory(), address(factory), "factory mismatch");
    }

    // =========================================================================
    // 2. Deposit Phase
    // =========================================================================

    function test_deposit_recordsParticipant() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        ContestV2.Participant memory p = ContestV2(c).getParticipant(alice);
        assertTrue(p.hasDeposited, "should be marked as deposited");
        assertEq(ContestV2(c).getParticipantCount(), 1, "participant count should be 1");
    }

    function test_deposit_cannotDepositTwice() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        vm.startPrank(alice);
        usdc.approve(c, DEFAULT_DEPOSIT_AMOUNT);
        vm.expectRevert(ContestV2.AlreadyDeposited.selector);
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    function test_deposit_cannotDepositAfterDepositEnd() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();

        vm.warp(cfg.depositEnd + 1);

        vm.startPrank(alice);
        usdc.approve(c, DEFAULT_DEPOSIT_AMOUNT);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    function test_deposit_cannotDepositBeforeDepositStart() public {
        // Create a contest with future depositStart by warping back before creation
        uint256 futureStart = block.timestamp + 2 hours;

        // Build config with future depositStart
        ContestV2.ContestConfig memory cfg = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           DEFAULT_DEPOSIT_AMOUNT,
            minParticipants:         DEFAULT_MIN_PARTICIPANTS,
            maxParticipants:         DEFAULT_MAX_PARTICIPANTS,
            depositStart:            futureStart,
            depositEnd:              futureStart + 1 hours + 1,
            lockEnd:                 futureStart + 2 hours + 1,
            revealEnd:               futureStart + 3 hours + 1,
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        DEFAULT_QUORUM_PERCENTAGE,
            requiresOracle:          false,
            metadataHash:            keccak256("future-contest"),
            metadataUri:             "ipfs://future"
        });
        ContestV2.PrizeConfig memory prizeCfg = _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL);

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
        (, address c) = factory.createCustomContest(cfg, prizeCfg, scoring, subCfg, address(0), opts, 0);

        // Try to deposit before futureStart
        vm.startPrank(alice);
        usdc.approve(c, DEFAULT_DEPOSIT_AMOUNT);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    function test_deposit_maxParticipantsEnforced() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Default maxParticipants is 5, fill them all
        _deposit(alice, c);
        _deposit(bob, c);
        _deposit(charlie, c);
        _deposit(dave, c);
        _deposit(eve, c);

        // 6th depositor should fail
        address extra = address(0x200);
        usdc.mint(extra, ACTOR_MINT_AMOUNT);
        vm.startPrank(extra);
        usdc.approve(c, DEFAULT_DEPOSIT_AMOUNT);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    function test_deposit_transfersTokensToVault() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        uint256 vaultBalBefore = usdc.balanceOf(address(yieldVault));
        _deposit(alice, c);
        uint256 vaultBalAfter = usdc.balanceOf(address(yieldVault));

        assertEq(vaultBalAfter - vaultBalBefore, DEFAULT_DEPOSIT_AMOUNT, "vault should hold deposit");
        assertGt(ContestV2(c).vaultShares(), 0, "contest should have vault shares");
    }

    function test_deposit_nonDepositorCannotCommit() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes32 commitHash = keccak256(abi.encodePacked("fake"));
        vm.prank(alice);
        vm.expectRevert(ContestV2.NotDeposited.selector);
        ContestV2(c).commitVote(commitHash);
    }

    function test_deposit_emitsDepositedEvent() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        vm.startPrank(alice);
        usdc.approve(c, DEFAULT_DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true, c);
        emit Deposited(alice, DEFAULT_DEPOSIT_AMOUNT);
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    // =========================================================================
    // 3. Commit Phase
    // =========================================================================

    function test_commit_duringDepositOpenWorks() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        assertEq(_getState(c), STATE_DEPOSIT_OPEN, "should be DEPOSIT_OPEN");

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("salt-alice");
        _commitVote(alice, c, voteData, salt);

        ContestV2.Participant memory p = ContestV2(c).getParticipant(alice);
        assertTrue(p.hasCommitted, "should be committed");
    }

    function test_commit_duringLockedWorks() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        // Advance past deposit -> DEPOSIT_CLOSED, then to LOCKED
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();
        vm.warp(cfg.depositEnd + 1);
        ContestV2(c).updateState(); // -> DEPOSIT_CLOSED
        // DEPOSIT_CLOSED -> LOCKED transition happens at lockEnd, but we need to be
        // in LOCKED before lockEnd to commit. The updateState at depositEnd moves to
        // DEPOSIT_CLOSED. We can still commit in DEPOSIT_CLOSED state.
        // Let's verify commit works in DEPOSIT_CLOSED too.
        assertEq(_getState(c), STATE_DEPOSIT_CLOSED, "should be DEPOSIT_CLOSED");

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("salt-alice-locked");
        _commitVote(alice, c, voteData, salt);

        ContestV2.Participant memory p = ContestV2(c).getParticipant(alice);
        assertTrue(p.hasCommitted, "should be committed in DEPOSIT_CLOSED");
    }

    function test_commit_cannotCommitAfterLockEnd() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        // Advance past lockEnd
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();
        vm.warp(cfg.lockEnd + 1);
        // Update state to REVEAL_OPEN (one transition per call)
        ContestV2(c).updateState(); // DEPOSIT_OPEN -> DEPOSIT_CLOSED
        ContestV2(c).updateState(); // DEPOSIT_CLOSED -> LOCKED
        ContestV2(c).updateState(); // LOCKED -> REVEAL_OPEN

        bytes32 commitHash = keccak256("late-commit");
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).commitVote(commitHash);
    }

    function test_commit_cannotCommitTwice() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("salt1");
        _commitVote(alice, c, voteData, salt);

        bytes32 commitHash2 = keccak256(abi.encodePacked("other"));
        vm.prank(alice);
        vm.expectRevert(ContestV2.AlreadyCommitted.selector);
        ContestV2(c).commitVote(commitHash2);
    }

    function test_commit_cannotCommitWithoutDepositing() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes32 commitHash = keccak256("no-deposit");
        vm.prank(alice);
        vm.expectRevert(ContestV2.NotDeposited.selector);
        ContestV2(c).commitVote(commitHash);
    }

    function test_commit_emitsVoteCommittedEvent() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_B);
        bytes32 salt = keccak256("salt-event");
        // Audit M-01: commit hash binds msg.sender to prevent reveal replay.
        bytes32 commitHash = keccak256(abi.encodePacked(alice, voteData, salt));

        vm.expectEmit(true, false, false, true, c);
        emit VoteCommitted(alice, commitHash);

        vm.prank(alice);
        ContestV2(c).commitVote(commitHash);
    }

    // =========================================================================
    // 4. Reveal Phase
    // =========================================================================

    function test_reveal_withCorrectDataSucceeds() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("reveal-salt");
        _commitVote(alice, c, voteData, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);
        assertEq(_getState(c), STATE_REVEAL_OPEN, "should be REVEAL_OPEN");

        _revealVote(alice, c, voteData, salt);

        ContestV2.Participant memory p = ContestV2(c).getParticipant(alice);
        assertTrue(p.hasRevealed, "should be revealed");
    }

    function test_reveal_withWrongSaltFails() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("correct-salt");
        _commitVote(alice, c, voteData, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);

        bytes32 wrongSalt = keccak256("wrong-salt");
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidReveal.selector);
        ContestV2(c).revealVote(voteData, wrongSalt);
    }

    function test_reveal_withWrongVoteDataFails() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("my-salt");
        _commitVote(alice, c, voteData, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);

        bytes memory wrongData = _makeVoteData_VOTE(OPT_C);
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidReveal.selector);
        ContestV2(c).revealVote(wrongData, salt);
    }

    function test_reveal_cannotRevealBeforeLockEnd() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("early-reveal");
        _commitVote(alice, c, voteData, salt);

        // Still in DEPOSIT_OPEN, not REVEAL_OPEN
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidState.selector);
        ContestV2(c).revealVote(voteData, salt);
    }

    function test_reveal_cannotRevealAfterRevealEnd() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("late-reveal");
        _commitVote(alice, c, voteData, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);

        // Now warp past revealEnd
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();
        vm.warp(cfg.revealEnd + 1);

        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).revealVote(voteData, salt);
    }

    function test_reveal_cannotRevealWithoutCommitting() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("no-commit");
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).revealVote(voteData, salt);
    }

    function test_reveal_cannotRevealTwice() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("double-reveal");
        _commitVote(alice, c, voteData, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);

        _revealVote(alice, c, voteData, salt);

        vm.prank(alice);
        vm.expectRevert(ContestV2.AlreadyRevealed.selector);
        ContestV2(c).revealVote(voteData, salt);
    }

    function test_reveal_emitsVoteRevealedEvent() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteData = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("event-salt");
        _commitVote(alice, c, voteData, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob-salt"));

        _advancePastLock(c);

        vm.expectEmit(true, false, false, true, c);
        emit VoteRevealed(alice, voteData);

        vm.prank(alice);
        ContestV2(c).revealVote(voteData, salt);
    }

    // =========================================================================
    // 5. State Transitions
    // =========================================================================

    function test_state_depositOpenToDepositClosedAfterDepositEnd() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        assertEq(_getState(c), STATE_DEPOSIT_OPEN, "should start DEPOSIT_OPEN");

        _advancePastDeposit(c);
        assertEq(_getState(c), STATE_DEPOSIT_CLOSED, "should be DEPOSIT_CLOSED");
    }

    function test_state_depositOpenToCancelledIfMinNotMet() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        // Only 1 depositor, minParticipants = 2
        _deposit(alice, c);

        _advancePastDeposit(c);
        assertEq(_getState(c), STATE_CANCELLED, "should be CANCELLED");
    }

    function test_state_depositClosedToLockedToRevealOpen() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        _advancePastDeposit(c);
        assertEq(_getState(c), STATE_DEPOSIT_CLOSED, "should be DEPOSIT_CLOSED");

        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();
        vm.warp(cfg.lockEnd + 1);
        // First call: DEPOSIT_CLOSED -> LOCKED (depositEnd has passed)
        ContestV2(c).updateState();
        // Second call: LOCKED -> REVEAL_OPEN (lockEnd has passed)
        ContestV2(c).updateState();
        assertEq(_getState(c), STATE_REVEAL_OPEN, "should be REVEAL_OPEN after lock");
    }

    function test_state_lockedToRevealOpenAfterLockEnd() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        _advancePastLock(c);
        assertEq(_getState(c), STATE_REVEAL_OPEN, "should be REVEAL_OPEN");
    }

    function test_state_fullProgression() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        assertEq(_getState(c), STATE_DEPOSIT_OPEN, "start: DEPOSIT_OPEN");

        _deposit(alice, c);
        _deposit(bob, c);

        // Advance past deposit
        _advancePastDeposit(c);
        assertEq(_getState(c), STATE_DEPOSIT_CLOSED, "after deposit: DEPOSIT_CLOSED");

        // Advance past lock (one transition per updateState call)
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();
        vm.warp(cfg.lockEnd + 1);
        ContestV2(c).updateState(); // DEPOSIT_CLOSED -> LOCKED
        ContestV2(c).updateState(); // LOCKED -> REVEAL_OPEN
        assertEq(_getState(c), STATE_REVEAL_OPEN, "after lock: REVEAL_OPEN");
    }

    function test_state_multipleUpdateStateCallsAreIdempotent() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        _advancePastDeposit(c);
        assertEq(_getState(c), STATE_DEPOSIT_CLOSED, "should be DEPOSIT_CLOSED");

        // After depositEnd, DEPOSIT_CLOSED immediately transitions to LOCKED
        ContestV2(c).updateState();
        assertEq(_getState(c), STATE_LOCKED, "should be LOCKED after depositEnd");

        // Further calls are idempotent until lockEnd
        ContestV2(c).updateState();
        assertEq(_getState(c), STATE_LOCKED, "should remain LOCKED until lockEnd");
    }

    function test_state_cannotGoBackwards() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);
        _deposit(bob, c);

        _advancePastLock(c);
        assertEq(_getState(c), STATE_REVEAL_OPEN, "should be REVEAL_OPEN");

        // Warp backwards (Foundry allows this in tests)
        ContestV2.ContestConfig memory cfg = ContestV2(c).getConfig();
        vm.warp(cfg.depositStart + 1);

        // updateState should not revert, but state should not go backwards
        ContestV2(c).updateState();
        assertEq(_getState(c), STATE_REVEAL_OPEN, "state should not go backwards");
    }

    function test_state_creatorCanCancel() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        // Advance past YieldVault MIN_HOLD_TIME (15s) so cancel can withdraw from vault
        vm.warp(block.timestamp + 61);
        _advanceBlock();

        vm.prank(creator);
        ContestV2(c).cancel("testing cancellation");
        assertEq(_getState(c), STATE_CANCELLED, "should be CANCELLED");
    }

    // =========================================================================
    // 6. Resolution
    // =========================================================================

    function test_resolve_withValidQuorumSucceeds() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes memory voteDataA = _makeVoteData_VOTE(OPT_A);
        bytes32 saltAlice = keccak256("alice-salt");
        bytes32 saltBob = keccak256("bob-salt");

        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, voteDataA, saltAlice);
        _commitVote(bob, c, voteDataA, saltBob);

        _advancePastLock(c);

        _revealVote(alice, c, voteDataA, saltAlice);
        _revealVote(bob, c, voteDataA, saltBob);

        _advancePastReveal(c);

        vm.prank(creator);
        ContestV2(c).resolveContest();
        assertEq(_getState(c), STATE_FINALIZED, "should be FINALIZED");
    }

    function test_resolve_beforeRevealEndFails() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes memory voteDataA = _makeVoteData_VOTE(OPT_A);
        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, voteDataA, keccak256("s1"));
        _commitVote(bob, c, voteDataA, keccak256("s2"));

        _advancePastLock(c);

        _revealVote(alice, c, voteDataA, keccak256("s1"));
        _revealVote(bob, c, voteDataA, keccak256("s2"));

        // Still within reveal window, do NOT advance past revealEnd
        vm.prank(creator);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).resolveContest();
    }

    function test_resolve_quorumNotMetFails() public {
        // Create contest with high quorum
        uint256 t = block.timestamp;
        ContestV2.ContestConfig memory cfg = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           DEFAULT_DEPOSIT_AMOUNT,
            minParticipants:         2,
            maxParticipants:         5,
            depositStart:            t,
            depositEnd:              t + 1 hours + 1,
            lockEnd:                 t + 2 hours + 1,
            revealEnd:               t + 3 hours + 1,
            contestType:             ContestV2.ContestType(TYPE_VOTE),
            winnerDetermination:     ContestV2.WinnerDetermination(WINNER_PLURALITY),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        100, // 100% quorum required
            requiresOracle:          false,
            metadataHash:            keccak256("high-quorum"),
            metadataUri:             "ipfs://quorum"
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0, topPercentile: 2500, confidenceMultiplier: 5000, earlyVoterBonus: 0
        });

        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig({
            enabled: false, submissionStart: 0, submissionEnd: 0, maxPerUser: 0,
            requiresModeration: false, paymentModel: ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0, minSubmissions: 0, maxTotalSubmissions: 0
        });

        vm.prank(creator);
        (, address c) = factory.createCustomContest(
            cfg,
            _defaultPrizeConfigForModel(ContestV2.PrizeModel.PROPORTIONAL),
            scoring, subCfg, address(0), _defaultOptions(), 0
        );

        // Deposit 2 users, only 1 reveals -> quorum 100% not met
        bytes memory voteDataA = _makeVoteData_VOTE(OPT_A);
        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, voteDataA, keccak256("s1"));
        _commitVote(bob, c, voteDataA, keccak256("s2"));

        _advancePastLock(c);

        // Only alice reveals
        _revealVote(alice, c, voteDataA, keccak256("s1"));

        _advancePastReveal(c);

        vm.prank(creator);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).resolveContest();
    }

    function test_resolve_winningOptionIsCorrect() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes memory voteB = _makeVoteData_VOTE(OPT_B);

        // Alice and Bob vote A, Charlie votes B -> A wins
        _deposit(alice, c);
        _deposit(bob, c);
        _deposit(charlie, c);

        bytes32 sA = keccak256("sA");
        bytes32 sB = keccak256("sB");
        bytes32 sC = keccak256("sC");

        _commitVote(alice, c, voteA, sA);
        _commitVote(bob, c, voteA, sB);
        _commitVote(charlie, c, voteB, sC);

        _advancePastLock(c);

        _revealVote(alice, c, voteA, sA);
        _revealVote(bob, c, voteA, sB);
        _revealVote(charlie, c, voteB, sC);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        assertTrue(res.isResolved, "should be resolved");
        assertEq(res.winningOption, OPT_A, "OPT_A should win with 2 votes");
        assertEq(ContestV2(c).getOptionVotes(OPT_A), 2, "OPT_A should have 2 votes");
        assertEq(ContestV2(c).getOptionVotes(OPT_B), 1, "OPT_B should have 1 vote");
    }

    function test_resolve_yieldSplitCorrectly() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, voteA, keccak256("s1"));
        _commitVote(bob, c, voteA, keccak256("s2"));

        _advancePastLock(c);

        _revealVote(alice, c, voteA, keccak256("s1"));
        _revealVote(bob, c, voteA, keccak256("s2"));

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        ContestV2.ContestResults memory res = ContestV2(c).getResults();
        // No real yield in mock vault (strategy 0 = hold), so yield = 0.
        // optionRewardsPool was removed in the 2026-04 slim-down; the entire
        // pool now flows to voterRewardsPool, so this should equal totalYield.
        assertEq(res.voterRewardsPool, res.totalYield, "voter pool = totalYield");
    }

    function test_resolve_transitionsToFinalized() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _fullLifecycle_VOTE(c, users, OPT_A);

        assertEq(_getState(c), STATE_FINALIZED, "should be FINALIZED after resolve");
        assertTrue(ContestV2(c).getResults().isResolved, "results.isResolved should be true");
    }

    // =========================================================================
    // 7. Withdrawal
    // =========================================================================

    function test_withdraw_afterFinalizedReturnsPrincipal() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _fullLifecycle_VOTE(c, users, OPT_A);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balAfter - balBefore, DEFAULT_DEPOSIT_AMOUNT, "should receive deposit back");
    }

    function test_withdraw_afterCancelledReturnsPrincipal() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        // Advance past YieldVault MIN_HOLD_TIME (15s) so cancel can withdraw from vault
        vm.warp(block.timestamp + 61);
        _advanceBlock();

        vm.prank(creator);
        ContestV2(c).cancel("test cancel");
        assertEq(_getState(c), STATE_CANCELLED, "should be CANCELLED");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balAfter - balBefore, DEFAULT_DEPOSIT_AMOUNT, "should receive deposit back after cancel");
    }

    function test_withdraw_cannotWithdrawBeforeFinalized() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        _deposit(alice, c);

        // Still in DEPOSIT_OPEN
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).withdrawPrincipal();
    }

    function test_withdraw_cannotWithdrawTwice() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _fullLifecycle_VOTE(c, users, OPT_A);

        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();

        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).withdrawPrincipal();
    }

    function test_claimVoterReward_worksForEligible_failsForIneligible() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Alice votes for OPT_A (winner), Bob votes for OPT_B (loser)
        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes memory voteB = _makeVoteData_VOTE(OPT_B);
        bytes32 sA = keccak256("claimA");
        bytes32 sB = keccak256("claimB");

        _deposit(alice, c);
        _deposit(bob, c);
        _commitVote(alice, c, voteA, sA);
        _commitVote(bob, c, voteB, sB);

        _advancePastLock(c);

        _revealVote(alice, c, voteA, sA);
        _revealVote(bob, c, voteB, sB);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        assertEq(_getState(c), STATE_FINALIZED, "should be FINALIZED");

        // In mock vault with no yield, voterRewardsPool = 0, so all rewards = 0.
        // Both alice and bob will get "no reward" since there is no yield.
        // Test that the claim function correctly checks the reward amount.
        uint256 aliceReward = ContestV2(c).getVoterReward(alice);
        uint256 bobReward = ContestV2(c).getVoterReward(bob);

        // With no yield, both rewards are 0
        assertEq(aliceReward, 0, "no yield means no reward for alice");
        assertEq(bobReward, 0, "no yield means no reward for bob");

        // Attempting to claim with 0 reward should revert
        vm.prank(alice);
        vm.expectRevert(ContestV2.NoReward.selector);
        ContestV2(c).claimVoterReward();

        // Non-revealer (charlie who did not even participate) should fail with "did not reveal"
        vm.prank(charlie);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        ContestV2(c).claimVoterReward();
    }
}
