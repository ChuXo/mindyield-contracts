// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/IdentityRegistry.sol";

/**
 * @title IdentityRegistryRevocationTest
 * @notice Tests for attestation revocation workflows in IdentityRegistry
 */
contract IdentityRegistryRevocationTest is Test {
    IdentityRegistry public registry;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);
    address public attestor1 = address(4);
    address public attestor2 = address(5);
    address public attestor3 = address(6);
    address public attacker = address(0xBAD);

    event TierUpdated(address indexed user, uint8 oldTier, uint8 newTier);
    event AttestationRecorded(address indexed user, address indexed attestor, uint8 tier, bytes32 attestationHash);
    event AttestationRevoked(address indexed user, address indexed attestor, uint256 attestationIndex);

    function setUp() public {
        vm.prank(owner);
        registry = new IdentityRegistry();

        // Register attestors
        vm.startPrank(owner);
        registry.addAttestor(attestor1);
        registry.addAttestor(attestor2);
        registry.addAttestor(attestor3);
        vm.stopPrank();
    }

    // ============ BASIC REVOCATION TESTS ============

    function testRevokeOnlyAttestation() public {
        // Attestor1 grants alice tier 3
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));
        assertEq(registry.getTier(alice), 3);

        // Attestor1 revokes
        vm.prank(attestor1);
        vm.expectEmit(true, true, false, true);
        emit AttestationRevoked(alice, attestor1, 0);
        registry.revokeAttestation(alice, 0);

        // Tier drops to 0
        assertEq(registry.getTier(alice), 0);
        IdentityRegistry.Attestation[] memory atts = registry.getAttestations(alice);
        assertEq(atts.length, 0);
    }

    function testRevokeEmitsTierUpdatedOnChange() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));

        vm.prank(attestor1);
        vm.expectEmit(true, false, false, true);
        emit TierUpdated(alice, 3, 0);
        registry.revokeAttestation(alice, 0);
    }

    // ============ CASCADE / TIER DOWNGRADE TESTS ============

    function testRevocationCascadesToLowerTier() public {
        // Attestor1 grants tier 2, attestor2 grants tier 4
        vm.prank(attestor1);
        registry.recordAttestation(alice, 2, keccak256("proof1"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, 4, keccak256("proof2"));

        assertEq(registry.getTier(alice), 4);

        // Revoke the tier 4 attestation (index 1)
        vm.prank(attestor2);
        registry.revokeAttestation(alice, 1);

        // Tier should downgrade to 2 (from remaining attestation)
        assertEq(registry.getTier(alice), 2);
    }

    function testRevocationOfLowerTierDoesNotChangeTier() public {
        // Attestor1 grants tier 2, attestor2 grants tier 4
        vm.prank(attestor1);
        registry.recordAttestation(alice, 2, keccak256("proof1"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, 4, keccak256("proof2"));

        assertEq(registry.getTier(alice), 4);

        // Revoke the lower tier attestation (index 0)
        // After swap-and-pop, the tier 4 attestation moves to index 0
        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);

        // Tier remains 4
        assertEq(registry.getTier(alice), 4);
    }

    function testRevocationWithThreeAttestors() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 1, keccak256("proof1"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, 3, keccak256("proof2"));
        vm.prank(attestor3);
        registry.recordAttestation(alice, 5, keccak256("proof3"));

        assertEq(registry.getTier(alice), 5);

        // Revoke highest tier (attestor3 at index 2)
        vm.prank(attestor3);
        registry.revokeAttestation(alice, 2);
        assertEq(registry.getTier(alice), 3);

        // Revoke next highest (attestor2, now at index 1)
        vm.prank(attestor2);
        registry.revokeAttestation(alice, 1);
        assertEq(registry.getTier(alice), 1);

        // Revoke last
        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);
        assertEq(registry.getTier(alice), 0);
    }

    // ============ RE-VERIFICATION AFTER REVOCATION ============

    function testReVerificationAfterRevocation() public {
        // Initial attestation
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));
        assertEq(registry.getTier(alice), 3);

        // Revoke
        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);
        assertEq(registry.getTier(alice), 0);

        // Re-attest with new proof
        vm.prank(attestor1);
        registry.recordAttestation(alice, 4, keccak256("proof2"));
        assertEq(registry.getTier(alice), 4);

        IdentityRegistry.Attestation[] memory atts = registry.getAttestations(alice);
        assertEq(atts.length, 1);
        assertEq(atts[0].attestationHash, keccak256("proof2"));
    }

    function testReVerificationByDifferentAttestorAfterRevocation() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));

        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);

        // Different attestor re-verifies
        vm.prank(attestor2);
        registry.recordAttestation(alice, 2, keccak256("proof2"));
        assertEq(registry.getTier(alice), 2);
    }

    // ============ UNAUTHORIZED REVOCATION TESTS ============

    function testCannotRevokeOtherAttestorsAttestation() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));

        // Attestor2 tries to revoke attestor1's attestation
        vm.prank(attestor2);
        vm.expectRevert("IdentityRegistry: not your attestation");
        registry.revokeAttestation(alice, 0);
    }

    function testNonAttestorCannotRevoke() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));

        vm.prank(attacker);
        vm.expectRevert(IdentityRegistry.NotAttestor.selector);
        registry.revokeAttestation(alice, 0);
    }

    function testRevokeInvalidIndexReverts() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));

        vm.prank(attestor1);
        vm.expectRevert("IdentityRegistry: invalid index");
        registry.revokeAttestation(alice, 1); // Only index 0 exists
    }

    function testRevokeWithNoAttestationsReverts() public {
        vm.prank(attestor1);
        vm.expectRevert("IdentityRegistry: invalid index");
        registry.revokeAttestation(alice, 0);
    }

    // ============ PARTIAL REVOCATION (SINGLE PROVIDER) ============

    function testPartialRevocationPreservesOtherAttestations() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 2, keccak256("worldcoin_proof"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, 3, keccak256("gitcoin_proof"));

        // Revoke only the Worldcoin attestation (index 0)
        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);

        // Gitcoin attestation survives (was swapped to index 0)
        IdentityRegistry.Attestation[] memory atts = registry.getAttestations(alice);
        assertEq(atts.length, 1);
        assertEq(atts[0].attestor, attestor2);
        assertEq(atts[0].attestationHash, keccak256("gitcoin_proof"));
        assertEq(registry.getTier(alice), 3);
    }

    // ============ BULK REVOCATION TESTS ============

    function testBulkRevocationByOwnerViaTierReset() public {
        // Multiple attestors attest
        vm.prank(attestor1);
        registry.recordAttestation(alice, 2, keccak256("proof1"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, 4, keccak256("proof2"));

        assertEq(registry.getTier(alice), 4);

        // Owner can override tier to 0 (admin revocation)
        vm.prank(owner);
        registry.setTier(alice, 0);
        assertEq(registry.getTier(alice), 0);

        // Note: attestations array still exists but tier is overridden
        // A new attestation with tier > 0 would upgrade again
    }

    function testBulkRevocationMultipleUsers() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof_a"));
        vm.prank(attestor1);
        registry.recordAttestation(bob, 2, keccak256("proof_b"));

        // Revoke both
        vm.startPrank(attestor1);
        registry.revokeAttestation(alice, 0);
        registry.revokeAttestation(bob, 0);
        vm.stopPrank();

        assertEq(registry.getTier(alice), 0);
        assertEq(registry.getTier(bob), 0);
    }

    // ============ REMOVED ATTESTOR REVOCATION ============

    function testRemovedAttestorCannotRevoke() public {
        vm.prank(attestor1);
        registry.recordAttestation(alice, 3, keccak256("proof1"));

        // Owner removes attestor1
        vm.prank(owner);
        registry.removeAttestor(attestor1);

        // Attestor1 can no longer revoke
        vm.prank(attestor1);
        vm.expectRevert(IdentityRegistry.NotAttestor.selector);
        registry.revokeAttestation(alice, 0);

        // Tier persists since revocation was blocked
        assertEq(registry.getTier(alice), 3);
    }

    // ============ SWAP-AND-POP CORRECTNESS ============

    function testSwapAndPopPreservesCorrectData() public {
        // Create 3 attestations
        vm.prank(attestor1);
        registry.recordAttestation(alice, 1, keccak256("proof1"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, 2, keccak256("proof2"));
        vm.prank(attestor3);
        registry.recordAttestation(alice, 3, keccak256("proof3"));

        // Revoke index 0 (attestor1) -- attestor3's entry moves to index 0
        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);

        IdentityRegistry.Attestation[] memory atts = registry.getAttestations(alice);
        assertEq(atts.length, 2);
        // Index 0 should now be attestor3's data (swapped from index 2)
        assertEq(atts[0].attestor, attestor3);
        assertEq(atts[0].tier, 3);
        assertEq(atts[0].attestationHash, keccak256("proof3"));
        // Index 1 should still be attestor2's data
        assertEq(atts[1].attestor, attestor2);
        assertEq(atts[1].tier, 2);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_RevocationRecalculatesTier(uint8 tier1, uint8 tier2) public {
        vm.assume(tier1 > 0 && tier2 > 0);

        vm.prank(attestor1);
        registry.recordAttestation(alice, tier1, keccak256("proof1"));
        vm.prank(attestor2);
        registry.recordAttestation(alice, tier2, keccak256("proof2"));

        uint8 maxTier = tier1 > tier2 ? tier1 : tier2;
        assertEq(registry.getTier(alice), maxTier);

        // Revoke first attestation (index 0 = attestor1's tier1)
        vm.prank(attestor1);
        registry.revokeAttestation(alice, 0);

        // After revoking tier1, remaining is tier2
        assertEq(registry.getTier(alice), tier2);
    }
}
