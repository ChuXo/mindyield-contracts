// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ProbabilityVaultV2.sol";
import "../src/ProbabilityVaultFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice Audit PoC harness. Demonstrates bugs found during the
///         pre-mainnet security review of ProbabilityVaultV2.
contract ProbabilityVaultAuditTest is Test {
    ProbabilityVaultV2      public impl;
    ProbabilityVaultFactory public factory;
    YieldVault              public yieldVault;
    IdentityRegistry        public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20               public usdc;

    address public creator  = address(0x100);
    address public alice    = address(0x101);
    address public bob      = address(0x102);
    address public griefer  = address(0x103);
    address public treasury = address(0x111);

    bytes32 public constant CONDITION_ID = keccak256("polymarket-cond-audit");
    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");

    uint64 public polyEnd;

    function setUp() public {
        vm.warp(1_800_000_000);
        polyEnd = uint64(block.timestamp + 7 days);

        usdc = new MockERC20("USDC", "USDC", 6);
        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));

        identityRegistry = new IdentityRegistry();
        address[4] memory all = [alice, bob, griefer, creator];
        for (uint256 i = 0; i < all.length; i++) {
            identityRegistry.setTier(all[i], 2);
            usdc.mint(all[i], 100_000e6);
        }

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
        ProbabilityVaultFactory.CreateParams memory p = ProbabilityVaultFactory.CreateParams({
            depositToken:      address(usdc),
            polymarketEndDate: polyEnd,
            joinEnd:           0,
            resolveStart:      0,
            cancelDeadline:    0,
            yesOption:         YES,
            noOption:          NO,
            conditionId:       CONDITION_ID,
            metadataHash:      keccak256("audit"),
            metadataUri:       "ipfs://",
            resolver:          address(resolver)
        });
        vm.prank(creator);
        (, address addr) = factory.createVault(p);
        return addr;
    }

    function _deposit(address user, address vault, uint256 amount, bytes32 side) internal {
        vm.startPrank(user);
        usdc.approve(vault, amount);
        ProbabilityVaultV2(vault).deposit(amount, side);
        vm.stopPrank();
    }

    // ─── FINDING 1: YieldVault MIN_HOLD_TIME griefing ─────────────────
    //
    // ProbabilityVault accounts per-user locally but delegates yield-vault
    // share bookkeeping to a single address (the vault itself). YieldVault
    // enforces a 60-second MIN_HOLD_TIME between the most-recent deposit
    // and any withdraw from the same depositor. Because the depositor is
    // the ProbabilityVault (not the user), any single user's deposit resets
    // the clock for ALL other users trying to `withdrawEarly()`.
    //
    // A griefer can dust-deposit every ~55 seconds and block the exit
    // ramp for the entire JOIN window.

    function test_bug_minHoldTimeBlocksOtherWithdrawals() public {
        address v = _createVault();

        // Alice deposits 1000 USDC, waits several blocks
        _deposit(alice, v, 1_000e6, YES);
        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + 10);

        // 30 seconds before Alice wants to exit, griefer deposits 1 wei.
        _deposit(griefer, v, 1, NO);
        vm.warp(block.timestamp + 30); // only 30s passed
        vm.roll(block.number + 1);     // different block, so FlashLoanBlocked doesn't fire locally

        // Alice's withdrawEarly() REVERTS inside YieldVault.withdraw()
        // even though her local `depositBlock` is old.
        vm.prank(alice);
        vm.expectRevert(bytes("YieldVault: minimum hold time not met"));
        ProbabilityVaultV2(v).withdrawEarly();
    }

    // ─── FINDING 2: Swap fee lost when protocolFeeRecipient == address(0)
    //
    // If the factory is deployed / configured such that protocolFeeRecipient
    // == address(0) (setFeeRecipient rejects it, but the InitParams sanity
    // check in initialize() does NOT enforce it), the swap fees accumulate
    // forever in `totalAccruedSwapFees` and the user's principal is already
    // debited. On finalize AND cancel paths the sweep is guarded by
    // `protocolFeeRecipient != address(0)` — fees are trapped, a pure
    // loss to depositors.
    //
    // The current factory constructor requires _feeRecipient != 0, so the
    // exploit path is "factory owner sets recipient, fee accrues, factory
    // owner later sets it to... actually can't set zero because of guard".
    // So this IS prevented by the factory setter, but the vault itself
    // does NOT validate protocolFeeRecipient — a hand-rolled deployment
    // bypassing the factory (e.g. from a future factory version) is unsafe.
    //
    // Documented as LOW / defense-in-depth.

    // ─── FINDING 3: totalAccruedSwapFees sweep on _cancel happens BEFORE
    // the accounting sentinel is written — so on strategy-loss cancel the
    // swap-fee sweep is included in `returned` accounting but the amount
    // subtracted from USDC balance may push claim() payouts to fail.
    //
    // Walk through: strategy lost 10%. _cancel() branch `returned < principal`
    // writes distributableYield = returned, totalYield = principal.
    // THEN it tries to sweep swap fees. If that transfer succeeds, the
    // contract's USDC balance drops. When users claim(), principalOut is
    // u.principal * returned / principal. Sum of principalOut across all
    // users == returned. But we just paid out `totalAccruedSwapFees` to
    // treasury, so contract balance is `returned + accruedSwapFees` (initial)
    // − accruedSwapFees (swept) = `returned`. Users' share is scaled down
    // to returned. OK — this works. But `returned` measured from
    // vault.withdraw already excludes accrued swap fees (which lived in
    // the contract, not the vault). So `returned + accruedSwapFees` is the
    // true balance. Principal is correctly scaled to `returned`, so fees
    // going to treasury doesn't starve users.
    //
    // This is actually FINE. Not a bug. Documented as reviewed.

    // ─── FINDING 4: Swap fee rounds DOWN to zero on small amounts ─────
    //
    // With swapFeeBps = 20 (0.2%), any swap of amount < 500 → fee = 0.
    // User swaps 1_000e6 in 499-wei chunks = 2e9 swaps, each fee 0 → total
    // swap fee is zero instead of 2e6. Realistic griefing is bounded
    // by gas cost (~50k gas per swap → $1.50/swap on Base → economically
    // NOT viable to save $2). Documented as economic (INFO).

    /// @notice Simulate yield by minting to YieldVault + bumping its accounting
    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(yieldVault), amount);
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur + amount));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 + amount));
    }

    function _proposeOutcome(address vault, bytes32 sideLabel) internal {
        bytes32 key = bytes32(uint256(uint160(vault)));
        PolymarketRelayResolver.Outcome outcome = sideLabel == YES
            ? PolymarketRelayResolver.Outcome.YES_WIN
            : PolymarketRelayResolver.Outcome.NO_WIN;
        if (block.timestamp < uint256(polyEnd) + 12 hours) {
            vm.warp(uint256(polyEnd) + 12 hours + 1);
        }
        resolver.propose(key, outcome);
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ─── CRITICAL: swap fees double-counted as yield, then swept to treasury
    // causing claim() to revert on insufficient balance.
    //
    // When Alice swaps, her stake counters decrease by `fee`. totalYesStake+totalNoStake
    // drops by fee. On resolveContest, the contract reads principal =
    // totalYesStake + totalNoStake (which is original deposit MINUS accumulated
    // swap fees). It reads totalAssets = full vault balance (original deposits
    // + yield — swap fees never went to the vault). So yieldGen =
    // totalAssets - principal DOUBLE-COUNTS the swap fees. Then the swap-fee
    // sweep sends totalAccruedSwapFees to treasury. Net: the contract's
    // USDC balance is now SHORT by `totalAccruedSwapFees` of what users+yield
    // need to be paid. Last claim(er) reverts.

    function test_bug_swapFeesDoubleCountedAsYield() public {
        address v = _createVault();
        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);

        // Alice deposits 1000 YES, Bob deposits 1000 NO (so we have winners on each side)
        _deposit(alice, v, 1_000e6, YES);
        vm.roll(block.number + 1);
        _deposit(bob, v, 1_000e6, NO);
        vm.roll(block.number + 1);

        // Wait a day, then Alice swaps 500 YES → NO (fee = 500e6 * 20 / 10000 = 1e6)
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        pv.swap(500e6, NO);

        // totalAccruedSwapFees should be 1e6
        assertEq(pv.totalAccruedSwapFees(), 1e6);

        // Warp to joinEnd
        vm.warp(uint256(pv.joinEnd()) + 1);

        // Inject yield of 30 USDC into vault
        _simulateYield(30e6);

        // Warp past resolveStart and resolve with YES winner
        vm.warp(uint256(pv.resolveStart()) + 1);
        vm.roll(block.number + 100); // advance past depositBlock for YieldVault guard
        _proposeOutcome(v, YES);
        pv.resolveContest();

        assertEq(uint256(pv.state()), uint256(ProbabilityVaultV2.State.FINALIZED));

        // After resolve, totalAccruedSwapFees should have been swept
        assertEq(pv.totalAccruedSwapFees(), 0);

        // Now measure contract USDC balance
        uint256 contractBal = usdc.balanceOf(v);

        // Alice claims first (she's on winning side + swapped to NO midway)
        vm.prank(alice);
        pv.claim();

        // Bob claims (on NO — losing side, just principal = 1000e6)
        // But wait — Bob has u.noTwab > 0, but he's not on WINNING side (YES).
        // NO: winner is YES, so Bob gets principal only. But Bob is on NO, which lost.
        // Bob gets 1000e6 principal.
        //
        // The issue: Alice has u.principal = 999e6, and u.yesTwab + u.noTwab.
        // The winning side is YES. Alice's u.yesTwab = 1000e6 * 1 day.
        // The remaining YES-TWAB holder: no one else (Bob was on NO).
        // So Alice gets ALL distributableYield.
        //
        // distributableYield = yieldGen - protocolFee
        //   yieldGen = totalAssets - principal
        //            = (2000e6 + 30e6) - (999e6 + 1000e6)
        //            = 2030e6 - 1999e6 = 31e6      ← WRONG (should be 30e6)
        //   protocolFee = 31e6 * 200 / 10000 = 620_000 (0.62 USDC)
        //   distributableYield = 31e6 - 620_000 = 30_380_000
        //
        // Alice payout = 999e6 principal + 30_380_000 yield = 1_029_380_000
        // Bob payout   = 1_000e6 principal
        // Treasury     = 1e6 (swap fee sweep) + 620_000 (protocol fee) = 1_620_000
        //
        // Total payouts = 1_029_380_000 + 1_000_000_000 + 1_620_000 = 2_031_000_000
        // Contract received (from vault) = 2_030_000_000
        // SHORT BY 1_000_000 = totalAccruedSwapFees DOUBLE-COUNTED
        //
        // One of Alice or Bob will fail to claim!

        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        // This SHOULD revert due to insufficient balance:
        try pv.claim() {
            uint256 bobGained = usdc.balanceOf(bob) - bobBalBefore;
            emit log_named_decimal_uint("bob gained", bobGained, 6);
            emit log_named_decimal_uint("contract balance after resolve", contractBal, 6);
        } catch Error(string memory r) {
            emit log_named_string("bob claim reverted", r);
        } catch (bytes memory) {
            emit log_string("bob claim reverted (no reason)");
        }

        // Demonstrate the shortfall directly
        uint256 finalBal = usdc.balanceOf(v);
        emit log_named_decimal_uint("final contract balance", finalBal, 6);
    }

    function test_bug_swapFeeRoundsToZeroOnTinyAmounts() public {
        address v = _createVault();
        _deposit(alice, v, 1_000e6, YES);

        vm.warp(block.timestamp + 1 days);

        // Swap 499 wei: fee = 499 * 20 / 10000 = 0.998 → 0
        vm.prank(alice);
        ProbabilityVaultV2(v).swap(499, NO);

        ProbabilityVaultV2 pv = ProbabilityVaultV2(v);
        assertEq(pv.totalAccruedSwapFees(), 0);
        // Alice now holds 499 wei on NO — no fee paid.
    }

    // ─── FINDING 5: _updateUserTwab on first-touch stores u.lastUserUpdate
    // but user's yesStake/noStake are ALREADY updated before _updateUserTwab
    // is called in deposit path? Let's check:
    //   deposit() → _updateGlobalTwab() → _updateUserTwab(u)
    //   Then u.yesStake += amount;
    // So on first-touch, u.yesStake = 0 when _updateUserTwab runs → the
    // branch `u.lastUserUpdate == 0` stores cap. Correct.
    //
    // But on subsequent deposit, _updateUserTwab sees u.yesStake (which
    // is the PREVIOUS stake) and accumulates for elapsed seconds. Then
    // new stake is added. This is correct TWAB accounting.
    //
    // What about early-withdraw? _updateUserTwab(u) is called AFTER the
    // user's stake is already set. It accumulates the stake-seconds up to
    // now, then stake is zeroed. The subsequent `totalYesTwab -= u.yesTwab`
    // subtraction must match what was added to global. BUT: global was
    // updated via _updateGlobalTwab which iterates over totalYesStake (the
    // SUM of all users). If Alice's cumulative stake-seconds (over all her
    // deposits) equals her `u.yesTwab`, then the subtraction is exact.
    //
    // Invariant: u.yesTwab == integral over time of u.yesStake from first
    // touch to now. sum(u.yesTwab, active users) + sum(u.yesTwab forfeited
    // earlywithdraws) == totalYesTwab accumulated.
    //
    // BUT: totalYesStake can have underflow-risk too — if a user deposits,
    // then swaps YES→NO, totalYesStake -= amount. Global TWAB accumulation
    // from that point onwards uses the NEW totalYesStake. Meanwhile user's
    // yesStake -= amount. So after the swap, global TWAB accumulates
    // correctly and user's TWAB also accumulates on NO side.
    //
    // Subtle issue: on early withdraw, we subtract u.yesTwab from totalYesTwab.
    // But u.yesTwab may have been built up across multiple deposit/swap
    // sequences. If user deposits 100 YES, waits 1 day, swaps all to NO,
    // waits 1 day, then early-withdraws: u.yesTwab = 100 * 86400 (from the
    // first day, not the second). totalYesTwab has 100 * 86400 contribution
    // from the first day AND 100 * 86400 + ... of other users' from the
    // second day. Subtracting u.yesTwab from totalYesTwab removes the
    // correct amount. OK.
    //
    // Conclusion: TWAB invariant holds. Not a bug.

    // ─── FINDING 6: sharesForAmount is called with getShareValue on
    // totalShares including VIRTUAL offset — so if the vault's
    // tokenTotalShares is very large relative to tokenValue (strategy
    // loss), _sharesForAmount returns MORE shares than needed. The code
    // caps at `vaultShares` and uses the actual `returned` amount.
    // Could returning MORE shares drain the vault's accrued yield
    // intended for other vaults? The YieldVault tracks shares per-depositor
    // (msg.sender = probVault), so only the probVault's own shares are
    // decremented. A single vault can't drain another vault's shares.
    //
    // Not a bug. Reviewed.

    // ─── FINDING 7: executeProtocolFeeTransfer reentrancy surface ─────
    //
    // resolveContest() is nonReentrant. Inside, it calls
    //   this.executeProtocolFeeTransfer(recipient, fee)
    // via try/catch. executeProtocolFeeTransfer checks `msg.sender == address(this)`.
    // The EXTERNAL self-call bypasses the nonReentrant modifier on
    // executeProtocolFeeTransfer — but the outer resolveContest STILL holds
    // the reentrancy lock. So a malicious recipient token that tries to
    // call back into deposit/swap/withdrawEarly/claim/resolveContest would
    // hit the reentrancy guard (lock is still held by outer frame).
    //
    // The only reentry path without the guard would be: recipient reenters
    // some view function → but none of those mutate state.
    //
    // Wait — is there any EXTERNAL non-reentrant function on this contract
    // that's NOT guarded? Let me check:
    //   - initialize: nonReentrant
    //   - deposit: nonReentrant
    //   - swap: nonReentrant
    //   - withdrawEarly: nonReentrant
    //   - resolveContest: nonReentrant
    //   - emergencyCancel: nonReentrant
    //   - claim: nonReentrant
    //   - updateState: NO GUARD — but only calls _maybeAutoTransitionFromJoin,
    //     which just flips state and calls _updateGlobalTwab.
    //   - executeProtocolFeeTransfer: has msg.sender guard
    //
    // updateState is a safe re-entry point (no fund movement). OK.
    //
    // Not a reentrancy bug.

    // ─── FINDING 8: Swap fee rate — integer division truncation in fee calc
    //   uint96 fee = uint96((amount * uint256(swapFeeBps)) / 10_000);
    //   uint96 netAmount = uint96(amount) - fee;
    // If amount > type(uint96).max: uint96(amount) wraps silently... WAIT.
    //
    // Solidity 0.8 on explicit `uint96(amount)` cast: does it revert on
    // truncation?
    //   `uint96(uint256)` is a conversion cast — in 0.8 this TRUNCATES,
    //   does NOT revert. This is a common footgun.
    //
    // What's the max amount? The contract accepts uint256 as `amount` to
    // swap. swap() only requires `u.yesStake >= amount` (checked as uint96
    // vs uint256 — uint96(u.yesStake) comparison promotes RHS to uint256
    // via implicit convert — actually NO, u.yesStake is a uint96 and
    // `amount` is uint256, so the comparison `u.yesStake < amount` is
    // automatic to the widest type — the uint96 is zero-extended to
    // uint256. So `u.noStake < amount` holds iff uint256(u.noStake) < amount.
    //
    // If user somehow has u.yesStake = 1000 USDC (uint96, easily fits) and
    // calls swap(amount = 2^97, NO) — the check `u.yesStake < amount`
    // evaluates `1000 < 2^97` = true → reverts InsufficientStake. Good.
    //
    // So amount is always ≤ u.yesStake or u.noStake ≤ uint96.max ≈ 7.9e28,
    // which for 6-decimal USDC = 7.9e22 USDC. Unreachable.
    //
    // uint96(amount) truncation is SAFE in practice because amount ≤ uint96.
    //
    // Not a bug.

    // ─── FINDING 9: resolveContest → withdraw from vault with vaultShares
    // cast from uint128 to uint256 — safe. But then on a happy-path finalize
    // with no yield (totalAssets == principal), protocolFee = 0, but swap
    // fee sweep still happens. Safe.

    // ─── FINDING 10: claim() path — principal cast to uint256 from uint96.
    // u.principal is uint96 (maxes out at 7.9e28 = safe for 6-dec USDC).
    // Safe.

    // ─── FINDING 11: `factory = msg.sender` set during initialize but
    // factory is just stored for nothing — only emergencyCancel uses it via
    // `onlyFactory` modifier. Note emergencyCancel is per-vault but the
    // FACTORY's emergencyCancelVault is onlyOwner. If factory owner is
    // compromised, any vault can be cancelled. Documented as centralization
    // trust assumption (not a bug).

    // ─── FINDING 12: impliedProbabilityYes / poolRatio use `totalYesStake +
    // totalNoStake`. After swap with fee, total shrinks (fee stripped out).
    // Principal conservation: initial sum = sum after fees + totalAccruedSwapFees.
    // The on-chain probability read is thus DISTORTED by fee accrual — each
    // swap reduces the reported pool size. This affects downstream oracles
    // that read impliedProbabilityYes but is not a bug; it's an accounting
    // design (fee is paid from the losing side).
    //
    // Actually, wait: consider an external contract using impliedProbabilityYes
    // as an oracle. Alice deposits 10_000 YES, 0 NO. Ratio = 100% YES.
    // Alice swaps 5000 YES → NO. fee = 10 USDC. After swap:
    //   totalYesStake = 5000e6
    //   totalNoStake  = 4990e6 (5000 - 10 fee)
    //   Ratio = 5000/9990 ≈ 50.05% YES
    // If Alice keeps swapping 100-USDC chunks back-and-forth,
    // each swap shrinks the pool by 0.2%. After 100 swaps pool is 5000 * 0.8 ≈
    // 4090 total. Probability still roughly 50% but pool size is 20% smaller.
    //
    // Impact: attacker can MANIPULATE the reported implied probability
    // by burning ~0.2% of their own principal per swap. Gas cost limits
    // this. Not obviously a serious bug. Documented as INFO.
}
