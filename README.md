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
| YieldOptimizer (proxy) | `0xc62CACA6402A1c698aCf4f9D1F4E8Cd7D4Ae50F5` |
| Timelock (48h) | `0x03DA5EEdDCf6364Aaa20dc07c51687a9591d9d53` |
| Guardian | `0x807AE17d48699861e678259d391255f68Fe176a5` |
| YieldVault | `0x23fc0080f54d7c20b51e260a96ef3f31d5768176` |
| ContestFactoryV2 | `0x6e8fb429a6cf76d526e94bdf14e71eb6a54586a4` |
| ContestV2 (clone implementation) | `0x6C6B8Ce1b372407BE7bf1b43d5B12d9e256d7F9A` |
| NoLossLotteryFactory | `0x9fe85fc51ec7f90f3c1e5a1d747a66a13c354239` |
| NoLossLotteryV3 (clone implementation) | `0xdefe76a5542955e75d73e268e7fedd3fdc88db45` |
| Lottery pools, weekly / monthly (clones) | `0xbe007BDFaE905c7383a8912DdA3643c918D68B08` / `0xEb1a9e60Eb410971799FbF125140d3eB88Ed3465` |
| RandomnessManagerV2 | `0xfc58d853950e427c76e7a17462da0c3ae3f0c556` |
| ProbabilityVaultFactory | `0xD093Ea9c89dd08434Cd29B6F30434F90e8c9BCa6` |
| ProbabilityVaultV2 (clone implementation) | `0x5Eb5181838e8D4E972E66a8a3e78E4E601aDcf97` |
| PVAutoYieldAdapter | `0xAAA44960432981d6F41FAf7356a0c383F9232913` |
| PolymarketRelayResolver | `0xaf461283b155cac6b0c1bf4622f3faf97c2336cd` |
| AffiliateDistributor | `0x64a9b36EF2d0b7136e4807CF24f037B20138E78c` |

An earlier lottery stack (weekly `0xD304…5be7`, RandomnessManager `0x9c42…40d2`, factory `0xe5f0…e036`)
and an earlier prediction-market factory (`0xB2af…2b7a`) still exist on-chain but are **superseded**;
the app no longer uses them.

## Deployed code vs. `main`

State as of 2026-10-30. Every contract in the table above is **source-verified on Basescan**.

| Contract | `main` vs. mainnet |
|---|---|
| NoLossLotteryV3, RandomnessManagerV2, NoLossLotteryFactory, ProbabilityVaultV2, ProbabilityVaultFactory | Runtime bytecode identical to `main` (differences only in constructor-immutable slots) |
| AutoYieldVault, YieldOptimizer, Timelock, Guardian, PVAutoYieldAdapter, PolymarketRelayResolver, AffiliateDistributor | Verified on Basescan; the Basescan source is authoritative |
| `ContestFactoryV2`, `ContestV2`, `YieldVault` | **`main` is ahead of mainnet** — it contains the pause-architecture change that is not deployed yet. Use the Basescan source for what is live |

The pause-architecture change will go live through a new deployment behind the 48h Timelock.

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
