// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IContest.sol";
import "./interfaces/IContestFactory.sol";
import "./interfaces/IYieldVault.sol";
import "./interfaces/IIdentityRegistry.sol";
import "./interfaces/IRandomnessManager.sol";
import "./interfaces/IDataRegistry.sol";

/**
 * @title Contest
 * @notice Core contest contract with deposit, commit-reveal voting, and yield distribution
 * @dev Implements full contest lifecycle: deposit -> commit -> reveal -> finalize
 * @dev Uses ReentrancyGuard for protection against reentrancy attacks
 * @dev Uses SafeERC20 for safe token transfers
 */
contract Contest is IContest, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    // Immutable references
    IYieldVault public immutable yieldVault;
    IIdentityRegistry public immutable identityRegistry;
    IRandomnessManager public immutable randomnessManager;
    IDataRegistry public immutable dataRegistry;
    address public immutable factory;

    // Contest configuration
    ContestConfig public config;
    bytes32 public contestId;
    address public creator;

    // State tracking
    ContestState public state;

    // Participant tracking
    address[] public participants;
    mapping(address => bool) public deposited;
    mapping(address => uint256) public depositAmounts;

    // Voting
    mapping(address => bytes32) public commitments;
    mapping(address => bool) public committed;
    mapping(address => bool) public revealed;
    mapping(address => bytes) public revealedVotes;

    // Results
    uint256 public totalDeposited;
    uint256 public vaultShares;
    uint256 public randomWord;
    address[] public winners;
    mapping(address => uint256) public winnerAmounts;
    uint256 public yieldGenerated;
    uint256 public protocolFee;

    // Principal withdrawal tracking
    mapping(address => bool) public principalWithdrawn;

    // Maximum participants to bound loop gas cost
    uint256 public constant MAX_PARTICIPANTS = 500;

    // Pending treasury fee (pull-over-push to handle non-standard tokens)
    uint256 public pendingTreasuryFee;

    /// @notice Treasury address stored at contest creation to prevent mid-contest recipient changes
    address public immutable contestTreasury;

    // Timestamp when the contest was finalized (used for dust sweep delay)
    uint256 public finalizedAt;

    // Dust sweep grace period: 30 days after finalization
    uint256 public constant SWEEP_DELAY = 30 days;

    error NotFactory();
    error NotRandomnessManager();
    error InvalidState();
    error DepositWindowNotOpen();
    error DepositWindowClosed();
    error InsufficientTier();
    error AlreadyDeposited();
    error NotDeposited();
    error CommitWindowNotOpen();
    error AlreadyCommitted();
    error NotCommitted();
    error RevealWindowNotOpen();
    error RevealWindowClosed();
    error AlreadyRevealed();
    error InvalidReveal();
    error NotFinalized();
    error AlreadyWithdrawn();
    error TransferFailed();
    error NoParticipants();

    event TreasuryFeeClaimed(uint256 amount, address recipient);
    event ProtocolFeeSkipped(uint256 amount, address recipient, string reason);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyRandomnessManager() {
        if (msg.sender != address(randomnessManager)) revert NotRandomnessManager();
        _;
    }

    modifier inState(ContestState expectedState) {
        _updateState();
        if (state != expectedState) revert InvalidState();
        _;
    }

    constructor(
        bytes32 _contestId,
        ContestConfig memory _config,
        address _creator,
        address _yieldVault,
        address _identityRegistry,
        address _randomnessManager,
        address _dataRegistry,
        address _treasury
    ) {
        require(_creator != address(0), "Contest: zero creator");
        require(_yieldVault != address(0), "Contest: zero yieldVault");
        require(_identityRegistry != address(0), "Contest: zero identityRegistry");
        require(_randomnessManager != address(0), "Contest: zero randomnessManager");
        require(_dataRegistry != address(0), "Contest: zero dataRegistry");
        require(_treasury != address(0), "Contest: zero treasury");

        contestId = _contestId;
        config = _config;
        creator = _creator;
        factory = msg.sender;
        contestTreasury = _treasury;

        yieldVault = IYieldVault(_yieldVault);
        identityRegistry = IIdentityRegistry(_identityRegistry);
        randomnessManager = IRandomnessManager(_randomnessManager);
        dataRegistry = IDataRegistry(_dataRegistry);

        state = ContestState.CREATED;
    }

    /**
     * @notice Internal state transition based on timestamps
     */
    function _updateState() internal {
        if (state == ContestState.CANCELLED || state == ContestState.FINALIZED) {
            return;
        }

        if (block.timestamp >= config.depositStart && state == ContestState.CREATED) {
            state = ContestState.DEPOSIT_OPEN;
        }

        if (block.timestamp >= config.depositEnd && state == ContestState.DEPOSIT_OPEN) {
            state = ContestState.DEPOSIT_CLOSED;
        }

        if (block.timestamp >= config.lockEnd && state == ContestState.LOCKED) {
            state = ContestState.REVEAL_OPEN;
        }

        if (block.timestamp >= config.revealEnd && state == ContestState.REVEAL_OPEN) {
            state = ContestState.RESOLVING;
        }
    }

    /**
     * @notice Deposit to join the contest
     * @dev Protected against reentrancy, uses SafeERC20 for token transfers
     */
    function deposit() external override nonReentrant whenNotPaused {
        _updateState();

        if (state != ContestState.DEPOSIT_OPEN) {
            if (block.timestamp < config.depositStart) revert DepositWindowNotOpen();
            revert DepositWindowClosed();
        }

        if (deposited[msg.sender]) revert AlreadyDeposited();
        if (participants.length >= MAX_PARTICIPANTS) revert InvalidState();

        // Check identity tier
        if (config.tierRequired > 0) {
            if (!identityRegistry.meetsRequirement(msg.sender, config.tierRequired)) {
                revert InsufficientTier();
            }
        }

        // Transfer deposit using SafeERC20
        IERC20(config.depositToken).safeTransferFrom(
            msg.sender,
            address(this),
            config.depositAmount
        );

        deposited[msg.sender] = true;
        depositAmounts[msg.sender] = config.depositAmount;
        participants.push(msg.sender);
        totalDeposited += config.depositAmount;

        emit Deposited(msg.sender, config.depositAmount);
    }

    /**
     * @notice Commit a vote hash
     * @param commitHash keccak256(abi.encodePacked(voteData, salt))
     */
    function commitVote(bytes32 commitHash) external override nonReentrant whenNotPaused {
        _updateState();

        // Commit window is during deposit + locked period
        if (state != ContestState.DEPOSIT_OPEN &&
            state != ContestState.DEPOSIT_CLOSED &&
            state != ContestState.LOCKED) {
            revert CommitWindowNotOpen();
        }

        if (!deposited[msg.sender]) revert NotDeposited();
        if (committed[msg.sender]) revert AlreadyCommitted();

        commitments[msg.sender] = commitHash;
        committed[msg.sender] = true;

        emit VoteCommitted(msg.sender, commitHash);
    }

    /**
     * @notice Reveal a previously committed vote
     * @param voteData The original vote data
     * @param salt The salt used in commitment
     */
    function revealVote(bytes calldata voteData, bytes32 salt) external override nonReentrant whenNotPaused {
        _updateState();

        if (state != ContestState.REVEAL_OPEN) revert RevealWindowNotOpen();
        if (!committed[msg.sender]) revert NotCommitted();
        if (revealed[msg.sender]) revert AlreadyRevealed();

        // Verify commitment
        bytes32 expectedHash = keccak256(abi.encodePacked(voteData, salt));
        if (commitments[msg.sender] != expectedHash) revert InvalidReveal();

        revealed[msg.sender] = true;
        revealedVotes[msg.sender] = voteData;

        emit VoteRevealed(msg.sender, voteData);
    }

    /**
     * @notice Lock funds in yield vault after deposit window
     * @dev Protected against reentrancy, uses SafeERC20 for approvals
     */
    function lockFunds() external override nonReentrant {
        _updateState();

        if (state != ContestState.DEPOSIT_CLOSED) revert InvalidState();
        if (participants.length == 0) revert NoParticipants();

        // Approve vault to spend tokens using SafeERC20
        IERC20(config.depositToken).forceApprove(address(yieldVault), totalDeposited);

        // Deposit into yield vault
        vaultShares = yieldVault.deposit(
            config.depositToken,
            totalDeposited,
            config.yieldStrategyId
        );

        state = ContestState.LOCKED;

        emit FundsLocked(totalDeposited, vaultShares);
    }

    /**
     * @notice Request randomness for winner selection
     */
    function requestRandomness() external override {
        _updateState();

        if (state != ContestState.RESOLVING) revert InvalidState();

        uint256 requestId = randomnessManager.requestRandomness(contestId);

        emit RandomnessRequested(requestId);
    }

    /**
     * @notice Callback from RandomnessManager with random word
     * @param _randomWord The random value
     */
    function fulfillRandomness(uint256 _randomWord) external override onlyRandomnessManager {
        require(_randomWord != 0, "Zero randomness");
        randomWord = _randomWord;
    }

    /**
     * @notice Finalize contest: withdraw from vault, distribute yield, return principal
     * @dev Protected against reentrancy
     */
    function finalize() external override nonReentrant {
        _updateState();

        if (state != ContestState.RESOLVING) revert InvalidState();
        if (randomWord == 0) revert InvalidState(); // Need randomness first

        // Withdraw from vault with slippage protection: must receive at least the principal
        uint256 withdrawn = yieldVault.withdraw(
            config.depositToken,
            vaultShares,
            config.yieldStrategyId,
            address(this)
        );
        require(withdrawn >= totalDeposited, "Contest: withdrawal below principal (slippage)");

        // Calculate yield
        yieldGenerated = withdrawn - totalDeposited;

        // Get protocol fee from factory (in basis points, e.g., 1000 = 10%)
        uint256 feeRate = IContestFactory(factory).getProtocolFee();
        protocolFee = (yieldGenerated * feeRate) / 10000;
        uint256 prizePool = yieldGenerated - protocolFee;

        // Accrue protocol fee for pull-based claim (avoids blacklistable-token DoS)
        if (protocolFee > 0) {
            pendingTreasuryFee = protocolFee;
        }

        // Select winners based on prize model and votes
        _selectWinners(prizePool);

        state = ContestState.FINALIZED;
        finalizedAt = block.timestamp;

        emit Finalized(yieldGenerated, protocolFee);

        // Anchor results to data registry (wrapped in try/catch so a
        // failing registry cannot block finalization and lock funds)
        uint256[] memory amounts = new uint256[](winners.length);
        for (uint256 i = 0; i < winners.length; i++) {
            amounts[i] = winnerAmounts[winners[i]];
        }
        bytes32 resultsRoot = keccak256(abi.encode(winners, amounts, randomWord));
        try dataRegistry.anchorResults(contestId, resultsRoot, "") {} catch {
            // Data registry failure is non-critical; finalization proceeds
        }
    }

    /**
     * @notice Select winners based on prize model and revealed votes
     * @dev Winners are participants who voted for the winning option
     * @dev Gas consideration: This function iterates over all participants multiple times.
     *      The MAX_PARTICIPANTS cap (500) ensures these loops stay within block gas limits.
     *      At 500 participants with ~3 loops, worst case is ~1500 iterations which is safe
     *      for current L1 and L2 block gas limits.
     */
    function _selectWinners(uint256 prizePool) internal {
        uint256 participantCount = participants.length;
        if (participantCount == 0) return;

        // First, tally votes to determine winning option
        // Vote data format: bytes32 optionId (first 32 bytes of revealedVotes)
        mapping(bytes32 => uint256) storage optionVotes = _getOptionVotes();
        bytes32 winningOption;
        uint256 highestVotes = 0;

        // Clear previous vote counts before tallying (prevents stale data from prior runs)
        for (uint256 i = 0; i < participantCount; i++) {
            address participant = participants[i];
            if (revealedVotes[participant].length >= 32) {
                bytes32 votedOption = bytes32(revealedVotes[participant]);
                optionVotes[votedOption] = 0;
            }
        }

        // Count votes from revealed votes
        for (uint256 i = 0; i < participantCount; i++) {
            address participant = participants[i];
            if (revealed[participant] && revealedVotes[participant].length >= 32) {
                bytes memory voteData = revealedVotes[participant];
                bytes32 votedOption = bytes32(voteData);
                optionVotes[votedOption]++;

                // Track winning option (use hash-based tiebreaker to avoid modulo-by-1 bias)
                if (optionVotes[votedOption] > highestVotes ||
                    (optionVotes[votedOption] == highestVotes && uint256(keccak256(abi.encode(votedOption, randomWord))) > uint256(keccak256(abi.encode(winningOption, randomWord))))) {
                    highestVotes = optionVotes[votedOption];
                    winningOption = votedOption;
                }
            }
        }

        // Build list of correct voters (those who voted for winning option)
        address[] memory correctVoters = new address[](participantCount);
        uint256 correctCount = 0;

        for (uint256 i = 0; i < participantCount; i++) {
            address participant = participants[i];
            if (revealed[participant] && revealedVotes[participant].length >= 32) {
                bytes memory voteData = revealedVotes[participant];
                bytes32 votedOption = bytes32(voteData);
                if (votedOption == winningOption) {
                    correctVoters[correctCount] = participant;
                    correctCount++;
                }
            }
        }

        // If no one voted correctly, fall back to all revealers
        if (correctCount == 0) {
            for (uint256 i = 0; i < participantCount; i++) {
                if (revealed[participants[i]]) {
                    correctVoters[correctCount] = participants[i];
                    correctCount++;
                }
            }
        }

        // If still no one, fall back to all participants (shouldn't happen normally)
        if (correctCount == 0) {
            correctCount = participantCount;
            for (uint256 i = 0; i < participantCount; i++) {
                correctVoters[i] = participants[i];
            }
        }

        // Now distribute prizes based on prize model
        if (config.prizeModel == PrizeModel.SINGLE_WINNER) {
            // Single winner from correct voters (use randomness to select)
            // Note: modulo bias is negligible for practical participant counts.
            // With a 256-bit random word and correctCount <= MAX_PARTICIPANTS (500),
            // the bias is at most ~2^-248, which is cryptographically insignificant.
            uint256 winnerIndex = randomWord % correctCount;
            address winner = correctVoters[winnerIndex];
            winners.push(winner);
            winnerAmounts[winner] = prizePool;
        } else if (config.prizeModel == PrizeModel.TOP_N) {
            // Top N from correct voters
            uint256 n = config.prizeModelParam;
            if (n > correctCount) n = correctCount;
            uint256 prizePerWinner = n > 0 ? prizePool / n : 0;

            // Use randomness to select N unique winners from correct voters
            uint256 tempRandom = randomWord;
            for (uint256 i = 0; i < n; i++) {
                uint256 remaining = correctCount - i;
                uint256 index = tempRandom % remaining;
                address winner = correctVoters[index];
                winners.push(winner);
                winnerAmounts[winner] = prizePerWinner;

                // Swap selected with last unselected
                correctVoters[index] = correctVoters[remaining - 1];
                tempRandom = uint256(keccak256(abi.encode(tempRandom, i)));
            }
        } else if (config.prizeModel == PrizeModel.PROPORTIONAL) {
            // All correct voters share equally
            uint256 prizePerWinner = correctCount > 0 ? prizePool / correctCount : 0;
            for (uint256 i = 0; i < correctCount; i++) {
                winners.push(correctVoters[i]);
                winnerAmounts[correctVoters[i]] = prizePerWinner;
            }
        }

        emit WinnersSelected(winners, _getWinnerAmountsArray());
    }

    // Persistent storage for vote counting (populated during finalization)
    mapping(bytes32 => uint256) private _optionVoteCounts;

    function _getOptionVotes() internal view returns (mapping(bytes32 => uint256) storage) {
        return _optionVoteCounts;
    }

    function _getWinnerAmountsArray() internal view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](winners.length);
        for (uint256 i = 0; i < winners.length; i++) {
            amounts[i] = winnerAmounts[winners[i]];
        }
        return amounts;
    }

    /**
     * @notice Withdraw principal after finalization
     * @dev Protected against reentrancy, uses SafeERC20 for token transfers
     */
    function withdrawPrincipal() external override nonReentrant {
        if (state != ContestState.FINALIZED && state != ContestState.CANCELLED) {
            revert NotFinalized();
        }
        if (!deposited[msg.sender]) revert NotDeposited();
        if (principalWithdrawn[msg.sender]) revert AlreadyWithdrawn();

        uint256 amount = depositAmounts[msg.sender];
        uint256 prize = winnerAmounts[msg.sender];
        uint256 total = amount + prize;

        // Update state before external call (checks-effects-interactions pattern)
        principalWithdrawn[msg.sender] = true;

        // Transfer using SafeERC20
        IERC20(config.depositToken).safeTransfer(msg.sender, total);

        emit PrincipalReturned(msg.sender, total, amount, prize);
    }

    /**
     * @notice Cancel contest (factory only, before finalization)
     * @dev Protected against reentrancy
     */
    function cancel(string calldata reason) external override onlyFactory nonReentrant {
        if (state == ContestState.FINALIZED) revert InvalidState();

        // If funds are locked, withdraw from vault first
        if (state == ContestState.LOCKED ||
            state == ContestState.REVEAL_OPEN ||
            state == ContestState.RESOLVING) {
            yieldVault.withdraw(
                config.depositToken,
                vaultShares,
                config.yieldStrategyId,
                address(this)
            );
        }

        state = ContestState.CANCELLED;
        emit Cancelled(reason);
    }

    /**
     * @notice Claim accumulated protocol fee (treasury pull pattern).
     *         Anyone may call; tokens are sent to the registered treasury address.
     */
    function claimTreasuryFee() external nonReentrant {
        uint256 fee = pendingTreasuryFee;
        require(fee > 0, "Contest: no fee pending");
        // Use per-contest treasury stored at creation time (not factory's current treasury)
        require(contestTreasury != address(0), "Contest: no treasury");
        pendingTreasuryFee = 0;
        IERC20(config.depositToken).safeTransfer(contestTreasury, fee);
        emit TreasuryFeeClaimed(fee, contestTreasury);
    }

    /**
     * @notice Pause the contest (factory or creator only)
     */
    function pause() external {
        require(msg.sender == factory || msg.sender == creator, "Contest: not authorized");
        _pause();
    }

    /**
     * @notice Unpause the contest (factory or creator only)
     */
    function unpause() external {
        require(msg.sender == factory || msg.sender == creator, "Contest: not authorized");
        _unpause();
    }

    /**
     * @notice Sweep any remaining token dust to the treasury after all withdrawals.
     *         Callable by the factory or factory owner after SWEEP_DELAY has elapsed
     *         since finalization. Prevents prize dust from being permanently stuck.
     */
    function sweepDust() external nonReentrant {
        require(state == ContestState.FINALIZED, "Contest: not finalized");
        require(block.timestamp >= finalizedAt + SWEEP_DELAY, "Contest: sweep too early");
        require(
            msg.sender == factory || msg.sender == IContestFactory(factory).getTreasury(),
            "Contest: not authorized"
        );

        uint256 balance = IERC20(config.depositToken).balanceOf(address(this));
        require(balance > 0, "Contest: no dust");

        // Calculate outstanding obligations (unclaimed principal + prizes + pending fee)
        uint256 obligations = pendingTreasuryFee;
        for (uint256 i = 0; i < participants.length; i++) {
            address p = participants[i];
            if (!principalWithdrawn[p]) {
                obligations += depositAmounts[p] + winnerAmounts[p];
            }
        }

        require(balance > obligations, "Contest: no dust after obligations");
        uint256 dust = balance - obligations;

        // Use per-contest treasury stored at creation time
        require(contestTreasury != address(0), "Contest: no treasury");

        IERC20(config.depositToken).safeTransfer(contestTreasury, dust);
    }

    // View functions

    function getConfig() external view override returns (ContestConfig memory) {
        return config;
    }

    function getState() external view override returns (ContestState) {
        // Return computed state
        ContestState computedState = state;

        if (computedState == ContestState.CANCELLED || computedState == ContestState.FINALIZED) {
            return computedState;
        }

        if (block.timestamp >= config.depositStart && computedState == ContestState.CREATED) {
            computedState = ContestState.DEPOSIT_OPEN;
        }

        if (block.timestamp >= config.depositEnd && computedState == ContestState.DEPOSIT_OPEN) {
            computedState = ContestState.DEPOSIT_CLOSED;
        }

        if (block.timestamp >= config.lockEnd && computedState == ContestState.LOCKED) {
            computedState = ContestState.REVEAL_OPEN;
        }

        if (block.timestamp >= config.revealEnd && computedState == ContestState.REVEAL_OPEN) {
            computedState = ContestState.RESOLVING;
        }

        return computedState;
    }

    function getParticipantCount() external view override returns (uint256) {
        return participants.length;
    }

    function hasDeposited(address participant) external view override returns (bool) {
        return deposited[participant];
    }

    function hasCommitted(address participant) external view override returns (bool) {
        return committed[participant];
    }

    function hasRevealed(address participant) external view override returns (bool) {
        return revealed[participant];
    }

    function getWinners() external view override returns (address[] memory) {
        return winners;
    }

    function getParticipants() external view returns (address[] memory) {
        return participants;
    }

    function getCommitCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            if (committed[participants[i]]) count++;
        }
        return count;
    }

    function getRevealCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            if (revealed[participants[i]]) count++;
        }
        return count;
    }

    /**
     * @notice Get commit hash for a participant (for frontend hooks)
     */
    function getCommitHash(address voter) external view returns (bytes32) {
        return commitments[voter];
    }

    /**
     * @notice Get contest info in a single call (for frontend hooks)
     */
    function getContestInfo() external view returns (
        address depositToken,
        uint256 depositAmount,
        uint256 depositStart,
        uint256 depositEnd,
        uint256 lockEnd,
        uint256 revealEnd,
        uint256 participantCount,
        uint256 _totalDeposited,
        ContestState currentState
    ) {
        return (
            config.depositToken,
            config.depositAmount,
            config.depositStart,
            config.depositEnd,
            config.lockEnd,
            config.revealEnd,
            participants.length,
            totalDeposited,
            this.getState()
        );
    }

    /**
     * @notice Get participant info in a single call (for frontend hooks)
     */
    function getParticipantInfo(address participant) external view returns (
        bool _hasDeposited,
        bool _hasCommitted,
        bool _hasRevealed,
        uint256 depositedAmount,
        uint256 winnerAmount,
        bool _principalWithdrawn
    ) {
        return (
            deposited[participant],
            committed[participant],
            revealed[participant],
            depositAmounts[participant],
            winnerAmounts[participant],
            principalWithdrawn[participant]
        );
    }

    /**
     * @notice Claim reward (alias for withdrawPrincipal for frontend compatibility)
     */
    function claimReward() external nonReentrant whenNotPaused {
        if (state != ContestState.FINALIZED && state != ContestState.CANCELLED) {
            revert NotFinalized();
        }
        if (!deposited[msg.sender]) revert NotDeposited();
        if (principalWithdrawn[msg.sender]) revert AlreadyWithdrawn();

        uint256 amount = depositAmounts[msg.sender];
        uint256 prize = winnerAmounts[msg.sender];
        uint256 total = amount + prize;

        principalWithdrawn[msg.sender] = true;

        IERC20(config.depositToken).safeTransfer(msg.sender, total);

        emit PrincipalReturned(msg.sender, total, amount, prize);
    }
}
