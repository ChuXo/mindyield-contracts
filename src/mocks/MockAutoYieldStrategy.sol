// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAutoYieldStrategy.sol";
import "./MockERC20.sol";

/**
 * @title MockAutoYieldStrategy
 * @notice Test double for IAutoYieldStrategy used in AutoYieldVault unit tests.
 *
 * Design:
 *  - Maintains its own share<→>asset mapping that mirrors the vault's accounting.
 *  - deposit(amount)        → pull tokens, issue proportional internal shares.
 *  - withdraw(sharesToBurn) → burn shares, return proportional tokens to caller.
 *  - simulateYield(amount)  → increase totalValue without issuing new shares,
 *                             so each share appreciates in value.
 *  - harvestYield()         → send accumulated pendingYield to caller.
 *
 * Because the vault and strategy both use the same share formula (amount × shares / value),
 * vault shares map 1-to-1 with strategy shares, making the accounting consistent.
 */
contract MockAutoYieldStrategy is IAutoYieldStrategy {
    MockERC20 public token;

    uint256 public strategyTotalValue;  // actual tokens managed (principal + yield)
    uint256 public strategyTotalShares; // strategy's internal share count

    mapping(address => uint256) public strategyShares;

    uint256 public pendingYield; // accumulated but not yet harvested yield

    /// @notice Principal-only tracking (mirrors BaseStrategy.totalDeposited for YieldOptimizer compatibility)
    uint256 public totalDeposited;

    uint256 public ESTIMATED_APY = 300; // 3 % in basis points (mutable for optimizer tests)

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function setEstimatedAPY(uint256 apy) external {
        ESTIMATED_APY = apy;
    }

    // ─── IAutoYieldStrategy ───────────────────────────────────────────────────

    function deposit(uint256 amount) external override {
        require(amount > 0, "MockStrategy: zero amount");

        require(token.transferFrom(msg.sender, address(this), amount), "MockStrategy: transferFrom failed");

        // Issue shares proportional to current holdings (1:1 on first deposit)
        uint256 sharesIssued = strategyTotalShares == 0
            ? amount
            : (amount * strategyTotalShares) / strategyTotalValue;

        strategyShares[msg.sender] += sharesIssued;
        strategyTotalShares        += sharesIssued;
        strategyTotalValue         += amount;
        totalDeposited             += amount;
    }

    function withdraw(uint256 sharesToBurn) external override returns (uint256 amountOut) {
        require(sharesToBurn > 0, "MockStrategy: zero shares");

        uint256 callerShares = strategyShares[msg.sender];
        if (sharesToBurn > callerShares) sharesToBurn = callerShares;

        amountOut = strategyTotalShares == 0
            ? 0
            : (sharesToBurn * strategyTotalValue) / strategyTotalShares;

        // Decrement principal proportionally (mirrors BaseStrategy._principalPortion)
        // Uses pre-burn totalShares as denominator (audit fix M-5)
        uint256 principalPortion = strategyTotalShares > 0
            ? (sharesToBurn * totalDeposited) / strategyTotalShares
            : 0;
        totalDeposited = totalDeposited > principalPortion ? totalDeposited - principalPortion : 0;

        strategyShares[msg.sender] -= sharesToBurn;
        strategyTotalShares        -= sharesToBurn;
        strategyTotalValue          = strategyTotalValue > amountOut
            ? strategyTotalValue - amountOut
            : 0;

        if (amountOut > 0) {
            require(token.transfer(msg.sender, amountOut), "MockStrategy: transfer failed");
        }
    }

    function getTotalValue() external view override returns (uint256) {
        return strategyTotalValue;
    }

    function getEstimatedAPY() external view override returns (uint256) {
        return ESTIMATED_APY;
    }

    function withdrawAmount(uint256 tokenAmount) external override returns (uint256 actualOut) {
        uint256 currentValue = strategyTotalValue;
        if (currentValue == 0 || strategyTotalShares == 0) return 0;
        uint256 sharesToBurn = (tokenAmount * strategyTotalShares) / currentValue;
        if (sharesToBurn > strategyShares[msg.sender]) sharesToBurn = strategyShares[msg.sender];
        if (sharesToBurn == 0) return 0;

        actualOut = strategyTotalShares == 0
            ? 0
            : (sharesToBurn * strategyTotalValue) / strategyTotalShares;

        // Decrement principal proportionally (pre-burn totalShares as denominator)
        uint256 principalPortion = strategyTotalShares > 0
            ? (sharesToBurn * totalDeposited) / strategyTotalShares
            : 0;
        totalDeposited = totalDeposited > principalPortion ? totalDeposited - principalPortion : 0;

        strategyShares[msg.sender] -= sharesToBurn;
        strategyTotalShares        -= sharesToBurn;
        strategyTotalValue          = strategyTotalValue > actualOut
            ? strategyTotalValue - actualOut
            : 0;

        if (actualOut > 0) {
            require(token.transfer(msg.sender, actualOut), "MockStrategy: transfer failed");
        }
    }

    function strategyName() external pure override returns (string memory) {
        return "Mock Strategy";
    }

    function protocolName() external pure override returns (string memory) {
        return "Mock";
    }

    function harvestYield() external override returns (uint256 harvested) {
        harvested    = pendingYield;
        pendingYield = 0;
        if (harvested > 0) {
            strategyTotalValue -= harvested; // tokens leave the strategy
            require(token.transfer(msg.sender, harvested), "MockStrategy: transfer failed");
        }
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Inject yield: increase totalValue and mint tokens to self,
     *         simulating interest accrual between harvests.
     */
    function simulateYield(uint256 amount) external {
        pendingYield       += amount;
        strategyTotalValue += amount;
        token.mint(address(this), amount);
    }
}
