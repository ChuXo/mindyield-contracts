// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../strategies/AaveStrategy.sol";
import "../interfaces/IRandomnessManager.sol";
import "./TwabController.sol";
import "./LotteryReceiptToken.sol";

/**
 * @title NoLossLotteryV3
 * @notice Enhanced no-loss lottery with streak bonuses, receipt tokens, and
 *         initializable pattern for factory deployment via Clones.
 *
 * Improvements over V2:
 *  1. Streak bonuses: consecutive-round depositors get an odds multiplier (up to 1.5x)
 *  2. Receipt tokens: ERC-20 minted/burned 1:1 on deposit/withdraw for DeFi composability
 *  3. Initializable: supports minimal proxy (Clones) deployment via NoLossLotteryFactory
 *  4. ProtocolFeeDeducted event: enables indexer to wire affiliate/referral rewards
 *  5. Pool type metadata: weekly vs monthly for multi-pool architecture
 *
 * Inherited from V2:
 *  - TWAB-based proportional odds (now genuinely used for winner selection)
 *  - Multi-tier prizes from single VRF word via keccak256 chaining
 *  - Auto-compound, protocol fee, yield buffer
 *  - Debt/asset separation, draw replay protection, canary tier auto-tuning
 *
 * Hardening in this revision:
 *  1. Decoupled settlement: `fulfillRandomness` (VRF callback) is O(1) — it only
 *     stores the random word. A permissionless `settleRound()` then harvests and
 *     picks winners with full block gas, so the callback can never run out of gas
 *     and a popular pool can never get stuck on draw day.
 *  2. Selection is weighted by each participant's TWAB over the round window
 *     (locked at endTime) × streak, NOT current balance — so a last-minute / during
 *     -draw whale deposit gets ~0 odds. Deposits are also blocked while a draw is
 *     pending.
 *  3. Delegation removed (was unused and only confused TWAB accounting).
 */
