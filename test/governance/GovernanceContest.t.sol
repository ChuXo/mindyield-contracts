// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/governance/GovernanceContest.sol";
import "../../src/mocks/MockERC20.sol";

/**
 * @title MockERC20Votes
 * @notice MockERC20 extended with IVotes.getPastVotes for governance tests.
 *         Returns the current balanceOf as a simple snapshot stand-in.
 */
contract MockERC20Votes is MockERC20 {
    constructor(string memory _name, string memory _symbol, uint8 _decimals)
        MockERC20(_name, _symbol, _decimals)
    {}

    function getPastVotes(address account, uint256 /* blockNumber */) external view returns (uint256) {
        return balanceOf[account];
    }
}

/**
 * @title GovernanceContestTest
 * @notice Comprehensive tests for the GovernanceContest contract
 * Tests proposal lifecycle, voting, delegation, quorum, and rewards
 */
contract GovernanceContestTest is Test {
    GovernanceContest public governance;
    MockERC20 public depositToken;
    MockERC20Votes public governanceToken;

    address public owner = address(1);
    address public yieldVault = address(0); // address(0) bypasses vault path in castVote/claimReward
    address public alice = address(3);
    address public bob = address(4);
    address public charlie = address(5);

    uint256 public constant PROPOSAL_THRESHOLD = 100e18;
    uint256 public constant QUORUM_PERCENTAGE = 2000; // 20%
    uint256 public constant MIN_DEPOSIT = 10e18;
    uint256 public constant VOTING_DELAY = 1 days;
    uint256 public constant VOTING_PERIOD = 3 days;

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
        GovernanceContest.VoteType voteType,
        uint256 weight,
        uint256 depositAmount
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event RewardClaimed(address indexed voter, uint256 indexed proposalId, uint256 amount);

    function setUp() public {
        vm.startPrank(owner);

        depositToken = new MockERC20("USDC", "USDC", 18);
        governanceToken = new MockERC20Votes("GOV", "GOV", 18);

        GovernanceContest.GovernanceConfig memory config = GovernanceContest.GovernanceConfig({
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            proposalThreshold: PROPOSAL_THRESHOLD,
            quorumPercentage: QUORUM_PERCENTAGE,
            minDeposit: MIN_DEPOSIT,
            weightedVoting: true
        });

        governance = new GovernanceContest(
            address(depositToken),
            address(governanceToken),
            yieldVault,
            config
        );

        vm.stopPrank();

        // Mint tokens
        governanceToken.mint(alice, 1000e18);
        governanceToken.mint(bob, 500e18);
        governanceToken.mint(charlie, 50e18);  // below PROPOSAL_THRESHOLD (100e18)

        depositToken.mint(alice, 10000e18);
        depositToken.mint(bob, 10000e18);
        depositToken.mint(charlie, 10000e18);

        // Approve governance contract
        vm.prank(alice);
        depositToken.approve(address(governance), type(uint256).max);
        vm.prank(bob);
        depositToken.approve(address(governance), type(uint256).max);
        vm.prank(charlie);
        depositToken.approve(address(governance), type(uint256).max);

        // Advance block number so block.number - 1 doesn't underflow in castVote snapshot
        vm.roll(10);
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(address(governance.depositToken()), address(depositToken));
        assertEq(address(governance.governanceToken()), address(governanceToken));
        // yieldVault getter removed (W2 cleanup) — vault integration is gone.
        assertEq(governance.proposalCount(), 0);

        (
            uint256 votingDelay,
            uint256 votingPeriod,
            uint256 proposalThreshold,
            uint256 quorumPercentage,
            uint256 minDeposit,
            bool weightedVoting
        ) = governance.config();

        assertEq(votingDelay, VOTING_DELAY);
        assertEq(votingPeriod, VOTING_PERIOD);
        assertEq(proposalThreshold, PROPOSAL_THRESHOLD);
        assertEq(quorumPercentage, QUORUM_PERCENTAGE);
        assertEq(minDeposit, MIN_DEPOSIT);
        assertTrue(weightedVoting);
    }

    // ============ PROPOSAL CREATION TESTS ============

    function testCreateProposal() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal(
            "Proposal 1",
            "Test proposal description",
            "ipfs://hash"
        );

        assertEq(proposalId, 1);
        assertEq(governance.proposalCount(), 1);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.id, 1);
        assertEq(proposal.proposer, alice);
        assertEq(proposal.title, "Proposal 1");
        assertEq(proposal.startTime, block.timestamp + VOTING_DELAY);
        assertEq(proposal.endTime, block.timestamp + VOTING_DELAY + VOTING_PERIOD);
    }

    function testCreateProposalEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ProposalCreated(1, alice, "Proposal 1", 0, 0);

        vm.prank(alice);
        governance.createProposal("Proposal 1", "Description", "ipfs://hash");
    }

    function testCreateMultipleProposals() public {
        vm.startPrank(alice);
        governance.createProposal("Proposal 1", "Desc 1", "ipfs://1");
        governance.createProposal("Proposal 2", "Desc 2", "ipfs://2");
        governance.createProposal("Proposal 3", "Desc 3", "ipfs://3");
        vm.stopPrank();

        assertEq(governance.proposalCount(), 3);

        uint256[] memory ids = governance.getProposalIds();
        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);
    }

    function testRevertCreateProposalBelowThreshold() public {
        // Charlie has < PROPOSAL_THRESHOLD
        vm.prank(charlie);
        vm.expectRevert("GovernanceContest: below proposal threshold");
        governance.createProposal("Proposal 1", "Description", "ipfs://hash");
    }

    // ============ PROPOSAL STATE TESTS ============

    function testProposalStatePending() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        assertEq(uint8(governance.state(proposalId)), uint8(GovernanceContest.ProposalState.PENDING));
    }

    function testProposalStateActive() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        assertEq(uint8(governance.state(proposalId)), uint8(GovernanceContest.ProposalState.ACTIVE));
    }

    function testProposalStateDefeated() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Vote against
        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.AGAINST, MIN_DEPOSIT);

        // End voting
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(governance.state(proposalId)), uint8(GovernanceContest.ProposalState.DEFEATED));
    }

    function testProposalStateSucceeded() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Vote for with enough quorum
        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.prank(bob);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        // End voting
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(governance.state(proposalId)), uint8(GovernanceContest.ProposalState.SUCCEEDED));
    }

    function testProposalStateCanceled() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.prank(alice);
        governance.cancelProposal(proposalId);

        assertEq(uint8(governance.state(proposalId)), uint8(GovernanceContest.ProposalState.CANCELED));
    }

    function testProposalStateExecuted() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);
        vm.prank(bob);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(alice);
        governance.executeProposal(proposalId);

        assertEq(uint8(governance.state(proposalId)), uint8(GovernanceContest.ProposalState.EXECUTED));
    }

    // ============ VOTING TESTS ============

    function testCastVoteFor() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        uint256 aliceBalanceBefore = depositToken.balanceOf(alice);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.forVotes, 1000e18); // Alice's governance token balance
        assertEq(proposal.totalDeposits, MIN_DEPOSIT);

        uint256 aliceBalanceAfter = depositToken.balanceOf(alice);
        assertEq(aliceBalanceBefore - aliceBalanceAfter, MIN_DEPOSIT);
    }

    function testCastVoteAgainst() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.AGAINST, MIN_DEPOSIT);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.againstVotes, 1000e18);
    }

    function testCastVoteAbstain() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.ABSTAIN, MIN_DEPOSIT);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.abstainVotes, 1000e18);
    }

    function testCastVoteEmitsEvent() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.expectEmit(true, true, false, true);
        emit VoteCast(alice, proposalId, GovernanceContest.VoteType.FOR, 1000e18, MIN_DEPOSIT);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);
    }

    function testGetReceipt() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        (
            bool hasVoted,
            GovernanceContest.VoteType voteType,
            uint256 weight,
            uint256 depositAmount,
            uint256 rewardClaimed
        ) = governance.getReceipt(proposalId, alice);

        assertTrue(hasVoted);
        assertEq(uint8(voteType), uint8(GovernanceContest.VoteType.FOR));
        assertEq(weight, 1000e18);
        assertEq(depositAmount, MIN_DEPOSIT);
        assertEq(rewardClaimed, 0);
    }

    function testRevertCastVoteNotActive() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        // Try to vote before voting starts
        vm.prank(alice);
        vm.expectRevert("GovernanceContest: voting not active");
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);
    }

    function testRevertCastVoteAlreadyVoted() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        // Try to vote again
        vm.prank(alice);
        vm.expectRevert("GovernanceContest: already voted");
        governance.castVote(proposalId, GovernanceContest.VoteType.AGAINST, MIN_DEPOSIT);
    }

    function testRevertCastVoteDepositTooLow() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert("GovernanceContest: deposit too low");
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT - 1);
    }

    // ============ DELEGATION TESTS ============

    function testDelegate() public {
        vm.prank(bob);
        governance.delegate(alice);

        assertEq(governance.delegates(bob), alice);
        // delegatedWeight is legacy storage; delegation now records delegator
        // relationship and weight is computed at vote time via getPastVotes
        assertEq(governance.delegatedWeight(alice), 0);
    }

    function testDelegateEmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit DelegateChanged(bob, address(0), alice);

        vm.prank(bob);
        governance.delegate(alice);
    }

    function testRedelegateChangesWeight() public {
        vm.prank(bob);
        governance.delegate(alice);

        assertEq(governance.delegates(bob), alice);

        // Redelegate to Charlie
        vm.prank(bob);
        governance.delegate(charlie);

        // delegatedWeight is legacy; verify delegation relationship changed
        assertEq(governance.delegates(bob), charlie);
    }

    function testVotingWithDelegation() public {
        // Bob delegates to Alice
        vm.prank(bob);
        governance.delegate(alice);

        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        // Alice's votes = her balance (1000) + Bob's delegation (500)
        assertEq(proposal.forVotes, 1500e18);
    }

    // ============ EXECUTION TESTS ============

    function testExecuteProposal() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);
        vm.prank(bob);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(alice);
        governance.executeProposal(proposalId);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertTrue(proposal.executed);
    }

    function testExecuteProposalEmitsEvent() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);
        vm.prank(bob);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.expectEmit(true, false, false, false);
        emit ProposalExecuted(proposalId);

        vm.prank(alice);
        governance.executeProposal(proposalId);
    }

    function testRevertExecuteProposalNotSucceeded() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Vote against
        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.AGAINST, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert("GovernanceContest: not succeeded");
        governance.executeProposal(proposalId);
    }

    // ============ CANCELLATION TESTS ============

    function testCancelProposalByProposer() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.prank(alice);
        governance.cancelProposal(proposalId);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertTrue(proposal.canceled);
    }

    function testCancelProposalByOwner() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.prank(owner);
        governance.cancelProposal(proposalId);

        GovernanceContest.ProposalView memory proposal = governance.getProposal(proposalId);
        assertTrue(proposal.canceled);
    }

    function testRevertCancelProposalUnauthorized() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.prank(bob);
        vm.expectRevert("GovernanceContest: not authorized");
        governance.cancelProposal(proposalId);
    }

    function testRevertCancelExecutedProposal() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);
        vm.prank(bob);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(alice);
        governance.executeProposal(proposalId);

        vm.prank(alice);
        vm.expectRevert("GovernanceContest: already executed");
        governance.cancelProposal(proposalId);
    }

    // ============ REWARD TESTS ============

    function testClaimReward() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        uint256 aliceBalanceBefore = depositToken.balanceOf(alice);

        vm.prank(alice);
        governance.claimReward(proposalId);

        uint256 aliceBalanceAfter = depositToken.balanceOf(alice);

        // No yield vault configured, so claim returns principal only
        assertEq(aliceBalanceAfter, aliceBalanceBefore + MIN_DEPOSIT);
    }

    function testRevertClaimRewardStillActive() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        // Still in voting period
        vm.prank(alice);
        vm.expectRevert("GovernanceContest: still active");
        governance.claimReward(proposalId);
    }

    function testRevertClaimRewardDidNotVote() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);

        vm.prank(bob);
        vm.expectRevert("GovernanceContest: did not vote");
        governance.claimReward(proposalId);
    }

    function testRevertClaimRewardAlreadyClaimed() public {
        vm.prank(alice);
        uint256 proposalId = governance.createProposal("Proposal 1", "Desc", "ipfs://1");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        governance.castVote(proposalId, GovernanceContest.VoteType.FOR, MIN_DEPOSIT);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(alice);
        governance.claimReward(proposalId);

        vm.prank(alice);
        vm.expectRevert("GovernanceContest: already claimed");
        governance.claimReward(proposalId);
    }

    // ============ VIEW FUNCTIONS TESTS ============

    function testGetActiveProposals() public {
        vm.prank(alice);
        uint256 id1 = governance.createProposal("Proposal 1", "Desc", "ipfs://1");
        vm.prank(alice);
        uint256 id2 = governance.createProposal("Proposal 2", "Desc", "ipfs://2");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        uint256[] memory active = governance.getActiveProposals();
        assertEq(active.length, 2);
        assertEq(active[0], id1);
        assertEq(active[1], id2);
    }

    // ============ ADMIN TESTS ============

    function testUpdateConfig() public {
        GovernanceContest.GovernanceConfig memory newConfig = GovernanceContest.GovernanceConfig({
            votingDelay: 2 days,
            votingPeriod: 5 days,
            proposalThreshold: 200e18,
            quorumPercentage: 3000,
            minDeposit: 20e18,
            weightedVoting: false
        });

        vm.prank(owner);
        governance.updateConfig(newConfig);

        (
            uint256 votingDelay,
            uint256 votingPeriod,
            uint256 proposalThreshold,
            uint256 quorumPercentage,
            uint256 minDeposit,
            bool weightedVoting
        ) = governance.config();

        assertEq(votingDelay, 2 days);
        assertEq(votingPeriod, 5 days);
        assertEq(proposalThreshold, 200e18);
        assertEq(quorumPercentage, 3000);
        assertEq(minDeposit, 20e18);
        assertFalse(weightedVoting);
    }

    // testSetYieldVault removed (W2 cleanup 2026-04-28) — setYieldVault and the
    // yieldVault storage slot were stripped from the contract. The audit fix
    // 2026-04-26 removed the vault from the hot path; W2 closes the residue
    // (interface, storage, setter, view dependency) so a future owner cannot
    // re-enable the vault path.
}
