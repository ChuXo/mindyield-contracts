// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/oracles/OracleRegistry.sol";

/**
 * @title MockOracleProvider
 * @notice Minimal mock implementing IOracleProvider for testing
 */
contract MockOracleProvider is IOracleProvider {
    mapping(bytes32 => bytes) private _data;
    mapping(bytes32 => uint256) private _timestamps;
    mapping(bytes32 => bool) private _available;
    string private _name;

    constructor(string memory name_) {
        _name = name_;
    }

    function setData(bytes32 dataId, bytes memory data, uint256 timestamp) external {
        _data[dataId] = data;
        _timestamps[dataId] = timestamp;
        _available[dataId] = true;
    }

    function getData(bytes32 dataId) external view override returns (bytes memory data, uint256 timestamp) {
        return (_data[dataId], _timestamps[dataId]);
    }

    function isDataAvailable(bytes32 dataId) external view override returns (bool) {
        return _available[dataId];
    }

    function getProviderName() external view override returns (string memory) {
        return _name;
    }
}

/**
 * @title OracleRegistryTest
 * @notice Comprehensive tests for the OracleRegistry contract
 * @dev Covers provider management, data requests, fulfillment, manual resolution,
 *      dispute handling, access control, view functions, and edge cases.
 */
contract OracleRegistryTest is Test {
    OracleRegistry public registry;

    address public owner = address(this);
    address public alice = address(1);
    address public bob = address(2);
    address public resolver = address(3);
    address public attacker = address(0xBAD);

    MockOracleProvider public providerA;
    MockOracleProvider public providerB;

    bytes32 public constant PROVIDER_ID_A = keccak256("provider-a");
    bytes32 public constant PROVIDER_ID_B = keccak256("provider-b");
    bytes32 public constant PROVIDER_ID_C = keccak256("provider-c");

    bytes32 public constant CONTEST_ID_1 = keccak256("contest-1");
    bytes32 public constant CONTEST_ID_2 = keccak256("contest-2");
    bytes32 public constant CONTEST_ID_3 = keccak256("contest-3");

    // Re-declare events for vm.expectEmit
    event ProviderRegistered(bytes32 indexed providerId, address provider, string dataType);
    event ProviderUpdated(bytes32 indexed providerId, bool isActive);
    event DataRequested(bytes32 indexed requestId, bytes32 indexed contestId, string dataType);
    event DataFulfilled(bytes32 indexed requestId, bytes result, address fulfilledBy);
    event ManualResolutionSubmitted(bytes32 indexed contestId, bytes result, string reason);
    event ResolutionDisputed(bytes32 indexed contestId, address disputedBy);

    function setUp() public {
        registry = new OracleRegistry();
        providerA = new MockOracleProvider("Chainlink-Sports");
        providerB = new MockOracleProvider("API3-Price");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _registerProviderA() internal {
        registry.registerProvider(PROVIDER_ID_A, address(providerA), "Chainlink-Sports", "sports");
    }

    function _registerProviderB() internal {
        registry.registerProvider(PROVIDER_ID_B, address(providerB), "API3-Price", "price");
    }

    /// @dev Requests data and returns the requestId
    function _requestData(bytes32 contestId, string memory dataType, uint256 deadline) internal returns (bytes32) {
        return registry.requestData(contestId, dataType, abi.encode("query"), deadline);
    }

    // ============================================================
    // 1. Deployment & Initialization
    // ============================================================

    function test_deploy_ownerIsDeployer() public view {
        assertEq(registry.owner(), owner);
    }

    function test_deploy_deployerHasAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_deploy_deployerHasResolverRole() public view {
        assertTrue(registry.hasRole(registry.RESOLVER_ROLE(), owner));
    }

    function test_deploy_noProvidersInitially() public view {
        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertEq(p.providerAddress, address(0));
    }

    // ============================================================
    // 2. Provider Registration
    // ============================================================

    function test_register_successfullyRegistersProvider() public {
        _registerProviderA();

        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertEq(p.providerAddress, address(providerA));
        assertEq(p.name, "Chainlink-Sports");
        assertEq(p.reputation, 100);
        assertTrue(p.isActive);
        assertEq(p.totalReports, 0);
        assertEq(p.disputedReports, 0);
    }

    function test_register_emitsProviderRegisteredEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ProviderRegistered(PROVIDER_ID_A, address(providerA), "sports");
        _registerProviderA();
    }

    function test_register_grantsOracleRoleToProvider() public {
        _registerProviderA();
        assertTrue(registry.hasRole(registry.ORACLE_ROLE(), address(providerA)));
    }

    function test_register_addsToDataTypeProviders() public {
        _registerProviderA();

        bytes32[] memory ids = registry.getProvidersForType("sports");
        assertEq(ids.length, 1);
        assertEq(ids[0], PROVIDER_ID_A);
    }

    function test_register_multipleProvidersForSameType() public {
        registry.registerProvider(PROVIDER_ID_A, address(providerA), "Provider-A", "price");
        registry.registerProvider(PROVIDER_ID_B, address(providerB), "Provider-B", "price");

        bytes32[] memory ids = registry.getProvidersForType("price");
        assertEq(ids.length, 2);
    }

    function test_register_revertsIfProviderAlreadyExists() public {
        _registerProviderA();

        vm.expectRevert("OracleRegistry: provider exists");
        registry.registerProvider(PROVIDER_ID_A, address(0x999), "Duplicate", "sports");
    }

    function test_register_revertsIfCallerNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.registerProvider(PROVIDER_ID_A, address(providerA), "Provider", "sports");
    }

    // ============================================================
    // 3. Provider Activation / Deactivation
    // ============================================================

    function test_setActive_deactivatesProvider() public {
        _registerProviderA();
        registry.setProviderActive(PROVIDER_ID_A, false);

        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertFalse(p.isActive);
    }

    function test_setActive_reactivatesProvider() public {
        _registerProviderA();
        registry.setProviderActive(PROVIDER_ID_A, false);
        registry.setProviderActive(PROVIDER_ID_A, true);

        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertTrue(p.isActive);
    }

    function test_setActive_emitsProviderUpdatedEvent() public {
        _registerProviderA();

        vm.expectEmit(true, false, false, true);
        emit ProviderUpdated(PROVIDER_ID_A, false);
        registry.setProviderActive(PROVIDER_ID_A, false);
    }

    function test_setActive_revertsForNonexistentProvider() public {
        vm.expectRevert("OracleRegistry: provider not found");
        registry.setProviderActive(PROVIDER_ID_A, false);
    }

    function test_setActive_revertsIfCallerNotOwner() public {
        _registerProviderA();

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setProviderActive(PROVIDER_ID_A, false);
    }

    // ============================================================
    // 4. Data Request
    // ============================================================

    function test_requestData_createsRequest() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        (
            bytes32 storedRequestId,
            bytes32 contestId,
            , // dataType
            , // queryData
            uint256 requestedAt,
            uint256 storedDeadline,
            bool isFulfilled,
            , // result
            address fulfilledBy
        ) = registry.dataRequests(requestId);

        assertEq(storedRequestId, requestId);
        assertEq(contestId, CONTEST_ID_1);
        assertEq(requestedAt, block.timestamp);
        assertEq(storedDeadline, deadline);
        assertFalse(isFulfilled);
        assertEq(fulfilledBy, address(0));
    }

    function test_requestData_emitsDataRequestedEvent() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 expectedRequestId = keccak256(abi.encodePacked(CONTEST_ID_1, "sports", block.timestamp));

        vm.expectEmit(true, true, false, true);
        emit DataRequested(expectedRequestId, CONTEST_ID_1, "sports");
        registry.requestData(CONTEST_ID_1, "sports", abi.encode("query"), deadline);
    }

    function test_requestData_linksContestToRequest() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        assertEq(registry.contestResolutions(CONTEST_ID_1), requestId);
    }

    function test_requestData_requiresRequesterRole() public {
        // After security fix, requestData requires REQUESTER_ROLE
        vm.prank(alice);
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert();
        registry.requestData(CONTEST_ID_1, "sports", abi.encode("q"), deadline);

        // Grant REQUESTER_ROLE to alice, then request succeeds
        registry.grantRole(registry.REQUESTER_ROLE(), alice);
        vm.prank(alice);
        bytes32 requestId = registry.requestData(CONTEST_ID_1, "sports", abi.encode("q"), deadline);
        assertTrue(requestId != bytes32(0));
    }

    // ============================================================
    // 5. Request Fulfillment
    // ============================================================

    function test_fulfill_successfulFulfillment() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        bytes memory result = abi.encode(uint256(42));
        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, result);

        (
            , , , , , ,
            bool isFulfilled,
            ,
            address fulfilledBy
        ) = registry.dataRequests(requestId);

        assertTrue(isFulfilled);
        assertEq(fulfilledBy, address(providerA));
    }

    function test_fulfill_emitsDataFulfilledEvent() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        bytes memory result = abi.encode(uint256(42));

        vm.prank(address(providerA));
        vm.expectEmit(true, false, false, true);
        emit DataFulfilled(requestId, result, address(providerA));
        registry.fulfillRequest(requestId, result);
    }

    function test_fulfill_incrementsProviderTotalReports() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));

        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertEq(p.totalReports, 1);
    }

    function test_fulfill_revertsIfNotOracleRole() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.prank(attacker);
        vm.expectRevert();
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));
    }

    function test_fulfill_revertsIfRequestNotFound() public {
        _registerProviderA();

        vm.prank(address(providerA));
        vm.expectRevert("OracleRegistry: request not found");
        registry.fulfillRequest(keccak256("nonexistent"), abi.encode(uint256(1)));
    }

    function test_fulfill_revertsIfAlreadyFulfilled() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.startPrank(address(providerA));
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));

        vm.expectRevert("OracleRegistry: already fulfilled");
        registry.fulfillRequest(requestId, abi.encode(uint256(2)));
        vm.stopPrank();
    }

    function test_fulfill_revertsIfDeadlinePassed() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.warp(deadline + 1);

        vm.prank(address(providerA));
        vm.expectRevert("OracleRegistry: deadline passed");
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));
    }

    function test_fulfill_atExactDeadlineSucceeds() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.warp(deadline);

        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));

        (, , , , , , bool isFulfilled, , ) = registry.dataRequests(requestId);
        assertTrue(isFulfilled);
    }

    // ============================================================
    // 6. Manual Resolution
    // ============================================================

    function test_manualResolution_submitsSuccessfully() public {
        bytes memory result = abi.encode(uint256(7));
        registry.submitManualResolution(CONTEST_ID_1, result, "Oracle failed");

        (
            bytes32 contestId,
            , // result
            , // reason
            uint256 timestamp,
            address resolverAddr,
            bool isDisputed
        ) = registry.manualResolutions(CONTEST_ID_1);

        assertEq(contestId, CONTEST_ID_1);
        assertEq(timestamp, block.timestamp);
        assertEq(resolverAddr, owner);
        assertFalse(isDisputed);
    }

    function test_manualResolution_emitsEvent() public {
        bytes memory result = abi.encode(uint256(7));

        vm.expectEmit(true, false, false, true);
        emit ManualResolutionSubmitted(CONTEST_ID_1, result, "Oracle failed");
        registry.submitManualResolution(CONTEST_ID_1, result, "Oracle failed");
    }

    function test_manualResolution_revertsIfAlreadyResolved() public {
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "first");

        vm.expectRevert("OracleRegistry: already resolved");
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(2)), "second");
    }

    function test_manualResolution_revertsIfNotResolverRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "nope");
    }

    function test_manualResolution_grantedResolverCanSubmit() public {
        registry.grantRole(registry.RESOLVER_ROLE(), alice);

        vm.prank(alice);
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "authorized");

        (, , , uint256 ts, address resolverAddr, ) = registry.manualResolutions(CONTEST_ID_1);
        assertGt(ts, 0);
        assertEq(resolverAddr, alice);
    }

    // ============================================================
    // 7. Dispute Resolution
    // ============================================================

    function test_dispute_marksResolutionAsDisputed() public {
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "reason");

        // Dispute requires ORACLE_ROLE, owner, or DEFAULT_ADMIN_ROLE
        // Use owner (this contract) to dispute
        registry.disputeResolution(CONTEST_ID_1);

        (, , , , , bool isDisputed) = registry.manualResolutions(CONTEST_ID_1);
        assertTrue(isDisputed);
    }

    function test_dispute_emitsResolutionDisputedEvent() public {
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "reason");

        vm.expectEmit(true, false, false, true);
        emit ResolutionDisputed(CONTEST_ID_1, owner);
        registry.disputeResolution(CONTEST_ID_1);
    }

    function test_dispute_revertsIfNoResolution() public {
        vm.expectRevert("OracleRegistry: no resolution");
        registry.disputeResolution(CONTEST_ID_1);
    }

    function test_dispute_revertsIfAlreadyDisputed() public {
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "reason");

        registry.disputeResolution(CONTEST_ID_1);

        vm.expectRevert("OracleRegistry: already disputed");
        registry.disputeResolution(CONTEST_ID_1);
    }

    function test_dispute_reducesProviderReputation() public {
        _registerProviderA();

        // Create and fulfill a request
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, abi.encode(uint256(42)));

        // Submit manual resolution (overriding oracle) and dispute (as owner)
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(99)), "oracle was wrong");
        registry.disputeResolution(CONTEST_ID_1);

        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertEq(p.reputation, 90, "reputation should decrease by 10");
        assertEq(p.disputedReports, 1);
    }

    function test_dispute_reputationFloorAt10() public {
        _registerProviderA();

        // We need to dispute many times across different contests
        // to drive reputation below 10. Each dispute reduces by 10.
        // Starting at 100, after 9 disputes => 10, then 10th should stay at 10.
        for (uint256 i = 0; i < 10; i++) {
            bytes32 contestId = keccak256(abi.encodePacked("contest-floor-", i));
            uint256 deadline = block.timestamp + 1 hours;

            // Need unique timestamps for unique requestIds
            vm.warp(block.timestamp + 1);

            bytes32 requestId = registry.requestData(contestId, "sports", abi.encode("q"), deadline);

            vm.prank(address(providerA));
            registry.fulfillRequest(requestId, abi.encode(uint256(i)));

            registry.submitManualResolution(contestId, abi.encode(uint256(i + 100)), "wrong");

            // Dispute as owner (authorized)
            registry.disputeResolution(contestId);
        }

        OracleRegistry.OracleProvider memory p = registry.getProvider(PROVIDER_ID_A);
        assertEq(p.reputation, 10, "reputation should floor at 10");
    }

    // ============================================================
    // 8. View Functions: getResolution
    // ============================================================

    function test_getResolution_noDataReturnsDefaults() public view {
        (bool hasOracle, bytes memory oracleResult, bool hasManual, bytes memory manualResult) =
            registry.getResolution(CONTEST_ID_1);

        assertFalse(hasOracle);
        assertEq(oracleResult.length, 0);
        assertFalse(hasManual);
        assertEq(manualResult.length, 0);
    }

    function test_getResolution_withOracleDataOnly() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        bytes memory result = abi.encode(uint256(42));
        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, result);

        (bool hasOracle, bytes memory oracleResult, bool hasManual, ) =
            registry.getResolution(CONTEST_ID_1);

        assertTrue(hasOracle);
        assertEq(abi.decode(oracleResult, (uint256)), 42);
        assertFalse(hasManual);
    }

    function test_getResolution_withManualResolutionOnly() public {
        bytes memory result = abi.encode(uint256(7));
        registry.submitManualResolution(CONTEST_ID_1, result, "fallback");

        (bool hasOracle, , bool hasManual, bytes memory manualResult) =
            registry.getResolution(CONTEST_ID_1);

        assertFalse(hasOracle);
        assertTrue(hasManual);
        assertEq(abi.decode(manualResult, (uint256)), 7);
    }

    function test_getResolution_withBothOracleAndManual() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, abi.encode(uint256(42)));

        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(99)), "override");

        (bool hasOracle, bytes memory oracleResult, bool hasManual, bytes memory manualResult) =
            registry.getResolution(CONTEST_ID_1);

        assertTrue(hasOracle);
        assertTrue(hasManual);
        assertEq(abi.decode(oracleResult, (uint256)), 42);
        assertEq(abi.decode(manualResult, (uint256)), 99);
    }

    // ============================================================
    // 9. View Functions: isDataAvailable
    // ============================================================

    function test_isDataAvailable_falseWhenNoData() public view {
        assertFalse(registry.isDataAvailable(CONTEST_ID_1));
    }

    function test_isDataAvailable_trueAfterOracleFulfillment() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));

        assertTrue(registry.isDataAvailable(CONTEST_ID_1));
    }

    function test_isDataAvailable_trueAfterManualResolution() public {
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "fallback");
        assertTrue(registry.isDataAvailable(CONTEST_ID_1));
    }

    function test_isDataAvailable_falseWhenRequestedButNotFulfilled() public {
        _requestData(CONTEST_ID_1, "sports", block.timestamp + 1 hours);
        assertFalse(registry.isDataAvailable(CONTEST_ID_1));
    }

    // ============================================================
    // 10. Edge Cases
    // ============================================================

    function test_edge_multipleContestsIndependent() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;

        // Request data for two contests
        bytes32 reqId1 = _requestData(CONTEST_ID_1, "sports", deadline);
        vm.warp(block.timestamp + 1); // different timestamp for unique requestId
        bytes32 reqId2 = _requestData(CONTEST_ID_2, "sports", deadline + 1);

        // Fulfill only first
        vm.prank(address(providerA));
        registry.fulfillRequest(reqId1, abi.encode(uint256(10)));

        assertTrue(registry.isDataAvailable(CONTEST_ID_1));
        assertFalse(registry.isDataAvailable(CONTEST_ID_2));

        // Fulfill second
        vm.prank(address(providerA));
        registry.fulfillRequest(reqId2, abi.encode(uint256(20)));

        assertTrue(registry.isDataAvailable(CONTEST_ID_2));
    }

    function test_edge_fulfillByDifferentOracleProviders() public {
        _registerProviderA();
        _registerProviderB();

        uint256 deadline = block.timestamp + 1 hours;

        bytes32 reqId1 = _requestData(CONTEST_ID_1, "sports", deadline);
        vm.warp(block.timestamp + 1);
        bytes32 reqId2 = _requestData(CONTEST_ID_2, "price", deadline + 1);

        vm.prank(address(providerA));
        registry.fulfillRequest(reqId1, abi.encode(uint256(1)));

        vm.prank(address(providerB));
        registry.fulfillRequest(reqId2, abi.encode(uint256(2)));

        OracleRegistry.OracleProvider memory pA = registry.getProvider(PROVIDER_ID_A);
        OracleRegistry.OracleProvider memory pB = registry.getProvider(PROVIDER_ID_B);
        assertEq(pA.totalReports, 1);
        assertEq(pB.totalReports, 1);
    }

    function test_edge_emptyResultDataAllowed() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        vm.prank(address(providerA));
        registry.fulfillRequest(requestId, "");

        (, , , , , , bool isFulfilled, , ) = registry.dataRequests(requestId);
        assertTrue(isFulfilled);
    }

    function test_edge_manualResolutionAsFallbackAfterDeadline() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        _requestData(CONTEST_ID_1, "sports", deadline);

        // Oracle misses the deadline
        vm.warp(deadline + 1);

        // Cache the requestId before setting up expectRevert,
        // otherwise vm.expectRevert() is consumed by the contestResolutions() view call.
        bytes32 requestId = registry.contestResolutions(CONTEST_ID_1);
        vm.prank(address(providerA));
        vm.expectRevert("OracleRegistry: deadline passed");
        registry.fulfillRequest(
            requestId,
            abi.encode(uint256(1))
        );

        // Manual resolution as fallback
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(99)), "deadline missed");
        assertTrue(registry.isDataAvailable(CONTEST_ID_1));

        (, , bool hasManual, bytes memory manualResult) = registry.getResolution(CONTEST_ID_1);
        assertTrue(hasManual);
        assertEq(abi.decode(manualResult, (uint256)), 99);
    }

    function test_edge_disputeWithoutOracleRequestDoesNotCrash() public {
        // Manual resolution without any oracle request
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "manual only");

        // Dispute should work without affecting any provider (called as owner)
        registry.disputeResolution(CONTEST_ID_1);

        (, , , , , bool isDisputed) = registry.manualResolutions(CONTEST_ID_1);
        assertTrue(isDisputed);
    }

    function test_edge_getProvidersForTypeReturnsEmptyForUnknownType() public view {
        bytes32[] memory ids = registry.getProvidersForType("unknown");
        assertEq(ids.length, 0);
    }

    // ============================================================
    // 11. Access Control - Role Granting
    // ============================================================

    function test_accessControl_ownerCanGrantResolverRole() public {
        registry.grantRole(registry.RESOLVER_ROLE(), alice);
        assertTrue(registry.hasRole(registry.RESOLVER_ROLE(), alice));
    }

    function test_accessControl_nonAdminCannotGrantRoles() public {
        // Cache the role value before setting up expectRevert,
        // otherwise vm.expectRevert() is consumed by the RESOLVER_ROLE() view call.
        bytes32 resolverRole = registry.RESOLVER_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        registry.grantRole(resolverRole, attacker);
    }

    function test_accessControl_revokedResolverCannotSubmit() public {
        registry.grantRole(registry.RESOLVER_ROLE(), alice);
        registry.revokeRole(registry.RESOLVER_ROLE(), alice);

        vm.prank(alice);
        vm.expectRevert();
        registry.submitManualResolution(CONTEST_ID_1, abi.encode(uint256(1)), "revoked");
    }

    function test_accessControl_revokedOracleCannotFulfill() public {
        _registerProviderA();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 requestId = _requestData(CONTEST_ID_1, "sports", deadline);

        // Revoke the ORACLE_ROLE from providerA
        registry.revokeRole(registry.ORACLE_ROLE(), address(providerA));

        vm.prank(address(providerA));
        vm.expectRevert();
        registry.fulfillRequest(requestId, abi.encode(uint256(1)));
    }
}
