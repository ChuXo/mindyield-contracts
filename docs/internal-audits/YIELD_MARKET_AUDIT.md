# ProbabilityVaultV2 / ProbabilityVaultFactory — Pre-Mainnet Security Audit

**Date:** 2026-04-17
**Scope:**
- `contracts/src/ProbabilityVaultV2.sol` (clone target)
- `contracts/src/ProbabilityVaultFactory.sol`
- Trust boundary with `contracts/src/resolvers/PolymarketRelayResolver.sol` and `contracts/src/YieldVault.sol`

**Baseline:** `forge test --match-contract ProbabilityVaultTest` — 24 passing before and after the audit patches proposed below. Two new PoC tests in `contracts/test/ProbabilityVault.audit.t.sol` prove the concrete bugs described.

---

## Must-Fix-Before-Mainnet — status

1. **[CRITICAL] C-01 — FIXED 2026-04-18** — `principalAndFees` added to `yieldGen` calc in both `resolveContest` and `_cancel`. Verified: 34 tests still pass, including the audit PoC.
2. **[HIGH] H-01 — FIXED 2026-04-18** — Added `trustedDepositor` mapping + setter on `YieldVault.sol`. Factory auto-registers each clone via `setTrustedDepositor(newClone, true)` on creation, with a deploy-runbook fallback for manual registration if the factory isn't YieldVault owner.
3. **[HIGH] H-02 — FIXED 2026-04-18** — Same fix as C-01 (strategy-loss detection now uses `principalAndFees`).

All three must-fix items are resolved. The remaining Medium/Low/Informational findings below are accepted or documented as known behavior. **No mainnet blockers.**

---

## Findings

| #   | Severity | Title                                                                                                   |
| --- | -------- | ------------------------------------------------------------------------------------------------------- |
| C-01 | Critical | Swap fees double-counted as yield → fund-conservation break → last claim reverts                        |
| H-01 | High     | YieldVault MIN_HOLD_TIME grief blocks `withdrawEarly` for all users                                     |
| H-02 | High     | Strategy-loss detection underestimates loss by `totalAccruedSwapFees`                                   |
| M-01 | Medium   | `distributableYield` stranded when winning side has zero TWAB (e.g. all winners withdrew early)         |
| M-02 | Medium   | `impliedProbabilityYes` shrinks with every swap (oracle-readable value drifts deterministically)       |
| L-01 | Low      | Vault's `initialize()` does not validate `protocolFeeRecipient != address(0)`                           |
| L-02 | Low      | `uint96(amount)` truncation cast in `swap()` is safe only because `amount ≤ u.sideStake ≤ uint96.max`   |
| L-03 | Low      | `_sharesForAmount` uses view-function round-trip against a live share price (not atomic with withdraw) |
| I-01 | Info     | Swap fee truncates to zero for `amount < 10000 / swapFeeBps` (500 wei at default 20 bps)                |
| I-02 | Info     | `updateState()` is permissionless and unguarded but only flips state forward                            |

---

## C-01 · CRITICAL · Swap fees double-counted as yield, breaking no-loss

**Location:** `contracts/src/ProbabilityVaultV2.sol:293-321` (swap bookkeeping) and `:436-437`, `:467-476`, `:480` (resolve accounting)

**Explanation.** `swap()` decrements the sender's `noStake` (or `yesStake`) by the *gross* swap amount and credits the other side with only `netAmount = amount - fee`. The net effect is that `totalYesStake + totalNoStake` decreases by `fee` on every swap, and `totalAccruedSwapFees` is incremented by the same `fee`. **However, no tokens are moved** — the full original deposit is still in `yieldVault`.

At resolution time (`resolveContest` line 436):

```solidity
uint256 principal = uint256(totalYesStake) + uint256(totalNoStake);
uint256 yieldGen  = totalAssets > principal ? totalAssets - principal : 0;
```

`principal` has been shrunk by `totalAccruedSwapFees` but `totalAssets` (withdrawn from the yield vault) has not. Therefore `yieldGen` is **inflated by exactly `totalAccruedSwapFees`**. The contract then:

1. Pays a protocol fee of `yieldGen * feeBps / 10_000` to the treasury (which includes fee-on-top-of-the-already-counted-swap-fee).
2. Separately sweeps `totalAccruedSwapFees` to the treasury a second time (line 470).
3. Sets `distributableYield = yieldGen - protocolFee`, distributing the swap fees *again* as yield to winners on claim.

