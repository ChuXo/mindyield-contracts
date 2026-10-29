// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IYieldVault.sol";
import "../interfaces/IAutoYieldStrategy.sol";

/**
 * @title PVAutoYieldAdapter
 * @notice Drop-in replacement for the old single-strategy YieldVault when used
 *         as the `yieldVault` parameter of ProbabilityVaultV2.
 *
 *         Unlike the generic YieldVault, this adapter:
 *         - Accepts only one deposit token (set at construction).
 *         - Manages an active IAutoYieldStrategy (Aave V3, Compound V3, Morpho…).
 *         - Allows the owner to queue a strategy switch with a configurable
 *           timelock (default 24 hours), mirroring AutoYieldVault's model.
 *         - Tracks depositor shares using a simple ERC-4626-style accounting
 *           with virtual offsets to prevent first-depositor inflation.
 *
 *         Multiple ProbabilityVault clones can share ONE adapter instance,
 *         which is more capital-efficient: their combined deposits earn yield
 *         in the same strategy, and each vault redeems its proportional share
 *         at resolution time.
 *
 *         Strategy-switch safety:
 *         - Slippage guard: migration must not lose > MAX_MIGRATION_LOSS_BPS.
 *         - Timelock: pendingStrategySwitchTime must have elapsed.
 *         - Anyone can execute a queued switch once the timelock passes
 *           (permissionless execution, owner-only queueing).
 *
 * @dev setTrustedDepositor is a no-op here (compatibility shim for
 *      ProbabilityVaultFactory's optional call).
 */
