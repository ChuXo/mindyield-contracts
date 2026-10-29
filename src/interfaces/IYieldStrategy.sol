// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IYieldStrategy
 * @notice Interface for MindYield yield strategies
 * @dev All yield strategies must implement this interface
 */
interface IYieldStrategy {
    // ============ Core Functions ============

    /**
     * @notice Deposit tokens into the strategy
     * @param amount Amount of underlying tokens to deposit
     * @return sharesIssued Number of shares issued
     */
    function deposit(uint256 amount) external returns (uint256 sharesIssued);

    /**
     * @notice Withdraw tokens from the strategy
     * @param sharesToBurn Number of shares to burn
     * @return amountWithdrawn Amount of underlying tokens withdrawn
     */
    function withdraw(uint256 sharesToBurn) external returns (uint256 amountWithdrawn);

    /**
     * @notice Withdraw all tokens for the caller
     * @return amountWithdrawn Amount of underlying tokens withdrawn
     */
    function withdrawAll() external returns (uint256 amountWithdrawn);

    /**
     * @notice Harvest yield and return it to yield vault
     * @return yieldAmount Amount of yield harvested
     */
    function harvestYield() external returns (uint256 yieldAmount);

    // ============ View Functions ============

    /**
     * @notice Get total value of assets in strategy (principal + yield)
     * @return Total value in underlying tokens
     */
    function getTotalValue() external view returns (uint256);

    /**
     * @notice Get pending yield (unrealized gains)
     * @return Pending yield amount
     */
    function getPendingYield() external view returns (uint256);

    /**
     * @notice Get share balance for a depositor
     * @param depositor Address to check
     * @return Share balance
     */
    function getShares(address depositor) external view returns (uint256);

    /**
     * @notice Get underlying value for shares
     * @param shareAmount Number of shares
     * @return Underlying token value
     */
    function getValueForShares(uint256 shareAmount) external view returns (uint256);

    /**
     * @notice Get current APY estimate
     * @return Estimated APY in basis points (100 = 1%)
     */
    function getEstimatedAPY() external view returns (uint256);

    /**
     * @notice Get strategy info
     * @return name Strategy name
     * @return protocol Protocol name
     * @return version Strategy version
     */
    function getStrategyInfo() external view returns (
        string memory name,
        string memory protocol,
        uint256 version
    );
}
