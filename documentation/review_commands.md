# Review commands and build results

These commands compile production sources and deployment scripts. They do not run tests or deployment scripts. The current source dispositions are in [`Analysis 9`](smart_contract_audits/2026-09-29-analysis-9-dispositions.md), [`Analysis 10`](smart_contract_audits/2026-09-30-analysis-10-dispositions.md), and [`Analysis 11`](smart_contract_audits/2026-10-01-analysis-11-dispositions.md); the whole-source review and its declared limits are in the [`pre-scan review`](smart_contract_audits/2026-10-02-pre-scan-review.md).

## Pinned profiles

From the public repository root, initialize the existing dependency Gitlinks and compile both profiles:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=default forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
FOUNDRY_PROFILE=deploy forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
```

Forge 1.3.5 and Solc 0.8.24 compiled 132 public inputs in each profile with zero compiler errors. Default code generation completed; its size child exited 1 with EIP-170 runtime overages: ForageGovernor 28,436 bytes (3,860 over); StakingQueue 27,439 bytes (2,863 over); USDCTreasury 27,905 bytes (3,329 over); EIP-3860 initcode overages: none. Deploy exited 0 and all 22 first-party contract runtime/initcode pairs fit. The table lists all 26 compiled contract/library artifacts. GuardianModule links GuardianAuthorityClassifier; ForageGovernorTimelockGuard links ForageGovernorTimelockMigrationGuard. GuardianAuthorityClassifier is 8,994/9,047 bytes in Default and 7,735/7,768 in Deploy; ForageGovernorTimelockMigrationGuard is 3,976/4,029 bytes in Default and 3,337/3,368 in Deploy.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 13,833 / 14,089 (+10,743 / +35,063) | 12,214 / 12,424 (+12,362 / +36,728) |
| AtRiskUSDProfitModule | 7,710 / 8,031 (+16,866 / +41,121) | 7,033 / 7,348 (+17,543 / +41,804) |
| AtRiskUSDStateModule | 24,471 / 25,083 (+105 / +24,069) | 20,907 / 21,442 (+3,669 / +27,710) |
| Blocklist | 9,335 / 9,585 (+15,241 / +39,567) | 7,807 / 8,016 (+16,769 / +41,136) |
| CustodianRegistry | 24,374 / 24,630 (+202 / +24,522) | 20,266 / 20,480 (+4,310 / +28,672) |
| DelegatingVestingWallet | 7,333 / 9,505 (+17,243 / +39,647) | 6,246 / 7,733 (+18,330 / +41,419) |
| FORAGETreasury | 24,542 / 24,834 (+34 / +24,318) | 21,624 / 21,874 (+2,952 / +27,278) |
| ForageGovernor | 28,436 / 46,948 (-3,860 / +2,204) | 24,499 / 41,441 (+77 / +7,711) |
| ForageGovernorTimelockGuard | 17,838 / 18,060 (+6,738 / +31,092) | 16,367 / 16,557 (+8,209 / +32,595) |
| ForageGovernorTimelockMigrationGuard | 3,976 / 4,029 (+20,600 / +45,123) | 3,337 / 3,368 (+21,239 / +45,784) |
| ForageToken | 24,112 / 49,129 (+464 / +23) | 23,455 / 45,684 (+1,121 / +3,468) |
| ForageTokenStateModule | 24,458 / 24,671 (+118 / +24,481) | 21,704 / 21,912 (+2,872 / +27,240) |
| GovernancePayloadBudget | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| GuardianAuthorityClassifier | 8,994 / 9,047 (+15,582 / +40,105) | 7,735 / 7,768 (+16,841 / +41,384) |
| GuardianModule | 24,487 / 24,743 (+89 / +24,409) | 19,674 / 19,888 (+4,902 / +29,264) |
| HLTradingBridge | 24,529 / 24,821 (+47 / +24,331) | 22,577 / 22,827 (+1,999 / +26,325) |
| RISKUSD | 12,324 / 12,616 (+12,252 / +36,536) | 10,418 / 10,663 (+14,158 / +38,489) |
| RISKUSDVault | 21,977 / 22,269 (+2,599 / +26,883) | 18,582 / 18,832 (+5,994 / +30,320) |
| RISKUSDVaultModule | 24,131 / 24,596 (+445 / +24,556) | 19,858 / 20,311 (+4,718 / +28,841) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,439 / 27,731 (-2,863 / +21,421) | 23,275 / 23,525 (+1,301 / +25,627) |
| StakingQueueModule | 24,536 / 24,658 (+40 / +24,494) | 23,262 / 23,380 (+1,314 / +25,772) |
| USDCTreasury | 27,905 / 28,197 (-3,329 / +20,955) | 24,365 / 24,615 (+211 / +24,537) |
| USDCTreasuryAccountingModule | 4,044 / 4,073 (+20,532 / +45,079) | 3,059 / 3,086 (+21,517 / +46,066) |
| VaultRegistry | 21,051 / 21,307 (+3,525 / +27,845) | 18,681 / 18,895 (+5,895 / +30,257) |
| atRISKUSD | 23,471 / 49,135 (+1,105 / +17) | 19,584 / 41,505 (+4,992 / +7,647) |


## ABI and storage review

The direct map contains 61 files: 35 sources/interfaces/libraries/modules, 18 ABI files, and 8 selected scripts/interfaces. The exact private inventory has no first-party source/interface/library/module/ABI path outside the map. All 61 mapped files match the exact private source. Seventeen ABI files have compiler source definitions; `FoundationTreasury.json` remains the source-less orphan.

```bash
forge inspect --root openforage_smart_contracts Allowlist abi --json
forge inspect --root openforage_smart_contracts Allowlist storageLayout --build-info --json
```

Repeat ABI inspection for each source-backed artifact. The latest recorded source-matched storage comparison is red at 17 OK rows and 7 historical divergences; no baseline changed, and this update did not run a fresh public-tree storage check. No layout comparison proves an old proxy's storage or migration safety.

## Static review and test boundary

The earlier public table retains 72 source-triage rows (28 Queue, 17 Semgrep, 27 Slither); all 72 independent-review statuses remain pending. The separate analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to a candidate-file blob. The previous PR #9 head and base of this update is `01f4abe7768f03d2a21e6ab0a0221795d315d79b`; `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and older commits are historical. Forty rows have bounded source-only review and seven stale or unresolved rows remain pending. `SL-28` still needs a current-source rebind. No fresh full `audit-static` pass is established; retained Slither and Semgrep results remain red, suppression reconciliation is in progress, and the scanner-coverage gap remains open.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The retained Slither and Semgrep results remain red; per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open. The two Windows CLI rows remain failed; no Visual Studio license or toolchain was installed, purchased, or accepted. No first-party contract test, fuzz/formal campaign, Forge test, Anvil, runtime, gas, RPC, chain, deployment, or Octane command was run. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved.
