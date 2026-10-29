// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice Mirrors all 8 dev-panel scenarios from scripts/dev-simulation-server.mjs.
///         Validates the contract-level logic that each JavaScript scenario exercises,
///         catching ABI mismatches, wrong Outcome enum values, and incorrect call
///         sequences before they hit a live chain.
contract ProbabilityVaultDevPanelTest is Test {
    ProbabilityVaultV2      public impl;
    ProbabilityVaultFactory public factory;
    YieldVault              public yieldVault;
    IdentityRegistry        public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20               public usdc;

    address public deployer  = address(this);
    address public creator   = address(0x100);
    address public treasury  = address(0x111);

    address public bot0 = address(0xB00);
    address public bot1 = address(0xB01);
    address public bot2 = address(0xB02);
    address public bot3 = address(0xB03);
    address public bot4 = address(0xB04);
    address public bot5 = address(0xB05);

    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");

    uint256 constant DEPOSIT = 100e6;

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockERC20("USDC", "USDC", 6);
        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));
        identityRegistry = new IdentityRegistry();

        address[7] memory all = [bot0, bot1, bot2, bot3, bot4, bot5, creator];
        for (uint256 i = 0; i < 7; i++) {
            identityRegistry.setTier(all[i], 2);
            usdc.mint(all[i], 10_000e6);
        }

        impl    = new ProbabilityVaultV2();
        factory = new ProbabilityVaultFactory(
            address(impl), address(yieldVault), address(0),
            address(identityRegistry), treasury
        );
        // Ownable2Step: must be accepted before setTrustedDepositor works.
        yieldVault.transferOwnership(address(factory));
        vm.prank(address(factory));
        yieldVault.acceptOwnership();
        resolver = new PolymarketRelayResolver(address(factory), address(usdc));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _createVault(bytes32 conditionId) internal returns (address vaultAddr, bytes32 vaultKey) {
        uint64 joinEnd      = uint64(block.timestamp + 120);
        uint64 polyEnd      = uint64(uint256(joinEnd)     + 24 hours + 120);
        uint64 resolveStart = uint64(uint256(polyEnd)     + 36 hours + 120);

        vm.prank(creator);
        (, vaultAddr) = factory.createVault(ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: polyEnd,
            joinEnd:           joinEnd,
            resolveStart:      resolveStart,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       conditionId,
            metadataHash:      keccak256(abi.encode(conditionId)),
            metadataUri:       "ipfs://devpanel-test",
            resolver:          address(resolver)
        }));
        vaultKey = bytes32(uint256(uint160(vaultAddr)));
    }

    function _deposit(address user, address vault, uint256 amount, bytes32 side) internal {
        vm.startPrank(user);
        usdc.approve(vault, amount);
        ProbabilityVaultV2(vault).deposit(amount, side);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _injectYield(uint256 amount) internal {
        usdc.mint(address(yieldVault), amount);
    }

    /// @dev Warp through all phases and resolve the vault with a given outcome.
    function _resolveVault(address vault, bytes32 vaultKey, PolymarketRelayResolver.Outcome outcome) internal {
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);
        vm.warp(uint256(pv.joinEnd()) + 1);
        _injectYield(10e6);
        vm.warp(uint256(pv.polymarketEndDate()) + 12 hours + 1);
        resolver.propose(vaultKey, outcome);
        vm.warp(uint256(pv.resolveStart()) + 1);
        pv.resolveContest();
    }

    // ─── Scenario 1: market-happy-path-yes ───────────────────────────────────

    function test_devpanel_01_happyPath_yesWins() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("happy-yes"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(bot0, vault, DEPOSIT, YES);
        _deposit(bot1, vault, DEPOSIT, YES);
        _deposit(bot2, vault, DEPOSIT, YES);
        _deposit(bot3, vault, DEPOSIT, NO);

        assertEq(uint256(pv.totalYesStake()), 3 * DEPOSIT, "3 YES stakes");
        assertEq(uint256(pv.totalNoStake()),  DEPOSIT,     "1 NO stake");

        _resolveVault(vault, vaultKey, PolymarketRelayResolver.Outcome.YES_WIN);
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        uint256 b0 = usdc.balanceOf(bot0);
        vm.prank(bot0); pv.claim();
        assertGe(usdc.balanceOf(bot0) - b0, DEPOSIT, "bot0 YES winner >= principal");

        uint256 b1 = usdc.balanceOf(bot1);
        vm.prank(bot1); pv.claim();
        assertGe(usdc.balanceOf(bot1) - b1, DEPOSIT, "bot1 YES winner >= principal");

        uint256 b2 = usdc.balanceOf(bot2);
        vm.prank(bot2); pv.claim();
        assertGe(usdc.balanceOf(bot2) - b2, DEPOSIT, "bot2 YES winner >= principal");

        uint256 b3 = usdc.balanceOf(bot3);
        vm.prank(bot3); pv.claim();
        assertEq(usdc.balanceOf(bot3) - b3, DEPOSIT, "bot3 NO loser = principal only");
    }

    // ─── Scenario 2: market-happy-path-no ────────────────────────────────────

    function test_devpanel_02_happyPath_noWins() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("happy-no"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(bot0, vault, DEPOSIT, YES);
        _deposit(bot1, vault, DEPOSIT, NO);
        _deposit(bot2, vault, DEPOSIT, NO);
        _deposit(bot3, vault, DEPOSIT, NO);

        _resolveVault(vault, vaultKey, PolymarketRelayResolver.Outcome.NO_WIN);
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        uint256 b0 = usdc.balanceOf(bot0);
        vm.prank(bot0); pv.claim();
        assertEq(usdc.balanceOf(bot0) - b0, DEPOSIT, "bot0 YES loser = principal only");

        uint256 b1 = usdc.balanceOf(bot1);
        vm.prank(bot1); pv.claim();
        assertGe(usdc.balanceOf(bot1) - b1, DEPOSIT, "bot1 NO winner >= principal");

        uint256 b2 = usdc.balanceOf(bot2);
        vm.prank(bot2); pv.claim();
        assertGe(usdc.balanceOf(bot2) - b2, DEPOSIT, "bot2 NO winner >= principal");

        uint256 b3 = usdc.balanceOf(bot3);
        vm.prank(bot3); pv.claim();
        assertGe(usdc.balanceOf(bot3) - b3, DEPOSIT, "bot3 NO winner >= principal");
    }

    // ─── Scenario 3: market-early-withdrawal ─────────────────────────────────

    function test_devpanel_03_earlyWithdrawal() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("early-out"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(bot0, vault, 200e6, YES);
        _deposit(bot1, vault, 200e6, YES);
        _deposit(bot2, vault, 200e6, YES);

        // bot0 withdraws early
        vm.warp(block.timestamp + 5);
        vm.prank(bot0);
        pv.withdrawEarly();

        ProbabilityVaultV2.UserPosition memory pos0 = pv.userPosition(bot0);
        assertTrue(pos0.withdrawnEarly, "bot0 withdrawnEarly=true");

        _resolveVault(vault, vaultKey, PolymarketRelayResolver.Outcome.YES_WIN);

        // bot0 already withdrew — claim reverts
        vm.prank(bot0);
        vm.expectRevert();
        pv.claim();

        // bot1 and bot2 claim — both get at least principal
        uint256 b1 = usdc.balanceOf(bot1);
        vm.prank(bot1); pv.claim();
        assertGe(usdc.balanceOf(bot1) - b1, 200e6, "bot1 gets >= principal");

        uint256 b2 = usdc.balanceOf(bot2);
        vm.prank(bot2); pv.claim();
        assertGe(usdc.balanceOf(bot2) - b2, 200e6, "bot2 gets >= principal");
    }

    // ─── Scenario 4: market-cancel-imbalance ─────────────────────────────────

    function test_devpanel_04_cancelImbalance() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("imbalance"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        // All YES — 100% one-sided, triggers CANCEL_MINORITY_PCT=5% guard
        _deposit(bot0, vault, DEPOSIT, YES);
        _deposit(bot1, vault, DEPOSIT, YES);
        _deposit(bot2, vault, DEPOSIT, YES);
        _deposit(bot3, vault, DEPOSIT, YES);
        _deposit(bot4, vault, DEPOSIT, YES);

        vm.warp(uint256(pv.joinEnd()) + 1);
        vm.warp(uint256(pv.polymarketEndDate()) + 12 hours + 1);
        resolver.propose(vaultKey, PolymarketRelayResolver.Outcome.AMBIGUOUS);
        vm.warp(uint256(pv.resolveStart()) + 1);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        uint256 b0 = usdc.balanceOf(bot0); vm.prank(bot0); pv.claim();
        assertEq(usdc.balanceOf(bot0) - b0, DEPOSIT, "bot0 refunded");
        uint256 b1 = usdc.balanceOf(bot1); vm.prank(bot1); pv.claim();
        assertEq(usdc.balanceOf(bot1) - b1, DEPOSIT, "bot1 refunded");
        uint256 b2 = usdc.balanceOf(bot2); vm.prank(bot2); pv.claim();
        assertEq(usdc.balanceOf(bot2) - b2, DEPOSIT, "bot2 refunded");
        uint256 b3 = usdc.balanceOf(bot3); vm.prank(bot3); pv.claim();
        assertEq(usdc.balanceOf(bot3) - b3, DEPOSIT, "bot3 refunded");
        uint256 b4 = usdc.balanceOf(bot4); vm.prank(bot4); pv.claim();
        assertEq(usdc.balanceOf(bot4) - b4, DEPOSIT, "bot4 refunded");
    }

    // ─── Scenario 5: market-cancel-timeout ───────────────────────────────────

    function test_devpanel_05_cancelTimeout() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("timeout"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(bot0, vault, DEPOSIT, YES);
        _deposit(bot1, vault, DEPOSIT, NO);
        _deposit(bot2, vault, DEPOSIT, YES);

        // Nobody proposes — warp past 7-day SETTLEMENT_TIMEOUT from polyEnd
        vm.warp(uint256(pv.polymarketEndDate()) + 7 days + 1);

        resolver.forceTimeoutCancel(vaultKey);

        // Vault resolveContest reads CANCELLED
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.CANCELLED));

        uint256 b0 = usdc.balanceOf(bot0); vm.prank(bot0); pv.claim();
        assertEq(usdc.balanceOf(bot0) - b0, DEPOSIT, "bot0 refunded on timeout");
        uint256 b1 = usdc.balanceOf(bot1); vm.prank(bot1); pv.claim();
        assertEq(usdc.balanceOf(bot1) - b1, DEPOSIT, "bot1 refunded on timeout");
        uint256 b2 = usdc.balanceOf(bot2); vm.prank(bot2); pv.claim();
        assertEq(usdc.balanceOf(bot2) - b2, DEPOSIT, "bot2 refunded on timeout");
    }

    // ─── Scenario 6: market-honest-challenge ─────────────────────────────────

    function test_devpanel_06_honestChallenge() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("dispute"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(bot0, vault, DEPOSIT, YES);
        _deposit(bot1, vault, DEPOSIT, YES);
        _deposit(bot2, vault, DEPOSIT, YES);
        _deposit(bot3, vault, DEPOSIT, NO);

        vm.warp(uint256(pv.joinEnd()) + 1);
        _injectYield(10e6);
        vm.warp(uint256(pv.polymarketEndDate()) + 12 hours + 1);

        // Owner proposes WRONG outcome: NO_WIN
        resolver.propose(vaultKey, PolymarketRelayResolver.Outcome.NO_WIN);

        // challenger disputes with correct YES_WIN
        address challenger = address(0x999);
        identityRegistry.setTier(challenger, 2);
        uint96 bond = resolver.requiredBondFor(vaultKey);
        usdc.mint(challenger, bond);
        vm.startPrank(challenger);
        usdc.approve(address(resolver), bond);
        resolver.challenge(vaultKey, PolymarketRelayResolver.Outcome.YES_WIN);
        vm.stopPrank();

        uint256 chalBefore = usdc.balanceOf(challenger);

        // Admin: challenger was honest → bond refunded, outcome = YES_WIN
        resolver.finalizeAfterDispute(
            vaultKey,
            PolymarketRelayResolver.Outcome.YES_WIN,
            true,
            treasury
        );
        assertGe(usdc.balanceOf(challenger), chalBefore, "challenger bond refunded");

        // Vault resolves with YES_WIN
        vm.warp(uint256(pv.resolveStart()) + 1);
        pv.resolveContest();
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        uint256 b0 = usdc.balanceOf(bot0); vm.prank(bot0); pv.claim();
        assertGe(usdc.balanceOf(bot0) - b0, DEPOSIT, "bot0 YES winner");
        uint256 b1 = usdc.balanceOf(bot1); vm.prank(bot1); pv.claim();
        assertGe(usdc.balanceOf(bot1) - b1, DEPOSIT, "bot1 YES winner");
        uint256 b2 = usdc.balanceOf(bot2); vm.prank(bot2); pv.claim();
        assertGe(usdc.balanceOf(bot2) - b2, DEPOSIT, "bot2 YES winner");

        uint256 b3 = usdc.balanceOf(bot3); vm.prank(bot3); pv.claim();
        assertEq(usdc.balanceOf(bot3) - b3, DEPOSIT, "bot3 NO loser = principal only");
    }

    // ─── Scenario 7: market-swap-sides ───────────────────────────────────────

    function test_devpanel_07_swapSides() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("swap"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        _deposit(bot0, vault, 200e6, YES);
        _deposit(bot1, vault, 200e6, YES);
        _deposit(bot2, vault, 200e6, YES);
        _deposit(bot3, vault, 200e6, YES);

        uint256 preYes = uint256(pv.totalYesStake());
        assertEq(preYes, 800e6, "800 YES pre-swap");
        assertEq(uint256(pv.totalNoStake()), 0, "0 NO pre-swap");

        vm.warp(block.timestamp + 5);

        // bot1 swaps half to NO
        ProbabilityVaultV2.UserPosition memory pos1 = pv.userPosition(bot1);
        uint256 half1 = uint256(pos1.yesStake) / 2;
        vm.prank(bot1); pv.swap(half1, NO);

        // bot2 swaps half to NO
        ProbabilityVaultV2.UserPosition memory pos2 = pv.userPosition(bot2);
        uint256 half2 = uint256(pos2.yesStake) / 2;
        vm.prank(bot2); pv.swap(half2, NO);

        assertLt(uint256(pv.totalYesStake()), preYes, "YES decreased after swap");
        assertGt(uint256(pv.totalNoStake()),  0,      "NO > 0 after swap");
        assertGt(pv.totalAccruedSwapFees(),   0,      "swap fees accrued");

        _resolveVault(vault, vaultKey, PolymarketRelayResolver.Outcome.YES_WIN);
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // All 4 bots claim successfully
        vm.prank(bot0); pv.claim();
        vm.prank(bot1); pv.claim();
        vm.prank(bot2); pv.claim();
        vm.prank(bot3); pv.claim();
    }

    // ─── Scenario 8: market-balance-check ────────────────────────────────────

    function test_devpanel_08_balanceConservation() public {
        (address vault, bytes32 vaultKey) = _createVault(keccak256("audit"));
        ProbabilityVaultV2 pv = ProbabilityVaultV2(vault);

        uint256[6] memory amounts = [uint256(100e6), 250e6, 75e6, 150e6, 200e6, 50e6];
        bytes32[6] memory sides   = [YES, YES, YES, NO, NO, YES];
        address[6] memory bots    = [bot0, bot1, bot2, bot3, bot4, bot5];

        // Ensure bot5 has enough tier and USDC
        identityRegistry.setTier(bot5, 2);
        usdc.mint(bot5, 10_000e6);

        uint256 totalDeposited;
        for (uint256 i = 0; i < 6; i++) {
            _deposit(bots[i], vault, amounts[i], sides[i]);
            totalDeposited += amounts[i];
        }

        uint256[6] memory pre;
        for (uint256 i = 0; i < 6; i++) {
            pre[i] = usdc.balanceOf(bots[i]);
        }

        _resolveVault(vault, vaultKey, PolymarketRelayResolver.Outcome.YES_WIN);
        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        for (uint256 i = 0; i < 6; i++) {
            vm.prank(bots[i]);
            pv.claim();
        }

        uint256 totalReturned;
        for (uint256 i = 0; i < 6; i++) {
            totalReturned += usdc.balanceOf(bots[i]) - pre[i];
        }

        uint256 vaultBal = usdc.balanceOf(vault);

        assertGe(
            totalReturned + vaultBal,
            totalDeposited,
            "Balance conservation: returned + vault_residue >= deposited"
        );
        assertLe(vaultBal, 1e6, "Vault near-empty after all claims");
    }
}
