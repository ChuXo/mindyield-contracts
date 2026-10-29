// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IYieldVault
 * @notice Interface for yield vault that wraps underlying yield strategies
 */
interface IYieldVault {
    event Deposited(
        address indexed depositor,
        address indexed token,
        uint256 amount,
        uint256 shares
    );

    event Withdrawn(
        address indexed recipient,
        address indexed token,
        uint256 shares,
        uint256 amount
    );

    event StrategyUpdated(uint256 indexed strategyId, address strategyAddress, bool active);

    function deposit(
        address token,
        uint256 amount,
        uint256 strategyId
    ) external returns (uint256 shares);

    function withdraw(
        address token,
        uint256 shares,
        uint256 strategyId,
        address recipient
    ) external returns (uint256 amount);

    function getShareValue(
        address token,
        uint256 shares,
        uint256 strategyId
    ) external view returns (uint256);

    function getTotalDeposited(
        address token,
        uint256 strategyId
    ) external view returns (uint256);

    function isStrategyActive(uint256 strategyId) external view returns (bool);

    function pause() external;

    function unpause() external;
}
