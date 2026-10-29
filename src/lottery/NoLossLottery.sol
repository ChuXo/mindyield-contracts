// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../strategies/AaveStrategy.sol";
import "../interfaces/IRandomnessManager.sol";

/**
 * @title NoLossLottery
 * @notice Platform-managed weekly no-loss lottery powered by Aave yield.
 *
 * Flow:
 *  1. Users deposit at any time (funds go to Aave via AaveStrategy).
 *  2. After 7 days, Chainlink Automation calls performUpkeep().
 *  3. performUpkeep() snapshots all live balances and requests VRF from RandomnessManager.
 *  4. RandomnessManager calls fulfillRandomness() with a random word.
 *  5. Winner is selected proportional to their balance; prize = yield since round start.
 *  6. A new round begins immediately.
 *  7. Winner calls claimPrize(roundId) to collect.
 *
 * Security considerations:
 *  - Deposits forwarded directly to AaveStrategy; principal protected.
 *  - Yield harvested only at draw time; never touched otherwise.
 *  - Re-entrancy protected on all external state-changing functions.
 *  - Only RandomnessManager can call fulfillRandomness.
 */
contract NoLossLottery is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MIN_ROUND_DURATION = 1 hours;
    uint256 public constant MAX_PARTICIPANTS = 10000;

    // ─── Immutables ───────────────────────────────────────────────────────────

    IERC20 public immutable depositToken;
    AaveStrategy public immutable aaveStrategy;
    IRandomnessManager public immutable randomnessManager;

    // ─── Configuration ────────────────────────────────────────────────────────

    uint256 public roundDuration; // default 7 days

    // ─── Round State ──────────────────────────────────────────────────────────

    struct Round {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
        uint256 yieldAtStart;            // strategy total value at round start
        uint256 totalDepositedSnapshot;  // sum of participant balances at draw time
        bool    isDrawPending;
        bool    isSettled;
        address winner;
        uint256 prizeAmount;
    }

    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;

    // ─── User Balances ────────────────────────────────────────────────────────

    /// @notice Persistent deposit balances; survive round boundaries.
    mapping(address => uint256) public balances;

    /// @notice Total principal held in the strategy.
    uint256 public totalDeposited;

    // ─── Participant Registry ─────────────────────────────────────────────────

    /// @dev Ordered list of unique depositors for proportional selection.
    address[] private _participants;
    mapping(address => bool) private _isParticipant;
    mapping(address => uint256) private _participantIndex;

    // ─── Snapshot (populated at draw time) ───────────────────────────────────

    address[] private _snapshotAddresses;
    uint256[] private _snapshotWeights;

    // ─── Prize Claims ─────────────────────────────────────────────────────────

    /// roundId → winner address → claimable amount
    mapping(uint256 => mapping(address => uint256)) public pendingPrizes;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed participant, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed participant, uint256 amount, uint256 remainingBalance);
    event RoundStarted(uint256 indexed roundId, uint256 startTime, uint256 endTime);
    event DrawRequested(uint256 indexed roundId, bytes32 requestKey);
    event WinnerSelected(uint256 indexed roundId, address indexed winner, uint256 prizeAmount);
    event PrizeClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);
    event RoundDurationUpdated(uint256 newDuration);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientBalance();
    error DrawNotReady();
    error DrawAlreadyPending();
    error RoundAlreadySettled();
    error RoundNotSettled();
    error NoPrizeToClaim();
    error NotRandomnessManager();
    error NoActiveParticipants();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _depositToken,
        address _aaveStrategy,
        address _randomnessManager,
        uint256 _roundDuration
    ) Ownable() {
        require(_depositToken != address(0),       "NoLossLottery: invalid token");
        require(_aaveStrategy != address(0),       "NoLossLottery: invalid strategy");
        require(_randomnessManager != address(0),  "NoLossLottery: invalid randomness manager");
        require(_roundDuration >= MIN_ROUND_DURATION, "NoLossLottery: duration too short");

        depositToken    = IERC20(_depositToken);
        aaveStrategy    = AaveStrategy(_aaveStrategy);
        randomnessManager = IRandomnessManager(_randomnessManager);
        roundDuration   = _roundDuration;

        _startNewRound();
    }

    // ─── User: Deposit ────────────────────────────────────────────────────────

    /**
     * @notice Deposit tokens to participate. Funds go immediately to Aave.
     * @param amount Amount of deposit tokens (in token's native decimals).
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        require(_participants.length < MAX_PARTICIPANTS, "NoLossLottery: max participants reached");

        depositToken.safeTransferFrom(msg.sender, address(this), amount);

        // Approve exact amount for this deposit (no unlimited approval)
        depositToken.safeApprove(address(aaveStrategy), 0);
        depositToken.safeApprove(address(aaveStrategy), amount);

        // Forward to Aave strategy. Strategy pulls via transferFrom.
        aaveStrategy.deposit(amount);

        balances[msg.sender] += amount;
        totalDeposited       += amount;

        // Register new participant
        if (!_isParticipant[msg.sender]) {
            _isParticipant[msg.sender] = true;
            _participantIndex[msg.sender] = _participants.length;
            _participants.push(msg.sender);
        }

        emit Deposited(msg.sender, amount, balances[msg.sender]);
    }

    // ─── User: Withdraw ───────────────────────────────────────────────────────

    /**
     * @notice Withdraw principal at any time. Yield stays in the prize pool.
     * @param amount Amount of tokens to withdraw.
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0)                       revert ZeroAmount();
        if (balances[msg.sender] < amount)     revert InsufficientBalance();

        balances[msg.sender] -= amount;
        totalDeposited       -= amount;

        // Remove from participants array on full withdrawal (swap-and-pop)
        if (balances[msg.sender] == 0 && _isParticipant[msg.sender]) {
            _removeParticipant(msg.sender);
        }

        // Burn the portion of strategy shares corresponding to `amount`
        uint256 sharesToBurn = _sharesForAmount(amount);
        uint256 actualOut    = aaveStrategy.withdraw(sharesToBurn);

        // AaveStrategy.aavePool.withdraw sends tokens to msg.sender (= this contract).
        // Transfer the actual withdrawn amount to the user.
        depositToken.safeTransfer(msg.sender, actualOut);

        emit Withdrawn(msg.sender, actualOut, balances[msg.sender]);
    }

    // ─── User: Claim Prize ────────────────────────────────────────────────────

    /**
     * @notice Collect prize for a settled round.
     * @param roundId The round to claim from.
     */
    function claimPrize(uint256 roundId) external nonReentrant {
        if (!rounds[roundId].isSettled) revert RoundNotSettled();

        uint256 prize = pendingPrizes[roundId][msg.sender];
        if (prize == 0) revert NoPrizeToClaim();

        pendingPrizes[roundId][msg.sender] = 0;
        depositToken.safeTransfer(msg.sender, prize);

        emit PrizeClaimed(roundId, msg.sender, prize);
    }

    // ─── Chainlink Automation ─────────────────────────────────────────────────

    /**
     * @notice Chainlink Automation checkUpkeep — returns true when draw is due.
     */
    function checkUpkeep(bytes calldata)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        Round storage r = rounds[currentRoundId];
        upkeepNeeded = (
            block.timestamp >= r.endTime &&
            !r.isDrawPending              &&
            !r.isSettled                  &&
            totalDeposited > 0
        );
        performData = ""; // not used
    }

    /**
     * @notice Chainlink Automation performUpkeep — snapshots balances, requests VRF.
     */
    function performUpkeep(bytes calldata) external {
        Round storage r = rounds[currentRoundId];
        if (block.timestamp < r.endTime) revert DrawNotReady();
        if (r.isDrawPending)             revert DrawAlreadyPending();
        if (r.isSettled)                 revert RoundAlreadySettled();
        if (totalDeposited == 0)         revert NoActiveParticipants();

        _requestDraw();
    }

    // ─── VRF Callback ─────────────────────────────────────────────────────────

    /**
     * @notice Called by RandomnessManager when VRF fulfills the request.
     *         Selects winner, harvests prize, starts next round.
     * @param randomWord The random value from Chainlink VRF.
     */
    function fulfillRandomness(uint256 randomWord) external nonReentrant {
        if (msg.sender != address(randomnessManager)) revert NotRandomnessManager();

        Round storage r = rounds[currentRoundId];
        require(!r.isSettled, "NoLossLottery: already settled");

        address winner = _selectWinner(randomWord);
        uint256 prize  = _harvestPrize(r);

        r.winner      = winner;
        r.prizeAmount = prize;
        r.isSettled   = true;
        r.isDrawPending = false;

        if (prize > 0 && winner != address(0)) {
            pendingPrizes[r.id][winner] = prize;
        }

        emit WinnerSelected(r.id, winner, prize);

        // Immediately begin next round
        _startNewRound();
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /**
     * @notice Win probability for a participant in basis points (0-10000).
     */
    function getWinProbability(address participant) external view returns (uint256) {
        if (totalDeposited == 0) return 0;
        return (balances[participant] * BASIS_POINTS) / totalDeposited;
    }

    /**
     * @notice Estimated prize pool = yield accumulated above total principal.
     *         prize = strategy.getTotalValue() - totalDeposited
     *         This correctly counts only yield, not principal.
     */
    function getCurrentPrizePool() external view returns (uint256) {
        uint256 currentValue = aaveStrategy.getTotalValue();
        if (currentValue <= totalDeposited) return 0;
        return currentValue - totalDeposited;
    }

    /**
     * @notice Get full details of the current round.
     */
    function getCurrentRound() external view returns (Round memory) {
        return rounds[currentRoundId];
    }

    /**
     * @notice Get full details of any round by ID.
     */
    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    /**
     * @notice Number of registered participants.
     */
    function participantCount() external view returns (uint256) {
        return _participants.length;
    }

    // ─── Owner Functions ──────────────────────────────────────────────────────

    function setRoundDuration(uint256 newDuration) external onlyOwner {
        require(newDuration >= MIN_ROUND_DURATION, "NoLossLottery: too short");
        roundDuration = newDuration;
        emit RoundDurationUpdated(newDuration);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Sweep unclaimed prizes from rounds that ended more than 30 days ago.
     * @param roundId The round whose prize to reclaim.
     */
    function sweepUnclaimedPrizes(uint256 roundId) external onlyOwner nonReentrant {
        Round storage r = rounds[roundId];
        require(r.isSettled, "NoLossLottery: round not settled");
        require(block.timestamp > r.endTime + 30 days, "NoLossLottery: claim period not expired");

        address winner = r.winner;
        uint256 prize = pendingPrizes[roundId][winner];
        require(prize > 0, "NoLossLottery: no unclaimed prize");

        pendingPrizes[roundId][winner] = 0;
        depositToken.safeTransfer(owner(), prize);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _startNewRound() internal {
        currentRoundId++;
        uint256 start = block.timestamp;
        uint256 end   = start + roundDuration;

        rounds[currentRoundId] = Round({
            id:                     currentRoundId,
            startTime:              start,
            endTime:                end,
            yieldAtStart:           aaveStrategy.getTotalValue(),
            totalDepositedSnapshot: 0,
            isDrawPending:          false,
            isSettled:              false,
            winner:                 address(0),
            prizeAmount:            0
        });

        emit RoundStarted(currentRoundId, start, end);
    }

    /**
     * @dev Snapshot live balances into storage arrays, then request VRF.
     *      Gas note: participant list is bounded by real depositors; works up to
     *      ~thousands of participants within Chainlink Automation gas limits.
     */
    function _requestDraw() internal {
        Round storage r = rounds[currentRoundId];
        r.isDrawPending          = true;
        r.totalDepositedSnapshot = totalDeposited;

        // Build snapshot of current participant balances
        delete _snapshotAddresses;
        delete _snapshotWeights;

        uint256 snapshotTotal = 0;
        for (uint256 i = 0; i < _participants.length; i++) {
            address p = _participants[i];
            uint256 bal = balances[p];
            if (bal > 0) {
                _snapshotAddresses.push(p);
                _snapshotWeights.push(bal);
                snapshotTotal += bal;
            }
        }

        if (_snapshotAddresses.length == 0) revert NoActiveParticipants();

        // requestKey is unique per contract+round
        bytes32 requestKey = bytes32(uint256(uint160(address(this))) ^ currentRoundId);
        randomnessManager.requestRandomness(requestKey);

        emit DrawRequested(currentRoundId, requestKey);
    }

    /**
     * @dev Weighted random selection from snapshot.
     *      Uses linear scan which is O(n) — acceptable for lottery participants.
     */
    function _selectWinner(uint256 randomWord) internal view returns (address) {
        uint256 len = _snapshotAddresses.length;
        if (len == 0) return address(0);
        if (len == 1) return _snapshotAddresses[0];

        // Compute total snapshot weight
        uint256 total = 0;
        for (uint256 i = 0; i < len; i++) {
            total += _snapshotWeights[i];
        }
        if (total == 0) return address(0);

        uint256 target = randomWord % total;
        uint256 cumulative = 0;
        for (uint256 i = 0; i < len; i++) {
            cumulative += _snapshotWeights[i];
            if (target < cumulative) {
                return _snapshotAddresses[i];
            }
        }

        // Fallback (should never reach here)
        return _snapshotAddresses[len - 1];
    }

    /**
     * @dev Withdraw the yield portion from AaveStrategy.
     *      yield = strategy.getTotalValue() - totalDeposited (principal)
     *      Returns the actual amount of tokens received.
     */
    function _harvestPrize(Round storage /*r*/) internal returns (uint256 prize) {
        uint256 currentValue = aaveStrategy.getTotalValue();
        if (currentValue <= totalDeposited) return 0;

        prize = currentValue - totalDeposited;

        // Compute strategy shares corresponding to `prize` tokens
        uint256 sharesToBurn = _sharesForAmount(prize);
        if (sharesToBurn == 0) return 0;

        // AaveStrategy sends tokens to msg.sender (= this contract)
        prize = aaveStrategy.withdraw(sharesToBurn);
        // (prize is now the actual tokens sitting in this contract)
    }

    /**
     * @dev Remove a participant from the array using swap-and-pop for O(1) removal.
     */
    function _removeParticipant(address participant) internal {
        uint256 index = _participantIndex[participant];
        uint256 lastIndex = _participants.length - 1;

        if (index != lastIndex) {
            address lastParticipant = _participants[lastIndex];
            _participants[index] = lastParticipant;
            _participantIndex[lastParticipant] = index;
        }

        _participants.pop();
        delete _participantIndex[participant];
        _isParticipant[participant] = false;
    }

    /**
     * @dev Converts a token amount to the number of AaveStrategy shares
     *      that the lottery holds, proportional to the token amount.
     *
     *      Formula: sharesToBurn = amount × strategyShares / strategyTotalValue
     *
     *      This correctly accounts for yield:
     *      e.g., if the strategy now holds 1050 (was 1000), burning 100/1050
     *      of shares returns exactly 100 tokens.
     */
    function _sharesForAmount(uint256 amount) internal view returns (uint256) {
        uint256 totalValue = aaveStrategy.getTotalValue();
        if (totalValue == 0) return amount;

        // Lottery's total shares in the strategy (public field → getter function)
        uint256 lotteryShares = aaveStrategy.shares(address(this));
        if (lotteryShares == 0) return 0;

        return (amount * lotteryShares) / totalValue;
    }
}