contract PVAutoYieldAdapter is IYieldVault, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @dev Virtual shares/assets offset (EIP-4626 inflation attack prevention).
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    /// @notice Maximum acceptable loss when migrating between strategies.
    /// @dev    Tightened from 100 (1%) to 50 (0.5%) on 2026-04-28 per the
    ///         pre-deploy audit. `executeStrategySwitch` is permissionless
    ///         after the timelock, so the slippage cap is the only floor on
    ///         how much a sandwich-bot can extract during the migration tx.
    ///         At $10M TVL, 50 bps caps a single switch loss at $50k; combined
    ///         with the 24h queue + cancel window this is the right pre-deploy
    ///         setting. Re-evaluate after 6 months of operational data.
    uint256 public constant MAX_MIGRATION_LOSS_BPS = 50;

    // ─── Config ───────────────────────────────────────────────────────────────

    address public immutable depositToken;

    IAutoYieldStrategy public activeStrategy;

    uint256 public switchDelay = 24 hours;

    // ─── Pending switch ───────────────────────────────────────────────────────

    IAutoYieldStrategy public pendingStrategy;
    uint256 public pendingSwitchTime; // timestamp after which execute is allowed

    // ─── Emergency pause (Guardian-compatible) ────────────────────────────────

    /// @notice Guardian address authorized to call `pause()` (in addition to
    ///         the owner). Settable by the owner. Set to a Guardian contract
    ///         (per docs/MAINNET_RELAUNCH_RUNBOOK.md) so the multisig can halt
    ///         all pause-able protocol contracts in one tx during an incident.
    address public guardian;

    // ─── Harvest rate-limit ───────────────────────────────────────────────────

    /// @notice Block of the most recent successful harvest. Combined with
    ///         `MIN_HARVEST_INTERVAL` it caps how often the share price can
    ///         spike upward, mitigating the deposit-sandwich described in the
    ///         pre-deploy audit (M-5).
    uint256 public lastHarvestBlock;

    /// @notice Minimum number of blocks between harvests. On Base (~2s/block)
    ///         300 blocks ≈ 10 minutes — enough to neutralize same-block /
    ///         same-tx sandwich while still letting the off-chain keeper run
    ///         on a sensible cadence.
    uint256 public constant MIN_HARVEST_INTERVAL = 300;

    // ─── Share accounting ─────────────────────────────────────────────────────

    uint256 public totalShares; // virtual-offset excluded
    mapping(address => uint256) public userShares;

    // ─── Events ───────────────────────────────────────────────────────────────

    event StrategySwitchQueued(address indexed newStrategy, uint256 executeAfter);
    event StrategySwitchExecuted(address indexed oldStrategy, address indexed newStrategy);
    event StrategySwitchCancelled(address indexed strategy);
    event SwitchDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event Harvested(uint256 amount);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error WrongToken();
    error ZeroAmount();
    error NoStrategySet();
    error NoPendingSwitch();
    error SwitchTooEarly();
    error SlippageTooHigh(uint256 expected, uint256 actual);
    error AlreadyQueued();
    error ZeroAddress();
    error InsufficientShares();
    error HarvestTooFrequent();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _depositToken,
        address _initialStrategy,
        address _owner
    ) Ownable() {
        if (_depositToken == address(0) || _initialStrategy == address(0)) revert ZeroAddress();
        depositToken   = _depositToken;
        activeStrategy = IAutoYieldStrategy(_initialStrategy);
        if (_owner != address(0) && _owner != msg.sender) _transferOwnership(_owner);
    }

    // ─── IYieldVault — deposit ────────────────────────────────────────────────

    /**
     * @notice Pull `amount` of depositToken from msg.sender, deposit into the
     *         active strategy, and return the shares minted.
     * @param token  Must equal depositToken.
     * @param amount Amount of deposit tokens.
     * @return shares Shares minted to msg.sender (used by PV as vaultShares).
     */
    function deposit(
        address token,
        uint256 amount,
        uint256 /* strategyId */
    ) external override nonReentrant whenNotPaused returns (uint256 shares) {
        if (token != depositToken) revert WrongToken();
        if (amount == 0)           revert ZeroAmount();
        if (address(activeStrategy) == address(0)) revert NoStrategySet();

        // Fee-on-transfer-token safety + EIP-4626 preview-then-mint:
        // - snapshot totalAssets BEFORE the transfer (so the new deposit is
        //   not in the denominator),
        // - then measure the actual received amount via balance delta and
        //   credit shares against THAT, not the nominal `amount`.
        // The `received` calc lives in a scoped block so its locals
        // (balBefore + received) are released before _toShares / approve /
        // strategy.deposit run — this is what keeps via_ir's stack happy.
        uint256 received = _pullTokensReceived(token, amount);
        shares = _toShares(received, _totalAssets() - received);

        // Forward the actually-received amount into the active strategy.
        IERC20(token).forceApprove(address(activeStrategy), received);
        activeStrategy.deposit(received);

        totalShares += shares;
        userShares[msg.sender] += shares;

        emit IYieldVault.Deposited(msg.sender, token, received, shares);
    }

    /// @dev Pulls `amount` of `token` from msg.sender and returns the actual
    ///      balance delta. Reverts on zero received (handles fee-on-transfer
    ///      tokens that levy 100% fees, blacklisted-recipient quirks, etc.).
    ///      Extracted from `deposit` so its locals don't pressure the via_ir
    ///      stack budget of the caller.
    function _pullTokensReceived(address token, uint256 amount) internal returns (uint256) {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();
        return received;
    }

    // ─── IYieldVault — withdraw ───────────────────────────────────────────────

    /**
     * @notice Redeem `shares` and transfer the underlying tokens to `recipient`.
     * @param token      Must equal depositToken.
     * @param shares     Shares to redeem.
     * @param recipient  Address to receive the underlying tokens.
     * @return amount    Underlying tokens transferred.
     */
    /// @dev Withdraw is deliberately NOT gated by `whenNotPaused`. Pausing must
    ///      never trap user funds: ProbabilityVaultV2 clones MUST always be
    ///      able to pull their assets out at resolve/cancel/early-withdraw,
    ///      otherwise an emergency pause becomes a hostage event for every
    ///      live market. Pause only blocks NEW capital inflow + strategy
    ///      migration; outflow stays open at all times.
    function withdraw(
        address token,
        uint256 shares,
        uint256 /* strategyId */,
        address recipient
    ) external override nonReentrant returns (uint256 amount) {
        if (token != depositToken) revert WrongToken();
        if (shares == 0)           revert ZeroAmount();
        if (address(activeStrategy) == address(0)) revert NoStrategySet();
        if (userShares[msg.sender] < shares) revert InsufficientShares();

        uint256 totalAssets = _totalAssets();
        amount = _toAssets(shares, totalAssets);

        totalShares -= shares;
        userShares[msg.sender] -= shares;

        // Withdraw from strategy and forward to recipient. The strategy may
        // return slightly less than the requested `amount` because of double
        // truncation in its share→asset math; in that case the adapter would
        // not hold the full target and the subsequent transfer would revert.
        // Use the actual received balance as the authoritative payout amount —
        // narrows only, never widens, so it cannot over-pay.
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        activeStrategy.withdrawAmount(amount);
        uint256 received  = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received < amount) amount = received;
        IERC20(token).safeTransfer(recipient, amount);

        emit IYieldVault.Withdrawn(recipient, token, shares, amount);
    }

    // ─── IYieldVault — views ──────────────────────────────────────────────────

    function getShareValue(
        address token,
        uint256 shares,
        uint256 /* strategyId */
    ) external view override returns (uint256) {
        if (token != depositToken) return 0;
        return _toAssets(shares, _totalAssets());
    }

    function getTotalDeposited(
        address token,
        uint256 /* strategyId */
    ) external view override returns (uint256) {
        if (token != depositToken) return 0;
        return address(activeStrategy) != address(0) ? activeStrategy.getTotalValue() : 0;
    }

    function isStrategyActive(uint256 /* strategyId */) external pure override returns (bool) {
        return true;
    }

    // ─── Pause / Guardian admin ───────────────────────────────────────────────

    /// @notice Pause deposits, withdrawals, strategy switches, and harvests.
    /// @dev    Callable by owner OR the configured Guardian. The Guardian-
    ///         registered path lets the multisig halt the prediction market
    ///         product alongside the lottery + AutoYieldVault in a single tx.
    function pause() external override {
        require(msg.sender == owner() || msg.sender == guardian, "PVAdapter: not authorized");
        _pause();
    }

    /// @notice Unpause. Owner-only by design — Guardian can pause but not
    ///         unpause, mirroring the AutoYieldVault pattern.
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @notice Wire a Guardian for emergency pauses. Set to address(0) to
    ///         disable guardian-pause path entirely.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @dev Compatibility shim for ProbabilityVaultFactory.setTrustedDepositor.
    function setTrustedDepositor(address, bool) external {}

    // ─── Strategy switching ───────────────────────────────────────────────────

    /**
     * @notice Queue a strategy switch. Executes after `switchDelay` has elapsed.
     *         Only owner can queue; anyone can execute once the delay passes.
     * @param newStrategy The strategy to switch to.
     */
    function queueStrategySwitch(address newStrategy) external onlyOwner {
        if (newStrategy == address(0)) revert ZeroAddress();
        if (address(pendingStrategy) != address(0)) revert AlreadyQueued();

        pendingStrategy   = IAutoYieldStrategy(newStrategy);
        pendingSwitchTime = block.timestamp + switchDelay;
        emit StrategySwitchQueued(newStrategy, pendingSwitchTime);
    }

    /**
     * @notice Execute the queued strategy switch. Permissionless after delay.
     *         Migrates ALL assets from the old strategy to the new one.
     */
    function executeStrategySwitch() external nonReentrant whenNotPaused {
        if (address(pendingStrategy) == address(0)) revert NoPendingSwitch();
        if (block.timestamp < pendingSwitchTime)    revert SwitchTooEarly();

        IAutoYieldStrategy oldStrategy = activeStrategy;
        IAutoYieldStrategy newStrategy = pendingStrategy;

        pendingStrategy   = IAutoYieldStrategy(address(0));
        pendingSwitchTime = 0;

        // Withdraw everything from old strategy
        uint256 valueBefore = oldStrategy.getTotalValue();
        uint256 received    = 0;
        if (valueBefore > 0) {
            received = oldStrategy.withdrawAmount(valueBefore);

            // Slippage check: migration must not lose more than MAX_MIGRATION_LOSS_BPS
            uint256 minReceived = valueBefore - (valueBefore * MAX_MIGRATION_LOSS_BPS / 10_000);
            if (received < minReceived) revert SlippageTooHigh(minReceived, received);

            // Deposit all received into new strategy
            IERC20(depositToken).forceApprove(address(newStrategy), received);
            newStrategy.deposit(received);
        }

        activeStrategy = newStrategy;
        emit StrategySwitchExecuted(address(oldStrategy), address(newStrategy));
    }

    /**
     * @notice Cancel a queued switch (e.g. if the new strategy becomes suspect).
     */
    function cancelStrategySwitch() external onlyOwner {
        if (address(pendingStrategy) == address(0)) revert NoPendingSwitch();
        address cancelled = address(pendingStrategy);
        pendingStrategy   = IAutoYieldStrategy(address(0));
        pendingSwitchTime = 0;
        emit StrategySwitchCancelled(cancelled);
    }

    /**
     * @notice Harvest accrued yield from the active strategy.
     *         Yield stays idle in this contract until the next deposit picks
     *         it up (because deposit() reads getTotalValue() which includes
     *         idle tokens). Alternatively, call harvestAndReinvest().
     */
    function harvest() external nonReentrant whenNotPaused returns (uint256 harvested) {
        if (address(activeStrategy) == address(0)) revert NoStrategySet();
        // Rate-limit to prevent share-price-sandwich (M-5). A keeper that
        // tries to call harvest more often than every MIN_HARVEST_INTERVAL
        // blocks reverts; legitimate cadence is preserved.
        if (lastHarvestBlock != 0 && block.number < lastHarvestBlock + MIN_HARVEST_INTERVAL) {
            revert HarvestTooFrequent();
        }
        lastHarvestBlock = block.number;
        harvested = activeStrategy.harvestYield();
        emit Harvested(harvested);
    }

    /**
     * @notice Harvest and immediately re-deposit idle tokens into the strategy.
     */
    function harvestAndReinvest() external nonReentrant whenNotPaused returns (uint256 harvested) {
        if (address(activeStrategy) == address(0)) revert NoStrategySet();
        if (lastHarvestBlock != 0 && block.number < lastHarvestBlock + MIN_HARVEST_INTERVAL) {
            revert HarvestTooFrequent();
        }
        lastHarvestBlock = block.number;
        harvested = activeStrategy.harvestYield();
        uint256 idle = IERC20(depositToken).balanceOf(address(this));
        if (idle > 0) {
            IERC20(depositToken).forceApprove(address(activeStrategy), idle);
            activeStrategy.deposit(idle);
        }
        emit Harvested(harvested);
    }

    /**
     * @notice Owner can update the switch delay (min 1 hour, max 7 days).
     */
    function setSwitchDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= 1 hours && newDelay <= 7 days, "PVAdapter: delay out of range");
        uint256 old = switchDelay;
        switchDelay = newDelay;
        emit SwitchDelayUpdated(old, newDelay);
    }

    // ─── APY view helper (for UI / keeper) ───────────────────────────────────

    /**
     * @notice Current strategy APY in basis points.
     */
    function getCurrentAPY() external view returns (uint256) {
        return address(activeStrategy) != address(0) ? activeStrategy.getEstimatedAPY() : 0;
    }

    /**
     * @notice Human-readable name of the active strategy.
     */
    function activeStrategyName() external view returns (string memory) {
        return address(activeStrategy) != address(0) ? activeStrategy.strategyName() : "none";
    }

    // ─── Internal share math ─────────────────────────────────────────────────

    function _totalAssets() internal view returns (uint256) {
        uint256 strategyValue = address(activeStrategy) != address(0)
            ? activeStrategy.getTotalValue()
            : 0;
        // Include idle tokens not yet deposited into the strategy (post-harvest, pre-reinvest)
        uint256 idle = IERC20(depositToken).balanceOf(address(this));
        return strategyValue + idle;
    }

    function _toShares(uint256 assets, uint256 totalAssets) internal view returns (uint256) {
        // EIP-4626 with virtual offsets: shares = assets * (totalShares + VIRTUAL) / (totalAssets + VIRTUAL)
        return (assets * (totalShares + VIRTUAL_SHARES)) / (totalAssets + VIRTUAL_ASSETS);
    }

    function _toAssets(uint256 shares, uint256 totalAssets) internal view returns (uint256) {
        return (shares * (totalAssets + VIRTUAL_ASSETS)) / (totalShares + VIRTUAL_SHARES);
    }
}
