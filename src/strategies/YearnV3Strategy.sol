// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC4626Strategy.sol";

// ─── Yearn V3 vault interface (extends ERC-4626) ──────────────────────────────

interface IYearnVault is IERC4626 {
    /// @notice Current vault APR (varies by Yearn V3 implementation)
    function apr() external view returns (uint256);
    /// @notice Alternative APR getter used by some Yearn V3 vaults
    function estimatedApr() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title YearnV3Strategy
 * @notice Yield strategy that deposits into a Yearn V3 ERC-4626 vault.
 *
 * Yearn V3 vaults are standard ERC-4626.  The APR getter varies by implementation:
 * some use `apr()`, others use `estimatedApr()`.  We try both; fallback to 0.
 */
contract YearnV3Strategy is ERC4626Strategy {

    string private _stratName;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _token       Underlying ERC-20 token
     * @param _yearnVault  Yearn V3 vault address (ERC-4626)
     * @param stratName_   Human-readable name for this instance
     */
    constructor(
        address _token,
        address _yearnVault,
        string memory stratName_
    ) ERC4626Strategy(_token, _yearnVault) {
        _stratName = bytes(stratName_).length > 0 ? stratName_ : "Yearn V3";
    }

    // ─── IAutoYieldStrategy (via ERC4626Strategy) ─────────────────────────────

    /**
     * @notice Estimated APY in basis points.
     *         Tries apr() then estimatedApr().  Returns 0 if neither exists.
     *
     * @dev Yearn V3 APR is typically 1e18-scaled (100% = 1e18) rather than RAY.
     *      We convert assuming 1e18 = 10_000 bps (100%).
     */
    function getEstimatedAPY() external view override returns (uint256) {
        IYearnVault yv = IYearnVault(address(externalVault));
        // Try apr() first
        try yv.apr() returns (uint256 aprWad) {
            return aprWad * 10_000 / 1e18;
        } catch {}
        // Try estimatedApr() as fallback
        try yv.estimatedApr() returns (uint256 aprWad) {
            return aprWad * 10_000 / 1e18;
        } catch {}
        return 0;
    }

    function strategyName() external view override returns (string memory) {
        return _stratName;
    }

    function protocolName() external pure override returns (string memory) {
        return "Yearn";
    }
}
