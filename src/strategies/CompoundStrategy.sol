// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IAutoYieldStrategy.sol";
import "./BaseStrategy.sol";

// ─── Minimal cToken interface (Compound V2) ───────────────────────────────────

interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function underlying() external view returns (address);
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title CompoundStrategy
 * @notice Yield strategy that deposits into Compound V2 (cToken).
 *
 * Bug fixes vs original:
 *  1. Implements IAutoYieldStrategy (not IYieldStrategy)
 *  2. Share formula uses getTotalValue() pre-deposit (not totalDeposited)
 *  3. Withdraw decrements totalDeposited by proportional principal only
 */
contract CompoundStrategy is IAutoYieldStrategy, BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @dev Approximate Ethereum mainnet blocks per year at ~12 s/block
    uint256 public constant BLOCKS_PER_YEAR = 2_628_000;

    // ─── State ────────────────────────────────────────────────────────────────

    IERC20  public immutable underlyingToken;
    ICToken public immutable cToken;

    /// @dev Compound V2 exchange rate mantissa: 10^(10 + underlyingDecimals)
    ///      For USDC (6 dec) = 10^16, for DAI (18 dec) = 10^28, etc.
    uint256 public immutable exchangeRateDenominator;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed from, uint256 amount, uint256 sharesIssued);
    event Withdrawn(address indexed to,   uint256 sharesToBurn, uint256 amountOut);
    event YieldHarvested(uint256 yieldAmount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _underlyingToken, address _cToken) {
        require(_underlyingToken != address(0), "CompoundStrategy: invalid token");
        require(_cToken          != address(0), "CompoundStrategy: invalid cToken");
        require(
            ICToken(_cToken).underlying() == _underlyingToken,
            "CompoundStrategy: token mismatch"
        );

        underlyingToken = IERC20(_underlyingToken);
        cToken          = ICToken(_cToken);

        // Compound V2 exchange rate is mantissa-scaled to 10^(10 + underlyingDecimals)
        uint8 dec = IERC20Metadata(_underlyingToken).decimals();
        exchangeRateDenominator = 10 ** (10 + uint256(dec));

        // NOTE: Unlimited approval to the Compound cToken is standard DeFi practice.
        // The cToken is a trusted, audited protocol contract. See AaveStrategy for rationale.
        IERC20(_underlyingToken).approve(_cToken, type(uint256).max);
    }

    // ─── IAutoYieldStrategy ───────────────────────────────────────────────────

    /**
     * @notice Deposit underlying tokens into Compound V2 (mint cTokens).
     * @param amount Amount of underlying tokens (pulled from msg.sender = vault)
     */
    function deposit(uint256 amount) external onlyYieldVault nonReentrant {
        require(amount > 0, "CompoundStrategy: zero amount");

        // Capture value BEFORE transfer (bug fix 2: share formula uses current value)
        uint256 priorValue   = getTotalValue();
        uint256 sharesIssued = _computeShares(amount, priorValue, totalShares);

        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        shares[msg.sender] += sharesIssued;
        totalShares        += sharesIssued;
        totalDeposited     += amount;

        uint256 result = cToken.mint(amount);
        require(result == 0, "CompoundStrategy: mint failed");

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
     * @param tokenAmount Underlying token amount to withdraw
     * @return actualOut Actual underlying tokens returned
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
     * @return yieldAmount Amount of yield in underlying tokens
     */
    function harvestYield() external onlyYieldVault nonReentrant returns (uint256 yieldAmount) {
        uint256 totalValue = getTotalValue();
        if (totalValue <= totalDeposited) return 0;

        yieldAmount = totalValue - totalDeposited;

        uint256 result = cToken.redeemUnderlying(yieldAmount);
        require(result == 0, "CompoundStrategy: redeem failed");

        underlyingToken.safeTransfer(msg.sender, yieldAmount);

        emit YieldHarvested(yieldAmount);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Total underlying value in Compound (cToken balance × exchange rate).
     */
    function getTotalValue() public view returns (uint256) {
        uint256 cTokenBalance = cToken.balanceOf(address(this));
        uint256 exchangeRate  = cToken.exchangeRateStored();
        return (cTokenBalance * exchangeRate) / exchangeRateDenominator;
    }

    /**
     * @notice Estimated APY in basis points from Compound's supplyRatePerBlock.
     */
    function getEstimatedAPY() external view returns (uint256) {
        uint256 supplyRate = cToken.supplyRatePerBlock();
        // Simplified: APY ≈ ratePerBlock * blocksPerYear * 10_000 / 1e18
        return (supplyRate * BLOCKS_PER_YEAR * 10_000) / 1e18;
    }

    function strategyName() external pure returns (string memory) {
        return "Compound V2";
    }

    function protocolName() external pure returns (string memory) {
        return "Compound";
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    /// @notice Emergency withdraw all funds from Compound V2 and transfer to recipient.
    function _emergencyWithdraw(address recipient) internal override {
        uint256 cTokenBalance = cToken.balanceOf(address(this));
        if (cTokenBalance > 0) {
            uint256 result = cToken.redeem(cTokenBalance);
            require(result == 0, "CompoundStrategy: emergency redeem failed");
            uint256 balance = underlyingToken.balanceOf(address(this));
            if (balance > 0) {
                underlyingToken.safeTransfer(recipient, balance);
            }
        }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _withdrawShares(uint256 sharesToBurn) internal returns (uint256 amountOut) {
        require(sharesToBurn > 0, "CompoundStrategy: zero shares");
        require(shares[msg.sender] >= sharesToBurn, "CompoundStrategy: insufficient shares");

        uint256 totalValue = getTotalValue();
        amountOut = (sharesToBurn * totalValue) / totalShares;

        // Bug fix 3: decrement only proportional principal
        uint256 principal = _principalPortion(sharesToBurn);

        shares[msg.sender] -= sharesToBurn;
        totalShares        -= sharesToBurn;
        totalDeposited     -= principal;

        uint256 result = cToken.redeemUnderlying(amountOut);
        require(result == 0, "CompoundStrategy: redeem failed");

        underlyingToken.safeTransfer(msg.sender, amountOut);

        emit Withdrawn(msg.sender, sharesToBurn, amountOut);
    }
}
