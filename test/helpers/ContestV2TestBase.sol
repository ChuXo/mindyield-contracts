// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/ContestV2.sol";
import "../../src/ContestFactoryV2.sol";
import "../../src/YieldVault.sol";
import "../../src/IdentityRegistry.sol";
import "../../src/mocks/MockRandomnessManager.sol";
import "../../src/mocks/MockERC20.sol";

/**
 * @title ContestV2TestBase
 * @notice Shared test base for all ContestV2 tests.
 *
 * Deploys the full stack (MockERC20, YieldVault, IdentityRegistry,
 * MockRandomnessManager, ContestV2 implementation, ContestFactoryV2)
 * and provides helper functions for creating contests, depositing,
 * committing/revealing votes, advancing time, and running full
 * lifecycle scenarios.
 *
 * Inherit from this contract in your test files:
 *
 *   contract MyTest is ContestV2TestBase {
 *       function test_example() public {
 *           address contest = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
 *           _deposit(alice, contest);
 *           ...
 *       }
 *   }
 */
abstract contract ContestV2TestBase is Test {

    // =========================================================================
    // Contest creation nonce (ensures unique metadataHash per contest)
    // =========================================================================
    uint256 internal _contestNonce;

    // =========================================================================
    // Block counter (workaround: vm.roll(block.number+1) doesn't persist in
    // Foundry test scripts, so we track block numbers explicitly)
    // =========================================================================
    uint256 internal _nextBlock = 100;

    /// @dev Advance to the next block. Uses an internal counter instead of
    ///      block.number+1 because Foundry's test-level block.number may not
    ///      reflect previous vm.roll() calls.
    function _advanceBlock() internal {
        vm.roll(_nextBlock++);
    }

    // =========================================================================
    // Deployed contracts
    // =========================================================================

    MockERC20            public usdc;
    YieldVault           public yieldVault;
    IdentityRegistry     public identityRegistry;
    MockRandomnessManager public randomnessManager;
    ContestV2            public contestImpl;
    ContestFactoryV2     public factory;

    // =========================================================================
    // Actors
    // =========================================================================

    address public creator  = address(0x100);
    address public alice    = address(0x101);
    address public bob      = address(0x102);
    address public charlie  = address(0x103);
    address public dave     = address(0x104);
    address public eve      = address(0x105);
    address public attacker = address(0x666);
    address public oracle   = address(0x999);

    /// @notice Convenience array of the five standard users (alice..eve).
    address[] internal _users;

    // =========================================================================
    // Predefined vote options
    // =========================================================================

    bytes32 public constant OPT_A = keccak256("Option_A");
    bytes32 public constant OPT_B = keccak256("Option_B");
    bytes32 public constant OPT_C = keccak256("Option_C");
    bytes32 public constant OPT_D = keccak256("Option_D");

    // =========================================================================
    // Enum shortcuts (matching ContestV2 enums for readability)
    // =========================================================================

    // --- ContestType ---
    uint8 public constant TYPE_VOTE     = 0;
    uint8 public constant TYPE_RANK     = 1;
    uint8 public constant TYPE_RATE     = 2;
    uint8 public constant TYPE_PREDICT  = 3;
    uint8 public constant TYPE_PAIRWISE = 4;

    // --- ContestState ---
    uint8 public constant STATE_CREATED           = 0;
    uint8 public constant STATE_SUBMISSION_OPEN    = 1;
    uint8 public constant STATE_SUBMISSION_CLOSED  = 2;
    uint8 public constant STATE_DEPOSIT_OPEN       = 3;
    uint8 public constant STATE_DEPOSIT_CLOSED     = 4;
    uint8 public constant STATE_LOCKED             = 5;
    uint8 public constant STATE_REVEAL_OPEN        = 6;
    uint8 public constant STATE_RESOLVING          = 7;
    uint8 public constant STATE_FINALIZED          = 8;
    uint8 public constant STATE_CANCELLED          = 9;

    // --- WinnerDetermination ---
    uint8 public constant WINNER_PLURALITY        = 0;
    uint8 public constant WINNER_MAJORITY         = 1;
    uint8 public constant WINNER_RANKED_CHOICE    = 2;
    uint8 public constant WINNER_BORDA_COUNT      = 3;
    uint8 public constant WINNER_WEIGHTED_AVERAGE = 4;
    uint8 public constant WINNER_ORACLE           = 5;
    uint8 public constant WINNER_THRESHOLD        = 6;
    uint8 public constant WINNER_CONSENSUS        = 7;

    // --- PrizeModel (updated 2026-04-14: new 5-mode taxonomy) ---
    uint8 public constant PRIZE_PROPORTIONAL   = 0;
    uint8 public constant PRIZE_SINGLE_TOP     = 1;
    uint8 public constant PRIZE_SINGLE_RANDOM  = 2;
    uint8 public constant PRIZE_TOP_N_RANKED   = 3;
    uint8 public constant PRIZE_TOP_N_RANDOM   = 4;
    // Legacy aliases — old tests passing these get the closest-equivalent new model
    // so they keep compiling. New tests should use the explicit constants above.
    uint8 public constant PRIZE_SINGLE_WINNER  = 1; // → SINGLE_TOP
    uint8 public constant PRIZE_TOP_N          = 3; // → TOP_N_RANKED
    uint8 public constant PRIZE_VOTER_REWARDS  = 0; // → PROPORTIONAL

    // --- VoterRewardDistribution ---
    uint8 public constant VOTER_DIST_EQUAL             = 0;
    uint8 public constant VOTER_DIST_PROPORTIONAL      = 1;
    uint8 public constant VOTER_DIST_TIERED            = 2;
    uint8 public constant VOTER_DIST_CORRELATION_BASED = 3;
    uint8 public constant VOTER_DIST_ACCURACY_WEIGHTED = 4;
    uint8 public constant VOTER_DIST_TIME_WEIGHTED     = 5;

    // =========================================================================
    // Default contest parameters (override in derived tests as needed)
    // =========================================================================

    uint256 public constant DEFAULT_DEPOSIT_AMOUNT  = 10e6;       // 10 USDC
    uint256 public constant DEFAULT_MIN_PARTICIPANTS = 2;
    uint256 public constant DEFAULT_MAX_PARTICIPANTS = 5;
    uint256 public constant DEFAULT_QUORUM_PERCENTAGE = 1;        // 1%
    uint256 public constant DEFAULT_VOTER_REWARD_PCT  = 50;       // 50% of yield
    uint256 public constant DEFAULT_DEPOSIT_DURATION  = 1 hours + 1;
    uint256 public constant DEFAULT_LOCK_DURATION     = 1 hours;
    uint256 public constant DEFAULT_REVEAL_DURATION   = 1 hours;
    uint256 public constant ACTOR_MINT_AMOUNT         = 100_000e6; // 100k USDC each

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public virtual {
        // --- Deploy core contracts (as this test contract, acting as deployer/owner) ---
        usdc = new MockERC20("USD Coin", "USDC", 6);

        yieldVault = new YieldVault();
        // Strategy 0 = simple hold (no external protocol, address(0))
        yieldVault.addStrategy(address(0));

        identityRegistry = new IdentityRegistry();
        randomnessManager = new MockRandomnessManager();

        // Deploy ContestV2 implementation (constructor marks it as initialized)
        contestImpl = new ContestV2();

        // Deploy factory (this test contract is the owner)
        factory = new ContestFactoryV2(
            address(contestImpl),
            address(yieldVault),
            address(identityRegistry),
            address(randomnessManager),
            address(this) // feeRecipient
        );

        // --- Populate user array ---
        _users = new address[](5);
        _users[0] = alice;
        _users[1] = bob;
        _users[2] = charlie;
        _users[3] = dave;
        _users[4] = eve;

        // --- Mint USDC to all actors ---
        usdc.mint(creator,  ACTOR_MINT_AMOUNT);
        usdc.mint(alice,    ACTOR_MINT_AMOUNT);
        usdc.mint(bob,      ACTOR_MINT_AMOUNT);
        usdc.mint(charlie,  ACTOR_MINT_AMOUNT);
        usdc.mint(dave,     ACTOR_MINT_AMOUNT);
        usdc.mint(eve,      ACTOR_MINT_AMOUNT);
        usdc.mint(attacker, ACTOR_MINT_AMOUNT);

        // --- Label addresses for clearer traces ---
        vm.label(creator,               "creator");
        vm.label(alice,                  "alice");
        vm.label(bob,                    "bob");
        vm.label(charlie,               "charlie");
        vm.label(dave,                   "dave");
        vm.label(eve,                    "eve");
        vm.label(attacker,              "attacker");
        vm.label(oracle,                "oracle");
        vm.label(address(usdc),         "USDC");
        vm.label(address(yieldVault),   "YieldVault");
        vm.label(address(identityRegistry), "IdentityRegistry");
        vm.label(address(randomnessManager), "RandomnessManager");
        vm.label(address(contestImpl),  "ContestV2Impl");
        vm.label(address(factory),      "ContestFactoryV2");

        // --- Warp to a sane start time so timestamps are non-zero ---
        vm.warp(1_700_000_000); // approx Nov 2023
    }

    // =========================================================================
    // Contest creation helpers
    // =========================================================================

    /**
     * @notice Create a contest via the factory with sensible defaults.
     * @param contestType   One of TYPE_VOTE..TYPE_PAIRWISE (uint8).
     * @param winnerMethod  One of WINNER_PLURALITY..WINNER_CONSENSUS (uint8).
     * @param prizeModel    One of PRIZE_SINGLE_WINNER..PRIZE_VOTER_REWARDS (uint8).
     * @return contestAddr  The deployed ContestV2 clone address.
     *
     * @dev Uses createCustomContest with:
     *      - 10 USDC deposit, 2 min / 5 max participants, 1% quorum
     *      - Deposit: now .. +1h, Lock: +1h .. +2h, Reveal: +2h .. +3h
     *      - Options: [OPT_A, OPT_B, OPT_C, OPT_D]
     *      - No oracle, no submissions, no tier requirement
     */
    function _createContest(
        uint8 contestType,
        uint8 winnerMethod,
        uint8 prizeModel
    ) internal returns (address contestAddr) {
        return _createContestCustomTiming(
            contestType,
            winnerMethod,
            prizeModel,
            DEFAULT_DEPOSIT_DURATION,
            DEFAULT_LOCK_DURATION,
            DEFAULT_REVEAL_DURATION
        );
    }

    /**
     * @notice Create a contest with custom phase durations.
     * @param contestType     One of TYPE_VOTE..TYPE_PAIRWISE.
     * @param winnerMethod    Winner determination method.
     * @param prizeModel      Prize distribution model.
     * @param depositDuration How long the deposit window stays open.
     * @param lockDuration    How long votes are locked (commit window).
     * @param revealDuration  How long the reveal window stays open.
     * @return contestAddr    The deployed ContestV2 clone address.
     */
    function _createContestCustomTiming(
        uint8 contestType,
        uint8 winnerMethod,
        uint8 prizeModel,
        uint256 depositDuration,
        uint256 lockDuration,
        uint256 revealDuration
    ) internal returns (address contestAddr) {
        uint256 t = block.timestamp;
        uint256 nonce = _contestNonce++;

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           DEFAULT_DEPOSIT_AMOUNT,
            minParticipants:         DEFAULT_MIN_PARTICIPANTS,
            maxParticipants:         DEFAULT_MAX_PARTICIPANTS,
            depositStart:            t,
            depositEnd:              t + depositDuration,
            lockEnd:                 t + depositDuration + lockDuration,
            revealEnd:               t + depositDuration + lockDuration + revealDuration,
            contestType:             ContestV2.ContestType(contestType),
            winnerDetermination:     ContestV2.WinnerDetermination(winnerMethod),
            voterRewardDistribution: ContestV2.VoterRewardDistribution(VOTER_DIST_PROPORTIONAL),
            tierRequired:            0,
            quorumPercentage:        DEFAULT_QUORUM_PERCENTAGE,
            requiresOracle:          false,
            metadataHash:            keccak256(abi.encodePacked("test-contest-", t, nonce)),
            metadataUri:             "ipfs://test"
        });

        // Build a PrizeConfig matching the test's prizeModel selection.
        // For TOP_N_* models, default to top-3 splits 60/30/10 (changeable
        // by tests via _createContestWithPrizeConfig once that helper exists).
        ContestV2.PrizeConfig memory prizeCfg = _defaultPrizeConfigForModel(
            ContestV2.PrizeModel(prizeModel)
        );

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold:  0,     // No minimum threshold — all revealed voters eligible
            topPercentile:         2500,  // Top 25%
            confidenceMultiplier:  5000,  // 50% bonus
            earlyVoterBonus:       0      // No early-voter bonus by default
        });

        // Submissions disabled by default
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
            address(0), // no oracle
            opts,
            0 // no creator prize
        );

        vm.label(contestAddr, "Contest");
    }

    /// @notice Returns [OPT_A, OPT_B, OPT_C, OPT_D].
    function _defaultOptions() internal pure returns (bytes32[] memory opts) {
        opts = new bytes32[](4);
        opts[0] = OPT_A;
        opts[1] = OPT_B;
        opts[2] = OPT_C;
        opts[3] = OPT_D;
    }

    // =========================================================================
    // Deposit helpers
    // =========================================================================

    /**
     * @notice Approve USDC and deposit into a contest as `user`.
     * @dev The contest pulls tokens from the user, then forwards them to YieldVault.
     *      User must have sufficient USDC balance (setUp mints 100k to each actor).
     */
    function _deposit(address user, address contest) internal {
        uint256 amount = ContestV2(contest).getConfig().depositAmount;
        vm.startPrank(user);
        usdc.approve(contest, amount);
        ContestV2(contest).deposit();
        vm.stopPrank();
        // Advance block for flash loan protection (SameBlockWithdraw)
        _advanceBlock();
    }

    /**
     * @notice Mint USDC to `user` and approve `spender`.
     * @param user    Recipient of the minted tokens.
     * @param amount  Amount to mint (6-decimal USDC).
     */
    function _mintAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(yieldVault), amount);
    }

    // =========================================================================
    // Commit-reveal helpers
    // =========================================================================

    /**
     * @notice Compute the commit hash and submit it on-chain as `user`.
     * @param user      The depositor committing a vote.
     * @param contest   The ContestV2 clone address.
     * @param voteData  ABI-encoded vote payload (use _makeVoteData_* helpers).
     * @param salt      Random salt for hiding the vote.
     *
     * @dev Audit M-01: commit hash binds msg.sender so reveals cannot be
     *      replayed from another voter's mempool tx. Matches ContestV2's
     *      revealVote() verification: keccak256(msg.sender, voteData, salt).
     */
    function _commitVote(
        address user,
        address contest,
        bytes memory voteData,
        bytes32 salt
    ) internal {
        bytes32 commitHash = keccak256(abi.encodePacked(user, voteData, salt));
        vm.prank(user);
        ContestV2(contest).commitVote(commitHash);
    }

    /**
     * @notice Reveal a previously committed vote as `user`.
     * @param user      The voter revealing.
     * @param contest   The ContestV2 clone address.
     * @param voteData  The original vote payload (must match commit).
     * @param salt      The original salt (must match commit).
     */
    function _revealVote(
        address user,
        address contest,
        bytes memory voteData,
        bytes32 salt
    ) internal {
        vm.prank(user);
        ContestV2(contest).revealVote(voteData, salt);
    }

    // =========================================================================
    // Vote data encoding helpers
    // =========================================================================

    /// @notice Encode vote data for VOTE-type contests.
    /// @param option The bytes32 option the voter selects.
    function _makeVoteData_VOTE(bytes32 option) internal pure returns (bytes memory) {
        return abi.encode(option);
    }

    /// @notice Encode vote data for RANK-type contests (Borda count).
    /// @param ranking Ordered array of option IDs (first = highest rank).
    function _makeVoteData_RANK(bytes32[] memory ranking) internal pure returns (bytes memory) {
        return abi.encode(ranking);
    }

    /// @notice Encode vote data for RATE-type contests.
    /// @param options  Array of option IDs being rated.
    /// @param ratings  Corresponding ratings (same length as options).
    function _makeVoteData_RATE(
        bytes32[] memory options,
        uint256[] memory ratings
    ) internal pure returns (bytes memory) {
        return abi.encode(options, ratings);
    }

    /// @notice Encode vote data for PREDICT-type contests.
    /// @param option     The predicted outcome option.
    /// @param confidence Confidence level (arbitrary scale).
    function _makeVoteData_PREDICT(
        bytes32 option,
        uint256 confidence
    ) internal pure returns (bytes memory) {
        return abi.encode(option, confidence);
    }

    /// @notice Encode vote data for PAIRWISE-type contests.
    /// @param chosen Array of option IDs chosen in each pairwise comparison.
    function _makeVoteData_PAIRWISE(bytes32[] memory chosen) internal pure returns (bytes memory) {
        return abi.encode(chosen);
    }

    // =========================================================================
    // Time advancement helpers
    // =========================================================================

    /**
     * @notice Warp past the deposit end and call updateState().
     * @dev Moves to depositEnd + 1 second. After this call the contest will be
     *      in DEPOSIT_CLOSED (or CANCELLED if min participants not met).
     */
    function _advancePastDeposit(address contest) internal {
        ContestV2.ContestConfig memory cfg = ContestV2(contest).getConfig();
        vm.warp(cfg.depositEnd + 1);
        ContestV2(contest).updateState();
    }

    /**
     * @notice Warp past the lock end and call updateState() twice.
     * @dev First call transitions DEPOSIT_OPEN -> DEPOSIT_CLOSED (if still there),
     *      second call transitions through to REVEAL_OPEN.
     *      After this call the contest should be in REVEAL_OPEN state.
     */
    function _advancePastLock(address contest) internal {
        ContestV2.ContestConfig memory cfg = ContestV2(contest).getConfig();
        vm.warp(cfg.lockEnd + 1);
        // updateState() does one transition per call, so call until REVEAL_OPEN
        ContestV2(contest).updateState(); // DEPOSIT_OPEN -> DEPOSIT_CLOSED
        ContestV2(contest).updateState(); // DEPOSIT_CLOSED -> LOCKED
        _advanceBlock(); // Advance block for flash loan protection (SameBlockWithdraw)
        ContestV2(contest).updateState(); // LOCKED -> REVEAL_OPEN
    }

    /**
     * @notice Warp past the reveal end.
     * @dev Does NOT call updateState() since the next step is typically
     *      resolveContest() which handles the transition itself.
     */
    function _advancePastReveal(address contest) internal {
        ContestV2.ContestConfig memory cfg = ContestV2(contest).getConfig();
        vm.warp(cfg.revealEnd + 1);
    }

    /**
     * @notice Read the current ContestState as a uint8 for easy assertion.
     */
    function _getState(address contest) internal view returns (uint8) {
        return uint8(ContestV2(contest).state());
    }

    // =========================================================================
    // config() destructuring helper
    // =========================================================================

    /**
     * @notice Read timing fields from a contest's config.
     * @return depositStart  Start of deposit window.
     * @return depositEnd    End of deposit window.
     * @return lockEnd       End of lock / commit window.
     * @return revealEnd     End of reveal window.
     */
    function _getTimings(address contest)
        internal
        view
        returns (uint256 depositStart, uint256 depositEnd, uint256 lockEnd, uint256 revealEnd)
    {
        ContestV2.ContestConfig memory cfg = ContestV2(contest).getConfig();
        return (cfg.depositStart, cfg.depositEnd, cfg.lockEnd, cfg.revealEnd);
    }

    // =========================================================================
    // Full lifecycle helper (VOTE type)
    // =========================================================================

    /**
     * @notice Run a complete VOTE contest lifecycle for the given users.
     *
     * Steps:
     *   1. Each user deposits.
     *   2. Each user commits a vote for `voteOption`.
     *   3. Advance past deposit end -> DEPOSIT_CLOSED.
     *   4. Advance past lock end -> REVEAL_OPEN.
     *   5. Each user reveals their vote.
     *   6. Advance past reveal end.
     *   7. Call resolveContest() -> FINALIZED.
     *
     * @param contest    The ContestV2 clone address.
     * @param users      Array of user addresses to participate.
     * @param voteOption The bytes32 option everyone votes for.
     *
     * @dev All users vote for the same option for simplicity.
     *      Override or write a custom lifecycle for heterogeneous votes.
     */
    /// @notice Build a sensible default PrizeConfig for a given model.
    ///         TOP_N_* models default to 3-way 60/30/10 splits.
    ///         Random models default to weighted=false (uniform odds).
    ///         Eligibility threshold = 0 (any revealed voter qualifies)
    ///         to keep small-N tests from filtering everyone out.
    function _defaultPrizeConfigForModel(ContestV2.PrizeModel model)
        internal
        pure
        returns (ContestV2.PrizeConfig memory)
    {
        bool isTopN = model == ContestV2.PrizeModel.TOP_N_RANKED ||
                      model == ContestV2.PrizeModel.TOP_N_RANDOM;
        uint16[] memory splits;
        if (isTopN) {
            splits = new uint16[](3);
            splits[0] = 6000;
            splits[1] = 3000;
            splits[2] = 1000;
        } else {
            splits = new uint16[](0);
        }
        return ContestV2.PrizeConfig({
            model: model,
            splitsBps: splits,
            eligibilityThreshold: 0,
            weightedByScore: false
        });
    }

    /// @notice Full PrizeConfig override variant of _createContest, for tests
    ///         that need non-default splits, weighted random, or a custom
    ///         eligibility threshold.
    function _createContestWithPrize(
        uint8 contestType,
        uint8 winnerMethod,
        ContestV2.PrizeConfig memory prizeCfg
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
            requiresOracle:          false,
            metadataHash:            keccak256(abi.encodePacked("test-contest-prize-", t, nonce)),
            metadataUri:             "ipfs://test"
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold:  0,
            topPercentile:         2500,
            confidenceMultiplier:  5000,
            earlyVoterBonus:       0
        });

        ContestV2.SubmissionConfig memory subConfig = ContestV2.SubmissionConfig({
            enabled: false, submissionStart: 0, submissionEnd: 0, maxPerUser: 0,
            requiresModeration: false, paymentModel: ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0, minSubmissions: 0, maxTotalSubmissions: 0
        });

        bytes32[] memory opts = _defaultOptions();

        vm.prank(creator);
        (, contestAddr) = factory.createCustomContest(
            config, prizeCfg, scoring, subConfig, address(0), opts, 0
        );

        vm.label(contestAddr, "Contest");
    }

    function _fullLifecycle_VOTE(
        address contest,
        address[] memory users,
        bytes32 voteOption
    ) internal {
        bytes memory voteData = _makeVoteData_VOTE(voteOption);
        bytes32[] memory salts = new bytes32[](users.length);

        // 1. Deposit + Commit
        for (uint256 i = 0; i < users.length; i++) {
            _deposit(users[i], contest);

            salts[i] = keccak256(abi.encodePacked("salt", users[i], i));
            _commitVote(users[i], contest, voteData, salts[i]);
        }

        // 2. Advance to REVEAL_OPEN
        _advancePastLock(contest);

        // 3. Reveal all votes
        for (uint256 i = 0; i < users.length; i++) {
            _revealVote(users[i], contest, voteData, salts[i]);
        }

        // 4. Advance past reveal and resolve (must be called by creator)
        _advancePastReveal(contest);
        vm.prank(creator);
        ContestV2(contest).resolveContest();
    }
}
