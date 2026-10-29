// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";
import "./MockAToken.sol";

/**
 * @title MockAavePool
 * @notice Minimal Aave V3 pool mock for local / unit-test use.
 *
 * Behaviour:
 *  - supply()          → pulls underlying from caller, mints aTokens to onBehalfOf
 *  - withdraw()        → burns aTokens from caller, sends underlying to `to`
 *  - simulateYield()   → mints extra aTokens to a target (simulates interest accrual)
 *
 * The pool holds all supplied underlying tokens so it can honour withdrawals.
 */
contract MockAavePool {
    MockERC20  public underlying;
    MockAToken public aToken;

    constructor(address _underlying, address _aToken) {
        underlying = MockERC20(_underlying);
        aToken     = MockAToken(_aToken);
    }

    /**
     * @notice Simulates Aave supply: pull tokens from strategy, mint aTokens to strategy.
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16  /* referralCode */
    ) external {
        // Pull underlying from the caller (AaveStrategy)
        require(
            MockERC20(asset).transferFrom(msg.sender, address(this), amount),
            "MockAavePool: supply transferFrom failed"
        );
        // Mint aTokens 1:1 to the designated recipient
        aToken.mint(onBehalfOf, amount);
    }

    /**
     * @notice Simulates Aave withdraw: burn aTokens from caller, send underlying to `to`.
     * @return The actual amount of underlying sent.
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        // Burn aTokens from the caller (AaveStrategy)
        aToken.burn(msg.sender, amount);
        // Transfer underlying to the target (may be AaveStrategy or NoLossLottery)
        require(
            MockERC20(asset).transfer(to, amount),
            "MockAavePool: withdraw transfer failed"
        );
        return amount;
    }

    /**
     * @notice Inject yield: mint extra aTokens to `target` (simulating interest accrual).
     *         Also mints the corresponding underlying to the pool so withdrawals stay solvent.
     * @param target       Address to receive the extra aTokens (usually AaveStrategy).
     * @param yieldAmount  Amount of yield tokens to inject.
     */
    function simulateYield(address target, uint256 yieldAmount) external {
        // Mint underlying to the pool so it can honour future withdrawals
        underlying.mint(address(this), yieldAmount);
        // Mint aTokens to the strategy (increasing getTotalValue())
        aToken.mint(target, yieldAmount);
    }
}
