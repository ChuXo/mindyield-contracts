// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIdentityRegistry
 * @notice Interface for managing identity tiers and attestations
 */
interface IIdentityRegistry {
    event TierUpdated(address indexed user, uint8 oldTier, uint8 newTier);
    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);
    event AttestationRecorded(
        address indexed user,
        address indexed attestor,
        uint8 tier,
        bytes32 attestationHash
    );
    event AttestationRevoked(
        address indexed user,
        address indexed attestor,
        uint256 attestationIndex
    );

    function setTier(address user, uint8 tier) external;

    function getTier(address user) external view returns (uint8);

    function meetsRequirement(address user, uint8 requiredTier) external view returns (bool);

    function addAttestor(address attestor) external;

    function removeAttestor(address attestor) external;

    function isAttestor(address account) external view returns (bool);

    function recordAttestation(
        address user,
        uint8 tier,
        bytes32 attestationHash
    ) external;

    function revokeAttestation(address user, uint256 attestationIndex) external;
}
