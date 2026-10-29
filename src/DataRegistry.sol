// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IDataRegistry.sol";

/**
 * @title DataRegistry
 * @notice Stores metadata hashes and results roots for contests on-chain
 * @dev Simple key-value store with events for indexing
 */
contract DataRegistry is IDataRegistry, Ownable2Step {
    struct MetadataRecord {
        bytes32 metadataHash;
        string metadataUri;
        uint256 timestamp;
    }

    struct ResultsRecord {
        bytes32 resultsRoot;
        string resultsUri;
        uint256 timestamp;
    }

    address public authorizedRegistrar;

    mapping(bytes32 => MetadataRecord) private _metadata;
    mapping(bytes32 => ResultsRecord) private _results;
    mapping(bytes32 => address) private _contestOwners;

    error NotContestOwner();
    error NotAuthorizedRegistrar();
    error MetadataAlreadyAnchored();
    error ResultsAlreadyAnchored();

    modifier onlyContestOwner(bytes32 contestId) {
        // For new contestIds (no owner set), only the authorized registrar can set ownership
        if (_contestOwners[contestId] == address(0)) {
            if (msg.sender != authorizedRegistrar) revert NotAuthorizedRegistrar();
        } else if (_contestOwners[contestId] != msg.sender) {
            revert NotContestOwner();
        }
        _;
    }

    constructor(address _registrar) Ownable() {
        require(_registrar != address(0), "DataRegistry: zero registrar");
        authorizedRegistrar = _registrar;
    }

    /**
     * @notice Set the authorized registrar (typically the contest factory)
     * @param registrar Address authorized to register new contest ownership
     */
    function setAuthorizedRegistrar(address registrar) external onlyOwner {
        require(registrar != address(0), "DataRegistry: zero registrar");
        authorizedRegistrar = registrar;
    }

    /**
     * @notice Anchor metadata hash for a contest
     * @param contestId Unique contest identifier
     * @param metadataHash Keccak256 hash of metadata JSON
     * @param metadataUri IPFS URI to metadata JSON
     */
    function anchorMetadata(
        bytes32 contestId,
        bytes32 metadataHash,
        string calldata metadataUri
    ) external override onlyContestOwner(contestId) {
        if (_metadata[contestId].timestamp != 0) {
            revert MetadataAlreadyAnchored();
        }

        _contestOwners[contestId] = msg.sender;
        _metadata[contestId] = MetadataRecord({
            metadataHash: metadataHash,
            metadataUri: metadataUri,
            timestamp: block.timestamp
        });

        emit MetadataAnchored(contestId, metadataHash, metadataUri, block.timestamp);
    }

    /**
     * @notice Anchor results root for a contest
     * @param contestId Unique contest identifier
     * @param resultsRoot Merkle root of results data
     * @param resultsUri IPFS URI to results JSON
     */
    function anchorResults(
        bytes32 contestId,
        bytes32 resultsRoot,
        string calldata resultsUri
    ) external override onlyContestOwner(contestId) {
        if (_results[contestId].timestamp != 0) {
            revert ResultsAlreadyAnchored();
        }

        _results[contestId] = ResultsRecord({
            resultsRoot: resultsRoot,
            resultsUri: resultsUri,
            timestamp: block.timestamp
        });

        emit ResultsAnchored(contestId, resultsRoot, resultsUri, block.timestamp);
    }

    /**
     * @notice Get metadata for a contest
     */
    function getMetadata(bytes32 contestId) external view override returns (
        bytes32 metadataHash,
        string memory metadataUri,
        uint256 timestamp
    ) {
        MetadataRecord storage record = _metadata[contestId];
        return (record.metadataHash, record.metadataUri, record.timestamp);
    }

    /**
     * @notice Get results for a contest
     */
    function getResults(bytes32 contestId) external view override returns (
        bytes32 resultsRoot,
        string memory resultsUri,
        uint256 timestamp
    ) {
        ResultsRecord storage record = _results[contestId];
        return (record.resultsRoot, record.resultsUri, record.timestamp);
    }

    /**
     * @notice Get contest owner
     */
    function getContestOwner(bytes32 contestId) external view returns (address) {
        return _contestOwners[contestId];
    }
}
