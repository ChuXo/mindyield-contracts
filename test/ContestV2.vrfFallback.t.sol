// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

/**
 * @title ContestV2VrfFallbackTest
 * @notice Coverage for forceDeterministicFallback() — the audit M-05 escape
 *         hatch that prevents a stuck VRF callback from indefinitely holding
 *         a SINGLE_RANDOM / TOP_N_RANDOM contest in AWAITING_VRF.
 *
 *         Window (relative to vrfRequestedAt):
 *           [0, VRF_TIMEOUT)                                         — reverts
 *           [VRF_TIMEOUT, VRF_TIMEOUT + FALLBACK_PUBLIC_AFTER)       — creator/factory only
 *           [VRF_TIMEOUT + FALLBACK_PUBLIC_AFTER, ∞)                 — anyone
 *
 *         Fallback model: SINGLE_RANDOM → SINGLE_TOP, TOP_N_RANDOM → TOP_N_RANKED.
 */
contract ContestV2VrfFallbackTest is ContestV2TestBase {

    // Re-declared event for vm.expectEmit
    event VRFFallbackUsed(ContestV2.PrizeModel originalModel, ContestV2.PrizeModel fallbackModel);

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Build a SINGLE_RANDOM-prize VOTE contest, deposit + commit + reveal
    ///      with two voters, then call resolveContest() so the contest parks
    ///      in AWAITING_VRF (MockRandomnessManager does not auto-fulfill).
    function _setupAwaitingVrfContest() internal returns (address contest) {
        ContestV2.PrizeConfig memory prizeCfg = _defaultPrizeConfigForModel(
            ContestV2.PrizeModel.SINGLE_RANDOM
        );
        contest = _createContestWithPrize(TYPE_VOTE, WINNER_PLURALITY, prizeCfg);

        address[] memory voters = new address[](2);
        voters[0] = alice;
        voters[1] = bob;
        _fullLifecycle_VOTE(contest, voters, OPT_A);

        assertEq(_getState(contest), uint8(ContestV2.ContestState.AWAITING_VRF), "must park in AWAITING_VRF");
    }

    // -------------------------------------------------------------------------
    // Window 1 — before VRF_TIMEOUT: every caller reverts
    // -------------------------------------------------------------------------

    function test_forceFallback_revertsBeforeTimeout_creator() public {
        address contest = _setupAwaitingVrfContest();

        // Just under the 24h cutoff — even the creator cannot force.
        uint256 reqAt = ContestV2(contest).vrfRequestedAt();
        vm.warp(reqAt + ContestV2(contest).VRF_TIMEOUT() - 1);

        vm.prank(creator);
        vm.expectRevert(ContestV2.VRFTimeoutNotReached.selector);
        ContestV2(contest).forceDeterministicFallback();
    }

    function test_forceFallback_revertsBeforeTimeout_anyone() public {
        address contest = _setupAwaitingVrfContest();

        vm.prank(attacker);
        vm.expectRevert(ContestV2.VRFTimeoutNotReached.selector);
        ContestV2(contest).forceDeterministicFallback();
    }

    // -------------------------------------------------------------------------
    // Window 2 — [VRF_TIMEOUT, +FALLBACK_PUBLIC_AFTER): creator / factory only
    // -------------------------------------------------------------------------

    function test_forceFallback_inCreatorWindow_revertsForUnauthorized() public {
        address contest = _setupAwaitingVrfContest();

        // Move 1 second past the 24h timeout — still inside the 7d creator-only window.
        uint256 reqAt = ContestV2(contest).vrfRequestedAt();
        vm.warp(reqAt + ContestV2(contest).VRF_TIMEOUT() + 1);

        vm.prank(attacker);
        vm.expectRevert(ContestV2.NotAuthorized.selector);
        ContestV2(contest).forceDeterministicFallback();
    }

    function test_forceFallback_inCreatorWindow_creatorSucceeds() public {
        address contest = _setupAwaitingVrfContest();

        uint256 reqAt = ContestV2(contest).vrfRequestedAt();
        vm.warp(reqAt + ContestV2(contest).VRF_TIMEOUT() + 1 hours);

        vm.expectEmit(false, false, false, true, contest);
        emit VRFFallbackUsed(ContestV2.PrizeModel.SINGLE_RANDOM, ContestV2.PrizeModel.SINGLE_TOP);

        vm.prank(creator);
        ContestV2(contest).forceDeterministicFallback();

        assertEq(_getState(contest), uint8(ContestV2.ContestState.FINALIZED), "must finalize");
        assertTrue(ContestV2(contest).getResults().isResolved, "results.isResolved must flip true");
    }

    function test_forceFallback_inCreatorWindow_factorySucceeds() public {
        address contest = _setupAwaitingVrfContest();

        uint256 reqAt = ContestV2(contest).vrfRequestedAt();
        vm.warp(reqAt + ContestV2(contest).VRF_TIMEOUT() + 1 hours);

        vm.prank(address(factory));
        ContestV2(contest).forceDeterministicFallback();

        assertEq(_getState(contest), uint8(ContestV2.ContestState.FINALIZED), "must finalize");
    }

    // -------------------------------------------------------------------------
    // Window 3 — past VRF_TIMEOUT + FALLBACK_PUBLIC_AFTER: anyone can call
    // -------------------------------------------------------------------------

    function test_forceFallback_publicAfter7d_anyoneSucceeds() public {
        address contest = _setupAwaitingVrfContest();

        uint256 reqAt = ContestV2(contest).vrfRequestedAt();
        // 24h timeout + 7d creator window + 1s = anyone can call.
        vm.warp(reqAt + ContestV2(contest).VRF_TIMEOUT() + ContestV2(contest).FALLBACK_PUBLIC_AFTER() + 1);

        vm.expectEmit(false, false, false, true, contest);
        emit VRFFallbackUsed(ContestV2.PrizeModel.SINGLE_RANDOM, ContestV2.PrizeModel.SINGLE_TOP);

        vm.prank(attacker);
        ContestV2(contest).forceDeterministicFallback();

        assertEq(_getState(contest), uint8(ContestV2.ContestState.FINALIZED), "must finalize");
    }

    // -------------------------------------------------------------------------
    // State guard: cannot re-fire after FINALIZED
    // -------------------------------------------------------------------------

    function test_forceFallback_revertsIfAlreadyFinalized() public {
        address contest = _setupAwaitingVrfContest();

        uint256 reqAt = ContestV2(contest).vrfRequestedAt();
        vm.warp(reqAt + ContestV2(contest).VRF_TIMEOUT() + 1 hours);

        vm.prank(creator);
        ContestV2(contest).forceDeterministicFallback();

        // State is now FINALIZED — second call must revert with VRFNotPending.
        vm.prank(creator);
        vm.expectRevert(ContestV2.VRFNotPending.selector);
        ContestV2(contest).forceDeterministicFallback();
    }

}
