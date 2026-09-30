# Review commands and build results

These commands compile production sources and deployment scripts. They do not run tests or deployment scripts. The current source dispositions are in [`Analysis 9`](smart_contract_audits/2026-09-29-analysis-9-dispositions.md) and [`Analysis 10`](smart_contract_audits/2026-09-30-analysis-10-dispositions.md).

## Pinned profiles

From the public repository root, initialize the existing dependency Gitlinks and compile both profiles:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=default forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
FOUNDRY_PROFILE=deploy forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
```

Forge 1.3.5 and Solc 0.8.24 compiled 130 public inputs in each profile with zero compiler errors. Default code generation completed, but the child exited 1 on three EIP-170 runtime-size overages: ForageGovernor is 27,842 bytes (3,266 over), StakingQueue is 27,382 bytes (2,806 over), and USDCTreasury is 27,723 bytes (3,147 over). Default initcode has no overage. ForageToken fits at 23,835 runtime bytes, 741 below EIP-170. Deploy exited 0 and all 22 first-party runtime/initcode pairs fit; ForageToken is 23,437 runtime bytes (1,139 below) and USDCTreasury is 24,210 (366 below). A Deploy fit does not clear a Default size failure.

| Contract | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 13,833 / 14,089 (+10,743 / +35,063) | 12,214 / 12,424 (+12,362 / +36,728) |
| AtRiskUSDProfitModule | 7,710 / 8,031 (+16,866 / +41,121) | 7,033 / 7,348 (+17,543 / +41,804) |
| AtRiskUSDStateModule | 23,989 / 24,601 (+587 / +24,551) | 20,132 / 20,667 (+4,444 / +28,485) |
| Blocklist | 9,249 / 9,499 (+15,327 / +39,653) | 7,784 / 7,993 (+16,792 / +41,159) |
| CustodianRegistry | 24,575 / 24,831 (+1 / +24,321) | 20,367 / 20,581 (+4,209 / +28,571) |
| DelegatingVestingWallet | 6,865 / 9,037 (+17,711 / +40,115) | 5,914 / 7,401 (+18,662 / +41,751) |
| FORAGETreasury | 20,905 / 21,197 (+3,671 / +27,955) | 17,451 / 17,697 (+7,125 / +31,455) |
| ForageGovernor | 27,842 / 37,107 (-3,266 / +12,045) | 24,072 / 32,154 (+504 / +16,998) |
| ForageGovernorTimelockGuard | 8,897 / 8,926 (+15,679 / +40,226) | 7,752 / 7,779 (+16,824 / +41,373) |
| ForageToken | 23,835 / 45,965 (+741 / +3,187) | 23,437 / 43,224 (+1,139 / +5,928) |
| ForageTokenStateModule | 21,579 / 21,784 (+2,997 / +27,368) | 19,269 / 19,470 (+5,307 / +29,682) |
| GuardianModule | 24,536 / 24,792 (+40 / +24,360) | 19,381 / 19,595 (+5,195 / +29,557) |
| HLTradingBridge | 24,532 / 24,824 (+44 / +24,328) | 22,184 / 22,434 (+2,392 / +26,718) |
| RISKUSD | 10,989 / 11,281 (+13,587 / +37,871) | 9,166 / 9,411 (+15,410 / +39,741) |
| RISKUSDVault | 21,937 / 22,229 (+2,639 / +26,923) | 18,550 / 18,800 (+6,026 / +30,352) |
| RISKUSDVaultModule | 24,031 / 24,503 (+545 / +24,649) | 19,336 / 19,796 (+5,240 / +29,356) |
| StakingQueue | 27,382 / 27,674 (-2,806 / +21,478) | 23,203 / 23,453 (+1,373 / +25,699) |
| StakingQueueModule | 24,451 / 24,573 (+125 / +24,579) | 22,853 / 22,971 (+1,723 / +26,181) |
| USDCTreasury | 27,723 / 28,015 (-3,147 / +21,137) | 24,210 / 24,460 (+366 / +24,692) |
| USDCTreasuryAccountingModule | 4,044 / 4,073 (+20,532 / +45,079) | 3,059 / 3,086 (+21,517 / +46,066) |
| VaultRegistry | 20,054 / 20,310 (+4,522 / +28,842) | 17,367 / 17,581 (+7,209 / +31,571) |
| atRISKUSD | 23,059 / 48,241 (+1,517 / +911) | 19,297 / 40,443 (+5,279 / +8,709) |


## ABI and storage review

The direct map contains 59 files: 33 sources/interfaces/modules, 18 ABI files, and 8 selected scripts/interfaces. The exact private inventory has no first-party source/interface/module/ABI path outside the map. All 59 mapped files match the exact private source. Seventeen ABI files have compiler source definitions; `FoundationTreasury.json` remains the source-less orphan.

```bash
forge inspect --root openforage_smart_contracts Allowlist abi --json
forge inspect --root openforage_smart_contracts Allowlist storageLayout --build-info --json
```

Repeat ABI inspection for each source-backed artifact. The source-matched storage-baseline comparison remains red at 16 OK rows and 7 historical divergences; no baseline changed. This is not a fresh public-tree storage check, and no layout comparison proves an old proxy's storage or migration safety.

## Static review and test boundary

The earlier public table retains 72 source-triage rows (28 Queue, 17 Semgrep, 27 Slither); all 72 independent-review statuses remain pending. The separate analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row names each cited candidate file's Git blob SHA-1, which identifies the exact file bytes in this candidate tree; `ef049358efb6496f8304faef11a99c34d2610e62` is the previous PR #9 head and base of this update, not the source of these lines. Forty rows have bounded source-only review and seven stale or unresolved rows remain pending. `SL-28` still needs a current-source rebind. No fresh full `audit-static` pass is established; retained Slither and Semgrep results remain red, per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The retained Slither and Semgrep results remain red; per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open. The two Windows CLI rows remain failed; no Visual Studio license or toolchain was installed, purchased, or accepted. No first-party contract test, fuzz/formal campaign, Forge test, Anvil, runtime, gas, RPC, chain, deployment, or Octane command was run. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved.
