// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title IOracleProvider
 * @notice Interface for oracle data providers
 */
interface IOracleProvider {
    function getData(bytes32 dataId) external view returns (bytes memory data, uint256 timestamp);
    function isDataAvailable(bytes32 dataId) external view returns (bool);
    function getProviderName() external view returns (string memory);
}

/**
 * @title OracleRegistry
 * @notice Registry and aggregator for contest resolution oracles
 * @dev Manages multiple oracle providers for different data types
 */
contract OracleRegistry is Ownable2Step, AccessControl {
    // ============ Roles ============

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant REQUESTER_ROLE = keccak256("REQUESTER_ROLE");

    // ============ Structs ============

    struct OracleProvider {
        address providerAddress;
        string name;
        string dataType;       // e.g., "sports", "price", "election", "general"
        bool isActive;
        uint256 reputation;    // Track reliability
        uint256 totalReports;
        uint256 disputedReports;
    }

    struct DataRequest {
        bytes32 requestId;
        bytes32 contestId;
        string dataType;
        bytes queryData;
        uint256 requestedAt;
        uint256 deadline;
        bool isFulfilled;
        bytes result;
        address fulfilledBy;
    }

    struct ManualResolution {
        bytes32 contestId;
        bytes result;
        string reason;
        uint256 timestamp;
        address resolver;
        bool isDisputed;
    }

    // ============ State Variables ============

    mapping(bytes32 => OracleProvider) public providers;
    bytes32[] public providerIds;
    mapping(address => bytes32) private _providerAddressToId;

    mapping(bytes32 => DataRequest) public dataRequests;
    bytes32[] public requestIds;

    mapping(bytes32 => ManualResolution) public manualResolutions;

    // Data type to provider mapping
    mapping(string => bytes32[]) public dataTypeProviders;

    // Contest to resolution mapping
    mapping(bytes32 => bytes32) public contestResolutions; // contestId => requestId

    // ============ Events ============

    event ProviderRegistered(bytes32 indexed providerId, address provider, string dataType);
    event ProviderUpdated(bytes32 indexed providerId, bool isActive);
    event DataRequested(bytes32 indexed requestId, bytes32 indexed contestId, string dataType);
    event DataFulfilled(bytes32 indexed requestId, bytes result, address fulfilledBy);
    event ManualResolutionSubmitted(bytes32 indexed contestId, bytes result, string reason);
    event ResolutionDisputed(bytes32 indexed contestId, address disputedBy);

    // ============ Constructor ============

    constructor() Ownable() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RESOLVER_ROLE, msg.sender);
        _grantRole(REQUESTER_ROLE, msg.sender);
    }

    // ============ Provider Management ============

    /**
     * @notice Register an oracle provider
     */
    function registerProvider(
        bytes32 providerId,
        address providerAddress,
        string calldata name,
        string calldata dataType
    ) external onlyOwner {
        require(providers[providerId].providerAddress == address(0), "OracleRegistry: provider exists");

        providers[providerId] = OracleProvider({
            providerAddress: providerAddress,
            name: name,
            dataType: dataType,
            isActive: true,
            reputation: 100,
            totalReports: 0,
            disputedReports: 0
        });

        providerIds.push(providerId);
        dataTypeProviders[dataType].push(providerId);
        _providerAddressToId[providerAddress] = providerId;

        _grantRole(ORACLE_ROLE, providerAddress);

        emit ProviderRegistered(providerId, providerAddress, dataType);
    }

    /**
     * @notice Update provider status
     */
    function setProviderActive(bytes32 providerId, bool active) external onlyOwner {
        require(providers[providerId].providerAddress != address(0), "OracleRegistry: provider not found");
        providers[providerId].isActive = active;
        emit ProviderUpdated(providerId, active);
    }

    // ============ Data Request Functions ============

    /**
     * @notice Request data from oracle for contest resolution
     */
    function requestData(
        bytes32 contestId,
        string calldata dataType,
        bytes calldata queryData,
        uint256 deadline
    ) external onlyRole(REQUESTER_ROLE) returns (bytes32 requestId) {
        require(contestResolutions[contestId] == bytes32(0), "OracleRegistry: contest already has resolution");

        requestId = keccak256(abi.encodePacked(contestId, dataType, block.timestamp));

        require(dataRequests[requestId].requestedAt == 0, "OracleRegistry: request exists");

        dataRequests[requestId] = DataRequest({
            requestId: requestId,
            contestId: contestId,
            dataType: dataType,
            queryData: queryData,
            requestedAt: block.timestamp,
            deadline: deadline,
            isFulfilled: false,
            result: "",
            fulfilledBy: address(0)
        });

        requestIds.push(requestId);
        contestResolutions[contestId] = requestId;

        emit DataRequested(requestId, contestId, dataType);

        return requestId;
    }

    /**
     * @notice Fulfill a data request (oracle providers only)
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes calldata result
    ) external onlyRole(ORACLE_ROLE) {
        DataRequest storage request = dataRequests[requestId];

        require(request.requestedAt > 0, "OracleRegistry: request not found");
        require(!request.isFulfilled, "OracleRegistry: already fulfilled");
        require(block.timestamp <= request.deadline, "OracleRegistry: deadline passed");

        // Verify the fulfilling oracle's registered dataType matches the request's dataType
        bytes32 providerId = _getProviderIdByAddress(msg.sender);
        require(providerId != bytes32(0), "OracleRegistry: provider not registered");
        require(providers[providerId].isActive, "OracleRegistry: provider not active");
        require(
            keccak256(bytes(providers[providerId].dataType)) == keccak256(bytes(request.dataType)),
            "OracleRegistry: data type mismatch"
        );

        request.isFulfilled = true;
        request.result = result;
        request.fulfilledBy = msg.sender;

        // Update provider stats
        providers[providerId].totalReports++;

        emit DataFulfilled(requestId, result, msg.sender);
    }

    /**
     * @notice Submit manual resolution (for disputes or oracle failure)
     */
    function submitManualResolution(
        bytes32 contestId,
        bytes calldata result,
        string calldata reason
    ) external onlyRole(RESOLVER_ROLE) {
        require(manualResolutions[contestId].timestamp == 0, "OracleRegistry: already resolved");

        manualResolutions[contestId] = ManualResolution({
            contestId: contestId,
            result: result,
            reason: reason,
            timestamp: block.timestamp,
            resolver: msg.sender,
            isDisputed: false
        });

        emit ManualResolutionSubmitted(contestId, result, reason);
    }

    /**
     * @notice Dispute a resolution
     */
    function disputeResolution(bytes32 contestId) external {
        ManualResolution storage resolution = manualResolutions[contestId];
        require(resolution.timestamp > 0, "OracleRegistry: no resolution");
        require(!resolution.isDisputed, "OracleRegistry: already disputed");
        // Only a registered provider or the owner/admin can dispute
        bool isProvider = hasRole(ORACLE_ROLE, msg.sender);
        bool isOwnerOrAdmin = msg.sender == owner() || hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        require(isProvider || isOwnerOrAdmin, "OracleRegistry: not authorized to dispute");

        resolution.isDisputed = true;

        // Update provider reputation if oracle-based
        bytes32 requestId = contestResolutions[contestId];
        if (requestId != bytes32(0) && dataRequests[requestId].isFulfilled) {
            bytes32 providerId = _getProviderIdByAddress(dataRequests[requestId].fulfilledBy);
            if (providerId != bytes32(0)) {
                providers[providerId].disputedReports++;
                // Reduce reputation
                if (providers[providerId].reputation > 10) {
                    providers[providerId].reputation -= 10;
                }
            }
        }

        emit ResolutionDisputed(contestId, msg.sender);
    }

    // ============ View Functions ============

    /**
     * @notice Get resolution data for a contest
     */
    function getResolution(bytes32 contestId) external view returns (
        bool hasOracleData,
        bytes memory oracleResult,
        bool hasManualResolution,
        bytes memory manualResult
    ) {
        bytes32 requestId = contestResolutions[contestId];

        if (requestId != bytes32(0) && dataRequests[requestId].isFulfilled) {
            hasOracleData = true;
            oracleResult = dataRequests[requestId].result;
        }

        if (manualResolutions[contestId].timestamp > 0) {
            hasManualResolution = true;
            manualResult = manualResolutions[contestId].result;
        }
    }

    /**
     * @notice Get providers for a data type
     */
    function getProvidersForType(string calldata dataType) external view returns (bytes32[] memory) {
        return dataTypeProviders[dataType];
    }

    /**
     * @notice Get provider details
     */
    function getProvider(bytes32 providerId) external view returns (OracleProvider memory) {
        return providers[providerId];
    }

    /**
     * @notice Check if data is available for a contest
     */
    function isDataAvailable(bytes32 contestId) external view returns (bool) {
        bytes32 requestId = contestResolutions[contestId];
        if (requestId != bytes32(0) && dataRequests[requestId].isFulfilled) {
            return true;
        }
        return manualResolutions[contestId].timestamp > 0;
    }

    // ============ Internal Functions ============

    function _getProviderIdByAddress(address addr) internal view returns (bytes32) {
        return _providerAddressToId[addr];
    }
}
