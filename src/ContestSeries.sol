// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./ContestFactoryV2.sol";

/**
 * @title ContestSeries
 * @notice Manages recurring contest series (weekly charts, monthly rankings, etc.)
 * @dev Automates contest creation and tracks series history
 */
contract ContestSeries is Ownable2Step {
    // ============ Structs ============

    struct Series {
        bytes32 id;
        string name;
        string description;
        address creator;

        // Template settings
        bytes32 templateId;
        address depositToken;
        uint256 depositAmount;

        // Recurrence settings
        RecurrenceType recurrenceType;
        uint256 intervalSeconds;          // For custom intervals
        uint256 depositPeriodSeconds;
        uint256 lockPeriodSeconds;
        uint256 revealPeriodSeconds;

        // Options management
        OptionsType optionsType;
        bytes32[] fixedOptions;           // For fixed option series
        uint256 maxOptionsPerEpisode;

        // Status
        bool isActive;
        uint256 currentEpisode;
        uint256 createdAt;
        uint256 lastEpisodeAt;
    }

    enum RecurrenceType {
        DAILY,
        WEEKLY,
        BIWEEKLY,
        MONTHLY,
        CUSTOM
    }

    enum OptionsType {
        FIXED,              // Same options every episode
        ROTATING,           // Options rotate from a pool
        SUBMITTED,          // Users submit options
        ORACLE_PROVIDED     // Oracle provides options
    }

    struct Episode {
        bytes32 seriesId;
        uint256 episodeNumber;
        bytes32 contestId;
        address contestAddress;
        uint256 createdAt;
        bytes32[] options;
        bool isFinalized;
        bytes32 winningOption;
        uint256 totalParticipants;
    }

    // ============ State Variables ============

    ContestFactoryV2 public contestFactory;

    mapping(bytes32 => Series) public series;
    bytes32[] public seriesIds;
    mapping(address => bytes32[]) public creatorSeries;

    mapping(bytes32 => Episode[]) public seriesEpisodes; // seriesId => episodes
    mapping(bytes32 => bytes32) public contestToSeries;  // contestId => seriesId
    mapping(bytes32 => uint256) public contestIdToEpisodeIndex; // contestId => index in seriesEpisodes

    // Option pools for rotating series
    mapping(bytes32 => bytes32[]) public optionPools;    // seriesId => available options

    // Automation
    mapping(bytes32 => bool) public autoCreateEnabled;
    uint256 public automationGasReserve;

    // ============ Events ============

    event SeriesCreated(bytes32 indexed seriesId, string name, address indexed creator);
    event SeriesUpdated(bytes32 indexed seriesId);
    event EpisodeCreated(bytes32 indexed seriesId, uint256 episodeNumber, bytes32 contestId);
    event EpisodeFinalized(bytes32 indexed seriesId, uint256 episodeNumber, bytes32 winningOption);
    event OptionsPoolUpdated(bytes32 indexed seriesId, uint256 optionCount);

    // ============ Constructor ============

    constructor(address _contestFactory) Ownable() {
        contestFactory = ContestFactoryV2(_contestFactory);
    }

    // ============ Series Management ============

    /**
     * @notice Create a new contest series
     */
    function createSeries(
        string calldata name,
        string calldata description,
        bytes32 templateId,
        address depositToken,
        uint256 depositAmount,
        RecurrenceType recurrenceType,
        uint256 intervalSeconds,
        uint256 depositPeriodSeconds,
        uint256 lockPeriodSeconds,
        uint256 revealPeriodSeconds,
        OptionsType optionsType,
        bytes32[] calldata initialOptions
    ) external returns (bytes32 seriesId) {
        seriesId = keccak256(abi.encodePacked(msg.sender, name, block.timestamp));
        require(series[seriesId].createdAt == 0, "ContestSeries: series exists");

        series[seriesId] = Series({
            id: seriesId,
            name: name,
            description: description,
            creator: msg.sender,
            templateId: templateId,
            depositToken: depositToken,
            depositAmount: depositAmount,
            recurrenceType: recurrenceType,
            intervalSeconds: intervalSeconds,
            depositPeriodSeconds: depositPeriodSeconds,
            lockPeriodSeconds: lockPeriodSeconds,
            revealPeriodSeconds: revealPeriodSeconds,
            optionsType: optionsType,
            fixedOptions: initialOptions,
            maxOptionsPerEpisode: initialOptions.length > 0 ? initialOptions.length : 10,
            isActive: true,
            currentEpisode: 0,
            createdAt: block.timestamp,
            lastEpisodeAt: 0
        });

        if (optionsType == OptionsType.ROTATING) {
            optionPools[seriesId] = initialOptions;
        }

        seriesIds.push(seriesId);
        creatorSeries[msg.sender].push(seriesId);

        emit SeriesCreated(seriesId, name, msg.sender);

        return seriesId;
    }

    /**
     * @notice Create next episode in series
     */
    function createEpisode(
        bytes32 seriesId,
        bytes32[] calldata episodeOptions,
        string calldata metadataUri
    ) external returns (bytes32 contestId, address contestAddress) {
        Series storage s = series[seriesId];
        require(s.createdAt > 0, "ContestSeries: series not found");
        require(s.isActive, "ContestSeries: series not active");
        require(
            msg.sender == s.creator || msg.sender == owner(),
            "ContestSeries: not authorized"
        );

        // Check timing
        if (s.lastEpisodeAt > 0) {
            uint256 nextAllowedTime = s.lastEpisodeAt + _getIntervalSeconds(s);
            require(block.timestamp >= nextAllowedTime, "ContestSeries: too soon");
        }

        // Determine options
        bytes32[] memory options;
        if (s.optionsType == OptionsType.FIXED) {
            options = s.fixedOptions;
        } else if (s.optionsType == OptionsType.ROTATING) {
            options = _selectRotatingOptions(seriesId);
        } else {
            require(episodeOptions.length >= 2, "ContestSeries: need at least 2 options");
            options = episodeOptions;
        }

        // Calculate timing
        uint256 depositStart = block.timestamp;
        uint256 depositEnd = depositStart + s.depositPeriodSeconds;
        uint256 lockEnd = depositEnd + s.lockPeriodSeconds;
        uint256 revealEnd = lockEnd + s.revealPeriodSeconds;

        // Build metadata hash
        bytes32 metadataHash = keccak256(abi.encodePacked(
            seriesId,
            s.currentEpisode + 1,
            metadataUri
        ));

        // Create contest through factory
        // NOTE: Known limitation — the contest's on-chain `creator` will be this ContestSeries
        // contract (msg.sender in the factory), not the original series creator. The factory's
        // createContestFromTemplate does not accept a creator passthrough parameter. The series
        // creator is tracked off-chain via s.creator and in the Episode struct's seriesId.
        ContestFactoryV2.CreateContestParams memory params = ContestFactoryV2.CreateContestParams({
            depositToken: s.depositToken,
            depositAmount: s.depositAmount,
            metadataHash: metadataHash,
            metadataUri: metadataUri,
            options: options,
            depositStart: depositStart,
            depositEnd: depositEnd,
            lockEnd: lockEnd,
            revealEnd: revealEnd,
            minParticipants: 0,
            maxParticipants: 0,
            tierRequired: 0,
            quorumPercentage: 0,
            oracle: address(0),
            correlationThreshold: 0,
            topPercentile: 0,
            confidenceMultiplier: 0,
            earlyVoterBonus: 0,
            creatorPrize: 0,
            // Empty prize-config overrides → use template defaults
            splitsBps: new uint16[](0),
            eligibilityThreshold: 0,
            weightedByScore: false,
            overrideWeightedByScore: false
        });

        (contestId, contestAddress) = contestFactory.createContestFromTemplate(
            s.templateId,
            params
        );

        // Record episode
        s.currentEpisode++;
        s.lastEpisodeAt = block.timestamp;

        Episode memory episode = Episode({
            seriesId: seriesId,
            episodeNumber: s.currentEpisode,
            contestId: contestId,
            contestAddress: contestAddress,
            createdAt: block.timestamp,
            options: options,
            isFinalized: false,
            winningOption: bytes32(0),
            totalParticipants: 0
        });

        contestIdToEpisodeIndex[contestId] = seriesEpisodes[seriesId].length;
        seriesEpisodes[seriesId].push(episode);
        contestToSeries[contestId] = seriesId;

        emit EpisodeCreated(seriesId, s.currentEpisode, contestId);

        return (contestId, contestAddress);
    }

    /**
     * @notice Record episode finalization (called after contest resolves)
     */
    function finalizeEpisode(
        bytes32 contestId,
        bytes32 winningOption,
        uint256 totalParticipants
    ) external {
        bytes32 seriesId = contestToSeries[contestId];
        require(seriesId != bytes32(0), "ContestSeries: not a series contest");

        Series storage s = series[seriesId];
        require(
            msg.sender == s.creator || msg.sender == owner(),
            "ContestSeries: not authorized"
        );

        // O(1) lookup via contestIdToEpisodeIndex mapping
        uint256 episodeIdx = contestIdToEpisodeIndex[contestId];
        Episode[] storage episodes = seriesEpisodes[seriesId];
        require(episodeIdx < episodes.length, "ContestSeries: episode not found");
        require(episodes[episodeIdx].contestId == contestId, "ContestSeries: index mismatch");

        episodes[episodeIdx].isFinalized = true;
        episodes[episodeIdx].winningOption = winningOption;
        episodes[episodeIdx].totalParticipants = totalParticipants;

        emit EpisodeFinalized(seriesId, episodes[episodeIdx].episodeNumber, winningOption);
    }

    // ============ Options Management ============

    /**
     * @notice Update options pool for rotating series
     */
    function updateOptionsPool(
        bytes32 seriesId,
        bytes32[] calldata newOptions
    ) external {
        Series storage s = series[seriesId];
        require(s.creator == msg.sender || msg.sender == owner(), "ContestSeries: not authorized");
        require(s.optionsType == OptionsType.ROTATING, "ContestSeries: not rotating");

        optionPools[seriesId] = newOptions;
        emit OptionsPoolUpdated(seriesId, newOptions.length);
    }

    /**
     * @notice Add options to pool
     */
    function addToOptionsPool(
        bytes32 seriesId,
        bytes32[] calldata options
    ) external {
        Series storage s = series[seriesId];
        require(s.creator == msg.sender || msg.sender == owner(), "ContestSeries: not authorized");

        for (uint256 i = 0; i < options.length; i++) {
            optionPools[seriesId].push(options[i]);
        }

        emit OptionsPoolUpdated(seriesId, optionPools[seriesId].length);
    }

    // ============ Series Control ============

    /**
     * @notice Pause/unpause series
     */
    function setSeriesActive(bytes32 seriesId, bool active) external {
        Series storage s = series[seriesId];
        require(s.creator == msg.sender || msg.sender == owner(), "ContestSeries: not authorized");
        s.isActive = active;
        emit SeriesUpdated(seriesId);
    }

    /**
     * @notice Update series timing
     */
    function updateSeriesTiming(
        bytes32 seriesId,
        uint256 depositPeriodSeconds,
        uint256 lockPeriodSeconds,
        uint256 revealPeriodSeconds
    ) external {
        Series storage s = series[seriesId];
        require(s.creator == msg.sender || msg.sender == owner(), "ContestSeries: not authorized");

        s.depositPeriodSeconds = depositPeriodSeconds;
        s.lockPeriodSeconds = lockPeriodSeconds;
        s.revealPeriodSeconds = revealPeriodSeconds;

        emit SeriesUpdated(seriesId);
    }

    // ============ View Functions ============

    /**
     * @notice Get series details
     */
    function getSeries(bytes32 seriesId) external view returns (Series memory) {
        return series[seriesId];
    }

    /**
     * @notice Get all episodes for a series
     */
    function getEpisodes(bytes32 seriesId) external view returns (Episode[] memory) {
        return seriesEpisodes[seriesId];
    }

    /**
     * @notice Get latest episode
     */
    function getLatestEpisode(bytes32 seriesId) external view returns (Episode memory) {
        Episode[] storage episodes = seriesEpisodes[seriesId];
        require(episodes.length > 0, "ContestSeries: no episodes");
        return episodes[episodes.length - 1];
    }

    /**
     * @notice Check if new episode can be created
     */
    function canCreateEpisode(bytes32 seriesId) external view returns (bool, uint256 nextTime) {
        Series storage s = series[seriesId];
        if (!s.isActive || s.createdAt == 0) {
            return (false, 0);
        }

        if (s.lastEpisodeAt == 0) {
            return (true, block.timestamp);
        }

        nextTime = s.lastEpisodeAt + _getIntervalSeconds(s);
        return (block.timestamp >= nextTime, nextTime);
    }

    /**
     * @notice Get series count
     */
    function getSeriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    /**
     * @notice Get creator's series
     */
    function getCreatorSeries(address creator) external view returns (bytes32[] memory) {
        return creatorSeries[creator];
    }

    /**
     * @notice Get options pool
     */
    function getOptionsPool(bytes32 seriesId) external view returns (bytes32[] memory) {
        return optionPools[seriesId];
    }

    // ============ Internal Functions ============

    function _getIntervalSeconds(Series storage s) internal view returns (uint256) {
        if (s.recurrenceType == RecurrenceType.DAILY) return 1 days;
        if (s.recurrenceType == RecurrenceType.WEEKLY) return 7 days;
        if (s.recurrenceType == RecurrenceType.BIWEEKLY) return 14 days;
        if (s.recurrenceType == RecurrenceType.MONTHLY) return 30 days;
        return s.intervalSeconds;
    }

    function _selectRotatingOptions(bytes32 seriesId) internal view returns (bytes32[] memory) {
        bytes32[] storage pool = optionPools[seriesId];
        require(pool.length > 0, "ContestSeries: empty option pool");
        Series storage s = series[seriesId];

        uint256 count = s.maxOptionsPerEpisode;
        if (count > pool.length) count = pool.length;

        bytes32[] memory selected = new bytes32[](count);

        // Simple deterministic rotation based on episode number.
        // NOTE: This rotation is predictable — participants can anticipate future options.
        // For use cases requiring unpredictability, consider integrating Chainlink VRF
        // to randomly select from the pool in future versions.
        uint256 startIdx = (s.currentEpisode * count) % pool.length;

        for (uint256 i = 0; i < count; i++) {
            selected[i] = pool[(startIdx + i) % pool.length];
        }

        return selected;
    }

    // ============ Admin Functions ============

    function setContestFactory(address _factory) external onlyOwner {
        contestFactory = ContestFactoryV2(_factory);
    }
}
