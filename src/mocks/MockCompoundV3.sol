// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";

/**
 * @title MockCompoundV3
 * @notice Mock Compound V3 (Comet) for unit tests.
 *
 * Key difference from V2: Comet tracks underlying balances directly (no cToken share).
 *
 * Behaviour:
 *  - supply(asset, amount)           → pull underlying from caller, record balance
 *  - withdraw(asset, amount)         → reduce balance, send underlying to caller
 *  - balanceOf(account)              → underlying balance (not shares)
 *  - getSupplyRate(utilization)      → configurable per-second rate
 *  - getUtilization()                → configurable utilization
 *  - simulateYield(amount)           → increase balance without new supply
 */
contract MockCompoundV3 {

    MockERC20 public immutable token;
    address private immutable _baseToken;

    mapping(address => uint256) private _balance; // underlying balance per account

    // Configurable supply rate per second (1e18 scale)
    // Default ≈ 3% APY: 0.03 / (365 * 24 * 3600) ≈ 9.51e8 in 1e18 = 951_293_760
    uint64 private _supplyRatePerSec = 951_293_760;

    // Configurable utilization (0–1e18, 1e18 = 100%)
    uint256 private _utilization = 0.8e18;

    constructor(address _underlying) {
        token       = MockERC20(_underlying);
        _baseToken  = _underlying;
    }

    // ─── Comet interface ──────────────────────────────────────────────────────

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    /**
     * @notice Supply underlying tokens to the caller's Comet account.
     */
    function supply(address asset, uint256 amount) external {
        require(asset == _baseToken, "MockCompoundV3: wrong asset");
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "MockCompoundV3: transferFrom failed"
        );
        _balance[msg.sender] += amount;
    }

    /**
     * @notice Withdraw underlying tokens from the caller's Comet account.
     *         Sends underlying to msg.sender.
     */
    function withdraw(address asset, uint256 amount) external {
        require(asset == _baseToken, "MockCompoundV3: wrong asset");
        require(_balance[msg.sender] >= amount, "MockCompoundV3: insufficient balance");
        _balance[msg.sender] -= amount;
        require(
            token.transfer(msg.sender, amount),
            "MockCompoundV3: transfer failed"
        );
    }

    /**
     * @notice Underlying balance of account (not cToken shares).
     */
    function balanceOf(address account) external view returns (uint256) {
        return _balance[account];
    }

    /**
     * @notice Supply rate per second at the given utilization (1e18 scale).
     */
    function getSupplyRate(uint256 /* utilization */) external view returns (uint64) {
        return _supplyRatePerSec;
    }

    /**
     * @notice Current borrow utilization (0–1e18).
     */
    function getUtilization() external view returns (uint256) {
        return _utilization;
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Simulate yield accrual: increase account balance without new supply.
     * @param account Account to credit (usually the strategy address)
     * @param amount  Yield amount in underlying tokens
     */
    function simulateYield(address account, uint256 amount) external {
        token.mint(address(this), amount);
        _balance[account] += amount;
    }

    function setSupplyRatePerSec(uint64 rate) external {
        _supplyRatePerSec = rate;
    }

    function setUtilization(uint256 util) external {
        _utilization = util;
    }
}
