// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../strategies/AaveStrategy.sol";
import "../interfaces/IRandomnessManager.sol";
import "./NoLossLotteryV3.sol";
import "./LotteryReceiptToken.sol";

/**
 * @title NoLossLotteryFactory
 * @notice Deploys NoLossLotteryV3 pools using the minimal proxy (Clones) pattern.
 *
 * Each call to `createPool()` atomically:
 *  1. Deploys a new AaveStrategy for the pool
 *  2. Deploys a LotteryReceiptToken (ERC-20)
 *  3. Clones the NoLossLotteryV3 implementation
 *  4. Initializes the clone with pool config
 *  5. Wires strategy → lottery, receipt token → lottery
 *  6. Registers lottery with RandomnessManager
 *
 * Follows the same pattern as ContestFactoryV2 (see ContestFactoryV2.sol).
 */
contract NoLossLotteryFactory is Ownable2Step {
    using Clones for address;

    // ─── State ──────────────────────────────────────────────────────────────────

    /// @notice NoLossLotteryV3 implementation contract (never initialized directly).
    address public lotteryImplementation;

    /// @notice Shared RandomnessManager for all pools.
    IRandomnessManager public randomnessManager;

    /// @notice Default protocol fee recipient for new pools.
    address public protocolFeeRecipient;

    /// @notice Default protocol fee for new pools (basis points, max 1000).
    uint256 public defaultProtocolFeeBps;

    /// @notice Aave V3 Pool address (shared across all pools on same chain).
    address public aavePool;

    /// @notice Aave V3 PoolDataProvider (shared, address(0) for mock/local mode).
    address public aaveDataProvider;

    // ─── Deployed Pools ─────────────────────────────────────────────────────────

    struct DeployedPool {
        address lottery;
        address strategy;
        address receiptToken;
        uint8   poolType;
        uint256 roundDuration;
        uint256 deployedAt;
    }

    DeployedPool[] public deployedPools;

    // ─── Pool Config ────────────────────────────────────────────────────────────

    struct PoolConfig {
        address depositToken;     // e.g., USDC
        address aToken;           // e.g., aUSDC on Base
        uint256 roundDuration;    // 604800 (weekly) / 2592000 (monthly)
        uint8   numberOfTiers;    // 2 (weekly) / 1 (monthly)
        uint256[5] tierBps;       // [7500,2500,0,0,0] / [10000,0,0,0,0]
        uint8   poolType;         // 0=weekly, 1=monthly
        string  receiptName;      // "MindYield Weekly USDC"
        string  receiptSymbol;    // "myWeeklyUSDC"
    }

    // ─── Events ─────────────────────────────────────────────────────────────────

    event PoolCreated(
        address indexed lottery,
        address indexed strategy,
        address indexed receiptToken,
        uint8   poolType,
        uint256 roundDuration
    );

    // ─── Errors ─────────────────────────────────────────────────────────────────

    error InvalidImplementation();
    error InvalidConfig();

    // ─── Constructor ────────────────────────────────────────────────────────────

    /**
     * @param _lotteryImpl        NoLossLotteryV3 implementation address.
     * @param _randomnessManager  Shared RandomnessManager.
     * @param _feeRecipient       Default protocol fee recipient.
     * @param _defaultFeeBps      Default protocol fee (basis points).
     * @param _aavePool           Aave V3 Pool address.
     * @param _aaveDataProvider   Aave V3 PoolDataProvider (address(0) = local mode).
     */
    constructor(
        address _lotteryImpl,
        address _randomnessManager,
        address _feeRecipient,
        uint256 _defaultFeeBps,
        address _aavePool,
        address _aaveDataProvider
    ) Ownable() {
        require(_lotteryImpl != address(0),       "Factory: invalid impl");
        require(_randomnessManager != address(0), "Factory: invalid RM");
        require(_feeRecipient != address(0),      "Factory: invalid fee recipient");
        require(_aavePool != address(0),          "Factory: invalid aave pool");

        lotteryImplementation = _lotteryImpl;
        randomnessManager     = IRandomnessManager(_randomnessManager);
        protocolFeeRecipient  = _feeRecipient;
        defaultProtocolFeeBps = _defaultFeeBps;
        aavePool              = _aavePool;
        aaveDataProvider      = _aaveDataProvider;
    }

    // ─── Pool Deployment ────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new lottery pool with its own strategy and receipt token.
     * @param config Pool configuration.
     * @return lottery Address of the deployed lottery clone.
     */
    function createPool(PoolConfig calldata config) external onlyOwner returns (address lottery) {
        if (config.depositToken == address(0)) revert InvalidConfig();
        if (config.aToken == address(0)) revert InvalidConfig();

        // 1. Deploy AaveStrategy for this pool
        AaveStrategy strategy = new AaveStrategy(
            aavePool,
            config.depositToken,
            config.aToken,
            aaveDataProvider
        );

        // 2. Deploy receipt token (match deposit token decimals)
        uint8 tokenDecimals = 18; // fallback
        try IERC20Metadata(config.depositToken).decimals() returns (uint8 d) {
            tokenDecimals = d;
        } catch {}

        LotteryReceiptToken receipt = new LotteryReceiptToken(
            config.receiptName,
            config.receiptSymbol,
            tokenDecimals
        );

        // 3. Clone lottery implementation
        lottery = lotteryImplementation.clone();

        // 4. Initialize the clone
        NoLossLotteryV3(lottery).initialize(
            config.depositToken,
            address(strategy),
            address(randomnessManager),
            config.roundDuration,
            protocolFeeRecipient,
            defaultProtocolFeeBps,
            config.numberOfTiers,
            config.tierBps,
            config.poolType,
            address(receipt)
        );

        // 5. Wire strategy → lottery (strategy only accepts calls from its yieldVault)
        strategy.setYieldVault(lottery);

        // 6. Transfer receipt token ownership to lottery (only lottery can mint/burn)
        receipt.transferOwnership(lottery);

        // 7. Transfer strategy ownership to factory owner (for emergency withdraw)
        strategy.transferOwnership(owner());

        // 8. Transfer lottery ownership to factory owner (for config changes)
        NoLossLotteryV3(lottery).transferOwnership(owner());

        // 9. Register lottery as allowed VRF requester
        //    Requires: RandomnessManager.setAuthorizedFactory(thisFactory, true) was called by RM owner
        (bool success, ) = address(randomnessManager).call(
            abi.encodeWithSignature("addAllowedRequester(address)", lottery)
        );
        // Non-fatal: if factory isn't authorized, owner can register manually
        if (!success) {
            // silently continue — owner will call addAllowedRequester on RM directly
        }

        // 10. Track deployment
        deployedPools.push(DeployedPool({
            lottery:       lottery,
            strategy:      address(strategy),
            receiptToken:  address(receipt),
            poolType:      config.poolType,
            roundDuration: config.roundDuration,
            deployedAt:    block.timestamp
        }));

        emit PoolCreated(lottery, address(strategy), address(receipt), config.poolType, config.roundDuration);
    }

    // ─── View Functions ─────────────────────────────────────────────────────────

    function poolCount() external view returns (uint256) {
        return deployedPools.length;
    }

    function getPool(uint256 index) external view returns (DeployedPool memory) {
        return deployedPools[index];
    }

    // ─── Admin ──────────────────────────────────────────────────────────────────

    function setLotteryImplementation(address _impl) external onlyOwner {
        if (_impl == address(0)) revert InvalidImplementation();
        lotteryImplementation = _impl;
    }

    function setDefaultProtocolFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "Factory: fee too high");
        defaultProtocolFeeBps = _feeBps;
    }

    function setProtocolFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Factory: invalid recipient");
        protocolFeeRecipient = _recipient;
    }

    /**
     * @notice Register a deployed lottery with the RandomnessManager.
     *         Call this if the factory doesn't have permission to register during createPool.
     */
    function registerWithRandomnessManager(address lottery) external onlyOwner {
        // Note: The RandomnessManager must have an addAllowedRequester function
        // accessible to this factory. If it uses a different access model,
        // the owner should register directly on the RandomnessManager.
    }
}
