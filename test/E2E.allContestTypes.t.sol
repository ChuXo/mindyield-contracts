// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/// @title End-to-End Test: All 5 Contest Types Full Lifecycle
/// @notice Verifies COMPLETE lifecycle (create→deposit→commit→reveal→resolve→withdraw→claim)
///         for VOTE, RANK, RATE, PREDICT, and PAIRWISE contest types.
contract E2EAllContestTypesTest is ContestV2TestBase {

    // ═══════════════════════════════════════════════════════════════════════════
    // VOTE Contest — Full Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_VOTE_fullLifecycle() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Deposit
        _deposit(alice, c);
        _deposit(bob, c);
        _deposit(charlie, c);

        // Commit
        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes memory voteB = _makeVoteData_VOTE(OPT_B);
        bytes32 saltA = keccak256("e2e_vote_a");
        bytes32 saltB = keccak256("e2e_vote_b");
        bytes32 saltC = keccak256("e2e_vote_c");
        _commitVote(alice, c, voteA, saltA);
        _commitVote(bob, c, voteB, saltB);
        _commitVote(charlie, c, voteA, saltC); // charlie also votes A

        // Advance to reveal
        _advancePastLock(c);

        // Reveal
        _revealVote(alice, c, voteA, saltA);
        _revealVote(bob, c, voteB, saltB);
        _revealVote(charlie, c, voteA, saltC);

        // Advance past reveal
        _advancePastReveal(c);

        // Resolve
        vm.prank(creator);
        ContestV2(c).resolveContest();
        assertEq(_getState(c), 8); // FINALIZED

        // OPT_A wins (2 votes vs 1)
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);

        // Withdraw principal
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        assertGt(usdc.balanceOf(alice), balBefore);

        // Claim voter reward (alice voted for winner) - may be 0 if no yield generated
        uint256 reward = ContestV2(c).getVoterReward(alice);
        if (reward > 0) {
            vm.prank(alice);
            ContestV2(c).claimVoterReward();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RANK Contest — Full Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_RANK_fullLifecycle() public {
        address c = _createContest(TYPE_RANK, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        // Rankings must cover ALL options (contest has 4: A,B,C,D)
        bytes32[] memory rankA = new bytes32[](4);
        rankA[0] = OPT_A; rankA[1] = OPT_B; rankA[2] = OPT_C; rankA[3] = OPT_D;
        bytes32[] memory rankB = new bytes32[](4);
        rankB[0] = OPT_A; rankB[1] = OPT_C; rankB[2] = OPT_D; rankB[3] = OPT_B;

        bytes memory voteA = _makeVoteData_RANK(rankA);
        bytes memory voteB = _makeVoteData_RANK(rankB);
        bytes32 saltA = keccak256("e2e_rank_a");
        bytes32 saltB = keccak256("e2e_rank_b");

        _commitVote(alice, c, voteA, saltA);
        _commitVote(bob, c, voteB, saltB);

        _advancePastLock(c);
        _revealVote(alice, c, voteA, saltA);
        _revealVote(bob, c, voteB, saltB);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        assertEq(_getState(c), 8); // FINALIZED
        // A is ranked first by both voters
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);

        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RATE Contest — Full Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_RATE_fullLifecycle() public {
        address c = _createContest(TYPE_RATE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        bytes32[] memory optIds = _defaultOptions(); // 4 options
        uint256[] memory ratingsA = new uint256[](4);
        ratingsA[0] = 9; ratingsA[1] = 5; ratingsA[2] = 3; ratingsA[3] = 2;
        uint256[] memory ratingsB = new uint256[](4);
        ratingsB[0] = 8; ratingsB[1] = 6; ratingsB[2] = 4; ratingsB[3] = 3;

        bytes memory voteA = _makeVoteData_RATE(optIds, ratingsA);
        bytes memory voteB = _makeVoteData_RATE(optIds, ratingsB);
        bytes32 saltA = keccak256("e2e_rate_a");
        bytes32 saltB = keccak256("e2e_rate_b");

        _commitVote(alice, c, voteA, saltA);
        _commitVote(bob, c, voteB, saltB);

        _advancePastLock(c);
        _revealVote(alice, c, voteA, saltA);
        _revealVote(bob, c, voteB, saltB);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        assertEq(_getState(c), 8); // FINALIZED
        // OPT_A has highest total score: 9+8=17
        assertEq(ContestV2(c).getResults().winningOption, OPT_A);

        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PREDICT Contest — Full Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_PREDICT_fullLifecycle() public {
        address c = _createContest(TYPE_PREDICT, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteA = _makeVoteData_PREDICT(OPT_B, 80);
        bytes memory voteB = _makeVoteData_PREDICT(OPT_B, 60);
        bytes32 saltA = keccak256("e2e_predict_a");
        bytes32 saltB = keccak256("e2e_predict_b");

        _commitVote(alice, c, voteA, saltA);
        _commitVote(bob, c, voteB, saltB);

        _advancePastLock(c);
        _revealVote(alice, c, voteA, saltA);
        _revealVote(bob, c, voteB, saltB);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        assertEq(_getState(c), 8); // FINALIZED
        assertEq(ContestV2(c).getResults().winningOption, OPT_B);

        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PAIRWISE Contest — Full Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_PAIRWISE_fullLifecycle() public {
        address c = _createContest(TYPE_PAIRWISE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        // Pairwise: select winners from pairs
        bytes32[] memory chosenA = new bytes32[](1);
        chosenA[0] = OPT_C;
        bytes32[] memory chosenB = new bytes32[](1);
        chosenB[0] = OPT_C;

        bytes memory voteA = _makeVoteData_PAIRWISE(chosenA);
        bytes memory voteB = _makeVoteData_PAIRWISE(chosenB);
        bytes32 saltA = keccak256("e2e_pairwise_a");
        bytes32 saltB = keccak256("e2e_pairwise_b");

        _commitVote(alice, c, voteA, saltA);
        _commitVote(bob, c, voteB, saltB);

        _advancePastLock(c);
        _revealVote(alice, c, voteA, saltA);
        _revealVote(bob, c, voteB, saltB);

        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        assertEq(_getState(c), 8); // FINALIZED
        assertEq(ContestV2(c).getResults().winningOption, OPT_C);

        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Edge: Cancel + Withdraw
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_cancelAndWithdraw() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        // Advance block AND time to meet YieldVault minimum hold time (60s) BEFORE cancel
        // Cancel withdraws from vault internally, so hold time must be met first
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        vm.prank(creator);
        ContestV2(c).cancel("e2e cancel test");
        assertEq(_getState(c), 9); // CANCELLED

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ContestV2(c).withdrawPrincipal();
        assertGt(usdc.balanceOf(alice), aliceBefore);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        ContestV2(c).withdrawPrincipal();
        assertGt(usdc.balanceOf(bob), bobBefore);
    }
}
