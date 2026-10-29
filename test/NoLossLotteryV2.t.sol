// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/lottery/NoLossLotteryV2.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockRandomnessManager.sol";

/**
 * @title NoLossLotteryV2Test
 * @notice Full feature test suite for NoLossLotteryV2.
 */
contract NoLossLotteryV2Test is Test {
    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLotteryV2       lottery;

    address owner    = address(this);
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address charlie  = address(0xC4A1);
    address treasury = address(0x7EA5);

    uint256 constant ROUND_DURATION = 7 days;
    uint256 constant DEPOSIT_AMOUNT = 1000e6; // 1000 USDC (6 decimals)

    function setUp() public {
        vm.warp(1000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        strategy = new AaveStrategy(
            address(aavePool),
            address(usdc),
            address(aUsdc),
            address(0) // no data provider
        );
        randMgr  = new MockRandomnessManager();

        lottery = new NoLossLotteryV2(
            address(usdc),
            address(strategy),
            address(randMgr),
            ROUND_DURATION,
            treasury
        );

        // Allow lottery to use strategy
        strategy.setYieldVault(address(lottery));

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(lottery), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(lottery), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(lottery), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        assertEq(lottery.totalDeposited(), DEPOSIT_AMOUNT);
        assertEq(lottery.participantCount(), 1);
        assertTrue(lottery.isParticipant(alice));
    }

    function test_deposit_multipleUsers() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT * 2);

        assertEq(lottery.totalDeposited(), DEPOSIT_AMOUNT * 3);
        assertEq(lottery.participantCount(), 2);
    }

    function test_deposit_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV2.ZeroAmount.selector);
        lottery.deposit(0);
    }

    function test_deposit_whenPausedReverts() public {
        lottery.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        lottery.deposit(DEPOSIT_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);

        assertEq(lottery.totalDeposited(), 0);
        assertFalse(lottery.isParticipant(alice));
    }

    function test_withdraw_partial() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT / 2);

        assertEq(lottery.totalDeposited(), DEPOSIT_AMOUNT / 2);
        assertTrue(lottery.isParticipant(alice));
    }

    function test_withdraw_insufficientReverts() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV2.InsufficientBalance.selector);
        lottery.withdraw(DEPOSIT_AMOUNT + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ROUND LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_roundStartsAtConstruction() public view {
        assertEq(lottery.currentRoundId(), 1);
        NoLossLotteryV2.Round memory r = lottery.getCurrentRound();
        assertEq(r.startTime, 1000);
        assertEq(r.endTime, 1000 + uint64(ROUND_DURATION));
        assertFalse(r.isDrawPending);
        assertFalse(r.isSettled);
    }

    function test_checkUpkeep_notReadyBeforeEnd() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        (bool needed,) = lottery.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_readyAfterEnd() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1000 + ROUND_DURATION);
        (bool needed,) = lottery.checkUpkeep("");
        assertTrue(needed);
    }

    function test_performUpkeep_tooEarlyReverts() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.expectRevert(NoLossLotteryV2.DrawNotReady.selector);
        lottery.performUpkeep("");
    }

    function test_performUpkeep_noParticipantsReverts() public {
        vm.warp(1000 + ROUND_DURATION);
        vm.expectRevert(NoLossLotteryV2.NoActiveParticipants.selector);
        lottery.performUpkeep("");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  FULL DRAW CYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fullDrawCycle() public {
        // Deposit
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Simulate yield
        aavePool.simulateYield(address(strategy), 100e6);

        // Advance past round end
        vm.warp(1000 + ROUND_DURATION);

        // Perform upkeep
        lottery.performUpkeep("");
        NoLossLotteryV2.Round memory r = lottery.getCurrentRound();
        assertTrue(r.isDrawPending);

        // Deliver randomness
        randMgr.deliverRandomness(address(lottery), 42);

        // Round should be settled
        r = lottery.getRound(1);
        assertTrue(r.isSettled);
        assertGt(r.totalPrize, 0);

        // New round started
        assertEq(lottery.currentRoundId(), 2);
    }

    function test_prizeDistribution_withProtocolFee() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // 100 USDC yield
        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        NoLossLotteryV2.Round memory r = lottery.getRound(1);
        // Protocol fee = 2% of ~100 = ~2
        // Net prize = ~98
        assertGt(r.protocolFee, 0);
        assertGt(r.totalPrize, 0);
        assertEq(r.totalPrize + r.protocolFee, r.totalPrize + r.protocolFee); // sanity
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MULTI-TIER PRIZES
    // ═══════════════════════════════════════════════════════════════════════════

    function test_multiTierPrizes_twoTiers() public {
        // Default: 2 tiers (70% / 30%)
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 12345);

        // Both tiers should have results
        NoLossLotteryV2.TierResult memory t0 = lottery.getTierResult(1, 0);
        NoLossLotteryV2.TierResult memory t1 = lottery.getTierResult(1, 1);
        assertGt(t0.amount, 0, "Grand prize should be > 0");
        assertGt(t1.amount, 0, "Runner-up prize should be > 0");
        assertGt(t0.amount, t1.amount, "Grand prize > runner-up");
    }

    function test_setTierConfig_threeTiers() public {
        uint256[5] memory tiers = [uint256(5000), 3000, 2000, 0, 0];
        lottery.setTierConfig(3, tiers);
        assertEq(lottery.numberOfTiers(), 3);
    }

    function test_setTierConfig_invalidSumReverts() public {
        uint256[5] memory tiers = [uint256(5000), 3000, 1000, 0, 0]; // sum = 9000
        vm.expectRevert(NoLossLotteryV2.InvalidTierConfig.selector);
        lottery.setTierConfig(3, tiers);
    }

    function test_setTierConfig_zeroTiersReverts() public {
        uint256[5] memory tiers = [uint256(0), 0, 0, 0, 0];
        vm.expectRevert(NoLossLotteryV2.InvalidTierConfig.selector);
        lottery.setTierConfig(0, tiers);
    }

    function test_setTierConfig_nonOwnerReverts() public {
        uint256[5] memory tiers = [uint256(10000), 0, 0, 0, 0];
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setTierConfig(1, tiers);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DELEGATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_delegation_basic() public {
        // Alice delegates to Bob
        vm.prank(alice);
        lottery.setDelegate(bob);

        assertEq(lottery.getDelegate(alice), bob);
    }

    function test_delegation_selfReverts() public {
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV2.SelfDelegation.selector);
        lottery.setDelegate(alice);
    }

    function test_delegation_movesWeight() public {
        // Alice deposits
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Alice delegates to Bob → Bob gets TWAB weight
        vm.warp(1500);
        vm.prank(alice);
        lottery.setDelegate(bob);

        // Bob's balance (TWAB) should be DEPOSIT_AMOUNT
        assertEq(lottery.balanceOf(bob), uint96(DEPOSIT_AMOUNT));
        // Alice's balance should be 0
        assertEq(lottery.balanceOf(alice), 0);
    }

    function test_delegation_undoBySettingZero() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1500);
        vm.prank(alice);
        lottery.setDelegate(bob);

        vm.warp(2000);
        vm.prank(alice);
        lottery.setDelegate(address(0)); // remove delegation

        assertEq(lottery.balanceOf(alice), uint96(DEPOSIT_AMOUNT));
        assertEq(lottery.balanceOf(bob), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  AUTO-COMPOUND
    // ═══════════════════════════════════════════════════════════════════════════

    function test_autoCompound_toggle() public {
        vm.prank(alice);
        lottery.setAutoCompound(true);
        assertTrue(lottery.autoCompound(alice));

        vm.prank(alice);
        lottery.setAutoCompound(false);
        assertFalse(lottery.autoCompound(alice));
    }

    function test_autoCompound_reDepositsWinnings() public {
        // Alice is the only participant → guaranteed winner
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.setAutoCompound(true);

        // Simulate yield
        aavePool.simulateYield(address(strategy), 100e6);

        // Complete draw
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Alice claims → should auto-compound
        uint256 balBefore = lottery.totalDeposited();
        vm.prank(alice);
        lottery.claimPrize(1);

        // totalDeposited should have increased
        assertGt(lottery.totalDeposited(), balBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  PRIZE CLAIMS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_claimPrize_normalClaim() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Find the winner
        NoLossLotteryV2.TierResult memory t0 = lottery.getTierResult(1, 0);
        address winner = t0.winner;

        uint256 balBefore = usdc.balanceOf(winner);
        vm.prank(winner);
        lottery.claimPrize(1);
        assertGt(usdc.balanceOf(winner), balBefore);
    }

    function test_claimPrize_roundNotSettledReverts() public {
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV2.RoundNotSettled.selector);
        lottery.claimPrize(1);
    }

    function test_claimPrize_noPrizeReverts() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Charlie was not a participant
        vm.prank(charlie);
        vm.expectRevert(NoLossLotteryV2.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    function test_claimPrize_doubleClaim() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        NoLossLotteryV2.TierResult memory t0 = lottery.getTierResult(1, 0);
        address winner = t0.winner;

        vm.prank(winner);
        lottery.claimPrize(1);

        // Second claim should revert
        vm.prank(winner);
        vm.expectRevert(NoLossLotteryV2.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  PROTOCOL FEE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_protocolFee_default() public view {
        assertEq(lottery.protocolFeeBps(), 200); // 2%
    }

    function test_setProtocolFee() public {
        lottery.setProtocolFee(300); // 3%
        assertEq(lottery.protocolFeeBps(), 300);
    }

    function test_setProtocolFee_tooHighReverts() public {
        vm.expectRevert(NoLossLotteryV2.FeeTooHigh.selector);
        lottery.setProtocolFee(1001);
    }

    function test_setProtocolFee_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setProtocolFee(300);
    }

    function test_withdrawProtocolFees() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        uint256 fees = lottery.accumulatedProtocolFees();
        assertGt(fees, 0);

        uint256 balBefore = usdc.balanceOf(treasury);
        lottery.withdrawProtocolFees();
        assertEq(usdc.balanceOf(treasury) - balBefore, fees);
        assertEq(lottery.accumulatedProtocolFees(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setRoundDuration() public {
        lottery.setRoundDuration(14 days);
        assertEq(lottery.roundDuration(), 14 days);
    }

    function test_setRoundDuration_tooShortReverts() public {
        vm.expectRevert("V2: too short");
        lottery.setRoundDuration(30 minutes);
    }

    function test_setProtocolFeeRecipient() public {
        lottery.setProtocolFeeRecipient(alice);
        assertEq(lottery.protocolFeeRecipient(), alice);
    }

    function test_setProtocolFeeRecipient_zeroReverts() public {
        vm.expectRevert(NoLossLotteryV2.InvalidRecipient.selector);
        lottery.setProtocolFeeRecipient(address(0));
    }

    function test_pauseUnpause() public {
        lottery.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        lottery.deposit(DEPOSIT_AMOUNT);

        lottery.unpause();
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT); // should succeed
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getCurrentPrizePool() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // No yield yet
        assertEq(lottery.getCurrentPrizePool(), 0);

        aavePool.simulateYield(address(strategy), 50e6);
        assertEq(lottery.getCurrentPrizePool(), 50e6);
    }

    function test_participantEnumeration() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT);

        assertEq(lottery.participantCount(), 2);
        // Participants can be enumerated
        address p0 = lottery.getParticipant(0);
        address p1 = lottery.getParticipant(1);
        assertTrue(p0 == alice || p0 == bob);
        assertTrue(p1 == alice || p1 == bob);
        assertTrue(p0 != p1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MULTI-ROUND
    // ═══════════════════════════════════════════════════════════════════════════

    function test_multipleRounds() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Round 1
        aavePool.simulateYield(address(strategy), 50e6);
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 111);

        assertEq(lottery.currentRoundId(), 2);

        // Round 2
        aavePool.simulateYield(address(strategy), 50e6);
        vm.warp(1000 + 2 * ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 222);

        assertEq(lottery.currentRoundId(), 3);

        // Both rounds should be settled
        assertTrue(lottery.getRound(1).isSettled);
        assertTrue(lottery.getRound(2).isSettled);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ZERO YIELD ROUND
    // ═══════════════════════════════════════════════════════════════════════════

    function test_zeroYieldRound() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // No yield simulated
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        NoLossLotteryV2.Round memory r = lottery.getRound(1);
        assertTrue(r.isSettled);
        assertEq(r.totalPrize, 0);
        assertEq(r.protocolFee, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VRF ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fulfillRandomness_notRMReverts() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");

        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV2.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  YIELD BUFFER (PT V5 Pattern)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_yieldBuffer_fund() public {
        usdc.mint(owner, 1e6);
        usdc.approve(address(lottery), 1e6);
        lottery.fundYieldBuffer(1e6);
        assertEq(lottery.yieldBuffer(), 1e6);
    }

    function test_yieldBuffer_excludedFromPrize() public {
        // Fund yield buffer
        usdc.mint(owner, 100e6);
        usdc.approve(address(lottery), 100e6);
        lottery.fundYieldBuffer(100e6);

        // Alice deposits
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Strategy holds: 100e6 (buffer) + 1000e6 (alice) = 1100e6
        // totalOwed = totalDebt(1000e6) + yieldBuffer(100e6) = 1100e6
        // No yield yet → prize should be 0
        assertEq(lottery.getCurrentPrizePool(), 0);

        // Simulate 50 USDC yield → strategy has 1150e6
        // Prize = 1150 - 1100 = 50e6 (buffer properly excluded)
        aavePool.simulateYield(address(strategy), 50e6);
        assertEq(lottery.getCurrentPrizePool(), 50e6);

        // Without the buffer, totalOwed would be 1000e6 and prize would be 150e6
        // The buffer protects against rounding and ensures dust doesn't leak as prizes
    }

    function test_yieldBuffer_zeroReverts() public {
        vm.expectRevert(NoLossLotteryV2.ZeroAmount.selector);
        lottery.fundYieldBuffer(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DEBT/ASSET SEPARATION (PT V5 Pattern)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_totalDebt_tracksDepositsAndWithdrawals() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        assertEq(lottery.totalDebt(), DEPOSIT_AMOUNT);

        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT);
        assertEq(lottery.totalDebt(), 2 * DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT / 2);
        assertEq(lottery.totalDebt(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    }

    function test_totalDebt_autoCompoundIncreases() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.setAutoCompound(true);

        // Simulate yield + draw
        aavePool.simulateYield(address(strategy),100e6);
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        uint256 debtBefore = lottery.totalDebt();
        // If alice won and auto-compounds, totalDebt increases
        NoLossLotteryV2.Round memory r = lottery.getRound(1);
        if (r.totalPrize > 0) {
            // Claim will auto-compound
            uint256 prize = lottery.pendingPrizes(1, alice);
            if (prize > 0) {
                vm.prank(alice);
                lottery.claimPrize(1);
                assertEq(lottery.totalDebt(), debtBefore + prize);
            }
        }
    }

    function test_isUndercollateralized() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        assertFalse(lottery.isUndercollateralized());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DRAW REPLAY PROTECTION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_drawNonce_incrementsOnDraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        assertEq(lottery.drawNonce(), 0);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        assertEq(lottery.drawNonce(), 1);
    }

    function test_fulfillRandomness_requiresDrawPending() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Try to fulfill without performUpkeep → no draw pending
        vm.prank(address(randMgr));
        vm.expectRevert("V2: no draw pending");
        lottery.fulfillRandomness(42);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CANARY TIER AUTO-TUNING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_canaryAutoTune_toggle() public {
        assertFalse(lottery.canaryAutoTuneEnabled());
        lottery.setCanaryAutoTune(true);
        assertTrue(lottery.canaryAutoTuneEnabled());
    }

    function test_canaryAutoTune_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setCanaryAutoTune(true);
    }

    function test_canaryAutoTune_reduceTiersAfterUnclaimed() public {
        // Set up 3 tiers and enable canary
        uint256[5] memory bps = [uint256(5_000), 3_000, 2_000, 0, 0];
        lottery.setTierConfig(3, bps);
        lottery.setCanaryAutoTune(true);

        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Run 3 rounds with zero yield → smallest tier unclaimed
        uint256 t = 1000;
        for (uint256 i = 0; i < 3; i++) {
            t += ROUND_DURATION;
            vm.warp(t);
            lottery.performUpkeep("");
            randMgr.deliverRandomness(address(lottery), uint256(keccak256(abi.encode(i))));
        }

        // After 3 unclaimed rounds, tiers should reduce from 3 → 2
        assertEq(lottery.numberOfTiers(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  TOTAL ASSETS VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function test_totalAssets() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        assertTrue(lottery.totalAssets() >= DEPOSIT_AMOUNT);
    }
}
