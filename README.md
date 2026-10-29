# MindYield Contracts

Solidity contracts for [MindYield](https://mindyield.io), a **no-loss** platform on Base: principal is
always returned, only DeFi-generated yield is distributed.

> ⚠️ **Unaudited.** Internal review only — see [SECURITY.md](SECURITY.md). Use at your own risk.

## Products

| Contract | What it does |
|---|---|
| `vaults/AutoYieldVault` | ERC-4626-style USDC vault that routes to Aave V3 / Compound V3 / Morpho; 2% performance fee on yield only |
| `NoLossLotteryV3` | Weekly/monthly lottery where the prize is the pool's yield (Chainlink VRF) |
| `ContestV2` + `ContestFactoryV2` | User-created contests with yield-funded prizes |
| `ProbabilityVaultV2` + factory | YES/NO yield prediction markets mirroring Polymarket |
| `resolvers/PolymarketRelayResolver` | Propose → 24h challenge (bond) → finalize outcome relay |
| `governance/Guardian`, `AffiliateDistributor`, … | Pause control, merkle referral payouts |

## Base mainnet (8453)

| Contract | Address |
|---|---|
| AutoYieldVault (USDC) | `0x20bCBDA9755512d46802174668b34DbC6f357a40` |
| YieldOptimizer | `0xc62CACA6402A1c698aCf4f9D1F4E8Cd7D4Ae50F5` |
| Timelock (48h) | `0x03DA5EEdDCf6364Aaa20dc07c51687a9591d9d53` |
| Guardian | `0x807AE17d48699861e678259d391255f68Fe176a5` |
| ContestFactoryV2 | `0x6e8fb429a6cf76d526e94bdf14e71eb6a54586a4` |
| ContestV2 (clone implementation) | `0x6C6B8Ce1b372407BE7bf1b43d5B12d9e256d7F9A` |
| ProbabilityVaultFactory | `0xB2af26B889618a4Dd2A8c608c05D7f09d7492b7a` |
| PVAutoYieldAdapter | `0xAAA44960432981d6F41FAf7356a0c383F9232913` |
| PolymarketRelayResolver | `0xaf461283b155cac6b0c1bf4622f3faf97c2336cd` |
| AffiliateDistributor | `0x64a9b36EF2d0b7136e4807CF24f037B20138E78c` |
| NoLossLotteryFactory | `0xe5f04a474aa83acb81ec34a06ce127dc0afde036` |
| NoLossLotteryV3 (clone implementation) | `0xFb851299841B48f56696923C3765c51A834f4CF8` |
| Lottery pools: weekly / monthly (clones) | `0xD3049097FB5653129abD83D6c890F3e2Cea45be7` / `0x8Caa6D5082Ed0694d69dcb9aE60D4DE43D164ad4` |
| RandomnessManagerV2 | `0x9c420dd94f30ebd1c62ecb946120274cdaea40d2` |

## Deployed code vs. `main`

`main` is the development branch and is **ahead of what is deployed** for some contracts. Do not assume
`main` equals mainnet. State as of 2026-10-29:

| Contract | Status |
|---|---|
| AutoYieldVault, YieldOptimizer (proxy + impl), Timelock, Guardian, ContestFactoryV2, ProbabilityVaultFactory, PVAutoYieldAdapter, PolymarketRelayResolver, AffiliateDistributor, YieldVault, ContestV2 impl | Source **verified on Basescan** — that source is authoritative for what is live |
| NoLossLotteryV3 impl (and thus the weekly/monthly clones) | Runtime bytecode matches this source as of the 2026-05-07 revision; **not yet verified on Basescan** |
| RandomnessManagerV2, NoLossLotteryFactory | Same length and structure as the 2026-05-07 revision; differences are constructor immutables. **Not yet verified on Basescan** |

Files on `main` with changes that are **not deployed yet** (compare against the Basescan source):
`ContestFactoryV2`, `ContestV2` (pause architecture), `ProbabilityVaultFactory`, `ProbabilityVaultV2`,
`YieldVault`, `RandomnessManager(V2)` and `lottery/NoLossLotteryV3` (hardened redeploy). They will go
live through a new deployment behind the 48h Timelock.

To check any address yourself, compare its runtime code with the compiled output:

```bash
cast code <address> --rpc-url https://mainnet.base.org   # strip the trailing CBOR metadata, expect differences only in immutable slots
forge inspect <Contract> deployedBytecode
```

## Build & test

```bash
git clone --recurse-submodules <this repo>
cd mindyield-contracts
forge build
forge test --jobs 2     # via_ir is memory hungry; 4–6 GB peak
```

Solidity 0.8.20, `via_ir`, optimizer runs = 1 (contest bytecode is close to the 24,576 B limit — check `forge build --sizes`).

## Design notes

- AutoYieldVault: virtual-shares offset against first-depositor inflation, same-block flash-loan guard,
  fee watermark re-anchored on every deposit/withdraw.
- Pauses never block withdrawals.
- Contest/market clones are immutable; upgrades only affect new instances.

## License

MIT — see [LICENSE](LICENSE).
