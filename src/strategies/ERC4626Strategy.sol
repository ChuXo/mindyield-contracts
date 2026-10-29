// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "../interfaces/IAutoYieldStrategy.sol";
import "./BaseStrategy.sol";

/**
 * @title ERC4626Strategy
 * @notice Abstract base for yield strategies that wrap any ERC-4626 compliant vault
 *         (e.g. MetaMorpho, Yearn V3).
 *
 * Implements deposit / withdraw / getTotalValue / harvestYield for the common
 * ERC-4626 pattern.  Subclasses must implement:
 *   - getEstimatedAPY()
 *   - strategyName()
 *   - protocolName()
 */
abstract contract ERC4626Strategy is IAutoYieldStrategy, BaseStrategy {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────────────────

    IERC4626 public immutable externalVault;
    IERC20   public immutable underlyingToken;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed from, uint256 amount, uint256 sharesIssued);
    event Withdrawn(address indexed to, uint256 sharesToBurn, uint256 amountOut);
    event YieldHarvested(uint256 yieldAmount);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _token, address _externalVault) {
        require(_token != address(0),        "ERC4626Strategy: invalid token");
        require(_externalVault != address(0), "ERC4626Strategy: invalid vault");

        underlyingToken = IERC20(_token);
        externalVault   = IERC4626(_externalVault);

        // Pre-approve the external vault to spend the strategy's underlying tokens.
        // NOTE: Unlimited approval to ERC4626 vaults is standard DeFi practice.
        // See AaveStrategy for rationale on trusted protocol approvals.
        IERC20(_token).approve(_externalVault, type(uint256).max);
    }

    // ─── IAutoYieldStrategy implementation ───────────────────────────────────

    /**
     * @notice Deposit underlying tokens into the external ERC-4626 vault.
     * @param amount Amount of underlying tokens (pulled from msg.sender = AutoYieldVault)
     */
    function deposit(uint256 amount) external onlyYieldVault nonReentrant {
        require(amount > 0, "ERC4626Strategy: zero amount");

        // Capture value BEFORE transfer (fix bug: share formula must use pre-deposit value)
        uint256 priorValue  = getTotalValue();
        uint256 sharesIssued = _computeShares(amount, priorValue, totalShares);

        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        shares[msg.sender] += sharesIssued;
        totalShares        += sharesIssued;
        totalDeposited     += amount;

        externalVault.deposit(amount, address(this));

        emit Deposited(msg.sender, amount, sharesIssued);
    }

    /**
     * @notice Redeem strategy shares and return proportional underlying to caller.
     * @param sharesToBurn Number of strategy shares to burn
     * @return amountOut Underlying tokens returned to msg.sender (the vault)
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
     * @return harvested Amount of yield in underlying tokens
     */
    function harvestYield() external onlyYieldVault nonReentrant returns (uint256 harvested) {
        uint256 totalValue = getTotalValue();
        if (totalValue <= totalDeposited) return 0;

        harvested = totalValue - totalDeposited;
        externalVault.withdraw(harvested, msg.sender, address(this));

        emit YieldHarvested(harvested);
    }

    /**
     * @notice Total underlying value managed by this strategy (principal + accrued yield).
     */
    function getTotalValue() public view returns (uint256) {
        return externalVault.convertToAssets(externalVault.balanceOf(address(this)));
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    /// @notice Emergency withdraw all funds from the external ERC-4626 vault to recipient.
    function _emergencyWithdraw(address recipient) internal override {
        uint256 vaultShares = externalVault.balanceOf(address(this));
        if (vaultShares > 0) {
            externalVault.redeem(vaultShares, recipient, address(this));
        }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _withdrawShares(uint256 sharesToBurn) internal returns (uint256 amountOut) {
        require(sharesToBurn > 0, "ERC4626Strategy: zero shares");
        require(shares[msg.sender] >= sharesToBurn, "ERC4626Strategy: insufficient shares");

        uint256 totalValue = getTotalValue();
        amountOut = (sharesToBurn * totalValue) / totalShares;

        // Decrement only the proportional principal (bug fix: don't subtract yield)
        uint256 principal = _principalPortion(sharesToBurn);

        shares[msg.sender] -= sharesToBurn;
        totalShares        -= sharesToBurn;
        totalDeposited     -= principal;

        // Withdraw from external ERC-4626 vault → tokens sent directly to vault (msg.sender)
        externalVault.withdraw(amountOut, msg.sender, address(this));

        emit Withdrawn(msg.sender, sharesToBurn, amountOut);
    }

    // ─── Abstract methods (subclasses must implement) ─────────────────────────

    function getEstimatedAPY() external view virtual returns (uint256);
    function strategyName()    external view virtual returns (string memory);
    function protocolName()    external view virtual returns (string memory);
}
