# Security Policy

## Status: NOT independently audited

These contracts have had **internal review only** (see `docs/internal-audits/`). No third-party
audit has been completed. Do not treat them as audited. Deposits on mainnet are small and
at your own risk. An independent audit and a public bug bounty are planned.

## Reporting a vulnerability

Please report privately via GitHub's **"Report a vulnerability"** (Security → Advisories) on this repo.
Do not open public issues for security bugs or test against mainnet funds you don't own.
We aim to acknowledge within 72 hours.

## Trust model (summary)

- Privileged setters on the live AutoYieldVault sit behind a 48h `TimelockController`.
- A pause-only `Guardian` can halt deposits/harvests but never blocks withdrawals.
- Fee recipients are immutable or set-once; performance fee is hard-capped.
