# Security Policy

## Status: NOT independently audited

These contracts have had **internal review only** (see `docs/internal-audits/`). No third-party
audit has been completed. Do not treat them as audited. Deposits on mainnet are small and
at your own risk. An independent audit and a public bug bounty are planned.

## Reporting a vulnerability

Please report privately via GitHub's **"Report a vulnerability"** (Security → Advisories) on this repo.
Do not open public issues for security bugs or test against mainnet funds you don't own.
We aim to acknowledge within 72 hours.

## Known issues (fixed in source, not yet in deployed clones)

- **Lottery fee accounting (low, 2026-11):** `NoLossLotteryV2/V3._harvestPrize` treated unwithdrawn protocol fees as
  owed by the Aave strategy, so a fee-sized amount of yield was held back each round until `withdrawProtocolFees()`
  was called. No funds are lost. Fixed on `main`; live clones are immutable, so the owner withdraws fees before each
  settle until the next lottery deployment. Details: `docs/internal-audits/2026-11-LOTTERY_FEE_ACCOUNTING.md`.

## Trust model (summary)

- Privileged setters on the live AutoYieldVault sit behind a 48h `TimelockController`.
- A pause-only `Guardian` can halt deposits/harvests but never blocks withdrawals.
- Fee recipients are immutable or set-once; performance fee is hard-capped.
