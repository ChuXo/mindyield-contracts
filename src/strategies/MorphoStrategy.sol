// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC4626Strategy.sol";

// ─── MetaMorpho vault interface (extends ERC-4626) ────────────────────────────

interface IMetaMorpho is IERC4626 {
    /// @notice Current vault APR in RAY (1e27 = 100%)
    function apr() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title MorphoStrategy
 * @notice Yield strategy that deposits into a MetaMorpho ERC-4626 vault.
 *
 * MetaMorpho vaults (e.g. Moonwell Flagship USDC on Base) expose a standard
 * ERC-4626 interface plus an optional `apr()` view that returns the current
 * APR in RAY (1e27).  We try calling apr(); if it reverts we return 0.
 */
contract MorphoStrategy is ERC4626Strategy {

    string private _stratName;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _token            Underlying ERC-20 token (USDC, USDT…)
     * @param _metaMorphoVault  MetaMorpho vault address (ERC-4626 + apr())
     * @param stratName_        Human-readable name for this instance
     */
    constructor(
        address _token,
        address _metaMorphoVault,
        string memory stratName_
    ) ERC4626Strategy(_token, _metaMorphoVault) {
        _stratName = bytes(stratName_).length > 0 ? stratName_ : "Morpho Blue";
    }

    // ─── IAutoYieldStrategy (via ERC4626Strategy) ─────────────────────────────

    /**
     * @notice Estimated APY in basis points.
     *         Reads `apr()` from MetaMorpho vault (RAY → bps conversion).
     *         Returns 0 if the vault doesn't expose apr().
     */
    function getEstimatedAPY() external view override returns (uint256) {
        try IMetaMorpho(address(externalVault)).apr() returns (uint256 aprRay) {
            return aprRay * 10_000 / 1e27;
        } catch {
            return 0;
        }
    }

    function strategyName() external view override returns (string memory) {
        return _stratName;
    }

    function protocolName() external pure override returns (string memory) {
        return "Morpho";
    }
}
