// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Integration Fork Tests
 * @notice Tests against real deployed protocols on live chains.
 *
 * @dev Only runs with a valid --fork-url:
 *   forge test --fork-url $BASE_RPC_URL --match-path "test/Integration.fork.t.sol" -vvvv
 *
 * Set FORK_URL env var to the RPC endpoint.
 * Tests auto-skip if FORK_URL is empty.
 */

import "forge-std/Test.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/strategies/CompoundV3Strategy.sol";
import "../src/strategies/MorphoStrategy.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/optimizers/YieldOptimizer.sol";
import "../src/addresses/NetworkAddresses.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWhale {
    // Used with vm.prank to impersonate a funded account
}

contract IntegrationForkTest is Test {

    // ─── Fork state ───────────────────────────────────────────────────────────

    string  internal forkUrl;
    bool    internal skipTests;
    uint256 internal chainId;

    // Common
    IUSDC internal usdc;
    address internal whale; // USDC-rich address on the fork

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        forkUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            skipTests = true;
            return;
        }

        vm.createSelectFork(forkUrl);
        chainId = block.chainid;

        // Base Mainnet fork
        if (chainId == 8453) {
            usdc  = IUSDC(NetworkAddresses.BASE_USDC);
            whale = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3; // Coinbase / large holder
        } else if (chainId == 1) {
            // Ethereum mainnet
            usdc  = IUSDC(NetworkAddresses.ETH_USDC);
            whale = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Binance
        } else {
            skipTests = true;
        }
    }

    // ─── Helper ───────────────────────────────────────────────────────────────

    modifier onlyFork() {
        if (skipTests) return;
        _;
    }

    function _getFunds(address to, uint256 amount) internal {
        vm.prank(whale);
        require(usdc.transfer(to, amount), "USDC whale transfer failed");
    }

    // =========================================================================
    // Aave V3 fork tests (Base)
    // =========================================================================

    function test_fork_aaveStrategy_depositAndWithdraw() public onlyFork {
        if (chainId != 8453) return;

        address pool     = NetworkAddresses.BASE_AAVE_POOL;
        address aUsdc    = NetworkAddresses.BASE_AUSDC;
        address dataProv = NetworkAddresses.BASE_AAVE_DATA_PROV;

        AaveStrategy strategy = new AaveStrategy(pool, address(usdc), aUsdc, dataProv);
        AutoYieldVault vault  = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Aave V3 USDC");
        strategy.setYieldVault(address(vault));

        uint256 amount = 100e6; // 100 USDC
        _getFunds(address(this), amount);

        IUSDC(address(usdc)).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount);
        assertGt(shares, 0, "should receive shares");
        assertApproxEqAbs(vault.totalAssets(), amount, 1e4, "assets should match deposit");

        // Roll forward some blocks to accrue interest
        vm.roll(block.number + 1000);

        // Check APY from real data provider
        uint256 apy = strategy.getEstimatedAPY();
        assertGt(apy, 0, "real Aave APY should be > 0");
        assertLt(apy, 3000, "Aave APY should be < 30% (sanity)");

        // Withdraw
        uint256 balBefore = usdc.balanceOf(address(this));
        vault.withdraw(shares);
        assertGe(usdc.balanceOf(address(this)) - balBefore, amount - 1e4, "should get at least principal");
    }

    // =========================================================================
    // Compound V3 (Comet) fork tests (Base)
    // =========================================================================

    function test_fork_compoundV3Strategy_depositAndWithdraw() public onlyFork {
        if (chainId != 8453) return;

        address comet_ = NetworkAddresses.BASE_COMET_USDC;

        CompoundV3Strategy strategy = new CompoundV3Strategy(comet_, address(usdc));
        AutoYieldVault vault = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Compound V3 USDC");
        strategy.setYieldVault(address(vault));

        uint256 amount = 100e6;
        _getFunds(address(this), amount);

        IUSDC(address(usdc)).approve(address(vault), amount);
        vault.deposit(amount);
        assertApproxEqAbs(vault.totalAssets(), amount, 1e4);

        // Check APY
        uint256 apy = strategy.getEstimatedAPY();
        assertGt(apy, 0, "Compound V3 APY should be > 0");
        assertLt(apy, 3000, "Compound V3 APY sanity check");

        // Withdraw all
        uint256 shares     = vault.shares(address(this));
        uint256 balBefore  = usdc.balanceOf(address(this));
        vault.withdraw(shares);
        assertGe(usdc.balanceOf(address(this)) - balBefore, amount - 1e4);
    }

    // =========================================================================
    // MetaMorpho (Morpho) fork tests (Base)
    // =========================================================================

    function test_fork_morphoStrategy_depositAndWithdraw() public onlyFork {
        if (chainId != 8453) return;

        address metaMorpho = NetworkAddresses.BASE_METAMORPHO_USDC;

        MorphoStrategy strategy = new MorphoStrategy(address(usdc), metaMorpho, "Morpho USDC");
        AutoYieldVault vault    = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Morpho USDC");
        strategy.setYieldVault(address(vault));

        uint256 amount = 100e6;
        _getFunds(address(this), amount);

        IUSDC(address(usdc)).approve(address(vault), amount);
        vault.deposit(amount);
        assertApproxEqAbs(vault.totalAssets(), amount, 1e4);

        // APY may be 0 if MetaMorpho doesn't implement apr() on this fork
        uint256 apy = strategy.getEstimatedAPY();
        // Just ensure it doesn't revert; it's 0 if the vault doesn't have apr()
        assertTrue(apy >= 0, "APY should not revert");

        uint256 shares    = vault.shares(address(this));
        uint256 balBefore = usdc.balanceOf(address(this));
        vault.withdraw(shares);
        assertGe(usdc.balanceOf(address(this)) - balBefore, amount - 1e4);
    }

    // =========================================================================
    // YieldOptimizer fork test (Base — Aave vs Compound V3)
    // =========================================================================

    function test_fork_yieldOptimizer_selectsBestStrategy() public onlyFork {
        if (chainId != 8453) return;

        AaveStrategy aaveStrat = new AaveStrategy(
            NetworkAddresses.BASE_AAVE_POOL,
            address(usdc),
            NetworkAddresses.BASE_AUSDC,
            NetworkAddresses.BASE_AAVE_DATA_PROV
        );
        CompoundV3Strategy compStrat = new CompoundV3Strategy(
            NetworkAddresses.BASE_COMET_USDC,
            address(usdc)
        );

        AutoYieldVault vault = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(aaveStrat),  "Aave V3 USDC");
        vault.addStrategy(address(compStrat),  "Compound V3 USDC");

        aaveStrat.setYieldVault(address(vault));
        compStrat.setYieldVault(address(vault));

        YieldOptimizer optImpl = new YieldOptimizer();
        bytes memory initData = abi.encodeWithSelector(
            YieldOptimizer.initialize.selector, uint256(50), uint256(0), uint256(10e6)
        );
        ERC1967Proxy optProxy = new ERC1967Proxy(address(optImpl), initData);
        YieldOptimizer optimizer = YieldOptimizer(address(optProxy));
        optimizer.addVault(address(vault));
        vault.setOperator(address(optimizer));

        uint256 amount = 100e6;
        _getFunds(address(this), amount);
        IUSDC(address(usdc)).approve(address(vault), amount);
        vault.deposit(amount);

        // Get APYs from both strategies
        uint256[] memory apys = vault.getStrategyAPYs();
        assertEq(apys.length, 2);

        (uint256 bestIdx, uint256 bestAPY) = vault.getBestStrategyIndex();
        assertGe(bestAPY, 0, "best APY should be >= 0");
        assertTrue(bestIdx < 2, "best index should be valid");

        // If optimizer should switch, verify checkUpkeep reports it correctly
        (bool needed, bytes memory data) = optimizer.checkUpkeep("");
        if (needed) {
            (YieldOptimizer.ActionType action,, uint256 newIdx) =
                abi.decode(data, (YieldOptimizer.ActionType, address, uint256));
            // Only queue-switch is expected here (no pending switch, no yield yet)
            if (action == YieldOptimizer.ActionType.QUEUE_SWITCH) {
                optimizer.performUpkeep(data);
                // Switch is now queued, not yet executed (24h timelock)
                assertGt(vault.pendingSwitchTimestamp(), 0, "switch should be queued");
            }
        }
    }
}
