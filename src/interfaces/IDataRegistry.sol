// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDataRegistry
 * @notice Interface for anchoring metadata hashes and results on-chain
 */
interface IDataRegistry {
    event MetadataAnchored(
        bytes32 indexed contestId,
        bytes32 metadataHash,
        string metadataUri,
        uint256 timestamp
    );

    event ResultsAnchored(
        bytes32 indexed contestId,
        bytes32 resultsRoot,
        string resultsUri,
        uint256 timestamp
    );

    function anchorMetadata(
        bytes32 contestId,
        bytes32 metadataHash,
        string calldata metadataUri
    ) external;

    function anchorResults(
        bytes32 contestId,
        bytes32 resultsRoot,
        string calldata resultsUri
    ) external;

    function getMetadata(bytes32 contestId) external view returns (
        bytes32 metadataHash,
        string memory metadataUri,
        uint256 timestamp
    );

    function getResults(bytes32 contestId) external view returns (
        bytes32 resultsRoot,
        string memory resultsUri,
        uint256 timestamp
    );
}
