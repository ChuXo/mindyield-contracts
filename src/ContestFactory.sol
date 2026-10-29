// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IContestFactory.sol";
import "./interfaces/IContest.sol";
import "./Contest.sol";

/**
 * @title ContestFactory
 * @notice Factory for deploying and managing Contest contracts
 */
contract ContestFactory is IContestFactory, Ownable2Step {
    address public yieldVault;
    address public identityRegistry;
    address public randomnessManager;
    address public dataRegistry;

    uint256 public protocolFee; // Basis points (e.g., 1000 = 10%)
    address public treasury;

    // Contest tracking
    bytes32[] public allContestIds;
    mapping(bytes32 => address) public contests;
    mapping(address => bytes32[]) public creatorContests;

    uint256 private _contestNonce;

    /// @notice Maximum allowed total contest duration (depositStart to revealEnd)
    uint256 public constant MAX_CONTEST_DURATION = 365 days;

    error ContestAlreadyExists();
    error InvalidConfig();
    error ZeroAddress();

    constructor(
        address _yieldVault,
        address _identityRegistry,
        address _randomnessManager,
        address _dataRegistry,
        address _treasury
    ) Ownable() {
        yieldVault = _yieldVault;
        identityRegistry = _identityRegistry;
        randomnessManager = _randomnessManager;
        dataRegistry = _dataRegistry;
        treasury = _treasury;
        protocolFee = 1000; // 10% default
    }

    /**
     * @notice Create a new contest
     * @param config Contest configuration
     * @return contestId Unique identifier for the contest
     * @return contestAddress Address of the deployed contest
     */
    function createContest(
        IContest.ContestConfig calldata config
    ) external override returns (bytes32 contestId, address contestAddress) {
        // Validate config
        if (config.depositToken == address(0)) revert ZeroAddress();
        if (config.depositEnd <= config.depositStart) revert InvalidConfig();
        if (config.lockEnd <= config.depositEnd) revert InvalidConfig();
        if (config.revealEnd <= config.lockEnd) revert InvalidConfig();
        if (config.depositAmount == 0) revert InvalidConfig();
        if (config.revealEnd - config.depositStart > MAX_CONTEST_DURATION) revert InvalidConfig();

        // Generate unique contest ID
        contestId = keccak256(
            abi.encode(
                msg.sender,
                block.timestamp,
                _contestNonce++
            )
        );

        if (contests[contestId] != address(0)) revert ContestAlreadyExists();

        // Deploy contest (treasury stored per-contest to prevent mid-contest recipient changes)
        Contest contest = new Contest(
            contestId,
            config,
            msg.sender,
            yieldVault,
            identityRegistry,
            randomnessManager,
            dataRegistry,
            treasury
        );

        contestAddress = address(contest);
        contests[contestId] = contestAddress;
        allContestIds.push(contestId);
        creatorContests[msg.sender].push(contestId);

        // Register contest as allowed requester for randomness
        // Note: Factory must be authorized via RandomnessManager.setAuthorizedFactory() during deployment
        (bool success,) = randomnessManager.call(
            abi.encodeWithSignature("addAllowedRequester(address)", contestAddress)
        );
        require(success, "ContestFactory: VRF registration failed");

        emit ContestCreated(contestId, contestAddress, msg.sender, config);
    }

    /**
     * @notice Get contest address by ID
     */
    function getContest(bytes32 contestId) external view override returns (address) {
        return contests[contestId];
    }

    /**
     * @notice Get all contests created by an address
     */
    function getContestsByCreator(address creator) external view override returns (bytes32[] memory) {
        return creatorContests[creator];
    }

    /**
     * @notice Get all contest IDs
     */
    function getAllContests() external view override returns (bytes32[] memory) {
        return allContestIds;
    }

    /**
     * @notice Get total contest count
     */
    function getContestCount() external view override returns (uint256) {
        return allContestIds.length;
    }

    /**
     * @notice Set protocol fee (owner only)
     * @param fee Fee in basis points (max 5000 = 50%)
     */
    function setProtocolFee(uint256 fee) external override onlyOwner {
        require(fee <= 2000, "Fee too high"); // Max 20%, matching V2
        uint256 oldFee = protocolFee;
        protocolFee = fee;
        emit ProtocolFeeUpdated(oldFee, fee);
    }

    /**
     * @notice Get current protocol fee
     */
    function getProtocolFee() external view override returns (uint256) {
        return protocolFee;
    }

    /**
     * @notice Set treasury address (owner only)
     */
    function setTreasury(address _treasury) external override onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Get treasury address
     */
    function getTreasury() external view override returns (address) {
        return treasury;
    }

    /**
     * @notice Cancel a contest (owner only, emergency)
     */
    function cancelContest(bytes32 contestId, string calldata reason) external onlyOwner {
        address contestAddress = contests[contestId];
        require(contestAddress != address(0), "Contest not found");
        IContest(contestAddress).cancel(reason);
    }

    /**
     * @notice Update registry addresses (owner only)
     */
    function updateRegistries(
        address _yieldVault,
        address _identityRegistry,
        address _randomnessManager,
        address _dataRegistry
    ) external onlyOwner {
        if (_yieldVault != address(0)) {
            emit RegistryUpdated("yieldVault", yieldVault, _yieldVault);
            yieldVault = _yieldVault;
        }
        if (_identityRegistry != address(0)) {
            emit RegistryUpdated("identityRegistry", identityRegistry, _identityRegistry);
            identityRegistry = _identityRegistry;
        }
        if (_randomnessManager != address(0)) {
            emit RegistryUpdated("randomnessManager", randomnessManager, _randomnessManager);
            randomnessManager = _randomnessManager;
        }
        if (_dataRegistry != address(0)) {
            emit RegistryUpdated("dataRegistry", dataRegistry, _dataRegistry);
            dataRegistry = _dataRegistry;
        }
    }
}
