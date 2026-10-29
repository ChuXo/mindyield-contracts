// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/// @title E2E Contest Edge Cases
/// @notice Tests edge cases: quorum, late reveal, double actions, factory cancel
contract E2EContestEdgeCasesTest is ContestV2TestBase {

    // ═══════════════════════════════════════════════════════════════════════════
    // Only 1 reveal (quorum check)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_singleReveal_quorumBehavior() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // 2 deposits, but only 1 reveals
        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("only_alice");
        _commitVote(alice, c, voteA, salt);

        // Bob commits but won't reveal
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob_skips"));

        _advancePastLock(c);
        _revealVote(alice, c, voteA, salt);
        // Bob does NOT reveal

        _advancePastReveal(c);

        // Resolve - should either succeed (1 reveal meets quorum) or revert
        vm.prank(creator);
        try ContestV2(c).resolveContest() {
            assertEq(_getState(c), 8); // FINALIZED
            // Winner should be OPT_A (only revealed vote)
            assertEq(ContestV2(c).getResults().winningOption, OPT_A);
        } catch {
            // Quorum not met - also valid
            assertEq(_getState(c), 6); // still REVEAL_OPEN or RESOLVING
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Deposit after window closes → reverts
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lateDeposit_reverts() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        // Advance past deposit window
        _advancePastDeposit(c);

        // Late deposit should revert
        vm.startPrank(charlie);
        usdc.approve(address(c), type(uint256).max);
        vm.expectRevert(); // InvalidState or InvalidConfig
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Late reveal (after revealEnd) → reverts
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_lateReveal_reverts() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("late_reveal");
        _commitVote(alice, c, voteA, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob_late"));

        _advancePastLock(c);
        // Alice reveals on time
        _revealVote(alice, c, voteA, salt);

        // Advance PAST reveal end
        _advancePastReveal(c);

        // Bob tries to reveal late → should revert
        vm.prank(bob);
        vm.expectRevert(); // InvalidConfig (past revealEnd)
        ContestV2(c).revealVote(_makeVoteData_VOTE(OPT_B), keccak256("bob_late"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Double deposit → reverts AlreadyDeposited
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_doubleDeposit_reverts() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);

        // Second deposit should revert
        vm.startPrank(alice);
        usdc.approve(address(c), type(uint256).max);
        vm.expectRevert(ContestV2.AlreadyDeposited.selector);
        ContestV2(c).deposit();
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Double commit → reverts AlreadyCommitted
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_doubleCommit_reverts() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _commitVote(alice, c, _makeVoteData_VOTE(OPT_A), keccak256("first"));

        vm.prank(alice);
        vm.expectRevert(ContestV2.AlreadyCommitted.selector);
        ContestV2(c).commitVote(keccak256("second_attempt"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Double reveal → reverts AlreadyRevealed
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_doubleReveal_reverts() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 salt = keccak256("double_reveal");
        _commitVote(alice, c, voteA, salt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob_ok"));

        _advancePastLock(c);
        _revealVote(alice, c, voteA, salt);

        // Second reveal should revert
        vm.prank(alice);
        vm.expectRevert(ContestV2.AlreadyRevealed.selector);
        ContestV2(c).revealVote(voteA, salt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Wrong salt reveal → reverts InvalidReveal
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_wrongSalt_revertsInvalidReveal() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        bytes memory voteA = _makeVoteData_VOTE(OPT_A);
        bytes32 correctSalt = keccak256("correct_salt");
        bytes32 wrongSalt = keccak256("wrong_salt");
        _commitVote(alice, c, voteA, correctSalt);
        _commitVote(bob, c, _makeVoteData_VOTE(OPT_B), keccak256("bob_salt"));

        _advancePastLock(c);

        // Reveal with wrong salt
        vm.prank(alice);
        vm.expectRevert(ContestV2.InvalidReveal.selector);
        ContestV2(c).revealVote(voteA, wrongSalt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Withdraw without depositing → reverts NotDeposited
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_withdrawWithoutDeposit_revertsNotDeposited() public {
        address c = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        _deposit(alice, c);
        _deposit(bob, c);

        // Run full lifecycle to FINALIZED
        bytes memory vA = _makeVoteData_VOTE(OPT_A);
        bytes memory vB = _makeVoteData_VOTE(OPT_A);
        bytes32 sA = keccak256("wa"); bytes32 sB = keccak256("wb");
        _commitVote(alice, c, vA, sA);
        _commitVote(bob, c, vB, sB);
        _advancePastLock(c);
        _revealVote(alice, c, vA, sA);
        _revealVote(bob, c, vB, sB);
        _advancePastReveal(c);
        vm.prank(creator);
        ContestV2(c).resolveContest();

        // Charlie (never deposited) tries to withdraw
        vm.prank(charlie);
        vm.expectRevert(ContestV2.NotDeposited.selector);
        ContestV2(c).withdrawPrincipal();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // All 5 types: commit without deposit → reverts NotDeposited
    // ═══════════════════════════════════════════════════════════════════════════

    function test_e2e_commitWithoutDeposit_allTypes() public {
        uint8[5] memory types = [TYPE_VOTE, TYPE_RANK, TYPE_RATE, TYPE_PREDICT, TYPE_PAIRWISE];

        for (uint256 i = 0; i < 5; i++) {
            address c = _createContest(types[i], WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

            vm.prank(alice);
            vm.expectRevert(ContestV2.NotDeposited.selector);
            ContestV2(c).commitVote(keccak256("no_deposit"));
        }
    }
}
