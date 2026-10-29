// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title BaseStrategy
 * @notice Abstract base contract for all MindYield yield strategies.
 *
 * Provides:
 *  - Share-accounting state (totalDeposited, totalShares, shares mapping)
 *  - onlyYieldVault modifier
 *  - setYieldVault admin function
 *  - _computeShares / _principalPortion internal helpers
 *  - emergencyWithdraw owner-only escape hatch
 *
 * All concrete strategies inherit this and implement IAutoYieldStrategy.
 */
abstract contract BaseStrategy is Ownable2Step, ReentrancyGuard {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Virtual shares offset to prevent first-depositor inflation attack (OZ 5.x pattern).
    uint256 internal constant _VIRTUAL_SHARES = 1e6;

    /// @notice Virtual assets offset to prevent first-depositor inflation attack.
    uint256 internal constant _VIRTUAL_ASSETS = 1;

    /// @notice Minimum first deposit to prevent tiny-deposit inflation attacks.
    uint256 public constant MINIMUM_FIRST_DEPOSIT = 1000;

    /// @notice Dust threshold for share cleanup in withdrawAmount (wei).
    uint256 public constant DUST_SHARES_THRESHOLD = 1000;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice The vault authorized to call deposit/withdraw/harvestYield
    address public yieldVault;

    /// @notice Total underlying tokens deposited (principal only, no yield)
    uint256 public totalDeposited;

    /// @notice Total strategy shares outstanding
    uint256 public totalShares;

    /// @notice Strategy share balance per address (vault is the only depositor)
    mapping(address => uint256) public shares;

    // ─── Events ───────────────────────────────────────────────────────────────

    event YieldVaultUpdated(address indexed newVault);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyYieldVault() {
        require(
            msg.sender == yieldVault,
            "BaseStrategy: not authorized"
        );
        _;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Set the authorized yield vault.
     * @param _yieldVault Address of the AutoYieldVault (or NoLossLottery) that controls this strategy.
     */
    function setYieldVault(address _yieldVault) external onlyOwner {
        require(_yieldVault != address(0), "BaseStrategy: invalid vault");
        yieldVault = _yieldVault;
        emit YieldVaultUpdated(_yieldVault);
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    /**
     * @notice Emergency withdraw all funds from the external protocol to recipient.
     * @dev Subclasses should override _emergencyWithdraw with protocol-specific logic.
     * @param recipient Address to receive the rescued funds.
     */
    function emergencyWithdraw(address recipient) external virtual onlyOwner {
        require(recipient != address(0), "BaseStrategy: invalid recipient");
        _emergencyWithdraw(recipient);
    }

    /**
     * @notice Internal hook for protocol-specific emergency withdrawal.
     * @dev Subclasses MUST override this to withdraw from their external protocol.
     *      Base implementation is a no-op (for strategies that hold tokens directly).
     */
    function _emergencyWithdraw(address recipient) internal virtual;

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /**
     * @notice Compute shares to issue for a deposit.
     *
     * @dev Uses virtual shares/assets offset (OZ 5.x pattern) to prevent first-depositor
     *      inflation attacks. priorValue MUST be captured before transferring tokens.
     *
     * @param amount       Amount being deposited (underlying tokens)
     * @param priorValue   getTotalValue() called before the deposit
     * @param _totalShares Current totalShares before the deposit
     * @return sharesIssued Number of new shares to mint
     */
    function _computeShares(
        uint256 amount,
        uint256 priorValue,
        uint256 _totalShares
    ) internal pure returns (uint256 sharesIssued) {
        // Virtual offset prevents first-depositor inflation attack:
        // shares = amount * (totalShares + VIRTUAL_SHARES) / (priorValue + VIRTUAL_ASSETS)
        return (amount * (_totalShares + _VIRTUAL_SHARES)) / (priorValue + _VIRTUAL_ASSETS);
    }

    /**
     * @notice Adjust sharesToBurn to include dust: if remaining shares after burn
     *         would be below DUST_SHARES_THRESHOLD, burn all remaining shares instead.
     * @param depositor   The address whose shares are being burned
     * @param sharesToBurn The initially computed shares to burn
     * @return Adjusted shares to burn (may be higher to sweep dust)
     */
    function _adjustForDust(address depositor, uint256 sharesToBurn) internal view returns (uint256) {
        uint256 remaining = shares[depositor] - sharesToBurn;
        if (remaining > 0 && remaining < DUST_SHARES_THRESHOLD) {
            return shares[depositor]; // burn all to prevent dust accumulation
        }
        return sharesToBurn;
    }

    /**
     * @notice Compute the principal portion attributed to a share burn.
     *
     * @dev Used to correctly decrement totalDeposited on withdrawal,
     *      so that it tracks only principal (not accrued yield).
     *
     * @param sharesToBurn Number of shares being redeemed
     * @return principal   Proportional principal = sharesToBurn * totalDeposited / totalShares
     */
    function _principalPortion(uint256 sharesToBurn) internal view returns (uint256 principal) {
        if (totalShares == 0) return 0;
        return (sharesToBurn * totalDeposited) / totalShares;
    }
}
