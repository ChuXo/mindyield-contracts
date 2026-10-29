// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IAutoYieldStrategy.sol";
import "./BaseStrategy.sol";

// ─── Minimal Aave V3 interfaces ───────────────────────────────────────────────

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/**
 * @notice Minimal IPoolDataProvider — used to read real liquidityRate on mainnet.
 *         Pass address(0) for dataProvider to disable (mock / local mode).
 */
interface IPoolDataProvider {
    function getReserveData(address asset) external view returns (
        uint256 unbacked,
        uint256 accruedToTreasuryScaled,
        uint256 totalAToken,
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 liquidityRate,        // RAY (1e27) — the one we care about
        uint256 variableBorrowRate,
        uint256 stableBorrowRate,
        uint256 averageStableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex,
        uint40  lastUpdateTimestamp
    );
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title AaveStrategy
 * @notice Yield strategy that deposits into Aave V3.
 *
 * Bug fixes vs original:
 *  1. Share formula uses getTotalValue() (pre-deposit) not totalDeposited
 *     → correct dilution when yield has already accrued
 *  2. Withdraw decrements totalDeposited by proportional principal only
 *     → prevents underflow when amountOut includes yield
 *  3. getEstimatedAPY reads real liquidityRate from IPoolDataProvider
 *     → returns 0 in local/mock mode (dataProvider == address(0))
 */
contract AaveStrategy is IAutoYieldStrategy, BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────────────────

    IAavePool         public immutable aavePool;
    IERC20            public immutable underlyingToken;
    IAToken           public immutable aToken;
    IPoolDataProvider public immutable dataProvider; // address(0) → disabled

    string private _strategyName;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed from, uint256 amount, uint256 sharesIssued);
    event Withdrawn(address indexed to,   uint256 sharesToBurn, uint256 amountOut);
    event YieldHarvested(uint256 yieldAmount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _aavePool       Aave V3 Pool address
     * @param _underlyingToken Underlying ERC-20 token (USDC, USDT, DAI…)
     * @param _aToken         Aave aToken for the underlying
     * @param _dataProvider   IPoolDataProvider address (address(0) = local/mock mode)
     */
    constructor(
        address _aavePool,
        address _underlyingToken,
        address _aToken,
        address _dataProvider
    ) {
        require(_aavePool        != address(0), "AaveStrategy: invalid pool");
        require(_underlyingToken != address(0), "AaveStrategy: invalid token");
        require(_aToken          != address(0), "AaveStrategy: invalid aToken");
        require(
            IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() == _underlyingToken,
            "AaveStrategy: token mismatch"
        );

        aavePool        = IAavePool(_aavePool);
        underlyingToken = IERC20(_underlyingToken);
        aToken          = IAToken(_aToken);
        dataProvider    = IPoolDataProvider(_dataProvider); // address(0) is valid

        // Build strategy name from token symbol (best-effort)
        try IERC20Metadata(_underlyingToken).symbol() returns (string memory sym) {
            _strategyName = string(abi.encodePacked("Aave V3 ", sym));
        } catch {
            _strategyName = "Aave V3";
        }

        // Approve Aave pool to spend all underlying tokens held by this strategy.
        // NOTE: Unlimited approval to the Aave pool is standard DeFi practice.
        // The Aave pool is a trusted, audited protocol contract. The risk of unlimited
        // approval is acknowledged and accepted — the alternative (per-tx approval)
        // adds gas cost on every deposit with minimal security benefit for trusted protocols.
        IERC20(_underlyingToken).approve(_aavePool, type(uint256).max);
    }

    // ─── IAutoYieldStrategy ───────────────────────────────────────────────────

    /**
     * @notice Deposit underlying tokens into Aave V3.
     * @param amount Amount of underlying tokens (pulled from msg.sender = vault)
     */
    function deposit(uint256 amount) external onlyYieldVault nonReentrant {
        require(amount > 0, "AaveStrategy: zero amount");

        // BUG FIX 1: capture total value BEFORE transfer so accrued yield is included
        uint256 priorValue   = getTotalValue();
        uint256 sharesIssued = _computeShares(amount, priorValue, totalShares);

        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        shares[msg.sender] += sharesIssued;
        totalShares        += sharesIssued;
        totalDeposited     += amount;

        aavePool.supply(address(underlyingToken), amount, address(this), 0);

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
        aavePool.withdraw(address(underlyingToken), yieldAmount, msg.sender);

        emit YieldHarvested(yieldAmount);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Total underlying value in Aave (aToken balance = principal + accrued interest).
     */
    function getTotalValue() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /**
     * @notice Estimated APY in basis points (100 = 1%).
     *         Reads real liquidityRate from Aave data provider when available.
     *         Returns 0 in local/mock mode (dataProvider == address(0)).
     *
     * BUG FIX 3: removed hardcoded 300 bps placeholder.
     */
    function getEstimatedAPY() external view returns (uint256) {
        if (address(dataProvider) == address(0)) return 0;
        (,,,,, uint256 liquidityRate,,,,,,) =
            dataProvider.getReserveData(address(underlyingToken));
        // liquidityRate is in RAY (1e27); convert to basis points
        return liquidityRate * 10_000 / 1e27;
    }

    function strategyName() external view returns (string memory) {
        return _strategyName;
    }

    function protocolName() external pure returns (string memory) {
        return "Aave";
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    /// @notice Emergency withdraw all funds from Aave and transfer to recipient.
    function _emergencyWithdraw(address recipient) internal override {
        uint256 totalValue = getTotalValue();
        if (totalValue > 0) {
            aavePool.withdraw(address(underlyingToken), type(uint256).max, recipient);
        }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _withdrawShares(uint256 sharesToBurn) internal returns (uint256 amountOut) {
        require(sharesToBurn > 0, "AaveStrategy: zero shares");
        require(shares[msg.sender] >= sharesToBurn, "AaveStrategy: insufficient shares");

        uint256 totalValue = getTotalValue();
        amountOut = (sharesToBurn * totalValue) / totalShares;

        // BUG FIX 2: decrement only proportional principal, not the full amountOut
        uint256 principal = _principalPortion(sharesToBurn);

        shares[msg.sender] -= sharesToBurn;
        totalShares        -= sharesToBurn;
        totalDeposited     -= principal;

        // Withdraw from Aave → tokens sent directly to vault (msg.sender)
        aavePool.withdraw(address(underlyingToken), amountOut, msg.sender);

        emit Withdrawn(msg.sender, sharesToBurn, amountOut);
    }
}

