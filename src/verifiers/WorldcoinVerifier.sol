// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IHumanVerifier.sol";

/**
 * @title IWorldID
 * @notice Minimal interface for World ID verification
 */
interface IWorldID {
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifier,
        uint256[8] calldata proof
    ) external;
}

/**
 * @title WorldcoinVerifier
 * @notice Human verification using World ID (Worldcoin)
 * @dev Implements IHumanVerifier for Worldcoin integration
 */
contract WorldcoinVerifier is IHumanVerifier, Ownable2Step {
    // ============ State Variables ============

    IWorldID public immutable worldId;
    uint256 public immutable groupId;
    uint256 public immutable externalNullifier;

    // Mapping from nullifier hash to verified address
    mapping(uint256 => address) public nullifierToAddress;

    // Mapping from address to verification data
    struct VerificationData {
        bool isVerified;
        uint256 verifiedAt;
        uint256 nullifierHash;
        uint256 tier; // 1 = Orb verified, 2 = Device verified
    }
    mapping(address => VerificationData) public verifications;

    // Verification validity period (0 = never expires)
    uint256 public verificationValidity;

    // ============ Events ============

    event Verified(address indexed user, uint256 nullifierHash, uint256 tier);
    event VerificationRevoked(address indexed user);
    event ValidityPeriodUpdated(uint256 newPeriod);

    // ============ Constructor ============

    constructor(
        address _worldId,
        uint256 _groupId,
        string memory _appId,
        string memory _actionId
    ) Ownable() {
        worldId = IWorldID(_worldId);
        groupId = _groupId;

        // Calculate external nullifier from app_id and action_id
        externalNullifier = uint256(
            keccak256(abi.encodePacked(keccak256(abi.encodePacked(_appId)), _actionId))
        );

        // Default: verifications never expire
        verificationValidity = 0;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set verification validity period
     * @param _validity Validity period in seconds (0 = never expires)
     */
    function setVerificationValidity(uint256 _validity) external onlyOwner {
        verificationValidity = _validity;
        emit ValidityPeriodUpdated(_validity);
    }

    /**
     * @notice Manually revoke a verification
     * @param user Address to revoke
     */
    function revokeVerification(address user) external onlyOwner {
        require(verifications[user].isVerified, "WorldcoinVerifier: not verified");

        uint256 nullifierHash = verifications[user].nullifierHash;
        delete nullifierToAddress[nullifierHash];
        delete verifications[user];

        emit VerificationRevoked(user);
    }

    // ============ Verification Functions ============

    /**
     * @notice Verify a user's World ID proof
     * @param user Address being verified
     * @param root Merkle tree root
     * @param nullifierHash Unique identifier for this user/action combination
     * @param proof Zero-knowledge proof
     * @param tier Verification tier (1 = Orb, 2 = Device)
     */
    function verify(
        address user,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof,
        uint256 tier
    ) external {
        require(!verifications[user].isVerified, "WorldcoinVerifier: already verified");
        require(nullifierToAddress[nullifierHash] == address(0), "WorldcoinVerifier: nullifier used");
        require(tier == 1 || tier == 2, "WorldcoinVerifier: invalid tier");

        // Calculate signal hash from the user's address
        uint256 signalHash = uint256(keccak256(abi.encodePacked(user)));

        // Verify the proof with World ID
        worldId.verifyProof(
            root,
            groupId,
            signalHash,
            nullifierHash,
            externalNullifier,
            proof
        );

        // Record verification
        verifications[user] = VerificationData({
            isVerified: true,
            verifiedAt: block.timestamp,
            nullifierHash: nullifierHash,
            tier: tier
        });
        nullifierToAddress[nullifierHash] = user;

        emit Verified(user, nullifierHash, tier);
    }

    // ============ IHumanVerifier Implementation ============

    /**
     * @notice Check if an address is verified as human
     * @param user Address to check
     * @return Whether the address is verified
     */
    function isVerified(address user) external view override returns (bool) {
        if (!verifications[user].isVerified) return false;
        return isVerificationValid(user);
    }

    /**
     * @notice Get the verification tier for an address
     * @param user Address to check
     * @return tier Verification tier:
     *         0 = Unverified (no valid World ID proof)
     *         1 = Orb-verified (in-person iris scan at a World ID Orb — highest assurance)
     *         2 = Device-verified (phone-based verification — lower assurance than Orb)
     * @dev Note: Tier 1 (Orb) provides stronger sybil resistance than Tier 2 (Device).
     *      The numbering reflects the order of World ID verification methods, NOT
     *      a quality ranking. Consumers should treat Orb (1) as higher assurance.
     */
    function getVerificationTier(address user) external view override returns (uint256 tier) {
        if (!verifications[user].isVerified) return 0;
        if (!isVerificationValid(user)) return 0;
        return verifications[user].tier;
    }

    /**
     * @notice Get verification timestamp
     * @param user Address to check
     * @return timestamp When the user was verified
     */
    function getVerificationTimestamp(address user) external view override returns (uint256 timestamp) {
        return verifications[user].verifiedAt;
    }

    /**
     * @notice Check if verification is still valid
     * @param user Address to check
     * @return isValid Whether verification hasn't expired
     */
    function isVerificationValid(address user) public view override returns (bool isValid) {
        if (!verifications[user].isVerified) return false;
        if (verificationValidity == 0) return true; // Never expires

        return block.timestamp <= verifications[user].verifiedAt + verificationValidity;
    }

    /**
     * @notice Get the name of this verifier
     * @return name Verifier name
     */
    function getVerifierName() external pure override returns (string memory name) {
        return "Worldcoin";
    }
}