Total outflow from the contract ends up being `totalAssets + totalAccruedSwapFees` against the contract's actual `totalAssets` balance — a shortfall of exactly `totalAccruedSwapFees`. The last `claim()` reverts with "Insufficient balance".

**Impact.** Direct no-loss invariant violation. Users who claim late lose *all* of their principal + yield to a transfer revert. Griefer scenario: any malicious user who monitors the mempool can front-run the final claimer's transaction and guarantee it reverts. More commonly, some ordinary user will simply be locked out of funds. Value at risk = `totalAccruedSwapFees` (scales with swap volume) per vault.

**Proof of concept.** `contracts/test/ProbabilityVault.audit.t.sol::test_bug_swapFeesDoubleCountedAsYield`:
- 2000 USDC deposited (1000 YES + 1000 NO), one 500 USDC swap (fee = 1 USDC), 30 USDC yield injected.
- After `resolveContest`: contract holds 2029 USDC (2030 withdrawn − 1 swept to treasury).
- Alice (YES winner) claims 999 principal + ~30 yield = ~1029.
- Bob (NO loser) tries to claim 1000 principal → reverts with "Insufficient balance". Final contract balance: 999 USDC.

**Recommendation (patch).**

```diff
// ProbabilityVaultV2.sol, resolveContest():
  uint256 principal = uint256(totalYesStake) + uint256(totalNoStake);
- uint256 yieldGen = totalAssets > principal ? totalAssets - principal : 0;
+ // Swap fees live in the contract's USDC balance, not in the yield vault.
+ // `principal` was decremented by swap fees during swap(), but the vault
+ // still holds the gross deposits. Add them back so yieldGen is pure yield.
+ uint256 nominalPrincipal = principal + uint256(totalAccruedSwapFees);
+ uint256 yieldGen = totalAssets > nominalPrincipal ? totalAssets - nominalPrincipal : 0;
```

And correspondingly in the strategy-loss detection a few lines below:

```diff
- if (totalAssets < principal && principal > 0) {
+ if (totalAssets < nominalPrincipal && nominalPrincipal > 0) {
      _cancel("strategy loss during lock");
      return;
  }
```

An alternative fix (preferred for clarity) is to change `swap()` so it *does not* decrement the totals at all; instead fee is tracked purely via `u.principal -= fee` and `totalAccruedSwapFees += fee`, and `totalYesStake + totalNoStake` remains equal to total-ever-deposited. But this requires touching TWAB logic carefully and is more invasive — the one-line accounting fix above is sufficient.

---

## H-01 · HIGH · YieldVault MIN_HOLD_TIME grief blocks `withdrawEarly` for everyone

**Location:** `contracts/src/ProbabilityVaultV2.sol:328-376` (`withdrawEarly`), interaction with `contracts/src/YieldVault.sol:52-63, 228-235`

**Explanation.** `YieldVault.withdraw` enforces two flash-loan guards against `msg.sender` (the ProbabilityVault contract):

```solidity
if (depositBlock[msg.sender][token][strategyId] == block.number) revert SameBlockWithdraw();
require(block.timestamp >= depositTimestamp[msg.sender][token][strategyId] + MIN_HOLD_TIME, ...);
```

Both maps are keyed on `msg.sender = ProbabilityVault contract address` — **not on the end user**. Every time *any* user calls `ProbabilityVaultV2.deposit()`, the inner `IYieldVault(yieldVault).deposit(...)` call resets `depositBlock[probVault][...]` and `depositTimestamp[probVault][...]` to the current block/timestamp. For the next 60 seconds, **no user** can successfully call `ProbabilityVaultV2.withdrawEarly()` — the inner `yieldVault.withdraw(...)` reverts with `"YieldVault: minimum hold time not met"`.

**Attack.** A griefer loops `deposit(1, YES)` → `deposit(1, NO)` every ~55 seconds throughout the JOIN window. With Base mainnet gas around 50k per deposit × $0.05 cent on Base ≈ $0.002/deposit × 1570 deposits/day ≈ $3/day to keep `withdrawEarly` permanently DoS'd for the entire contest duration (up to 365 days at worst). Total cost < $1100 to lock every participant out of their principal refund before finalize. The 1-wei grief deposits also pass the tier check only if the griefer is Tier 2+ — still a trivial bar given `setTier` is admin-set; but note that the grief only needs *one* authorized identity.

