// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IYieldVault.sol";
import "./interfaces/IIdentityRegistry.sol";
import "./interfaces/IRandomnessManager.sol";
import "./interfaces/IResolver.sol";
import "./ContestScoring.sol";
import "./libraries/PrizeDistribution.sol";

/// @notice Minimal interface for clones to read the factory's pause flag.
///         Reused by ProbabilityVaultV2 with the same shape.
interface IFactoryPauseLookup {
    function paused() external view returns (bool);
}

/**
 * @title ContestV2
 * @notice Enhanced no-loss contest with full configuration and voter rewards
 * @dev Supports all contest types with flexible reward distribution
 */
contract ContestV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom errors (saves ~3KB bytecode vs string requires)
    error InvalidState();
    error NotCreator();
    error NotFactory();
    error AlreadyInitialized();
    error InvalidConfig();
    error NotDeposited();
    error AlreadyDeposited();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error AlreadyCancelled();
    error AlreadyFinalized();
    error AlreadyClaimed();
    error InvalidReveal();
    error InvalidOption();
    error NotAuthorized();
    error TransferFailed();
    error TooManyOptions();
    error NoReward();
    error TierRequired();
    error WindowNotActive();
    error VRFNotPending();
    error VRFTimeoutNotReached();
    error ResolverNotReady();

    // ============ Enums ============

    enum ContestType { VOTE, RANK, RATE, PREDICT, PAIRWISE }

    /// @notice Voter prize distribution model. Replaces the legacy enum
    ///         (SINGLE_WINNER/TOP_N/PROPORTIONAL/VOTER_REWARDS) which had no
    ///         meaningful payout difference — the new values are honest about
    ///         what each does:
    ///           - PROPORTIONAL:   pool * score / totalScore for every eligible
    ///           - SINGLE_TOP:     100% to top-score voter (ties split pro-rata)
    ///           - SINGLE_RANDOM:  VRF picks 1 eligible (uniform or score-weighted)
    ///           - TOP_N_RANKED:   splitsBps to top-N by score (cutoff ties pro-rata)
    ///           - TOP_N_RANDOM:   VRF picks N eligibles (uniform or score-weighted)
    ///           - STAKE_WEIGHTED: pool * stake / totalWinnerStake — the
    ///                             prediction-market default. Eligibility is
    ///                             still score-based (voted for winner), but
    ///                             payout is proportional to depositReceived.
    enum PrizeModel { PROPORTIONAL, SINGLE_TOP, SINGLE_RANDOM, TOP_N_RANKED, TOP_N_RANDOM, STAKE_WEIGHTED }

    /// @notice AWAITING_VRF appended at the end so existing index values
    ///         (FINALIZED=8, CANCELLED=9) stay stable for off-chain consumers.
    enum ContestState { CREATED, SUBMISSION_OPEN, SUBMISSION_CLOSED, DEPOSIT_OPEN, DEPOSIT_CLOSED, LOCKED, REVEAL_OPEN, RESOLVING, FINALIZED, CANCELLED, AWAITING_VRF }
    enum WinnerDetermination { PLURALITY, MAJORITY, RANKED_CHOICE, BORDA_COUNT, WEIGHTED_AVERAGE, ORACLE, THRESHOLD, CONSENSUS }
    enum VoterRewardDistribution { EQUAL, PROPORTIONAL, TIERED, CORRELATION_BASED, ACCURACY_WEIGHTED, TIME_WEIGHTED }
    enum PaymentModel { PROTOCOL, CREATOR_UPFRONT, USER_PER_SUBMISSION }
    enum SubmissionType { IMAGE, VIDEO, AUDIO }

    // ============ Structs ============

    struct ContestConfig {
        // Basic settings
        address depositToken;
        uint256 depositAmount;
        uint256 minParticipants;
        uint256 maxParticipants;

        // Timing (unix timestamps)
        uint256 depositStart;
        uint256 depositEnd;
        uint256 lockEnd;
        uint256 revealEnd;

        // Contest type settings
        ContestType contestType;
        WinnerDetermination winnerDetermination;
        VoterRewardDistribution voterRewardDistribution;

        // NOTE: legacy fields prizeModel / prizeModelParam / voterRewardPercentage
        // have been removed. All prize logic now lives in the top-level
        // `prizeConfig` storage variable (see PrizeConfig struct + initialize()).
        // The full prize pool (yield - protocol fee + creator prize principal)
        // is now always paid to voters per `prizeConfig.model`. The prior
        // optionRewardsPool was never distributed and has been deprecated.

        // Requirements
        uint256 tierRequired;
        uint256 quorumPercentage;       // Min % of participants who must reveal
        bool requiresOracle;

        // Metadata
        bytes32 metadataHash;
        string metadataUri;
    }

    /// @notice All voter-reward distribution settings. Stored separately from
    ///         ContestConfig so the dynamic `splitsBps` array round-trips cleanly
    ///         through external getters.
    struct PrizeConfig {
        PrizeModel model;
        /// @notice Per-rank split in basis points. Length = N for TOP_N_*
        ///         models; must sum to exactly 10_000. For PROPORTIONAL,
        ///         SINGLE_TOP, and SINGLE_RANDOM the array must be empty
        ///         (the math is fully implied by the model).
        uint16[] splitsBps;
        /// @notice Minimum voter score to be eligible for any reward.
        ///         Replaces the per-mode correlationThreshold for prize
        ///         distribution. Pure scoring still uses correlationThreshold
        ///         for the score calculation itself.
        uint256 eligibilityThreshold;
        /// @notice For *_RANDOM models only: when true, selection probability
        ///         is proportional to voter score (better voters more likely
        ///         to win). When false, all eligibles have equal odds.
        bool weightedByScore;
    }

    struct ScoringConfig {
        uint256 correlationThreshold;   // Min correlation for ranking rewards (scaled by 1e4)
        uint256 topPercentile;          // Top X% get rewards
        uint256 confidenceMultiplier;   // Bonus for high confidence (scaled by 1e4)
        uint256 earlyVoterBonus;        // Bonus for early voters (scaled by 1e4)
    }

    struct Participant {
        bool hasDeposited;
        bool hasCommitted;
        bool hasRevealed;
        bytes32 commitHash;
        bytes revealedData;
        uint256 commitTimestamp;
        uint256 revealTimestamp;
        uint256 score;                  // Calculated after results
        bool principalWithdrawn;
        bool rewardsClaimed;
        uint256 depositReceived;        // Actual amount received (fee-on-transfer safe)
        uint256 withdrawableAmount;     // Scaled amount after strategy loss (0 = use depositReceived)
    }

    struct ContestResults {
        bool isResolved;
        bytes32[] rankedOptions;        // Option IDs in order
        uint256[] optionScores;         // Scores for each option
        bytes32 winningOption;          // For single-winner contests
        uint256 totalYield;
        uint256 voterRewardsPool;       // Full prize pool allocated to voters
        // Removed in 2026-04 slim-down: `bytes oracleData` (legacy submitOracleData
        // path is gone; resolvers replace it) and `uint256 optionRewardsPool`
        // (deprecated since v2.1, always 0). Cutting these keeps ContestV2 under
        // the EIP-170 24,576-byte limit. Off-chain readers that referenced them
        // must be updated.
    }

    struct SubmissionConfig {
        bool enabled;                    // Allow user submissions
        uint256 submissionStart;         // When submissions open
        uint256 submissionEnd;           // Submission deadline
        uint8 maxPerUser;                // Max submissions per user (0 = unlimited)
        bool requiresModeration;         // Manual approval required
        PaymentModel paymentModel;       // Who pays storage costs
        uint256 storageFeePerSubmission; // Fee amount (if users pay)
        uint256 minSubmissions;          // Min to start contest
        uint256 maxTotalSubmissions;     // Max total allowed
    }

    struct Submission {
        address submitter;
        string ipfsCid;                  // IPFS content hash
        string title;
        string description;
        uint256 timestamp;
        bool approved;                   // Moderation status
        SubmissionType fileType;
    }

    // ============ Constants ============

    uint256 public constant MAX_PARTICIPANTS_CAP = 10_000;

    /// @notice Maximum time a contest waits for a VRF callback before
    ///         creator/factory may force a deterministic fallback.
    uint256 public constant VRF_TIMEOUT = 24 hours;

    /// @notice Audit M-05: after VRF_TIMEOUT + FALLBACK_PUBLIC_AFTER the
    ///         deterministic fallback becomes permissionless so a disengaged
    ///         creator cannot indefinitely hold a contest in AWAITING_VRF.
    uint256 public constant FALLBACK_PUBLIC_AFTER = 7 days;

    // ============ State Variables ============

    // NOTE: factory is NOT immutable because clones don't run constructor
    // It's set in initialize() to msg.sender (the factory)
    address public factory;
    address public creator;
    bool private _initialized;
    /// @notice Public state but no auto-getter — use `getConfig()` instead. Going
    ///         `internal` here saves ~2KB of tuple-decoder bytecode that the auto
    ///         getter would generate (ContestConfig has 16+ fields including dynamic
    ///         strings/bytes32). EIP-170 size optimization.
    ContestConfig internal config;
    ScoringConfig internal scoringConfig;
    ContestState public state;
    ContestResults internal results;

    // External contracts
    IYieldVault public yieldVault;
    IIdentityRegistry public identityRegistry;
    IRandomnessManager public randomnessManager;
    address public oracle;

    // Protocol fee (set at initialization from factory, immutable per-contest)
    uint256 public protocolFeePercentage; // basis points (e.g. 200 = 2%)
    address public protocolFeeRecipient;

    // Participant tracking — internal to drop the 12-field auto-getter encoder.
    // Use `getParticipant(addr)` for external reads.
    mapping(address => Participant) internal participants;
    address[] public participantList;
    uint256 public totalDeposited;
    uint256 public vaultShares;

    // Vote tracking
    mapping(bytes32 => uint256) public optionVotes;          // optionId => vote count
    mapping(bytes32 => uint256) public optionTotalScore;     // optionId => total score (for ratings)
    mapping(bytes32 => bool) public validOptions;            // optionId => is valid option
    bytes32[] public options;

    // Voter reward tracking
    mapping(address => uint256) public voterRewards;
    uint256 public totalVoterRewardsDistributed;
    uint256 public undistributedRewards; // Dust from rounding — claimable by creator

    // Prize configuration (replaces deprecated ContestConfig.prizeModel/prizeModelParam/voterRewardPercentage)
    PrizeConfig internal _prizeConfig;

    // VRF tracking (only set when prizeConfig.model is SINGLE_RANDOM or TOP_N_RANDOM)
    uint256 public vrfRequestedAt;
    bytes32 public vrfRequestKey; // The key passed to randomnessManager.requestRandomness

    // Creator-sponsored prize (deposited to vault at creation to generate yield)
    uint256 public creatorPrize;

    // Revealed vote counter (gas optimization — avoids iterating participantList)
    uint256 public revealedCount;

    // SUBMISSION SYSTEM REMOVED in 2026-04 slim-down to fit ContestV2 under the
    // EIP-170 24,576-byte limit. The `SubmissionConfig` and `Submission` structs
    // are retained as inert type definitions so ContestFactoryV2.initialize() and
    // off-chain ABIs keep their shape — but no submission state is stored, no
    // submission functions exist, and `initialize()` reverts if a contest is
    // created with `submissionConfig.enabled = true`. To bring the feature back,
    // deploy a separate ContestSubmissionsExtension contract that stores its own
    // state and is referenced by the contest via an immutable address.

    // ============ Events ============

    event ContestCreated(address indexed creator, ContestType contestType);
    event Deposited(address indexed participant, uint256 amount);
    event VoteCommitted(address indexed participant, bytes32 commitHash);
    event VoteRevealed(address indexed participant, bytes data);
    event ContestResolved(bytes32 winningOption, uint256 totalYield);
    event ProtocolFeeDeducted(uint256 amount, address recipient);
    event VoterRewardsDistributed(uint256 totalAmount, uint256 recipientCount);
    event RewardClaimed(address indexed participant, uint256 amount);
    event PrincipalWithdrawn(address indexed participant, uint256 amount);
    event ContestCancelled(string reason);
    event StateChanged(ContestState newState);
    event TreasuryFeeClaimed(uint256 amount, address recipient);
    event ProtocolFeeSkipped(uint256 amount, address recipient, string reason);
    event CreatorPrizeDeposited(address indexed creator, uint256 amount);
    event CreatorPrizeRefunded(address indexed creator, uint256 amount);

    /// @notice Emitted when *_RANDOM prize models request a VRF word.
    event VRFResolutionRequested(bytes32 indexed requestKey, uint256 requestedAt);
    /// @notice Emitted when creator/factory forces deterministic fallback after VRF timeout.
    event VRFFallbackUsed(PrizeModel originalModel, PrizeModel fallbackModel);
    /// @notice Emitted once when prize distribution completes (all winners resolved).
    ///         Off-chain consumers can read full payout from this single event
    ///         instead of reconstructing it from voterRewards storage reads.
    event PrizeDistributionFinalized(
        PrizeModel model,
        address[] winners,
        uint256[] amounts,
        uint256 undistributed
    );

    // ============ Modifiers ============

    modifier onlyCreator() {
        if (msg.sender != creator) revert NotCreator();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier inState(ContestState _state) {
        if (state != _state) revert InvalidState();
        _;
    }

    /// @notice Reverts when the factory is paused. Applied only to mutation
    ///         entry points that the Guardian should be able to halt in
    ///         emergencies (deposit, commitVote, revealVote). Resolution,
    ///         refund, withdraw, claim and cancel paths are intentionally
    ///         NOT gated — principal redemption must always succeed even
    ///         while the factory is paused.
    modifier whenFactoryNotPaused() {
        if (factory != address(0) && IFactoryPauseLookup(factory).paused()) revert InvalidState();
        _;
    }

    // ============ Constructor ============

    /// @dev Constructor is only used for the implementation contract
    /// Clones will not run this - they use initialize() instead
    constructor() {
        // Prevent implementation from being initialized
        _initialized = true;
    }

    // ============ Initialization ============

    /// @notice Initialize a cloned contest
    /// @dev Can only be called once by the factory
    function initialize(
        address _creator,
        ContestConfig calldata _config,
        PrizeConfig calldata _prize,
        ScoringConfig calldata _scoringConfig,
        SubmissionConfig calldata _submissionConfig,
        address _yieldVault,
        address _identityRegistry,
        address _randomnessManager,
        address _oracle,
        bytes32[] calldata _options,
        uint256 _protocolFeePercentage,
        address _protocolFeeRecipient,
        uint256 _creatorPrize
    ) external nonReentrant {
        // Prevent re-initialization
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Only contracts (i.e., the factory) can initialize clones.
        // Combined with the atomic clone+initialize in ContestFactoryV2, this prevents
        // EOA front-running of initialize() on freshly deployed clones.
        if (!(msg.sender.code.length > 0)) revert InvalidConfig();

        // ReentrancyGuard's _status defaults to 0 in clones (constructor not run).
        // The nonReentrant modifier checks _status != _ENTERED (2), so 0 passes.
        // After this function completes, _status is correctly set to 1 (_NOT_ENTERED),
        // protecting all subsequent nonReentrant calls.

        // Set factory to the caller (ContestFactoryV2)
        factory = msg.sender;

        if (!(_config.depositEnd > _config.depositStart)) revert InvalidConfig();
        if (!(_config.lockEnd > _config.depositEnd)) revert InvalidConfig();
        if (!(_config.revealEnd > _config.lockEnd)) revert InvalidConfig();
        if (!(_options.length >= 2)) revert InvalidConfig();
        if (!(_options.length <= 100)) revert InvalidConfig();
        if (!(_config.maxParticipants > 0)) revert InvalidConfig();
        if (!(_config.maxParticipants <= MAX_PARTICIPANTS_CAP)) revert InvalidConfig();

        if (!(_creator != address(0))) revert InvalidConfig();

        // Submission contests are deferred to a future ContestSubmissionsExtension
        // (the bytecode for the on-chain submission system was removed in 2026-04
        // to fit ContestV2 under EIP-170). Reject contests that try to enable them.
        if (_submissionConfig.enabled) revert InvalidConfig();

        // Validate prize config based on model (extracted to library to save bytecode)
        PrizeDistribution.validateConfig(
            uint8(_prize.model),
            _prize.splitsBps,
            MAX_PARTICIPANTS_CAP,
            _randomnessManager
        );

        // Validate oracle address when contest type requires it
        if (_config.requiresOracle) {
            if (!(_oracle != address(0))) revert InvalidConfig();
        }

        // Note: Rebasing tokens (stETH, AMPL) are NOT supported.
        // Using rebasing tokens will cause accounting discrepancies.

        creator = _creator;
        config = _config;
        _prizeConfig = _prize;
        scoringConfig = _scoringConfig;
        yieldVault = IYieldVault(_yieldVault);
        identityRegistry = IIdentityRegistry(_identityRegistry);
        randomnessManager = IRandomnessManager(_randomnessManager);
        oracle = _oracle;
        options = _options;

        // Protocol fee — copied from factory at creation time
        protocolFeePercentage = _protocolFeePercentage;
        protocolFeeRecipient = _protocolFeeRecipient;

        // Populate validOptions mapping for vote validation
        for (uint256 i = 0; i < _options.length; i++) {
            validOptions[_options[i]] = true;
        }

        // Deposit creator prize to yield vault to generate yield (and platform fees).
        // Measure actual balance to handle fee-on-transfer tokens safely (mirrors deposit()).
        if (_creatorPrize > 0) {
            uint256 prizeBalance = IERC20(_config.depositToken).balanceOf(address(this));
            if (!(prizeBalance > 0)) revert InvalidConfig();
            // Use actual balance (may be less than _creatorPrize for fee-on-transfer tokens)
            uint256 actualPrize = prizeBalance < _creatorPrize ? prizeBalance : _creatorPrize;
            creatorPrize = actualPrize;
            IERC20(_config.depositToken).forceApprove(address(yieldVault), actualPrize);
            uint256 shares = yieldVault.deposit(_config.depositToken, actualPrize, 0);
            vaultShares += shares;
            emit CreatorPrizeDeposited(_creator, actualPrize);
        }

        // Submissions disabled (rejected above) → always start at DEPOSIT_OPEN.
        _transitionState(ContestState.DEPOSIT_OPEN);

        emit ContestCreated(_creator, _config.contestType);
    }

    // ============ Submission Functions REMOVED ============
    //
    // submitContent / moderateSubmission / finalizeSubmissions / withdrawStorageFee /
    // releaseStorageFees / getSubmissionCount / getSubmission were all removed in the
    // 2026-04 slim-down to fit ContestV2 below the EIP-170 24,576-byte limit. Any
    // contest that needs user-submitted content must register pre-computed option IDs
    // (e.g. keccak256 of IPFS CIDs) at creation time. The submission feature will
    // return as a separate ContestSubmissionsExtension contract referenced by the
    // contest in a future release.

    // ============ Deposit Functions ============

    function deposit() external nonReentrant whenFactoryNotPaused inState(ContestState.DEPOSIT_OPEN) {
        if (!(block.timestamp >= config.depositStart)) revert InvalidConfig();
        if (!(block.timestamp < config.depositEnd)) revert InvalidConfig();
        if (participants[msg.sender].hasDeposited) revert AlreadyDeposited();
        if (!(participantList.length < config.maxParticipants)) revert InvalidConfig();

        // Check identity tier
        if (config.tierRequired > 0) {
            if (!(identityRegistry.getTier(msg.sender) >= config.tierRequired)) revert InvalidConfig();
        }

        // Sponsored contest: free participation (no deposit needed)
        if (config.depositAmount == 0) {
            participants[msg.sender].hasDeposited = true;
            participantList.push(msg.sender);
            emit Deposited(msg.sender, 0);
            return;
        }

        // Measure actual received amount to handle fee-on-transfer tokens
        uint256 balanceBefore = IERC20(config.depositToken).balanceOf(address(this));
        IERC20(config.depositToken).safeTransferFrom(
            msg.sender,
            address(this),
            config.depositAmount
        );
        uint256 received = IERC20(config.depositToken).balanceOf(address(this)) - balanceBefore;
        if (!(received > 0)) revert InvalidConfig();

        // Deposit actual received amount to yield vault (using default strategy 0)
        IERC20(config.depositToken).forceApprove(address(yieldVault), received);
        uint256 shares = yieldVault.deposit(config.depositToken, received, 0);
        vaultShares += shares;
        totalDeposited += received;

        // Record participant with actual received amount
        participants[msg.sender].hasDeposited = true;
        participants[msg.sender].depositReceived = received;
        participantList.push(msg.sender);

        emit Deposited(msg.sender, received);
    }

    // ============ Voting Functions ============

    function commitVote(bytes32 commitHash) external nonReentrant whenFactoryNotPaused {
        if (!(state == ContestState.DEPOSIT_OPEN ||
            state == ContestState.DEPOSIT_CLOSED ||
            state == ContestState.LOCKED)) revert InvalidConfig();
        if (!(block.timestamp < config.lockEnd)) revert InvalidConfig();

        Participant storage p = participants[msg.sender];
        if (!p.hasDeposited) revert NotDeposited();
        if (p.hasCommitted) revert AlreadyCommitted();

        p.hasCommitted = true;
        p.commitHash = commitHash;
        p.commitTimestamp = block.timestamp;

        emit VoteCommitted(msg.sender, commitHash);
    }

    function revealVote(
        bytes calldata voteData,
        bytes32 salt
    ) external nonReentrant whenFactoryNotPaused inState(ContestState.REVEAL_OPEN) {
        if (!(block.timestamp >= config.lockEnd)) revert InvalidConfig();
        if (!(block.timestamp < config.revealEnd)) revert InvalidConfig();

        Participant storage p = participants[msg.sender];
        if (!p.hasCommitted) revert InvalidConfig();
        if (p.hasRevealed) revert AlreadyRevealed();

        // Audit M-01: bind the commitment to msg.sender so reveals cannot be replayed
        // from another voter's mempool tx. Mirrors MirrorContestV2's expected hash.
        bytes32 expectedHash = keccak256(abi.encodePacked(msg.sender, voteData, salt));
        if (expectedHash != p.commitHash) revert InvalidReveal();

        p.hasRevealed = true;
        p.revealedData = voteData;
        p.revealTimestamp = block.timestamp;
        revealedCount++;

        // Process vote based on contest type
        _processVote(msg.sender, voteData);

        emit VoteRevealed(msg.sender, voteData);
    }

    // ============ Resolution Functions ============

    function resolveContest() external nonReentrant {
        if (!(msg.sender == creator || msg.sender == factory)) revert InvalidConfig();
        if (!(state == ContestState.REVEAL_OPEN || state == ContestState.RESOLVING)) revert InvalidConfig();
        if (!(block.timestamp >= config.revealEnd)) revert InvalidConfig();

        if (state == ContestState.REVEAL_OPEN) {
            _transitionState(ContestState.RESOLVING);
        }

        // Check quorum (revealedCount is tracked incrementally in revealVote).
        // After a 24h grace period past revealEnd, proceed with however many reveals
        // occurred — prevents a single non-revealer from permanently locking a contest.
        uint256 quorumRequired = (participantList.length * config.quorumPercentage) / 100;
        bool quorumGracePassed = block.timestamp >= config.revealEnd + 24 hours;
        if (!quorumGracePassed && !(revealedCount >= quorumRequired)) revert InvalidConfig();

        // ─── Resolver consultation (optional, set via factory) ─────────────
        // If this contest has an external resolver bound, consult it BEFORE
        // withdrawing funds from the vault. This way, if the resolver is not
        // yet ready (e.g. Chainlink feed stale, Polymarket UMA still in its
        // 2h liveness window), we can revert cleanly and retry later without
        // double-withdrawing on the next call. If the resolver returns the
        // ambiguous sentinel bytes32(0) (e.g. UMA 50/50), _cancel() handles
        // the refund path exactly like an admin cancel.
        address resolverAddr = _resolverAddress();
        bytes32 resolverWinner = bytes32(0);
        bool resolverUsed = false;
        if (resolverAddr != address(0)) {
            bytes32 cid = bytes32(uint256(uint160(address(this))));
            bool ready;
            bytes32 winner;
            try IResolver(resolverAddr).resolve(cid) returns (bool _ready, bytes32 _winner) {
                ready = _ready;
                winner = _winner;
            } catch {
                // Resolver reverted — cancel so participants can recover principal.
                _cancel("Resolver failed");
                return;
            }
            if (!ready) revert ResolverNotReady();
            if (winner == bytes32(0)) {
                _cancel("resolver: ambiguous outcome");
                return;
            }
            if (!validOptions[winner]) revert InvalidOption();
            resolverWinner = winner;
            resolverUsed = true;
        }

        // Contests that requiresOracle MUST have a resolver bound at the factory.
        // submitOracleData was removed; a resolver is now the only oracle path. Check
        // here BEFORE withdrawing — otherwise a misconfigured contest would pull
        // funds from the vault on every retry just to revert.
        if (config.requiresOracle && !resolverUsed) revert ResolverNotReady();

        // Withdraw ALL funds from vault (participant deposits + creator prize + all yield)
        uint256 totalAssets = 0;
        if (vaultShares > 0) {
            totalAssets = yieldVault.withdraw(config.depositToken, vaultShares, 0, address(this));
            if (!(totalAssets > 0 || (totalDeposited == 0 && creatorPrize == 0))) revert InvalidConfig();
            vaultShares = 0;
        }

        // Total principal = participant deposits + creator prize
        uint256 totalPrincipal = totalDeposited + creatorPrize;
        uint256 yieldGenerated = totalAssets > totalPrincipal ? totalAssets - totalPrincipal : 0;

        // If strategy lost funds, scale down BOTH participant deposits AND creator prize
        if (totalAssets < totalPrincipal && totalPrincipal > 0) {
            // Pro-rata for participants
            for (uint256 i = 0; i < participantList.length; i++) {
                Participant storage p = participants[participantList[i]];
                if (p.hasDeposited && p.depositReceived > 0) {
                    p.withdrawableAmount = (p.depositReceived * totalAssets) / totalPrincipal;
                }
            }
            // Scale down creator prize proportionally
            uint256 scaledCreatorPrize = (creatorPrize * totalAssets) / totalPrincipal;
            totalDeposited = totalAssets - scaledCreatorPrize;
            creatorPrize = scaledCreatorPrize;
        }

        // Deduct protocol fee from ALL yield (including yield from creator prize capital)
        uint256 protocolFee = 0;
        if (protocolFeePercentage > 0 && protocolFeeRecipient != address(0) && yieldGenerated > 0) {
            protocolFee = (yieldGenerated * protocolFeePercentage) / 10000;
            if (protocolFee > 0) {
                // Use try/catch so a reverting feeRecipient cannot lock contest funds.
                // On failure, fee stays in the contest and is distributed to winners.
                // Use safeTransfer (handles non-standard ERC20s) via external self-call
                // so try/catch can still protect against a reverting feeRecipient.
                try this.executeProtocolFeeTransfer(protocolFeeRecipient, protocolFee) {
                    emit ProtocolFeeDeducted(protocolFee, protocolFeeRecipient);
                } catch {
                    emit ProtocolFeeSkipped(protocolFee, protocolFeeRecipient, "transfer reverted");
                    protocolFee = 0; // transfer reverted — skip fee, yield goes to winners
                }
            }
        }
        uint256 distributableYield = yieldGenerated - protocolFee;

        // Full prize pool = (yield after fees) + creator prize principal.
        // The whole pool flows to voters per prizeConfig.model — the legacy
        // voter/option split has been removed (option pool was never paid out).
        uint256 totalPrizePool = distributableYield + creatorPrize;

        results.totalYield = totalPrizePool;
        results.voterRewardsPool = totalPrizePool;

        _determineWinners();      // option ranking (display + winningOption)

        // If a resolver gave us an authoritative winner, override the
        // vote-determined winningOption. _calculateVoterScores reads
        // results.winningOption when scoring VOTE/PREDICT contests, so this
        // is what flips rewards from "majority vote was right" to "voters
        // who matched the real-world outcome win."
        if (resolverUsed) {
            results.winningOption = resolverWinner;
        }

        _calculateVoterScores();  // per-voter score (scoring still proportional)

        // Branch on prize model:
        //   - Deterministic models: distribute now, finalize.
        //   - VRF models: request randomness and park in AWAITING_VRF until
        //     fulfillRandomness callback completes the distribution.
        PrizeModel model = _prizeConfig.model;
        if (model == PrizeModel.SINGLE_RANDOM || model == PrizeModel.TOP_N_RANDOM) {
            // Use the contest address as the request key (clones are unique).
            bytes32 key = bytes32(uint256(uint160(address(this))));
            vrfRequestKey = key;
            vrfRequestedAt = block.timestamp;
            randomnessManager.requestRandomness(key);
            _transitionState(ContestState.AWAITING_VRF);
            emit VRFResolutionRequested(key, block.timestamp);
            return;
        }

        // Deterministic: distribute and finalize in this tx. randomWord = 0 ignored.
        _executeDistribution(model, totalPrizePool, 0);
        results.isResolved = true;
        _transitionState(ContestState.FINALIZED);
        emit ContestResolved(results.winningOption, distributableYield);
    }

    // ============ VRF Callback + Fallback ============

    /// @notice VRF callback for *_RANDOM prize models.
    /// @dev Only callable by the configured randomnessManager (mirrors the
    ///      lottery's pattern). Distribution runs inside this callback so the
    ///      contest atomically transitions AWAITING_VRF → FINALIZED.
    function fulfillRandomness(uint256 randomWord) external nonReentrant {
        if (msg.sender != address(randomnessManager)) revert NotAuthorized();
        if (state != ContestState.AWAITING_VRF) revert VRFNotPending();

        _executeDistribution(_prizeConfig.model, results.voterRewardsPool, randomWord);

        results.isResolved = true;
        _transitionState(ContestState.FINALIZED);
        emit ContestResolved(results.winningOption, results.voterRewardsPool);
    }

    /// @notice Force a deterministic fallback if VRF never delivers.
    /// @dev    Audit M-05: callable by creator OR factory between
    ///         vrfRequestedAt + VRF_TIMEOUT (24h) and vrfRequestedAt +
    ///         FALLBACK_PUBLIC_AFTER (7d). After 7d anyone can call so a
    ///         disengaged creator cannot indefinitely hold the contest in
    ///         AWAITING_VRF.
    ///         Falls back to the deterministic equivalent of the configured
    ///         random model (SINGLE_RANDOM → SINGLE_TOP, TOP_N_RANDOM →
    ///         TOP_N_RANKED), preserving fairness via score-ranking.
    function forceDeterministicFallback() external nonReentrant {
        if (state != ContestState.AWAITING_VRF) revert VRFNotPending();
        if (block.timestamp < vrfRequestedAt + VRF_TIMEOUT) revert VRFTimeoutNotReached();
        // Creator/factory window: VRF_TIMEOUT … VRF_TIMEOUT + FALLBACK_PUBLIC_AFTER
        // After that window, anyone can call.
        if (block.timestamp < vrfRequestedAt + VRF_TIMEOUT + FALLBACK_PUBLIC_AFTER) {
            if (msg.sender != creator && msg.sender != factory) revert NotAuthorized();
        }

        PrizeModel original = _prizeConfig.model;
        PrizeModel fallbackModel = original == PrizeModel.SINGLE_RANDOM
            ? PrizeModel.SINGLE_TOP
            : PrizeModel.TOP_N_RANKED;

        _executeDistribution(fallbackModel, results.voterRewardsPool, 0);

        results.isResolved = true;
        _transitionState(ContestState.FINALIZED);
        emit VRFFallbackUsed(original, fallbackModel);
        emit ContestResolved(results.winningOption, results.voterRewardsPool);
    }

    // ============ Withdrawal Functions ============

    function withdrawPrincipal() external nonReentrant {
        if (!(state == ContestState.FINALIZED || state == ContestState.CANCELLED)) revert InvalidConfig();

        Participant storage p = participants[msg.sender];
        if (!p.hasDeposited) revert NotDeposited();
        if (!(!p.principalWithdrawn)) revert InvalidConfig();

        p.principalWithdrawn = true;

        // Funds already withdrawn to this contract in resolveContest() or _cancel()
        // Use withdrawableAmount if set (strategy loss scenario), else depositReceived
        uint256 amount = p.withdrawableAmount > 0 ? p.withdrawableAmount : p.depositReceived;
        if (!(amount > 0)) revert InvalidConfig();
        IERC20(config.depositToken).safeTransfer(msg.sender, amount);

        emit PrincipalWithdrawn(msg.sender, amount);
    }

    function claimVoterReward() external nonReentrant inState(ContestState.FINALIZED) {
        Participant storage p = participants[msg.sender];
        if (!p.hasRevealed) revert InvalidConfig();
        if (p.rewardsClaimed) revert AlreadyClaimed();

        uint256 reward = voterRewards[msg.sender];
        if (reward == 0) revert NoReward();

        p.rewardsClaimed = true;

        // Transfer reward
        IERC20(config.depositToken).safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    /// @notice Claim undistributed voter rewards (rounding dust) — creator only
    function claimUndistributedRewards() external onlyCreator nonReentrant inState(ContestState.FINALIZED) {
        uint256 dust = undistributedRewards;
        if (!(dust > 0)) revert InvalidConfig();
        undistributedRewards = 0;
        IERC20(config.depositToken).safeTransfer(creator, dust);
    }

    // ============ State Management ============

    function updateState() external {
        // Submission phase removed in 2026-04 slim-down — initialize() rejects
        // any contest with `submissionConfig.enabled == true`, so SUBMISSION_*
        // states are unreachable.
        if (state == ContestState.DEPOSIT_OPEN && block.timestamp >= config.depositEnd) {
            if (participantList.length < config.minParticipants) {
                _cancel("Minimum participants not reached");
            } else {
                _transitionState(ContestState.DEPOSIT_CLOSED);
            }
            return;
        }

        // DEPOSIT_CLOSED → LOCKED when deposit period ends (lock period begins)
        if (state == ContestState.DEPOSIT_CLOSED && block.timestamp >= config.depositEnd) {
            _transitionState(ContestState.LOCKED);
            return;
        }

        // LOCKED → REVEAL_OPEN when lock period ends (same timestamp — transitions immediately)
        if (state == ContestState.LOCKED && block.timestamp >= config.lockEnd) {
            _transitionState(ContestState.REVEAL_OPEN);
            return;
        }
    }

    function cancel(string calldata reason) external onlyCreator nonReentrant {
        if (state == ContestState.FINALIZED) revert AlreadyFinalized();
        if (state == ContestState.CANCELLED) revert AlreadyCancelled();
        _cancel(reason);
    }

    /// @notice Emergency cancel by factory — bypasses creator-only restriction
    /// @dev Allows factory/admin to cancel stuck or malicious contests
    function emergencyCancel() external onlyFactory nonReentrant {
        if (state == ContestState.FINALIZED) revert AlreadyFinalized();
        if (state == ContestState.CANCELLED) revert AlreadyCancelled();
        _cancel("Emergency cancel by factory");
    }

    // ============ View Functions ============

    function getParticipantCount() external view returns (uint256) {
        return participantList.length;
    }

    function getOptions() external view returns (bytes32[] memory) {
        return options;
    }

    function getOptionVotes(bytes32 optionId) external view returns (uint256) {
        return optionVotes[optionId];
    }

    function getVoterReward(address voter) external view returns (uint256) {
        return voterRewards[voter];
    }

    function getParticipant(address addr) external view returns (Participant memory) {
        return participants[addr];
    }

    function getResults() external view returns (ContestResults memory) {
        return results;
    }

    function getConfig() external view returns (ContestConfig memory) {
        return config;
    }

    /// @notice Returns the prize config (replaces auto-generated getter, which
    ///         can't return the dynamic `splitsBps` array via tuple unpacking).
    function getPrizeConfig() external view returns (PrizeConfig memory) {
        return _prizeConfig;
    }

    // ============ Protocol Fee Helper ============

    /// @notice External helper for try/catch safeTransfer of protocol fees.
    /// @dev Only callable by this contract itself (via `this.executeProtocolFeeTransfer`).
    function executeProtocolFeeTransfer(address recipient, uint256 amount) external {
        if (!(msg.sender == address(this))) revert InvalidConfig();
        IERC20(config.depositToken).safeTransfer(recipient, amount);
    }

    // ============ Resolver Lookup ============

    /// @notice Read the resolver bound to this contest from the factory.
    /// @dev Kept as a staticcall instead of an interface import so adding the
    ///      resolver feature doesn't cascade into every test that builds a
    ///      mock factory. Returns address(0) (no resolver configured) on any
    ///      failure — the resolve path then behaves identically to the
    ///      pre-resolver flow.
    function _resolverAddress() internal view returns (address) {
        (bool ok, bytes memory ret) = factory.staticcall(
            abi.encodeWithSignature("resolverForContest(address)", address(this))
        );
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    // ============ Internal Functions ============

    function _processVote(address voter, bytes calldata voteData) internal {
        // Decode and process based on contest type, validating all option IDs
        if (config.contestType == ContestType.VOTE) {
            bytes32 selectedOption = abi.decode(voteData, (bytes32));
            if (!validOptions[selectedOption]) revert InvalidOption();
            optionVotes[selectedOption]++;
        }
        else if (config.contestType == ContestType.RANK) {
            bytes32[] memory ranking = abi.decode(voteData, (bytes32[]));
            // Ranking must cover all options
            if (!(ranking.length == options.length)) revert InvalidConfig();
            if (!(options.length <= 256)) revert InvalidConfig();
            // Bitmap dedup: validate options and check for duplicates in O(n)
            // Options are capped at 100, so a uint256 bitmap (256 bits) is sufficient
            uint256 bitmap = 0;
            for (uint256 i = 0; i < ranking.length; i++) {
                if (!(validOptions[ranking[i]])) revert InvalidConfig();
                uint256 idx = _getOptionIndex(ranking[i]);
                if (!(bitmap & (1 << idx) == 0)) revert InvalidConfig();
                bitmap |= (1 << idx);
            }
            // Borda count scoring
            for (uint256 i = 0; i < ranking.length; i++) {
                uint256 points = ranking.length - i;
                optionTotalScore[ranking[i]] += points;
            }
        }
        else if (config.contestType == ContestType.RATE) {
            (bytes32[] memory optionIds, uint256[] memory ratings) = abi.decode(voteData, (bytes32[], uint256[]));
            if (!(optionIds.length == ratings.length)) revert InvalidConfig();
            if (!(optionIds.length <= 100)) revert InvalidConfig();
            for (uint256 i = 0; i < optionIds.length; i++) {
                if (!(validOptions[optionIds[i]])) revert InvalidConfig();
                if (!(ratings[i] >= 1 && ratings[i] <= 10)) revert InvalidConfig();
                optionVotes[optionIds[i]]++;
                optionTotalScore[optionIds[i]] += ratings[i];
            }
        }
        else if (config.contestType == ContestType.PREDICT) {
            (bytes32 prediction, uint256 confidence) = abi.decode(voteData, (bytes32, uint256));
            if (!(validOptions[prediction])) revert InvalidConfig();
            optionVotes[prediction]++;
            // Store confidence for accuracy-weighted rewards
            participants[voter].score = confidence;
        }
        else if (config.contestType == ContestType.PAIRWISE) {
            bytes32[] memory choices = abi.decode(voteData, (bytes32[]));
            for (uint256 i = 0; i < choices.length; i++) {
                if (!(validOptions[choices[i]])) revert InvalidConfig();
                optionVotes[choices[i]]++;
            }
        }
    }

    function _determineWinners() internal {
        // Pull per-option vote/total arrays into memory so the pure library call
        // doesn't need storage references. ContestScoring.determineWinners then
        // does the math + sort, and we write the result tuple back to storage.
        uint256 n = options.length;
        uint256[] memory votes = new uint256[](n);
        uint256[] memory totals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            votes[i] = optionVotes[options[i]];
            totals[i] = optionTotalScore[options[i]];
        }

        (
            bytes32[] memory ranked,
            uint256[] memory scores,
            bytes32 winningOption
        ) = ContestScoring.determineWinners(options, uint8(config.contestType), votes, totals);

        results.rankedOptions = ranked;
        results.optionScores = scores;
        results.winningOption = winningOption;
    }

    function _calculateVoterScores() internal {
        bytes32 winner = results.winningOption;

        for (uint256 i = 0; i < participantList.length; i++) {
            address voter = participantList[i];
            Participant storage p = participants[voter];

            if (!p.hasRevealed) continue;

            uint256 score = 0;

            if (config.contestType == ContestType.VOTE || config.contestType == ContestType.PREDICT) {
                bytes32 selected = abi.decode(p.revealedData, (bytes32));
                if (selected == winner) {
                    score = 100;
                    // Apply confidence multiplier for predictions
                    if (config.contestType == ContestType.PREDICT && p.score > 0) {
                        score = score * (10000 + (p.score * scoringConfig.confidenceMultiplier / 100)) / 10000;
                    }
                }
            }
            else if (config.contestType == ContestType.RANK) {
                bytes32[] memory ranking = abi.decode(p.revealedData, (bytes32[]));
                score = ContestScoring.calculateRankingScore(ranking, results.rankedOptions);
            }
            else if (config.contestType == ContestType.RATE) {
                (bytes32[] memory optionIds, uint256[] memory ratings) = abi.decode(p.revealedData, (bytes32[], uint256[]));
                score = ContestScoring.calculateRatingScore(optionIds, ratings, optionVotes, optionTotalScore);
            }

            // Apply early voter bonus (skip if commitTimestamp < depositStart to prevent underflow)
            if (scoringConfig.earlyVoterBonus > 0 && p.commitTimestamp > 0 && p.commitTimestamp >= config.depositStart) {
                uint256 votingPeriod = config.lockEnd - config.depositStart;
                uint256 voteTime = p.commitTimestamp - config.depositStart;
                uint256 earlyFactor = ((votingPeriod - voteTime) * scoringConfig.earlyVoterBonus) / votingPeriod;
                score = score * (10000 + earlyFactor) / 10000;
            }

            p.score = score;
        }
    }

    // Scoring functions extracted to ContestScoring library for bytecode size reduction

    /// @notice Build the eligible-voter array for distribution.
    /// @dev Eligibility = hasRevealed && score >= prizeConfig.eligibilityThreshold.
    ///      The legacy code also gated on scoringConfig.correlationThreshold —
    ///      we keep correlationThreshold for score *calculation* (handled in
    ///      _calculateVoterScores) and use eligibilityThreshold here for
    ///      *eligibility for prize* (separation of concerns).
    function _buildEligibles() internal view returns (PrizeDistribution.Eligible[] memory) {
        uint256 threshold = _prizeConfig.eligibilityThreshold;
        uint256 n = participantList.length;

        // First pass: count eligibles.
        uint256 count;
        for (uint256 i = 0; i < n; ) {
            address voter = participantList[i];
            Participant storage p = participants[voter];
            if (p.hasRevealed && p.score >= threshold) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        // Second pass: populate.
        PrizeDistribution.Eligible[] memory out = new PrizeDistribution.Eligible[](count);
        uint256 cursor;
        for (uint256 i = 0; i < n; ) {
            address voter = participantList[i];
            Participant storage p = participants[voter];
            if (p.hasRevealed && p.score >= threshold) {
                out[cursor] = PrizeDistribution.Eligible({voter: voter, score: p.score});
                unchecked { ++cursor; }
            }
            unchecked { ++i; }
        }
        return out;
    }

    /// @dev In-place rewrite for STAKE_WEIGHTED: replace each eligible's
    ///      score with that voter's depositReceived so the existing
    ///      distributeProportional math (pool * weight / totalWeight) yields
    ///      stake-proportional payouts. Voters whose original score was zero
    ///      (didn't vote, didn't match the winner) KEEP weight 0 so they
    ///      get no payout — preserving the "only winners earn yield"
    ///      property. Eligibles is a memory array; participants storage is
    ///      not mutated.
    function _rewriteScoresWithStake(PrizeDistribution.Eligible[] memory eligibles) internal view {
        uint256 n = eligibles.length;
        for (uint256 i = 0; i < n; ) {
            if (eligibles[i].score > 0) {
                eligibles[i].score = participants[eligibles[i].voter].depositReceived;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Execute prize distribution (deterministic OR random) via the library
    ///         dispatcher and persist results. Used by the synchronous resolution
    ///         path, the VRF callback, and the VRF-timeout deterministic fallback.
    /// @dev    For STAKE_WEIGHTED the eligibles array is in-place rewritten so each
    ///         voter's score becomes their depositReceived; the library then runs
    ///         proportional math on those weights.
    function _executeDistribution(PrizeModel model, uint256 pool, uint256 randomWord) internal {
        if (pool == 0) {
            emit PrizeDistributionFinalized(model, new address[](0), new uint256[](0), 0);
            return;
        }

        PrizeDistribution.Eligible[] memory eligibles = _buildEligibles();
        if (model == PrizeModel.STAKE_WEIGHTED) {
            _rewriteScoresWithStake(eligibles);
        }

        (address[] memory winners, uint256[] memory amounts) = PrizeDistribution.distribute(
            uint8(model),
            eligibles,
            pool,
            _prizeConfig.splitsBps,
            randomWord,
            _prizeConfig.weightedByScore
        );

        _persistDistribution(model, pool, winners, amounts);
    }

    /// @dev Write distribution results to storage and emit summary events.
    ///      Shared by all three execution paths.
    function _persistDistribution(
        PrizeModel model,
        uint256 pool,
        address[] memory winners,
        uint256[] memory amounts
    ) internal {
        uint256 distributed;
        for (uint256 i = 0; i < winners.length; ) {
            // Sum first so we can compute dust without a second loop.
            distributed += amounts[i];
            voterRewards[winners[i]] = amounts[i];
            unchecked { ++i; }
        }

        totalVoterRewardsDistributed = distributed;
        undistributedRewards = pool - distributed;

        emit VoterRewardsDistributed(distributed, winners.length);
        emit PrizeDistributionFinalized(model, winners, amounts, undistributedRewards);
    }

    function _transitionState(ContestState newState) internal {
        state = newState;
        emit StateChanged(newState);
    }

    /// @dev Returns the index of an option in the options array (for bitmap dedup)
    function _getOptionIndex(bytes32 option) internal view returns (uint256) {
        for (uint256 i = 0; i < options.length; i++) {
            if (options[i] == option) return i;
        }
        revert InvalidConfig();
    }

    function _cancel(string memory reason) internal {
        // Withdraw all funds from vault (participant deposits + creator prize + yield)
        if (vaultShares > 0) {
            uint256 returned = yieldVault.withdraw(config.depositToken, vaultShares, 0, address(this));
            if (!(returned > 0 || (totalDeposited == 0 && creatorPrize == 0))) revert InvalidConfig();
            vaultShares = 0;

            uint256 totalPrincipal = totalDeposited + creatorPrize;

            if (totalPrincipal > 0) {
                if (returned < totalPrincipal) {
                    // Strategy loss: pro-rata for both participants and creator prize
                    for (uint256 i = 0; i < participantList.length; i++) {
                        Participant storage p = participants[participantList[i]];
                        if (p.hasDeposited && !p.principalWithdrawn && p.depositReceived > 0) {
                            p.withdrawableAmount = (p.depositReceived * returned) / totalPrincipal;
                        }
                    }
                    // Return creator prize pro-rata
                    if (creatorPrize > 0) {
                        uint256 creatorRefund = (creatorPrize * returned) / totalPrincipal;
                        creatorPrize = 0;
                        if (creatorRefund > 0) {
                            IERC20(config.depositToken).safeTransfer(creator, creatorRefund);
                            emit CreatorPrizeRefunded(creator, creatorRefund);
                        }
                    }
                } else {
                    // No loss: participants get exact deposits.
                    uint256 surplus = returned - totalDeposited;
                    if (creatorPrize > 0) {
                        // Sponsored / boosted contest — surplus (= sponsor prize +
                        // accrued yield) goes back to the creator, mirroring
                        // a normal cancel refund.
                        creatorPrize = 0;
                        if (surplus > 0) {
                            IERC20(config.depositToken).safeTransfer(creator, surplus);
                            emit CreatorPrizeRefunded(creator, surplus);
                        }
                    } else if (surplus > 0) {
                        // Audit L-05: normal contest with no creator prize. The
                        // surplus is pure yield. Sweep it to the protocol fee
                        // recipient instead of leaving it stuck in the contract
                        // forever. Mirrors MirrorContestV2's protocol-surplus
                        // handling on cancel.
                        // Wrap in try/catch: a blacklisted protocolFeeRecipient must not
                        // permanently block cancel and trap participant principal.
                        try this.executeProtocolFeeTransfer(protocolFeeRecipient, surplus) {
                            emit TreasuryFeeClaimed(surplus, protocolFeeRecipient);
                        } catch {
                            emit ProtocolFeeSkipped(surplus, protocolFeeRecipient, "cancel: transfer reverted");
                        }
                    }
                }
            }
        }
        _transitionState(ContestState.CANCELLED);
        emit ContestCancelled(reason);
    }
}
