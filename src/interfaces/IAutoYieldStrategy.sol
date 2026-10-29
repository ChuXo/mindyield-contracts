// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAutoYieldStrategy
 * @notice Standard interface for pluggable yield strategies used by AutoYieldVault
 */
interface IAutoYieldStrategy {
    /**
     * @notice Deposit underlying tokens into the strategy
     * @param amount Amount of underlying tokens to deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraw underlying tokens from the strategy by burning shares
     * @param sharesToBurn Number of strategy shares to redeem
     * @return amountOut Amount of underlying tokens returned to caller
     */
    function withdraw(uint256 sharesToBurn) external returns (uint256 amountOut);

    /**
     * @notice Withdraw a specific token amount from the strategy (converts to shares internally)
     * @param tokenAmount Amount of underlying tokens to withdraw
     * @return actualOut Actual amount of underlying tokens returned to caller
     */
    function withdrawAmount(uint256 tokenAmount) external returns (uint256 actualOut);

    /**
     * @notice Get total value of assets managed by the strategy (principal + accrued yield)
     * @return Total value in underlying tokens
     */
    function getTotalValue() external view returns (uint256);

    /**
     * @notice Get estimated annual percentage yield
     * @return APY in basis points (100 = 1%)
     */
    function getEstimatedAPY() external view returns (uint256);

    /**
     * @notice Harvest accumulated yield and send it to the caller (vault)
     * @return harvested Amount of yield tokens sent to caller
     */
    function harvestYield() external returns (uint256 harvested);

    /**
     * @notice Human-readable name for this specific strategy instance
     * @return name Strategy name (e.g. "Aave V3 USDC")
     */
    function strategyName() external view returns (string memory);

    /**
     * @notice Name of the underlying protocol
     * @return name Protocol name (e.g. "Aave")
     */
    function protocolName() external view returns (string memory);
}
