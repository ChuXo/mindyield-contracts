// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IHumanVerifier
 * @notice Interface for proof-of-human verification providers
 * @dev Implement this interface to add support for different human verification systems
 */
interface IHumanVerifier {
    /**
     * @notice Check if an address is verified as human
     * @param user Address to check
     * @return isVerified Whether the address is verified
     */
    function isVerified(address user) external view returns (bool isVerified);

    /**
     * @notice Get the verification tier for an address
     * @param user Address to check
     * @return tier Verification tier (0 = unverified, higher = more verified)
     */
    function getVerificationTier(address user) external view returns (uint256 tier);

    /**
     * @notice Get verification timestamp
     * @param user Address to check
     * @return timestamp When the user was verified (0 if never)
     */
    function getVerificationTimestamp(address user) external view returns (uint256 timestamp);

    /**
     * @notice Check if verification is still valid
     * @param user Address to check
     * @return isValid Whether verification hasn't expired
     */
    function isVerificationValid(address user) external view returns (bool isValid);

    /**
     * @notice Get the name of this verifier
     * @return name Verifier name (e.g., "Worldcoin", "Gitcoin Passport")
     */
    function getVerifierName() external view returns (string memory name);
}