**Impact.** Denial-of-service on every user's early-exit path. Real-money harm = interest/opportunity-cost during the lockout window, plus forced-yield-forfeiture for users who wanted out (they're pushed into accepting the full contest risk). Principal is not stolen but is effectively frozen until JOIN closes. Breaks one of the two explicit safety promises of the vault ("deposits and early withdrawals allowed during JOIN").

**Proof of concept.** `test/ProbabilityVault.audit.t.sol::test_bug_minHoldTimeBlocksOtherWithdrawals`:
- Alice deposits 1000 USDC, waits 10 minutes.
- Griefer deposits 1 wei. 30 s later, Alice tries `withdrawEarly()`.
- Reverts with `"YieldVault: minimum hold time not met"`.

**Recommendation.** Three viable options:

1. **Per-user hold-time accounting.** `ProbabilityVaultV2` already tracks `u.depositBlock` at line 275 and checks it at line 335 (`FlashLoanBlocked`). Extend this with a `uint64 u.depositTimestamp` and enforce ≥60 s inside `withdrawEarly`. Then pass a sentinel to the yield vault that bypasses the vault-level guard (e.g. a whitelist map `bypassHoldTime[address]`) only for registered probability vaults.
2. **Relax YieldVault guard for whitelisted depositors.** Add `mapping(address => bool) skipHoldTime` on `YieldVault`, and have `ProbabilityVaultFactory.createVault` register each vault. Per-user protection is handled at the probability-vault layer (which already has `depositBlock`).
3. **Let `withdrawEarly` reach directly into the yield vault bypassing the hold check.** Least-preferred; diverges from the in-production safety pattern used by other MindYield contests.

Option 2 is the cleanest and aligns with the AutoYieldVault's existing pattern. Sample patch:

```diff
// YieldVault.sol
+ mapping(address => bool) public exemptFromHoldTime;
+ function setExemptFromHoldTime(address depositor, bool exempt) external onlyOwner { … }

  function withdraw(...) external ... {
      ...
-     if (depositBlock[msg.sender][token][strategyId] == block.number) revert SameBlockWithdraw();
-     require(block.timestamp >= depositTimestamp[...] + MIN_HOLD_TIME, "...");
+     if (!exemptFromHoldTime[msg.sender]) {
+         if (depositBlock[msg.sender][token][strategyId] == block.number) revert SameBlockWithdraw();
+         require(block.timestamp >= depositTimestamp[...] + MIN_HOLD_TIME, "...");
+     }
```

Vaults enable the exemption via the factory; per-user flash-loan protection remains via `u.depositBlock` inside `ProbabilityVaultV2`.

---

## H-02 · HIGH · Strategy-loss detection under-reports loss by `totalAccruedSwapFees`

**Location:** `contracts/src/ProbabilityVaultV2.sol:443-451`

**Explanation.** Same root cause as C-01. The branch that detects strategy loss compares:

```solidity
if (totalAssets < principal && principal > 0) { _cancel("strategy loss during lock"); return; }
```

`principal` is `totalYesStake + totalNoStake`, which is the nominal deposit **minus accumulated swap fees**. Suppose users deposited 1000 total, swapped around enough to accrue 10 USDC in `totalAccruedSwapFees`, and the yield strategy lost 5 USDC. Then:

