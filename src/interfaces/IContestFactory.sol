// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IContest.sol";

/**
 * @title IContestFactory
 * @notice Interface for creating and managing contests
 */
interface IContestFactory {
    event ContestCreated(
        bytes32 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        IContest.ContestConfig config
    );

    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeEnabledUpdated(bool enabled);
    event ContestCreationFeeUpdated(uint256 newFee);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event RegistryUpdated(string registryName, address oldAddress, address newAddress);

    function createContest(
        IContest.ContestConfig calldata config
    ) external returns (bytes32 contestId, address contestAddress);

    function getContest(bytes32 contestId) external view returns (address);

    function getContestsByCreator(address creator) external view returns (bytes32[] memory);

    function getAllContests() external view returns (bytes32[] memory);

    function getContestCount() external view returns (uint256);

    function setProtocolFee(uint256 fee) external;

    function getProtocolFee() external view returns (uint256);

    function setTreasury(address treasury) external;

    function getTreasury() external view returns (address);
}
