// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ContestV2TestBase.sol";
import "../src/interfaces/IResolver.sol";

/// @dev Scripted resolver — tests drive `setOutcome` to simulate ready/not-ready,
///      specific winners, and the ambiguous sentinel.
contract MockResolver is IResolver {
    mapping(bytes32 => bool) public ready;
    mapping(bytes32 => bytes32) public winner;
    mapping(bytes32 => bool) public registered;

    uint256 public registerCallCount;

    function setOutcome(bytes32 contestId, bool _ready, bytes32 _winner) external {
        ready[contestId] = _ready;
        winner[contestId] = _winner;
    }

    // ─── IResolver ─────────────────────────────────────────────────────────

    function register(bytes32 contestId, bytes calldata /* params */) external {
        registered[contestId] = true;
        registerCallCount++;
    }

    function requestSettlement(bytes32 /* contestId */) external pure returns (bool) {
        return false;
    }

    function resolve(bytes32 contestId) external view returns (bool, bytes32) {
        return (ready[contestId], winner[contestId]);
    }

    function settlementTimeout() external pure returns (uint64) {
        return 24 hours;
    }

    function resolverType() external pure returns (bytes32) {
        return keccak256("MockResolver.test");
    }
}

contract ContestV2ResolverTest is ContestV2TestBase {
    MockResolver public resolverMock;

    function setUp() public override {
        super.setUp();
        resolverMock = new MockResolver();
        vm.label(address(resolverMock), "MockResolver");
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// @notice Create a VOTE contest bound to the MockResolver.
    function _createVoteContestWithResolver() internal returns (address contestAddr) {
        uint256 t = block.timestamp;
        uint256 nonce = _contestNonce++;

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
            metadataHash:            keccak256(abi.encodePacked("resolver-test-", t, nonce)),
            metadataUri:             "ipfs://test"
        });

        ContestV2.PrizeConfig memory prizeCfg = _defaultPrizeConfigForModel(
            ContestV2.PrizeModel.PROPORTIONAL
        );
        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0,
            topPercentile:        2500,
            confidenceMultiplier: 5000,
            earlyVoterBonus:      0
        });
        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig({
            enabled:                 false,
            submissionStart:         0,
            submissionEnd:           0,
            maxPerUser:              0,
            requiresModeration:      false,
            paymentModel:            ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0,
            minSubmissions:          0,
            maxTotalSubmissions:     0
        });

        bytes32[] memory opts = _defaultOptions();

        vm.prank(creator);
        (, contestAddr) = factory.createCustomContestWithResolver(
            config, prizeCfg, scoring, subCfg,
            address(0), // no legacy oracle
            opts,
            0,                       // no creator prize
            address(resolverMock),   // NEW: resolver
            ""                        // empty resolver params
        );

        vm.label(contestAddr, "ResolverContest");
    }

    /// @notice Run a full VOTE lifecycle where majority picks `crowdPick`.
    function _runLifecycleMajority(address contest, bytes32 crowdPick, bytes32 minorityPick) internal {
        // alice, bob, charlie pick crowdPick; dave picks minorityPick.
        _deposit(alice, contest);
        _deposit(bob, contest);
        _deposit(charlie, contest);
        _deposit(dave, contest);

        bytes32 salt = keccak256("salt");
        _commitVote(alice,   contest, _makeVoteData_VOTE(crowdPick),    salt);
        _commitVote(bob,     contest, _makeVoteData_VOTE(crowdPick),    salt);
        _commitVote(charlie, contest, _makeVoteData_VOTE(crowdPick),    salt);
        _commitVote(dave,    contest, _makeVoteData_VOTE(minorityPick), salt);

        _advancePastLock(contest);

        _revealVote(alice,   contest, _makeVoteData_VOTE(crowdPick),    salt);
        _revealVote(bob,     contest, _makeVoteData_VOTE(crowdPick),    salt);
        _revealVote(charlie, contest, _makeVoteData_VOTE(crowdPick),    salt);
        _revealVote(dave,    contest, _makeVoteData_VOTE(minorityPick), salt);

        _advancePastReveal(contest);
    }

    // ─── Core tests ────────────────────────────────────────────────────────

    function test_resolverBinding_isRegisteredAtCreation() public {
        address contest = _createVoteContestWithResolver();
        bytes32 cid = bytes32(uint256(uint160(contest)));
        assertTrue(resolverMock.registered(cid), "resolver.register not called at creation");
        assertEq(
            factory.resolverForContest(contest),
            address(resolverMock),
            "factory should store resolver binding"
        );
    }

    function test_resolver_overridesPlurality() public {
        address contest = _createVoteContestWithResolver();
        _runLifecycleMajority(contest, OPT_A, OPT_B); // 3 vote A, 1 votes B

        // Resolver says B won — opposite of crowd.
        bytes32 cid = bytes32(uint256(uint160(contest)));
        resolverMock.setOutcome(cid, true, OPT_B);

        vm.prank(creator);
        ContestV2(contest).resolveContest();

        assertEq(_getState(contest), STATE_FINALIZED);
        assertEq(
            ContestV2(contest).getResults().winningOption,
            OPT_B,
            "resolver answer must override plurality"
        );

        // Dave (voted B, the minority) should be the only winner. The auto-getter
        // for `participants` was removed in the 2026-04 slim-down; use the
        // explicit `getParticipant(addr)` view that returns the full struct.
        uint256 daveScore = ContestV2(contest).getParticipant(dave).score;
        uint256 aliceScore = ContestV2(contest).getParticipant(alice).score;
        assertGt(daveScore, 0, "dave voted resolver winner, should score > 0");
        assertEq(aliceScore, 0, "alice voted crowd winner (wrong), should score 0");
    }

    function test_resolver_notReadyReverts() public {
        address contest = _createVoteContestWithResolver();
        _runLifecycleMajority(contest, OPT_A, OPT_B);

        // Resolver not ready — leave default (ready=false).
        vm.prank(creator);
        vm.expectRevert(ContestV2.ResolverNotReady.selector);
        ContestV2(contest).resolveContest();

        // The revert rolls back ALL state changes in the tx — including the
        // REVEAL_OPEN -> RESOLVING transition at the top of resolveContest().
        // So the contest stays in REVEAL_OPEN and can simply be retried.
        assertEq(_getState(contest), STATE_REVEAL_OPEN);

        // Now resolver becomes ready — retry succeeds.
        bytes32 cid = bytes32(uint256(uint160(contest)));
        resolverMock.setOutcome(cid, true, OPT_A);

        vm.prank(creator);
        ContestV2(contest).resolveContest();
        assertEq(_getState(contest), STATE_FINALIZED);
    }

    function test_resolver_ambiguousOutcomeCancels() public {
        address contest = _createVoteContestWithResolver();
        _runLifecycleMajority(contest, OPT_A, OPT_B);

        // Ambiguous sentinel (bytes32(0)) — e.g. UMA 50/50.
        bytes32 cid = bytes32(uint256(uint160(contest)));
        resolverMock.setOutcome(cid, true, bytes32(0));

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(creator);
        ContestV2(contest).resolveContest();

        assertEq(_getState(contest), STATE_CANCELLED, "ambiguous must cancel");

        // Alice can withdraw her principal.
        vm.prank(alice);
        ContestV2(contest).withdrawPrincipal();
        assertEq(
            usdc.balanceOf(alice),
            aliceBalanceBefore + DEFAULT_DEPOSIT_AMOUNT,
            "alice should recover full deposit after ambiguous cancel"
        );
    }

    function test_resolver_invalidOptionReverts() public {
        address contest = _createVoteContestWithResolver();
        _runLifecycleMajority(contest, OPT_A, OPT_B);

        // Resolver returns a bytes32 that isn't in the option set.
        bytes32 cid = bytes32(uint256(uint160(contest)));
        resolverMock.setOutcome(cid, true, keccak256("not-an-option"));

        vm.prank(creator);
        vm.expectRevert(ContestV2.InvalidOption.selector);
        ContestV2(contest).resolveContest();
    }

    function test_nonResolverContest_stillResolvesByPlurality() public {
        // Sanity: contests created via the ORIGINAL (non-resolver) factory
        // path keep the pre-resolver behavior — plurality wins.
        address contest = _createContest(
            TYPE_VOTE,
            WINNER_PLURALITY,
            PRIZE_PROPORTIONAL
        );
        _runLifecycleMajority(contest, OPT_A, OPT_B);

        // Factory has no resolver binding for this contest.
        assertEq(factory.resolverForContest(contest), address(0));

        vm.prank(creator);
        ContestV2(contest).resolveContest();

        assertEq(
            ContestV2(contest).getResults().winningOption,
            OPT_A,
            "no resolver -> plurality wins (3 A vs 1 B)"
        );
    }

    function test_zeroResolver_factoryReverts() public {
        // createCustomContestWithResolver must reject a zero resolver.
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
            metadataHash:            keccak256("zero-resolver"),
            metadataUri:             "ipfs://test"
        });
        ContestV2.PrizeConfig memory prizeCfg = _defaultPrizeConfigForModel(
            ContestV2.PrizeModel.PROPORTIONAL
        );
        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0, topPercentile: 2500, confidenceMultiplier: 5000, earlyVoterBonus: 0
        });
        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig({
            enabled: false, submissionStart: 0, submissionEnd: 0, maxPerUser: 0,
            requiresModeration: false, paymentModel: ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0, minSubmissions: 0, maxTotalSubmissions: 0
        });
        bytes32[] memory opts = _defaultOptions();

        vm.prank(creator);
        vm.expectRevert("ContestFactoryV2: zero resolver");
        factory.createCustomContestWithResolver(
            config, prizeCfg, scoring, subCfg,
            address(0), opts, 0,
            address(0), // zero resolver — should revert
            ""
        );
    }
}
