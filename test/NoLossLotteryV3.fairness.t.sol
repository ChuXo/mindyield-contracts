// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/lottery/NoLossLotteryV3.sol";
import "../src/lottery/LotteryReceiptToken.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockRandomnessManager.sol";

/**
 * @title NoLossLotteryV3 fairness + autonomy regression tests
 * @notice Locks in the three hardening fixes made for the redeploy:
 *
 *   Finding 1 (manipulation): winner odds are weighted by TWAB over the round
 *     window, NOT current balance — so a last-minute / during-draw whale deposit
 *     gets ~0 odds.
 *   Finding 3 (stuck): settlement is decoupled from the VRF callback. The
 *     callback (`fulfillRandomness`) is O(1); a permissionless `settleRound`
 *     does the work. Deposits are blocked while a draw is in flight.
 */
contract NoLossLotteryV3FairnessTest is Test {
    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLotteryV3       lottery;
    LotteryReceiptToken   receipt;

    address owner   = address(this);
    address alice   = address(0xA11CE);  // long-term, honest depositor
    address eve     = address(0xE5E);    // last-minute whale (attacker)
    address treasury = address(0x7EA5);

    uint256 constant ROUND_DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        strategy = new AaveStrategy(address(aavePool), address(usdc), address(aUsdc), address(0));
        randMgr  = new MockRandomnessManager();

        NoLossLotteryV3 impl = new NoLossLotteryV3();
        receipt = new LotteryReceiptToken("MindYield Weekly USDC", "myWeeklyUSDC", 6);
        lottery = NoLossLotteryV3(Clones.clone(address(impl)));

        // Single 100% tier → exactly one winner per round (simplest to reason about).
        uint256[5] memory tierBps = [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)];
        lottery.initialize(
            address(usdc), address(strategy), address(randMgr),
            ROUND_DURATION, treasury, 200, 1, tierBps, 0, address(receipt)
        );
        strategy.setYieldVault(address(lottery));
        receipt.transferOwnership(address(lottery));
        lottery.transferOwnership(owner);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(eve,   1_000_000e6);
        vm.prank(alice); usdc.approve(address(lottery), type(uint256).max);
        vm.prank(eve);   usdc.approve(address(lottery), type(uint256).max);
    }

    function _deposit(address u, uint256 a) internal { vm.prank(u); lottery.deposit(a); }

    // ───────────────────────────────────────────────────────────────────────────
    // Finding 1 — last-minute whale gets ~0 odds (TWAB, not current balance)
    // ───────────────────────────────────────────────────────────────────────────

    /// @notice A deposit made AT endTime has exactly zero TWAB over the round
    ///         window [start, endTime] → cannot win, no matter how large. Under
    ///         the old current-balance weighting eve (100×) would dominate.
    function test_fairness_depositAtEndTimeCannotWin() public {
        _deposit(alice, 1_000e6);                       // honest, present all round

        vm.warp(block.timestamp + ROUND_DURATION);      // now == endTime
        _deposit(eve, 100_000e6);                        // 100× whale, zero time-at-risk

        // eve's time-weighted odds over the elapsed window are zero
        assertEq(lottery.getWinProbability(eve), 0, "late whale must have ~0 TWAB odds");

        aavePool.simulateYield(address(strategy), 500e6);

        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), uint256(keccak256("any-word")));
        lottery.settleRound();

        // alice (the only one with TWAB over the round) wins regardless of the word.
        assertEq(lottery.getTierResult(1, 0).winner, alice, "TWAB winner must be the long-term depositor");
        assertEq(lottery.pendingPrizes(1, eve), 0, "whale must win nothing");
    }

    /// @notice Even a deposit late (but before endTime) yields odds far below a
    ///         full-round depositor's, despite a much larger balance.
    function test_fairness_lateDepositHasMuchLowerOdds() public {
        _deposit(alice, 1_000e6);
        // 90% through the round, eve deposits 50× alice's stake.
        vm.warp(block.timestamp + (ROUND_DURATION * 9) / 10);
        _deposit(eve, 50_000e6);
        // advance a touch so both have a positive window
        vm.warp(block.timestamp + 1 hours);

        uint256 pAlice = lottery.getWinProbability(alice);
        uint256 pEve   = lottery.getWinProbability(eve);
        // Time dominates balance: the full-round depositor still has the larger share.
        assertGt(pAlice, pEve, "long-term depositor must out-weigh a late whale");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Finding 3 — autonomy: O(1) callback + permissionless settle, deposit lock
    // ───────────────────────────────────────────────────────────────────────────

    function test_deposit_blockedWhileDrawPending() public {
        _deposit(alice, 1_000e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");                        // draw now pending

        vm.prank(eve);
        vm.expectRevert(NoLossLotteryV3.DepositDuringDraw.selector);
        lottery.deposit(1_000e6);
    }

    function test_fulfillRandomness_isO1_doesNotSettle() public {
        _deposit(alice, 1_000e6);
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");

        randMgr.deliverRandomness(address(lottery), 42);

        // Callback only stored the word — round NOT settled, still pending.
        assertTrue(lottery.roundRandomReady(1), "random word should be stored");
        NoLossLotteryV3.Round memory r = lottery.getRound(1);
        assertFalse(r.isSettled, "callback must not settle");
        assertTrue(r.isDrawPending, "still pending until settleRound");
    }

    function test_settleRound_revertsBeforeRandom_thenPermissionless() public {
        _deposit(alice, 1_000e6);
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");

        // No VRF word yet → cannot settle.
        vm.expectRevert(NoLossLotteryV3.RandomNotReady.selector);
        lottery.settleRound();

        randMgr.deliverRandomness(address(lottery), 7);

        // Permissionless: a random non-owner address can settle.
        vm.prank(eve);
        lottery.settleRound();

        assertTrue(lottery.getRound(1).isSettled, "round settled by anyone");
        assertEq(lottery.currentRoundId(), 2, "fresh round opened");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Cancelled-round refund — depositors reclaim THEIR OWN yield (pro-rata TWAB)
    // ───────────────────────────────────────────────────────────────────────────

    function test_cancel_refundsYieldProRataByTwab() public {
        // Two equal, simultaneous depositors → equal TWAB → equal refund.
        _deposit(alice, 1_000e6);
        _deposit(eve,   1_000e6);
        aavePool.simulateYield(address(strategy), 200e6);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        // VRF never delivers → owner voids the round after 3h.
        vm.warp(block.timestamp + 3 hours + 1);
        lottery.cancelDraw();

        assertTrue(lottery.roundCancelled(1), "round voided");
        assertEq(lottery.currentRoundId(), 2, "fresh round opened");
        uint256 pool = lottery.roundYieldRefund(1);
        assertGt(pool, 0, "yield reserved for refund (not rolled to a future winner)");

        uint256 aBefore = usdc.balanceOf(alice);
        uint256 eBefore = usdc.balanceOf(eve);
        vm.prank(alice); lottery.claimRoundYield(1);
        vm.prank(eve);   lottery.claimRoundYield(1);
        uint256 aGot = usdc.balanceOf(alice) - aBefore;
        uint256 eGot = usdc.balanceOf(eve)   - eBefore;

        assertApproxEqAbs(aGot, eGot, 2, "equal TWAB -> equal refund");
        assertApproxEqAbs(aGot + eGot, pool, 2, "refunds sum to the reserved pool");
    }

    function test_cancel_refundDoubleClaimReverts() public {
        _deposit(alice, 1_000e6);
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        vm.warp(block.timestamp + 3 hours + 1);
        lottery.cancelDraw();

        vm.prank(alice); lottery.claimRoundYield(1);
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV3.NoPrizeToClaim.selector);
        lottery.claimRoundYield(1);
    }

    function test_cancel_principalUntouched_andNewRoundUsable() public {
        _deposit(alice, 1_000e6);
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        vm.warp(block.timestamp + 3 hours + 1);
        lottery.cancelDraw();

        // Principal fully withdrawable in the fresh round (no lock, untouched).
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); lottery.withdraw(1_000e6);
        assertGe(usdc.balanceOf(alice) - before, 1_000e6 - 1, "principal returned");

        // And the reserved yield is still separately claimable.
        vm.prank(alice); lottery.claimRoundYield(1);
        assertGt(lottery.roundYieldRefund(1), 0);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Unlimited scale — ONE TWAB-weighted winner via paginated reservoir settle
    // ───────────────────────────────────────────────────────────────────────────

    function test_largePool_singleWinner_viaPaginatedSettle() public {
        lottery.setSettleBatch(2); // force a multi-batch settle (5 users / 2 = 3 calls)

        address carol = address(0xCA401);
        address dave  = address(0xDA53);
        address erin  = address(0xE817);
        address[5] memory users = [alice, eve, carol, dave, erin];
        for (uint256 i; i < 5; i++) {
            usdc.mint(users[i], 1_000_000e6);
            vm.prank(users[i]); usdc.approve(address(lottery), type(uint256).max);
            _deposit(users[i], 1_000e6);
        }
        aavePool.simulateYield(address(strategy), 500e6);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 0xABCDEF);

        // Batches 1 + 2 leave it in-progress; batch 3 finalizes.
        lottery.settleRound();
        (bool active1,,,) = lottery.settlementInProgress();
        assertTrue(active1, "settle in progress after batch 1");
        assertFalse(lottery.getRound(1).isSettled, "not settled mid-pass");
        lottery.settleRound();
        lottery.settleRound();

        assertTrue(lottery.getRound(1).isSettled, "settled after final batch");
        assertEq(lottery.currentRoundId(), 2, "fresh round opened");
        (bool active2,,,) = lottery.settlementInProgress();
        assertFalse(active2, "settlement cleared");

        // EXACTLY ONE jackpot winner (1-tier) takes the full net prize — no pro-rata.
        uint256 net = lottery.getRound(1).totalPrize;
        assertGt(net, 0);
        uint256 winnerCount;
        uint256 paid;
        for (uint256 i; i < 5; i++) {
            uint256 pp = lottery.pendingPrizes(1, users[i]);
            if (pp > 0) { winnerCount++; paid += pp; }
        }
        assertEq(winnerCount, 1, "exactly one winner");
        assertEq(paid, net, "winner takes the whole net prize");
        assertEq(lottery.roundYieldRefund(1), 0, "no pro-rata reserve on a normal round");
    }

    function test_settleBatch_cannotChangeMidSettle() public {
        lottery.setSettleBatch(2);
        address carol = address(0xCA401);
        address[3] memory users = [alice, eve, carol];
        for (uint256 i; i < 3; i++) {
            usdc.mint(users[i], 10_000e6);
            vm.prank(users[i]); usdc.approve(address(lottery), type(uint256).max);
            _deposit(users[i], 1_000e6);
        }
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 5);
        lottery.settleRound(); // in progress (2 of 3)

        vm.expectRevert(bytes("V3: settle in progress"));
        lottery.setSettleBatch(300);
    }

    function test_cannotCancelMidSettle_mustResume() public {
        lottery.setSettleBatch(2);
        address carol = address(0xCA401);
        address[3] memory users = [alice, eve, carol];
        for (uint256 i; i < 3; i++) {
            usdc.mint(users[i], 10_000e6);
            vm.prank(users[i]); usdc.approve(address(lottery), type(uint256).max);
            _deposit(users[i], 1_000e6);
        }
        aavePool.simulateYield(address(strategy), 100e6);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        randMgr.deliverRandomness(address(lottery), 9);
        lottery.settleRound(); // batch 1 (2 of 3) → settle in progress

        // Cancel is blocked once settlement has started — even past the 7d window.
        // The escape from a half-done settle is to RESUME (settleRound is
        // permissionless and pure compute), never to void + double-harvest.
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vm.expectRevert(bytes("V3: settle in progress"));
        lottery.cancelDrawPublic();

        // Resuming finalizes the draw normally — exactly one winner.
        lottery.settleRound();
        assertTrue(lottery.getRound(1).isSettled, "resume finishes the draw");
        assertEq(lottery.currentRoundId(), 2);
    }

    function test_cancel_chargesTwoPercentYieldFee_andViewMatchesClaim() public {
        _deposit(alice, 1_000e6);
        aavePool.simulateYield(address(strategy), 100e6); // 100 USDC generated yield
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        vm.warp(block.timestamp + 3 hours + 1);
        lottery.cancelDraw();

        // 2% yield-only fee (never on principal) — ~98 reserved, ~2 to protocol.
        assertApproxEqAbs(lottery.roundYieldRefund(1), 98e6, 1e6, "~98% of yield reserved");
        assertApproxEqAbs(lottery.accumulatedProtocolFees(), 2e6, 1e6, "~2% protocol fee on yield");

        // The on-chain view equals what claimRoundYield actually pays.
        uint256 quoted = lottery.claimableRoundYield(1, alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); lottery.claimRoundYield(1);
        assertEq(usdc.balanceOf(alice) - before, quoted, "view == claimed amount");
        assertEq(lottery.claimableRoundYield(1, alice), 0, "view 0 after claim");

        // Principal still fully returned — fee was on yield only.
        uint256 pBefore = usdc.balanceOf(alice);
        vm.prank(alice); lottery.withdraw(1_000e6);
        assertGe(usdc.balanceOf(alice) - pBefore, 1_000e6 - 1, "principal never fee'd");
    }

    function test_cancel_earlierDepositorGetsLargerRefund() public {
        // alice deposits at round start; eve deposits halfway in. Equal principal,
        // but alice's funds worked longer → alice's TWAB (and refund) is larger.
        _deposit(alice, 1_000e6);
        vm.warp(block.timestamp + ROUND_DURATION / 2);
        _deposit(eve, 1_000e6);
        aavePool.simulateYield(address(strategy), 300e6);

        vm.warp(block.timestamp + ROUND_DURATION); // well past endTime
        lottery.performUpkeep("");
        vm.warp(block.timestamp + 3 hours + 1);
        lottery.cancelDraw();

        uint256 aBefore = usdc.balanceOf(alice);
        uint256 eBefore = usdc.balanceOf(eve);
        vm.prank(alice); lottery.claimRoundYield(1);
        vm.prank(eve);   lottery.claimRoundYield(1);
        assertGt(usdc.balanceOf(alice) - aBefore, usdc.balanceOf(eve) - eBefore,
            "earlier/longer deposit earns a larger pro-rata yield refund");
    }
}
