// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/verifiers/GitcoinPassportVerifier.sol";
import "../src/HumanVerificationRegistry.sol";

/**
 * @title MockGitcoinPassportDecoder
 * @notice Mock implementation of IGitcoinPassportDecoder for testing
 */
contract MockGitcoinPassportDecoder is IGitcoinPassportDecoder {
    mapping(address => uint256) public scores;
    mapping(address => bool) public humans;
    bool public shouldRevert;

    function setScore(address user, uint256 score) external {
        scores[user] = score;
    }

    function setIsHuman(address user, bool _isHuman) external {
        humans[user] = _isHuman;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getScore(address user) external view override returns (uint256) {
        if (shouldRevert) revert("Decoder unavailable");
        return scores[user];
    }

    function isHuman(address user) external view override returns (bool) {
        return humans[user];
    }
}

/**
 * @title GitcoinPassportVerifierTest
 * @notice Isolated tests for the GitcoinPassportVerifier contract
 */
contract GitcoinPassportVerifierTest is Test {
    GitcoinPassportVerifier public verifier;
    MockGitcoinPassportDecoder public decoder;
    HumanVerificationRegistry public registry;

    address public owner = address(this);
    address public alice = address(2);
    address public bob = address(3);
    address public attacker = address(0xBAD);

    // Default thresholds (scaled by 100)
    uint256 public constant TIER_ONE = 1500;   // 15.00
    uint256 public constant TIER_TWO = 2500;   // 25.00
    uint256 public constant TIER_THREE = 4000; // 40.00

    event ThresholdsUpdated(uint256 tierOne, uint256 tierTwo, uint256 tierThree);
    event DecoderUpdated(address indexed newDecoder);
    event ManualVerification(address indexed user, bool verified);

    function setUp() public {
        decoder = new MockGitcoinPassportDecoder();
        verifier = new GitcoinPassportVerifier(address(decoder));
    }

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(address(verifier.passportDecoder()), address(decoder));
        assertEq(verifier.tierOneThreshold(), TIER_ONE);
        assertEq(verifier.tierTwoThreshold(), TIER_TWO);
        assertEq(verifier.tierThreeThreshold(), TIER_THREE);
        assertEq(verifier.cacheValidity(), 1 days);
        assertEq(verifier.getVerifierName(), "Gitcoin Passport");
    }

    function testRevertDeployWithZeroDecoder() public {
        vm.expectRevert("GitcoinPassportVerifier: invalid decoder");
        new GitcoinPassportVerifier(address(0));
    }

    // ============ SCORE AND TIER CALCULATION TESTS ============

    function testScoreBelowTierOneReturnsUnverified() public {
        decoder.setScore(alice, 1000); // Below 15.00
        verifier.refreshScore(alice);

        assertFalse(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 0);
    }

    function testScoreAtTierOneThreshold() public {
        decoder.setScore(alice, TIER_ONE);
        verifier.refreshScore(alice);

        assertTrue(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 1);
    }

    function testScoreAtTierTwoThreshold() public {
        decoder.setScore(alice, TIER_TWO);
        verifier.refreshScore(alice);

        assertTrue(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 2);
    }

    function testScoreAtTierThreeThreshold() public {
        decoder.setScore(alice, TIER_THREE);
        verifier.refreshScore(alice);

        assertTrue(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 3);
    }

    function testScoreBetweenTiers() public {
        decoder.setScore(alice, 2000); // Between tier 1 (1500) and tier 2 (2500)
        verifier.refreshScore(alice);

        assertEq(verifier.getVerificationTier(alice), 1);
    }

    // ============ CACHE VALIDITY TESTS ============

    function testRefreshScoreCachesTimestamp() public {
        decoder.setScore(alice, 3000);
        uint256 ts = block.timestamp;
        verifier.refreshScore(alice);

        assertEq(verifier.getVerificationTimestamp(alice), ts);
        assertEq(verifier.getScore(alice), 3000);
    }

    function testCacheExpiresAfterValidityPeriod() public {
        decoder.setScore(alice, 3000);
        verifier.refreshScore(alice);

        assertTrue(verifier.isVerificationValid(alice));

        // Warp past cache validity
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(verifier.isVerificationValid(alice));
    }

    function testCacheStillValidBeforeExpiry() public {
        decoder.setScore(alice, 3000);
        verifier.refreshScore(alice);

        vm.warp(block.timestamp + 1 days);
        assertTrue(verifier.isVerificationValid(alice));
    }

    function testNoCacheReturnsInvalid() public view {
        // User never had their score refreshed
        assertFalse(verifier.isVerificationValid(alice));
    }

    function testFallbackToCachedScoreWhenDecoderFails() public {
        // First, cache a valid score
        decoder.setScore(alice, 3000);
        verifier.refreshScore(alice);

        // Now break the decoder and warp past cache validity
        decoder.setShouldRevert(true);
        vm.warp(block.timestamp + 2 days);

        // _getScore falls back to cached score when decoder reverts
        assertEq(verifier.getScore(alice), 3000);
    }

    // ============ ADMIN THRESHOLD TESTS ============

    function testSetThresholds() public {
        vm.expectEmit(false, false, false, true);
        emit ThresholdsUpdated(1000, 2000, 3000);

        verifier.setThresholds(1000, 2000, 3000);

        (uint256 t1, uint256 t2, uint256 t3) = verifier.getThresholds();
        assertEq(t1, 1000);
        assertEq(t2, 2000);
        assertEq(t3, 3000);
    }

    function testRevertInvalidThresholdOrder() public {
        vm.expectRevert("GitcoinPassportVerifier: invalid thresholds");
        verifier.setThresholds(2000, 1000, 3000); // tier1 > tier2

        vm.expectRevert("GitcoinPassportVerifier: invalid thresholds");
        verifier.setThresholds(1000, 3000, 2000); // tier2 > tier3

        vm.expectRevert("GitcoinPassportVerifier: invalid thresholds");
        verifier.setThresholds(1000, 1000, 2000); // tier1 == tier2 (not strictly less)
    }

    function testNonOwnerCannotSetThresholds() public {
        vm.prank(attacker);
        vm.expectRevert();
        verifier.setThresholds(1000, 2000, 3000);
    }

    // ============ DECODER UPDATE TESTS ============

    function testSetDecoder() public {
        MockGitcoinPassportDecoder newDecoder = new MockGitcoinPassportDecoder();

        vm.expectEmit(true, false, false, true);
        emit DecoderUpdated(address(newDecoder));

        verifier.setDecoder(address(newDecoder));
        assertEq(address(verifier.passportDecoder()), address(newDecoder));
    }

    function testRevertSetDecoderZeroAddress() public {
        vm.expectRevert("GitcoinPassportVerifier: invalid decoder");
        verifier.setDecoder(address(0));
    }

    function testNonOwnerCannotSetDecoder() public {
        vm.prank(attacker);
        vm.expectRevert();
        verifier.setDecoder(address(1));
    }

    // ============ MANUAL VERIFICATION TESTS ============

    function testManualVerificationOverridesScore() public {
        // User has no score at all
        vm.expectEmit(true, false, false, true);
        emit ManualVerification(alice, true);

        verifier.setManualVerification(alice, true);

        assertTrue(verifier.isVerified(alice));
        assertEq(verifier.getVerificationTier(alice), 3); // Manual = tier 3
        assertTrue(verifier.isVerificationValid(alice));
    }

    function testRemoveManualVerification() public {
        verifier.setManualVerification(alice, true);
        assertTrue(verifier.isVerified(alice));

        verifier.setManualVerification(alice, false);
        // Without cached score, not verified
        assertFalse(verifier.isVerified(alice));
    }

    function testNonOwnerCannotSetManualVerification() public {
        vm.prank(attacker);
        vm.expectRevert();
        verifier.setManualVerification(alice, true);
    }

    // ============ CACHE VALIDITY ADMIN ============

    function testSetCacheValidity() public {
        verifier.setCacheValidity(7 days);
        assertEq(verifier.cacheValidity(), 7 days);
    }

    function testNonOwnerCannotSetCacheValidity() public {
        vm.prank(attacker);
        vm.expectRevert();
        verifier.setCacheValidity(7 days);
    }

    // ============ INTEGRATION WITH REGISTRY ============

    function testIntegrationWithHumanVerificationRegistry() public {
        registry = new HumanVerificationRegistry();
        bytes32 gitcoinId = keccak256("GitcoinPassport");

        registry.registerVerifier(gitcoinId, address(verifier));

        // Give alice a high score and cache it
        decoder.setScore(alice, TIER_THREE);
        verifier.refreshScore(alice);

        // Check via registry
        (bool isHuman, bytes32 vid) = registry.isHumanVerified(alice);
        assertTrue(isHuman);
        assertEq(vid, gitcoinId);

        // Check tier via registry
        (bool meetsTier,, uint256 userTier) = registry.meetsHumanTier(alice, 2);
        assertTrue(meetsTier);
        assertEq(userTier, 3);
    }
}