contract NoLossLotteryV3 is Initializable, TwabController, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ─── Constants ──────────────────────────────────────────────────────────────

    uint256 public constant BASIS_POINTS         = 10_000;
    uint256 public constant MIN_ROUND_DURATION   = 1 hours;
    uint256 public constant MAX_LOTTERY_FEE_BPS = 500; // 5% hard ceiling
    /// @dev Kept for ABI back-compat; now equals MAX_LOTTERY_FEE_BPS.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_LOTTERY_FEE_BPS;
    uint8   public constant MAX_TIERS            = 5;
    uint8   public constant MAX_STREAK_LEVELS    = 5;
    uint256 public constant MIN_DEPOSIT          = 1e6;    // 1 USDC (6 decimals) — prevents participant set spam

    /// @notice Default deposit cap. The lottery scales to far more depositors than
    ///         this — large pools settle via the pro-rata claim path (see
    ///         `pushSelectionLimit`), so this only bounds storage growth.
    uint256 public constant DEFAULT_MAX_PARTICIPANTS = 10_000;

    /// @notice Hard ceiling on the owner-settable deposit cap. Effectively
    ///         "unlimited" for the product.
    uint256 public constant MAX_PARTICIPANTS_CEILING = 1_000_000;

    /// @notice Maximum depositors allowed. Owner-configurable.
    uint256 public maxParticipants;

    // ─── Paginated settlement (single winner at unlimited scale) ────────────────
    // settleRound() draws EXACTLY ONE TWAB-weighted winner per tier, every round,
    // for ANY number of participants. Winner selection is a one-pass weighted
    // reservoir (A-Chao) over the participant set; for pools larger than
    // `settleBatch` it runs across multiple permissionless settleRound() calls
    // (the keeper loops them), so it never hits the block gas limit and never gets
    // stuck. Pro-rata "everyone gets their own yield" applies ONLY to cancellation.

    struct Settlement {
        bool    active;        // a settle pass is underway
        uint64  cursor;        // next participant index to process
        uint256 roundId;       // round being settled
        uint256 netPrize;      // prize pool (post-fee), fixed at the first batch
        uint256 runningWeight; // Σ processed TWAB weights (reservoir denominator)
    }
    Settlement public settlement;

    /// @notice Current reservoir leader per tier during an in-progress settle.
    address[MAX_TIERS] private _settleWinners;

    /// @notice Participants processed per settleRound() call. Owner-tunable within
    ///         [1, MAX_SETTLE_BATCH] for gas headroom; large pools just take more
    ///         calls. Each participant costs ~one TWAB lookup (~30k gas).
    uint256 public settleBatch;
    uint256 public constant MAX_SETTLE_BATCH = 1_000;

    // ─── Immutables (set once in initialize, never changed) ─────────────────────
    // NOTE: Using regular state variables because Clones can't use immutable.

    IERC20             public depositToken;
    AaveStrategy       public aaveStrategy;
    IRandomnessManager public randomnessManager;

    // ─── Configuration ──────────────────────────────────────────────────────────

    uint256 public roundDuration;
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;
    uint8   public numberOfTiers;
    uint256[MAX_TIERS] public tierBps;

    /// @notice Pool type: 0 = weekly, 1 = monthly
    uint8 public poolType;

    /// @notice Receipt token minted/burned 1:1 on deposit/withdraw. address(0) = disabled.
    LotteryReceiptToken public receiptToken;

    // ─── Streak Bonuses ─────────────────────────────────────────────────────────

    /// @notice Last round in which a user was an active depositor at settlement time.
    mapping(address => uint256) public lastActiveRound;

    /// @notice Number of consecutive rounds the user has been deposited through.
    mapping(address => uint16) public streakCount;

    /// @notice Streak threshold levels (ascending). Default: [3, 7, 14, 30, max].
    uint16[MAX_STREAK_LEVELS] public streakThresholds;

    /// @notice Multiplier in BPS for each threshold. Default: [11000, 12000, 13000, 15000, 15000].
    ///         10000 = 1.0x (no bonus).
    uint16[MAX_STREAK_LEVELS] public streakMultipliers;

    // ─── Round State ────────────────────────────────────────────────────────────

    struct Round {
        uint256 id;
        uint64  startTime;
        uint64  endTime;
        uint256 totalDepositedSnapshot;
        bool    isDrawPending;
        bool    isSettled;
        uint256 totalPrize;
        uint256 protocolFee;
    }

    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;

    /// @notice VRF word delivered for a round (set in `fulfillRandomness`, consumed
    ///         by `settleRound`). Settlement is decoupled from the VRF callback so
    ///         the callback can never run out of gas — see `settleRound`.
    mapping(uint256 => uint256) public roundRandomWord;

    /// @notice True once the VRF word for a round has been delivered and the round
    ///         is awaiting `settleRound`. Round lifecycle:
    ///           OPEN → (endTime) → performUpkeep → isDrawPending
    ///           → fulfillRandomness → randomReady → settleRound → isSettled.
    mapping(uint256 => bool) public roundRandomReady;

    // ─── Cancelled-round yield refund ───────────────────────────────────────────
    // When a draw is cancelled (VRF gave up), the round is VOIDED rather than
    // settled: no one wins, and instead every depositor can reclaim THEIR OWN
    // generated yield for that round, pro-rata by their TWAB over the round
    // window. This mirrors ProbabilityVaultV2's cancel-yield refund. Principal
    // is unaffected (it stays in the strategy, withdrawable as always).

    /// @notice True if a round was voided (cancelled) instead of settled.
    mapping(uint256 => bool) public roundCancelled;
    /// @notice USDC reserved for pro-rata yield refund on a voided round.
    mapping(uint256 => uint256) public roundYieldRefund;
    /// @notice TWAB window end (the cancel timestamp) used to size each refund.
    mapping(uint256 => uint64) public roundYieldWindowEnd;
    /// @notice Replay guard: per-round, per-user refund claim flag.
    mapping(uint256 => mapping(address => bool)) public yieldRefundClaimed;

    // ─── Prize Tiers ────────────────────────────────────────────────────────────

    struct TierResult {
        address winner;
        uint256 amount;
    }

    mapping(uint256 => mapping(uint8 => TierResult)) public tierResults;

    // ─── User State ─────────────────────────────────────────────────────────────

    uint256 public totalDeposited;
    mapping(uint256 => mapping(address => uint256)) public pendingPrizes;
    mapping(address => bool) public autoCompound;
    mapping(address => uint96) public userDeposited;
    uint256 public accumulatedProtocolFees;

    // ─── Yield Buffer & Debt ────────────────────────────────────────────────────

    uint256 public yieldBuffer;
    uint256 public totalDebt;

    // ─── Canary Tier Auto-Tuning ────────────────────────────────────────────────

    uint8 public canaryUnclaimed;
    uint8 public canaryClaimed;
    uint8 public constant CANARY_DOWN_THRESHOLD = 3;
    uint8 public constant CANARY_UP_THRESHOLD   = 3;
    bool  public canaryAutoTuneEnabled;

    // ─── Draw Replay Protection ─────────────────────────────────────────────────

    uint256 public drawNonce;

    // ─── Keeper-Hardening Config (V3+) ──────────────────────────────────────────

    /// @notice Guardian address that can trigger emergency pause (but not unpause).
    address public guardian;

    /// @notice Minimum distinct depositors required before a draw is allowed.
    ///         Default 1 (original V3 behaviour). Owner-settable so a very
    ///         low-activity pool can be configured to only draw once a
    ///         meaningful participant count is reached, preventing degenerate
    ///         "guaranteed win" draws on a freshly seeded pool.
    uint32 public minParticipantsForDraw;

    // ─── Participant Set ────────────────────────────────────────────────────────

    EnumerableSet.AddressSet private _participants;

    // ─── Events ─────────────────────────────────────────────────────────────────

    event Deposited(address indexed participant, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed participant, uint256 amount, uint256 remainingBalance);
    event RoundStarted(uint256 indexed roundId, uint64 startTime, uint64 endTime);
    event DrawRequested(uint256 indexed roundId, bytes32 requestKey);
    event TierWinner(uint256 indexed roundId, uint8 indexed tier, address indexed winner, uint256 amount);
    event RoundSettled(uint256 indexed roundId, uint256 totalPrize, uint256 protocolFee);
    event ProtocolFeeDeducted(uint256 indexed roundId, uint256 feeAmount);
    event PrizeClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);
    event PrizeAutoCompounded(uint256 indexed roundId, address indexed winner, uint256 amount);
    event AutoCompoundToggled(address indexed user, bool enabled);
    /// @notice Emitted by the (now O(1)) VRF callback once a round's random word is
    ///         delivered. The round still needs a permissionless `settleRound` call
    ///         to harvest yield and pick winners.
    event RandomnessReceived(uint256 indexed roundId, uint256 randomWord);
    /// @notice Emitted after each settleRound() batch that does NOT finish the
    ///         round — lets the keeper/UI know more calls are needed.
    event SettleProgress(uint256 indexed roundId, uint256 processed, uint256 total);
    /// @notice A round's yield was reserved for pro-rata, per-depositor claim
    ///         (claim via claimRoundYield). `viaCancel` = true when the round was
    ///         voided (draw cancelled); false when a too-large round settled in
    ///         pro-rata mode (participantCount > pushSelectionLimit).
    event RoundYieldReserved(uint256 indexed roundId, uint256 reservedForUsers, uint64 windowEnd, bool viaCancel);
    /// @notice A depositor claimed their pro-rata yield share from a round.
    event RoundYieldClaimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event ProtocolFeeUpdated(uint256 newFeeBps);
    event ProtocolFeesWithdrawn(address indexed recipient, uint256 amount);
    event TierConfigUpdated(uint8 numberOfTiers, uint256[5] bps);
    event RoundDurationUpdated(uint256 newDuration);
    event YieldBufferFunded(address indexed funder, uint256 amount);
    event CanaryAutoTuneToggled(bool enabled);
    event TierAutoAdjusted(uint8 oldTiers, uint8 newTiers, string reason);
    event StreakConfigUpdated(uint16[5] thresholds, uint16[5] multipliers);
    event StreakUpdated(address indexed user, uint16 newStreak);
    /// @notice Emitted when an empty round's window is slid forward because a
    ///         late first-depositor arrived after the original endTime. Lets
    ///         indexers refresh `depositStart` / `depositEnd` without
    ///         inventing a synthetic round-settled pair.
    event RoundRolled(uint256 indexed roundId, uint64 newStartTime, uint64 newEndTime);
    event DrawCancelled(uint256 indexed roundId);
    event MinParticipantsForDrawUpdated(uint32 oldValue, uint32 newValue);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    /// @notice Emitted when cancelDraw could not reset the RandomnessManager
    ///         request because MAX_RETRIES was exceeded. The draw flag is
    ///         cleared so the round can retry, but the RandomnessManager key
    ///         is still live — owner must call RandomnessManager.resetFailedRequest
    ///         directly (via the owner path) before the next draw can succeed.
    event VRFRetryExhausted(uint256 indexed roundId, bytes32 requestKey);

    // ─── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientBalance();
    error DrawNotReady();
    error DrawAlreadyPending();
    error RoundAlreadySettled();
    error RoundNotSettled();
    error NoPrizeToClaim();
    error NotRandomnessManager();
    error NoActiveParticipants();
    error FeeTooHigh();
    error InvalidTierConfig();
    error InvalidRecipient();
    error DrawReplay();
    error Undercollateralized();
    error InvalidStreakConfig();
    error BelowMinDeposit();
    error ParticipantCapReached();
    error DrawStillFresh();
    error BelowMinParticipants();
    /// @notice Reverted by deposit() while a draw/settlement is in flight. Deposits
    ///         made after `endTime` would have ~0 TWAB weight for the round anyway;
    ///         blocking them keeps the participant set (and therefore settleRound
    ///         gas) frozen between performUpkeep and settleRound.
    error DepositDuringDraw();
    /// @notice Reverted by settleRound() when the round has no VRF word yet.
    error RandomNotReady();
    /// @notice Reverted by withdraw() while a VRF draw is in flight. Pairs with
    ///         the "always one winner" guarantee — if the participant set could
    ///         empty between performUpkeep and fulfillRandomness, the draw
    ///         would settle with no winner. Cleared automatically when the
    ///         VRF callback (or `cancelDraw` / `cancelDrawPublic`) flips
    ///         `isDrawPending` back to false.
    error WithdrawDuringDraw();

    // ─── Constructor (disabled for Clones) ──────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer ────────────────────────────────────────────────────────────

    /**
     * @notice Initialize the lottery. Called once by the factory after cloning.
     * @param _depositToken       ERC-20 token for deposits (e.g., USDC).
     * @param _aaveStrategy       Aave V3 yield strategy (1:1 coupled).
     * @param _randomnessManager  Chainlink VRF integration.
     * @param _roundDuration      Seconds per round (min 1 hour).
     * @param _feeRecipient       Protocol fee destination.
     * @param _protocolFeeBps     Fee in basis points (max 1000 = 10%).
     * @param _numberOfTiers      Active prize tiers (1-5).
     * @param _tierBps            BPS per tier (must sum to 10000 across active tiers).
     * @param _poolType           Pool type: 0 = weekly, 1 = monthly.
     * @param _receiptToken       Receipt token address (address(0) to disable).
     */
    function initialize(
        address _depositToken,
        address _aaveStrategy,
        address _randomnessManager,
        uint256 _roundDuration,
        address _feeRecipient,
        uint256 _protocolFeeBps,
        uint8   _numberOfTiers,
        uint256[5] calldata _tierBps,
        uint8   _poolType,
        address _receiptToken
    ) external initializer {
        require(_depositToken != address(0),          "V3: invalid token");
        require(_aaveStrategy != address(0),          "V3: invalid strategy");
        require(_randomnessManager != address(0),     "V3: invalid RM");
        require(_roundDuration >= MIN_ROUND_DURATION, "V3: duration too short");
        require(_feeRecipient != address(0),          "V3: invalid fee recipient");
        require(_protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, "V3: fee too high");

        // Validate tier config
        require(_numberOfTiers > 0 && _numberOfTiers <= MAX_TIERS, "V3: invalid tiers");
        uint256 total = 0;
        for (uint8 i = 0; i < _numberOfTiers; i++) {
            total += _tierBps[i];
        }
        require(total == BASIS_POINTS, "V3: tier bps != 10000");
        for (uint8 i = _numberOfTiers; i < MAX_TIERS; i++) {
            require(_tierBps[i] == 0, "V3: inactive tier != 0");
        }

        // Initialize Ownable (caller = factory becomes initial owner)
        _transferOwnership(msg.sender);

        // Set immutable-like state
        depositToken      = IERC20(_depositToken);
        aaveStrategy      = AaveStrategy(_aaveStrategy);
        randomnessManager = IRandomnessManager(_randomnessManager);

        // Configuration
        roundDuration        = _roundDuration;
        protocolFeeBps       = _protocolFeeBps;
        protocolFeeRecipient = _feeRecipient;
        numberOfTiers        = _numberOfTiers;
        poolType             = _poolType;

        for (uint8 i = 0; i < MAX_TIERS; i++) {
            tierBps[i] = _tierBps[i];
        }

        // Receipt token (address(0) = disabled)
        if (_receiptToken != address(0)) {
            receiptToken = LotteryReceiptToken(_receiptToken);
        }

        // Default streak config: 3/7/14/30 rounds → 1.1x/1.2x/1.3x/1.5x
        maxParticipants = DEFAULT_MAX_PARTICIPANTS;
        settleBatch     = 300; // participants processed per settleRound() call

        // Default: draw allowed as soon as one depositor is present. Owner
        // can raise this later via setMinParticipantsForDraw.
        minParticipantsForDraw = 1;

        streakThresholds[0]  = 3;
        streakThresholds[1]  = 7;
        streakThresholds[2]  = 14;
        streakThresholds[3]  = 30;
        streakThresholds[4]  = type(uint16).max; // sentinel (unreachable)

        streakMultipliers[0] = 11_000; // 1.1x
        streakMultipliers[1] = 12_000; // 1.2x
        streakMultipliers[2] = 13_000; // 1.3x
        streakMultipliers[3] = 15_000; // 1.5x
        streakMultipliers[4] = 15_000; // cap (same as 30+)

        _startNewRound();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit tokens to participate. Funds go immediately to Aave.
     * @param amount Amount of deposit tokens.
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_DEPOSIT) revert BelowMinDeposit();
        require(amount <= type(uint96).max, "V3: amount overflow");
        // Freeze the participant set once a draw is requested: deposits resume
        // automatically into the fresh round opened by settleRound. (A deposit
        // after endTime has ~0 TWAB weight, so this costs honest users nothing.)
        if (rounds[currentRoundId].isDrawPending) revert DepositDuringDraw();

        // ── First-depositor window extension ───────────────────────────────
        // If the current round sat empty past its endTime (no deposits at
        // all across the whole window), sliding the window forward here
        // gives this depositor a full `roundDuration` of TWAB accumulation
        // before the draw fires. Without this, a pool that's been dormant
        // for a while would end up drawing one block after the first
        // deposit — guaranteed win to that depositor, zero real lottery.
        //
        // Guards:
        //   - Only runs when totalDeposited == 0 — once any balance is
        //     active we keep the original endTime to preserve round cadence.
        //   - Only runs when `block.timestamp >= r.endTime` — a timely
        //     first deposit doesn't reset the window.
        //   - Never moves endTime backward.
        //   - Does not increment roundId, so round accounting is undisturbed.
        Round storage roundRef = rounds[currentRoundId];
        if (totalDeposited == 0 && block.timestamp >= roundRef.endTime) {
            uint64 newStart = uint64(block.timestamp);
            uint64 newEnd   = newStart + uint64(roundDuration);
            roundRef.startTime = newStart;
            roundRef.endTime   = newEnd;
            emit RoundRolled(currentRoundId, newStart, newEnd);
        }

        depositToken.safeTransferFrom(msg.sender, address(this), amount);

        depositToken.safeApprove(address(aaveStrategy), 0);
        depositToken.safeApprove(address(aaveStrategy), amount);
        aaveStrategy.deposit(amount);

        uint96 amt96 = uint96(amount);

        _increaseBalance(msg.sender, amt96);

        totalDeposited += amount;
        totalDebt += amount;
        userDeposited[msg.sender] += amt96;
        _participants.add(msg.sender);
        if (_participants.length() > maxParticipants) revert ParticipantCapReached();

        // Mint receipt token
        if (address(receiptToken) != address(0)) {
            receiptToken.mint(msg.sender, amount);
        }

        emit Deposited(msg.sender, amount, _accounts[msg.sender].balance);
    }

    /**
     * @notice Withdraw principal at any time. Yield stays in prize pool.
     * @param amount Amount to withdraw.
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Block withdrawals while a draw is in flight so the participant set
        // observed by `performUpkeep` is the same one used by
        // `fulfillRandomness` — otherwise the lone depositor could exit
        // mid-VRF and leave the round with no winner. Worst-case lock is
        // bounded by `cancelDraw` (owner, +3h) and `cancelDrawPublic`
        // (anyone, +7d), so the no-loss guarantee is preserved.
        if (rounds[currentRoundId].isDrawPending) revert WithdrawDuringDraw();

        if (_accounts[msg.sender].balance < uint96(amount)) revert InsufficientBalance();

        // Pro-rata withdrawal if under-collateralized
        uint256 strategyValue = aaveStrategy.getTotalValue();
        uint256 actualAmount = amount;
        if (strategyValue < totalDebt) {
            actualAmount = (amount * strategyValue) / totalDebt;
        }

        uint96 amt96 = uint96(amount);
        _decreaseBalance(msg.sender, amt96);

        totalDeposited -= amount;
        totalDebt -= amount;
        userDeposited[msg.sender] -= amt96;

        if (userDeposited[msg.sender] == 0) {
            _participants.remove(msg.sender);
        }

        uint256 sharesToBurn = _sharesForAmount(actualAmount);
        uint256 actualOut = aaveStrategy.withdraw(sharesToBurn);
        depositToken.safeTransfer(msg.sender, actualOut);

        // Burn receipt token (best-effort: if user transferred tokens away, withdrawal still succeeds
        // since principal tracking uses userDeposited[], not receipt token balance)
        if (address(receiptToken) != address(0)) {
            uint256 receiptBal = receiptToken.balanceOf(msg.sender);
            if (receiptBal >= amount) {
                receiptToken.burn(msg.sender, amount);
            } else if (receiptBal > 0) {
                receiptToken.burn(msg.sender, receiptBal);
            }
        }

        emit Withdrawn(msg.sender, actualOut, _accounts[msg.sender].balance);
    }

    /**
     * @notice Claim prize for a settled round.
     */
    function claimPrize(uint256 roundId) external nonReentrant {
        if (!rounds[roundId].isSettled) revert RoundNotSettled();

        uint256 prize = pendingPrizes[roundId][msg.sender];
        if (prize == 0) revert NoPrizeToClaim();

        pendingPrizes[roundId][msg.sender] = 0;

        if (autoCompound[msg.sender]) {
            require(prize <= type(uint96).max, "V3: prize overflow");
            depositToken.safeApprove(address(aaveStrategy), 0);
            depositToken.safeApprove(address(aaveStrategy), prize);
            aaveStrategy.deposit(prize);
            uint96 amt96 = uint96(prize);
            _increaseBalance(msg.sender, amt96);
            totalDeposited += prize;
            totalDebt += prize;
            userDeposited[msg.sender] += amt96;
            _participants.add(msg.sender);

            // Mint receipt token for auto-compounded prize
            if (address(receiptToken) != address(0)) {
                receiptToken.mint(msg.sender, prize);
            }

            emit PrizeAutoCompounded(roundId, msg.sender, prize);
        } else {
            depositToken.safeTransfer(msg.sender, prize);
            emit PrizeClaimed(roundId, msg.sender, prize);
        }
    }

    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundToggled(msg.sender, enabled);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CHAINLINK AUTOMATION
    // ═══════════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata)
        external view returns (bool upkeepNeeded, bytes memory performData)
    {
        Round storage r = rounds[currentRoundId];
        upkeepNeeded = (
            block.timestamp >= r.endTime &&
            !r.isDrawPending &&
            !r.isSettled &&
            totalDeposited > 0 &&
            _participants.length() >= minParticipantsForDraw
        );
        performData = "";
    }

    function performUpkeep(bytes calldata) external {
        Round storage r = rounds[currentRoundId];
        if (block.timestamp < r.endTime)              revert DrawNotReady();
        if (r.isDrawPending)                          revert DrawAlreadyPending();
        if (r.isSettled)                              revert RoundAlreadySettled();
        if (totalDeposited == 0)                      revert NoActiveParticipants();
        if (_participants.length() < minParticipantsForDraw) revert BelowMinParticipants();

        r.isDrawPending          = true;
        r.totalDepositedSnapshot = totalDeposited;

        bytes32 requestKey = bytes32(uint256(uint160(address(this))) ^ currentRoundId);
        randomnessManager.requestRandomness(requestKey);

        emit DrawRequested(currentRoundId, requestKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VRF CALLBACK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks whether streaks have been updated for the most recently settled round.
    uint256 public lastStreakUpdateRound;

    /**
     * @notice VRF callback — DELIBERATELY O(1).
     *
     *         Winner selection and yield harvest are NOT done here. They run in
     *         the permissionless `settleRound()`, which executes in a normal
     *         transaction with full block gas instead of the VRF subscription's
     *         tight `callbackGasLimit`. This guarantees the callback can never
     *         run out of gas, so a popular pool can never get stuck on draw day
     *         (the bug that the per-callback distribution loop created).
     *
     *         All we do here is record the random word and flag the round ready.
     */
    function fulfillRandomness(uint256 randomWord) external nonReentrant {
        if (msg.sender != address(randomnessManager)) revert NotRandomnessManager();

        uint256 roundId = currentRoundId;
        Round storage r = rounds[roundId];
        require(!r.isSettled, "V3: already settled");
        require(r.isDrawPending, "V3: no draw pending");

        // Idempotent: a late retry-race double callback is a benign no-op.
        if (roundRandomReady[roundId]) return;

        drawNonce++;
        roundRandomWord[roundId]  = randomWord;
        roundRandomReady[roundId] = true;

        emit RandomnessReceived(roundId, randomWord);
    }

    /**
     * @notice Draw the round's single TWAB-weighted winner per tier and pay out.
     *
     *         PERMISSIONLESS + RESUMABLE — callable by the keeper, the frontend
     *         "Settle Draw" button, or anyone. Eligible once `fulfillRandomness`
     *         stored the round's word (`roundRandomReady`).
     *
     *         Scales to ANY number of participants: winner selection is a one-pass
     *         weighted reservoir (A-Chao) over the participant set, processed in
     *         batches of `settleBatch`. Pools larger than one batch finish over
     *         several calls (the keeper loops them); each call is gas-bounded, so
     *         settlement can never exceed the block gas limit or get stuck. There
     *         is always EXACTLY ONE winner per tier, weighted by each
     *         participant's TWAB over the round window × streak.
     *
     *         The first call harvests the yield (fixing the prize pool); the final
     *         call (cursor reaches the end) assigns prizes + opens the next round.
     *         Deposits/withdrawals stay frozen for the whole settle span (bounded
     *         by `cancelDrawPublic`, so principal is never locked > 7 days).
     */
    function settleRound() external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage r = rounds[roundId];
        if (r.isSettled)                revert RoundAlreadySettled();
        if (!r.isDrawPending)           revert DrawNotReady();
        if (!roundRandomReady[roundId]) revert RandomNotReady();

        Settlement storage s = settlement;

        // ── First batch: harvest yield, fix the prize pool, init the reservoir ──
        if (!s.active || s.roundId != roundId) {
            uint256 grossPrize = _harvestPrize();
            uint256 fee = (grossPrize * protocolFeeBps) / BASIS_POINTS;
            accumulatedProtocolFees += fee;
            r.protocolFee = fee;
            if (fee > 0) emit ProtocolFeeDeducted(roundId, fee);

            s.active        = true;
            s.roundId       = roundId;
            s.cursor        = 0;
            s.runningWeight = 0;
            s.netPrize      = grossPrize - fee;
            for (uint8 t = 0; t < MAX_TIERS; t++) _settleWinners[t] = address(0);
        }

        // ── Process a batch via A-Chao weighted reservoir ───────────────────────
        // Set stability across batches: deposit + withdraw are blocked while
        // isDrawPending, so no EnumerableSet `remove` (swap-and-pop) can reorder
        // indices mid-pass. The only mutation still possible is a claimPrize
        // auto-compound appending a participant — that's inert here: a newly
        // appended address had no balance in the set during [start,end], so its
        // TWAB is 0 → weight 0 → no effect, and append-only never reorders, so
        // every participant is still processed exactly once.
        uint256 randomWord = roundRandomWord[roundId];
        uint64  start = r.startTime;
        uint64  end   = r.endTime;
        uint256 len   = _participants.length();
        uint256 i     = s.cursor;
        uint256 stop  = i + settleBatch;
        if (stop > len) stop = len;
        uint256 running = s.runningWeight;
        uint8   tiers   = numberOfTiers;

        for (; i < stop;) {
            address p = _participants.at(i);
            // Weight = time-weighted balance over the round × streak multiplier.
            uint256 w = (_getTwab(p, start, end) * uint256(_getStreakMultiplier(streakCount[p]))) / BASIS_POINTS;
            if (w > 0) {
                running += w;
                // Independent reservoir per tier (same weights, distinct draws):
                // replace tier t's leader with probability w/running.
                for (uint8 t = 0; t < tiers;) {
                    uint256 draw = uint256(keccak256(abi.encodePacked(randomWord, t, p)));
                    if (draw % running < w) _settleWinners[t] = p;
                    unchecked { t++; }
                }
            }
            unchecked { i++; }
        }
        s.cursor        = uint64(i);
        s.runningWeight = running;

        // ── More participants remain → another call needed ──────────────────────
        if (i < len) {
            emit SettleProgress(roundId, i, len);
            return;
        }

        // ── Final batch: assign prizes, finalize, open the next round ───────────
        bool smallestTierClaimed = _finalizeSettlement(roundId, randomWord, len);
        if (canaryAutoTuneEnabled && numberOfTiers > 1) {
            _updateCanaryState(smallestTierClaimed);
        }

        r.totalPrize    = s.netPrize;
        r.isSettled     = true;
        r.isDrawPending = false;
        s.active        = false;

        emit RoundSettled(roundId, s.netPrize, r.protocolFee);
        _startNewRound();
    }

    /**
     * @dev Assign each tier's prize to its reservoir-drawn winner. If no
     *      participant had any TWAB weight (degenerate — unreachable in practice
     *      since depositing before endTime guarantees positive TWAB), fall back to
     *      a uniform pick so the prize still goes to a participant.
     */
    function _finalizeSettlement(uint256 roundId, uint256 randomWord, uint256 len)
        internal
        returns (bool smallestTierClaimed)
    {
        Settlement storage s = settlement;
        uint256 netPrize = s.netPrize;
        if (netPrize == 0 || len == 0) return false;

        bool noWeight = s.runningWeight == 0;
        uint8 tiers   = numberOfTiers;

        for (uint8 t = 0; t < tiers;) {
            uint256 tierPrize = (netPrize * tierBps[t]) / BASIS_POINTS;
            if (tierPrize > 0) {
                address winner = _settleWinners[t];
                if (winner == address(0) && noWeight) {
                    winner = _participants.at(uint256(keccak256(abi.encodePacked(randomWord, t))) % len);
                }
                if (winner != address(0)) {
                    tierResults[roundId][t] = TierResult({ winner: winner, amount: tierPrize });
                    pendingPrizes[roundId][winner] += tierPrize;
                    if (t == tiers - 1) smallestTierClaimed = true;
                    emit TierWinner(roundId, t, winner, tierPrize);
                }
            }
            unchecked { t++; }
        }
    }

    /**
     * @notice Update streak counts for all participants of the most recently settled round.
     *         Separated from fulfillRandomness() to prevent gas exhaustion from blocking
     *         round settlement. Can be called by anyone (Automation, owner, or user).
     *         Safe to call multiple times — only processes once per round.
     */
    function updateStreaks() external {
        uint256 settledRound = currentRoundId - 1;
        require(settledRound > 0, "V3: no settled round");
        require(rounds[settledRound].isSettled, "V3: round not settled");
        require(lastStreakUpdateRound < settledRound, "V3: streaks already updated");

        lastStreakUpdateRound = settledRound;
        _updateStreaks();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getWinProbability(address participant) external view returns (uint256) {
        Round storage r = rounds[currentRoundId];
        uint64 start = r.startTime;
        uint64 end = uint64(block.timestamp);
        if (end <= start) return 0;

        uint256 userTwab = _getTwab(participant, start, end);
        uint256 totalTwab = _getTwab(address(0), start, end);
        if (totalTwab == 0) return 0;

        return (userTwab * BASIS_POINTS) / totalTwab;
    }

    function getCurrentPrizePool() external view returns (uint256) {
        uint256 currentValue = aaveStrategy.getTotalValue();
        uint256 totalOwed = totalDebt + yieldBuffer + accumulatedProtocolFees;
        if (currentValue <= totalOwed) return 0;
        return currentValue - totalOwed;
    }

    function getCurrentRound() external view returns (Round memory) {
        return rounds[currentRoundId];
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function participantCount() external view returns (uint256) {
        return _participants.length();
    }

    function getParticipant(uint256 index) external view returns (address) {
        return _participants.at(index);
    }

    function isParticipant(address user) external view returns (bool) {
        return _participants.contains(user);
    }

    function getTierResult(uint256 roundId, uint8 tier) external view returns (TierResult memory) {
        return tierResults[roundId][tier];
    }

    /**
     * @notice Get a user's streak info: current count and effective multiplier.
     */
    function getStreakInfo(address user) external view returns (uint16 streak, uint16 multiplier) {
        streak = streakCount[user];
        multiplier = _getStreakMultiplier(streak);
    }

    /**
     * @notice Get the effective weight for a user (base deposit * streak multiplier).
     *         Used for frontend display of boosted odds.
     */
    function getEffectiveWeight(address user) external view returns (uint256) {
        return _getEffectiveWeight(user);
    }

    function totalAssets() external view returns (uint256) {
        return aaveStrategy.getTotalValue();
    }

    function isUndercollateralized() external view returns (bool) {
        return aaveStrategy.getTotalValue() < totalDebt;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setRoundDuration(uint256 newDuration) external onlyOwner {
        require(newDuration >= MIN_ROUND_DURATION, "V3: too short");
        roundDuration = newDuration;
        emit RoundDurationUpdated(newDuration);
    }

    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_LOTTERY_FEE_BPS) revert FeeTooHigh();
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(newFeeBps);
    }

    // setProtocolFeeRecipient REMOVED 2026-04-28 — protocolFeeRecipient is now
    // write-once via initialize() and cannot be rotated by a compromised owner.
    // To rotate the recipient, deploy a new lottery clone.

    function setTierConfig(uint8 _numberOfTiers, uint256[5] calldata _tierBps) external onlyOwner {
        // Disallow changes while a VRF draw is in flight — that would alter prize
        // distribution for winners who have already contributed to the current round.
        if (rounds[currentRoundId].isDrawPending) revert InvalidTierConfig();
        if (_numberOfTiers == 0 || _numberOfTiers > MAX_TIERS) revert InvalidTierConfig();

        uint256 total = 0;
        for (uint8 i = 0; i < _numberOfTiers; i++) {
            total += _tierBps[i];
        }
        if (total != BASIS_POINTS) revert InvalidTierConfig();

        for (uint8 i = _numberOfTiers; i < MAX_TIERS; i++) {
            if (_tierBps[i] != 0) revert InvalidTierConfig();
        }

        numberOfTiers = _numberOfTiers;
        for (uint8 i = 0; i < MAX_TIERS; i++) {
            tierBps[i] = _tierBps[i];
        }

        emit TierConfigUpdated(_numberOfTiers, _tierBps);
    }

    /**
     * @notice Update streak bonus configuration.
     * @param _thresholds  Ascending round counts (e.g., [3, 7, 14, 30, 65535]).
     * @param _multipliers BPS multiplier per threshold (e.g., [11000, 12000, 13000, 15000, 15000]).
     */
    function setStreakConfig(
        uint16[5] calldata _thresholds,
        uint16[5] calldata _multipliers
    ) external onlyOwner {
        // Validate ascending thresholds
        for (uint8 i = 1; i < MAX_STREAK_LEVELS; i++) {
            if (_thresholds[i] <= _thresholds[i - 1]) revert InvalidStreakConfig();
        }
        // Validate multipliers >= BASIS_POINTS (no negative bonus)
        for (uint8 i = 0; i < MAX_STREAK_LEVELS; i++) {
            if (_multipliers[i] < uint16(BASIS_POINTS)) revert InvalidStreakConfig();
        }

        for (uint8 i = 0; i < MAX_STREAK_LEVELS; i++) {
            streakThresholds[i]  = _thresholds[i];
            streakMultipliers[i] = _multipliers[i];
        }

        emit StreakConfigUpdated(_thresholds, _multipliers);
    }

    function withdrawProtocolFees() external onlyOwner {
        uint256 amount = accumulatedProtocolFees;
        require(amount > 0, "V3: no fees");
        accumulatedProtocolFees = 0;
        depositToken.safeTransfer(protocolFeeRecipient, amount);
        emit ProtocolFeesWithdrawn(protocolFeeRecipient, amount);
    }

    function fundYieldBuffer(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        depositToken.safeApprove(address(aaveStrategy), 0);
        depositToken.safeApprove(address(aaveStrategy), amount);
        aaveStrategy.deposit(amount);
        yieldBuffer += amount;
        emit YieldBufferFunded(msg.sender, amount);
    }

    function setMaxParticipants(uint256 _max) external onlyOwner {
        require(_max >= 10, "V3: max too low");
        require(_max <= MAX_PARTICIPANTS_CEILING, "V3: max too high");
        maxParticipants = _max;
    }

    /**
     * @notice Tune how many participants `settleRound` processes per call. Lower
     *         it if settle txs approach the block gas limit; raise it (≤
     *         MAX_SETTLE_BATCH) to finish big pools in fewer calls. Cannot be
     *         changed mid-settle (would corrupt the reservoir pass).
     */
    function setSettleBatch(uint256 _batch) external onlyOwner {
        require(_batch >= 1 && _batch <= MAX_SETTLE_BATCH, "V3: bad batch");
        require(!settlement.active, "V3: settle in progress");
        settleBatch = _batch;
    }

    /**
     * @notice Settlement progress for the keeper/UI: whether a multi-batch settle
     *         is underway, the round, and how many participants are processed.
     */
    function settlementInProgress()
        external
        view
        returns (bool active, uint256 roundId, uint256 processed, uint256 total)
    {
        Settlement storage s = settlement;
        return (s.active, s.roundId, uint256(s.cursor), _participants.length());
    }

    function setCanaryAutoTune(bool enabled) external onlyOwner {
        canaryAutoTuneEnabled = enabled;
        emit CanaryAutoTuneToggled(enabled);
    }

    /**
     * @notice Raise or lower the minimum participant count required before a
     *         draw can fire. Default 1. Setting to 0 is disallowed — would
     *         let `performUpkeep` attempt a draw with nobody in the pool.
     *         Setting to a very high value effectively pauses draws until
     *         the pool reaches that size; useful for a freshly seeded pool
     *         that hasn't gathered a meaningful participant set yet.
     */
    function setMinParticipantsForDraw(uint32 newMin) external onlyOwner {
        require(newMin >= 1, "V3: min must be >= 1");
        uint32 oldValue = minParticipantsForDraw;
        minParticipantsForDraw = newMin;
        emit MinParticipantsForDrawUpdated(oldValue, newMin);
    }

    /**
     * @notice Emergency escape for a stuck `isDrawPending = true` state.
     *         Normally VRF's callback flips this back to false via
     *         `fulfillRandomness`. If the callback itself reverts (e.g.
     *         an accounting invariant break inside `_distributePrizes`),
     *         or if the RandomnessManager's manualFulfill path also
     *         fails, the round would otherwise be permanently locked.
     *
     *         Requires the round's endTime to be at least
     *         `RandomnessManager.VRF_TIMEOUT` in the past — the same
     *         threshold the RandomnessManager uses to allow
     *         `manualFulfill`. That prevents the owner from racing a
     *         legitimate VRF response.
     *
     *         Effects:
     *           - Clears `isDrawPending` so `performUpkeep` can retry.
     *           - Resets the outstanding RandomnessManager request so
     *             a fresh `requestRandomness` can be issued.
     *           - Slides `endTime` forward to `block.timestamp` so the
     *             retry can fire in the next block.
     *
     *         Does NOT settle the round or distribute a prize — there is
     *         no random word available. The prize stays in the pool and
     *         flows into the next successful draw.
     */
    function cancelDraw() external onlyOwner nonReentrant {
        Round storage r = rounds[currentRoundId];
        if (!r.isDrawPending) revert DrawNotReady();
        if (r.isSettled)      revert RoundAlreadySettled();

        // VRF_TIMEOUT in the RandomnessManager is 2 hours. We mirror the
        // same threshold here (measured from original endTime) so this
        // function can only run after VRF has genuinely had a chance.
        // 3 hours is a conservative buffer above VRF_TIMEOUT (2h).
        if (block.timestamp < r.endTime + 3 hours) revert DrawStillFresh();

        _voidRoundAndRefund();
    }

    /**
     * @dev Void the current round (no winner) and reserve its generated yield
     *      for a pro-rata, per-depositor refund — then open a fresh round.
     *
     *      Used by both `cancelDraw` (owner, +3h) and `cancelDrawPublic`
     *      (anyone, +7d). Rather than rolling a stuck round's yield into a
     *      future winner's prize, every depositor can reclaim THEIR OWN yield
     *      for the voided round (`claimRoundYield`), weighted by their TWAB over
     *      the round window. Principal is untouched (stays in the strategy).
     *
     *      The fresh round opened here uses a NEW requestKey (derived from the
     *      incremented roundId), so even if the RandomnessManager slot for the
     *      old round is still stuck, the next draw is unaffected.
     */
    function _voidRoundAndRefund() internal {
        uint256 roundId = currentRoundId;
        Round storage r = rounds[roundId];

        // Never cancel a round whose settlement has already STARTED. Once the
        // first settle batch runs, the prize is harvested and the reservoir is
        // mid-pass — and every remaining batch is pure on-chain compute (no
        // external calls), so the settle can ALWAYS be finished by calling
        // settleRound() again (permissionless). Cancelling here instead would
        // double-harvest and orphan the first batch's prize. So: if a settle is
        // in progress, the escape is "resume settleRound", not "cancel".
        require(!(settlement.active && settlement.roundId == roundId), "V3: settle in progress");

        // Best-effort reset of the RM request slot (requester path). With the
        // RMv2 fix this succeeds for a genuinely-failed request; if not, the
        // fresh round below sidesteps the stuck slot anyway.
        bytes32 requestKey = bytes32(uint256(uint160(address(this))) ^ roundId);
        try randomnessManager.resetFailedRequest(requestKey) {
        } catch {
            emit VRFRetryExhausted(roundId, requestKey);
        }

        r.isDrawPending          = false;
        r.totalDepositedSnapshot = 0;
        delete roundRandomReady[roundId];
        delete roundRandomWord[roundId];
        roundCancelled[roundId] = true;

        // Pull this round's generated yield out of the strategy and reserve it
        // for pro-rata refund. The standard 2% yield-only protocol fee applies
        // (consistent with settle and the AutoYieldVault) — never on principal.
        uint256 grossYield = _harvestPrize();
        if (grossYield > 0) {
            uint64 windowEnd  = uint64(block.timestamp);
            uint256 totalTwab = _getTwab(address(0), r.startTime, windowEnd);
            if (totalTwab > 0) {
                uint256 fee = (grossYield * protocolFeeBps) / BASIS_POINTS;
                accumulatedProtocolFees += fee;
                uint256 reserved = grossYield - fee;
                roundYieldRefund[roundId]    = reserved;
                roundYieldWindowEnd[roundId] = windowEnd;
                if (fee > 0) emit ProtocolFeeDeducted(roundId, fee);
                emit RoundYieldReserved(roundId, reserved, windowEnd, true);
            } else {
                // Unreachable post-draw (deposits ⇒ TWAB > 0); guard so funds
                // are never stranded.
                accumulatedProtocolFees += grossYield;
            }
        }

        emit DrawCancelled(roundId);

        // Resume deposits/withdrawals + enable the next draw.
        _startNewRound();
    }

    /**
     * @notice Claim your pro-rata share of a voided (cancelled) round's yield.
     *         Share = reservedYield × yourTWAB / totalTWAB over the round window
     *         — i.e. the yield YOUR funds generated while deposited that round.
     *         O(1); no participant loop, so it scales to any pool size.
     */
    function claimRoundYield(uint256 roundId) external nonReentrant {
        uint256 pool = roundYieldRefund[roundId];
        if (pool == 0)                                  revert NoPrizeToClaim();
        if (yieldRefundClaimed[roundId][msg.sender])    revert NoPrizeToClaim();

        uint64 start = rounds[roundId].startTime;
        uint64 end   = roundYieldWindowEnd[roundId];
        uint256 totalTwab = _getTwab(address(0), start, end);
        uint256 userTwab  = _getTwab(msg.sender, start, end);
        if (userTwab == 0 || totalTwab == 0)            revert NoPrizeToClaim();

        yieldRefundClaimed[roundId][msg.sender] = true;
        uint256 amount = (pool * userTwab) / totalTwab;
        if (amount == 0)                                revert NoPrizeToClaim();

        depositToken.safeTransfer(msg.sender, amount);
        emit RoundYieldClaimed(roundId, msg.sender, amount);
    }

    /**
     * @notice How much pro-rata yield `user` can still claim from `roundId`
     *         (0 if none / already claimed). O(1) — lets the frontend show the
     *         exact claimable amount without indexing TWAB off-chain.
     */
    function claimableRoundYield(uint256 roundId, address user) external view returns (uint256) {
        uint256 pool = roundYieldRefund[roundId];
        if (pool == 0 || yieldRefundClaimed[roundId][user]) return 0;
        uint64 start = rounds[roundId].startTime;
        uint64 end   = roundYieldWindowEnd[roundId];
        if (end <= start) return 0;
        uint256 totalTwab = _getTwab(address(0), start, end);
        if (totalTwab == 0) return 0;
        uint256 userTwab = _getTwab(user, start, end);
        return (pool * userTwab) / totalTwab;
    }

    /**
     * @notice Permissionless escape from a stalled VRF draw, mirroring
     *         `ContestV2.forceDeterministicFallback`'s public-after-timeout
     *         path. Anyone can call this once the round's `endTime` is at
     *         least `CANCEL_DRAW_PUBLIC_TIMEOUT` (7 days) in the past so a
     *         non-responsive owner cannot indefinitely lock principal —
     *         the `withdraw` guard pairs with this to ensure the worst-case
     *         lock is exactly 7 days.
     *
     *         Behaviour is identical to `cancelDraw`: voids the round (no
     *         winner), reserves its generated yield for a pro-rata per-depositor
     *         refund (`claimRoundYield`), resets the RandomnessManager slot, and
     *         opens a fresh round. Principal is never locked beyond 7 days.
     */
    uint256 public constant CANCEL_DRAW_PUBLIC_TIMEOUT = 7 days;

    function cancelDrawPublic() external nonReentrant {
        Round storage r = rounds[currentRoundId];
        if (!r.isDrawPending) revert DrawNotReady();
        if (r.isSettled)      revert RoundAlreadySettled();
        if (block.timestamp < r.endTime + CANCEL_DRAW_PUBLIC_TIMEOUT) revert DrawStillFresh();

        _voidRoundAndRefund();
    }

    function setGuardian(address _guardian) external onlyOwner {
        emit GuardianUpdated(guardian, _guardian);
        guardian = _guardian;
    }

    function pause() external {
        require(msg.sender == owner() || msg.sender == guardian, "Not authorized");
        _pause();
    }

    function unpause() external onlyOwner { _unpause(); }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _startNewRound() internal {
        currentRoundId++;
        uint64 start = uint64(block.timestamp);
        uint64 end   = start + uint64(roundDuration);

        rounds[currentRoundId] = Round({
            id:                     currentRoundId,
            startTime:              start,
            endTime:                end,
            totalDepositedSnapshot: 0,
            isDrawPending:          false,
            isSettled:              false,
            totalPrize:             0,
            protocolFee:            0
        });

        emit RoundStarted(currentRoundId, start, end);
    }

    /**
     * @dev Display-only effective weight: current balance × streak multiplier.
     *      NOT used for winner selection (that uses TWAB — see `settleRound`).
     *      Kept for the `getEffectiveWeight` view / frontend odds preview.
     */
    function _getEffectiveWeight(address user) internal view returns (uint256) {
        uint256 base = userDeposited[user];
        uint16 mult = _getStreakMultiplier(streakCount[user]);
        return (base * uint256(mult)) / BASIS_POINTS;
    }

    /**
     * @dev Look up the streak multiplier for a given streak count.
     *      Returns BASIS_POINTS (10000 = 1.0x) if below the first threshold.
     */
    function _getStreakMultiplier(uint16 streak) internal view returns (uint16) {
        uint16 mult = uint16(BASIS_POINTS); // 1.0x default
        for (uint8 i = 0; i < MAX_STREAK_LEVELS;) {
            if (streak >= streakThresholds[i]) {
                mult = streakMultipliers[i];
            } else {
                break;
            }
            unchecked { i++; }
        }
        return mult;
    }

    /**
     * @dev Update streak counts for all active participants after a round settles.
     *      If the participant was active in the previous round (consecutive), increment.
     *      Otherwise, reset to 1 (they were active this round).
     */
    function _updateStreaks() internal {
        uint256 len = _participants.length();
        uint256 roundId = currentRoundId;

        for (uint256 i = 0; i < len;) {
            address p = _participants.at(i);
            uint256 lastRound = lastActiveRound[p];

            if (roundId == 1 || lastRound == roundId - 1) {
                // Consecutive or first round ever
                streakCount[p]++;
            } else {
                // Streak broken — reset to 1 (active this round)
                streakCount[p] = 1;
            }

            lastActiveRound[p] = roundId;
            emit StreakUpdated(p, streakCount[p]);

            unchecked { i++; }
        }
    }

    function _harvestPrize() internal returns (uint256 prize) {
        uint256 currentValue = aaveStrategy.getTotalValue();
        uint256 totalOwed = totalDebt + yieldBuffer + accumulatedProtocolFees;
        if (currentValue <= totalOwed) return 0;

        prize = currentValue - totalOwed;

        uint256 sharesToBurn = _sharesForAmount(prize);
        if (sharesToBurn == 0) return 0;

        prize = aaveStrategy.withdraw(sharesToBurn);
    }

    function _updateCanaryState(bool smallestTierClaimed) internal {
        if (smallestTierClaimed) {
            canaryUnclaimed = 0;
            canaryClaimed++;

            if (canaryClaimed >= CANARY_UP_THRESHOLD && numberOfTiers < MAX_TIERS) {
                uint8 oldTiers = numberOfTiers;
                numberOfTiers++;
                uint256 newTierBps = 1_000; // 10% for new canary tier
                // Proportional reduction: scale each tier down by (10000 - 1000) / 10000
                // This is safe even when individual tiers are small
                for (uint8 i = 0; i < oldTiers; i++) {
                    tierBps[i] = (tierBps[i] * (BASIS_POINTS - newTierBps)) / BASIS_POINTS;
                }
                uint256 total = 0;
                for (uint8 i = 0; i < oldTiers; i++) {
                    total += tierBps[i];
                }
                tierBps[numberOfTiers - 1] = BASIS_POINTS - total;
                canaryClaimed = 0;
                emit TierAutoAdjusted(oldTiers, numberOfTiers, "canary-up");
            }
        } else {
            canaryClaimed = 0;
            canaryUnclaimed++;

            if (canaryUnclaimed >= CANARY_DOWN_THRESHOLD && numberOfTiers > 1) {
                uint8 oldTiers = numberOfTiers;
                uint256 removedBps = tierBps[numberOfTiers - 1];
                tierBps[numberOfTiers - 1] = 0;
                numberOfTiers--;
                uint256 addPerTier = removedBps / numberOfTiers;
                uint256 remainder = removedBps - (addPerTier * numberOfTiers);
                for (uint8 i = 0; i < numberOfTiers; i++) {
                    tierBps[i] += addPerTier;
                }
                tierBps[0] += remainder;
                canaryUnclaimed = 0;
                emit TierAutoAdjusted(oldTiers, numberOfTiers, "canary-down");
            }
        }
    }

    function _sharesForAmount(uint256 amount) internal view returns (uint256) {
        uint256 totalValue = aaveStrategy.getTotalValue();
        if (totalValue == 0) return amount;

        uint256 lotteryShares = aaveStrategy.shares(address(this));
        if (lotteryShares == 0) return 0;

        return (amount * lotteryShares) / totalValue;
    }
}
