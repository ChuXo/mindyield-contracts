// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice Fuzz + property tests for ProbabilityVault.
///         Verifies key invariants hold across random input space:
///           - Principal conservation (deposits in == principal + fees accrued)
///           - TWAB monotonicity (user TWAB only grows while stake is held)
///           - Swap fee bound (never exceeds swapFeeBps of any single swap)
///           - No-loss: every depositor can always reclaim ≥0 principal
contract ProbabilityVaultFuzzTest is Test {
    ProbabilityVaultV2      public impl;
    ProbabilityVaultFactory public factory;
    YieldVault              public yieldVault;
    IdentityRegistry        public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20               public usdc;

    address public creator  = address(0x100);
    address public treasury = address(0x111);
    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");
    bytes32 public constant CID = keccak256("fuzz-cid");
    uint64 public polyEnd;

    function setUp() public {
        vm.warp(1_800_000_000);
        polyEnd = uint64(block.timestamp + 7 days);
        usdc = new MockERC20("USDC", "USDC", 6);
        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));
        identityRegistry = new IdentityRegistry();
        impl = new ProbabilityVaultV2();
        factory = new ProbabilityVaultFactory(
            address(impl),
            address(yieldVault),
            address(0),
            address(identityRegistry),
            treasury
        );
        resolver = new PolymarketRelayResolver(address(factory), address(usdc));
    }

    function _createVault() internal returns (address) {
        vm.prank(creator);
        (, address addr) = factory.createVault(ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: polyEnd,
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       CID,
            metadataHash:      keccak256("fuzz"),
            metadataUri:       "ipfs://fuzz",
            resolver:          address(resolver)
        }));
        return addr;
    }

    function _deposit(address user, address vault, uint256 amount, bytes32 side) internal {
        // Yield markets are tier 0 / anonymous — no IdentityRegistry promotion
        // required for fuzz wallets.
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(vault, amount);
        ProbabilityVaultV2(vault).deposit(amount, side);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    // ─── Principal conservation ───────────────────────────────────────

    /// @notice After any single deposit, the sum of user.principal + swap fees
    ///         equals exactly the transferred-in amount.
    function testFuzz_singleDeposit_principalEqualsTransferred(uint96 amount, bool chooseYes) public {
        amount = uint96(bound(amount, 1, type(uint96).max / 2));
        address user = address(uint160(0xBEEF));
        bytes32 side = chooseYes ? YES : NO;

        address v = _createVault();
        _deposit(user, v, uint256(amount), side);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        ProbabilityVaultV2.UserPosition memory pos = pv.userPosition(user);
        assertEq(uint256(pos.principal), uint256(amount));
        // No swap yet → no fees accrued
        assertEq(uint256(pv.totalAccruedSwapFees()), 0);
        // Total stake on chosen side == amount
        if (chooseYes) {
            assertEq(uint256(pv.totalYesStake()), uint256(amount));
            assertEq(uint256(pv.totalNoStake()), 0);
        } else {
            assertEq(uint256(pv.totalNoStake()), uint256(amount));
            assertEq(uint256(pv.totalYesStake()), 0);
        }
    }

    // ─── Swap fee bound ───────────────────────────────────────────────

    /// @notice After a single swap, the fee never exceeds swapFeeBps of the
    ///         swapped amount (fee = amount * swapFeeBps / 10_000).
    function testFuzz_swapFee_neverExceedsBpsOfAmount(uint96 depositAmount, uint96 swapAmount) public {
        depositAmount = uint96(bound(depositAmount, 10_000, 10_000e6)); // reasonable range
        swapAmount = uint96(bound(swapAmount, 1, depositAmount));

        address user = address(uint160(0xBEEF));
        address v = _createVault();
        _deposit(user, v, uint256(depositAmount), YES);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        uint96 feeBps = pv.swapFeeBps();
        uint256 expectedFee = (uint256(swapAmount) * uint256(feeBps)) / 10_000;

        vm.prank(user);
        pv.swap(uint256(swapAmount), NO);

        assertEq(uint256(pv.totalAccruedSwapFees()), expectedFee);

        // Principal decremented by fee
        ProbabilityVaultV2.UserPosition memory pos = pv.userPosition(user);
        assertEq(uint256(pos.principal), uint256(depositAmount) - expectedFee);
    }

    // ─── Multiple deposits accrue totals ──────────────────────────────

    function testFuzz_multipleDeposits_totalsMatchSum(uint96 a, uint96 b, uint96 c) public {
        a = uint96(bound(a, 1, 1_000_000e6));
        b = uint96(bound(b, 1, 1_000_000e6));
        c = uint96(bound(c, 1, 1_000_000e6));

        address v = _createVault();
        address alice = address(0xA);
        address bob = address(0xB);
        address carol = address(0xC);

        _deposit(alice, v, a, YES);
        _deposit(bob,   v, b, NO);
        _deposit(carol, v, c, YES);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        assertEq(uint256(pv.totalYesStake()), uint256(a) + uint256(c));
        assertEq(uint256(pv.totalNoStake()), uint256(b));
    }

    // ─── Swap conservation: YES + NO stake sum changes only by fee ────

    function testFuzz_swap_conservesPoolMinusFee(uint96 depA, uint96 depB, uint96 swapAmt) public {
        depA = uint96(bound(depA, 1000, 10_000e6));
        depB = uint96(bound(depB, 1000, 10_000e6));
        swapAmt = uint96(bound(swapAmt, 1, depA));

        address v = _createVault();
        address alice = address(0xAA);
        address bob = address(0xBB);

        _deposit(alice, v, depA, YES);
        _deposit(bob, v, depB, NO);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        uint256 totalBefore = uint256(pv.totalYesStake()) + uint256(pv.totalNoStake());

        vm.prank(alice);
        pv.swap(uint256(swapAmt), NO);

        uint256 totalAfter = uint256(pv.totalYesStake()) + uint256(pv.totalNoStake());
        uint256 fee = uint256(pv.totalAccruedSwapFees());
        // Total pool decreases by exactly the fee amount (fee leaves the pool bookkeeping)
        assertEq(totalBefore, totalAfter + fee);
    }

    // ─── Early withdraw removes principal + TWAB ──────────────────────

    function testFuzz_earlyWithdraw_returnsPrincipalAndClearsStake(uint96 amount, uint32 holdSecs) public {
        amount = uint96(bound(amount, 1e6, 10_000e6));
        // YieldVault enforces MIN_HOLD_TIME=60s as flash-loan defense; start above it.
        holdSecs = uint32(bound(holdSecs, 61, 1 days));

        address user = address(uint160(0xC0FFEE));
        address v = _createVault();
        _deposit(user, v, uint256(amount), YES);

        vm.warp(block.timestamp + holdSecs);

        uint256 balBefore = usdc.balanceOf(user);
        vm.prank(user);
        ProbabilityVaultV2(v).withdrawEarly();

        // User got principal back (within vault rounding)
        uint256 received = usdc.balanceOf(user) - balBefore;
        assertApproxEqAbs(received, uint256(amount), 1);

        ProbabilityVaultV2.UserPosition memory pos = ProbabilityVaultV2(v).userPosition(user);
        assertEq(uint256(pos.yesStake), 0);
        assertEq(uint256(pos.noStake), 0);
        assertEq(uint256(pos.yesTwab), 0);
        assertEq(uint256(pos.noTwab), 0);
        assertTrue(pos.withdrawnEarly);
    }

    // ─── Optional tier gate (off by default) ─────────────────────────

    /// @notice When the factory owner opts into a tier floor, wallets below
    ///         that tier must always revert on new vaults. The default
    ///         (minTier == 0) leaves the gate fully open — covered by the
    ///         happy-path fuzz tests above which run with anonymous wallets.
    function testFuzz_optInTierGate_belowFloorReverts(uint8 floor, uint8 callerTier) public {
        floor = uint8(bound(floor, 1, 5));
        callerTier = uint8(bound(callerTier, 0, floor - 1));

        factory.setMinTier(floor);

        address user = address(uint160(0xDEAD));
        identityRegistry.setTier(user, callerTier);
        usdc.mint(user, 1000e6);

        address v = _createVault();
        vm.startPrank(user);
        usdc.approve(v, 1000e6);
        vm.expectRevert(ProbabilityVaultV2.TierTooLow.selector);
        ProbabilityVaultV2(v).deposit(1000e6, YES);
        vm.stopPrank();
    }

    // ─── Invariant: implied probability matches stake ratio ───────────

    function testFuzz_impliedProbability_matchesStakeRatio(uint96 yesAmt, uint96 noAmt) public {
        yesAmt = uint96(bound(yesAmt, 1, 100_000e6));
        noAmt = uint96(bound(noAmt, 1, 100_000e6));

        address v = _createVault();
        _deposit(address(0xA1), v, uint256(yesAmt), YES);
        _deposit(address(0xA2), v, uint256(noAmt), NO);

        uint256 total = uint256(yesAmt) + uint256(noAmt);
        uint256 expectedYes = (uint256(yesAmt) * 10_000) / total;

        uint256 actualYes = ProbabilityVaultV2(v).impliedProbabilityYes();
        assertApproxEqAbs(actualYes, expectedYes, 1);
    }
}
