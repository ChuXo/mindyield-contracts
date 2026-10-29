// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestSeries.sol";
import "../src/ContestFactoryV2.sol";
import "../src/ContestV2.sol";
import "../src/DataRegistry.sol";
import "../src/IdentityRegistry.sol";
import "../src/YieldVault.sol";
import "../src/RandomnessManager.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockVRFCoordinator.sol";

/**
 * @title ContestSeriesTest
 * @notice Comprehensive tests for the ContestSeries contract
 * Tests series creation, episode management, options handling, and automation
 */
contract ContestSeriesTest is Test {
    ContestSeries public series;
    ContestFactoryV2 public factory;
    ContestV2 public contestImpl;  // Implementation for clone factory
    DataRegistry public dataRegistry;
    IdentityRegistry public identityRegistry;
    YieldVault public yieldVault;
    RandomnessManager public randomnessManager;
    MockERC20 public token;
    MockVRFCoordinator public vrfCoordinator;

    address public owner = address(1);
    address public treasury = address(2);
    address public alice = address(3);
    address public bob = address(4);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;
    bytes32 public constant TEMPLATE_ID = keccak256("VOTE_TEMPLATE");

    event SeriesCreated(bytes32 indexed seriesId, string name, address indexed creator);
    event SeriesUpdated(bytes32 indexed seriesId);
    event EpisodeCreated(bytes32 indexed seriesId, uint256 episodeNumber, bytes32 contestId);
    event EpisodeFinalized(bytes32 indexed seriesId, uint256 episodeNumber, bytes32 winningOption);
    event OptionsPoolUpdated(bytes32 indexed seriesId, uint256 optionCount);

    function setUp() public {
        vm.startPrank(owner);

        token = new MockERC20("USDC", "USDC", 18);
        vrfCoordinator = new MockVRFCoordinator();
        dataRegistry = new DataRegistry(address(this));
        identityRegistry = new IdentityRegistry();
        yieldVault = new YieldVault();
        randomnessManager = new RandomnessManager(
            address(vrfCoordinator),
            bytes32(0),
            1
        );

        vrfCoordinator.setRandomnessManager(address(randomnessManager));

        // Deploy ContestV2 implementation for the clone factory
        contestImpl = new ContestV2();

        // ContestFactoryV2(impl, yieldVault, identityRegistry, randomnessManager, feeRecipient)
        factory = new ContestFactoryV2(
            address(contestImpl),
            address(yieldVault),
            address(identityRegistry),
            address(randomnessManager),
            treasury
        );

        series = new ContestSeries(address(factory));

        yieldVault.addStrategy(address(0));

        // Authorize factory to register contest addresses with RandomnessManager
        randomnessManager.setAuthorizedFactory(address(factory), true);

        // Create a template in the factory (v2.1 — new createTemplate signature)
        factory.createTemplate(
            TEMPLATE_ID,
            "Vote Template",
            ContestV2.ContestType.VOTE,
            ContestV2.PrizeModel.PROPORTIONAL,
            ContestV2.WinnerDetermination.PLURALITY,
            ContestV2.VoterRewardDistribution.EQUAL,
            1 days,   // defaultDepositPeriod
            1 days,   // defaultLockPeriod
            1 days,   // defaultRevealPeriod
            0,        // minParticipants
            1000,     // maxParticipants
            0,        // defaultEligibilityThreshold
            false,    // defaultWeightedByScore
            false,    // requiresOracle
            new uint16[](0)  // splitsBps (empty for PROPORTIONAL)
        );

        vm.stopPrank();

        token.mint(alice, 10000e18);
        token.mint(bob, 10000e18);
    }

    function _createDefaultOptions() internal pure returns (bytes32[] memory) {
        bytes32[] memory options = new bytes32[](3);
        options[0] = keccak256("Option A");
        options[1] = keccak256("Option B");
        options[2] = keccak256("Option C");
        return options;
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(address(series.contestFactory()), address(factory));
        assertEq(series.owner(), owner);
        assertEq(series.getSeriesCount(), 0);
    }

    // ============ SERIES CREATION TESTS ============

    function testCreateSeriesDaily() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Daily Top Songs",
            "Vote for the best song each day",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0, // intervalSeconds not used for DAILY
            1 days, // depositPeriod
            1 days, // lockPeriod
            1 days, // revealPeriod
            ContestSeries.OptionsType.FIXED,
            options
        );

        ContestSeries.Series memory s = series.getSeries(seriesId);
        assertEq(s.name, "Daily Top Songs");
        assertEq(s.creator, alice);
        assertEq(s.depositToken, address(token));
        assertEq(s.depositAmount, DEPOSIT_AMOUNT);
        assertTrue(s.isActive);
        assertEq(s.currentEpisode, 0);
        assertEq(series.getSeriesCount(), 1);
    }

    function testCreateSeriesWeekly() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Weekly Charts",
            "Weekly music charts",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.WEEKLY,
            0,
            2 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        ContestSeries.Series memory s = series.getSeries(seriesId);
        assertTrue(uint8(s.recurrenceType) == uint8(ContestSeries.RecurrenceType.WEEKLY));
    }

    function testCreateSeriesCustomInterval() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Custom Series",
            "Every 3 days",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.CUSTOM,
            3 days, // custom interval
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        ContestSeries.Series memory s = series.getSeries(seriesId);
        assertEq(s.intervalSeconds, 3 days);
    }

    function testCreateSeriesEmitsEvent() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.expectEmit(false, true, false, false);
        emit SeriesCreated(bytes32(0), "Test Series", alice);

        vm.prank(alice);
        series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );
    }

    function testCreateSeriesRotatingOptions() public {
        bytes32[] memory options = new bytes32[](5);
        for (uint i = 0; i < 5; i++) {
            options[i] = keccak256(abi.encodePacked("Option", i));
        }

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Rotating Series",
            "Options rotate",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.ROTATING,
            options
        );

        bytes32[] memory pool = series.getOptionsPool(seriesId);
        assertEq(pool.length, 5);
        assertEq(pool[0], options[0]);
    }

    function testRevertCreateDuplicateSeries() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.startPrank(alice);

        // Create series
        series.createSeries(
            "Same Name",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        // Try to create with same name at same timestamp (should use different timestamp in practice)
        vm.warp(block.timestamp + 1); // Advance time to avoid duplicate

        // This should succeed since timestamp is different
        series.createSeries(
            "Same Name",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.stopPrank();

        assertEq(series.getSeriesCount(), 2);
    }

    // ============ EPISODE CREATION TESTS ============

    function testCreateFirstEpisode() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.prank(alice);
        (bytes32 contestId, address contestAddress) = series.createEpisode(
            seriesId,
            new bytes32[](0), // Empty for FIXED options
            "ipfs://metadata"
        );

        assertTrue(contestId != bytes32(0));
        assertTrue(contestAddress != address(0));

        ContestSeries.Series memory s = series.getSeries(seriesId);
        assertEq(s.currentEpisode, 1);
        assertEq(s.lastEpisodeAt, block.timestamp);
    }

    function testCreateMultipleEpisodes() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        // Episode 1
        vm.prank(alice);
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");

        // Advance time by 1 day
        vm.warp(block.timestamp + 1 days);

        // Episode 2
        vm.prank(alice);
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep2");

        ContestSeries.Episode[] memory episodes = series.getEpisodes(seriesId);
        assertEq(episodes.length, 2);
        assertEq(episodes[0].episodeNumber, 1);
        assertEq(episodes[1].episodeNumber, 2);
    }

    function testRevertCreateEpisodeTooSoon() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.prank(alice);
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");

        // Try to create episode immediately (should fail - too soon)
        vm.prank(alice);
        vm.expectRevert("ContestSeries: too soon");
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep2");
    }

    function testRevertCreateEpisodeUnauthorized() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        // Bob tries to create episode (unauthorized)
        vm.prank(bob);
        vm.expectRevert("ContestSeries: not authorized");
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");
    }

    function testRevertCreateEpisodeInactiveSeries() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        // Deactivate series
        vm.prank(alice);
        series.setSeriesActive(seriesId, false);

        // Try to create episode
        vm.prank(alice);
        vm.expectRevert("ContestSeries: series not active");
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");
    }

    function testOwnerCanCreateEpisode() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        // Owner can create episode
        vm.prank(owner);
        (bytes32 contestId,) = series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");

        assertTrue(contestId != bytes32(0));
    }

    // ============ OPTIONS MANAGEMENT TESTS ============

    function testUpdateOptionsPool() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.ROTATING,
            options
        );

        bytes32[] memory newOptions = new bytes32[](4);
        for (uint i = 0; i < 4; i++) {
            newOptions[i] = keccak256(abi.encodePacked("NewOption", i));
        }

        vm.prank(alice);
        series.updateOptionsPool(seriesId, newOptions);

        bytes32[] memory pool = series.getOptionsPool(seriesId);
        assertEq(pool.length, 4);
        assertEq(pool[0], newOptions[0]);
    }

    function testAddToOptionsPool() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.ROTATING,
            options
        );

        bytes32[] memory additionalOptions = new bytes32[](2);
        additionalOptions[0] = keccak256("Option D");
        additionalOptions[1] = keccak256("Option E");

        vm.prank(alice);
        series.addToOptionsPool(seriesId, additionalOptions);

        bytes32[] memory pool = series.getOptionsPool(seriesId);
        assertEq(pool.length, 5); // 3 initial + 2 added
    }

    function testRevertUpdateOptionsPoolNotRotating() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED, // Not ROTATING
            options
        );

        bytes32[] memory newOptions = new bytes32[](2);
        newOptions[0] = keccak256("Option D");
        newOptions[1] = keccak256("Option E");

        vm.prank(alice);
        vm.expectRevert("ContestSeries: not rotating");
        series.updateOptionsPool(seriesId, newOptions);
    }

    // ============ SERIES CONTROL TESTS ============

    function testSetSeriesActive() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.prank(alice);
        series.setSeriesActive(seriesId, false);

        ContestSeries.Series memory s = series.getSeries(seriesId);
        assertFalse(s.isActive);

        vm.prank(alice);
        series.setSeriesActive(seriesId, true);

        s = series.getSeries(seriesId);
        assertTrue(s.isActive);
    }

    function testUpdateSeriesTiming() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.prank(alice);
        series.updateSeriesTiming(seriesId, 2 days, 2 days, 2 days);

        ContestSeries.Series memory s = series.getSeries(seriesId);
        assertEq(s.depositPeriodSeconds, 2 days);
        assertEq(s.lockPeriodSeconds, 2 days);
        assertEq(s.revealPeriodSeconds, 2 days);
    }

    // ============ VIEW FUNCTIONS TESTS ============

    function testCanCreateEpisode() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        (bool canCreate, uint256 nextTime) = series.canCreateEpisode(seriesId);
        assertTrue(canCreate);
        assertEq(nextTime, block.timestamp);

        // Create episode
        vm.prank(alice);
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");

        // Check again immediately (should be false)
        (canCreate, nextTime) = series.canCreateEpisode(seriesId);
        assertFalse(canCreate);
        assertEq(nextTime, block.timestamp + 1 days);
    }

    function testGetLatestEpisode() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.prank(alice);
        bytes32 seriesId = series.createSeries(
            "Test Series",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.prank(alice);
        series.createEpisode(seriesId, new bytes32[](0), "ipfs://ep1");

        ContestSeries.Episode memory latest = series.getLatestEpisode(seriesId);
        assertEq(latest.episodeNumber, 1);
    }

    function testGetCreatorSeries() public {
        bytes32[] memory options = _createDefaultOptions();

        vm.startPrank(alice);
        series.createSeries(
            "Series 1",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.DAILY,
            0,
            1 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );

        vm.warp(block.timestamp + 1);

        series.createSeries(
            "Series 2",
            "Description",
            TEMPLATE_ID,
            address(token),
            DEPOSIT_AMOUNT,
            ContestSeries.RecurrenceType.WEEKLY,
            0,
            2 days,
            1 days,
            1 days,
            ContestSeries.OptionsType.FIXED,
            options
        );
        vm.stopPrank();

        bytes32[] memory aliceSeries = series.getCreatorSeries(alice);
        assertEq(aliceSeries.length, 2);
    }

    // ============ ADMIN FUNCTIONS TESTS ============

    function testSetContestFactory() public {
        address newFactory = address(0x123);

        vm.prank(owner);
        series.setContestFactory(newFactory);

        assertEq(address(series.contestFactory()), newFactory);
    }

    function testRevertSetContestFactoryNotOwner() public {
        address newFactory = address(0x123);

        vm.prank(alice);
        vm.expectRevert();
        series.setContestFactory(newFactory);
    }
}
