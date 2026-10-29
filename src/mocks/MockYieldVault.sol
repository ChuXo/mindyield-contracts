// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IYieldVault.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockYieldVault
 * @notice Minimal IYieldVault stub for gas benchmarks and legacy tests.
 *         Does not interact with any external protocol — tokens are held in-contract.
 */
contract MockYieldVault is IYieldVault {
    using SafeERC20 for IERC20;

    // token => strategyId => depositor => shares
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userShares;
    // token => strategyId => totalDeposited
    mapping(address => mapping(uint256 => uint256)) public totalDeposits;
    // strategyId => total shares
    mapping(uint256 => uint256) public totalSharesPerStrategy;

    bool public paused;
    address public immutable defaultToken;

    constructor(address _token) {
        defaultToken = _token;
    }

    function deposit(
        address token,
        uint256 amount,
        uint256 strategyId
    ) external override returns (uint256 shares) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        shares = amount; // 1:1 for simplicity
        userShares[token][strategyId][msg.sender] += shares;
        totalDeposits[token][strategyId] += amount;
        totalSharesPerStrategy[strategyId] += shares;
        emit Deposited(msg.sender, token, amount, shares);
    }

    function withdraw(
        address token,
        uint256 shares,
        uint256 strategyId,
        address recipient
    ) external override returns (uint256 amount) {
        require(userShares[token][strategyId][msg.sender] >= shares, "MockYieldVault: insufficient shares");
        uint256 total = totalDeposits[token][strategyId];
        uint256 totalSh = totalSharesPerStrategy[strategyId];
        amount = totalSh == 0 ? 0 : (shares * total) / totalSh;

        userShares[token][strategyId][msg.sender] -= shares;
        totalDeposits[token][strategyId] -= amount;
        totalSharesPerStrategy[strategyId] -= shares;

        IERC20(token).safeTransfer(recipient, amount);
        emit Withdrawn(recipient, token, shares, amount);
    }

    function getShareValue(
        address token,
        uint256 shares,
        uint256 strategyId
    ) external view override returns (uint256) {
        uint256 totalSh = totalSharesPerStrategy[strategyId];
        if (totalSh == 0) return 0;
        return (shares * totalDeposits[token][strategyId]) / totalSh;
    }

    function getTotalDeposited(
        address token,
        uint256 strategyId
    ) external view override returns (uint256) {
        return totalDeposits[token][strategyId];
    }

    function isStrategyActive(uint256) external pure override returns (bool) {
        return true;
    }

    function pause() external override {
        paused = true;
    }

    function unpause() external override {
        paused = false;
    }
}
