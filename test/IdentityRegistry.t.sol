// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/IdentityRegistry.sol";

/**
 * @title IdentityRegistryTest
 * @notice Comprehensive tests for the IdentityRegistry contract
 */
contract IdentityRegistryTest is Test {
    IdentityRegistry public registry;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);
    address public attestor1 = address(4);
    address public attestor2 = address(5);
    address public attacker = address(0xBAD);

    event TierUpdated(address indexed user, uint8 oldTier, uint8 newTier);
    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);
    event AttestationRecorded(address indexed user, address indexed attestor, uint8 tier, bytes32 attestationHash);

    function setUp() public {
        vm.prank(owner);
        registry = new IdentityRegistry();
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.getTier(alice), 0);
    }

    // ============ TIER MANAGEMENT TESTS ============

    function testSetTier() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TierUpdated(alice, 0, 3);
        registry.setTier(alice, 3);

        assertEq(registry.getTier(alice), 3);
    }

    function testSetTierMultipleUsers() public {
        vm.startPrank(owner);
        registry.setTier(alice, 1);
        registry.setTier(bob, 2);
        vm.stopPrank();

        assertEq(registry.getTier(alice), 1);
        assertEq(registry.getTier(bob), 2);
    }

    function testUpdateTier() public {
        vm.startPrank(owner);
        registry.setTier(alice, 1);
        registry.setTier(alice, 3);
        vm.stopPrank();

        assertEq(registry.getTier(alice), 3);
    }

    function testDowngradeTier() public {
        vm.startPrank(owner);
        registry.setTier(alice, 3);
        registry.setTier(alice, 1);
        vm.stopPrank();

        assertEq(registry.getTier(alice), 1);
    }

    function testCannotSetTierForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IdentityRegistry.ZeroAddress.selector);
        registry.setTier(address(0), 1);
    }

    function testNonOwnerCannotSetTier() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setTier(alice, 1);
    }

    // ============ TIER REQUIREMENT TESTS ============

    function testMeetsRequirementExact() public {
        vm.prank(owner);
        registry.setTier(alice, 2);

        assertTrue(registry.meetsRequirement(alice, 2));
    }

    function testMeetsRequirementHigherTier() public {
        vm.prank(owner);
        registry.setTier(alice, 3);

        assertTrue(registry.meetsRequirement(alice, 2));
        assertTrue(registry.meetsRequirement(alice, 1));
    }

    function testDoesNotMeetRequirement() public {
        vm.prank(owner);
        registry.setTier(alice, 1);

        assertFalse(registry.meetsRequirement(alice, 2));
    }

    function testDefaultTierMeetsZeroRequirement() public view {
        assertTrue(registry.meetsRequirement(alice, 0));
    }

    function testDefaultTierDoesNotMeetHigherRequirement() public view {
        assertFalse(registry.meetsRequirement(alice, 1));
    }

    // ============ ATTESTOR MANAGEMENT TESTS ============

    function testAddAttestor() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit AttestorAdded(attestor1);
        registry.addAttestor(attestor1);

        assertTrue(registry.isAttestor(attestor1));
    }

    function testAddMultipleAttestors() public {
        vm.startPrank(owner);
        registry.addAttestor(attestor1);
        registry.addAttestor(attestor2);
        vm.stopPrank();

        assertTrue(registry.isAttestor(attestor1));
        assertTrue(registry.isAttestor(attestor2));
    }

    function testCannotAddZeroAddressAsAttestor() public {
        vm.prank(owner);
        vm.expectRevert(IdentityRegistry.ZeroAddress.selector);
        registry.addAttestor(address(0));
    }

    function testNonOwnerCannotAddAttestor() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.addAttestor(attestor1);
    }

    function testRemoveAttestor() public {
        vm.startPrank(owner);
        registry.addAttestor(attestor1);

        vm.expectEmit(true, true, true, true);
        emit AttestorRemoved(attestor1);
        registry.removeAttestor(attestor1);
        vm.stopPrank();

        assertFalse(registry.isAttestor(attestor1));
    }

    function testNonOwnerCannotRemoveAttestor() public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.removeAttestor(attestor1);
    }

    // ============ ATTESTATION TESTS ============

    function testRecordAttestation() public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        bytes32 attestationHash = keccak256("proof_data");

        vm.prank(attestor1);
        vm.expectEmit(true, true, true, true);
        emit AttestationRecorded(alice, attestor1, 2, attestationHash);
        registry.recordAttestation(alice, 2, attestationHash);

        assertEq(registry.getTier(alice), 2);
    }

    function testAttestationUpgradesTier() public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        vm.startPrank(attestor1);
        registry.recordAttestation(alice, 1, bytes32(uint256(1)));
        registry.recordAttestation(alice, 3, bytes32(uint256(2)));
        vm.stopPrank();

        assertEq(registry.getTier(alice), 3);
    }

    function testAttestationDoesNotDowngradeTier() public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        vm.startPrank(attestor1);
        registry.recordAttestation(alice, 3, bytes32(uint256(1)));
        registry.recordAttestation(alice, 1, bytes32(uint256(2))); // Lower tier
        vm.stopPrank();

        // Tier should remain 3
        assertEq(registry.getTier(alice), 3);
    }

    function testNonAttestorCannotRecordAttestation() public {
        vm.prank(attacker);
        vm.expectRevert(IdentityRegistry.NotAttestor.selector);
        registry.recordAttestation(alice, 2, bytes32(uint256(1)));
    }

    function testCannotAttestZeroAddress() public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        vm.prank(attestor1);
        vm.expectRevert(IdentityRegistry.ZeroAddress.selector);
        registry.recordAttestation(address(0), 2, bytes32(uint256(1)));
    }

    function testGetAttestations() public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        bytes32 hash1 = bytes32(uint256(1));
        bytes32 hash2 = bytes32(uint256(2));

        vm.startPrank(attestor1);
        registry.recordAttestation(alice, 1, hash1);
        registry.recordAttestation(alice, 2, hash2);
        vm.stopPrank();

        IdentityRegistry.Attestation[] memory attestations = registry.getAttestations(alice);

        assertEq(attestations.length, 2);
        assertEq(attestations[0].attestor, attestor1);
        assertEq(attestations[0].tier, 1);
        assertEq(attestations[0].attestationHash, hash1);
        assertEq(attestations[1].tier, 2);
        assertEq(attestations[1].attestationHash, hash2);
    }

    function testMultipleAttestorsCanAttest() public {
        vm.startPrank(owner);
        registry.addAttestor(attestor1);
        registry.addAttestor(attestor2);
        vm.stopPrank();

        vm.prank(attestor1);
        registry.recordAttestation(alice, 1, bytes32(uint256(1)));

        vm.prank(attestor2);
        registry.recordAttestation(alice, 2, bytes32(uint256(2)));

        IdentityRegistry.Attestation[] memory attestations = registry.getAttestations(alice);

        assertEq(attestations.length, 2);
        assertEq(attestations[0].attestor, attestor1);
        assertEq(attestations[1].attestor, attestor2);
    }

    function testRemovedAttestorCannotAttest() public {
        vm.startPrank(owner);
        registry.addAttestor(attestor1);
        registry.removeAttestor(attestor1);
        vm.stopPrank();

        vm.prank(attestor1);
        vm.expectRevert(IdentityRegistry.NotAttestor.selector);
        registry.recordAttestation(alice, 2, bytes32(uint256(1)));
    }

    // ============ OWNERSHIP TESTS ============

    function testTransferOwnership() public {
        // Ownable2Step: transferOwnership stages pendingOwner; new owner must
        // call acceptOwnership() to complete the handoff.
        address newOwner = address(100);

        vm.prank(owner);
        registry.transferOwnership(newOwner);
        assertEq(registry.pendingOwner(), newOwner, "pending set");
        assertEq(registry.owner(), owner, "owner unchanged until accept");

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner, "ownership transferred");
    }

    function testCannotTransferOwnershipToZero() public {
        // Ownable2Step accepts address(0) and clears the pendingOwner — does NOT revert.
        vm.prank(owner);
        registry.transferOwnership(address(0));
        assertEq(registry.pendingOwner(), address(0), "pending cleared");
        assertEq(registry.owner(), owner, "owner unchanged");
    }

    function testNonOwnerCannotTransferOwnership() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.transferOwnership(attacker);
    }

    function testNewOwnerCanManageAttestors() public {
        // Ownable2Step requires acceptOwnership() to complete the handoff.
        address newOwner = address(100);

        vm.prank(owner);
        registry.transferOwnership(newOwner);
        vm.prank(newOwner);
        registry.acceptOwnership();

        vm.prank(newOwner);
        registry.addAttestor(attestor1);

        assertTrue(registry.isAttestor(attestor1));
    }

    // ============ FUZZ TESTS ============

    function testFuzz_SetTier(address user, uint8 tier) public {
        vm.assume(user != address(0));

        vm.prank(owner);
        registry.setTier(user, tier);

        assertEq(registry.getTier(user), tier);
    }

    function testFuzz_MeetsRequirement(uint8 userTier, uint8 requiredTier) public {
        vm.prank(owner);
        registry.setTier(alice, userTier);

        bool meets = registry.meetsRequirement(alice, requiredTier);

        assertEq(meets, userTier >= requiredTier);
    }

    function testFuzz_AttestationUpgradesOnly(uint8 tier1, uint8 tier2) public {
        vm.prank(owner);
        registry.addAttestor(attestor1);

        vm.startPrank(attestor1);
        registry.recordAttestation(alice, tier1, bytes32(uint256(1)));
        registry.recordAttestation(alice, tier2, bytes32(uint256(2)));
        vm.stopPrank();

        uint8 expectedTier = tier1 > tier2 ? tier1 : tier2;
        assertEq(registry.getTier(alice), expectedTier);
    }

    function testFuzz_MultipleUsersIndependent(uint8 aliceTier, uint8 bobTier) public {
        vm.startPrank(owner);
        registry.setTier(alice, aliceTier);
        registry.setTier(bob, bobTier);
        vm.stopPrank();

        assertEq(registry.getTier(alice), aliceTier);
        assertEq(registry.getTier(bob), bobTier);
    }
}
