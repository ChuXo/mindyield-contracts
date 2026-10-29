// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IAutoYieldStrategy.sol";
import "./BaseStrategy.sol";

// ─── Minimal Compound V3 (Comet) interface ────────────────────────────────────

interface IComet {
    /// @notice Supply an asset to the caller's account in Compound V3
    function supply(address asset, uint256 amount) external;
    /// @notice Withdraw an asset from the caller's account (sent to caller)
    function withdraw(address asset, uint256 amount) external;
    /// @notice Underlying balance of `account` (in underlying token units)
    function balanceOf(address account) external view returns (uint256);
    /// @notice Supply rate per second at the given utilization (1e18 scale)
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    /// @notice Current borrow utilization (0–1e18)
    function getUtilization() external view returns (uint256);
    /// @notice The base (underlying) token address
    function baseToken() external view returns (address);
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title CompoundV3Strategy
 * @notice Yield strategy that deposits into Compound V3 (Comet).
 *
 * Key difference from V2: Comet tracks underlying balances directly (not cTokens).
 * getTotalValue() = comet.balanceOf(address(this)) in underlying token units.
 */
contract CompoundV3Strategy is IAutoYieldStrategy, BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // ─── State ────────────────────────────────────────────────────────────────

    IComet public immutable comet;
    IERC20 public immutable underlyingToken;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed from, uint256 amount, uint256 sharesIssued);
    event Withdrawn(address indexed to,   uint256 sharesToBurn, uint256 amountOut);
    event YieldHarvested(uint256 yieldAmount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _comet, address _underlyingToken) {
        require(_comet           != address(0), "CompoundV3Strategy: invalid comet");
        require(_underlyingToken != address(0), "CompoundV3Strategy: invalid token");
        require(
            IComet(_comet).baseToken() == _underlyingToken,
            "CompoundV3Strategy: token mismatch"
        );

        comet           = IComet(_comet);
        underlyingToken = IERC20(_underlyingToken);

        // Approve Comet to pull underlying when we call supply().
        // NOTE: Unlimited approval to Compound V3 (Comet) is standard DeFi practice.
        // See AaveStrategy for rationale on trusted protocol approvals.
        IERC20(_underlyingToken).approve(_comet, type(uint256).max);
    }

    // ─── IAutoYieldStrategy ───────────────────────────────────────────────────

    /**
     * @notice Deposit underlying tokens into Compound V3 (Comet).
     * @param amount Amount of underlying tokens (pulled from msg.sender = vault)
     */
    function deposit(uint256 amount) external onlyYieldVault nonReentrant {
        require(amount > 0, "CompoundV3Strategy: zero amount");

        uint256 priorValue   = getTotalValue();
        uint256 sharesIssued = _computeShares(amount, priorValue, totalShares);

        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        shares[msg.sender] += sharesIssued;
        totalShares        += sharesIssued;
        totalDeposited     += amount;

        comet.supply(address(underlyingToken), amount);

        emit Deposited(msg.sender, amount, sharesIssued);
    }

    /**
     * @notice Redeem strategy shares and return proportional underlying to caller.
     * @param sharesToBurn Number of strategy shares to burn
     * @return amountOut Underlying tokens sent to msg.sender (the vault)
     */
    function withdraw(uint256 sharesToBurn) external onlyYieldVault nonReentrant returns (uint256 amountOut) {
        return _withdrawShares(sharesToBurn);
    }

    /**
     * @notice Withdraw a specific token amount (converts to shares internally).
     */
    function withdrawAmount(uint256 tokenAmount) external onlyYieldVault nonReentrant returns (uint256 actualOut) {
        uint256 currentValue = getTotalValue();
        if (currentValue == 0 || totalShares == 0) return 0;
        uint256 sharesToBurn = (tokenAmount * totalShares) / currentValue;
        if (sharesToBurn == 0) return 0;
        // Sweep dust: if remaining shares would be below threshold, burn all
        sharesToBurn = _adjustForDust(msg.sender, sharesToBurn);
        return _withdrawShares(sharesToBurn);
    }

    /**
     * @notice Harvest accumulated yield and send it to the caller (vault).
     */
    function harvestYield() external onlyYieldVault nonReentrant returns (uint256 yieldAmount) {
        uint256 totalValue = getTotalValue();
        if (totalValue <= totalDeposited) return 0;

        yieldAmount = totalValue - totalDeposited;

        // Withdraw yield from Comet → tokens arrive at this contract
        comet.withdraw(address(underlyingToken), yieldAmount);
        underlyingToken.safeTransfer(msg.sender, yieldAmount);

        emit YieldHarvested(yieldAmount);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Total underlying value in Comet (underlying units, not cTokens).
     */
    function getTotalValue() public view returns (uint256) {
        return comet.balanceOf(address(this));
    }

    /**
     * @notice Estimated APY in basis points.
     *         Reads per-second supply rate from Comet and annualizes.
     */
    function getEstimatedAPY() external view returns (uint256) {
        uint256 utilization = comet.getUtilization();
        uint64  ratePerSec  = comet.getSupplyRate(utilization);
        // ratePerSec is 1e18-scaled; APY_bps = rate * secondsPerYear * 10_000 / 1e18
        return (uint256(ratePerSec) * SECONDS_PER_YEAR * 10_000) / 1e18;
    }

    function strategyName() external pure returns (string memory) {
        return "Compound V3";
    }

    function protocolName() external pure returns (string memory) {
        return "Compound";
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    /// @notice Emergency withdraw all funds from Compound V3 and transfer to recipient.
    function _emergencyWithdraw(address recipient) internal override {
        uint256 balance = comet.balanceOf(address(this));
        if (balance > 0) {
            comet.withdraw(address(underlyingToken), balance);
            uint256 tokenBalance = underlyingToken.balanceOf(address(this));
            if (tokenBalance > 0) {
                underlyingToken.safeTransfer(recipient, tokenBalance);
            }
        }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _withdrawShares(uint256 sharesToBurn) internal returns (uint256 amountOut) {
        require(sharesToBurn > 0, "CompoundV3Strategy: zero shares");
        require(shares[msg.sender] >= sharesToBurn, "CompoundV3Strategy: insufficient shares");

        uint256 totalValue = getTotalValue();
        amountOut = (sharesToBurn * totalValue) / totalShares;

        uint256 principal = _principalPortion(sharesToBurn);

        shares[msg.sender] -= sharesToBurn;
        totalShares        -= sharesToBurn;
        totalDeposited     -= principal;

        // Comet.withdraw sends tokens to msg.sender (this contract)
        comet.withdraw(address(underlyingToken), amountOut);
        underlyingToken.safeTransfer(msg.sender, amountOut);

        emit Withdrawn(msg.sender, sharesToBurn, amountOut);
    }
}
