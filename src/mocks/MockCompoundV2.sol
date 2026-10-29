// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";

/**
 * @title MockCompoundV2
 * @notice Mock Compound V2 cToken for unit tests.
 *
 * Behaviour:
 *  - mint(amount)          → pull underlying from caller, issue cTokens at current exchange rate
 *  - redeemUnderlying(amt) → burn cTokens, send underlying to caller
 *  - exchangeRateStored()  → Compound V2-accurate rate: 10^(10+dec) scale
 *  - supplyRatePerBlock()  → configurable (default ~3% APY at 2.6M blocks/year)
 *  - simulateYield(amount) → increases totalUnderlying without new cTokens → exchange rate rises
 *
 * Exchange rate scale: 10^(10 + underlyingDecimals) — matches real Compound V2 mantissa.
 * For USDC (6 dec) the initial rate is 10^16; for DAI (18 dec) it is 10^28.
 */
contract MockCompoundV2 {

    MockERC20 public immutable token; // underlying ERC-20 token

    // Internal accounting
    uint256 public totalUnderlying; // total underlying held by this cToken (principal + yield)
    uint256 public totalCTokens;    // total cToken supply

    // Exchange rate scale: 10^(10 + underlyingDecimals)
    uint256 private immutable _exchangeRateScale;

    // Configurable supply rate (per block, 1e18 scale)
    // Default ≈ 3% APY: 0.03 / 2_628_000 blocks * 1e18 ≈ 1.14e10
    uint256 private _supplyRatePerBlock = 11_415_525_115;

    mapping(address => uint256) private _cTokenBalance;

    address private immutable _underlyingAddr;

    constructor(address _underlying) {
        token           = MockERC20(_underlying);
        _underlyingAddr = _underlying;
        uint8 dec       = MockERC20(_underlying).decimals();
        _exchangeRateScale = 10 ** (10 + uint256(dec));
    }

    // ─── cToken interface ─────────────────────────────────────────────────────

    /// @notice Returns the underlying token address (ICToken.underlying())
    function underlying() external view returns (address) {
        return _underlyingAddr;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _cTokenBalance[owner];
    }

    /**
     * @notice Current exchange rate (Compound V2 mantissa: 10^(10+underlyingDecimals) scale).
     *         For USDC (6 dec) the initial rate is 10^16.
     */
    function exchangeRateStored() public view returns (uint256) {
        if (totalCTokens == 0) return _exchangeRateScale;
        return (totalUnderlying * _exchangeRateScale) / totalCTokens;
    }

    function supplyRatePerBlock() external view returns (uint256) {
        return _supplyRatePerBlock;
    }

    /**
     * @notice Mint cTokens by supplying underlying.
     * @param mintAmount Amount of underlying to supply
     * @return 0 on success (Compound V2 convention)
     */
    function mint(uint256 mintAmount) external returns (uint256) {
        uint256 rate = exchangeRateStored();

        require(
            token.transferFrom(msg.sender, address(this), mintAmount),
            "MockCompoundV2: transferFrom failed"
        );

        uint256 cTokensMinted = (mintAmount * _exchangeRateScale) / rate;
        _cTokenBalance[msg.sender] += cTokensMinted;
        totalCTokens               += cTokensMinted;
        totalUnderlying            += mintAmount;

        return 0;
    }

    /**
     * @notice Redeem exact underlying amount.
     * @param redeemAmount Amount of underlying to receive
     * @return 0 on success
     */
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        require(redeemAmount <= totalUnderlying, "MockCompoundV2: insufficient liquidity");
        require(totalCTokens > 0, "MockCompoundV2: no supply");

        uint256 rate          = exchangeRateStored();
        uint256 cTokensBurned = (redeemAmount * _exchangeRateScale + rate - 1) / rate; // round up

        // Clamp to caller's balance to avoid precision dust issues
        if (cTokensBurned > _cTokenBalance[msg.sender]) {
            cTokensBurned = _cTokenBalance[msg.sender];
        }
        require(_cTokenBalance[msg.sender] >= cTokensBurned, "MockCompoundV2: insufficient cTokens");

        _cTokenBalance[msg.sender] -= cTokensBurned;
        totalCTokens               -= cTokensBurned;
        totalUnderlying            -= redeemAmount;

        require(
            token.transfer(msg.sender, redeemAmount),
            "MockCompoundV2: transfer failed"
        );

        return 0;
    }

    /**
     * @notice Redeem exact cToken amount.
     * @param redeemTokens Number of cTokens to burn
     * @return 0 on success
     */
    function redeem(uint256 redeemTokens) external returns (uint256) {
        require(_cTokenBalance[msg.sender] >= redeemTokens, "MockCompoundV2: insufficient cTokens");

        uint256 rate          = exchangeRateStored();
        uint256 underlyingOut = (redeemTokens * rate) / _exchangeRateScale;

        _cTokenBalance[msg.sender] -= redeemTokens;
        totalCTokens               -= redeemTokens;
        totalUnderlying            -= underlyingOut;

        require(
            token.transfer(msg.sender, underlyingOut),
            "MockCompoundV2: transfer failed"
        );

        return 0;
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Simulate yield accrual: increase underlying balance without minting new cTokens.
     *         This increases the exchange rate, making each cToken worth more.
     * @param amount Yield amount in underlying tokens
     */
    function simulateYield(uint256 amount) external {
        token.mint(address(this), amount);
        totalUnderlying += amount;
    }

    function setSupplyRatePerBlock(uint256 rate) external {
        _supplyRatePerBlock = rate;
    }
}
