// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";

/**
 * @title MockERC4626Vault
 * @notice Generic mock ERC-4626 vault for unit testing MorphoStrategy and YearnV3Strategy.
 *
 * Behaviour:
 *  - deposit(assets, receiver)        → pull underlying, mint proportional shares
 *  - withdraw(assets, receiver, owner)→ burn proportional shares, send underlying
 *  - convertToAssets(shares)          → shares * totalAssets / totalShares
 *  - balanceOf(account)               → vault share balance
 *  - simulateYield(amount)            → increase totalAssets without new shares
 *  - apr()                            → configurable APR in RAY (1e27) for Morpho tests
 *  - estimatedApr()                   → same value, for Yearn tests
 */
contract MockERC4626Vault {

    MockERC20 public immutable asset;

    // ERC-20-like share token state
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply; // total vault shares

    // ERC-4626 state
    uint256 public totalAssets; // total underlying managed

    // Configurable APR in RAY (1e27); 5% = 0.05e27 = 5e25
    uint256 private _aprRay;

    constructor(address _asset, uint256 aprRay) {
        asset   = MockERC20(_asset);
        _aprRay = aprRay;
    }

    // ─── ERC-4626 core ────────────────────────────────────────────────────────

    /**
     * @notice Deposit assets, receive proportional shares.
     * @param assets   Amount of underlying to deposit
     * @param receiver Address to receive vault shares
     * @return shares  Number of vault shares minted
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, "MockERC4626: zero assets");
        shares = convertToShares(assets);
        require(shares > 0, "MockERC4626: zero shares");

        require(
            asset.transferFrom(msg.sender, address(this), assets),
            "MockERC4626: transferFrom failed"
        );

        balanceOf[receiver] += shares;
        totalSupply         += shares;
        totalAssets         += assets;
    }

    /**
     * @notice Withdraw exact underlying amount, burning proportional shares.
     * @param assets   Amount of underlying to receive
     * @param receiver Address to receive underlying
     * @param owner_   Address whose shares are burned
     * @return shares  Number of vault shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        shares = convertToShares(assets);

        // Allow owner or approved spender
        if (msg.sender != owner_) {
            require(allowance[owner_][msg.sender] >= shares, "MockERC4626: not approved");
            allowance[owner_][msg.sender] -= shares;
        }

        require(balanceOf[owner_] >= shares, "MockERC4626: insufficient shares");

        balanceOf[owner_] -= shares;
        totalSupply       -= shares;
        totalAssets       -= assets;

        require(
            asset.transfer(receiver, assets),
            "MockERC4626: transfer failed"
        );
    }

    /**
     * @notice Redeem exact shares for underlying.
     */
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        assets = convertToAssets(shares);

        if (msg.sender != owner_) {
            require(allowance[owner_][msg.sender] >= shares, "MockERC4626: not approved");
            allowance[owner_][msg.sender] -= shares;
        }

        require(balanceOf[owner_] >= shares, "MockERC4626: insufficient shares");

        balanceOf[owner_] -= shares;
        totalSupply       -= shares;
        totalAssets       -= assets;

        require(
            asset.transfer(receiver, assets),
            "MockERC4626: transfer failed"
        );
    }

    // ─── ERC-4626 view ────────────────────────────────────────────────────────

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares; // 1:1 when empty
        return (shares * totalAssets) / totalSupply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalSupply == 0 || totalAssets == 0) return assets; // 1:1 when empty
        return (assets * totalSupply) / totalAssets;
    }

    // ─── ERC-20 approve (needed by ERC4626Strategy constructor) ──────────────

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // ─── APR getters (used by MorphoStrategy / YearnV3Strategy) ──────────────

    /// @notice APR in RAY (1e27); used by MorphoStrategy
    function apr() external view returns (uint256) {
        return _aprRay;
    }

    /// @notice APR in WAD (1e18); used by YearnV3Strategy
    function estimatedApr() external view returns (uint256) {
        // convert RAY to WAD: _aprRay / 1e9
        return _aprRay / 1e9;
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Inject yield: increase totalAssets without minting new shares.
     *         Each share is now worth more underlying.
     */
    function simulateYield(uint256 amount) external {
        asset.mint(address(this), amount);
        totalAssets += amount;
    }

    function setApr(uint256 aprRay) external {
        _aprRay = aprRay;
    }
}
