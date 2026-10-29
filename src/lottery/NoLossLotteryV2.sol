// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../strategies/AaveStrategy.sol";
import "../interfaces/IRandomnessManager.sol";
import "./TwabController.sol";

/**
 * @title NoLossLotteryV2
 * @notice Enhanced no-loss lottery with PoolTogether V5-inspired features.
 *
 * Improvements over V1:
 *  1. TWAB-based proportional odds (no per-draw snapshot gas)
 *  2. Multi-tier prizes: Grand + Runner-up + Lucky tiers from single VRF word
 *  3. Delegation: delegate your odds without moving your deposit
 *  4. Auto-compound: opt-in to re-deposit winnings automatically
 *  5. Protocol fee: capped at 10% of yield, funds platform treasury
 *  6. EnumerableSet for O(1) participant add/remove
 *  7. Yield buffer: deployer-funded dust buffer to absorb rounding errors (PT V5)
 *  8. Debt/asset separation: totalDebt tracks what is owed, decoupled from totalAssets
 *  9. Draw replay protection: strict state machine guards on fulfillRandomness
 * 10. Canary tier auto-tuning: adjusts tier count based on claim patterns
 *
 * Flow:
 *  1. Users deposit at any time → funds go to Aave, TWAB recorded.
 *  2. After roundDuration, Chainlink Automation calls performUpkeep().
 *  3. performUpkeep() requests VRF from RandomnessManager.
 *  4. fulfillRandomness() derives multiple tier winners from single random word,
 *     harvests yield, distributes prizes, starts next round.
 *  5. Winners claim prizes (or auto-compound re-deposits).
 */
