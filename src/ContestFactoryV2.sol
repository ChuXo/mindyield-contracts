// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ContestV2.sol";
import "./interfaces/IResolver.sol";

/**
 * @title ContestFactoryV2
 * @notice Factory for creating enhanced contests with full configuration
 * @dev Uses minimal proxy pattern for gas-efficient deployment
 */
contract ContestFactoryV2 is Ownable2Step {
    using Clones for address;
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    address public contestImplementation;
    address public yieldVault;
    address public identityRegistry;
    address public randomnessManager;
    address public dataRegistry;
    address public reputationRegistry;

    // Protocol fee settings
    uint256 public protocolFeePercentage = 200; // 2% in basis points
    address public immutable feeRecipient;
    bool public feeEnabled = true;              // Global toggle — when false, new contests get 0% fee
    uint256 public contestCreationFee;          // Flat fee in deposit token to create a contest (default: 0)

    // ── Mirror-contest economics ────────────────────────────────────────
    // Mirror contests rely on an off-chain relayer that pays Base ETH
    // gas (~$0.05) for each propose() call to the resolver. To make that
    // sustainable independent of yield revenue, mirror creators pay a
    // small USDC-denominated fee at creation that funds the relayer
    // wallet. Both fields are owner-settable; default 0 means "no fee".
    uint256 public mirrorResolverFee;            // USDC (6-dec), per-contest
    address public resolverTreasury;             // destination for relayer top-ups

    /// @notice Maximum allowed total contest duration (depositStart to revealEnd)
    uint256 public constant MAX_CONTEST_DURATION = 365 days;

    /// @notice Hard ceiling for protocol fee — 5%.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500;

    // ─── Pausable (per-factory; gates new contest creation only) ──────────
    // Mirrors the YieldVault / AutoYieldVault pattern: Guardian (cold key)
    // can pause without timelock; unpause is owner-only. Pause halts NEW
    // contest creation only — every existing ContestV2 clone reads this
    // factory's `paused()` to decide whether to accept new deposits, votes
    // and reveals; `resolveContest`, `withdrawPrincipal`, refunds and claims
    // are NEVER gated by pause so principal redemption always works.
    bool public paused;
    address public guardian;
    event ContestFactoryPaused(address indexed by, uint256 timestamp);
    event ContestFactoryUnpaused(address indexed by, uint256 timestamp);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    error Paused();
    error NotPaused();
    error NotGuardianOrOwner();
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // Nonce for unique contest ID generation
    uint256 private _contestNonce;

    // Contest tracking
    mapping(bytes32 => address) public contests;
    bytes32[] public contestIds;
    mapping(address => bytes32[]) public creatorContests;

    // Resolver binding — ContestV2 queries this via staticcall at resolve time.
    // Zero address (default) means "no resolver; resolve by voter plurality"
    // i.e. the pre-resolver behavior. Set exactly once at contest creation by
    // createCustomContestWithResolver / createContestFromTemplateWithResolver.
    mapping(address => address) public resolverForContest;

    // Template settings (stored on-chain for reference)
    mapping(bytes32 => ContestTemplate) public templates;
    bytes32[] public templateIds;

    struct ContestTemplate {
        bytes32 id;
        string name;
        ContestV2.ContestType contestType;
        ContestV2.PrizeModel prizeModel;
        ContestV2.WinnerDetermination winnerDetermination;
        ContestV2.VoterRewardDistribution voterRewardDistribution;
        uint256 defaultDepositPeriod;
        uint256 defaultLockPeriod;
        uint256 defaultRevealPeriod;
        uint256 minParticipants;
        uint256 maxParticipants;
        /// @notice Default basis-point splits for TOP_N_* templates.
        ///         Empty for PROPORTIONAL/SINGLE_TOP/SINGLE_RANDOM.
        ///         Stored separately because Solidity nested storage arrays
        ///         can't be set in struct literals — see _setTemplateSplits.
        uint256 defaultEligibilityThreshold;
        bool defaultWeightedByScore;
        bool requiresOracle;
        bool isActive;
    }

    /// @notice Per-template default splitsBps. Stored separately from the
    ///         ContestTemplate struct because Solidity disallows dynamic-array
    ///         struct fields in storage struct-literal assignments.
    mapping(bytes32 => uint16[]) public templateSplitsBps;

    // ============ Events ============

    event ContestCreated(
        bytes32 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        bytes32 templateId
    );
    event VRFRegistrationResult(address indexed contestAddress, bool success);
    event TemplateCreated(bytes32 indexed templateId, string name);
    event TemplateUpdated(bytes32 indexed templateId);
    event ProtocolFeeUpdated(uint256 newFee);
    event FeeEnabledUpdated(bool enabled);
    event ContestCreationFeeUpdated(uint256 newFee);
    event ImplementationUpdated(address newImplementation);
    // FeeRecipientUpdated event removed 2026-04-28 — recipient is now immutable.
    event IdentityRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event YieldVaultUpdated(address indexed oldVault, address indexed newVault);

    // ============ Constructor ============

    constructor(
        address _contestImplementation,
        address _yieldVault,
        address _identityRegistry,
        address _randomnessManager,
        address _feeRecipient
    ) Ownable() {
        require(_contestImplementation != address(0), "ContestFactoryV2: zero implementation");
        require(_feeRecipient != address(0), "ContestFactoryV2: zero fee recipient");
        contestImplementation = _contestImplementation;
        yieldVault = _yieldVault;
        identityRegistry = _identityRegistry;
        randomnessManager = _randomnessManager;
        feeRecipient = _feeRecipient;

        _initializeDefaultTemplates();
    }

    // ============ Contest Creation ============

    /**
     * @notice Create a contest from a template with custom parameters
     */
    function createContestFromTemplate(
        bytes32 templateId,
        CreateContestParams calldata params
    ) external whenNotPaused returns (bytes32 contestId, address contestAddress) {
        return _createFromTemplateInternal(templateId, params, msg.sender);
    }

    /// @notice Resolver-bound counterpart of {createContestFromTemplate}.
    ///         Same semantics as {createCustomContestWithResolver}: binds
    ///         `resolver` to the new contest and calls its `register()`.
    function createContestFromTemplateWithResolver(
        bytes32 templateId,
        CreateContestParams calldata params,
        address resolver,
        bytes calldata resolverParams
    ) external whenNotPaused returns (bytes32 contestId, address contestAddress) {
        require(resolver != address(0), "ContestFactoryV2: zero resolver");

        (contestId, contestAddress) = _createFromTemplateInternal(
            templateId, params, msg.sender
        );

        resolverForContest[contestAddress] = resolver;
        IResolver(resolver).register(
            bytes32(uint256(uint160(contestAddress))),
            resolverParams
        );
        emit ResolverBound(contestAddress, resolver);
    }

    function _createFromTemplateInternal(
        bytes32 templateId,
        CreateContestParams calldata params,
        address creator
    ) internal returns (bytes32 contestId, address contestAddress) {
        ContestTemplate storage template = templates[templateId];
        require(template.isActive, "ContestFactoryV2: template not active");
        require(params.depositToken != address(0), "ContestFactoryV2: zero deposit token");

        // Generate contest ID (nonce prevents same-block collisions)
        contestId = keccak256(abi.encodePacked(
            creator,
            block.timestamp,
            params.metadataHash,
            _contestNonce++
        ));
        require(contests[contestId] == address(0), "ContestFactoryV2: contest exists");

        // Clone implementation
        contestAddress = contestImplementation.clone();

        // Build config from template + params
        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken: params.depositToken,
            depositAmount: params.depositAmount,
            minParticipants: params.minParticipants > 0 ? params.minParticipants : template.minParticipants,
            maxParticipants: params.maxParticipants > 0 ? params.maxParticipants : template.maxParticipants,
            depositStart: params.depositStart > 0 ? params.depositStart : block.timestamp,
            depositEnd: params.depositEnd > 0 ? params.depositEnd : block.timestamp + template.defaultDepositPeriod,
            lockEnd: params.lockEnd > 0 ? params.lockEnd : block.timestamp + template.defaultDepositPeriod + template.defaultLockPeriod,
            revealEnd: params.revealEnd > 0 ? params.revealEnd : block.timestamp + template.defaultDepositPeriod + template.defaultLockPeriod + template.defaultRevealPeriod,
            contestType: template.contestType,
            winnerDetermination: template.winnerDetermination,
            voterRewardDistribution: template.voterRewardDistribution,
            tierRequired: params.tierRequired,
            quorumPercentage: params.quorumPercentage > 0 ? params.quorumPercentage : 50,
            requiresOracle: template.requiresOracle,
            metadataHash: params.metadataHash,
            metadataUri: params.metadataUri
        });

        // Build prize config from template + overrides.
        // Defaults come from the template; explicit non-empty splitsBps / non-zero
        // threshold overrides them. ContestV2.initialize validates the final shape.
        // Solidity can't unify calldata vs storage in a ternary, so resolve splits
        // explicitly into a memory array.
        uint16[] memory effectiveSplits;
        if (params.splitsBps.length > 0) {
            effectiveSplits = new uint16[](params.splitsBps.length);
            for (uint256 i = 0; i < params.splitsBps.length; i++) {
                effectiveSplits[i] = params.splitsBps[i];
            }
        } else {
            uint16[] storage tplSplits = templateSplitsBps[templateId];
            effectiveSplits = new uint16[](tplSplits.length);
            for (uint256 i = 0; i < tplSplits.length; i++) {
                effectiveSplits[i] = tplSplits[i];
            }
        }
        ContestV2.PrizeConfig memory prize = ContestV2.PrizeConfig({
            model: template.prizeModel,
            splitsBps: effectiveSplits,
            eligibilityThreshold: params.eligibilityThreshold > 0
                ? params.eligibilityThreshold
                : template.defaultEligibilityThreshold,
            weightedByScore: params.overrideWeightedByScore
                ? params.weightedByScore
                : template.defaultWeightedByScore
        });

        ContestV2.ScoringConfig memory scoringConfig = ContestV2.ScoringConfig({
            correlationThreshold: params.correlationThreshold > 0 ? params.correlationThreshold : 5000, // 50%
            topPercentile: params.topPercentile > 0 ? params.topPercentile : 2500, // 25%
            confidenceMultiplier: params.confidenceMultiplier > 0 ? params.confidenceMultiplier : 5000, // 50%
            earlyVoterBonus: params.earlyVoterBonus
        });

        // Default disabled submission config (can be enabled via params)
        ContestV2.SubmissionConfig memory submissionConfig = ContestV2.SubmissionConfig({
            enabled: false,
            submissionStart: 0,
            submissionEnd: 0,
            maxPerUser: 0,
            requiresModeration: false,
            paymentModel: ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0,
            minSubmissions: 0,
            maxTotalSubmissions: 0
        });

        // Validate timing: all timestamps must be in the future and properly ordered
        require(config.depositStart >= block.timestamp, "ContestFactoryV2: depositStart must be in the future");
        require(config.depositEnd > config.depositStart + 1 hours, "ContestFactoryV2: deposit period too short");
        require(config.lockEnd > config.depositEnd, "ContestFactoryV2: lockEnd must be after depositEnd");
        require(config.revealEnd > config.lockEnd, "ContestFactoryV2: revealEnd must be after lockEnd");
        require(config.revealEnd - config.depositStart <= MAX_CONTEST_DURATION, "ContestFactoryV2: contest duration exceeds maximum");

        // Fully sponsored contests must have a creator prize
        if (params.depositAmount == 0) {
            require(params.creatorPrize > 0, "ContestFactoryV2: sponsored contest needs prize");
        }

        // Charge contest creation fee (if set and fee is enabled)
        if (contestCreationFee > 0 && feeEnabled && feeRecipient != address(0)) {
            IERC20(params.depositToken).safeTransferFrom(creator, feeRecipient, contestCreationFee);
        }

        // Transfer creator prize to contest address (will be deposited to vault in initialize)
        if (params.creatorPrize > 0) {
            IERC20(params.depositToken).safeTransferFrom(creator, contestAddress, params.creatorPrize);
        }

        // Determine effective protocol fee (0 when fees globally disabled)
        uint256 effectiveFee = feeEnabled ? protocolFeePercentage : 0;

        // Initialize contest
        ContestV2(contestAddress).initialize(
            creator,
            config,
            prize,
            scoringConfig,
            submissionConfig,
            yieldVault,
            identityRegistry,
            randomnessManager,
            params.oracle,
            params.options,
            effectiveFee,
            feeRecipient,
            params.creatorPrize
        );

        // Register contest as allowed VRF requester — reverts if registration fails
        // to prevent creating contests that cannot request randomness
        if (randomnessManager != address(0)) {
            (bool ok,) = randomnessManager.call(
                abi.encodeWithSignature("addAllowedRequester(address)", contestAddress)
            );
            require(ok, "ContestFactoryV2: VRF registration failed");
        }

        // Track contest
        contests[contestId] = contestAddress;
        contestIds.push(contestId);
        creatorContests[creator].push(contestId);

        emit ContestCreated(contestId, contestAddress, creator, templateId);

        return (contestId, contestAddress);
    }

    /**
     * @notice Create a fully custom contest
     */
    function createCustomContest(
        ContestV2.ContestConfig calldata config,
        ContestV2.PrizeConfig calldata prize,
        ContestV2.ScoringConfig calldata scoringConfig,
        ContestV2.SubmissionConfig calldata submissionConfig,
        address oracle,
        bytes32[] calldata options,
        uint256 creatorPrize_
    ) external whenNotPaused returns (bytes32 contestId, address contestAddress) {
        return _createCustomInternal(
            config, prize, scoringConfig, submissionConfig,
            oracle, options, creatorPrize_, msg.sender
        );
    }

    /// @notice Resolver-bound counterpart of {createCustomContest}. The
    ///         contest is permanently bound to `resolver` at creation and
    ///         `resolver.register()` is called so the resolver can stash
    ///         its per-contest config. PREDICT contests should use this
    ///         variant — a PREDICT without a resolver falls back to
    ///         plurality voting, which is not what prediction-market UX
    ///         should deliver.
    /// @dev    `contestKey` passed to the resolver is
    ///         `bytes32(uint256(uint160(contestAddress)))`; ContestV2 uses
    ///         the same derivation when it calls `resolver.resolve(...)`.
    function createCustomContestWithResolver(
        ContestV2.ContestConfig calldata config,
        ContestV2.PrizeConfig calldata prize,
        ContestV2.ScoringConfig calldata scoringConfig,
        ContestV2.SubmissionConfig calldata submissionConfig,
        address oracle,
        bytes32[] calldata options,
        uint256 creatorPrize_,
        address resolver,
        bytes calldata resolverParams
    ) external whenNotPaused returns (bytes32 contestId, address contestAddress) {
        require(resolver != address(0), "ContestFactoryV2: zero resolver");

        (contestId, contestAddress) = _createCustomInternal(
            config, prize, scoringConfig, submissionConfig,
            oracle, options, creatorPrize_, msg.sender
        );

        resolverForContest[contestAddress] = resolver;
        IResolver(resolver).register(
            bytes32(uint256(uint160(contestAddress))),
            resolverParams
        );
        emit ResolverBound(contestAddress, resolver);
    }

    function _createCustomInternal(
        ContestV2.ContestConfig memory config,
        ContestV2.PrizeConfig memory prize,
        ContestV2.ScoringConfig memory scoringConfig,
        ContestV2.SubmissionConfig memory submissionConfig,
        address oracle,
        bytes32[] memory options,
        uint256 creatorPrize_,
        address creator
    ) internal returns (bytes32 contestId, address contestAddress) {
        contestId = keccak256(abi.encodePacked(
            creator,
            block.timestamp,
            config.metadataHash,
            _contestNonce++
        ));
        require(contests[contestId] == address(0), "ContestFactoryV2: contest exists");

        // Validate deposit token
        require(config.depositToken != address(0), "ContestFactoryV2: zero deposit token");

        // Validate oracle address when contest requires it
        if (config.requiresOracle) {
            require(oracle != address(0), "ContestFactoryV2: zero oracle address");
        }

        // Validate timing: same constraints as template-based contests
        require(config.depositStart >= block.timestamp, "ContestFactoryV2: depositStart must be in the future");
        require(config.depositEnd > config.depositStart + 1 hours, "ContestFactoryV2: deposit period too short");
        require(config.lockEnd > config.depositEnd, "ContestFactoryV2: lockEnd must be after depositEnd");
        require(config.revealEnd > config.lockEnd, "ContestFactoryV2: revealEnd must be after lockEnd");
        require(config.revealEnd - config.depositStart <= MAX_CONTEST_DURATION, "ContestFactoryV2: contest duration exceeds maximum");

        // Fully sponsored contests must have a creator prize
        if (config.depositAmount == 0) {
            require(creatorPrize_ > 0, "ContestFactoryV2: sponsored contest needs prize");
        }

        contestAddress = contestImplementation.clone();

        // Charge contest creation fee (if set and fee is enabled)
        if (contestCreationFee > 0 && feeEnabled && feeRecipient != address(0)) {
            IERC20(config.depositToken).safeTransferFrom(creator, feeRecipient, contestCreationFee);
        }

        // Transfer creator prize to contest address (will be deposited to vault in initialize)
        if (creatorPrize_ > 0) {
            IERC20(config.depositToken).safeTransferFrom(creator, contestAddress, creatorPrize_);
        }

        // Determine effective protocol fee (0 when fees globally disabled)
        uint256 effectiveFee = feeEnabled ? protocolFeePercentage : 0;

        ContestV2(contestAddress).initialize(
            creator,
            config,
            prize,
            scoringConfig,
            submissionConfig,
            yieldVault,
            identityRegistry,
            randomnessManager,
            oracle,
            options,
            effectiveFee,
            feeRecipient,
            creatorPrize_
        );

        // Register contest as allowed VRF requester — reverts if registration fails
        // to prevent creating contests that cannot request randomness
        if (randomnessManager != address(0)) {
            (bool ok,) = randomnessManager.call(
                abi.encodeWithSignature("addAllowedRequester(address)", contestAddress)
            );
            require(ok, "ContestFactoryV2: VRF registration failed");
        }

        contests[contestId] = contestAddress;
        contestIds.push(contestId);
        creatorContests[creator].push(contestId);

        emit ContestCreated(contestId, contestAddress, creator, bytes32(0));

        return (contestId, contestAddress);
    }

    event ResolverBound(address indexed contest, address indexed resolver);

    // ============ Mirror Contest Creation (Polymarket) ============

    /// @notice Minimum identity tier required for participation in
    ///         Polymarket-mirror contests. Tier 2 = "Trusted" (50+
    ///         verification points; multiple social/identity sources).
    ///         Hard floor — creators cannot lower this. Sybil-resistance
    ///         is THE most important guard for prediction markets, given
    ///         that real-money outcomes flow on identity-tied vote shares.
    uint256 public constant MIRROR_MIN_TIER = 2;

    /// @notice Minimum participants required across both YES and NO
    ///         sides in a mirror contest. Lower numbers risk collusion
    ///         contests masquerading as markets.
    uint256 public constant MIRROR_MIN_PARTICIPANTS = 10;

    /// @notice Required gap between depositEnd and the polymarketEndDate.
    ///         Ensures deposits close before the underlying market settles
    ///         so insiders with leaked outcomes cannot deposit on a
    ///         certain win.
    uint256 public constant MIRROR_DEPOSIT_LOCKOUT = 24 hours;

    struct MirrorParams {
        address depositToken;             // typically USDC
        uint256 depositAmount;            // FIXED stake per user (variable
                                          //   stakes are Phase 5b — depositAmount
                                          //   doubles as max for now)
        uint256 maxParticipants;          // hard cap per contest
        uint256 quorumPercentage;         // % of participants who must reveal
        uint256 depositStart;             // unix
        uint256 depositEnd;               // unix; MUST be ≤ polymarketEndDate − MIRROR_DEPOSIT_LOCKOUT
        uint256 lockEnd;                  // unix
        uint256 revealEnd;                // unix; SHOULD be ≥ polymarketEndDate + 36h to absorb dispute window
        bytes32 metadataHash;             // IPFS hash of question text + criteria
        string  metadataUri;              // ipfs:// URI
        // Resolver binding — fully validated by the resolver itself.
        address resolver;                 // PolymarketRelayResolver address
        bytes32 conditionId;              // Polymarket CTF conditionId
        uint64  polymarketEndDate;        // unix; market's settlement timestamp
        bytes32 yesOption;                // optionId for "YES" outcome
        bytes32 noOption;                 // optionId for "NO" outcome
    }

    event MirrorContestCreated(
        bytes32 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        bytes32 conditionId
    );

    /// @notice Create a Polymarket-mirror contest. Bundles the standard
    ///         resolver-bound creation flow with mirror-specific guards
    ///         that cannot be relaxed (anti-sybil, anti-insider).
    /// @dev    Defaults applied automatically:
    ///           - prizeModel: STAKE_WEIGHTED (the prediction-market default)
    ///           - winnerDetermination: ORACLE (resolver overrides plurality)
    ///           - voterRewardDistribution: PROPORTIONAL (matches the model)
    ///           - tierRequired: max(caller's choice, MIRROR_MIN_TIER)
    ///           - requiresOracle: true (resolver provides it)
    ///           - submissions: disabled (binary YES/NO is the option set)
    ///           - creatorPrize: 0 (creator-prize-only contests are
    ///             rejected — too easy to sybil-attack)
    function createMirrorContest(MirrorParams calldata p)
        external
        whenNotPaused
        returns (bytes32 contestId, address contestAddress)
    {
        // ─── Mirror-specific validation ─────────────────────────────
        require(p.resolver != address(0), "Mirror: zero resolver");
        require(p.conditionId != bytes32(0), "Mirror: zero conditionId");
        require(p.yesOption != bytes32(0) && p.noOption != bytes32(0), "Mirror: zero option");
        require(p.yesOption != p.noOption, "Mirror: yes==no");
        require(p.depositAmount > 0, "Mirror: deposit required (sybil risk)");
        require(p.maxParticipants >= MIRROR_MIN_PARTICIPANTS, "Mirror: maxParticipants < 10");

        // Lockout: deposits must close at least MIRROR_DEPOSIT_LOCKOUT
        // before the Polymarket market settles. Catches insider trading
        // on leaked / late-breaking news.
        require(p.polymarketEndDate > 0, "Mirror: zero polymarketEndDate");
        require(
            p.depositEnd + MIRROR_DEPOSIT_LOCKOUT <= uint256(p.polymarketEndDate),
            "Mirror: depositEnd too close to settlement"
        );

        // Reveal window must extend long enough to absorb the resolver's
        // grace + dispute windows. Hardcoded 36h margin (= 12h grace +
        // 24h dispute). Creators can extend further but not shorten.
        require(
            p.revealEnd >= uint256(p.polymarketEndDate) + 36 hours,
            "Mirror: revealEnd too early (grace+dispute)"
        );

        // ─── Build the standard ContestConfig ────────────────────────
        bytes32[] memory options = new bytes32[](2);
        options[0] = p.yesOption;
        options[1] = p.noOption;

        ContestV2.ContestConfig memory cfg = ContestV2.ContestConfig({
            depositToken:            p.depositToken,
            depositAmount:           p.depositAmount,
            minParticipants:         MIRROR_MIN_PARTICIPANTS,
            maxParticipants:         p.maxParticipants,
            depositStart:            p.depositStart > 0 ? p.depositStart : block.timestamp,
            depositEnd:              p.depositEnd,
            lockEnd:                 p.lockEnd,
            revealEnd:               p.revealEnd,
            contestType:             ContestV2.ContestType.PREDICT,
            winnerDetermination:     ContestV2.WinnerDetermination.ORACLE,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.PROPORTIONAL,
            tierRequired:            MIRROR_MIN_TIER,   // hard floor
            quorumPercentage:        p.quorumPercentage > 0 ? p.quorumPercentage : 50,
            // Legacy oracle field unused for mirror contests — the resolver
            // (queried via factory.resolverForContest in ContestV2.resolveContest)
            // is the authoritative outcome source. Setting requiresOracle=true
            // here would force submitOracleData() to be called too, which we
            // don't use.
            requiresOracle:          false,
            metadataHash:            p.metadataHash,
            metadataUri:             p.metadataUri
        });

        ContestV2.PrizeConfig memory prize = ContestV2.PrizeConfig({
            model:                ContestV2.PrizeModel.STAKE_WEIGHTED,
            splitsBps:            new uint16[](0),
            eligibilityThreshold: 0,
            weightedByScore:      false
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0,
            topPercentile:        2500,
            confidenceMultiplier: 0, // confidence not meaningful for stake-weighted markets
            earlyVoterBonus:      0
        });

        ContestV2.SubmissionConfig memory submissions = ContestV2.SubmissionConfig({
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

        // ─── Mirror resolver fee (sustains the relayer wallet) ─────
        // Charged in the same token as the contest's deposit — typically
        // USDC. Skipped when fee == 0. If fee > 0 the treasury MUST be
        // configured, otherwise we'd silently drop funds.
        uint256 resolverFee = mirrorResolverFee;
        if (resolverFee > 0) {
            require(resolverTreasury != address(0), "Mirror: treasury unset");
            IERC20(p.depositToken).safeTransferFrom(msg.sender, resolverTreasury, resolverFee);
            emit MirrorResolverFeePaid(msg.sender, resolverTreasury, resolverFee);
        }

        // ─── Create + bind resolver ─────────────────────────────────
        (contestId, contestAddress) = _createCustomInternal(
            cfg, prize, scoring, submissions,
            address(0),   // legacy oracle slot unused
            options,
            0,            // creatorPrize forced to 0
            msg.sender
        );

        resolverForContest[contestAddress] = p.resolver;
        bytes32 contestKey = bytes32(uint256(uint160(contestAddress)));
        bytes memory resolverParams = abi.encode(
            p.conditionId, p.yesOption, p.noOption, p.polymarketEndDate
        );
        IResolver(p.resolver).register(contestKey, resolverParams);
        emit ResolverBound(contestAddress, p.resolver);
        emit MirrorContestCreated(contestId, contestAddress, msg.sender, p.conditionId);
    }

    struct CreateContestParams {
        // Required
        address depositToken;
        uint256 depositAmount;
        bytes32 metadataHash;
        string metadataUri;
        bytes32[] options;

        // Optional (0 = use template default)
        uint256 depositStart;
        uint256 depositEnd;
        uint256 lockEnd;
        uint256 revealEnd;
        uint256 minParticipants;
        uint256 maxParticipants;
        uint256 tierRequired;
        uint256 quorumPercentage;
        address oracle;

        // Scoring params
        uint256 correlationThreshold;
        uint256 topPercentile;
        uint256 confidenceMultiplier;
        uint256 earlyVoterBonus;

        // Sponsor prize (optional, 0 = no sponsor prize)
        uint256 creatorPrize;

        // Prize-config overrides. Empty splitsBps + zero threshold means
        // "use template defaults". Non-empty splitsBps overrides the
        // template's per-rank splits (must still sum to 10_000 and match
        // the model's TOP_N requirements — validated downstream by ContestV2).
        uint16[] splitsBps;
        uint256 eligibilityThreshold;
        bool weightedByScore;
        bool overrideWeightedByScore; // true = use the field above; false = use template default
    }

    // ============ Template Management ============

    /// @notice Owner-callable template registration. Splits are passed as a
    ///         separate `splitsBps` array (Solidity disallows dynamic arrays
    ///         in calldata-to-storage struct literals).
    function createTemplate(
        bytes32 id,
        string calldata name,
        ContestV2.ContestType contestType,
        ContestV2.PrizeModel prizeModel,
        ContestV2.WinnerDetermination winnerDetermination,
        ContestV2.VoterRewardDistribution voterRewardDistribution,
        uint256 defaultDepositPeriod,
        uint256 defaultLockPeriod,
        uint256 defaultRevealPeriod,
        uint256 minParticipants,
        uint256 maxParticipants,
        uint256 defaultEligibilityThreshold,
        bool defaultWeightedByScore,
        bool requiresOracle,
        uint16[] calldata splitsBps
    ) external onlyOwner {
        require(templates[id].id == bytes32(0), "ContestFactoryV2: template exists");

        ContestTemplate memory tpl = ContestTemplate({
            id: id,
            name: name,
            contestType: contestType,
            prizeModel: prizeModel,
            winnerDetermination: winnerDetermination,
            voterRewardDistribution: voterRewardDistribution,
            defaultDepositPeriod: defaultDepositPeriod,
            defaultLockPeriod: defaultLockPeriod,
            defaultRevealPeriod: defaultRevealPeriod,
            minParticipants: minParticipants,
            maxParticipants: maxParticipants,
            defaultEligibilityThreshold: defaultEligibilityThreshold,
            defaultWeightedByScore: defaultWeightedByScore,
            requiresOracle: requiresOracle,
            isActive: true
        });

        // Memory → storage copy (calldata array → memory → storage push loop).
        uint16[] memory splitsCopy = new uint16[](splitsBps.length);
        for (uint256 i = 0; i < splitsBps.length; i++) splitsCopy[i] = splitsBps[i];
        _registerTemplate(id, tpl, splitsCopy);

        emit TemplateCreated(id, name);
    }

    /// @notice Read template's splits separately (auto-generated getter for the
    ///         mapping doesn't return the full uint16[] in one call).
    function getTemplateSplits(bytes32 id) external view returns (uint16[] memory) {
        return templateSplitsBps[id];
    }

    function setTemplateActive(bytes32 id, bool active) external onlyOwner {
        require(templates[id].id != bytes32(0), "ContestFactoryV2: template not found");
        templates[id].isActive = active;
        emit TemplateUpdated(id);
    }

    // ============ Admin Functions ============

    function setProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_PROTOCOL_FEE_BPS, "Fee exceeds maximum");
        protocolFeePercentage = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    /**
     * @notice Set fee recipient address (owner only)
     * @dev SECURITY: ContestV2 stores protocolFeeRecipient per-contest at initialization time
     *      (see ContestV2.protocolFeeRecipient), so changing feeRecipient here only affects
     *      newly created contests, not in-progress ones. This prevents the mid-contest
     *      fee recipient change vulnerability present in ContestFactory V1.
     */
    // setFeeRecipient REMOVED 2026-04-28 — feeRecipient is now constructor-immutable.
    // ContestV2 clones already snapshot protocolFeeRecipient at initialize() so live
    // contests were always immune to redirects; this change extends the same guarantee
    // to FUTURE contests too. To rotate the recipient, deploy a new factory.

    function setFeeEnabled(bool enabled) external onlyOwner {
        feeEnabled = enabled;
        emit FeeEnabledUpdated(enabled);
    }

    function setContestCreationFee(uint256 newFee) external onlyOwner {
        contestCreationFee = newFee;
        emit ContestCreationFeeUpdated(newFee);
    }

    /// @notice Update the per-mirror-contest USDC fee that funds the
    ///         relayer wallet. Set to 0 to disable. When non-zero,
    ///         resolverTreasury MUST be non-zero — createMirrorContest
    ///         enforces this defensively too.
    function setMirrorResolverFee(uint256 newFee) external onlyOwner {
        mirrorResolverFee = newFee;
        emit MirrorResolverFeeUpdated(newFee);
    }

    /// @notice Update the destination address for mirror creation fees.
    ///         Typically the relayer's hot wallet (so it can directly
    ///         spend the funds for swaps to ETH for gas).
    function setResolverTreasury(address newTreasury) external onlyOwner {
        resolverTreasury = newTreasury;
        emit ResolverTreasuryUpdated(newTreasury);
    }

    event MirrorResolverFeeUpdated(uint256 newFee);
    event ResolverTreasuryUpdated(address indexed newTreasury);
    event MirrorResolverFeePaid(address indexed creator, address indexed treasury, uint256 amount);

    function setImplementation(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "ContestFactoryV2: invalid implementation");
        contestImplementation = newImplementation;
        emit ImplementationUpdated(newImplementation);
    }

    function setYieldVault(address _yieldVault) external onlyOwner {
        require(_yieldVault != address(0), "ContestFactoryV2: zero address");
        address oldVault = yieldVault;
        yieldVault = _yieldVault;
        emit YieldVaultUpdated(oldVault, _yieldVault);
    }

    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        require(_identityRegistry != address(0), "ContestFactoryV2: zero address");
        address oldRegistry = identityRegistry;
        identityRegistry = _identityRegistry;
        emit IdentityRegistryUpdated(oldRegistry, _identityRegistry);
    }

    // ─── Pause controls ─────────────────────────────────────────────────
    // The Guardian (cold key) can pause this factory immediately to halt new
    // contest creation AND stop new deposits/votes/reveals on every active
    // ContestV2 clone (each clone reads `IPausable(factory).paused()`).
    // Withdrawal, refund, claim, and resolve paths on existing contests are
    // intentionally NEVER gated by pause — principal must always be
    // redeemable. Owner is the 48h Timelock so unpausing is delayed; that's
    // the trade-off documented in docs/audits/PAUSE_ARCHITECTURE_NEXT_REDEPLOY.md.

    function pause() external whenNotPaused {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner();
        paused = true;
        emit ContestFactoryPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit ContestFactoryUnpaused(msg.sender, block.timestamp);
    }

    /// @notice Set the guardian (emergency-pause role). Owner-only.
    /// @dev Pass address(0) to revoke the guardian role.
    function setGuardian(address _guardian) external onlyOwner {
        emit GuardianUpdated(guardian, _guardian);
        guardian = _guardian;
    }

    // ============ View Functions ============

    function getContest(bytes32 contestId) external view returns (address) {
        return contests[contestId];
    }

    function getContestCount() external view returns (uint256) {
        return contestIds.length;
    }

    function getCreatorContests(address creator) external view returns (bytes32[] memory) {
        return creatorContests[creator];
    }

    function getTemplateIds() external view returns (bytes32[] memory) {
        return templateIds;
    }

    function getTemplate(bytes32 id) external view returns (ContestTemplate memory) {
        return templates[id];
    }

    // ============ Internal Functions ============

    /// @dev Internal helper that registers a template + its splitsBps in one call.
    ///      Avoids the verbose pattern of writing the storage struct then push'ing
    ///      to templateIds and templateSplitsBps separately for every template.
    function _registerTemplate(
        bytes32 id,
        ContestTemplate memory tpl,
        uint16[] memory splits
    ) internal {
        templates[id] = tpl;
        templateIds.push(id);
        if (splits.length > 0) {
            uint16[] storage stored = templateSplitsBps[id];
            for (uint256 i = 0; i < splits.length; i++) {
                stored.push(splits[i]);
            }
        }
    }

    function _initializeDefaultTemplates() internal {
        // ── Election: SINGLE_TOP — best voter wins all, ties split pro-rata. ──
        _registerTemplate(keccak256("election"), ContestTemplate({
            id: keccak256("election"),
            name: "Election",
            contestType: ContestV2.ContestType.VOTE,
            prizeModel: ContestV2.PrizeModel.SINGLE_TOP,
            winnerDetermination: ContestV2.WinnerDetermination.PLURALITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.EQUAL,
            defaultDepositPeriod: 14 days,
            defaultLockPeriod: 7 days,
            defaultRevealPeriod: 3 days,
            minParticipants: 100,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 1, // any non-zero score qualifies
            defaultWeightedByScore: false,
            requiresOracle: false,
            isActive: true
        }), new uint16[](0));

        // ── Ranking: TOP_N_RANKED 60/30/10 — top three rankers paid by accuracy. ──
        uint16[] memory rankingSplits = new uint16[](3);
        rankingSplits[0] = 6000;
        rankingSplits[1] = 3000;
        rankingSplits[2] = 1000;
        _registerTemplate(keccak256("ranking"), ContestTemplate({
            id: keccak256("ranking"),
            name: "Ranking/Chart",
            contestType: ContestV2.ContestType.RANK,
            prizeModel: ContestV2.PrizeModel.TOP_N_RANKED,
            winnerDetermination: ContestV2.WinnerDetermination.BORDA_COUNT,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.CORRELATION_BASED,
            defaultDepositPeriod: 7 days,
            defaultLockPeriod: 2 days,
            defaultRevealPeriod: 1 days,
            minParticipants: 30,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 1,
            defaultWeightedByScore: false,
            requiresOracle: false,
            isActive: true
        }), rankingSplits);

        // ── Rating: PROPORTIONAL — every accurate rater shares pool by score. ──
        _registerTemplate(keccak256("rating"), ContestTemplate({
            id: keccak256("rating"),
            name: "Rating Contest",
            contestType: ContestV2.ContestType.RATE,
            prizeModel: ContestV2.PrizeModel.PROPORTIONAL,
            winnerDetermination: ContestV2.WinnerDetermination.WEIGHTED_AVERAGE,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.CORRELATION_BASED,
            defaultDepositPeriod: 7 days,
            defaultLockPeriod: 2 days,
            defaultRevealPeriod: 1 days,
            minParticipants: 50,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 1,
            defaultWeightedByScore: false,
            requiresOracle: false,
            isActive: true
        }), new uint16[](0));

        // ── Prediction: PROPORTIONAL — accuracy-weighted payout for correct predictors. ──
        _registerTemplate(keccak256("prediction"), ContestTemplate({
            id: keccak256("prediction"),
            name: "Prediction Market",
            contestType: ContestV2.ContestType.PREDICT,
            prizeModel: ContestV2.PrizeModel.PROPORTIONAL,
            winnerDetermination: ContestV2.WinnerDetermination.ORACLE,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.ACCURACY_WEIGHTED,
            defaultDepositPeriod: 3 days,
            defaultLockPeriod: 1 days,
            defaultRevealPeriod: 2 days,
            minParticipants: 20,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 1,
            defaultWeightedByScore: false,
            requiresOracle: true,
            isActive: true
        }), new uint16[](0));

        // ── Governance: PROPORTIONAL — every quorum voter shares pool. ──
        _registerTemplate(keccak256("governance"), ContestTemplate({
            id: keccak256("governance"),
            name: "Governance Proposal",
            contestType: ContestV2.ContestType.VOTE,
            prizeModel: ContestV2.PrizeModel.PROPORTIONAL,
            winnerDetermination: ContestV2.WinnerDetermination.MAJORITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.EQUAL,
            defaultDepositPeriod: 3 days,
            defaultLockPeriod: 4 days,
            defaultRevealPeriod: 1 days,
            minParticipants: 10,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 1,
            defaultWeightedByScore: false,
            requiresOracle: false,
            isActive: true
        }), new uint16[](0));

        // ── Meme: TOP_N_RANDOM 70/20/10 — VRF picks 3 from accurate voters. ──
        // Showcases the new VRF-driven raffle behavior in a high-engagement format.
        uint16[] memory memeSplits = new uint16[](3);
        memeSplits[0] = 7000;
        memeSplits[1] = 2000;
        memeSplits[2] = 1000;
        _registerTemplate(keccak256("meme"), ContestTemplate({
            id: keccak256("meme"),
            name: "Meme Contest",
            contestType: ContestV2.ContestType.VOTE,
            prizeModel: ContestV2.PrizeModel.TOP_N_RANDOM,
            winnerDetermination: ContestV2.WinnerDetermination.PLURALITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.EQUAL,
            defaultDepositPeriod: 3 days,
            defaultLockPeriod: 1 days,
            defaultRevealPeriod: 1 days,
            minParticipants: 20,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 1,
            defaultWeightedByScore: true, // better-voting memers more likely to win
            requiresOracle: false,
            isActive: true
        }), memeSplits);

        // ── Raffle (NEW): SINGLE_RANDOM — VRF picks one winner from all eligibles. ──
        // Pure lottery-style payout for high-engagement low-skill contests.
        _registerTemplate(keccak256("raffle"), ContestTemplate({
            id: keccak256("raffle"),
            name: "Raffle",
            contestType: ContestV2.ContestType.VOTE,
            prizeModel: ContestV2.PrizeModel.SINGLE_RANDOM,
            winnerDetermination: ContestV2.WinnerDetermination.PLURALITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.EQUAL,
            defaultDepositPeriod: 2 days,
            defaultLockPeriod: 12 hours,
            defaultRevealPeriod: 12 hours,
            minParticipants: 10,
            maxParticipants: 10000,
            defaultEligibilityThreshold: 0, // raffle = anyone who revealed
            defaultWeightedByScore: false,  // pure uniform odds
            requiresOracle: false,
            isActive: true
        }), new uint16[](0));
    }
}
