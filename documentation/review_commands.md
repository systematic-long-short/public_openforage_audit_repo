# Review commands and build results

These commands compile production sources and deployment scripts. They do not run tests or deployment scripts. The current source dispositions are in [`Analysis 9`](smart_contract_audits/2026-09-29-analysis-9-dispositions.md), [`Analysis 10`](smart_contract_audits/2026-09-30-analysis-10-dispositions.md), and [`Analysis 11`](smart_contract_audits/2026-10-01-analysis-11-dispositions.md).

## Pinned profiles

From the public repository root, initialize the existing dependency Gitlinks and compile both profiles:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=default forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
FOUNDRY_PROFILE=deploy forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
```

Forge 1.3.5 and Solc 0.8.24 compiled 131 public inputs in each profile with zero compiler errors. Default code generation completed, but the child exited 1 on three EIP-170 runtime-size overages: ForageGovernor 28,646 bytes (4,070 over), StakingQueue 27,382 bytes (2,806 over), and USDCTreasury 27,779 bytes (3,203 over). Default initcode has no overage. ForageToken fits at 24,112 runtime bytes, 464 below EIP-170; its 49,125-byte initcode is 27 below EIP-3860. Deploy exited 0 and all 22 first-party contract runtime/initcode pairs fit. ForageGovernor is 24,564 runtime bytes (12 below EIP-170); USDCTreasury is 24,231 runtime bytes (345 below EIP-170). The table lists all 25 compiled contract/library artifacts. GuardianModule links GuardianAuthorityClassifier; the library is 6,658/6,711 bytes in Default and 5,756/5,787 in Deploy.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 13,833 / 14,089 (+10,743 / +35,063) | 12,214 / 12,424 (+12,362 / +36,728) |
| AtRiskUSDProfitModule | 7,710 / 8,031 (+16,866 / +41,121) | 7,033 / 7,348 (+17,543 / +41,804) |
| AtRiskUSDStateModule | 23,989 / 24,601 (+587 / +24,551) | 20,132 / 20,667 (+4,444 / +28,485) |
| Blocklist | 9,249 / 9,499 (+15,327 / +39,653) | 7,784 / 7,993 (+16,792 / +41,159) |
| CustodianRegistry | 24,374 / 24,630 (+202 / +24,522) | 20,266 / 20,480 (+4,310 / +28,672) |
| DelegatingVestingWallet | 6,865 / 9,037 (+17,711 / +40,115) | 5,914 / 7,401 (+18,662 / +41,751) |
| FORAGETreasury | 23,802 / 24,094 (+774 / +25,058) | 20,479 / 20,725 (+4,097 / +28,427) |
| ForageGovernor | 28,646 / 38,793 (-4,070 / +10,359) | 24,564 / 33,507 (+12 / +15,645) |
| ForageGovernorTimelockGuard | 9,779 / 9,808 (+14,797 / +39,344) | 8,613 / 8,640 (+15,963 / +40,512) |
| ForageToken | 24,112 / 49,125 (+464 / +27) | 23,455 / 45,828 (+1,121 / +3,324) |
| ForageTokenStateModule | 24,454 / 24,667 (+122 / +24,485) | 21,848 / 22,056 (+2,728 / +27,096) |
| GovernancePayloadBudget | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| GuardianAuthorityClassifier | 6,658 / 6,711 (+17,918 / +42,441) | 5,756 / 5,787 (+18,820 / +43,365) |
| GuardianModule | 23,073 / 23,329 (+1,503 / +25,823) | 17,972 / 18,186 (+6,604 / +30,966) |
| HLTradingBridge | 24,372 / 24,664 (+204 / +24,488) | 22,238 / 22,488 (+2,338 / +26,664) |
| RISKUSD | 10,989 / 11,281 (+13,587 / +37,871) | 9,166 / 9,411 (+15,410 / +39,741) |
| RISKUSDVault | 21,977 / 22,269 (+2,599 / +26,883) | 18,582 / 18,832 (+5,994 / +30,320) |
| RISKUSDVaultModule | 24,079 / 24,544 (+497 / +24,608) | 19,766 / 20,219 (+4,810 / +28,933) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,382 / 27,674 (-2,806 / +21,478) | 23,203 / 23,453 (+1,373 / +25,699) |
| StakingQueueModule | 24,451 / 24,573 (+125 / +24,579) | 22,853 / 22,971 (+1,723 / +26,181) |
| USDCTreasury | 27,779 / 28,071 (-3,203 / +21,081) | 24,231 / 24,481 (+345 / +24,671) |
| USDCTreasuryAccountingModule | 4,044 / 4,073 (+20,532 / +45,079) | 3,059 / 3,086 (+21,517 / +46,066) |
| VaultRegistry | 20,054 / 20,310 (+4,522 / +28,842) | 17,367 / 17,581 (+7,209 / +31,571) |
| atRISKUSD | 23,059 / 48,241 (+1,517 / +911) | 19,297 / 40,443 (+5,279 / +8,709) |


## ABI and storage review

The direct map contains 60 files: 34 sources/interfaces/libraries/modules, 18 ABI files, and 8 selected scripts/interfaces. The exact private inventory has no first-party source/interface/library/module/ABI path outside the map. All 60 mapped files match the exact private source. Seventeen ABI files have compiler source definitions; `FoundationTreasury.json` remains the source-less orphan.

```bash
forge inspect --root openforage_smart_contracts Allowlist abi --json
forge inspect --root openforage_smart_contracts Allowlist storageLayout --build-info --json
```

Repeat ABI inspection for each source-backed artifact. The source-matched storage-baseline comparison remains red at 16 OK rows and 7 historical divergences; no baseline changed. This is not a fresh public-tree storage check, and no layout comparison proves an old proxy's storage or migration safety.

## Static review and test boundary

The earlier public table retains 72 source-triage rows (28 Queue, 17 Semgrep, 27 Slither); all 72 independent-review statuses remain pending. The separate analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to a candidate-file blob. The previous PR #9 head and base of this update is `6efd4cd86a9b2fec7f484c0da073f71385900308`; `ef049358efb6496f8304faef11a99c34d2610e62` and older commits are historical. Forty rows have bounded source-only review and seven stale or unresolved rows remain pending. `SL-28` still needs a current-source rebind. No fresh full `audit-static` pass is established; retained Slither and Semgrep results remain red, suppression reconciliation is in progress, and the scanner-coverage gap remains open.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The retained Slither and Semgrep results remain red; per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open. The two Windows CLI rows remain failed; no Visual Studio license or toolchain was installed, purchased, or accepted. No first-party contract test, fuzz/formal campaign, Forge test, Anvil, runtime, gas, RPC, chain, deployment, or Octane command was run. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved.
