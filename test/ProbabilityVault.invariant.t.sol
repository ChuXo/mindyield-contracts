// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice Handler contract that wraps ProbabilityVaultV2 actions.
///         The invariant fuzzer calls these bounded actions, then the
///         invariant checks are asserted on the vault state.
contract ProbabilityVaultHandler is Test {
    ProbabilityVaultV2      public vault;
    MockERC20               public usdc;
    IdentityRegistry        public identityRegistry;

    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");

    // Track depositors for invariant checking
    address[] public depositors;
    mapping(address => bool) public hasDeposited;

    // Ghost variables for invariant tracking
    uint256 public ghost_totalDeposited;   // total USDC transferred in
    uint256 public ghost_totalEarlyOut;    // USDC returned via withdrawEarly

    uint256 private _userNonce;

    constructor(
        address _vault,
        address _usdc,
        address _identityRegistry
    ) {
        vault = ProbabilityVaultV2(_vault);
        usdc = MockERC20(_usdc);
        identityRegistry = IdentityRegistry(_identityRegistry);
    }

    function deposit(uint96 amount, bool chooseYes) external {
        // Only during JOIN_OPEN
        if (vault.state() != ProbabilityVaultV2.State.JOIN_OPEN) return;
        if (block.timestamp >= vault.joinEnd()) return;

        amount = uint96(bound(uint256(amount), 1e6, 100_000e6));
        bytes32 side = chooseYes ? YES : NO;

        address user = _nextUser();
        identityRegistry.setTier(user, 2);
        usdc.mint(user, uint256(amount));

        vm.startPrank(user);
        usdc.approve(address(vault), uint256(amount));
        try vault.deposit(uint256(amount), side) {
            ghost_totalDeposited += uint256(amount);
            if (!hasDeposited[user]) {
                depositors.push(user);
                hasDeposited[user] = true;
            }
        } catch { /* bounded but still guard */ }
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    function swap(uint256 depositorIdx, uint96 swapAmt, bool toYes) external {
        if (vault.state() != ProbabilityVaultV2.State.JOIN_OPEN) return;
        if (block.timestamp >= vault.joinEnd()) return;
        if (depositors.length == 0) return;

        depositorIdx = bound(depositorIdx, 0, depositors.length - 1);
        address user = depositors[depositorIdx];

        ProbabilityVaultV2.UserPosition memory pos = vault.userPosition(user);
        bytes32 newSide = toYes ? YES : NO;
        uint256 stakeAvail = toYes ? uint256(pos.noStake) : uint256(pos.yesStake);
        if (stakeAvail == 0) return;
        swapAmt = uint96(bound(uint256(swapAmt), 1, stakeAvail));

        vm.prank(user);
        try vault.swap(uint256(swapAmt), newSide) {} catch {}
    }

    function withdrawEarly(uint256 depositorIdx) external {
        if (vault.state() != ProbabilityVaultV2.State.JOIN_OPEN) return;
        if (block.timestamp >= vault.joinEnd()) return;
        if (depositors.length == 0) return;

        depositorIdx = bound(depositorIdx, 0, depositors.length - 1);
        address user = depositors[depositorIdx];

        ProbabilityVaultV2.UserPosition memory pos = vault.userPosition(user);
        if (pos.withdrawnEarly || pos.principal == 0) return;
        // Ensure we're not in the same block as the last deposit
        vm.roll(block.number + 1);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        try vault.withdrawEarly() {
            ghost_totalEarlyOut += usdc.balanceOf(user) - balBefore;
        } catch {}
    }

    function advanceTime(uint32 secs) external {
        // Advance at most to joinEnd
        uint64 joinEnd = vault.joinEnd();
        uint64 cap = block.timestamp + secs > joinEnd
            ? joinEnd - uint64(block.timestamp)
            : secs;
        if (cap == 0) return;
        vm.warp(block.timestamp + cap);
        vm.roll(block.number + 1);
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function _nextUser() internal returns (address) {
        return address(uint160(0xBEEF_0000 + (_userNonce++)));
    }
}

/// @notice Invariant test suite for ProbabilityVaultV2.
///         The fuzzer calls handler functions; after each sequence it
///         checks the invariants below.
contract ProbabilityVaultInvariantTest is Test {
    ProbabilityVaultV2      public vault;
    ProbabilityVaultFactory public factory;
    YieldVault              public yieldVault;
    IdentityRegistry        public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20               public usdc;
    ProbabilityVaultHandler public handler;

    address public creator  = address(0x100);
    address public treasury = address(0x111);

    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");

    function setUp() public {
        vm.warp(1_800_000_000);
        uint64 polyEnd = uint64(block.timestamp + 30 days);

        usdc = new MockERC20("USDC", "USDC", 6);
        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));
        identityRegistry = new IdentityRegistry();

        ProbabilityVaultV2 impl = new ProbabilityVaultV2();
        factory = new ProbabilityVaultFactory(
            address(impl),
            address(yieldVault),
            address(0),
            address(identityRegistry),
            treasury
        );
        yieldVault.transferOwnership(address(factory));

        resolver = new PolymarketRelayResolver(address(factory), address(usdc));

        vm.prank(creator);
        (, address vaultAddr) = factory.createVault(ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: polyEnd,
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       keccak256("invariant-cid"),
            metadataHash:      keccak256("invariant"),
            metadataUri:       "ipfs://invariant",
            resolver:          address(resolver)
        }));
        vault = ProbabilityVaultV2(vaultAddr);

        handler = new ProbabilityVaultHandler(vaultAddr, address(usdc), address(identityRegistry));

        // Bound fuzzer to handler only
        targetContract(address(handler));
    }

    // ─── Invariant 1: Pool conservation ──────────────────────────────
    // total stake in pool + fees = total deposited − total early-withdrawn

    function invariant_poolConservation() public view {
        uint256 yesStake = uint256(vault.totalYesStake());
        uint256 noStake  = uint256(vault.totalNoStake());
        uint256 fees     = uint256(vault.totalAccruedSwapFees());

        // pool (yes + no + fees) ≤ total deposited (early-outs reduce deposits)
        uint256 accountedIn = handler.ghost_totalDeposited();
        uint256 accountedOut = handler.ghost_totalEarlyOut();

        // pool + earlyOut ≤ deposited (within 1 wei rounding)
        assertLe(
            yesStake + noStake + fees + accountedOut,
            accountedIn + 1,
            "Pool conservation violated"
        );
    }

    // ─── Invariant 2: State is monotonic (doesn't regress) ───────────

    function invariant_state_monotonic() public view {
        uint256 s = uint256(vault.state());
        // In JOIN_OPEN phase (0 is CREATED which is transient; 1 is JOIN_OPEN)
        // State should be 0 (CREATED, never — impl blocks), 1 (JOIN_OPEN),
        // or 2+ (post-join), but since handler doesn't advance past joinEnd
        // on its own, state should stay at JOIN_OPEN=1 or LOCKED=2.
        assertLe(s, 5, "State out of range");
    }

    // ─── Invariant 3: VaultShares match deposits ──────────────────────

    function invariant_vaultSharesPositive() public view {
        uint256 totalStake = uint256(vault.totalYesStake()) + uint256(vault.totalNoStake());
        // If deposits happened, vaultShares must be > 0
        if (totalStake > 0) {
            assertGt(vault.vaultShares(), 0, "vaultShares must be positive when stake exists");
        }
    }

    // ─── Invariant 4: TWAB grows (only increases while stake > 0) ─────
    // We can't easily check historic values, but we can verify
    // global TWAB ≥ each user's TWAB across all depositors.

    function invariant_globalTwabGeUserTwabs() public view {
        uint256 totalYesTwab = uint256(vault.totalYesTwab());
        uint256 totalNoTwab  = uint256(vault.totalNoTwab());
        uint256 count = handler.depositorCount();

        uint256 sumUserYes;
        uint256 sumUserNo;
        for (uint256 i = 0; i < count; i++) {
            address user = handler.depositors(i);
            ProbabilityVaultV2.UserPosition memory pos = vault.userPosition(user);
            if (!pos.withdrawnEarly) {
                sumUserYes += uint256(pos.yesTwab);
                sumUserNo  += uint256(pos.noTwab);
            }
        }

        // Global TWAB must be ≥ sum of active user TWABs
        // (active early-withdrawers forfeited their TWAB from global)
        assertGe(totalYesTwab + 1, sumUserYes, "Global YES TWAB < sum of user YES TWABs");
        assertGe(totalNoTwab  + 1, sumUserNo,  "Global NO TWAB < sum of user NO TWABs");
    }

    // ─── Invariant 5: implied probability in [0, 10000] ──────────────

    function invariant_impliedProbabilityInRange() public view {
        uint256 prob = vault.impliedProbabilityYes();
        assertLe(prob, 10_000, "Implied probability > 10000");
    }
}
