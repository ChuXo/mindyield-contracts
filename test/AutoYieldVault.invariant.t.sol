// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/// @notice Handler that exposes a bounded subset of AutoYieldVault actions
///         for stateful fuzzing. The invariant fuzzer calls these in random
///         orders; the invariant checks (in the test contract below) assert
///         the platform's "fees only on accrued yield" promise across every
///         possible interleaving.
contract AutoYieldVaultHandler is Test {
    AutoYieldVault public vault;
    MockERC20 public usdc;
    MockAutoYieldStrategy public strategy;
    address public treasury;
    address public owner;

    address[] public depositors;
    mapping(address => bool) public registered;
    mapping(address => uint256) public ghostDeposited;
    mapping(address => uint256) public ghostWithdrawn;

    /// @notice Cumulative real yield injected via simulateYield. Upper-bounds
    ///         what the treasury can have legitimately accrued.
    uint256 public ghostCumulativeYield;

    /// @notice Sum of fee assets minted to treasury (snapshotted at mint
    ///         time). Upper-bounded by ghostCumulativeYield × PERF_FEE_BPS.
    uint256 public ghostCumulativeFeeMinted;

    uint256 private _userNonce;

    constructor(address _vault, address _usdc, address _strategy, address _treasury, address _owner) {
        vault = AutoYieldVault(_vault);
        usdc = MockERC20(_usdc);
        strategy = MockAutoYieldStrategy(_strategy);
        treasury = _treasury;
        owner = _owner;
    }

    // ─── Bounded handler actions ──────────────────────────────────────────────

    /// @dev Snapshots treasury share growth across an action and converts the
    ///      delta to asset-equivalent at the *post-action* share price (which
    ///      is the moment of mint, since `_accrueFees` advances `lastFeeAssets`
    ///      and totalShares atomically). Approximates fee-asset minted.
    function _trackTreasuryMint(uint256 trSharesBefore) private {
        uint256 trSharesAfter = vault.shares(treasury);
        if (trSharesAfter <= trSharesBefore) return;
        uint256 minted = trSharesAfter - trSharesBefore;
        uint256 totalA = vault.totalAssets();
        uint256 totalS = vault.totalShares();
        if (totalS == 0) return;
        // Same formula as the contract's `_convertAssetsToShares` inverse.
        uint256 mintedAssets = (minted * (totalA + 1)) / (totalS + 1e6);
        ghostCumulativeFeeMinted += mintedAssets;
    }

    function deposit(uint96 amount) external {
        amount = uint96(bound(uint256(amount), 1_000, 10_000_000e6)); // 0.001 → 10M USDC
        address user = _nextUser();
        usdc.mint(user, uint256(amount));

        uint256 trSharesBefore = vault.shares(treasury);

        vm.startPrank(user);
        usdc.approve(address(vault), uint256(amount));
        try vault.deposit(uint256(amount)) {
            ghostDeposited[user] += uint256(amount);
            if (!registered[user]) {
                depositors.push(user);
                registered[user] = true;
            }
        } catch { /* bounded but still guard */ }
        vm.stopPrank();

        _trackTreasuryMint(trSharesBefore);
        vm.roll(block.number + 1);
    }

    function withdraw(uint256 idx, uint256 sharePct) external {
        if (depositors.length == 0) return;
        idx = bound(idx, 0, depositors.length - 1);
        address user = depositors[idx];
        uint256 userShares = vault.shares(user);
        if (userShares == 0) return;

        // 1..100 percent of user's shares
        sharePct = bound(sharePct, 1, 100);
        uint256 sharesToBurn = (userShares * sharePct) / 100;
        if (sharesToBurn == 0) return;

        // Move past MIN_HOLD_TIME and same-block guard.
        vm.warp(block.timestamp + 16);
        vm.roll(block.number + 1);

        uint256 trSharesBefore = vault.shares(treasury);

        vm.startPrank(user);
        try vault.withdraw(sharesToBurn) returns (uint256 out) {
            ghostWithdrawn[user] += out;
        } catch { /* OK — same-block guards etc. */ }
        vm.stopPrank();

        _trackTreasuryMint(trSharesBefore);
    }

    function injectYield(uint96 amount) external {
        // Yield without depositors creates "orphan yield" that gets absorbed
        // into virtual-offset dust, which is a known property of OZ 5.x ERC-4626
        // vaults but never happens in production (the first depositor always
        // arrives before any yield can accrue). Gate on having at least one
        // depositor so the invariants reflect real-world behaviour.
        if (vault.totalShares() == 0) return;
        amount = uint96(bound(uint256(amount), 0, 10_000e6)); // 0..10k USDC of yield
        if (amount == 0) return;
        strategy.simulateYield(uint256(amount));
        ghostCumulativeYield += uint256(amount);
    }

    function accrue() external {
        uint256 trSharesBefore = vault.shares(treasury);
        try vault.accrueFees() {} catch {}
        _trackTreasuryMint(trSharesBefore);
    }

    function setFloor(uint256 newFloor) external {
        newFloor = bound(newFloor, 0, vault.MAX_MIN_FEE_YIELD_ASSETS());
        uint256 trSharesBefore = vault.shares(treasury);
        vm.prank(owner);
        try vault.setMinFeeYieldAssets(newFloor) {} catch {}
        _trackTreasuryMint(trSharesBefore);
    }

    function timeJump(uint256 secs) external {
        secs = bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _nextUser() private returns (address) {
        _userNonce++;
        return address(uint160(uint256(keccak256(abi.encode("ay-user", _userNonce)))));
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function depositorAt(uint256 i) external view returns (address) {
        return depositors[i];
    }
}

contract AutoYieldVaultInvariantTest is Test {
    AutoYieldVault vault;
    MockERC20 usdc;
    MockAutoYieldStrategy strategy;
    AutoYieldVaultHandler handler;

    address owner = address(0xA11CE);
    address treasury = address(0xFEE);

    /// @notice Tolerated rounding from virtual offset / strategy share math.
    /// Two raw units per active depositor is generous (in practice ≪ 1 raw unit).
    uint256 constant DUST_PER_USER = 2;

    /// @notice Performance fee in bps used throughout. 10% to amplify any
    /// fee-billing-on-principal regression so the invariant fails loudly.
    uint256 constant PERF_FEE_BPS = 1_000;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("Test USDC", "USDC", 6);
        strategy = new MockAutoYieldStrategy(address(usdc));
        vault = new AutoYieldVault(address(usdc), "USDC");
        vault.addStrategy(address(strategy), "Mock");

        // Wire fees BEFORE first deposit — the production order that surfaced
        // the original principal-as-yield bug. The invariants below run
        // continuously over random handler call sequences.
        vault.setFeeRecipient(treasury);
        vault.setPerformanceFee(PERF_FEE_BPS);
        // Default $0.10 floor stays in place. Handler can mutate it via setFloor.
        vm.stopPrank();

        // Pre-fund strategy with simulateYield headroom (mock holds tokens it
        // hands back as yield).
        usdc.mint(address(strategy), 100_000_000e6);

        handler = new AutoYieldVaultHandler(
            address(vault),
            address(usdc),
            address(strategy),
            treasury,
            owner
        );

        // Restrict the fuzzer to handler functions (not arbitrary calls into
        // the vault — those would just produce junk reverts).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = AutoYieldVaultHandler.deposit.selector;
        selectors[1] = AutoYieldVaultHandler.withdraw.selector;
        selectors[2] = AutoYieldVaultHandler.injectYield.selector;
        selectors[3] = AutoYieldVaultHandler.accrue.selector;
        selectors[4] = AutoYieldVaultHandler.setFloor.selector;
        selectors[5] = AutoYieldVaultHandler.timeJump.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ─── Invariants ──────────────────────────────────────────────────────────
    //
    // We deliberately don't fuzz-check a per-user "no principal loss" property
    // because legitimate ERC-4626 share-price dilution (a new depositor joins
    // *after* yield has accrued to existing holders) means a new depositor
    // can immediately have userAssets slightly less than their deposit. This
    // is intrinsic to the OZ 5.x virtual-offset pattern and not the bug we
    // fixed. The principal-fee bug is already covered exhaustively in the
    // deterministic unit tests in `AutoYieldVault.fees.t.sol`. The two
    // invariants below catch the *systemic* properties: (a) accounting can't
    // drift, and (b) the treasury can never extract more than the configured
    // fee percentage of cumulative yield.

    /// @notice Treasury's accumulated fee shares (denominated in assets at
    ///         time of minting) can never exceed `PERF_FEE_BPS` of the
    ///         cumulative real yield ever injected. We use the handler's
    ///         ghost variable that snapshots treasury share growth on each
    ///         call rather than `getUserInfo(treasury)` directly, because
    ///         already-minted treasury shares legitimately appreciate with
    ///         vault yield (they're real shares of the vault), and that
    ///         appreciation is NOT a fee — it's the treasury earning yield
    ///         on its own holdings just like any depositor.
    function invariant_treasuryFeeMintsBoundedByYield() public {
        uint256 cumYield = handler.ghostCumulativeYield();
        uint256 maxFee = (cumYield * PERF_FEE_BPS) / 10_000;
        // The handler approximates each mint's asset value at the *post-action*
        // share price (it can't observe mid-tx share price without parsing
        // FeesAccrued logs). Below-floor yield that accrues between mints
        // grows everyone's share price proportionally, so by the time we sum
        // a later mint it's denominated against a higher price than at its
        // own mint instant. The drift is bounded by cumYield × small_factor,
        // never by principal — the principal-fee bug this invariant guards
        // against would breach the bound by >100% of any deposit, not by
        // <1% of yield. Allow 2% of cumulative yield + a small absolute
        // floor for share-math rounding on tiny vaults.
        uint256 tolerance = cumYield / 50 + 1_000;
        assertLe(
            handler.ghostCumulativeFeeMinted(),
            maxFee + tolerance,
            "fee shares minted exceed max-fee on cumulative yield"
        );
    }

    /// @notice Sum of every share-holder's userAssets must approximate
    ///         totalAssets. Drift here would mean either accounting is broken
    ///         or shares are minted from thin air. Skipped when totalShares
    ///         is 0 because virtual offset means assets-without-holders is a
    ///         legitimate transient state.
    function invariant_userAssetsAddUpToTotalAssets() public {
        if (vault.totalShares() == 0) return;

        uint256 sum;
        uint256 n = handler.depositorCount();
        for (uint256 i = 0; i < n; i++) {
            (, uint256 ua) = vault.getUserInfo(handler.depositorAt(i));
            sum += ua;
        }
        (, uint256 treasuryAssets) = vault.getUserInfo(treasury);
        sum += treasuryAssets;

        uint256 ta = vault.totalAssets();
        uint256 ts = vault.totalShares();
        // The virtual offset (1e6 phantom shares, 1 phantom asset) holds a
        // fraction `1e6 / (totalShares + 1e6)` of totalAssets. For small
        // totalShares (just after the first deposit) this can be a non-trivial
        // share of assets; for large totalShares it shrinks toward zero.
        // The exact phantom-asset bound is the contract's own formula:
        //   phantom = totalAssets * 1e6 / (totalShares + 1e6)
        uint256 phantomBound = (ta * 1e6) / (ts + 1e6);
        uint256 tolerance = DUST_PER_USER * (n + 1) + phantomBound + 100;
        if (sum > ta) {
            assertLe(sum - ta, tolerance, "sum userAssets exceeds totalAssets");
        } else {
            assertLe(ta - sum, tolerance, "totalAssets exceeds sum userAssets");
        }
    }
}
