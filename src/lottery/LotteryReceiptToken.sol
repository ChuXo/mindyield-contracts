// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LotteryReceiptToken
 * @notice Minimal ERC-20 receipt token minted 1:1 on lottery deposits.
 *
 * The lottery contract (owner) is the sole minter/burner. Users can freely
 * transfer receipt tokens for DeFi composability (e.g., use as collateral).
 *
 * IMPORTANT: Receipt tokens do NOT affect lottery odds. Winner selection uses
 * the lottery's internal `userDeposited[]` mapping, not receipt token balances.
 * Buying receipt tokens on a DEX does NOT give lottery eligibility.
 *
 * Uses single-step Ownable (not Ownable2Step): the factory transfers ownership
 * to the lottery atomically during deployment, and the lottery never relinquishes
 * it. Two-step would require the lottery to call `acceptOwnership()`, but that
 * function isn't exposed on the lottery, so the receipt token would silently
 * remain owned by the factory and `mint()` would always revert.
 */
contract LotteryReceiptToken is ERC20, Ownable {
    uint8 private immutable _decimals;

    /**
     * @param name_     Token name (e.g., "MindYield Weekly USDC")
     * @param symbol_   Token symbol (e.g., "myWeeklyUSDC")
     * @param decimals_ Decimals matching the deposit token (e.g., 6 for USDC)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) Ownable() {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint receipt tokens. Only callable by the lottery contract (owner).
     * @param to     Depositor address.
     * @param amount Amount matching the deposit.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn receipt tokens. Only callable by the lottery contract (owner).
     * @param from   Withdrawer address.
     * @param amount Amount matching the withdrawal.
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
