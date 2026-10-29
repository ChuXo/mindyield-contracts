// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IHumanVerifier.sol";

/**
 * @title IGitcoinPassportDecoder
 * @notice Minimal interface for Gitcoin Passport on-chain decoder
 */
interface IGitcoinPassportDecoder {
    function getScore(address user) external view returns (uint256);
    function isHuman(address user) external view returns (bool);
}

/**
 * @title GitcoinPassportVerifier
 * @notice Human verification using Gitcoin Passport scores
 * @dev Implements IHumanVerifier for Gitcoin Passport integration
 */
contract GitcoinPassportVerifier is IHumanVerifier, Ownable2Step {
    // ============ State Variables ============

    IGitcoinPassportDecoder public passportDecoder;

    // Minimum score thresholds for different tiers (scaled by 100)
    uint256 public tierOneThreshold = 1500; // 15.00 score
    uint256 public tierTwoThreshold = 2500; // 25.00 score
    uint256 public tierThreeThreshold = 4000; // 40.00 score

    // Cached verification data
    struct VerificationCache {
        uint256 cachedScore;
        uint256 cachedAt;
        bool manuallyVerified;
    }
    mapping(address => VerificationCache) public verificationCache;

    // Cache validity period
    uint256 public cacheValidity = 1 days;

    // ============ Events ============

    event ThresholdsUpdated(uint256 tierOne, uint256 tierTwo, uint256 tierThree);
    event DecoderUpdated(address indexed newDecoder);
    event ManualVerification(address indexed user, bool verified);

    // ============ Constructor ============

    constructor(address _passportDecoder) Ownable() {
        require(_passportDecoder != address(0), "GitcoinPassportVerifier: invalid decoder");
        passportDecoder = IGitcoinPassportDecoder(_passportDecoder);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update score thresholds for tiers
     * @param _tierOne Tier 1 threshold
     * @param _tierTwo Tier 2 threshold
     * @param _tierThree Tier 3 threshold
     */
    function setThresholds(
        uint256 _tierOne,
        uint256 _tierTwo,
        uint256 _tierThree
    ) external onlyOwner {
        require(_tierOne < _tierTwo && _tierTwo < _tierThree, "GitcoinPassportVerifier: invalid thresholds");
        tierOneThreshold = _tierOne;
        tierTwoThreshold = _tierTwo;
        tierThreeThreshold = _tierThree;
        emit ThresholdsUpdated(_tierOne, _tierTwo, _tierThree);
    }

    /**
     * @notice Update the passport decoder address
     * @param _decoder New decoder address
     */
    function setDecoder(address _decoder) external onlyOwner {
        require(_decoder != address(0), "GitcoinPassportVerifier: invalid decoder");
        passportDecoder = IGitcoinPassportDecoder(_decoder);
        emit DecoderUpdated(_decoder);
    }

    /**
     * @notice Set cache validity period
     * @param _validity Validity period in seconds
     */
    function setCacheValidity(uint256 _validity) external onlyOwner {
        cacheValidity = _validity;
    }

    /**
     * @notice Manually verify or unverify a user
     * @param user User address
     * @param verified Whether to verify or unverify
     */
    function setManualVerification(address user, bool verified) external onlyOwner {
        verificationCache[user].manuallyVerified = verified;
        emit ManualVerification(user, verified);
    }

    // ============ User Functions ============

    /**
     * @notice Refresh score cache for a user
     * @param user Address to refresh
     */
    function refreshScore(address user) external {
        uint256 score = passportDecoder.getScore(user);
        verificationCache[user].cachedScore = score;
        verificationCache[user].cachedAt = block.timestamp;
    }

    // ============ IHumanVerifier Implementation ============

    /**
     * @notice Check if an address is verified as human
     * @param user Address to check
     * @return Whether the address is verified
     */
    function isVerified(address user) external view override returns (bool) {
        if (verificationCache[user].manuallyVerified) return true;

        uint256 score = _getScore(user);
        return score >= tierOneThreshold;
    }

    /**
     * @notice Get the verification tier for an address
     * @param user Address to check
     * @return tier Verification tier (0 = unverified, 1-3 based on score)
     */
    function getVerificationTier(address user) external view override returns (uint256 tier) {
        if (verificationCache[user].manuallyVerified) return 3;

        uint256 score = _getScore(user);

        if (score >= tierThreeThreshold) return 3;
        if (score >= tierTwoThreshold) return 2;
        if (score >= tierOneThreshold) return 1;
        return 0;
    }

    /**
     * @notice Get verification timestamp (when score was last cached)
     * @param user Address to check
     * @return timestamp Cache timestamp
     */
    function getVerificationTimestamp(address user) external view override returns (uint256 timestamp) {
        return verificationCache[user].cachedAt;
    }

    /**
     * @notice Check if verification is still valid (cache is fresh)
     * @param user Address to check
     * @return isValid Whether cache is still valid
     */
    function isVerificationValid(address user) external view override returns (bool isValid) {
        if (verificationCache[user].manuallyVerified) return true;

        VerificationCache storage cache = verificationCache[user];
        if (cache.cachedAt == 0) return false;

        return block.timestamp <= cache.cachedAt + cacheValidity;
    }

    /**
     * @notice Get the name of this verifier
     * @return name Verifier name
     */
    function getVerifierName() external pure override returns (string memory name) {
        return "Gitcoin Passport";
    }

    // ============ Internal Functions ============

    /**
     * @notice Get score for user (from cache or directly)
     * @param user Address to check
     * @return score Passport score
     */
    function _getScore(address user) internal view returns (uint256 score) {
        VerificationCache storage cache = verificationCache[user];

        // Use cached score if still valid
        if (cache.cachedAt > 0 && block.timestamp <= cache.cachedAt + cacheValidity) {
            return cache.cachedScore;
        }

        // Otherwise query decoder (note: this will fail if called in view context
        // and decoder doesn't support view mode)
        try passportDecoder.getScore(user) returns (uint256 _score) {
            return _score;
        } catch {
            return cache.cachedScore;
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get current score for a user
     * @param user Address to check
     * @return score Current passport score
     */
    function getScore(address user) external view returns (uint256 score) {
        return _getScore(user);
    }

    /**
     * @notice Get all thresholds
     * @return tierOne Tier 1 threshold
     * @return tierTwo Tier 2 threshold
     * @return tierThree Tier 3 threshold
     */
    function getThresholds() external view returns (
        uint256 tierOne,
        uint256 tierTwo,
        uint256 tierThree
    ) {
        return (tierOneThreshold, tierTwoThreshold, tierThreeThreshold);
    }
}
