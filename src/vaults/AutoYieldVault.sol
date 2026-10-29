// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IAutoYieldStrategy.sol";

/**
 * @title AutoYieldVault
 * @notice Platform-managed ERC-4626-style single-asset vault.
 *
 * One deploy per token (USDC, USDT, DAI).
 *
 * Security features:
 *   - Virtual shares/assets offset (OZ 5.x pattern) prevents first-depositor inflation attack
 *   - Same-block deposit-withdraw prevention mitigates flash loan manipulation
 *   - All rounding favors the vault (Solidity integer division rounds down)
 *
 * Share formula (with virtual offset):
 *   sharesIssued = deposit * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
 *   assetsOut    = sharesToBurn * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
 */
contract AutoYieldVault is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Minimum tokens required for the very first deposit (additional safety measure).
    uint256 public constant MINIMUM_FIRST_DEPOSIT = 1_000;

    /// @notice Virtual shares offset for first-depositor inflation attack protection.
    /// @dev Together with _VIRTUAL_ASSETS, creates a floor share price that prevents
    ///      an attacker from inflating the share price via donation to steal from subsequent depositors.
    ///      Pattern from OpenZeppelin ERC4626 5.x.
    uint256 private constant _VIRTUAL_SHARES = 1e6;

    /// @notice Virtual assets offset for first-depositor inflation attack protection.
    uint256 private constant _VIRTUAL_ASSETS = 1;

    // ─── State ────────────────────────────────────────────────────────────────

    IERC20 public immutable asset;
    string public tokenSymbol;

    /// @notice Optional operator (e.g. YieldOptimizer) allowed to call switchStrategy
    address public operator;

    /// @notice Guardian address that can trigger emergency pause (but not unpause).
    address public guardian;

    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Internal tracking of idle assets held in the vault (not deployed to strategy).
    /// @dev Prevents donation attacks — we never use balanceOf(address(this)) in accounting.
    uint256 public idleAssets;

    /// @notice Tracks deposit block for flash loan / same-block deposit-withdraw prevention.
    mapping(address => uint256) public depositBlock;

    /// @notice Tracks deposit timestamp for L2 flash loan protection (same-block bypass).
    mapping(address => uint256) public depositTimestamp;

    /// @notice Minimum hold time in seconds (prevents same-timestamp bypass on L2)
    uint256 public constant MIN_HOLD_TIME = 15;

    /// @notice ERC-4626-style share accounting.
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    // ─── Fees (default 0 — opt-in by owner) ───────────────────────────────────
    //
    // Single fee lever: a performance fee on accrued yield. Charged via fee-share
    // *minting* — the recipient is granted vault shares equal in value to the fee.
    // This preserves the OZ 5.x first-depositor-attack invariants because the
    // share-price formula (totalAssets / totalShares) sees the fee dilute pro-rata
    // across holders instead of being skimmed off totalAssets directly.
    //
    //   performanceFee — % of yield generated since the last fee anchor, in bps.
    //
    // No management fee. The platform promise is "fees only on accrued yield" —
    // an annualized AUM fee would erode principal in flat-yield periods, so it
    // is intentionally absent from this contract.
    //
    // A configurable minimum-yield threshold (`minFeeYieldAssets`) prevents
    // billing dust: if cumulative un-charged yield since the last successful
    // accrual is below this floor, no fee is minted and `lastFeeAssets` is NOT
    // advanced — yield keeps accumulating against the same anchor until it
    // crosses the floor.
    //
    // The accrual function is callable by anyone (it only mints to feeRecipient)
    // and is automatically invoked from deposit/withdraw/harvestYield so a
    // mid-transaction share price always reflects the latest accrued fees.

    /// @notice Hard cap on performance fee — 10% of yield.
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 1000; // 10%
    /// @notice Hard cap on the dust-floor setter ($1,000 in 6-decimal token units).
    /// @dev Bounds the owner from silently disabling fees by setting an absurd floor.
    uint256 public constant MAX_MIN_FEE_YIELD_ASSETS = 1_000_000_000; // 1,000 × 10^6
    /// @notice BPS denominator.
    uint256 internal constant FEE_BPS_DENOMINATOR = 10_000;

    /// @notice Performance fee in bps. 0 = disabled.
    uint256 public performanceFeeBps;
    /// @notice Recipient of fee shares. Zero-address disables fee minting (safety).
    address public feeRecipient;
    /// @notice Last totalAssets anchor at the moment fees were last successfully
    ///         accrued. Performance fee charges `(currentAssets - lastFeeAssets)`
    ///         when that delta crosses `minFeeYieldAssets`.
    uint256 public lastFeeAssets;
    /// @notice Minimum un-charged yield (in asset units) required to mint fee
    ///         shares. Below this floor, accruals are no-ops and the anchor is
    ///         NOT advanced — yield accumulates until the floor is reached.
    ///         Owner-settable up to MAX_MIN_FEE_YIELD_ASSETS.
    uint256 public minFeeYieldAssets;

    event PerformanceFeeUpdated(uint256 newBps);
    event MinFeeYieldAssetsUpdated(uint256 oldValue, uint256 newValue);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    /// @dev `feeAssets` is the USDC-equivalent value of the performance fee at
    ///      the moment of accrual. Exposing it saves downstream indexers an
    ///      extra `previewRedeem` round-trip when wiring affiliate/analytics.
    event FeesAccrued(uint256 performanceShares, uint256 feeAssets, uint256 newTotalAssets);

    error FeeTooHigh();
    error InvalidRecipient();
    error MinFeeYieldTooHigh();

    struct StrategyInfo {
        IAutoYieldStrategy strategy;
        string name;
        bool   isActive;
    }

    StrategyInfo[] public availableStrategies;
    uint256 public  activeStrategyIndex;

    /// @notice Delay before a queued strategy switch can be executed (24 hours)
    uint256 public constant STRATEGY_SWITCH_DELAY = 24 hours;

    /// @notice Pending strategy switch index (0 means no pending switch when pendingSwitchTimestamp == 0)
    uint256 public pendingSwitchIndex;
    /// @notice Timestamp after which the pending switch can be executed (0 = no pending switch)
    uint256 public pendingSwitchTimestamp;

    // ─── Events ───────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 assets, uint256 sharesIssued);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 assetsReturned);
    event YieldHarvested(uint256 harvested, uint256 newTotalAssets);
    event StrategyAdded(uint256 indexed index, address strategy, string name);
    event StrategySwitched(uint256 fromIndex, uint256 toIndex, uint256 fundsMigrated);
    event OperatorUpdated(address indexed newOperator);
    event StrategyChangeQueued(uint256 toIndex, uint256 executeAfter);
    event StrategyChangeCancelled(uint256 toIndex);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientShares();
    error InvalidStrategyIndex();
    error StrategyAlreadyActive();
    error NoStrategyConfigured();
    error SameBlockWithdraw();
    error BelowMinimumDeposit();
    error ZeroShares();
    error InvalidAsset();
    error InvalidStrategy();
    error NotAuthorized();
    error StrategyChangeNotReady();
    error NoStrategyChangeQueued();
    error StrategyAddTooSoon();
    error TooManyStrategies();
    error FeeRecipientAlreadySet();

    // ─── Strategy-add throttle ────────────────────────────────────────────────
    //
    // A compromised owner could otherwise add an arbitrary strategy and
    // queue-switch to it (24h delay + 1% slippage cap mitigate but do not
    // eliminate the risk). The throttle gives the community a long window to
    // detect a malicious addition before the operator can switch to it.
    //
    // - BOOTSTRAP_WINDOW: grace period after deploy where adds are unrestricted.
    //                    Lets the deployer wire Aave + Compound + Morpho without
    //                    waiting weeks. After it expires, MIN_STRATEGY_ADD_INTERVAL
    //                    enforces one add per 14 days.
    // - MAX_STRATEGIES:  hard cap so a compromised owner cannot proliferate.
    uint256 public constant BOOTSTRAP_WINDOW = 7 days;
    uint256 public constant MIN_STRATEGY_ADD_INTERVAL = 14 days;
    uint256 public constant MAX_STRATEGIES = 5;

    /// @notice Timestamp after which the bootstrap window closes and the
    ///         per-add cooldown begins to apply.
    uint256 public immutable bootstrapEndTime;

    /// @notice Last time addStrategy succeeded; gate for the cooldown.
    uint256 public lastStrategyAddTime;

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _asset, string memory _tokenSymbol) Ownable() {
        if (_asset == address(0)) revert InvalidAsset();
        asset       = IERC20(_asset);
        tokenSymbol = _tokenSymbol;
        bootstrapEndTime = block.timestamp + BOOTSTRAP_WINDOW;

        // Safe-by-default fee surface, so a deploy that forgets to call the
        // setters is still "platform-correct" the moment `setFeeRecipient`
        // wires a treasury. Owners can override either via the (capped)
        // setters below.
        //
        // - performanceFeeBps = 200 (2% of accrued yield) — matches the
        //   platform-wide promise. Capped at MAX_PERFORMANCE_FEE_BPS = 1000.
        // - minFeeYieldAssets = 100_000 raw = $0.10 in 6-decimal token
        //   units (USDC/USDT). Deployers using 18-decimal assets (DAI etc.)
        //   should override with `setMinFeeYieldAssets()`. Passing 0
        //   disables the threshold and bills every accrued sat.
        performanceFeeBps = 200;
        minFeeYieldAssets = 100_000;
    }

    // ─── User: Deposit ────────────────────────────────────────────────────────

    /**
     * @notice Deposit tokens and receive vault shares.
     * @param amount Amount of underlying tokens (in token's native decimals).
     * @return sharesIssued Number of shares minted to caller.
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 sharesIssued) {
        if (amount == 0) revert ZeroAmount();
        if (availableStrategies.length == 0) revert NoStrategyConfigured();

        // Accrue fees against the current totalAssets BEFORE the share-price calculation,
        // so the new depositor doesn't dilute the fee owed to existing holders.
        _accrueFees();

        // Enforce minimum on first deposit for additional safety
        if (totalShares == 0 && amount < MINIMUM_FIRST_DEPOSIT) revert BelowMinimumDeposit();

        // Snapshot total assets BEFORE transfer to avoid inflating share calculation
        uint256 _totalAssets = totalAssets();

        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Virtual offset prevents ERC-4626 first-depositor inflation attack (OZ 5.x pattern).
        // Rounding direction: down (fewer shares issued = favors vault).
        sharesIssued = (amount * (totalShares + _VIRTUAL_SHARES)) / (_totalAssets + _VIRTUAL_ASSETS);
        if (sharesIssued == 0) revert ZeroShares();

        shares[msg.sender] += sharesIssued;
        totalShares        += sharesIssued;

        // Track deposit block and timestamp for flash loan protection
        depositBlock[msg.sender] = block.number;
        depositTimestamp[msg.sender] = block.timestamp;

        // Forward to active strategy
        IAutoYieldStrategy strategy = _activeStrategy();
        asset.forceApprove(address(strategy), amount);
        strategy.deposit(amount);

        // Re-anchor the fee high-water mark by adding the deposit's principal.
        // We deliberately do NOT do `lastFeeAssets = totalAssets()` here —
        // that would erase any below-threshold yield that has accumulated but
        // not yet been charged (because cumulative yield < minFeeYieldAssets).
        // Adding `amount` 1:1 keeps un-charged yield intact for the next
        // accrual, while preventing the just-deposited principal from being
        // billed as yield (the original bug fixed in this iteration).
        if (feeRecipient != address(0) && performanceFeeBps != 0) {
            lastFeeAssets += amount;
        }

        emit Deposited(msg.sender, amount, sharesIssued);
    }

    // ─── User: Withdraw ───────────────────────────────────────────────────────

    /**
     * @notice Burn shares to receive proportional underlying assets (principal + accrued yield).
     * @param sharesToBurn Number of shares to redeem.
     * @return assetsReturned Amount of underlying tokens sent to caller.
     */
    function withdraw(uint256 sharesToBurn) external nonReentrant returns (uint256 assetsReturned) {
        if (sharesToBurn == 0)                  revert ZeroAmount();
        if (shares[msg.sender] < sharesToBurn)  revert InsufficientShares();
        if (depositBlock[msg.sender] >= block.number) revert SameBlockWithdraw();

        // Accrue fees so the withdrawing user pays their share before exiting.
        _accrueFees();
        require(
            block.timestamp >= depositTimestamp[msg.sender] + MIN_HOLD_TIME,
            "AutoYieldVault: minimum hold time not met"
        );

        // Snapshot pre-withdraw totalAssets so we can scale lastFeeAssets at
        // the end of the call. Captured after _accrueFees so any fee shares
        // already minted in this transaction are reflected in totalShares.
        uint256 totalAssetsBefore = totalAssets();

        // Rounding direction: down (fewer assets returned = favors vault).
        assetsReturned = (sharesToBurn * (totalAssetsBefore + _VIRTUAL_ASSETS)) / (totalShares + _VIRTUAL_SHARES);

        shares[msg.sender] -= sharesToBurn;
        totalShares        -= sharesToBurn;

        // First consume idle assets (harvested yield sitting in the vault),
        // then pull the remainder from the active strategy.
        uint256 fromIdle = assetsReturned < idleAssets ? assetsReturned : idleAssets;
        if (fromIdle > 0) {
            idleAssets -= fromIdle;
        }
        uint256 fromStrategy = assetsReturned - fromIdle;
        if (fromStrategy > 0) {
            IAutoYieldStrategy strategy = _activeStrategy();
            uint256 actualOut = strategy.withdrawAmount(fromStrategy);
            // Use actual amount returned by strategy (may differ slightly due to rounding)
            if (actualOut < fromStrategy) {
                assetsReturned = fromIdle + actualOut;
            }
        }

        // Transfer assets to user
        asset.safeTransfer(msg.sender, assetsReturned);

        // Re-anchor the fee high-water mark proportionally to the share of
        // assets that remain. We deliberately do NOT do `lastFeeAssets =
        // totalAssets()` here — that would erase below-threshold un-charged
        // yield. Scaling preserves it in proportion to the assets still under
        // management; the withdrawing user takes their share of un-charged
        // yield with them (it stays inside `assetsReturned`).
        if (feeRecipient != address(0) && performanceFeeBps != 0 && totalAssetsBefore > 0) {
            lastFeeAssets = (lastFeeAssets * totalAssets()) / totalAssetsBefore;
        }

        emit Withdrawn(msg.sender, sharesToBurn, assetsReturned);
    }

    // ─── Yield ────────────────────────────────────────────────────────────────

    /**
     * @notice Harvest accumulated yield from the active strategy.
     *         Anyone can call; yield appreciation increases value of all shares.
     * @return harvested Amount of yield collected.
     */
    function harvestYield() external nonReentrant returns (uint256 harvested) {
        require(msg.sender == owner() || msg.sender == operator, "AutoYieldVault: not authorized");
        IAutoYieldStrategy strategy = _activeStrategy();
        harvested = strategy.harvestYield();
        // Track harvested yield arriving at the vault
        idleAssets += harvested;
        // Accrue platform fees against the new (higher) totalAssets snapshot
        _accrueFees();
        emit YieldHarvested(harvested, totalAssets());
    }

    /**
     * @notice Accrue the performance fee by minting fee shares to feeRecipient.
     *
     * Performance fee: charged on `currentAssets - lastFeeAssets` (the cumulative
     * un-charged yield since the last successful accrual). Two short-circuits:
     *   - Fee config disabled / no recipient / no depositors → no-op, anchor
     *     follows totalAssets so a future fee turn-on doesn't backfill history.
     *   - Cumulative yield below `minFeeYieldAssets` → no-op AND anchor is
     *     NOT advanced. Yield keeps accruing against the same anchor until
     *     it crosses the floor. Prevents dust-fee minting on micro-yields.
     *
     * Fees are minted as new shares (NOT transferred from assets), so the
     * share-price formula sees only dilution — the OZ 5.x first-depositor
     * invariants remain intact.
     *
     * Anyone may call this externally; in practice it is invoked from inside
     * deposit/withdraw/harvest so users always interact with fresh accounting.
     */
    function accrueFees() external nonReentrant {
        _accrueFees();
    }

    function _accrueFees() internal {
        // Skip entirely when fees are off, no recipient, or no depositors yet.
        // Anchor still tracks totalAssets so a future turn-on doesn't backfill.
        if (performanceFeeBps == 0 || feeRecipient == address(0) || totalShares == 0) {
            lastFeeAssets = totalAssets();
            return;
        }

        uint256 currentAssets = totalAssets();

        // No yield since last anchor → nothing to charge.
        if (currentAssets <= lastFeeAssets) return;

        uint256 yieldDelta = currentAssets - lastFeeAssets;

        // Below the dust floor: do not charge, do not advance the anchor.
        // The yield accumulates across calls until the cumulative delta
        // crosses minFeeYieldAssets, at which point the full delta is charged.
        if (yieldDelta < minFeeYieldAssets) return;

        uint256 perfFeeAssets = (yieldDelta * performanceFeeBps) / FEE_BPS_DENOMINATOR;
        // Defensive clamp: a regression in watermark tracking can't bill more
        // than the actual yield delta. Cheap, single-comparison guard.
        if (perfFeeAssets > yieldDelta) perfFeeAssets = yieldDelta;

        uint256 perfFeeShares = _convertAssetsToShares(perfFeeAssets, currentAssets);
        if (perfFeeShares > 0) {
            shares[feeRecipient] += perfFeeShares;
            totalShares          += perfFeeShares;
            // Fee shares inherit the same MIN_HOLD_TIME guard as user shares
            // via the depositBlock/depositTimestamp paths in withdraw(); we
            // intentionally do NOT touch those for the recipient because the
            // treasury is expected to call withdraw() infrequently and on its
            // own schedule.
            emit FeesAccrued(perfFeeShares, perfFeeAssets, currentAssets);
        }

        lastFeeAssets = currentAssets;
    }

    /// @dev Internal share conversion using the current totalAssets snapshot (not totalAssets()).
    function _convertAssetsToShares(uint256 assets, uint256 currentAssets) internal view returns (uint256) {
        if (assets == 0) return 0;
        // Same formula as deposit(), uses the same virtual offsets for invariant preservation.
        return (assets * (totalShares + _VIRTUAL_SHARES)) / (currentAssets + _VIRTUAL_ASSETS);
    }

    // ─── Owner: Fee Configuration ─────────────────────────────────────────────

    /**
     * @notice Set the performance fee in bps. Capped at MAX_PERFORMANCE_FEE_BPS (10%).
     * @dev Accrues outstanding fees at the OLD rate first to avoid retroactive application.
     */
    function setPerformanceFee(uint256 newBps) external onlyOwner {
        if (newBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        _accrueFees();
        performanceFeeBps = newBps;
        emit PerformanceFeeUpdated(newBps);
    }

    /**
     * @notice Set the minimum un-charged-yield floor before any performance
     *         fee is minted. Below this floor, accruals are no-ops AND the
     *         watermark is NOT advanced — yield keeps accumulating until it
     *         crosses the floor.
     * @dev Capped at MAX_MIN_FEE_YIELD_ASSETS so a compromised owner cannot
     *      silently disable fees by setting an absurd floor. Accrues at the
     *      OLD floor first so a raise doesn't retroactively let dust yield
     *      sneak through, and a lowering doesn't retroactively trigger fees
     *      on yield that was below the previous floor.
     */
    function setMinFeeYieldAssets(uint256 newFloor) external onlyOwner {
        if (newFloor > MAX_MIN_FEE_YIELD_ASSETS) revert MinFeeYieldTooHigh();
        _accrueFees();
        uint256 old = minFeeYieldAssets;
        minFeeYieldAssets = newFloor;
        emit MinFeeYieldAssetsUpdated(old, newFloor);
    }

    /**
     * @notice Set the fee recipient. **Set-once only** — once a non-zero
     *         recipient is wired, it cannot be changed. A compromised owner
     *         therefore cannot redirect fees mid-flight. To rotate the
     *         recipient, deploy a new vault.
     * @dev Setting `newRecipient = address(0)` would silently disable fees
     *      and is rejected to keep the once-set semantic clear.
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (feeRecipient != address(0)) revert FeeRecipientAlreadySet();
        if (newRecipient == address(0)) revert InvalidRecipient();
        emit FeeRecipientUpdated(address(0), newRecipient);
        feeRecipient = newRecipient;
        // Anchor the fee watermark at the current totalAssets so we don't
        // retroactively bill historical yield as fees on first accrual.
        lastFeeAssets = totalAssets();
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Number of registered strategies.
    function strategyCount() external view returns (uint256) {
        return availableStrategies.length;
    }

    /// @notice APY (basis points) for every registered strategy (0 on revert).
    function getStrategyAPYs() external view returns (uint256[] memory apys) {
        uint256 len = availableStrategies.length;
        apys = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            try availableStrategies[i].strategy.getEstimatedAPY() returns (uint256 apy) {
                apys[i] = apy;
            } catch {
                apys[i] = 0;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Index and APY of the strategy with the highest estimated APY.
    function getBestStrategyIndex() external view returns (uint256 bestIndex, uint256 bestAPY) {
        uint256 len = availableStrategies.length;
        for (uint256 i = 0; i < len;) {
            uint256 apy;
            try availableStrategies[i].strategy.getEstimatedAPY() returns (uint256 a) {
                apy = a;
            } catch {}
            if (apy > bestAPY) {
                bestAPY   = apy;
                bestIndex = i;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Total assets under management (principal + yield).
    /// @dev Uses internal idleAssets tracking instead of balanceOf to prevent donation attacks.
    function totalAssets() public view returns (uint256) {
        if (availableStrategies.length == 0) return 0;
        return _activeStrategy().getTotalValue() + idleAssets;
    }

    /// @notice Preview how many tokens `sharesToBurn` redeems for.
    function previewRedeem(uint256 sharesToBurn) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesToBurn * (totalAssets() + _VIRTUAL_ASSETS)) / (totalShares + _VIRTUAL_SHARES);
    }

    /// @notice Current APY from active strategy in basis points (100 = 1%).
    function getCurrentAPY() external view returns (uint256) {
        if (availableStrategies.length == 0) return 0;
        return _activeStrategy().getEstimatedAPY();
    }

    /// @notice Get a user's shares and their current asset value.
    function getUserInfo(address user)
        external view
        returns (uint256 userShares, uint256 userAssets_)
    {
        userShares  = shares[user];
        userAssets_ = totalShares == 0 ? 0 : (userShares * (totalAssets() + _VIRTUAL_ASSETS)) / (totalShares + _VIRTUAL_SHARES);
    }

    // ─── Owner: Strategy Management ───────────────────────────────────────────

    /**
     * @notice Register a new yield strategy.
     * @param strategyAddress Address of the strategy contract (must implement IAutoYieldStrategy).
     * @param name            Human-readable name, e.g. "Aave V3".
     */
    function addStrategy(address strategyAddress, string calldata name) external onlyOwner {
        if (strategyAddress == address(0)) revert InvalidStrategy();
        uint256 index = availableStrategies.length;
        if (index >= MAX_STRATEGIES) revert TooManyStrategies();
        // Enforce add-cooldown only after the bootstrap window. Within the
        // window the deployer can wire all initial strategies in one session;
        // after, each add costs 14 days of community visibility before the
        // next can land.
        if (block.timestamp >= bootstrapEndTime
            && lastStrategyAddTime != 0
            && block.timestamp < lastStrategyAddTime + MIN_STRATEGY_ADD_INTERVAL) {
            revert StrategyAddTooSoon();
        }
        lastStrategyAddTime = block.timestamp;
        availableStrategies.push(StrategyInfo({
            strategy: IAutoYieldStrategy(strategyAddress),
            name:     name,
            isActive: index == 0 // first strategy is auto-activated
        }));
        emit StrategyAdded(index, strategyAddress, name);
    }

    /**
     * @notice Set the operator address (e.g. YieldOptimizer).
     *         The operator can call switchStrategy in addition to the owner.
     */
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    /**
     * @notice Queue a strategy switch. Must wait STRATEGY_SWITCH_DELAY before executing.
     * @param newIndex Index in availableStrategies.
     */
    function queueStrategySwitchTo(uint256 newIndex) external {
        if (msg.sender != owner() && msg.sender != operator) revert NotAuthorized();
        if (newIndex >= availableStrategies.length) revert InvalidStrategyIndex();
        if (newIndex == activeStrategyIndex)        revert StrategyAlreadyActive();

        uint256 executeAfter = block.timestamp + STRATEGY_SWITCH_DELAY;
        pendingSwitchIndex = newIndex;
        pendingSwitchTimestamp = executeAfter;

        emit StrategyChangeQueued(newIndex, executeAfter);
    }

    /**
     * @notice Cancel a pending strategy switch.
     */
    function cancelStrategySwitchQueue() external {
        if (msg.sender != owner() && msg.sender != operator) revert NotAuthorized();
        if (pendingSwitchTimestamp == 0) revert NoStrategyChangeQueued();

        uint256 cancelledIndex = pendingSwitchIndex;
        pendingSwitchIndex = 0;
        pendingSwitchTimestamp = 0;

        emit StrategyChangeCancelled(cancelledIndex);
    }

    /**
     * @notice Execute a previously queued strategy switch after the delay has elapsed.
     *         Migrates ALL funds atomically.
     */
    /// @dev Maximum allowed loss during strategy switch (1% in basis points)
    uint256 private constant MAX_SWITCH_SLIPPAGE_BPS = 100;

    function switchStrategy(uint256 newIndex) external nonReentrant {
        if (msg.sender != owner() && msg.sender != operator) revert NotAuthorized();
        if (newIndex >= availableStrategies.length) revert InvalidStrategyIndex();
        if (newIndex == activeStrategyIndex)        revert StrategyAlreadyActive();

        // Enforce timelock: must match queued switch and delay must have elapsed
        if (pendingSwitchTimestamp == 0 || pendingSwitchIndex != newIndex) revert NoStrategyChangeQueued();
        if (block.timestamp < pendingSwitchTimestamp) revert StrategyChangeNotReady();

        // Clear pending switch
        pendingSwitchIndex = 0;
        pendingSwitchTimestamp = 0;

        uint256 oldIndex = activeStrategyIndex;
        IAutoYieldStrategy oldStrategy = availableStrategies[oldIndex].strategy;
        IAutoYieldStrategy newStrategy = availableStrategies[newIndex].strategy;

        // Withdraw ALL funds from old strategy using its total value
        uint256 strategyValue = oldStrategy.getTotalValue();
        uint256 fundsReceived;
        if (strategyValue > 0) {
            fundsReceived = oldStrategy.withdrawAmount(strategyValue);
        }

        // Slippage protection: revert if strategy returned significantly less than expected
        if (strategyValue > 0) {
            uint256 minExpected = strategyValue * (10_000 - MAX_SWITCH_SLIPPAGE_BPS) / 10_000;
            require(fundsReceived >= minExpected, "AutoYieldVault: switch slippage too high");
        }

        // Recover dust: if old strategy still has remaining value, withdraw all remaining
        uint256 remainingValue = oldStrategy.getTotalValue();
        if (remainingValue > 0) {
            uint256 dustRecovered = oldStrategy.withdrawAmount(remainingValue);
            fundsReceived += dustRecovered;
        }

        // Include idle assets (harvested yield sitting in the vault) in the migration
        uint256 totalToDeposit = fundsReceived + idleAssets;

        // Deposit all into new strategy (only zero idleAssets after confirming success)
        if (totalToDeposit > 0) {
            asset.forceApprove(address(newStrategy), totalToDeposit);
            newStrategy.deposit(totalToDeposit);
        }
        // Zero idleAssets only after successful deposit to new strategy
        idleAssets = 0;

        availableStrategies[oldIndex].isActive = false;
        availableStrategies[newIndex].isActive = true;
        activeStrategyIndex = newIndex;

        emit StrategySwitched(oldIndex, newIndex, totalToDeposit);
    }

    function setGuardian(address _guardian) external onlyOwner {
        emit GuardianUpdated(guardian, _guardian);
        guardian = _guardian;
    }

    function pause() external {
        require(msg.sender == owner() || msg.sender == guardian, "Not authorized");
        _pause();
    }

    function unpause() external onlyOwner { _unpause(); }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _activeStrategy() internal view returns (IAutoYieldStrategy) {
        if (availableStrategies.length == 0) revert NoStrategyConfigured();
        return availableStrategies[activeStrategyIndex].strategy;
    }
}
