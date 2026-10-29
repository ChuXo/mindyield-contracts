// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockAToken
 * @notice Mock Aave aToken for local / unit-test use.
 *         Simulates the ERC-20 balance that AaveStrategy reads via
 *         `aToken.balanceOf(address(strategy))` to compute getTotalValue().
 */
contract MockAToken {
    // ─── ERC-20 state ─────────────────────────────────────────────────────────
    string public name     = "Mock aToken";
    string public symbol   = "maToken";
    uint8  public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ─── Aave-specific ────────────────────────────────────────────────────────
    address public immutable underlyingAsset;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address _underlyingAsset) {
        underlyingAsset = _underlyingAsset;
    }

    /// @notice Required by AaveStrategy constructor check.
    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return underlyingAsset;
    }

    /// @notice Scaled balance — not used in our strategy, returns raw balance.
    function scaledBalanceOf(address user) external view returns (uint256) {
        return balanceOf[user];
    }

    // ─── Mint / burn (called by MockAavePool) ─────────────────────────────────

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "MockAToken: insufficient balance");
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ─── Standard ERC-20 ──────────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockAToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockAToken: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockAToken: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
