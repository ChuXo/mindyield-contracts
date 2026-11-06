# Deployment checklist

Run through this for every new or redeployed contract. Add a line whenever an audit/finding teaches something.

## Before deploying
- [ ] `forge test` fully green; `forge build` with the pinned solc.
- [ ] Open findings in `docs/internal-audits/` are all **fixed in the code being deployed** (or explicitly
      accepted with a reason). Currently relevant:
  - [ ] `2026-11-LOTTERY_FEE_ACCOUNTING.md` — a new lottery implementation MUST use
        `totalOwed = totalDebt + yieldBuffer` (no `accumulatedProtocolFees`). Verify the three
        `test_protocolFee_*` regression tests are present and passing.
- [ ] Accounting invariant: for any vault/lottery holding funds in a strategy, "owed by the strategy" must
      only include amounts the strategy actually holds. Anything withdrawn into the contract (fees, unclaimed
      prizes, refund reserves) is NOT owed by the strategy.
- [ ] Clone implementations are immutable: any fix means a new implementation + new pools. Plan migration of
      deposits (users withdraw/redeposit) before announcing.

## After deploying
- [ ] Verify source on Basescan; compare runtime bytecode with `forge inspect <C> deployedBytecode`.
- [ ] Update README live addresses and the "Deployed code vs. main" table.
- [ ] Roles: owner/guardian/timelock set as intended; privileged setters behind the 48h Timelock.
- [ ] Operational: owner fee-withdrawal cadence documented (lottery: withdraw fees before each settle while any
      deployed version predates the fee-accounting fix).
