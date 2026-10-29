// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/verifiers/WorldcoinVerifier.sol";
import "../src/HumanVerificationRegistry.sol";

/**
 * @title MockWorldID
 * @notice Mock implementation of IWorldID for testing
 */
contract MockWorldID is IWorldID {
    bool public shouldRevert;
    string public revertReason;

    function verifyProof(
        uint256, /* root */
        uint256, /* groupId */
        uint256, /* signalHash */
        uint256, /* nullifierHash */
        uint256, /* externalNullifier */
        uint256[8] calldata /* proof */
    ) external view {
        if (shouldRevert) {
            revert(revertReason);
        }
    }

    function setShouldRevert(bool _shouldRevert, string memory _reason) external {
        shouldRevert = _shouldRevert;
        revertReason = _reason;
    }
}

/**
 * @title WorldcoinVerifierTest
 * @notice Isolated tests for the WorldcoinVerifier contract
 */
contract WorldcoinVerifierTest is Test {
    WorldcoinVerifier public verifier;
    MockWorldID public mockWorldId;
    HumanVerificationRegistry public registry;

    address public owner = address(this);
    address public alice = address(2);
    address public bob = address(3);
    address public attacker = address(0xBAD);

    uint256 public constant GROUP_ID = 1;
    string public constant APP_ID = "app_mindyield";
    string public constant ACTION_ID = "verify_human";

    uint256 public constant VALID_ROOT = 12345;
    uint256 public constant NULLIFIER_ALICE = 111111;
    uint256 public constant NULLIFIER_BOB = 222222;

    event Verified(address indexed user, uint256 nullifierHash, uint256 tier);
    event VerificationRevoked(address indexed user);
    event ValidityPeriodUpdated(uint256 newPeriod);

    function setUp() public {
        mockWorldId = new MockWorldID();
        verifier = new WorldcoinVerifier(
            address(mockWorldId),
            GROUP_ID,
            APP_ID,
            ACTION_ID
        );
    }

    function _dummyProof() internal pure returns (uint256[8] memory) {
        uint256[8] memory proof;
        for (uint256 i = 0; i < 8; i++) {
            proof[i] = i + 1;
        }
        return proof;
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(address(verifier.worldId()), address(mockWorldId));
        assertEq(verifier.groupId(), GROUP_ID);
        assertEq(verifier.verificationValidity(), 0);
        assertEq(verifier.getVerifierName(), "Worldcoin");
    }

    function testExternalNullifierCalculation() public view {
        uint256 expected = uint256(
            keccak256(abi.encodePacked(keccak256(abi.encodePacked(APP_ID)), ACTION_ID))
        );
        assertEq(verifier.externalNullifier(), expected);
    }

    // ============ VERIFICATION TESTS ============

    function testVerifyWithValidProofOrbTier() public {
        vm.expectEmit(true, false, false, true);
        emit Verified(alice, NULLIFIER_ALICE, 1);

        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        assertTrue(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 1);
        assertEq(verifier.getVerificationTimestamp(alice), block.timestamp);
        assertTrue(verifier.isVerificationValid(alice));
    }

    function testVerifyWithValidProofDeviceTier() public {
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 2);

        assertTrue(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 2);
    }

    function testRejectInvalidProof() public {
        mockWorldId.setShouldRevert(true, "Invalid proof");

        vm.expectRevert("Invalid proof");
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        assertFalse(verifier.isVerified(alice));
    }

    function testRejectDuplicateNullifierHash() public {
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        vm.expectRevert("WorldcoinVerifier: nullifier used");
        verifier.verify(bob, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);
    }

    function testRejectAlreadyVerifiedUser() public {
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        vm.expectRevert("WorldcoinVerifier: already verified");
        verifier.verify(alice, VALID_ROOT, NULLIFIER_BOB, _dummyProof(), 1);
    }

    function testRejectInvalidTierZero() public {
        vm.expectRevert("WorldcoinVerifier: invalid tier");
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 0);
    }

    function testRejectInvalidTierThree() public {
        vm.expectRevert("WorldcoinVerifier: invalid tier");
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 3);
    }

    // ============ EXPIRY TESTS ============

    function testVerificationNeverExpiresWhenValidityZero() public {
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        // Warp far into the future
        vm.warp(block.timestamp + 365 days * 100);

        assertTrue(verifier.isVerified(alice));
        assertTrue(verifier.isVerificationValid(alice));
        assertEq(verifier.getVerificationTier(alice), 1);
    }

    function testVerificationExpiresAfterValidityPeriod() public {
        verifier.setVerificationValidity(30 days);
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        // Still valid before expiry
        vm.warp(block.timestamp + 29 days);
        assertTrue(verifier.isVerified(alice));
        assertTrue(verifier.isVerificationValid(alice));
        assertEq(verifier.getVerificationTier(alice), 1);

        // Expired after validity period
        vm.warp(block.timestamp + 2 days);
        assertFalse(verifier.isVerified(alice));
        assertFalse(verifier.isVerificationValid(alice));
        assertEq(verifier.getVerificationTier(alice), 0);
    }

    // ============ ADMIN TESTS ============

    function testSetVerificationValidity() public {
        vm.expectEmit(false, false, false, true);
        emit ValidityPeriodUpdated(7 days);

        verifier.setVerificationValidity(7 days);
        assertEq(verifier.verificationValidity(), 7 days);
    }

    function testNonOwnerCannotSetValidity() public {
        vm.prank(attacker);
        vm.expectRevert();
        verifier.setVerificationValidity(7 days);
    }

    function testRevokeVerification() public {
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);
        assertTrue(verifier.isVerified(alice));

        vm.expectEmit(true, false, false, true);
        emit VerificationRevoked(alice);
        verifier.revokeVerification(alice);

        assertFalse(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 0);
        // Nullifier should be freed
        assertEq(verifier.nullifierToAddress(NULLIFIER_ALICE), address(0));
    }

    function testRevokeNotVerifiedReverts() public {
        vm.expectRevert("WorldcoinVerifier: not verified");
        verifier.revokeVerification(alice);
    }

    function testNonOwnerCannotRevoke() public {
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        vm.prank(attacker);
        vm.expectRevert();
        verifier.revokeVerification(alice);
    }

    // ============ UNVERIFIED USER TESTS ============

    function testUnverifiedUserReturnsDefaults() public view {
        assertFalse(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 0);
        assertEq(verifier.getVerificationTimestamp(alice), 0);
        assertFalse(verifier.isVerificationValid(alice));
    }

    // ============ INTEGRATION WITH REGISTRY ============

    function testIntegrationWithHumanVerificationRegistry() public {
        registry = new HumanVerificationRegistry();
        bytes32 worldcoinId = keccak256("Worldcoin");

        registry.registerVerifier(worldcoinId, address(verifier));

        // Verify alice via Worldcoin
        verifier.verify(alice, VALID_ROOT, NULLIFIER_ALICE, _dummyProof(), 1);

        // Check via registry
        (bool isHuman, bytes32 vid) = registry.isHumanVerified(alice);
        assertTrue(isHuman);
        assertEq(vid, worldcoinId);

        // Check tier via registry
        (bool meetsTier,, uint256 userTier) = registry.meetsHumanTier(alice, 1);
        assertTrue(meetsTier);
        assertEq(userTier, 1);
    }
}
