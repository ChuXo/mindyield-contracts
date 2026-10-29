// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/ContestV2TestBase.sol";

/// @title ContestV2 — Submissions (REMOVED)
/// @notice The submission feature was removed from ContestV2 in the 2026-04
///         slim-down to fit the contract under the EIP-170 24,576-byte limit.
///         The original test suite has been replaced with a single guard test
///         confirming that creating a contest with `submissionConfig.enabled
///         == true` reverts. The feature will return as a separate
///         ContestSubmissionsExtension contract — its tests will live there.
contract ContestV2SubmissionsRemovedTest is ContestV2TestBase {
    /// @notice initialize() must reject any contest that tries to enable submissions.
    function test_submissions_creationRejectedWhenEnabled() public {
        uint256 t = block.timestamp;
        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           DEFAULT_DEPOSIT_AMOUNT,
            minParticipants:         DEFAULT_MIN_PARTICIPANTS,
            maxParticipants:         DEFAULT_MAX_PARTICIPANTS,
            depositStart:            t,
            depositEnd:              t + DEFAULT_DEPOSIT_DURATION,
            lockEnd:                 t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION,
            revealEnd:               t + DEFAULT_DEPOSIT_DURATION + DEFAULT_LOCK_DURATION + DEFAULT_REVEAL_DURATION,
            contestType:             ContestV2.ContestType.VOTE,
            winnerDetermination:     ContestV2.WinnerDetermination.PLURALITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.PROPORTIONAL,
            tierRequired:            0,
            quorumPercentage:        DEFAULT_QUORUM_PERCENTAGE,
            requiresOracle:          false,
            metadataHash:            keccak256("test-submissions-removed"),
            metadataUri:             "ipfs://test"
        });

        ContestV2.PrizeConfig memory prizeCfg = ContestV2.PrizeConfig({
            model:                ContestV2.PrizeModel.PROPORTIONAL,
            splitsBps:            new uint16[](0),
            eligibilityThreshold: 0,
            weightedByScore:      false
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold:  0,
            topPercentile:         2500,
            confidenceMultiplier:  5000,
            earlyVoterBonus:       0
        });

        ContestV2.SubmissionConfig memory subs = ContestV2.SubmissionConfig({
            enabled: true,                                  // ← the trigger
            submissionStart: t,
            submissionEnd: t + 1 days,
            maxPerUser: 1,
            requiresModeration: false,
            paymentModel: ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0,
            minSubmissions: 1,
            maxTotalSubmissions: 10
        });

        bytes32[] memory opts = _defaultOptions();

        vm.prank(creator);
        vm.expectRevert(ContestV2.InvalidConfig.selector);
        factory.createCustomContest(
            config, prizeCfg, scoring, subs, address(0), opts, 0
        );
    }
}
