// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";

contract ContestFactoryV2ExtendedTest is ContestV2TestBase {

    // Template ID constants
    bytes32 internal ELECTION_ID   = keccak256("election");
    bytes32 internal RANKING_ID    = keccak256("ranking");
    bytes32 internal RATING_ID     = keccak256("rating");
    bytes32 internal PREDICTION_ID = keccak256("prediction");
    bytes32 internal GOVERNANCE_ID = keccak256("governance");
    bytes32 internal MEME_ID       = keccak256("meme");

    // =========================================================================
    // Helpers
    // =========================================================================

    function _buildDefaultParams() internal view returns (ContestFactoryV2.CreateContestParams memory) {
        return ContestFactoryV2.CreateContestParams({
            depositToken: address(usdc),
            depositAmount: 10e6,
            metadataHash: keccak256("test"),
            metadataUri: "ipfs://test",
            options: _defaultOptions(),
            depositStart: 0,
            depositEnd: 0,
            lockEnd: 0,
            revealEnd: 0,
            minParticipants: 0,
            maxParticipants: 10000,  // Must not exceed MAX_PARTICIPANTS_CAP (10_000)
            tierRequired: 0,
            quorumPercentage: 0,
            oracle: address(0),
            correlationThreshold: 0,
            topPercentile: 0,
            confidenceMultiplier: 0,
            earlyVoterBonus: 0,
            creatorPrize: 0,
            // v2.1: empty prize-config overrides → use template defaults
            splitsBps: new uint16[](0),
            eligibilityThreshold: 0,
            weightedByScore: false,
            overrideWeightedByScore: false
        });
    }

    // =========================================================================
    // 1. Default templates (5 tests)
    // =========================================================================

    function test_factory_has_7_templates_after_deployment() public view {
        // v2.1 — added Raffle template (SINGLE_RANDOM)
        bytes32[] memory ids = factory.getTemplateIds();
        assertEq(ids.length, 7, "Should have 7 default templates (v2.1)");
    }

    function test_election_template_config() public view {
        // v2.1 — Election now uses SINGLE_TOP (was VOTER_REWARDS, which was a no-op)
        ContestFactoryV2.ContestTemplate memory t = factory.getTemplate(ELECTION_ID);
        assertEq(t.id, ELECTION_ID, "ID mismatch");
        assertEq(uint8(t.contestType), TYPE_VOTE, "Should be VOTE type");
        assertEq(uint8(t.winnerDetermination), WINNER_PLURALITY, "Should be PLURALITY");
        assertEq(uint8(t.prizeModel), PRIZE_SINGLE_TOP, "Should be SINGLE_TOP");
        assertTrue(t.isActive, "Should be active");
    }

    function test_ranking_template_config() public view {
        ContestFactoryV2.ContestTemplate memory t = factory.getTemplate(RANKING_ID);
        assertEq(uint8(t.contestType), TYPE_RANK, "Should be RANK type");
        assertEq(uint8(t.winnerDetermination), WINNER_BORDA_COUNT, "Should be BORDA_COUNT");
        assertEq(t.minParticipants, 30, "Min participants should be 30");
    }

    function test_prediction_template_requires_oracle() public view {
        ContestFactoryV2.ContestTemplate memory t = factory.getTemplate(PREDICTION_ID);
        assertTrue(t.requiresOracle, "Prediction template should require oracle");
        assertEq(uint8(t.contestType), TYPE_PREDICT, "Should be PREDICT type");
        assertEq(uint8(t.winnerDetermination), WINNER_ORACLE, "Should be ORACLE winner method");
    }

    function test_getTemplateIds_returns_all_7() public view {
        // v2.1 — added Raffle (SINGLE_RANDOM) at index 6
        bytes32[] memory ids = factory.getTemplateIds();
        assertEq(ids.length, 7);
        assertEq(ids[0], ELECTION_ID);
        assertEq(ids[1], RANKING_ID);
        assertEq(ids[2], RATING_ID);
        assertEq(ids[3], PREDICTION_ID);
        assertEq(ids[4], GOVERNANCE_ID);
        assertEq(ids[5], MEME_ID);
        assertEq(ids[6], keccak256("raffle"));
    }

    // =========================================================================
    // 2. createContestFromTemplate (5 tests)
    // =========================================================================

    function test_createFromTemplate_election_succeeds() public {
        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();

        vm.prank(creator);
        (bytes32 contestId, address contestAddr) = factory.createContestFromTemplate(ELECTION_ID, params);

        assertTrue(contestAddr != address(0), "Contest address should be non-zero");
        assertTrue(contestId != bytes32(0), "Contest ID should be non-zero");

        // Verify contest type matches election template
        ContestV2.ContestConfig memory cfg = ContestV2(contestAddr).getConfig();
        assertEq(uint8(cfg.contestType), TYPE_VOTE, "Should inherit VOTE from election template");
        assertEq(uint8(cfg.winnerDetermination), WINNER_PLURALITY, "Should inherit PLURALITY");
    }

    function test_createFromTemplate_inactive_reverts() public {
        // Deactivate election template (this contract is factory owner)
        factory.setTemplateActive(ELECTION_ID, false);

        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();

        vm.prank(creator);
        vm.expectRevert("ContestFactoryV2: template not active");
        factory.createContestFromTemplate(ELECTION_ID, params);
    }

    function test_createFromTemplate_tracking() public {
        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();

        vm.prank(creator);
        (bytes32 contestId, address contestAddr) = factory.createContestFromTemplate(ELECTION_ID, params);

        // getContest returns correct address
        assertEq(factory.getContest(contestId), contestAddr, "getContest mismatch");

        // getContestCount incremented
        assertEq(factory.getContestCount(), 1, "Contest count should be 1");

        // getCreatorContests tracks creator
        bytes32[] memory creatorIds = factory.getCreatorContests(creator);
        assertEq(creatorIds.length, 1, "Creator should have 1 contest");
        assertEq(creatorIds[0], contestId, "Creator contest ID mismatch");
    }

    function test_createFromTemplate_uses_template_defaults_when_params_zero() public {
        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();
        // Leave all timing and participant params as 0 to use template defaults

        vm.prank(creator);
        (, address contestAddr) = factory.createContestFromTemplate(ELECTION_ID, params);

        ContestV2.ContestConfig memory cfg = ContestV2(contestAddr).getConfig();

        // Election template: minParticipants=100, maxParticipants=10000 (capped at MAX_PARTICIPANTS_CAP)
        assertEq(cfg.minParticipants, 100, "Should use template min participants");
        assertEq(cfg.maxParticipants, 10000, "Should use params maxParticipants (within cap)");

        // Election template: deposit=14d, lock=7d, reveal=3d
        uint256 expectedDepositEnd = block.timestamp + 14 days;
        uint256 expectedLockEnd = block.timestamp + 14 days + 7 days;
        uint256 expectedRevealEnd = block.timestamp + 14 days + 7 days + 3 days;
        assertEq(cfg.depositEnd, expectedDepositEnd, "Should use template deposit period");
        assertEq(cfg.lockEnd, expectedLockEnd, "Should use template lock period");
        assertEq(cfg.revealEnd, expectedRevealEnd, "Should use template reveal period");
    }

    function test_createFromTemplate_custom_params_override_defaults() public {
        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();
        params.minParticipants = 5;
        params.maxParticipants = 50;
        params.depositStart = block.timestamp + 1 hours;
        params.depositEnd = block.timestamp + 3 hours; // Must be > depositStart + 1 hour
        params.lockEnd = block.timestamp + 5 hours;
        params.revealEnd = block.timestamp + 7 hours;
        // v2.1 — voterRewardPercentage removed; voter pool is always 100% now.
        // Override eligibilityThreshold instead to verify per-contest prize-config customization.
        params.eligibilityThreshold = 25;

        vm.prank(creator);
        (, address contestAddr) = factory.createContestFromTemplate(ELECTION_ID, params);

        ContestV2.ContestConfig memory cfg = ContestV2(contestAddr).getConfig();
        assertEq(cfg.minParticipants, 5, "Custom min should override template");
        assertEq(cfg.maxParticipants, 50, "Custom max should override template");
        assertEq(cfg.depositStart, block.timestamp + 1 hours, "Custom depositStart");
        assertEq(cfg.depositEnd, block.timestamp + 3 hours, "Custom depositEnd");
        assertEq(cfg.lockEnd, block.timestamp + 5 hours, "Custom lockEnd");
        assertEq(cfg.revealEnd, block.timestamp + 7 hours, "Custom revealEnd");
        ContestV2.PrizeConfig memory prize = ContestV2(contestAddr).getPrizeConfig();
        assertEq(prize.eligibilityThreshold, 25, "Custom eligibility threshold");
    }

    // =========================================================================
    // 3. createCustomContest (4 tests)
    // =========================================================================

    function test_createCustomContest_succeeds() public {
        address contestAddr = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        assertTrue(contestAddr != address(0), "Contest should be created");
        assertEq(factory.getContestCount(), 1, "Count should be 1");
    }

    function test_createCustomContest_id_is_deterministic() public {
        // Contest ID = keccak256(sender, block.timestamp, metadataHash, factoryNonce)
        // _contestNonce is the test helper nonce used for metadataHash generation
        uint256 nonce = _contestNonce;
        bytes32 metadataHash = keccak256(abi.encodePacked("test-contest-", block.timestamp, nonce));
        // The factory's internal nonce starts at 0 for the first contest created
        uint256 factoryNonce = 0;
        bytes32 expectedId = keccak256(abi.encodePacked(creator, block.timestamp, metadataHash, factoryNonce));

        // _createContest uses creator as the sender and this metadataHash format
        address contestAddr = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        assertEq(factory.getContest(expectedId), contestAddr, "Contest ID should be deterministic");
    }

    function test_createCustomContest_nonce_prevents_id_collision() public {
        // With the nonce in ID generation, two contests with identical params
        // in the same block get different IDs (no collision)
        address contest1 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);
        address contest2 = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        assertTrue(contest1 != contest2, "Two contests should have different addresses");
        assertTrue(contest1 != address(0), "First contest should be deployed");
        assertTrue(contest2 != address(0), "Second contest should be deployed");
    }

    function test_createCustomContest_options_stored_correctly() public {
        address contestAddr = _createContest(TYPE_VOTE, WINNER_PLURALITY, PRIZE_VOTER_REWARDS);

        // Verify options on the created contest
        ContestV2 c = ContestV2(contestAddr);
        bytes32[] memory opts = c.getOptions();
        assertEq(opts.length, 4, "Should have 4 options");
        assertEq(opts[0], OPT_A);
        assertEq(opts[1], OPT_B);
        assertEq(opts[2], OPT_C);
        assertEq(opts[3], OPT_D);
    }

    // =========================================================================
    // 4. Template management (4 tests)
    // =========================================================================

    function test_owner_can_create_template() public {
        bytes32 newId = keccak256("custom-template");

        // address(this) is the factory owner -- no prank needed (v2.1 signature)
        factory.createTemplate(
            newId,
            "Custom Template",
            ContestV2.ContestType.VOTE,
            ContestV2.PrizeModel.SINGLE_TOP,
            ContestV2.WinnerDetermination.PLURALITY,
            ContestV2.VoterRewardDistribution.EQUAL,
            7 days,
            3 days,
            1 days,
            10,
            1000,
            0,        // defaultEligibilityThreshold
            false,    // defaultWeightedByScore
            false,    // requiresOracle
            new uint16[](0) // splitsBps (empty for SINGLE_TOP)
        );

        ContestFactoryV2.ContestTemplate memory t = factory.getTemplate(newId);
        assertEq(t.id, newId, "Template ID should match");
        assertTrue(t.isActive, "New template should be active");

        bytes32[] memory ids = factory.getTemplateIds();
        assertEq(ids.length, 8, "Should now have 8 templates (7 defaults + 1 custom)");
    }

    function test_nonOwner_cannot_create_template() public {
        bytes32 newId = keccak256("rogue-template");

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.createTemplate(
            newId,
            "Rogue Template",
            ContestV2.ContestType.VOTE,
            ContestV2.PrizeModel.SINGLE_TOP,
            ContestV2.WinnerDetermination.PLURALITY,
            ContestV2.VoterRewardDistribution.EQUAL,
            1 days,
            1 days,
            1 days,
            2,
            100,
            0,
            false,
            false,
            new uint16[](0)
        );
    }

    function test_setTemplateActive_disables_template() public {
        // Verify initially active
        ContestFactoryV2.ContestTemplate memory t = factory.getTemplate(MEME_ID);
        assertTrue(t.isActive, "Meme template should start active");

        // Disable it
        factory.setTemplateActive(MEME_ID, false);

        t = factory.getTemplate(MEME_ID);
        assertFalse(t.isActive, "Meme template should be inactive");
    }

    function test_cannot_create_template_with_existing_id() public {
        // ELECTION_ID already exists from default templates
        vm.expectRevert("ContestFactoryV2: template exists");
        factory.createTemplate(
            ELECTION_ID,
            "Duplicate Election",
            ContestV2.ContestType.VOTE,
            ContestV2.PrizeModel.SINGLE_TOP,
            ContestV2.WinnerDetermination.PLURALITY,
            ContestV2.VoterRewardDistribution.EQUAL,
            1 days,
            1 days,
            1 days,
            2,
            100,
            0,
            false,
            false,
            new uint16[](0)
        );
    }

    // =========================================================================
    // 5. Admin functions (5 tests)
    // =========================================================================

    function test_setProtocolFee_within_range() public {
        // MAX_PROTOCOL_FEE_BPS = 500 (5%) per the contract's hard cap.
        factory.setProtocolFee(200); // 2%
        assertEq(factory.protocolFeePercentage(), 200, "Fee should be updated to 200");

        factory.setProtocolFee(0); // 0%
        assertEq(factory.protocolFeePercentage(), 0, "Fee should be updated to 0");

        factory.setProtocolFee(500); // 5% — at the cap
        assertEq(factory.protocolFeePercentage(), 500, "Fee should be updated to 500");
    }

    function test_setProtocolFee_over_max_reverts() public {
        vm.expectRevert("Fee exceeds maximum");
        factory.setProtocolFee(501);

        vm.expectRevert("Fee exceeds maximum");
        factory.setProtocolFee(5000);
    }

    function test_feeRecipient_isImmutable() public view {
        // Post-2026-04-28: setFeeRecipient was removed; feeRecipient is constructor-immutable.
        // The constructor enforces non-zero (line 124). Live contests are unaffected because
        // ContestV2 clones snapshot protocolFeeRecipient at initialize().
        assertTrue(factory.feeRecipient() != address(0));
    }

    function test_setImplementation_updates() public {
        ContestV2 newImpl = new ContestV2();
        factory.setImplementation(address(newImpl));
        assertEq(factory.contestImplementation(), address(newImpl), "Implementation should be updated");
    }

    function test_nonOwner_cannot_call_admin_functions() public {
        vm.startPrank(attacker);

        vm.expectRevert("Ownable: caller is not the owner");
        factory.setProtocolFee(100);

        // setFeeRecipient was removed 2026-04-28 — feeRecipient is immutable.

        vm.expectRevert("Ownable: caller is not the owner");
        factory.setImplementation(attacker);

        vm.expectRevert("Ownable: caller is not the owner");
        factory.setYieldVault(attacker);

        vm.expectRevert("Ownable: caller is not the owner");
        factory.setIdentityRegistry(attacker);

        vm.stopPrank();
    }

    // =========================================================================
    // 6. Edge cases (2 tests)
    // =========================================================================

    function test_multiple_contests_from_same_creator_tracked() public {
        // Create 3 contests from the same creator at different timestamps
        vm.prank(creator);
        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();
        params.metadataHash = keccak256("contest-1");
        (bytes32 id1,) = factory.createContestFromTemplate(ELECTION_ID, params);

        vm.warp(block.timestamp + 1);
        vm.prank(creator);
        params.metadataHash = keccak256("contest-2");
        (bytes32 id2,) = factory.createContestFromTemplate(ELECTION_ID, params);

        vm.warp(block.timestamp + 1);
        vm.prank(creator);
        params.metadataHash = keccak256("contest-3");
        (bytes32 id3,) = factory.createContestFromTemplate(ELECTION_ID, params);

        bytes32[] memory creatorIds = factory.getCreatorContests(creator);
        assertEq(creatorIds.length, 3, "Creator should have 3 contests");
        assertEq(creatorIds[0], id1);
        assertEq(creatorIds[1], id2);
        assertEq(creatorIds[2], id3);
        assertEq(factory.getContestCount(), 3, "Total count should be 3");
    }

    function test_contests_from_different_creators_tracked_separately() public {
        ContestFactoryV2.CreateContestParams memory params = _buildDefaultParams();
        params.metadataHash = keccak256("creator-contest");

        vm.prank(creator);
        (bytes32 idCreator,) = factory.createContestFromTemplate(ELECTION_ID, params);

        // Different sender at same timestamp produces different contest ID
        vm.prank(alice);
        (bytes32 idAlice,) = factory.createContestFromTemplate(ELECTION_ID, params);

        assertTrue(idCreator != idAlice, "Different creators should get different IDs");

        bytes32[] memory creatorIds = factory.getCreatorContests(creator);
        assertEq(creatorIds.length, 1, "Creator should have 1 contest");
        assertEq(creatorIds[0], idCreator);

        bytes32[] memory aliceIds = factory.getCreatorContests(alice);
        assertEq(aliceIds.length, 1, "Alice should have 1 contest");
        assertEq(aliceIds[0], idAlice);

        assertEq(factory.getContestCount(), 2, "Total count should be 2");
    }
}
