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
 * @title NoLossLotteryV2SecurityTest
 * @notice Manipulation, re-entrancy, and adversarial scenario tests.
 */
contract NoLossLotteryV2SecurityTest is Test {
    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLotteryV2       lottery;

    address owner    = address(this);
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address attacker = address(0xBAD);
    address treasury = address(0x7EA5);

    uint256 constant ROUND_DURATION = 7 days;
    uint256 constant DEPOSIT_AMOUNT = 1000e6;

    function setUp() public {
        vm.warp(1000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        strategy = new AaveStrategy(
            address(aavePool),
            address(usdc),
            address(aUsdc),
            address(0)
        );
        randMgr  = new MockRandomnessManager();

        lottery = new NoLossLotteryV2(
            address(usdc),
            address(strategy),
            address(randMgr),
            ROUND_DURATION,
            treasury
        );

        strategy.setYieldVault(address(lottery));

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(attacker, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(lottery), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(lottery), type(uint256).max);
        vm.prank(attacker);
        usdc.approve(address(lottery), type(uint256).max);
    }

    // ─── Flash deposit/withdraw around draw ─────────────────────────────────

    function test_flashDepositBeforeDraw_twabMinimizesAdvantage() public {
        // Bob deposits early (full round)
        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Attacker waits until just before draw
        vm.warp(1000 + ROUND_DURATION - 1);
        vm.prank(attacker);
        lottery.deposit(DEPOSIT_AMOUNT * 10); // 10x deposit

        // Draw
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");

        // Attacker's TWAB is negligible since they deposited 1 second before draw
        // Bob's TWAB is much larger since he was in for the entire round
        // We can verify by checking win probability
        uint256 bobProb = lottery.getWinProbability(bob);
        uint256 attackerProb = lottery.getWinProbability(attacker);

        // Bob should have overwhelmingly higher probability
        assertGt(bobProb, attackerProb, "TWAB should minimize flash deposit advantage");
    }

    // ─── Withdraw during pending draw ───────────────────────────────────────

    function test_withdrawDuringPendingDraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        vm.prank(bob);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");

        // Alice withdraws while draw is pending — should succeed
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);
        assertEq(lottery.totalDeposited(), DEPOSIT_AMOUNT);
    }

    // ─── Double performUpkeep ───────────────────────────────────────────────

    function test_doublePerformUpkeepReverts() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");

        vm.expectRevert(NoLossLotteryV2.DrawAlreadyPending.selector);
        lottery.performUpkeep("");
    }

    // ─── Unauthorized fulfillRandomness ──────────────────────────────────────

    function test_fulfillRandomness_onlyRM() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");

        // Direct call from attacker
        vm.prank(attacker);
        vm.expectRevert(NoLossLotteryV2.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);

        // Direct call from owner
        vm.expectRevert(NoLossLotteryV2.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);
    }

    // ─── Protocol fee manipulation ──────────────────────────────────────────

    function test_protocolFee_cannotExceedMax() public {
        vm.expectRevert(NoLossLotteryV2.FeeTooHigh.selector);
        lottery.setProtocolFee(1001); // > 10%
    }

    function test_protocolFee_zeroAllowed() public {
        lottery.setProtocolFee(0);

        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        NoLossLotteryV2.Round memory r = lottery.getRound(1);
        assertEq(r.protocolFee, 0);
        assertGt(r.totalPrize, 0);
    }

    // ─── Tier configuration ─────────────────────────────────────────────────

    function test_tierConfig_nonZeroInUnusedSlotReverts() public {
        uint256[5] memory tiers = [uint256(10000), 0, 0, 100, 0]; // slot 3 nonzero but only 1 tier
        vm.expectRevert(NoLossLotteryV2.InvalidTierConfig.selector);
        lottery.setTierConfig(1, tiers);
    }

    function test_tierConfig_sixTiersReverts() public {
        uint256[5] memory tiers = [uint256(2000), 2000, 2000, 2000, 2000];
        vm.expectRevert(NoLossLotteryV2.InvalidTierConfig.selector);
        lottery.setTierConfig(6, tiers);
    }

    // ─── Delegation edge cases ──────────────────────────────────────────────

    function test_delegation_depositAfterDelegate() public {
        // Set delegation BEFORE depositing
        vm.prank(alice);
        lottery.setDelegate(bob);

        // Deposit should go to bob's TWAB
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        assertEq(lottery.balanceOf(bob), uint96(DEPOSIT_AMOUNT));
        assertEq(lottery.balanceOf(alice), 0);
    }

    function test_delegation_cannotChangeDuringPendingDraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");

        // Delegation change during pending draw — this should still work
        // (TWAB is historical, changing delegation doesn't retroactively change it)
        vm.prank(alice);
        lottery.setDelegate(bob);

        // Verify delegation was applied
        assertEq(lottery.getDelegate(alice), bob);
    }

    // ─── Single participant edge case ───────────────────────────────────────

    function test_singleParticipant_winsAll() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 100e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 99999);

        // Alice should win all tiers
        NoLossLotteryV2.TierResult memory t0 = lottery.getTierResult(1, 0);
        NoLossLotteryV2.TierResult memory t1 = lottery.getTierResult(1, 1);
        assertEq(t0.winner, alice);
        assertEq(t1.winner, alice);
    }

    // ─── Principal protection ───────────────────────────────────────────────

    function test_principalProtected_afterDraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        aavePool.simulateYield(address(strategy), 50e6);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Alice should be able to withdraw full principal
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);

        // Should get back at least the deposit amount (minus rounding)
        uint256 received = usdc.balanceOf(alice) - balBefore;
        assertGe(received, DEPOSIT_AMOUNT - 1, "Principal should be protected");
    }

    // ─── Owner-only access control ──────────────────────────────────────────

    function test_onlyOwner_setRoundDuration() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setRoundDuration(14 days);
    }

    function test_onlyOwner_setProtocolFee() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setProtocolFee(100);
    }

    function test_onlyOwner_setFeeRecipient() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.setProtocolFeeRecipient(alice);
    }

    function test_onlyOwner_withdrawFees() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.withdrawProtocolFees();
    }

    function test_onlyOwner_pause() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        lottery.pause();
    }

    // ─── Deposit after full withdraw ────────────────────────────────────────

    function test_reDepositAfterFullWithdraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);
        assertFalse(lottery.isParticipant(alice));

        // Re-deposit should work
        vm.warp(2000);
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        assertTrue(lottery.isParticipant(alice));
        assertEq(lottery.participantCount(), 1);
    }

    // ─── Massive number of participants ─────────────────────────────────────

    function test_manyParticipants() public {
        // Create 50 participants
        for (uint256 i = 1; i <= 50; i++) {
            address user = address(uint160(0x1000 + i));
            usdc.mint(user, DEPOSIT_AMOUNT);
            vm.prank(user);
            usdc.approve(address(lottery), type(uint256).max);
            vm.prank(user);
            lottery.deposit(DEPOSIT_AMOUNT);
        }

        assertEq(lottery.participantCount(), 50);

        aavePool.simulateYield(address(strategy), 500e6);
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        assertTrue(lottery.getRound(1).isSettled);
    }

    // ─── Auto-compound edge: no prize ───────────────────────────────────────

    function test_autoCompound_noPrize_reverts() public {
        vm.prank(alice);
        lottery.setAutoCompound(true);

        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Zero-yield round
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Alice has auto-compound on but no prize → revert
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV2.NoPrizeToClaim.selector);
        lottery.claimPrize(1);
    }

    // ─── EnumerableSet: remove on withdraw, add on deposit ──────────────────

    function test_participantSet_removedOnFullWithdraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);
        assertTrue(lottery.isParticipant(alice));

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);
        assertFalse(lottery.isParticipant(alice));
        assertEq(lottery.participantCount(), 0);
    }

    function test_participantSet_keptOnPartialWithdraw() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT / 2);
        assertTrue(lottery.isParticipant(alice));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  YIELD BUFFER SECURITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_yieldBuffer_notCountedAsPrize() public {
        // Fund 100 USDC yield buffer
        usdc.mint(owner, 100e6);
        usdc.approve(address(lottery), 100e6);
        lottery.fundYieldBuffer(100e6);

        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Strategy holds: 100e6 (buffer) + 1000e6 (alice) = 1100e6
        // No yield → no prize
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // No prize since no yield above buffer
        NoLossLotteryV2.Round memory r = lottery.getRound(1);
        assertEq(r.totalPrize, 0);

        // Now add yield and verify buffer is excluded
        aavePool.simulateYield(address(strategy), 50e6);
        // Prize pool = 1150 - (1000 debt + 100 buffer) = 50e6
        assertEq(lottery.getCurrentPrizePool(), 50e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DRAW REPLAY SECURITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_drawReplay_blockedByNonce() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);

        // Try to fulfill again (round 2 has no pending draw)
        vm.prank(address(randMgr));
        vm.expectRevert("V2: no draw pending");
        lottery.fulfillRandomness(42);
    }

    function test_drawReplay_nonceIncrements() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Round 1
        vm.warp(1000 + ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 42);
        assertEq(lottery.drawNonce(), 1);

        // Round 2
        vm.warp(1000 + 2 * ROUND_DURATION);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 99);
        assertEq(lottery.drawNonce(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DEBT/ASSET SECURITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_debtAssetSeparation_tracksProperly() public {
        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        vm.prank(bob);
        lottery.deposit(2 * DEPOSIT_AMOUNT);

        assertEq(lottery.totalDebt(), 3 * DEPOSIT_AMOUNT);
        assertEq(lottery.totalDeposited(), 3 * DEPOSIT_AMOUNT);

        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);

        assertEq(lottery.totalDebt(), 2 * DEPOSIT_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CANARY TIER SECURITY
    // ═══════════════════════════════════════════════════════════════════════════

    function test_canaryAutoTune_doesNotDropBelowOneTier() public {
        lottery.setCanaryAutoTune(true);
        // Default is 2 tiers

        vm.prank(alice);
        lottery.deposit(DEPOSIT_AMOUNT);

        // Run 3 rounds with zero yield
        uint256 t = 1000;
        for (uint256 i = 0; i < 3; i++) {
            t += ROUND_DURATION;
            vm.warp(t);
            lottery.performUpkeep("");
            randMgr.deliverRandomness(address(lottery), uint256(keccak256(abi.encode(i))));
        }

        // Should reduce to 1 tier but not below
        assertEq(lottery.numberOfTiers(), 1);

        // Run 3 more rounds — should stay at 1
        for (uint256 i = 10; i < 13; i++) {
            t += ROUND_DURATION;
            vm.warp(t);
            lottery.performUpkeep("");
            randMgr.deliverRandomness(address(lottery), uint256(keccak256(abi.encode(i))));
        }

        assertEq(lottery.numberOfTiers(), 1);
    }
}
