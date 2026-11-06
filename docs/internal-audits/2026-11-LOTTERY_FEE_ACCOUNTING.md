# Finding: protocol fees counted as owed by the strategy (NoLossLotteryV2 / V3)

- **Reported:** 2026-11-02 by KupiaSec (unsolicited outreach, no engagement). Verified by us 2026-11-06.
- **Severity:** Low. No loss of principal or funds; yield *timing* shifts between rounds/winners.
- **Status:** Fixed on `main` (source + regression tests). **Not deployed** — see "Live deployment".

## Root cause
`_harvestPrize()` and `getCurrentPrizePool()` computed

    totalOwed = totalDebt + yieldBuffer + accumulatedProtocolFees

and harvested only `strategyValue - totalOwed`. But the protocol fee is skimmed from a prize that was
**already withdrawn** from the strategy, so the fee USDC sits in the lottery contract
(`withdrawProtocolFees()` pays from its balance). Subtracting it again from the strategy value left
`sum(unwithdrawn fees)` of yield in Aave every round.

Example (1,000 USDC yield/round, 2% fee): round 1 harvests 1,000 (fee 20 kept in contract); round 2
harvests 980 and leaves 20 in Aave; round 3 leaves ~40 ... ~180 after ten rounds. Winners get ~4% less
than the round produced (steady state, fees never withdrawn); voided rounds refund less through
`claimRoundYield()`. The held-back yield is paid in the first round settled after the next
`withdrawProtocolFees()`.

## Fix
`totalOwed = totalDebt + yieldBuffer` in `NoLossLotteryV3._harvestPrize`, `NoLossLotteryV3.getCurrentPrizePool`,
`NoLossLotteryV2._harvestPrize` and the V2 prize-pool view. Fees are never in the strategy, so they are never
subtracted from it.

## Regression tests (`test/NoLossLotteryV3.t.sol`)
- `test_protocolFee_unwithdrawnFeesDoNotWithholdLaterYield` — 10 rounds, fees never withdrawn; strategy holds
  exactly principal after each harvest; every round pays ~980 of 1,000.
- `test_protocolFee_prizePoolViewIgnoresUnwithdrawnFees`
- `test_protocolFee_voidedRoundRefundsFullYieldAfterUnwithdrawnFees`

Before the fix these failed with exactly the reported numbers (20 USDC stranded after round 1).

## Live deployment (action needed)
Pools are EIP-1167 clones of an immutable implementation (`0xdefe76a5…db45`), so the live pools cannot be
patched. Until a new implementation + factory/pools are deployed:

1. **Mitigation:** the owner calls `withdrawProtocolFees()` **before every `settleRound()`** (or at least
   before each draw). That zeroes `accumulatedProtocolFees`, so nothing is held back.
2. The yield currently stranded is not lost: it is harvested by the next round after fees are withdrawn.
3. Do not redeploy just for this; fold it into the next lottery deployment (it will also carry the pending
   pause-architecture changes) and migrate pools then.

## Remediation plan for the live pools (TODO — not done yet)
Tracked here so it is not forgotten. Do these when the next lottery deployment is prepared:

1. [ ] Deploy a new `NoLossLotteryV3` implementation built from `main` (contains this fix) and a new
       `NoLossLotteryFactory` pointing at it, together with the pending pause-architecture change.
2. [ ] Create the new weekly/monthly pools from the new factory; verify source on Basescan and compare runtime
       bytecode with `forge inspect NoLossLotteryV3 deployedBytecode`.
3. [ ] Migrate: announce, let current rounds settle, owner calls `withdrawProtocolFees()` then `settleRound()`, so
       all stranded yield is paid out; users withdraw from the old pools and deposit into the new ones;
       point the app/contracts config at the new addresses.
4. [ ] Update README addresses + "Deployed code vs. main" table; mark the old pools superseded.
5. [ ] Until step 3 is finished: owner runs `withdrawProtocolFees()` before every `settleRound()` on both live
       pools (weekly `0xbe007B…8B08`, monthly `0xEb1a9e…3465`).

## Lessons / invariants to keep (see `docs/DEPLOYMENT_CHECKLIST.md`)
- Every value counted as "owed by the strategy" must actually be held by the strategy. Fees, prizes awaiting
  claim and anything already withdrawn are held by the contract.
- Add an invariant test: after any harvest, `strategy.getTotalValue() ≈ totalDebt + yieldBuffer`.