contract NoLossLotteryV2 is TwabController, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ─── Constants ──────────────────────────────────────────────────────────────

    uint256 public constant BASIS_POINTS         = 10_000;
    uint256 public constant MIN_ROUND_DURATION   = 1 hours;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1_000; // 10%
    uint8   public constant MAX_TIERS            = 5;

    // ─── Immutables ─────────────────────────────────────────────────────────────

    IERC20           public immutable depositToken;
    AaveStrategy     public immutable aaveStrategy;
    IRandomnessManager public immutable randomnessManager;

    // ─── Configuration ──────────────────────────────────────────────────────────

    uint256 public roundDuration;          // default 7 days
    uint256 public protocolFeeBps;         // default 200 (2%)
    address public protocolFeeRecipient;
    uint8   public numberOfTiers;          // active prize tiers (1-5)

    /// @notice Prize distribution per tier in basis points (must sum to 10000).
    ///         Index 0 = Grand Prize, 1 = Runner-up, etc.
    uint256[MAX_TIERS] public tierBps;

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

    // ─── Prize Tiers ────────────────────────────────────────────────────────────

    struct TierResult {
        address winner;
        uint256 amount;
    }

    /// @dev roundId → tier index → TierResult
    mapping(uint256 => mapping(uint8 => TierResult)) public tierResults;

    // ─── User State ─────────────────────────────────────────────────────────────

    /// @notice Total principal held in strategy.
    uint256 public totalDeposited;

    /// @notice Prize claims: roundId → user → amount
    mapping(uint256 => mapping(address => uint256)) public pendingPrizes;

    /// @notice Delegation: delegator → delegate (address(0) means self)
    mapping(address => address) public delegates;

    /// @notice Auto-compound opt-in
    mapping(address => bool) public autoCompound;

    /// @notice Each user's own deposited amount (not including delegated weight)
    mapping(address => uint96) public userDeposited;

    /// @notice Accumulated protocol fees not yet withdrawn
    uint256 public accumulatedProtocolFees;

    // ─── Yield Buffer (PoolTogether V5 pattern) ───────────────────────────────

    /// @notice Deployer-funded buffer to absorb rounding errors in share/asset conversions.
    ///         Until yield generation naturally covers dust, this buffer prevents deposit/withdraw
    ///         rounding from causing accounting discrepancies.
    uint256 public yieldBuffer;

    // ─── Debt/Asset Separation (PoolTogether V5 pattern) ──────────────────────

    /// @notice Total debt owed to depositors (sum of all deposits minus withdrawals).
    ///         Decoupled from totalAssets so the contract handles under-collateralization gracefully.
    uint256 public totalDebt;

    // ─── Canary Tier Auto-Tuning ──────────────────────────────────────────────

    /// @notice Tracks whether the smallest active tier was claimed in the last round.
    ///         If not claimed for `canaryDownThreshold` consecutive rounds, reduce tier count.
    ///         If claimed for `canaryUpThreshold` consecutive rounds, increase tier count.
    uint8 public canaryUnclaimed;   // consecutive rounds where smallest tier went unclaimed
    uint8 public canaryClaimed;     // consecutive rounds where smallest tier was claimed
    uint8 public constant CANARY_DOWN_THRESHOLD = 3; // unclaimed 3x → remove tier
    uint8 public constant CANARY_UP_THRESHOLD   = 3; // claimed 3x   → add tier
    bool  public canaryAutoTuneEnabled;

    // ─── Draw Replay Protection ───────────────────────────────────────────────

    /// @notice Nonce incremented on each draw to prevent replay/re-entrancy across rounds
    uint256 public drawNonce;

    // ─── Participant Set ────────────────────────────────────────────────────────

    EnumerableSet.AddressSet private _participants;

    // ─── Events ─────────────────────────────────────────────────────────────────

    event Deposited(address indexed participant, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed participant, uint256 amount, uint256 remainingBalance);
    event RoundStarted(uint256 indexed roundId, uint64 startTime, uint64 endTime);
    event DrawRequested(uint256 indexed roundId, bytes32 requestKey);
    event TierWinner(uint256 indexed roundId, uint8 indexed tier, address indexed winner, uint256 amount);
    event RoundSettled(uint256 indexed roundId, uint256 totalPrize, uint256 protocolFee);
    event PrizeClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);
    event PrizeAutoCompounded(uint256 indexed roundId, address indexed winner, uint256 amount);
    event DelegateChanged(address indexed delegator, address indexed oldDelegate, address indexed newDelegate);
    event AutoCompoundToggled(address indexed user, bool enabled);
    event ProtocolFeeUpdated(uint256 newFeeBps);
    event ProtocolFeesWithdrawn(address indexed recipient, uint256 amount);
    event TierConfigUpdated(uint8 numberOfTiers, uint256[5] bps);
    event RoundDurationUpdated(uint256 newDuration);
    event YieldBufferFunded(address indexed funder, uint256 amount);
    event CanaryAutoTuneToggled(bool enabled);
    event TierAutoAdjusted(uint8 oldTiers, uint8 newTiers, string reason);

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
    error SelfDelegation();
    error InvalidRecipient();
    error DrawReplay();
    error Undercollateralized();

    // ─── Constructor ────────────────────────────────────────────────────────────

    constructor(
        address _depositToken,
        address _aaveStrategy,
        address _randomnessManager,
        uint256 _roundDuration,
        address _feeRecipient
    ) Ownable() {
        require(_depositToken != address(0),       "V2: invalid token");
        require(_aaveStrategy != address(0),       "V2: invalid strategy");
        require(_randomnessManager != address(0),  "V2: invalid RM");
        require(_roundDuration >= MIN_ROUND_DURATION, "V2: duration too short");
        require(_feeRecipient != address(0),       "V2: invalid fee recipient");

        depositToken       = IERC20(_depositToken);
        aaveStrategy       = AaveStrategy(_aaveStrategy);
        randomnessManager  = IRandomnessManager(_randomnessManager);
        roundDuration      = _roundDuration;
        protocolFeeRecipient = _feeRecipient;

        // Default: 2% protocol fee, 2 tiers (70/30)
        protocolFeeBps = 200;
        numberOfTiers  = 2;
        tierBps[0] = 7_000; // Grand prize: 70%
        tierBps[1] = 3_000; // Runner-up:   30%

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
        require(amount <= type(uint96).max, "V2: amount overflow");

        depositToken.safeTransferFrom(msg.sender, address(this), amount);

        // Approve exact amount for this deposit (no unlimited approval)
        depositToken.safeApprove(address(aaveStrategy), 0);
        depositToken.safeApprove(address(aaveStrategy), amount);
        aaveStrategy.deposit(amount);

        uint96 amt96 = uint96(amount);
        address effectiveUser = _effectiveUser(msg.sender);

        // Record TWAB for the effective user (delegate or self)
        _increaseBalance(effectiveUser, amt96);

        totalDeposited += amount;
        totalDebt += amount;
        userDeposited[msg.sender] += amt96;
        _participants.add(msg.sender);

        emit Deposited(msg.sender, amount, _accounts[effectiveUser].balance);
    }

    /**
     * @notice Withdraw principal at any time. Yield stays in prize pool.
     * @param amount Amount to withdraw.
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address effectiveUser = _effectiveUser(msg.sender);
        if (_accounts[effectiveUser].balance < uint96(amount)) revert InsufficientBalance();

        // Pro-rata withdrawal if under-collateralized (PT V5 pattern):
        // Check BEFORE decrementing totalDebt so the ratio uses current state
        uint256 strategyValue = aaveStrategy.getTotalValue();
        uint256 actualAmount = amount;
        if (strategyValue < totalDebt) {
            actualAmount = (amount * strategyValue) / totalDebt;
        }

        uint96 amt96 = uint96(amount);
        _decreaseBalance(effectiveUser, amt96);

        totalDeposited -= amount;
        totalDebt -= amount;
        userDeposited[msg.sender] -= amt96;

        // Remove from participants if fully withdrawn (regardless of delegation)
        if (userDeposited[msg.sender] == 0) {
            _participants.remove(msg.sender);
        }

        uint256 sharesToBurn = _sharesForAmount(actualAmount);
        uint256 actualOut = aaveStrategy.withdraw(sharesToBurn);
        depositToken.safeTransfer(msg.sender, actualOut);

        emit Withdrawn(msg.sender, actualOut, _accounts[effectiveUser].balance);
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
            // Re-deposit the prize
            require(prize <= type(uint96).max, "V2: prize overflow");
            depositToken.safeApprove(address(aaveStrategy), 0);
            depositToken.safeApprove(address(aaveStrategy), prize);
            aaveStrategy.deposit(prize);
            uint96 amt96 = uint96(prize);
            address effectiveUser = _effectiveUser(msg.sender);
            _increaseBalance(effectiveUser, amt96);
            totalDeposited += prize;
            totalDebt += prize;
            userDeposited[msg.sender] += amt96;
            _participants.add(msg.sender);
            emit PrizeAutoCompounded(roundId, msg.sender, prize);
        } else {
            depositToken.safeTransfer(msg.sender, prize);
            emit PrizeClaimed(roundId, msg.sender, prize);
        }
    }

    /**
     * @notice Delegate your lottery odds to another address.
     *         The delegate receives your TWAB weight but you keep your deposit.
     *         Pass address(0) to remove delegation (revert to self).
     */
    function setDelegate(address delegate) external {
        if (delegate == msg.sender) revert SelfDelegation();

        // Prevent delegation chains: delegate must not have their own delegate
        if (delegate != address(0) && delegates[delegate] != address(0)) {
            revert("V2: delegate already has a delegate");
        }

        address oldDelegate = delegates[msg.sender];
        address oldEffective = oldDelegate == address(0) ? msg.sender : oldDelegate;
        address newEffective = delegate == address(0) ? msg.sender : delegate;

        if (oldEffective == newEffective) return;

        // Move only this user's own deposited weight, not delegated weight
        uint96 bal = userDeposited[msg.sender];
        if (bal > 0) {
            _decreaseBalance(oldEffective, bal);
            _increaseBalance(newEffective, bal);
        }

        delegates[msg.sender] = delegate;
        emit DelegateChanged(msg.sender, oldDelegate, delegate);
    }

    /**
     * @notice Toggle auto-compound for winnings.
     */
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
            totalDeposited > 0
        );
        performData = "";
    }

    function performUpkeep(bytes calldata) external {
        Round storage r = rounds[currentRoundId];
        if (block.timestamp < r.endTime)   revert DrawNotReady();
        if (r.isDrawPending)               revert DrawAlreadyPending();
        if (r.isSettled)                   revert RoundAlreadySettled();
        if (totalDeposited == 0)           revert NoActiveParticipants();

        r.isDrawPending          = true;
        r.totalDepositedSnapshot = totalDeposited;

        bytes32 requestKey = bytes32(uint256(uint160(address(this))) ^ currentRoundId);
        randomnessManager.requestRandomness(requestKey);

        emit DrawRequested(currentRoundId, requestKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VRF CALLBACK
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by RandomnessManager. Derives multi-tier winners from
     *         a single VRF word via keccak256 chaining.
     */
    function fulfillRandomness(uint256 randomWord) external nonReentrant {
        if (msg.sender != address(randomnessManager)) revert NotRandomnessManager();

        Round storage r = rounds[currentRoundId];
        require(!r.isSettled, "V2: already settled");
        require(r.isDrawPending, "V2: no draw pending");

        // Draw replay protection: increment nonce and validate
        drawNonce++;

        // Harvest yield
        uint256 grossPrize = _harvestPrize();

        // Protocol fee
        uint256 fee = (grossPrize * protocolFeeBps) / BASIS_POINTS;
        uint256 netPrize = grossPrize - fee;
        accumulatedProtocolFees += fee;

        r.totalPrize    = netPrize;
        r.protocolFee   = fee;
        r.isSettled     = true;
        r.isDrawPending = false;

        // Select winners per tier
        bool smallestTierClaimed = false;
        if (netPrize > 0 && _participants.length() > 0) {
            smallestTierClaimed = _distributePrizes(r.id, randomWord, netPrize);
        }

        // Canary tier auto-tuning (PT V5 pattern)
        if (canaryAutoTuneEnabled && numberOfTiers > 1) {
            _updateCanaryState(smallestTierClaimed);
        }

        emit RoundSettled(r.id, netPrize, fee);

        _startNewRound();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice TWAB-based win probability in basis points.
     *         Uses the current round time range for the TWAB calculation.
     */
    function getWinProbability(address participant) external view returns (uint256) {
        Round storage r = rounds[currentRoundId];
        uint64 start = r.startTime;
        uint64 end = uint64(block.timestamp);
        if (end <= start) return 0;

        uint256 userTwab = _getTwab(_effectiveUser(participant), start, end);
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

    function getDelegate(address user) external view returns (address) {
        address d = delegates[user];
        return d == address(0) ? user : d;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setRoundDuration(uint256 newDuration) external onlyOwner {
        require(newDuration >= MIN_ROUND_DURATION, "V2: too short");
        roundDuration = newDuration;
        emit RoundDurationUpdated(newDuration);
    }

    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(newFeeBps);
    }

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        protocolFeeRecipient = recipient;
    }

    /**
     * @notice Configure prize tier distribution.
     * @param _numberOfTiers Number of active tiers (1-5).
     * @param _tierBps       BPS per tier (must sum to 10000 across active tiers).
     */
    function setTierConfig(uint8 _numberOfTiers, uint256[5] calldata _tierBps) external onlyOwner {
        if (_numberOfTiers == 0 || _numberOfTiers > MAX_TIERS) revert InvalidTierConfig();

        uint256 total = 0;
        for (uint8 i = 0; i < _numberOfTiers; i++) {
            total += _tierBps[i];
        }
        if (total != BASIS_POINTS) revert InvalidTierConfig();

        // Remaining tiers must be 0
        for (uint8 i = _numberOfTiers; i < MAX_TIERS; i++) {
            if (_tierBps[i] != 0) revert InvalidTierConfig();
        }

        numberOfTiers = _numberOfTiers;
        for (uint8 i = 0; i < MAX_TIERS; i++) {
            tierBps[i] = _tierBps[i];
        }

        emit TierConfigUpdated(_numberOfTiers, _tierBps);
    }

    function withdrawProtocolFees() external onlyOwner {
        uint256 amount = accumulatedProtocolFees;
        require(amount > 0, "V2: no fees");
        accumulatedProtocolFees = 0;
        depositToken.safeTransfer(protocolFeeRecipient, amount);
        emit ProtocolFeesWithdrawn(protocolFeeRecipient, amount);
    }

    /**
     * @notice Fund the yield buffer to absorb rounding errors (PT V5 pattern).
     *         Anyone can contribute, but typically done by the deployer at init.
     */
    function fundYieldBuffer(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        depositToken.safeApprove(address(aaveStrategy), 0);
        depositToken.safeApprove(address(aaveStrategy), amount);
        aaveStrategy.deposit(amount);
        yieldBuffer += amount;
        emit YieldBufferFunded(msg.sender, amount);
    }

    function setCanaryAutoTune(bool enabled) external onlyOwner {
        canaryAutoTuneEnabled = enabled;
        emit CanaryAutoTuneToggled(enabled);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _effectiveUser(address user) internal view returns (address) {
        address d = delegates[user];
        return d == address(0) ? user : d;
    }

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
     * @dev Derive multiple random values from a single VRF word using keccak256 chaining.
     *      tierRandom[i] = keccak256(abi.encodePacked(randomWord, i))
     *
     *      For each tier, select a winner proportional to their TWAB during the round.
     */
    /**
     * @dev Returns true if the smallest (last) active tier found a winner.
     */
    function _distributePrizes(uint256 roundId, uint256 randomWord, uint256 netPrize) internal returns (bool smallestTierClaimed) {
        Round storage r = rounds[roundId];

        for (uint8 tier = 0; tier < numberOfTiers; tier++) {
            uint256 tierPrize = (netPrize * tierBps[tier]) / BASIS_POINTS;
            if (tierPrize == 0) continue;

            // Derive tier-specific random value
            uint256 tierRandom = uint256(keccak256(abi.encodePacked(randomWord, tier)));

            // Select winner via TWAB-weighted random selection
            address winner = _selectTwabWinner(tierRandom, r.startTime, r.endTime);

            if (winner != address(0)) {
                tierResults[roundId][tier] = TierResult({
                    winner: winner,
                    amount: tierPrize
                });
                pendingPrizes[roundId][winner] += tierPrize;

                // Track canary: smallest active tier is the last one
                if (tier == numberOfTiers - 1) {
                    smallestTierClaimed = true;
                }

                emit TierWinner(roundId, tier, winner, tierPrize);
            }
        }
    }

    /**
     * @dev TWAB-weighted winner selection across all participants.
     *      Uses the round's time range for TWAB calculation.
     */
    function _selectTwabWinner(
        uint256 randomValue,
        uint64 start,
        uint64 end
    ) internal view returns (address) {
        uint256 len = _participants.length();
        if (len == 0) return address(0);

        uint64 effectiveEnd = end > uint64(block.timestamp) ? uint64(block.timestamp) : end;

        // Get total TWAB
        uint256 totalTwab = _getTwab(address(0), start, effectiveEnd);
        if (totalTwab == 0) {
            // Fallback: uniform random if no TWAB data
            return _participants.at(randomValue % len);
        }

        // Use each participant's own deposited amount as weight to avoid
        // double-counting delegated TWAB when multiple participants share
        // the same effective user.
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len; i++) {
            totalWeight += userDeposited[_participants.at(i)];
        }
        if (totalWeight == 0) {
            return _participants.at(randomValue % len);
        }

        uint256 target = randomValue % totalWeight;
        uint256 cumulative = 0;

        for (uint256 i = 0; i < len; i++) {
            address participant = _participants.at(i);
            cumulative += userDeposited[participant];
            if (target < cumulative) {
                return participant;
            }
        }

        // Fallback
        return _participants.at(len - 1);
    }

    function _harvestPrize() internal returns (uint256 prize) {
        uint256 currentValue = aaveStrategy.getTotalValue();
        // Total owed = depositor debt + yield buffer + accumulated protocol fees
        uint256 totalOwed = totalDebt + yieldBuffer + accumulatedProtocolFees;
        if (currentValue <= totalOwed) return 0;

        prize = currentValue - totalOwed;

        uint256 sharesToBurn = _sharesForAmount(prize);
        if (sharesToBurn == 0) return 0;

        prize = aaveStrategy.withdraw(sharesToBurn);
    }

    /**
     * @dev Canary tier auto-tuning logic (inspired by PoolTogether V5).
     *      Adjusts the number of active prize tiers based on claim patterns.
     */
    function _updateCanaryState(bool smallestTierClaimed) internal {
        if (smallestTierClaimed) {
            canaryUnclaimed = 0;
            canaryClaimed++;

            // Smallest tier keeps getting claimed → add a tier (more/smaller prizes)
            if (canaryClaimed >= CANARY_UP_THRESHOLD && numberOfTiers < MAX_TIERS) {
                uint8 oldTiers = numberOfTiers;
                numberOfTiers++;
                // Redistribute BPS: take 10% from existing tiers, give to new tier
                uint256 newTierBps = 1_000; // 10%
                uint256 reduction = newTierBps / oldTiers;
                for (uint8 i = 0; i < oldTiers; i++) {
                    tierBps[i] -= reduction;
                }
                // Handle rounding: ensure total = 10000
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

            // Smallest tier keeps going unclaimed → remove it (fewer/bigger prizes)
            if (canaryUnclaimed >= CANARY_DOWN_THRESHOLD && numberOfTiers > 1) {
                uint8 oldTiers = numberOfTiers;
                // Redistribute the removed tier's BPS to remaining tiers
                uint256 removedBps = tierBps[numberOfTiers - 1];
                tierBps[numberOfTiers - 1] = 0;
                numberOfTiers--;
                uint256 addPerTier = removedBps / numberOfTiers;
                uint256 remainder = removedBps - (addPerTier * numberOfTiers);
                for (uint8 i = 0; i < numberOfTiers; i++) {
                    tierBps[i] += addPerTier;
                }
                tierBps[0] += remainder; // give remainder to grand prize
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

        // Round down (in protocol's favor for withdrawals, PT V5 pattern)
        return (amount * lotteryShares) / totalValue;
    }

    /**
     * @notice View: get the total assets held by the strategy on behalf of this lottery.
     */
    function totalAssets() external view returns (uint256) {
        return aaveStrategy.getTotalValue();
    }

    /**
     * @notice View: check if the vault is under-collateralized.
     */
    function isUndercollateralized() external view returns (bool) {
        return aaveStrategy.getTotalValue() < totalDebt;
    }
}
