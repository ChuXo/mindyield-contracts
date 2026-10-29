// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @dev Minimal interface for snapshot-based voting weight (ERC20Votes / Governor)
interface IVotes {
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
}

// AutoYieldVault integration removed (audit fix 2026-04-26 + W2 cleanup
// 2026-04-28). castVote/claimReward no longer route through any vault;
// principal is held in this contract and returned principal-only on claim.
// The previous shared-`depositBlock` flash-loan-guard DoS is closed.

/**
 * @title GovernanceContest
 * @notice DAO governance voting with yield-generating deposits
 * @dev Implements weighted voting with delegation support
 */
contract GovernanceContest is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // ============ Enums ============

    enum ProposalState {
        PENDING,
        ACTIVE,
        CANCELED,
        DEFEATED,
        SUCCEEDED,
        QUEUED,
        EXPIRED,
        EXECUTED
    }

    enum VoteType {
        AGAINST,
        FOR,
        ABSTAIN
    }

    // ============ Structs ============

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        string ipfsHash;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 quorumRequired;
        bool executed;
        bool canceled;
        uint256 totalDeposits;
        uint256 totalSupplySnapshot;  // Snapshot of governance token totalSupply at creation
        mapping(address => Receipt) receipts;
    }

    struct Receipt {
        bool hasVoted;
        VoteType voteType;
        uint256 weight;
        uint256 depositAmount;
        uint256 vaultShares;    // shares minted by AutoYieldVault for this voter's deposit
        uint256 rewardClaimed;
    }

    struct ProposalView {
        uint256 id;
        address proposer;
        string title;
        string description;
        string ipfsHash;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 quorumRequired;
        bool executed;
        bool canceled;
        uint256 totalDeposits;
        ProposalState state;
    }

    struct GovernanceConfig {
        uint256 votingDelay;        // Time before voting starts
        uint256 votingPeriod;       // Duration of voting
        uint256 proposalThreshold;   // Min tokens to create proposal
        uint256 quorumPercentage;   // Required participation (basis points)
        uint256 minDeposit;         // Minimum deposit to vote
        bool weightedVoting;         // Token-weighted vs 1-person-1-vote
    }

    // ============ Constants ============

    uint256 public constant MAX_DELEGATORS = 500;

    // ============ State Variables ============

    IERC20 public depositToken;
    IERC20 public governanceToken;  // For weighted voting

    GovernanceConfig public config;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    uint256[] public proposalIds;

    // Delegation
    mapping(address => address) public delegates;
    mapping(address => uint256) public delegatedWeight;        // legacy — kept for storage compat
    mapping(address => uint256) public delegationAmount;       // legacy — kept for storage compat
    mapping(address => address[]) public delegators;           // delegatee => list of delegators

    // Rewards
    uint256 public totalYieldGenerated;
    uint256 public voterRewardPool;

    // ============ Events ============

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 startTime,
        uint256 endTime
    );
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        VoteType voteType,
        uint256 weight,
        uint256 depositAmount
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event RewardClaimed(address indexed voter, uint256 indexed proposalId, uint256 amount);

    // ============ Constructor ============

    /// @param _yieldVault DEPRECATED — accepted for backward compat with existing
    ///        deploy scripts but unused. Pass address(0). Will be removed in a
    ///        future major version.
    constructor(
        address _depositToken,
        address _governanceToken,
        address _yieldVault,
        GovernanceConfig memory _config
    ) Ownable() {
        depositToken = IERC20(_depositToken);
        governanceToken = IERC20(_governanceToken);
        config = _config;
        _yieldVault; // silence unused-var warning
    }

    // ============ Proposal Functions ============

    /**
     * @notice Create a new governance proposal
     */
    function createProposal(
        string calldata title,
        string calldata description,
        string calldata ipfsHash
    ) external returns (uint256 proposalId) {
        // Use getPastVotes to prevent flash loan attacks on proposal creation
        require(
            IVotes(address(governanceToken)).getPastVotes(msg.sender, block.number - 1) >= config.proposalThreshold,
            "GovernanceContest: below proposal threshold"
        );

        proposalId = ++proposalCount;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.ipfsHash = ipfsHash;
        proposal.startTime = block.timestamp + config.votingDelay;
        proposal.endTime = proposal.startTime + config.votingPeriod;
        proposal.totalSupplySnapshot = governanceToken.totalSupply();
        proposal.quorumRequired = _calculateQuorumFromSnapshot(proposal.totalSupplySnapshot);

        proposalIds.push(proposalId);

        emit ProposalCreated(proposalId, msg.sender, title, proposal.startTime, proposal.endTime);

        return proposalId;
    }

    /**
     * @notice Cast vote with deposit
     */
    function castVote(
        uint256 proposalId,
        VoteType voteType,
        uint256 depositAmount
    ) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[msg.sender];

        require(state(proposalId) == ProposalState.ACTIVE, "GovernanceContest: voting not active");
        require(!receipt.hasVoted, "GovernanceContest: already voted");
        require(delegates[msg.sender] == address(0), "GovernanceContest: must undelegate first");
        require(depositAmount >= config.minDeposit, "GovernanceContest: deposit too low");

        // Transfer deposit
        depositToken.safeTransferFrom(msg.sender, address(this), depositAmount);

        // Calculate voting weight — use snapshot to prevent flash-loan manipulation.
        // Governance token MUST implement IVotes (ERC20Votes). No balanceOf fallback
        // is provided because live balance is vulnerable to flash-loan manipulation.
        uint256 weight;
        if (config.weightedVoting) {
            uint256 snapshotBlock = block.number - 1;
            uint256 snapshotVotes = IVotes(address(governanceToken)).getPastVotes(msg.sender, snapshotBlock);
            weight = snapshotVotes + _computeDelegatedWeight(msg.sender, snapshotBlock);
        } else {
            weight = 1; // 1 person = 1 vote
        }

        require(weight > 0, "GovernanceContest: no voting power");

        // Record vote
        receipt.hasVoted = true;
        receipt.voteType = voteType;
        receipt.weight = weight;
        receipt.depositAmount = depositAmount;

        if (voteType == VoteType.FOR) {
            proposal.forVotes += weight;
        } else if (voteType == VoteType.AGAINST) {
            proposal.againstVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }

        proposal.totalDeposits += depositAmount;

        emit VoteCast(msg.sender, proposalId, voteType, weight, depositAmount);
    }

    /**
     * @notice Execute a succeeded proposal
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        require(state(proposalId) == ProposalState.SUCCEEDED, "GovernanceContest: not succeeded");

        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal (proposer or owner only)
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || msg.sender == owner(),
            "GovernanceContest: not authorized"
        );
        require(!proposal.executed, "GovernanceContest: already executed");

        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    // ============ Delegation ============

    /**
     * @notice Delegate voting power to another address
     */
    function delegate(address delegatee) external {
        address currentDelegate = delegates[msg.sender];

        // Remove from previous delegatee's delegator list
        if (currentDelegate != address(0)) {
            _removeDelegator(currentDelegate, msg.sender);
        }

        delegates[msg.sender] = delegatee;

        // Add to new delegatee's delegator list (weight computed at vote time via getPastVotes)
        if (delegatee != address(0)) {
            require(delegators[delegatee].length < MAX_DELEGATORS, "GovernanceContest: max delegators reached");
            delegators[delegatee].push(msg.sender);
        }

        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
    }

    // ============ Rewards ============

    /**
     * @notice Claim voting rewards after proposal ends
     */
    function claimReward(uint256 proposalId) external nonReentrant {
        ProposalState currentState = state(proposalId);
        require(currentState != ProposalState.ACTIVE, "GovernanceContest: still active");

        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[msg.sender];

        require(receipt.hasVoted, "GovernanceContest: did not vote");
        require(receipt.rewardClaimed == 0, "GovernanceContest: already claimed");

        // Deposits are held in-contract; return principal directly.
        // (Vault integration was removed to eliminate the shared-depositBlock DoS
        // where any concurrent castVote() could permanently block all claimReward()
        // calls by resetting the vault's per-contract flash-loan guard.)
        uint256 total = receipt.depositAmount;

        // Canceled proposals: return only principal, no yield distribution
        if (currentState == ProposalState.CANCELED) {
            total = total > receipt.depositAmount ? receipt.depositAmount : total;
        }

        uint256 reward = total > receipt.depositAmount ? total - receipt.depositAmount : 0;
        // Store total (not just reward) so the zero-reward case is still marked claimed
        receipt.rewardClaimed = total;

        // Verify contract has sufficient balance before transfer
        require(depositToken.balanceOf(address(this)) >= total, "GovernanceContest: insufficient balance");
        depositToken.safeTransfer(msg.sender, total);

        emit RewardClaimed(msg.sender, proposalId, reward);
    }

    // ============ View Functions ============

    /**
     * @notice Get proposal state
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.canceled) {
            return ProposalState.CANCELED;
        }

        if (block.timestamp < proposal.startTime) {
            return ProposalState.PENDING;
        }

        if (block.timestamp <= proposal.endTime) {
            return ProposalState.ACTIVE;
        }

        if (proposal.executed) {
            return ProposalState.EXECUTED;
        }

        // Check if quorum reached and passed
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        if (totalVotes < proposal.quorumRequired) {
            return ProposalState.DEFEATED;
        }

        if (proposal.forVotes > proposal.againstVotes) {
            return ProposalState.SUCCEEDED;
        }

        return ProposalState.DEFEATED;
    }

    /**
     * @notice Get proposal details
     */
    function getProposal(uint256 proposalId) external view returns (ProposalView memory) {
        Proposal storage p = proposals[proposalId];
        return ProposalView({
            id: p.id,
            proposer: p.proposer,
            title: p.title,
            description: p.description,
            ipfsHash: p.ipfsHash,
            startTime: p.startTime,
            endTime: p.endTime,
            forVotes: p.forVotes,
            againstVotes: p.againstVotes,
            abstainVotes: p.abstainVotes,
            quorumRequired: p.quorumRequired,
            executed: p.executed,
            canceled: p.canceled,
            totalDeposits: p.totalDeposits,
            state: state(proposalId)
        });
    }

    /**
     * @notice Get voter receipt
     */
    function getReceipt(uint256 proposalId, address voter) external view returns (
        bool hasVoted,
        VoteType voteType,
        uint256 weight,
        uint256 depositAmount,
        uint256 rewardClaimed
    ) {
        Receipt storage receipt = proposals[proposalId].receipts[voter];
        return (
            receipt.hasVoted,
            receipt.voteType,
            receipt.weight,
            receipt.depositAmount,
            receipt.rewardClaimed
        );
    }

    /**
     * @notice Get all proposal IDs
     */
    function getProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }

    /**
     * @notice Get active proposals
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            if (state(proposalIds[i]) == ProposalState.ACTIVE) {
                count++;
            }
        }

        uint256[] memory active = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            if (state(proposalIds[i]) == ProposalState.ACTIVE) {
                active[index++] = proposalIds[i];
            }
        }

        return active;
    }

    // ============ Admin Functions ============

    function updateConfig(GovernanceConfig calldata newConfig) external onlyOwner {
        config = newConfig;
    }

    // setYieldVault removed (W2 cleanup 2026-04-28). The vault path no longer
    // exists; deposits are held in-contract and returned principal-only.

    // ============ Internal Functions ============

    function _calculateQuorum() internal view returns (uint256) {
        return (governanceToken.totalSupply() * config.quorumPercentage) / 10000;
    }

    function _calculateQuorumFromSnapshot(uint256 snapshotTotalSupply) internal view returns (uint256) {
        return (snapshotTotalSupply * config.quorumPercentage) / 10000;
    }

    /// @notice Preview the reward a voter would receive when they claim (read-only, for UI)
    /// @dev Always returns 0 since the AutoYieldVault integration was removed.
    ///      Kept as a function so the public `previewReward` view continues to
    ///      compile without forcing every UI caller to drop the call site.
    function _calculateReward(uint256, address) internal pure returns (uint256) {
        return 0;
    }

    /// @notice External view: preview claimable reward for a voter
    function previewReward(uint256 proposalId, address voter) external view returns (uint256) {
        return _calculateReward(proposalId, voter);
    }

    /**
     * @dev Compute delegated weight at a specific snapshot block using getPastVotes.
     *      This ensures delegation weight reflects actual token balances at vote time,
     *      not at delegation time.
     */
    function _computeDelegatedWeight(address delegatee, uint256 snapshotBlock) internal view returns (uint256) {
        address[] storage dels = delegators[delegatee];
        uint256 total = 0;
        for (uint256 i = 0; i < dels.length; i++) {
            total += IVotes(address(governanceToken)).getPastVotes(dels[i], snapshotBlock);
        }
        return total;
    }

    /**
     * @dev Remove a delegator from a delegatee's list (swap-and-pop).
     */
    function _removeDelegator(address delegatee, address delegator) internal {
        address[] storage dels = delegators[delegatee];
        for (uint256 i = 0; i < dels.length; i++) {
            if (dels[i] == delegator) {
                dels[i] = dels[dels.length - 1];
                dels.pop();
                return;
            }
        }
    }
}
