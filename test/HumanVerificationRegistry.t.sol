// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HumanVerificationRegistry.sol";
import "../src/interfaces/IHumanVerifier.sol";

/**
 * @title MockHumanVerifier
 * @notice Mock implementation of IHumanVerifier for testing
 */
contract MockHumanVerifier is IHumanVerifier {
    string public name;
    mapping(address => bool) private _verified;
    mapping(address => uint256) private _tier;
    mapping(address => uint256) private _timestamp;
    mapping(address => bool) private _valid;

    constructor(string memory _name) {
        name = _name;
    }

    function isVerified(address user) external view returns (bool) {
        return _verified[user];
    }

    function getVerificationTier(address user) external view returns (uint256) {
        return _tier[user];
    }

    function getVerificationTimestamp(address user) external view returns (uint256) {
        return _timestamp[user];
    }

    function isVerificationValid(address user) external view returns (bool) {
        return _valid[user];
    }

    function getVerifierName() external view returns (string memory) {
        return name;
    }

    // Test helpers
    function setVerified(address user, bool verified) external {
        _verified[user] = verified;
    }

    function setTier(address user, uint256 tier) external {
        _tier[user] = tier;
    }

    function setTimestamp(address user, uint256 timestamp) external {
        _timestamp[user] = timestamp;
    }

    function setValid(address user, bool valid) external {
        _valid[user] = valid;
    }
}

/**
 * @title HumanVerificationRegistryTest
 * @notice Comprehensive tests for the HumanVerificationRegistry contract
 */
