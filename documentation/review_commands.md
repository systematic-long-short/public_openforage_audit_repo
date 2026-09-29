# Review commands and build results

These commands compile production sources and deployment scripts. They do not run tests or deployment scripts.

## Pinned profiles

From the public repository root, initialize the existing dependency Gitlinks and compile both profiles:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=default forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
FOUNDRY_PROFILE=deploy forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
```

The candidate was compiled with Forge 1.3.5 and Solc 0.8.24. Both profiles compiled 130 inputs with zero compiler errors. Default code generation completed, but its child exited 1 on three runtime-size overages. Deploy exited 0, and all 22 first-party runtime/initcode pairs fit. A Deploy fit does not clear a Default size failure.

| Contract | Default runtime / initcode | Deploy runtime / initcode |
|---|---:|---:|
| Allowlist | 13,833 / 14,089 bytes | 12,214 / 12,424 bytes |
| AtRiskUSDProfitModule | 6,657 / 6,961 bytes | 5,396 / 5,697 bytes |
| AtRiskUSDStateModule | 24,057 / 24,669 bytes | 20,271 / 20,806 bytes |
| Blocklist | 9,249 / 9,499 bytes | 7,784 / 7,993 bytes |
| CustodianRegistry | 24,575 / 24,831 bytes | 20,367 / 20,581 bytes |
| DelegatingVestingWallet | 6,865 / 9,037 bytes | 5,914 / 7,401 bytes |
| FORAGETreasury | 20,905 / 21,197 bytes | 17,451 / 17,697 bytes |
| ForageGovernor | 27,458 / 35,161 bytes | 23,757 / 30,385 bytes |
| ForageGovernorTimelockGuard | 7,335 / 7,364 bytes | 6,298 / 6,325 bytes |
| ForageToken | 23,830 / 41,015 bytes | 23,050 / 38,856 bytes |
| ForageTokenStateModule | 16,669 / 16,839 bytes | 15,323 / 15,489 bytes |
| GuardianModule | 24,533 / 24,789 bytes | 19,381 / 19,595 bytes |
| HLTradingBridge | 24,520 / 24,812 bytes | 22,156 / 22,406 bytes |
| RISKUSD | 10,989 / 11,281 bytes | 9,166 / 9,411 bytes |
| RISKUSDVault | 21,711 / 22,003 bytes | 18,385 / 18,635 bytes |
| RISKUSDVaultModule | 23,988 / 24,460 bytes | 19,293 / 19,753 bytes |
| StakingQueue | 27,382 / 27,674 bytes | 23,203 / 23,453 bytes |
| StakingQueueModule | 24,443 / 24,565 bytes | 22,833 / 22,951 bytes |
| USDCTreasury | 27,671 / 27,963 bytes | 24,168 / 24,418 bytes |
| USDCTreasuryAccountingModule | 4,044 / 4,073 bytes | 3,059 / 3,086 bytes |
| VaultRegistry | 20,054 / 20,310 bytes | 17,367 / 17,581 bytes |
| atRISKUSD | 22,906 / 48,156 bytes | 19,214 / 40,499 bytes |

The Default runtime-size failures are ForageGovernor (27,458 bytes), StakingQueue (27,382 bytes), USDCTreasury (27,671 bytes). Default initcode has no overage. CustodianRegistry is 1 byte below EIP-170; atRISKUSD initcode is 48,156 bytes, 996 bytes below EIP-3860. Deploy has no runtime or initcode overage; USDCTreasury is 24,168 runtime bytes, 408 bytes below EIP-170.

## ABI and storage review

The direct map remains 59 files: 33 sources/interfaces/modules, 18 ABI files, and 8 selected scripts/interfaces. C9 changes the already-mapped `RISKUSDVault.sol`; no mapped ABI or selected script changed, and no new first-party source/interface/module/ABI mapping was added. The mapped ABI bytes match the exact source. Seventeen ABI files have compiler source definitions; `FoundationTreasury.json` remains source-less.

```bash
forge inspect --root openforage_smart_contracts Allowlist abi --json
forge inspect --root openforage_smart_contracts Allowlist storageLayout --build-info --json
```

Repeat ABI inspection for each source-backed artifact. The retained historical storage check remains red at 14 OK rows and 7 divergences. This candidate did not change that baseline. A layout comparison does not prove an old proxy's storage or migration safety.

## Static review and test boundary

The prior source-triage record lists 28 Queue rows and 44 Token rows, with 28 Queue rows justified and 43 Token rows justified plus one Token script row fixed; those source-triage statuses remain separate from the introduced analyzer-row review. Independent review agrees with 187 introduced analyzer-row dispositions at their stated source-bounded scope: 61 Semgrep, 89 reused Slither, and 37 rederived Slither rows. One separate scanner-coverage issue remains under private repair, so no exact-bound Semgrep or full static pass is claimed. Pre-existing analyzer rows remain open, and the earlier `SL-28` RISKUSDVault entry still requires a current-source rebind.

Full Slither, configured Semgrep, and the full static-audit route were not rerun on this public candidate. The two Windows CLI rows remain failed; no Visual Studio license or toolchain was installed, purchased, or accepted. No first-party contract test, fuzz/formal campaign, Forge test, Anvil, runtime, gas, RPC, chain, deployment, or Octane command was run. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved.
