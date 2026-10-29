// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IYieldVault.sol";
import "./interfaces/IYieldStrategy.sol";

/**
 * @title YieldVault
 * @notice Manages deposits to yield strategies and tracks shares
 * @dev ERC-4626 style vault wrapper for multiple strategies
 * @dev Uses virtual shares/assets offset (OZ 5.x pattern) to prevent first-depositor inflation attacks
 * @dev Uses depositBlock mapping to prevent same-block deposit-withdraw (flash loan protection)
 * @dev Uses ReentrancyGuard for protection against reentrancy attacks
 * @dev Uses SafeERC20 for safe token transfers
 */
contract YieldVault is IYieldVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bool public paused;

    /// @dev Virtual shares offset to prevent first-depositor inflation attack
    uint256 private constant _VIRTUAL_SHARES = 1e6;
    /// @dev Virtual assets offset to prevent first-depositor inflation attack
    uint256 private constant _VIRTUAL_ASSETS = 1;

    struct Strategy {
        address strategyAddress;
        bool active;
        uint256 totalShares;
        /// @dev Aggregate total deposited across ALL tokens for this strategy.
        ///      Used for share-price calculation in _getStrategyValue() when no external strategy exists.
        uint256 totalDeposited;
    }

    mapping(uint256 => Strategy) public strategies;
    uint256 public strategyCount;

    // token => strategyId => depositor => shares
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userShares;

    /// @dev Per-token deposit tracking for a given strategy.
    ///      Complements Strategy.totalDeposited (which is token-agnostic aggregate).
    ///      Needed because the vault supports multiple tokens per strategy.
    // token => strategyId => total deposited
    mapping(address => mapping(uint256 => uint256)) public tokenDeposits;

    /// @dev Flash loan protection: block number of last deposit per user per token per strategy
    mapping(address => mapping(address => mapping(uint256 => uint256))) public depositBlock;

    /// @dev Flash loan protection on L2: timestamp of last deposit per user per token per strategy
    /// On L2s like Base, multiple transactions can share a block.number, so we also
    /// enforce a minimum hold time measured in seconds.
    mapping(address => mapping(address => mapping(uint256 => uint256))) public depositTimestamp;

    /// @dev Per-token share totals for a given strategy (prevents cross-token share contamination)
    mapping(address => mapping(uint256 => uint256)) public tokenTotalShares;

    /// @dev Minimum hold time in seconds (prevents same-timestamp bypass on L2)
    uint256 public constant MIN_HOLD_TIME = 60;

    error Paused();
    error NotPaused();
    error StrategyNotActive();
    error InsufficientShares();
    error TransferFailed();
    error ZeroAmount();
    error InvalidStrategy();
    error SameBlockWithdraw();
    error NotGuardianOrOwner();

    /// @notice Guardian can pause but not unpause. Set by owner; allows fast
    ///         emergency response without requiring a multisig signature ceremony.
    address public guardian;

    event VaultPaused(address indexed by, uint256 timestamp);
    event VaultUnpaused(address indexed by, uint256 timestamp);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event StrategyLossDetected(uint256 strategyId, uint256 expectedAmount, uint256 actualAmount);

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    constructor() Ownable() {}

    /**
     * @notice Get the actual total value held in a strategy (principal + yield)
     * @dev For address(0) strategies (simple hold), returns totalDeposited since there's no external yield.
     *      For real strategies, queries getTotalValue() which includes accrued yield.
     * @param strategy The strategy struct
     * @return The total value of assets in the strategy
     */
    function _getStrategyValue(Strategy storage strategy) internal view returns (uint256) {
        if (strategy.strategyAddress == address(0)) {
            return strategy.totalDeposited;
        }
        return IYieldStrategy(strategy.strategyAddress).getTotalValue();
    }

    /**
     * @notice Get estimated per-token value for a strategy
     * @dev For multi-token strategies, approximates token-specific value proportionally.
     *      Prevents cross-token share contamination when multiple tokens share a strategy.
     * @param token The token address
     * @param strategyId The strategy ID
     * @return The estimated value for this token in the strategy
     */
    function _getStrategyTokenValue(address token, uint256 strategyId) internal view returns (uint256) {
        Strategy storage strategy = strategies[strategyId];
        uint256 totalValue = _getStrategyValue(strategy);
        if (strategy.totalDeposited == 0) return 0;
        // Proportional value based on per-token deposits vs total deposits
        return (totalValue * tokenDeposits[token][strategyId]) / strategy.totalDeposited;
    }

    /**
     * @notice Add a new yield strategy
     * @param strategyAddress Address of the strategy contract
     * @return strategyId The ID of the new strategy
     */
    function addStrategy(address strategyAddress) external onlyOwner returns (uint256 strategyId) {
        strategyId = strategyCount++;
        strategies[strategyId] = Strategy({
            strategyAddress: strategyAddress,
            active: true,
            totalShares: 0,
            totalDeposited: 0
        });

        emit StrategyUpdated(strategyId, strategyAddress, true);
    }

    /**
     * @notice Activate or deactivate a strategy
     */
    function setStrategyActive(uint256 strategyId, bool active) external onlyOwner {
        if (strategyId >= strategyCount) revert InvalidStrategy();

        strategies[strategyId].active = active;
        emit StrategyUpdated(strategyId, strategies[strategyId].strategyAddress, active);
    }

    /// @notice Trusted depositor registry — used to exempt MindYield contest
    ///         contracts (which have their own per-user flash-loan defenses)
    ///         from the vault-level hold-time guard. Without this, one user's
    ///         deposit into a shared contest vault resets the hold-time window
    ///         for ALL users, since `depositBlock[msg.sender]` is keyed on the
    ///         contest contract address — see audit finding H-01, 2026-04-18.
    mapping(address => bool) public trustedDepositor;
    event TrustedDepositorUpdated(address indexed depositor, bool trusted);

    /// @notice Owner-only setter. Call with `trusted=true` for each
    ///         ProbabilityVaultV2 clone (or other contest vault with its own
    ///         user-level flash-loan protection) to exempt them from the
    ///         vault's per-depositor MIN_HOLD_TIME + same-block guards.
    function setTrustedDepositor(address depositor, bool trusted) external onlyOwner {
        trustedDepositor[depositor] = trusted;
        emit TrustedDepositorUpdated(depositor, trusted);
    }

    /**
     * @notice Deposit tokens into a yield strategy
     * @param token Token address to deposit
     * @param amount Amount to deposit
     * @param strategyId Strategy to use
     * @return shares Number of shares received
     * @dev Uses virtual offset to prevent first-depositor inflation attack
     * @dev Protected against reentrancy, uses SafeERC20 for token transfers
     */
    function deposit(
        address token,
        uint256 amount,
        uint256 strategyId
    ) external override whenNotPaused nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (!strategies[strategyId].active) revert StrategyNotActive();

        // Transfer tokens from sender using SafeERC20
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate shares using per-token value to prevent cross-token share contamination
        // shares = amount * (tokenTotalShares + virtualShares) / (tokenStrategyValue + virtualAssets)
        Strategy storage strategy = strategies[strategyId];
        uint256 tokenValue = _getStrategyTokenValue(token, strategyId);
        uint256 tokenShares = tokenTotalShares[token][strategyId];
        shares = (amount * (tokenShares + _VIRTUAL_SHARES)) / (tokenValue + _VIRTUAL_ASSETS);

        // Update accounting before external calls (checks-effects-interactions)
        strategy.totalShares += shares;
        strategy.totalDeposited += amount;
        userShares[token][strategyId][msg.sender] += shares;
        tokenDeposits[token][strategyId] += amount;

        // Track per-token shares
        tokenTotalShares[token][strategyId] += shares;

        // Record deposit block and timestamp for flash loan protection (per-token)
        depositBlock[msg.sender][token][strategyId] = block.number;
        depositTimestamp[msg.sender][token][strategyId] = block.timestamp;

        // If strategy has an external protocol, deposit there
        if (strategy.strategyAddress != address(0)) {
            // Approve strategy to spend tokens — reset first for USDT compatibility
            IERC20(token).safeApprove(strategy.strategyAddress, 0);
            IERC20(token).safeApprove(strategy.strategyAddress, amount);

            // Typed interface call — prevents wrong-signature silent failures
            IYieldStrategy(strategy.strategyAddress).deposit(amount);
        }

        emit Deposited(msg.sender, token, amount, shares);
    }

    /**
     * @notice Withdraw tokens from a yield strategy
     * @param token Token address to withdraw
     * @param shares Number of shares to redeem
     * @param strategyId Strategy to withdraw from
     * @param recipient Address to receive tokens
     * @return amount Amount of tokens received
     * @dev Uses virtual offset for consistent share valuation
     * @dev Prevents same-block deposit-withdraw (flash loan protection)
     * @dev Protected against reentrancy, uses SafeERC20 for token transfers
     * @dev Withdraw is intentionally NOT gated by `whenNotPaused`. The Guardian
     *      pause must never strand principal — ContestV2, MirrorContestV2 and
     *      ProbabilityVaultV2 all redeem participant principal via this path.
     *      Mirrors AutoYieldVault.withdraw and PVAutoYieldAdapter.withdraw,
     *      which deliberately skip the modifier for the same reason. Pausing
     *      blocks new deposits via `deposit()` (which DOES carry the modifier);
     *      that's sufficient as an emergency lever without violating the
     *      no-loss invariant.
     */
    function withdraw(
        address token,
        uint256 shares,
        uint256 strategyId,
        address recipient
    ) external override nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (userShares[token][strategyId][msg.sender] < shares) revert InsufficientShares();

        // Flash loan protection: prevent same-block deposit-withdraw (per-token).
        // Trusted contest vaults (registered via `setTrustedDepositor`) are
        // exempt because they enforce per-END-USER flash-loan defenses in their
        // own storage — without this exemption, one user's deposit would DoS
        // every other user's withdraw for the hold-time window (audit H-01).
        if (!trustedDepositor[msg.sender]) {
            if (depositBlock[msg.sender][token][strategyId] == block.number) revert SameBlockWithdraw();
            // L2 flash loan protection: enforce minimum hold time (block.number alone is
            // insufficient on L2s where multiple txs can share the same block number)
            require(
                block.timestamp >= depositTimestamp[msg.sender][token][strategyId] + MIN_HOLD_TIME,
                "YieldVault: minimum hold time not met"
            );
        }

        Strategy storage strategy = strategies[strategyId];

        // Calculate amount using per-token value to prevent cross-token contamination
        // amount = shares * (tokenStrategyValue + virtualAssets) / (tokenTotalShares + virtualShares)
        uint256 tokenValue = _getStrategyTokenValue(token, strategyId);
        uint256 tokenShares = tokenTotalShares[token][strategyId];
        amount = (shares * (tokenValue + _VIRTUAL_ASSETS)) / (tokenShares + _VIRTUAL_SHARES);

        // Update accounting before external calls (checks-effects-interactions)
        strategy.totalShares -= shares;
        // Clamp totalDeposited reduction to avoid underflow when yield causes amount > totalDeposited
        if (amount > strategy.totalDeposited) {
            emit StrategyLossDetected(strategyId, strategy.totalDeposited, amount);
            strategy.totalDeposited = 0;
        } else {
            strategy.totalDeposited -= amount;
        }
        userShares[token][strategyId][msg.sender] -= shares;
        // Update per-token share tracking
        if (shares > tokenTotalShares[token][strategyId]) {
            tokenTotalShares[token][strategyId] = 0;
        } else {
            tokenTotalShares[token][strategyId] -= shares;
        }
        // Clamp tokenDeposits to avoid underflow when withdrawing yield
        if (amount > tokenDeposits[token][strategyId]) {
            tokenDeposits[token][strategyId] = 0;
        } else {
            tokenDeposits[token][strategyId] -= amount;
        }

        // If strategy has external protocol, withdraw from there
        if (strategy.strategyAddress != address(0)) {
            // Compute how many strategy shares to burn for the desired token amount
            IYieldStrategy strat = IYieldStrategy(strategy.strategyAddress);
            uint256 stratTotalShares = strat.getShares(address(this));
            uint256 stratTotalValue  = strat.getTotalValue();
            uint256 stratSharesToBurn = stratTotalValue > 0
                ? (amount * stratTotalShares) / stratTotalValue
                : 0;
            if (stratSharesToBurn > 0) {
                strat.withdraw(stratSharesToBurn);
            }
        }

        // Transfer tokens to recipient using SafeERC20
        IERC20(token).safeTransfer(recipient, amount);

        emit Withdrawn(recipient, token, shares, amount);
    }

    /**
     * @notice Get current value of shares
     * @dev Uses actual strategy value (principal + yield) for accurate valuation
     */
    function getShareValue(
        address token,
        uint256 shares,
        uint256 strategyId
    ) external view override returns (uint256) {
        uint256 tokenValue = _getStrategyTokenValue(token, strategyId);
        uint256 tokenSharesTotal = tokenTotalShares[token][strategyId];
        return (shares * (tokenValue + _VIRTUAL_ASSETS)) / (tokenSharesTotal + _VIRTUAL_SHARES);
    }

    /**
     * @notice Get total deposited for a token in a strategy
     */
    function getTotalDeposited(
        address token,
        uint256 strategyId
    ) external view override returns (uint256) {
        return tokenDeposits[token][strategyId];
    }

    /**
     * @notice Check if strategy is active
     */
    function isStrategyActive(uint256 strategyId) external view override returns (bool) {
        return strategies[strategyId].active;
    }

    /**
     * @notice Pause the vault (emergency). Callable by owner OR guardian.
     * @dev Guardian intentionally cannot unpause — pause is one-directional from
     *      the guardian, mirroring the AffiliateDistributor / AutoYieldVault pattern.
     */
    function pause() external override whenNotPaused {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner();
        paused = true;
        emit VaultPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpause the vault. Owner-only.
     */
    function unpause() external override onlyOwner whenPaused {
        paused = false;
        emit VaultUnpaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Set the guardian address (emergency-pause role). Owner-only.
     * @dev Set once at deploy; rarely changed. Pass address(0) to revoke.
     */
    function setGuardian(address _guardian) external onlyOwner {
        emit GuardianUpdated(guardian, _guardian);
        guardian = _guardian;
    }

    /**
     * @notice Get user's shares for a token/strategy
     */
    function getUserShares(
        address user,
        address token,
        uint256 strategyId
    ) external view returns (uint256) {
        return userShares[token][strategyId][user];
    }

}