contract HumanVerificationRegistryTest is Test {
    HumanVerificationRegistry public registry;
    MockHumanVerifier public worldcoin;
    MockHumanVerifier public gitcoin;
    MockHumanVerifier public civic;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);

    bytes32 public constant WORLDCOIN_ID = keccak256("Worldcoin");
    bytes32 public constant GITCOIN_ID = keccak256("GitcoinPassport");
    bytes32 public constant CIVIC_ID = keccak256("CivicPass");

    event VerifierRegistered(bytes32 indexed verifierId, address verifier, string name);
    event VerifierEnabled(bytes32 indexed verifierId, bool enabled);
    event VerifierRemoved(bytes32 indexed verifierId);
    event DefaultTierUpdated(uint256 newTier);

    function setUp() public {
        vm.startPrank(owner);

        registry = new HumanVerificationRegistry();
        worldcoin = new MockHumanVerifier("Worldcoin");
        gitcoin = new MockHumanVerifier("GitcoinPassport");
        civic = new MockHumanVerifier("CivicPass");

        vm.stopPrank();
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.defaultRequiredTier(), 1);
        assertEq(registry.getVerifierCount(), 0);
    }

    // ============ VERIFIER REGISTRATION TESTS ============

    function testRegisterVerifier() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        assertEq(address(registry.verifiers(WORLDCOIN_ID)), address(worldcoin));
        assertTrue(registry.isVerifierEnabled(WORLDCOIN_ID));
        assertEq(registry.getVerifierCount(), 1);
    }

    function testRegisterVerifierEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit VerifierRegistered(WORLDCOIN_ID, address(worldcoin), "Worldcoin");

        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
    }

    function testRegisterMultipleVerifiers() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.registerVerifier(GITCOIN_ID, address(gitcoin));
        registry.registerVerifier(CIVIC_ID, address(civic));
        vm.stopPrank();

        assertEq(registry.getVerifierCount(), 3);

        bytes32[] memory ids = registry.getVerifierIds();
        assertEq(ids.length, 3);
        assertEq(ids[0], WORLDCOIN_ID);
        assertEq(ids[1], GITCOIN_ID);
        assertEq(ids[2], CIVIC_ID);
    }

    function testRevertRegisterZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("HumanVerificationRegistry: invalid verifier");
        registry.registerVerifier(WORLDCOIN_ID, address(0));
    }

    function testRevertRegisterDuplicateVerifier() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        vm.expectRevert("HumanVerificationRegistry: already registered");
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        vm.stopPrank();
    }

    function testRevertRegisterVerifierNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
    }

    // ============ VERIFIER ENABLE/DISABLE TESTS ============

    function testSetVerifierEnabled() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        registry.setVerifierEnabled(WORLDCOIN_ID, false);
        assertFalse(registry.isVerifierEnabled(WORLDCOIN_ID));

        registry.setVerifierEnabled(WORLDCOIN_ID, true);
        assertTrue(registry.isVerifierEnabled(WORLDCOIN_ID));
        vm.stopPrank();
    }

    function testSetVerifierEnabledEmitsEvent() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        vm.expectEmit(true, false, false, true);
        emit VerifierEnabled(WORLDCOIN_ID, false);
        registry.setVerifierEnabled(WORLDCOIN_ID, false);
        vm.stopPrank();
    }

    function testRevertSetVerifierEnabledNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert("HumanVerificationRegistry: not registered");
        registry.setVerifierEnabled(WORLDCOIN_ID, false);
    }

    // ============ DEFAULT TIER TESTS ============

    function testSetDefaultRequiredTier() public {
        vm.prank(owner);
        registry.setDefaultRequiredTier(3);

        assertEq(registry.defaultRequiredTier(), 3);
    }

    function testSetDefaultRequiredTierEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit DefaultTierUpdated(2);

        vm.prank(owner);
        registry.setDefaultRequiredTier(2);
    }

    // ============ VERIFICATION CHECKS TESTS ============

    function testIsHumanVerified() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        // Alice is verified by Worldcoin
        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, true);

        (bool isVerified, bytes32 verifierId) = registry.isHumanVerified(alice);
        assertTrue(isVerified);
        assertEq(verifierId, WORLDCOIN_ID);
    }

    function testIsHumanVerifiedMultipleVerifiers() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.registerVerifier(GITCOIN_ID, address(gitcoin));
        vm.stopPrank();

        // Alice verified by Gitcoin only
        gitcoin.setVerified(alice, true);
        gitcoin.setValid(alice, true);

        (bool isVerified, bytes32 verifierId) = registry.isHumanVerified(alice);
        assertTrue(isVerified);
        assertEq(verifierId, GITCOIN_ID);
    }

    function testIsHumanVerifiedNotVerified() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        (bool isVerified, bytes32 verifierId) = registry.isHumanVerified(alice);
        assertFalse(isVerified);
        assertEq(verifierId, bytes32(0));
    }

    function testIsHumanVerifiedExpiredVerification() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, false); // Expired

        (bool isVerified,) = registry.isHumanVerified(alice);
        assertFalse(isVerified);
    }

    function testIsHumanVerifiedDisabledVerifier() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.setVerifierEnabled(WORLDCOIN_ID, false);
        vm.stopPrank();

        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, true);

        (bool isVerified,) = registry.isHumanVerified(alice);
        assertFalse(isVerified);
    }

    // ============ TIER VERIFICATION TESTS ============

    function testMeetsHumanTier() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        worldcoin.setValid(alice, true);
        worldcoin.setTier(alice, 3);

        (bool meetsTier, bytes32 verifierId, uint256 userTier) = registry.meetsHumanTier(alice, 2);
        assertTrue(meetsTier);
        assertEq(verifierId, WORLDCOIN_ID);
        assertEq(userTier, 3);
    }

    function testMeetsHumanTierExactMatch() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        worldcoin.setValid(alice, true);
        worldcoin.setTier(alice, 2);

        (bool meetsTier,,uint256 userTier) = registry.meetsHumanTier(alice, 2);
        assertTrue(meetsTier);
        assertEq(userTier, 2);
    }

    function testMeetsHumanTierBelowRequirement() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        worldcoin.setValid(alice, true);
        worldcoin.setTier(alice, 1);

        (bool meetsTier, bytes32 verifierId, uint256 userTier) = registry.meetsHumanTier(alice, 3);
        assertFalse(meetsTier);
        assertEq(verifierId, WORLDCOIN_ID); // Still returns highest tier verifier
        assertEq(userTier, 1);
    }

    function testMeetsHumanTierMultipleVerifiers() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.registerVerifier(GITCOIN_ID, address(gitcoin));
        vm.stopPrank();

        // Alice has tier 1 on Worldcoin, tier 3 on Gitcoin
        worldcoin.setValid(alice, true);
        worldcoin.setTier(alice, 1);
        gitcoin.setValid(alice, true);
        gitcoin.setTier(alice, 3);

        (bool meetsTier, bytes32 verifierId, uint256 userTier) = registry.meetsHumanTier(alice, 2);
        assertTrue(meetsTier);
        assertEq(verifierId, GITCOIN_ID);
        assertEq(userTier, 3);
    }

    // ============ SPECIFIC VERIFIER TESTS ============

    function testIsVerifiedBy() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, true);

        assertTrue(registry.isVerifiedBy(alice, WORLDCOIN_ID));
    }

    function testIsVerifiedByNotRegistered() public {
        assertFalse(registry.isVerifiedBy(alice, WORLDCOIN_ID));
    }

    function testIsVerifiedByDisabled() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.setVerifierEnabled(WORLDCOIN_ID, false);
        vm.stopPrank();

        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, true);

        assertFalse(registry.isVerifiedBy(alice, WORLDCOIN_ID));
    }

    function testIsVerifiedByExpired() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, false);

        assertFalse(registry.isVerifiedBy(alice, WORLDCOIN_ID));
    }

    // ============ VERIFICATION DETAILS TESTS ============

    function testGetVerificationDetails() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.registerVerifier(GITCOIN_ID, address(gitcoin));
        vm.stopPrank();

        worldcoin.setVerified(alice, true);
        worldcoin.setValid(alice, true);
        worldcoin.setTier(alice, 2);

        gitcoin.setVerified(alice, false);
        gitcoin.setValid(alice, true);
        gitcoin.setTier(alice, 0);

        (
            bytes32[] memory verifierIds,
            bool[] memory isVerifiedList,
            uint256[] memory tierList
        ) = registry.getVerificationDetails(alice);

        assertEq(verifierIds.length, 2);
        assertEq(verifierIds[0], WORLDCOIN_ID);
        assertEq(verifierIds[1], GITCOIN_ID);

        assertTrue(isVerifiedList[0]);
        assertFalse(isVerifiedList[1]);

        assertEq(tierList[0], 2);
        assertEq(tierList[1], 0);
    }

    function testGetVerificationDetailsDisabledVerifier() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.setVerifierEnabled(WORLDCOIN_ID, false);
        vm.stopPrank();

        worldcoin.setVerified(alice, true);
        worldcoin.setTier(alice, 3);

        (
            ,
            bool[] memory isVerifiedList,
            uint256[] memory tierList
        ) = registry.getVerificationDetails(alice);

        // Disabled verifier returns false/0
        assertFalse(isVerifiedList[0]);
        assertEq(tierList[0], 0);
    }

    // ============ VIEW FUNCTIONS TESTS ============

    function testGetVerifierInfo() public {
        vm.prank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));

        (address verifier, bool enabled, string memory name) = registry.getVerifierInfo(WORLDCOIN_ID);

        assertEq(verifier, address(worldcoin));
        assertTrue(enabled);
        assertEq(name, "Worldcoin");
    }

    function testGetVerifierInfoNotRegistered() public {
        (address verifier, bool enabled, string memory name) = registry.getVerifierInfo(WORLDCOIN_ID);

        assertEq(verifier, address(0));
        assertFalse(enabled);
        assertEq(name, "");
    }

    function testGetVerifierInfoDisabled() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.setVerifierEnabled(WORLDCOIN_ID, false);
        vm.stopPrank();

        (, bool enabled,) = registry.getVerifierInfo(WORLDCOIN_ID);
        assertFalse(enabled);
    }

    function testGetVerifierId() public view {
        bytes32 id = registry.getVerifierId("Worldcoin");
        assertEq(id, WORLDCOIN_ID);
    }

    function testGetVerifierIds() public {
        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        registry.registerVerifier(GITCOIN_ID, address(gitcoin));
        vm.stopPrank();

        bytes32[] memory ids = registry.getVerifierIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], WORLDCOIN_ID);
        assertEq(ids[1], GITCOIN_ID);
    }

    function testGetVerifierCount() public {
        assertEq(registry.getVerifierCount(), 0);

        vm.startPrank(owner);
        registry.registerVerifier(WORLDCOIN_ID, address(worldcoin));
        assertEq(registry.getVerifierCount(), 1);

        registry.registerVerifier(GITCOIN_ID, address(gitcoin));
        assertEq(registry.getVerifierCount(), 2);
        vm.stopPrank();
    }
}
