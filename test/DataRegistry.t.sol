// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DataRegistry.sol";

/**
 * @title DataRegistryTest
 * @notice Comprehensive tests for the DataRegistry contract
 * Tests metadata anchoring, results anchoring, access control, event emission, and edge cases.
 *
 * After the security fix, only the authorizedRegistrar can anchor metadata/results
 * for new (unowned) contestIds. This test contract is set as the registrar.
 */
contract DataRegistryTest is Test {
    DataRegistry public registry;

    address public alice = address(1);
    address public bob = address(2);
    address public charlie = address(3);

    bytes32 public constant CONTEST_ID_1 = keccak256("contest-1");
    bytes32 public constant CONTEST_ID_2 = keccak256("contest-2");
    bytes32 public constant CONTEST_ID_3 = keccak256("contest-3");

    bytes32 public constant METADATA_HASH_1 = keccak256("metadata-json-1");
    bytes32 public constant METADATA_HASH_2 = keccak256("metadata-json-2");
    bytes32 public constant RESULTS_ROOT_1 = keccak256("results-merkle-1");
    bytes32 public constant RESULTS_ROOT_2 = keccak256("results-merkle-2");

    string public constant METADATA_URI_1 = "ipfs://QmTest1234567890abcdef";
    string public constant METADATA_URI_2 = "ipfs://QmTest0987654321fedcba";
    string public constant RESULTS_URI_1 = "ipfs://QmResults1234567890";
    string public constant RESULTS_URI_2 = "ipfs://QmResults0987654321";

    // Re-declare events for vm.expectEmit
    event MetadataAnchored(
        bytes32 indexed contestId,
        bytes32 metadataHash,
        string metadataUri,
        uint256 timestamp
    );

    event ResultsAnchored(
        bytes32 indexed contestId,
        bytes32 resultsRoot,
        string resultsUri,
        uint256 timestamp
    );

    function setUp() public {
        registry = new DataRegistry(address(this));
        // The security fix requires an authorizedRegistrar for new contest anchoring.
        // Set this test contract as the authorized registrar.
        registry.setAuthorizedRegistrar(address(this));
    }

    // ============ DEPLOYMENT TESTS ============

    function test_deployment_registryDeploysSuccessfully() public view {
        // Registry should be deployed with no data
        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, bytes32(0));
        assertEq(bytes(uri).length, 0);
        assertEq(ts, 0);
    }

    function test_deployment_noContestOwnerByDefault() public view {
        address owner = registry.getContestOwner(CONTEST_ID_1);
        assertEq(owner, address(0));
    }

    // ============ ANCHOR METADATA TESTS ============

    function test_anchorMetadata_storesDataCorrectly() public {
        // Called by registrar (this contract) — sets owner to address(this)
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, METADATA_HASH_1);
        assertEq(uri, METADATA_URI_1);
        assertEq(ts, block.timestamp);
    }

    function test_anchorMetadata_setsContestOwner() public {
        // Registrar anchors metadata — becomes contest owner
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        assertEq(registry.getContestOwner(CONTEST_ID_1), address(this));
    }

    function test_anchorMetadata_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit MetadataAnchored(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1, block.timestamp);

        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);
    }

    function test_anchorMetadata_differentContestsIndependent() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);
        registry.anchorMetadata(CONTEST_ID_2, METADATA_HASH_2, METADATA_URI_2);

        (bytes32 hash1, string memory uri1,) = registry.getMetadata(CONTEST_ID_1);
        (bytes32 hash2, string memory uri2,) = registry.getMetadata(CONTEST_ID_2);

        assertEq(hash1, METADATA_HASH_1);
        assertEq(uri1, METADATA_URI_1);
        assertEq(hash2, METADATA_HASH_2);
        assertEq(uri2, METADATA_URI_2);
    }

    function test_anchorMetadata_recordsCorrectTimestamp() public {
        uint256 targetTime = 1700000000;
        vm.warp(targetTime);

        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        (,, uint256 ts) = registry.getMetadata(CONTEST_ID_1);
        assertEq(ts, targetTime);
    }

    function test_anchorMetadata_revertsOnDuplicateAnchor() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Even the owner cannot re-anchor
        vm.expectRevert(DataRegistry.MetadataAlreadyAnchored.selector);
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_2, METADATA_URI_2);
    }

    function test_anchorMetadata_ownerCannotBeOverwrittenByDuplicate() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Even the same owner cannot re-anchor
        vm.expectRevert(DataRegistry.MetadataAlreadyAnchored.selector);
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_2, METADATA_URI_2);

        // Original data is preserved
        (bytes32 hash,,) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, METADATA_HASH_1);
    }

    // ============ ANCHOR RESULTS TESTS ============

    function test_anchorResults_storesDataCorrectly() public {
        // Registrar anchors metadata first (sets ownership)
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Owner (this contract) anchors results
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        (bytes32 root, string memory uri, uint256 ts) = registry.getResults(CONTEST_ID_1);
        assertEq(root, RESULTS_ROOT_1);
        assertEq(uri, RESULTS_URI_1);
        assertEq(ts, block.timestamp);
    }

    function test_anchorResults_emitsEvent() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        vm.expectEmit(true, false, false, true);
        emit ResultsAnchored(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1, block.timestamp);

        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);
    }

    function test_anchorResults_revertsOnDuplicateAnchor() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        vm.expectRevert(DataRegistry.ResultsAlreadyAnchored.selector);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_2, RESULTS_URI_2);
    }

    function test_anchorResults_withoutPriorMetadata() public {
        // Registrar can anchor results for an unowned contest (no prior metadata)
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        (bytes32 root, string memory uri, uint256 ts) = registry.getResults(CONTEST_ID_1);
        assertEq(root, RESULTS_ROOT_1);
        assertEq(uri, RESULTS_URI_1);
        assertGt(ts, 0);
    }

    function test_anchorResults_recordsCorrectTimestamp() public {
        uint256 targetTime = 1800000000;
        vm.warp(targetTime);

        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        (,, uint256 ts) = registry.getResults(CONTEST_ID_1);
        assertEq(ts, targetTime);
    }

    // ============ ACCESS CONTROL TESTS ============

    function test_accessControl_nonRegistrarCannotAnchorNewContest() public {
        // Non-registrar cannot anchor metadata for new (unowned) contest
        vm.prank(bob);
        vm.expectRevert(DataRegistry.NotAuthorizedRegistrar.selector);
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);
    }

    function test_accessControl_nonOwnerCannotAnchorMetadataForOwnedContest() public {
        // Registrar anchors metadata, becoming the owner
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Bob tries to anchor results — should revert since this contract is the owner
        vm.prank(bob);
        vm.expectRevert(DataRegistry.NotContestOwner.selector);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);
    }

    function test_accessControl_ownerCanAnchorResults() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Owner (this contract) can anchor results
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        (bytes32 root,,) = registry.getResults(CONTEST_ID_1);
        assertEq(root, RESULTS_ROOT_1);
    }

    function test_accessControl_registrarCanAnchorUnownedContest() public {
        // Only registrar can anchor metadata for unowned contest
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        assertEq(registry.getContestOwner(CONTEST_ID_1), address(this));
    }

    function test_accessControl_resultsAnchorBlockedForNonOwner() public {
        // Registrar sets ownership via metadata
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Charlie is not the owner
        vm.prank(charlie);
        vm.expectRevert(DataRegistry.NotContestOwner.selector);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);
    }

    function test_accessControl_differentOwnersForDifferentContests() public {
        // Both contests owned by registrar (this contract)
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);
        registry.anchorMetadata(CONTEST_ID_2, METADATA_HASH_2, METADATA_URI_2);

        assertEq(registry.getContestOwner(CONTEST_ID_1), address(this));
        assertEq(registry.getContestOwner(CONTEST_ID_2), address(this));

        // Non-owner (bob) cannot write to either contest
        vm.prank(bob);
        vm.expectRevert(DataRegistry.NotContestOwner.selector);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        vm.prank(alice);
        vm.expectRevert(DataRegistry.NotContestOwner.selector);
        registry.anchorResults(CONTEST_ID_2, RESULTS_ROOT_2, RESULTS_URI_2);
    }

    // ============ RETRIEVAL TESTS ============

    function test_getMetadata_returnsZeroForNonExistent() public view {
        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, bytes32(0));
        assertEq(bytes(uri).length, 0);
        assertEq(ts, 0);
    }

    function test_getResults_returnsZeroForNonExistent() public view {
        (bytes32 root, string memory uri, uint256 ts) = registry.getResults(CONTEST_ID_1);
        assertEq(root, bytes32(0));
        assertEq(bytes(uri).length, 0);
        assertEq(ts, 0);
    }

    function test_getContestOwner_returnsZeroForUnowned() public view {
        assertEq(registry.getContestOwner(CONTEST_ID_1), address(0));
    }

    function test_getMetadata_doesNotReturnResults() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        // Metadata and results are separate
        (bytes32 hash,,) = registry.getMetadata(CONTEST_ID_1);
        (bytes32 root,,) = registry.getResults(CONTEST_ID_1);

        assertEq(hash, METADATA_HASH_1);
        assertEq(root, RESULTS_ROOT_1);
        assertTrue(hash != root);
    }

    // ============ EDGE CASES ============

    function test_edge_zeroHashMetadata() public {
        registry.anchorMetadata(CONTEST_ID_1, bytes32(0), METADATA_URI_1);

        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, bytes32(0));
        assertEq(uri, METADATA_URI_1);
        assertGt(ts, 0);
    }

    function test_edge_emptyUriMetadata() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, "");

        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, METADATA_HASH_1);
        assertEq(bytes(uri).length, 0);
        assertGt(ts, 0);
    }

    function test_edge_emptyUriResults() public {
        // Registrar anchors results for unowned contest
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, "");

        (bytes32 root, string memory uri, uint256 ts) = registry.getResults(CONTEST_ID_1);
        assertEq(root, RESULTS_ROOT_1);
        assertEq(bytes(uri).length, 0);
        assertGt(ts, 0);
    }

    function test_edge_zeroContestId() public {
        bytes32 zeroId = bytes32(0);

        registry.anchorMetadata(zeroId, METADATA_HASH_1, METADATA_URI_1);

        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(zeroId);
        assertEq(hash, METADATA_HASH_1);
        assertEq(uri, METADATA_URI_1);
        assertGt(ts, 0);
    }

    function test_edge_longUri() public {
        // Test with a very long URI string
        string memory longUri = "ipfs://QmVeryLongCIDThatExceedsNormalLengthAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBCCCCCCCCCCCCCCCCCCCCC";

        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, longUri);

        (, string memory uri,) = registry.getMetadata(CONTEST_ID_1);
        assertEq(uri, longUri);
    }

    function test_edge_manyContestsIndependent() public {
        // Anchor metadata for multiple contests and verify isolation
        bytes32[5] memory ids;
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = keccak256(abi.encodePacked("contest-batch-", i));
        }

        for (uint256 i = 0; i < 5; i++) {
            registry.anchorMetadata(ids[i], keccak256(abi.encodePacked("hash-", i)), "ipfs://batch");
        }

        for (uint256 i = 0; i < 5; i++) {
            (bytes32 hash,,) = registry.getMetadata(ids[i]);
            assertEq(hash, keccak256(abi.encodePacked("hash-", i)));
        }
    }

    // ============ INTEGRATION: FULL CONTEST LIFECYCLE ============

    function test_integration_fullContestLifecycle() public {
        // 1. Registrar anchors metadata
        vm.warp(1000);
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // 2. Verify metadata was stored
        (bytes32 hash, string memory mUri, uint256 mTs) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, METADATA_HASH_1);
        assertEq(mUri, METADATA_URI_1);
        assertEq(mTs, 1000);

        // 3. After contest resolves, owner anchors results
        vm.warp(2000);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        // 4. Verify results were stored
        (bytes32 root, string memory rUri, uint256 rTs) = registry.getResults(CONTEST_ID_1);
        assertEq(root, RESULTS_ROOT_1);
        assertEq(rUri, RESULTS_URI_1);
        assertEq(rTs, 2000);

        // 5. Both metadata and results coexist
        assertEq(registry.getContestOwner(CONTEST_ID_1), address(this));
    }

    function test_integration_multipleContestsDifferentOwners() public {
        // Registrar creates both contests
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);
        registry.anchorMetadata(CONTEST_ID_2, METADATA_HASH_2, METADATA_URI_2);

        // Owner (registrar) anchors results for both
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);
        registry.anchorResults(CONTEST_ID_2, RESULTS_ROOT_2, RESULTS_URI_2);

        // Verify isolation
        (bytes32 root1,,) = registry.getResults(CONTEST_ID_1);
        (bytes32 root2,,) = registry.getResults(CONTEST_ID_2);
        assertEq(root1, RESULTS_ROOT_1);
        assertEq(root2, RESULTS_ROOT_2);
    }

    // ============ IMMUTABILITY TESTS ============

    function test_immutability_metadataCannotBeChanged() public {
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Attempting to re-anchor with different data reverts
        vm.expectRevert(DataRegistry.MetadataAlreadyAnchored.selector);
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_2, METADATA_URI_2);

        // Original data unchanged
        (bytes32 hash, string memory uri,) = registry.getMetadata(CONTEST_ID_1);
        assertEq(hash, METADATA_HASH_1);
        assertEq(uri, METADATA_URI_1);
    }

    function test_immutability_resultsCannotBeChanged() public {
        // Registrar anchors results for unowned contest
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        vm.expectRevert(DataRegistry.ResultsAlreadyAnchored.selector);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_2, RESULTS_URI_2);

        // Original data unchanged
        (bytes32 root, string memory uri,) = registry.getResults(CONTEST_ID_1);
        assertEq(root, RESULTS_ROOT_1);
        assertEq(uri, RESULTS_URI_1);
    }

    // ============ OWNERSHIP EDGE CASES ============

    function test_ownership_resultsAnchorSetsNoOwnerIfUnowned() public {
        // Anchoring results on an unowned contest does NOT set ownership
        // (only anchorMetadata sets _contestOwners)
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        // Owner is still zero because anchorResults doesn't set it
        assertEq(registry.getContestOwner(CONTEST_ID_1), address(0));
    }

    function test_ownership_metadataAnchorAfterResultsOnUnowned() public {
        // Results anchored first on unowned contest (no owner set)
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);

        // Registrar can still anchor metadata since no metadata owner was set
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        // Registrar is now the owner
        assertEq(registry.getContestOwner(CONTEST_ID_1), address(this));
    }

    // ============ FUZZ TESTS ============

    function testFuzz_anchorMetadata_arbitraryInputs(
        bytes32 contestId,
        bytes32 metadataHash,
        string calldata metadataUri
    ) public {
        // Registrar anchors metadata
        registry.anchorMetadata(contestId, metadataHash, metadataUri);

        (bytes32 hash, string memory uri, uint256 ts) = registry.getMetadata(contestId);
        assertEq(hash, metadataHash);
        assertEq(uri, metadataUri);
        assertGt(ts, 0);
        assertEq(registry.getContestOwner(contestId), address(this));
    }

    function testFuzz_anchorResults_arbitraryInputs(
        bytes32 contestId,
        bytes32 resultsRoot,
        string calldata resultsUri
    ) public {
        // Registrar anchors results for unowned contest
        registry.anchorResults(contestId, resultsRoot, resultsUri);

        (bytes32 root, string memory uri, uint256 ts) = registry.getResults(contestId);
        assertEq(root, resultsRoot);
        assertEq(uri, resultsUri);
        assertGt(ts, 0);
    }

    function testFuzz_accessControl_nonOwnerBlocked(address attacker) public {
        vm.assume(attacker != address(this) && attacker != address(0));

        // Registrar anchors metadata (becomes owner)
        registry.anchorMetadata(CONTEST_ID_1, METADATA_HASH_1, METADATA_URI_1);

        vm.prank(attacker);
        vm.expectRevert(DataRegistry.NotContestOwner.selector);
        registry.anchorResults(CONTEST_ID_1, RESULTS_ROOT_1, RESULTS_URI_1);
    }
}
