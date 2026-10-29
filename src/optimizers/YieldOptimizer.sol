// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../vaults/AutoYieldVault.sol";
import "../strategies/BaseStrategy.sol";

/**
 * @title YieldOptimizer
 * @notice Full-lifecycle UUPS-upgradeable automation keeper for AutoYieldVault instances.
 *
 * Three automated actions (checked in priority order):
 *   1. EXECUTE_SWITCH — finalize a pending strategy switch whose timelock has elapsed
 *   2. HARVEST        — collect accumulated yield when it exceeds minHarvestAmount
 *   3. QUEUE_SWITCH   — queue a switch to a better-yielding strategy
 *
 * Compatible with Chainlink Automation (Keeper network):
 *   - checkUpkeep()  → off-chain view; returns the highest-priority action needed
 *   - performUpkeep() → on-chain; dispatches to the appropriate handler
 *
 * Can also be triggered manually via triggerSwitch(), executeSwitch(), or manualHarvest().
 *
 * Security:
 *   - performUpkeep() validates vault membership and re-checks all conditions on-chain
 *   - executeSwitch() restricted to owner only
 *   - UUPS pattern allows logic upgrades while preserving proxy address (important for Chainlink upkeep)
 */
contract YieldOptimizer is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum ActionType { NONE, QUEUE_SWITCH, EXECUTE_SWITCH, HARVEST }

    // ─── State ────────────────────────────────────────────────────────────────
    // NOTE: Storage layout is append-only for UUPS upgradeability.
    //       Never reorder or remove existing variables. Only add new ones at the end.

    /// @notice Minimum APY improvement (bps) required to trigger a switch
    uint256 public switchThresholdBps;

    /// @notice Minimum time between successive strategy switches per vault
    uint256 public minSwitchInterval;

    /// @notice Minimum harvestable yield (in underlying token decimals) to justify a harvest
    uint256 public minHarvestAmount;

    /// @notice Vault addresses managed by this optimizer
    address[] public managedVaults;

    /// @notice Timestamp of the last completed strategy switch per vault
    mapping(address => uint256) public lastSwitchTime;

    /// @notice Fast lookup for managed vault membership (audit fix H-2, M-1)
    mapping(address => bool) public isManagedVault;

    // ─── Events ───────────────────────────────────────────────────────────────

    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event SwitchQueued(address indexed vault, uint256 fromIndex, uint256 toIndex, uint256 gainBps);
    event SwitchExecuted(address indexed vault, uint256 fromIndex, uint256 toIndex);
    event SwitchCancelled(address indexed vault);
    event HarvestTriggered(address indexed vault, uint256 harvested);
    event ThresholdUpdated(uint256 newThresholdBps);
    event MinSwitchIntervalUpdated(uint256 newInterval);
    event MinHarvestAmountUpdated(uint256 newAmount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidVault();
    error InvalidIndex();
    error ConditionsNotMet();
    error VaultAlreadyManaged();
    error VaultNotManaged();

    // ─── Initializer (replaces constructor for UUPS) ─────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the optimizer (called once via proxy).
     * @param _switchThresholdBps Min APY improvement in bps (default: 50 = 0.5%)
     * @param _minSwitchInterval  Cooldown between switches (default: 7 days)
     * @param _minHarvestAmount   Min yield to harvest in token decimals (default: 10e6)
     */
    function initialize(
        uint256 _switchThresholdBps,
        uint256 _minSwitchInterval,
        uint256 _minHarvestAmount
    ) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        switchThresholdBps = _switchThresholdBps;
        minSwitchInterval  = _minSwitchInterval;
        minHarvestAmount   = _minHarvestAmount;
    }

    // ─── UUPS authorization ──────────────────────────────────────────────────

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ─── Admin ────────────────────────────────────────────────────────────────

    function addVault(address vault) external onlyOwner {
        if (vault == address(0)) revert InvalidVault();
        if (isManagedVault[vault]) revert VaultAlreadyManaged();
        managedVaults.push(vault);
        isManagedVault[vault] = true;
        emit VaultAdded(vault);
    }

    function removeVault(uint256 index) external onlyOwner {
        if (index >= managedVaults.length) revert InvalidIndex();
        address removed = managedVaults[index];
        isManagedVault[removed] = false;
        managedVaults[index] = managedVaults[managedVaults.length - 1];
        managedVaults.pop();
        emit VaultRemoved(removed);
    }

    function setSwitchThreshold(uint256 bps) external onlyOwner {
        switchThresholdBps = bps;
        emit ThresholdUpdated(bps);
    }

    function setMinSwitchInterval(uint256 interval) external onlyOwner {
        minSwitchInterval = interval;
        emit MinSwitchIntervalUpdated(interval);
    }

    function setMinHarvestAmount(uint256 amount) external onlyOwner {
        minHarvestAmount = amount;
        emit MinHarvestAmountUpdated(amount);
    }

    function managedVaultCount() external view returns (uint256) {
        return managedVaults.length;
    }

    // ─── Chainlink Automation ─────────────────────────────────────────────────

    /**
     * @notice Called off-chain by Chainlink Automation nodes.
     *         Checks all managed vaults for actionable conditions in priority order:
     *         1. EXECUTE_SWITCH — pending switch with elapsed timelock
     *         2. HARVEST — accumulated yield above threshold
     *         3. QUEUE_SWITCH — better strategy available (with cooldown)
     *
     * @return upkeepNeeded True when any action should be performed.
     * @return performData  ABI-encoded (ActionType, vaultAddress, strategyIndex).
     */
    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 len = managedVaults.length;

        // Priority 1: Execute pending switches that have passed their timelock
        for (uint256 i = 0; i < len;) {
            AutoYieldVault vault = AutoYieldVault(managedVaults[i]);
            uint256 pendingTs = vault.pendingSwitchTimestamp();

            if (pendingTs > 0 && block.timestamp >= pendingTs) {
                uint256 pendingIdx = vault.pendingSwitchIndex();
                return (true, abi.encode(ActionType.EXECUTE_SWITCH, managedVaults[i], pendingIdx));
            }
            unchecked { ++i; }
        }

        // Priority 2: Harvest yield when accumulated amount exceeds threshold
        for (uint256 i = 0; i < len;) {
            AutoYieldVault vault = AutoYieldVault(managedVaults[i]);
            uint256 harvestable = _getHarvestableYield(vault);

            if (harvestable >= minHarvestAmount) {
                return (true, abi.encode(ActionType.HARVEST, managedVaults[i], uint256(0)));
            }
            unchecked { ++i; }
        }

        // Priority 3: Queue strategy switch if better option available
        for (uint256 i = 0; i < len;) {
            address vaultAddr = managedVaults[i];
            AutoYieldVault vault = AutoYieldVault(vaultAddr);

            // Skip if there's already a pending switch
            if (vault.pendingSwitchTimestamp() != 0) {
                unchecked { ++i; }
                continue;
            }

            // Skip if cooldown hasn't elapsed (only applies after first switch)
            if (lastSwitchTime[vaultAddr] > 0 && block.timestamp < lastSwitchTime[vaultAddr] + minSwitchInterval) {
                unchecked { ++i; }
                continue;
            }

            uint256 currentAPY = vault.getCurrentAPY();
            (uint256 bestIndex, uint256 bestAPY) = vault.getBestStrategyIndex();

            if (
                bestIndex != vault.activeStrategyIndex() &&
                bestAPY >= currentAPY + switchThresholdBps
            ) {
                return (true, abi.encode(ActionType.QUEUE_SWITCH, vaultAddr, bestIndex));
            }
            unchecked { ++i; }
        }

        return (false, "");
    }

    /**
     * @notice Called on-chain by Chainlink Automation when checkUpkeep returns true.
     *         Dispatches to the appropriate handler based on action type.
     * @param performData ABI-encoded (ActionType, vaultAddress, strategyIndex).
     */
    function performUpkeep(bytes calldata performData) external {
        (ActionType action, address vaultAddr, uint256 param) =
            abi.decode(performData, (ActionType, address, uint256));

        // Audit fix H-2: validate vault is managed
        if (!isManagedVault[vaultAddr]) revert VaultNotManaged();

        if (action == ActionType.EXECUTE_SWITCH) {
            _executeSwitch(vaultAddr, param);
        } else if (action == ActionType.HARVEST) {
            _harvestVault(vaultAddr);
        } else if (action == ActionType.QUEUE_SWITCH) {
            _queueSwitch(vaultAddr, param);
        } else {
            revert ConditionsNotMet();
        }
    }

    // ─── Internal handlers ────────────────────────────────────────────────────

    function _executeSwitch(address vaultAddr, uint256 newIndex) internal {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);

        // Re-validate on-chain: pending switch must still exist and timelock must have elapsed
        uint256 pendingTs = vault.pendingSwitchTimestamp();
        if (pendingTs == 0 || block.timestamp < pendingTs) revert ConditionsNotMet();
        if (vault.pendingSwitchIndex() != newIndex) revert ConditionsNotMet();

        uint256 fromIndex = vault.activeStrategyIndex();
        vault.switchStrategy(newIndex);
        lastSwitchTime[vaultAddr] = block.timestamp;

        emit SwitchExecuted(vaultAddr, fromIndex, newIndex);
    }

    function _harvestVault(address vaultAddr) internal {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);

        // Re-validate: yield must still exceed threshold
        uint256 harvestable = _getHarvestableYield(vault);
        if (harvestable < minHarvestAmount) revert ConditionsNotMet();

        uint256 harvested = vault.harvestYield();
        emit HarvestTriggered(vaultAddr, harvested);
    }

    function _queueSwitch(address vaultAddr, uint256 newIndex) internal {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);

        // Re-validate on-chain (stale data protection)
        if (vault.pendingSwitchTimestamp() != 0) revert ConditionsNotMet();
        if (lastSwitchTime[vaultAddr] > 0 && block.timestamp < lastSwitchTime[vaultAddr] + minSwitchInterval) revert ConditionsNotMet();

        uint256 currentAPY = vault.getCurrentAPY();
        (uint256 bestIndex, uint256 bestAPY) = vault.getBestStrategyIndex();

        if (bestIndex != newIndex || bestAPY < currentAPY + switchThresholdBps) {
            revert ConditionsNotMet();
        }

        uint256 fromIndex = vault.activeStrategyIndex();
        vault.queueStrategySwitchTo(newIndex);

        emit SwitchQueued(vaultAddr, fromIndex, newIndex, bestAPY - currentAPY);
    }

    // ─── Manual triggers ──────────────────────────────────────────────────────

    /**
     * @notice Execute a previously queued strategy switch after the timelock has elapsed.
     *         Owner-only to prevent front-running at unfavorable moments. (Audit fix H-1)
     */
    function executeSwitch(address vaultAddr, uint256 newIndex) external onlyOwner {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);
        uint256 fromIndex = vault.activeStrategyIndex();
        vault.switchStrategy(newIndex);
        lastSwitchTime[vaultAddr] = block.timestamp;
        emit SwitchExecuted(vaultAddr, fromIndex, newIndex);
    }

    /**
     * @notice Manually harvest yield from a vault (owner only).
     * @param vaultAddr Address of the vault to harvest.
     */
    function manualHarvest(address vaultAddr) external onlyOwner {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);
        uint256 harvested = vault.harvestYield();
        emit HarvestTriggered(vaultAddr, harvested);
    }

    /**
     * @notice Manually queue a strategy switch for a vault (owner only).
     * @dev Bypasses the threshold and cooldown checks, useful for emergency re-allocation.
     *      Still subject to AutoYieldVault's STRATEGY_SWITCH_DELAY timelock.
     */
    function triggerSwitch(address vaultAddr, uint256 newIndex) external onlyOwner {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);
        uint256 fromIndex = vault.activeStrategyIndex();
        vault.queueStrategySwitchTo(newIndex);
        emit SwitchQueued(vaultAddr, fromIndex, newIndex, 0);
    }

    /**
     * @notice Cancel a pending strategy switch on a vault (owner only). (Audit fix M-4)
     */
    function cancelSwitch(address vaultAddr) external onlyOwner {
        AutoYieldVault vault = AutoYieldVault(vaultAddr);
        vault.cancelStrategySwitchQueue();
        emit SwitchCancelled(vaultAddr);
    }

    // ─── Internal view helpers ────────────────────────────────────────────────

    /**
     * @notice Calculate harvestable yield for a vault's active strategy.
     * @dev Yield = strategy.getTotalValue() - strategy.totalDeposited()
     *      Returns 0 if no yield or on error.
     */
    function _getHarvestableYield(AutoYieldVault vault) internal view returns (uint256) {
        uint256 activeIdx = vault.activeStrategyIndex();

        // Read strategy address from the public struct array getter
        (IAutoYieldStrategy strategy,,) = vault.availableStrategies(activeIdx);

        // Both calls are external views that could revert on non-conforming strategies
        try strategy.getTotalValue() returns (uint256 totalValue) {
            try BaseStrategy(address(strategy)).totalDeposited() returns (uint256 deposited) {
                if (totalValue > deposited) {
                    return totalValue - deposited;
                }
            } catch {}
        } catch {}

        return 0;
    }

    /**
     * @notice Get harvestable yield for a vault (external view for monitoring).
     */
    function getHarvestableYield(address vaultAddr) external view returns (uint256) {
        return _getHarvestableYield(AutoYieldVault(vaultAddr));
    }
}