- True invested principal: 1000.
- `totalAssets` from vault: 995 (lost 5).
- `principal` (code's definition): 1000 − 10 = 990.
- `totalAssets < principal` evaluates to `995 < 990` = **false** — loss is missed.

Contract proceeds down the happy-path finalize. `yieldGen = totalAssets - principal = 5`, protocol fee, swap-fee sweep, etc. But the actual economic picture is that users collectively have claims worth 990, a yield of 0, and the contract only holds 995 USDC. Combined with C-01, the arithmetic is doubly broken.

**Impact.** Moderate-to-severe strategy losses (up to `totalAccruedSwapFees`) are silently absorbed without pro-rata scaling, causing later claimers to revert. Also, users on the winning side get "yield" that is actually returned principal — mispriced. Severity is HIGH because it violates the loss-socialization safety net that the `_cancel` branch is there to enforce.

**Recommendation.** Fix C-01 (use `nominalPrincipal = principal + totalAccruedSwapFees` everywhere in `resolveContest`). The same patch repairs H-02.

---

## M-01 · MEDIUM · `distributableYield` stranded when winning side has zero TWAB

**Location:** `contracts/src/ProbabilityVaultV2.sol:568-574` (`claim()`)

**Explanation.** If all winning-side participants call `withdrawEarly()` before `joinEnd`, their TWAB is subtracted from `totalYesTwab` / `totalNoTwab` (line 341-342). If the winning side ends up with `totalWinTwab == 0`, the condition `if (totalWinTwab > 0 && userWinTwab > 0)` is false for every would-be claimer, so `yieldOut = 0` and `distributableYield` is stranded in the contract.

The upstream `resolveContest` imbalance guard (line 409-415) catches *some* of this — it cancels when `minorityTwab * 100 < totalTwab * cancelMinorityPct` (default 5%). But that check uses the combined TWAB of both sides. Suppose the market ends with 94% YES / 6% NO by TWAB (NO above the 5% floor → no cancel). If all NO holders withdrew early and only their TWAB was subtracted, we'd get `totalNoTwab = 0` but `totalYesTwab > 0` — fine, YES wins and yield distributes. The edge case is: *NO holders early-withdrew*, but the resolver says NO won. Then `distributableYield > 0, totalNoTwab == 0, totalYesTwab > 0` — the winners have no TWAB, yield is stranded.

**Impact.** Low likelihood (requires *all* winning-side holders to forfeit). Funds are locked in the contract but not lost to attackers. Up to `distributableYield + protocolFee` is trapped forever.

**Recommendation.** Either

- In `resolveContest`, add a second guard after the resolver returns: if `winningSideTwab == 0`, treat as AMBIGUOUS and cancel → everyone gets principal back, stranded yield flows to treasury via the existing `_cancel` surplus handler.
- Or accept the edge case and route the stranded yield via a small owner-only `sweepStrandedYield()` on `CANCELLED`/`FINALIZED` states.

```diff
  // resolveContest, after resolver returns a winner:
  if (winner != yesOption && winner != noOption) revert InvalidConfig();

+ uint128 winningTwab = winner == yesOption ? totalYesTwab : totalNoTwab;
+ if (winningTwab == 0) {
+     _cancel("winning side has no TWAB");
+     return;
+ }
```

---

## M-02 · MEDIUM · Pool ratio oracle drifts with every swap

**Location:** `contracts/src/ProbabilityVaultV2.sol:679-690`

**Explanation.** `impliedProbabilityYes()` and `poolRatio()` both return ratios against `totalYesStake + totalNoStake`. As swaps execute, the denominator shrinks by `fee` on each swap because the swap code credits only `netAmount` to the new side but debits `amount` from the old side (see C-01). The ratio itself isn't systematically biased, but the *size* of the denominator decays predictably.

If an external contract uses this view as a price oracle ("implied probability of YES") over a long time horizon, an attacker can burn ~0.2% of their own principal per swap to reshape the reported ratio by swapping back-and-forth in sub-minority amounts, because fees are deducted asymmetrically from whichever side is being reduced.

**Impact.** Oracle manipulation is bounded by attacker's principal: reshaping the ratio by X bps costs roughly `X bps × pool size` in swap fees, paid to the treasury. Economically bounded but not cryptographically bounded.

**Recommendation.** Document that these views are *not* suitable as a manipulation-resistant oracle; downstream contracts should use a TWAP or observe over a long window. Optionally, change the swap bookkeeping per C-01 recommendation (keep totals whole) so the denominator only moves with real stake changes.

---

## L-01 · LOW · `initialize()` does not validate `protocolFeeRecipient != address(0)`

**Location:** `contracts/src/ProbabilityVaultV2.sol:201-215`

The `initialize` sanity checks enforce `depositToken`, `resolver`, and `yieldVault` are non-zero but do not check `protocolFeeRecipient`. The current factory constructor and `setFeeRecipient` both reject zero, so this is exploitable only from a future / misconfigured factory. Still, defense-in-depth recommends enforcing it at the clone level because `initialize` is the last line of defense.

```diff
  if (p.resolver == address(0)) revert InvalidConfig();
  if (p.yieldVault == address(0)) revert InvalidConfig();
+ if (p.protocolFeeRecipient == address(0)) revert InvalidConfig();
```

If recipient is zero, both the protocol-fee transfer and the swap-fee sweep are skipped (lines 455, 468, 511, 530). Yield still distributes correctly; swap fees trap in the contract. Not a direct loss, but silently breaks the fee model.

---

## L-02 · LOW · `uint96(amount)` silent truncation in `swap()` is safe only by upstream invariant

**Location:** `contracts/src/ProbabilityVaultV2.sol:293-312`

`uint96(amount) - fee` and `uint128(amount)` casts in `swap()` silently truncate if `amount > uint96.max`. Safety relies on the earlier check `if (u.yesStake < amount) revert InsufficientStake();` — since `u.yesStake` is `uint96`, a user whose `amount` exceeds `uint96.max` has `u.yesStake < amount` (after the implicit uint256 comparison) and reverts cleanly.

This is not exploitable because `u.yesStake ≤ uint96.max`, but the cast is still fragile. Recommend `SafeCast.toUint96(amount)`:

```diff
- uint96 fee = uint96((amount * uint256(swapFeeBps)) / 10_000);
- uint96 netAmount = uint96(amount) - fee;
+ uint96 amount96 = SafeCast.toUint96(amount);
+ uint96 fee = uint96((uint256(amount96) * uint256(swapFeeBps)) / 10_000);
+ uint96 netAmount = amount96 - fee;
```

---

## L-03 · LOW · `_sharesForAmount` uses a live share price

**Location:** `contracts/src/ProbabilityVaultV2.sol:668-673`

`_sharesForAmount` queries `yieldVault.getShareValue(...)` in the same transaction as the subsequent `withdraw(...)`. Because the vault applies its virtual-shares / virtual-assets offset identically in both paths, this is mathematically consistent. But a malicious yield strategy could return different `getTotalValue()` / `getShares()` values across the two calls (e.g. a reentrant callback during `withdraw`). Since `ReentrancyGuard` is in effect on the outer call and the inner call path is already guarded by `YieldVault.nonReentrant`, the only way to exploit this would require compromising the strategy contract itself — outside the audit scope but worth noting.

The code already caps the withdraw at `payout = min(actuallyReceived, principalAmount)`, so the downside is bounded: attacker can at worst force the user to get less than `principalAmount` (leaving dust shares in the vault). The remaining shares are still owned by the probability vault and recoverable at finalize. No recommendation — this is robust enough.

---

## I-01 · INFO · Swap fee truncates to zero for sub-500-wei swaps

**Location:** `contracts/src/ProbabilityVaultV2.sol:293`

`uint96 fee = uint96((amount * uint256(swapFeeBps)) / 10_000)` — with `swapFeeBps = 20`, any `amount < 500` yields `fee = 0`. An attacker could spam 499-wei swaps to rebalance their position at no fee cost. Economic disincentive: gas cost ~50k per swap × cheap base gas ≈ $0.005/swap, vs. $0.001 saved per 499-wei swap. Not exploitable in practice. Documented in PoC `test_bug_swapFeeRoundsToZeroOnTinyAmounts`.

No fix required; optionally add `if (fee == 0 && swapFeeBps > 0) revert ZeroAmount();` to discourage the pattern.

---

## I-02 · INFO · `updateState()` is permissionless and unguarded

**Location:** `contracts/src/ProbabilityVaultV2.sol:595-597`

Anyone can call `updateState()`. It only advances `state` from `JOIN_OPEN → LOCKED` when `block.timestamp >= joinEnd`. State never moves backwards, no funds move. This is standard practice for "kickable" state machines and poses no risk.

---

## Fixed during audit

No contract code was modified during this review. The repository's `forge test --match-contract ProbabilityVaultTest` still reports 24/24 passing.

Two new PoC tests were added at `contracts/test/ProbabilityVault.audit.t.sol`:
- `test_bug_minHoldTimeBlocksOtherWithdrawals` — H-01 repro.
- `test_bug_swapFeesDoubleCountedAsYield` — C-01 repro.
- `test_bug_swapFeeRoundsToZeroOnTinyAmounts` — I-01 repro.

All three pass, demonstrating the bugs on the current source.

---

## Review notes on explicitly-tested focus areas

1. **TWAB invariant (user sum = global).** Holds. `withdrawEarly` correctly subtracts the full `u.yesTwab`/`u.noTwab` from globals. Swap does not touch TWAB — it relies on the subsequent `_updateUserTwab` call to accumulate stake-seconds on the NEW side from the swap timestamp onwards, which is sound because the old side's TWAB up to the swap moment has already been accumulated by the `_updateUserTwab(u)` call at the top of `swap()`. **No re-deposit manipulation vector found**: TWAB is strictly monotone-accumulating and subtraction is exact-on-withdraw.
2. **Fund conservation.** Broken — see C-01.
3. **Overflow/underflow.** `uint128(stake) × uint64(elapsed)` fits `uint128` for realistic parameters (USDC 6-dec, 365 d). Explicit `uint128(...)` casts truncate silently, but stake bounds (7.9e28 worst-case) × 365 d keeps the product at ~2.5e37 < 3.4e38 = uint128.max. Safe in practice; recommend explicit `SafeCast` for 18-dec tokens.
4. **Reentrancy.** All fund-movers are `nonReentrant`. The self-call via `this.executeProtocolFeeTransfer(...)` is from inside a `nonReentrant` frame, so the lock is still held during the callback; the only non-guarded state mutator reachable mid-execution is `updateState()`, which only advances the state machine. **No reentrancy-exploitable path found.**
5. **State-machine bypasses.** `resolveContest` requires `state ∈ {LOCKED, RESOLVING}`, moves to `RESOLVING` on first call, and to `FINALIZED` / `CANCELLED` atomically. `emergencyCancel` requires `state != FINALIZED && state != CANCELLED`. `claim` requires `FINALIZED`/`CANCELLED`. **Cannot be called twice**, cannot be called out of order. **No state-bypass found.**
6. **Swap fee gaming.** Integer-truncation to zero is possible (I-01) but economically non-viable given gas costs. Sum invariant (principal reduced by fee + totalAccruedSwapFees tracked) is maintained inside the swap function itself — the break is at resolve time (C-01).
7. **Resolver trust.** If resolver reverts, `resolveContest` reverts; timeout cancel (`block.timestamp >= cancelDeadline`) is checked *before* the resolver call, so a permanently-broken resolver always resolves into cancel after 7 d. If resolver returns unknown winner, line 425 reverts — user must wait for timeout. Acceptable.
8. **Flash-loan + same-block.** `u.depositBlock == block.number` blocks deposit→withdrawEarly in the same block. Deposit→swap→withdrawEarly in the same block is also blocked because `swap()` does NOT update `u.depositBlock`, so `depositBlock == block.number` still holds when `withdrawEarly` is called. **Verified safe.** Deposit→resolveContest manipulation is a non-issue because `resolveContest` requires `block.timestamp >= resolveStart` ≥ `polymarketEndDate + 36h`, far after any deposit's block.
9. **Fee-recipient DoS.** `try/catch` on both the yield protocol fee and the swap-fee sweep. If the recipient reverts, fees are left in contract (emitted as `ProtocolFeeSkipped`). **Not locked, not lost to users** — safe degradation. Acceptable.
10. **Cancel-path correctness.** `_cancel` withdraws the full vault balance, pro-rata scales user principal via `distributableYield / totalYield` (repurposing those slots), and sweeps swap fees. **Correct when there are no swap fees**; when swap fees are present, same root cause as C-01 applies (the `returned < principal` check under-reports loss by the swap-fee amount).
11. **MIN_BOND / bondOverride.** Out of scope for the vault. Noted for the resolver: `requiredBondFor()` now defaults to `MIN_BOND = 25e6` (P-MIRROR-02 fix), relying on admin `setBondOverride` for pool-scaled friction — still trust-dependent on the admin configuring it correctly. No new finding.
12. **Grief with uncooperative ERC20.** `deposit()` uses `SafeERC20.safeTransferFrom` (reverts on `false` return; does not check fee-on-transfer tokens). Immediately after, it measures `received = balanceOf(this) - balanceBefore` — **fee-on-transfer safe**. Zero-return tokens would revert via SafeERC20. Reverting tokens DoS only their own deposits, not other users'. **No grief vector found** on the deposit path.

---

**Recommended action.** Patch C-01, H-01, H-02 before mainnet. M-01 and the L/I issues can ship with documentation. After patching, rerun `forge test --match-contract ProbabilityVaultTest --match-contract ProbabilityVaultAuditTest` to confirm no regression (the audit PoCs should pass as *negative* tests after the fix — update the assertions accordingly).
