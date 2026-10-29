// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IIdentityRegistry.sol";

/**
 * @title IdentityRegistry
 * @notice Manages identity tiers and attestations for sybil resistance
 * @dev Tier 0 = default (anyone), higher tiers require attestations
 */
contract IdentityRegistry is IIdentityRegistry, Ownable2Step {

    mapping(address => uint8) private _tiers;
    mapping(address => bool) private _attestors;

    struct Attestation {
        address attestor;
        uint8 tier;
        bytes32 attestationHash;
        uint256 timestamp;
    }

    mapping(address => Attestation[]) private _attestations;

    error NotAttestor();
    error InvalidTier();
    error ZeroAddress();

    modifier onlyAttestor() {
        if (!_attestors[msg.sender]) revert NotAttestor();
        _;
    }

    constructor() Ownable() {}

    /**
     * @notice Set tier for a user (owner only)
     * @param user Address to set tier for
     * @param tier New tier level
     */
    function setTier(address user, uint8 tier) external override onlyOwner {
        if (user == address(0)) revert ZeroAddress();

        uint8 oldTier = _tiers[user];
        _tiers[user] = tier;

        emit TierUpdated(user, oldTier, tier);
    }

    /**
     * @notice Get tier for a user
     * @param user Address to query
     * @return Current tier level (0 = default)
     */
    function getTier(address user) external view override returns (uint8) {
        return _tiers[user];
    }

    /**
     * @notice Check if user meets tier requirement
     * @param user Address to check
     * @param requiredTier Minimum tier required
     * @return True if user tier >= required tier
     */
    function meetsRequirement(address user, uint8 requiredTier) external view override returns (bool) {
        return _tiers[user] >= requiredTier;
    }

    /**
     * @notice Add an attestor (owner only)
     * @param attestor Address to grant attestor role
     */
    function addAttestor(address attestor) external override onlyOwner {
        if (attestor == address(0)) revert ZeroAddress();

        _attestors[attestor] = true;
        emit AttestorAdded(attestor);
    }

    /**
     * @notice Remove an attestor (owner only)
     * @param attestor Address to revoke attestor role
     */
    function removeAttestor(address attestor) external override onlyOwner {
        _attestors[attestor] = false;
        emit AttestorRemoved(attestor);
    }

    /**
     * @notice Check if address is an attestor
     */
    function isAttestor(address account) external view override returns (bool) {
        return _attestors[account];
    }

    /**
     * @notice Record an attestation and update tier (attestor only)
     * @param user Address being attested
     * @param tier Tier level to grant
     * @param attestationHash Hash of attestation data (e.g., proof hash)
     */
    function recordAttestation(
        address user,
        uint8 tier,
        bytes32 attestationHash
    ) external override onlyAttestor {
        if (user == address(0)) revert ZeroAddress();

        uint8 oldTier = _tiers[user];

        // Only upgrade tier, never downgrade via attestation
        if (tier > oldTier) {
            _tiers[user] = tier;
            emit TierUpdated(user, oldTier, tier);
        }

        _attestations[user].push(Attestation({
            attestor: msg.sender,
            tier: tier,
            attestationHash: attestationHash,
            timestamp: block.timestamp
        }));

        emit AttestationRecorded(user, msg.sender, tier, attestationHash);
    }

    /**
     * @notice Revoke an attestation you previously issued (attestor only).
     *         Recalculates the user's tier as the max of remaining attestations.
     * @param user Address whose attestation to revoke
     * @param attestationIndex Index in the user's attestation array
     */
    function revokeAttestation(address user, uint256 attestationIndex) external override onlyAttestor {
        Attestation[] storage atts = _attestations[user];
        require(attestationIndex < atts.length, "IdentityRegistry: invalid index");
        require(atts[attestationIndex].attestor == msg.sender, "IdentityRegistry: not your attestation");

        // Remove attestation (swap-and-pop)
        atts[attestationIndex] = atts[atts.length - 1];
        atts.pop();

        // Recalculate tier as max of remaining attestations
        uint8 oldTier = _tiers[user];
        uint8 newTier = 0;
        for (uint256 i = 0; i < atts.length; i++) {
            if (atts[i].tier > newTier) {
                newTier = atts[i].tier;
            }
        }

        if (newTier != oldTier) {
            _tiers[user] = newTier;
            emit TierUpdated(user, oldTier, newTier);
        }

        emit AttestationRevoked(user, msg.sender, attestationIndex);
    }

    /**
     * @notice Get all attestations for a user
     */
    function getAttestations(address user) external view returns (Attestation[] memory) {
        return _attestations[user];
    }
}
