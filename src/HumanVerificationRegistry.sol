// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IHumanVerifier.sol";

/**
 * @title HumanVerificationRegistry
 * @notice Aggregates multiple human verification providers
 * @dev Allows contests to require human verification from any supported provider
 */
contract HumanVerificationRegistry is Ownable2Step {
    // ============ State Variables ============

    // Mapping from verifier ID to verifier contract
    mapping(bytes32 => IHumanVerifier) public verifiers;

    // Array of registered verifier IDs
    bytes32[] public verifierIds;

    // Mapping from verifier ID to whether it's enabled
    mapping(bytes32 => bool) public isVerifierEnabled;

    // Default required tier for human verification
    uint256 public defaultRequiredTier = 1;

    // ============ Events ============

    event VerifierRegistered(bytes32 indexed verifierId, address verifier, string name);
    event VerifierEnabled(bytes32 indexed verifierId, bool enabled);
    event VerifierRemoved(bytes32 indexed verifierId);
    event DefaultTierUpdated(uint256 newTier);

    // ============ Constructor ============

    constructor() Ownable() {}

    // ============ Admin Functions ============

    /**
     * @notice Register a new verifier
     * @param verifierId Unique identifier for the verifier
     * @param verifier Verifier contract address
     */
    function registerVerifier(bytes32 verifierId, address verifier) external onlyOwner {
        require(verifier != address(0), "HumanVerificationRegistry: invalid verifier");
        require(address(verifiers[verifierId]) == address(0), "HumanVerificationRegistry: already registered");

        verifiers[verifierId] = IHumanVerifier(verifier);
        verifierIds.push(verifierId);
        isVerifierEnabled[verifierId] = true;

        string memory name = IHumanVerifier(verifier).getVerifierName();
        emit VerifierRegistered(verifierId, verifier, name);
    }

    /**
     * @notice Enable or disable a verifier
     * @param verifierId Verifier identifier
     * @param enabled Whether to enable or disable
     */
    function setVerifierEnabled(bytes32 verifierId, bool enabled) external onlyOwner {
        require(address(verifiers[verifierId]) != address(0), "HumanVerificationRegistry: not registered");
        isVerifierEnabled[verifierId] = enabled;
        emit VerifierEnabled(verifierId, enabled);
    }

    /**
     * @notice Set default required tier
     * @param tier New default tier
     */
    function setDefaultRequiredTier(uint256 tier) external onlyOwner {
        defaultRequiredTier = tier;
        emit DefaultTierUpdated(tier);
    }

    // ============ Verification Functions ============

    /**
     * @notice Check if user is verified by ANY enabled verifier
     * @param user Address to check
     * @return isVerified Whether user is verified
     * @return verifierId ID of the verifier that verified them (if any)
     */
    function isHumanVerified(address user) external view returns (bool isVerified, bytes32 verifierId) {
        for (uint256 i = 0; i < verifierIds.length; i++) {
            bytes32 id = verifierIds[i];
            if (!isVerifierEnabled[id]) continue;

            IHumanVerifier verifier = verifiers[id];
            if (verifier.isVerified(user) && verifier.isVerificationValid(user)) {
                return (true, id);
            }
        }
        return (false, bytes32(0));
    }

    /**
     * @notice Check if user meets a specific tier requirement
     * @param user Address to check
     * @param requiredTier Minimum tier required
     * @return meetsTier Whether user meets the tier
     * @return verifierId ID of the verifier
     * @return userTier User's actual tier
     */
    function meetsHumanTier(
        address user,
        uint256 requiredTier
    ) external view returns (bool meetsTier, bytes32 verifierId, uint256 userTier) {
        for (uint256 i = 0; i < verifierIds.length; i++) {
            bytes32 id = verifierIds[i];
            if (!isVerifierEnabled[id]) continue;

            IHumanVerifier verifier = verifiers[id];
            if (!verifier.isVerificationValid(user)) continue;

            uint256 tier = verifier.getVerificationTier(user);
            if (tier >= requiredTier) {
                return (true, id, tier);
            }

            // Track highest tier even if not meeting requirement
            if (tier > userTier) {
                userTier = tier;
                verifierId = id;
            }
        }

        return (false, verifierId, userTier);
    }

    /**
     * @notice Check if user is verified by a specific verifier
     * @param user Address to check
     * @param verifierId Verifier to check
     * @return isVerified Whether user is verified
     */
    function isVerifiedBy(address user, bytes32 verifierId) external view returns (bool isVerified) {
        IHumanVerifier verifier = verifiers[verifierId];
        if (address(verifier) == address(0)) return false;
        if (!isVerifierEnabled[verifierId]) return false;

        return verifier.isVerified(user) && verifier.isVerificationValid(user);
    }

    /**
     * @notice Get verification details for a user across all verifiers
     * @param user Address to check
     * @return verifierIdList Array of verifier IDs
     * @return isVerifiedList Array indicating if user is verified by each verifier
     * @return tierList Array of tier levels from each verifier
     */
    function getVerificationDetails(address user) external view returns (
        bytes32[] memory verifierIdList,
        bool[] memory isVerifiedList,
        uint256[] memory tierList
    ) {
        uint256 count = verifierIds.length;
        verifierIdList = new bytes32[](count);
        isVerifiedList = new bool[](count);
        tierList = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 id = verifierIds[i];
            IHumanVerifier verifier = verifiers[id];

            verifierIdList[i] = id;
            if (isVerifierEnabled[id] && verifier.isVerificationValid(user)) {
                isVerifiedList[i] = verifier.isVerified(user);
                tierList[i] = verifier.getVerificationTier(user);
            }
        }

        return (verifierIdList, isVerifiedList, tierList);
    }

    // ============ View Functions ============

    /**
     * @notice Get all registered verifier IDs
     * @return Array of verifier IDs
     */
    function getVerifierIds() external view returns (bytes32[] memory) {
        return verifierIds;
    }

    /**
     * @notice Get number of registered verifiers
     * @return count Number of verifiers
     */
    function getVerifierCount() external view returns (uint256 count) {
        return verifierIds.length;
    }

    /**
     * @notice Get verifier info
     * @param verifierId Verifier ID
     * @return verifier Verifier address
     * @return enabled Whether enabled
     * @return name Verifier name
     */
    function getVerifierInfo(bytes32 verifierId) external view returns (
        address verifier,
        bool enabled,
        string memory name
    ) {
        IHumanVerifier v = verifiers[verifierId];
        if (address(v) == address(0)) {
            return (address(0), false, "");
        }
        return (address(v), isVerifierEnabled[verifierId], v.getVerifierName());
    }

    // ============ Helper Functions ============

    /**
     * @notice Generate verifier ID from name
     * @param name Verifier name
     * @return id Verifier ID
     */
    function getVerifierId(string memory name) external pure returns (bytes32 id) {
        return keccak256(abi.encodePacked(name));
    }
}
