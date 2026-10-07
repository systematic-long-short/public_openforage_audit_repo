# Review commands and build results

These commands compile production sources and deployment scripts. They do not run tests or deployment scripts. The current source dispositions are in [`Analysis 9`](smart_contract_audits/2026-09-29-analysis-9-dispositions.md), [`Analysis 10`](smart_contract_audits/2026-09-30-analysis-10-dispositions.md), and [`Analysis 11`](smart_contract_audits/2026-10-01-analysis-11-dispositions.md); the whole-source review and its declared limits are in the [`pre-scan review`](smart_contract_audits/2026-10-07-pre-scan-review.md).

## Pinned profiles

From the public repository root, initialize the existing dependency Gitlinks and compile both profiles:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=default forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
FOUNDRY_PROFILE=deploy forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
```

Forge 1.3.5 and Solc 0.8.24 compiled 137 public source inputs in each profile. Default code generation completed; the size child exited 1 with EIP-170 runtime overages: ForageGovernor 27,212 runtime (2,636 over); StakingQueue 27,697 runtime (3,121 over); EIP-3860 initcode overages: none. Deploy exited 0; 39 of 39 first-party runtime/initcode artifacts fit. The table covers all 39 first-party runtime/initcode artifacts, including linked libraries.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 15,058 / 15,314 (+9,518 / +33,838) | 13,303 / 13,513 (+11,273 / +35,639) |
| AtRiskUSDProfitModule | 16,270 / 16,604 (+8,306 / +32,548) | 14,794 / 15,117 (+9,782 / +34,035) |
| AtRiskUSDStateModule | 23,213 / 23,853 (+1,363 / +25,299) | 20,614 / 21,177 (+3,962 / +27,975) |
| AtRiskUSDWeeklyExitModule | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| Blocklist | 9,711 / 9,967 (+14,865 / +39,185) | 8,175 / 8,384 (+16,401 / +40,768) |
| CustodianRegistry | 21,533 / 34,516 (+3,043 / +14,636) | 17,435 / 28,865 (+7,141 / +20,287) |
| CustodianRegistryCapitalModule | 12,545 / 12,651 (+12,031 / +36,501) | 11,030 / 11,125 (+13,546 / +38,027) |
| CustodianRegistryCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| DelegatingVestingWallet | 7,333 / 9,505 (+17,243 / +39,647) | 6,246 / 7,733 (+18,330 / +41,419) |
| FORAGETreasury | 23,994 / 27,364 (+582 / +21,788) | 19,852 / 22,527 (+4,724 / +26,625) |
| FORAGETreasuryModule | 2,930 / 2,981 (+21,646 / +46,171) | 2,261 / 2,308 (+22,315 / +46,844) |
| ForageGovernor | 27,212 / 48,170 (-2,636 / +982) | 23,120 / 42,223 (+1,456 / +6,929) |
| ForageGovernorTimelockGuard | 20,284 / 20,506 (+4,292 / +28,646) | 18,528 / 18,718 (+6,048 / +30,434) |
| ForageGovernorTimelockMigrationGuard | 24,546 / 24,599 (+30 / +24,553) | 21,770 / 21,803 (+2,806 / +27,349) |
| ForageToken | 24,553 / 24,986 (+23 / +24,166) | 23,917 / 24,278 (+659 / +24,874) |
| ForageTokenStateModule | 24,525 / 40,292 (+51 / +8,860) | 22,223 / 37,544 (+2,353 / +11,608) |
| ForageTokenVoteEligibilitySyncQueue | 9,044 / 15,436 (+15,532 / +33,716) | 8,094 / 14,993 (+16,482 / +34,159) |
| ForageTokenVoteEligibilitySyncReplay | 6,191 / 6,234 (+18,385 / +42,918) | 6,700 / 6,739 (+17,876 / +42,413) |
| GovernancePayloadBudget | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| GuardianAuthorityClassifier | 12,838 / 12,891 (+11,738 / +36,261) | 10,855 / 10,888 (+13,721 / +38,264) |
| GuardianEmergencyPrincipalLane | 2,590 / 2,915 (+21,986 / +46,237) | 2,306 / 2,585 (+22,270 / +46,567) |
| GuardianModule | 24,238 / 24,494 (+338 / +24,658) | 19,761 / 19,975 (+4,815 / +29,177) |
| HLTradingBridge | 24,108 / 32,935 (+468 / +16,217) | 22,193 / 29,908 (+2,383 / +19,244) |
| HLTradingBridgeCapitalModule | 8,345 / 8,445 (+16,231 / +40,707) | 7,281 / 7,370 (+17,295 / +41,782) |
| HLTradingBridgeCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsHostStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsModule | 1,536 / 1,579 (+23,040 / +47,573) | 1,240 / 1,279 (+23,336 / +47,873) |
| HLTradingBridgeReturnCapsModuleStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| RISKUSD | 12,324 / 12,616 (+12,252 / +36,536) | 10,418 / 10,663 (+14,158 / +38,489) |
| RISKUSDVault | 22,135 / 22,427 (+2,441 / +26,725) | 18,655 / 18,905 (+5,921 / +30,247) |
| RISKUSDVaultModule | 24,460 / 24,925 (+116 / +24,227) | 20,482 / 20,935 (+4,094 / +28,217) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,697 / 27,989 (-3,121 / +21,163) | 23,669 / 23,919 (+907 / +25,233) |
| StakingQueueModule | 24,272 / 24,401 (+304 / +24,751) | 23,643 / 23,768 (+933 / +25,384) |
| USDCTreasury | 24,197 / 28,737 (+379 / +20,415) | 21,095 / 24,840 (+3,481 / +24,312) |
| USDCTreasuryAccountingModule | 12,879 / 12,958 (+11,697 / +36,194) | 11,086 / 11,161 (+13,490 / +37,991) |
| USDCTreasuryProfitPolicyModule | 4,121 / 4,165 (+20,455 / +44,987) | 3,353 / 3,392 (+21,223 / +45,760) |
| VaultRegistry | 21,051 / 21,307 (+3,525 / +27,845) | 18,681 / 18,895 (+5,895 / +30,257) |
| atRISKUSD | 23,520 / 47,954 (+1,056 / +1,198) | 19,552 / 41,208 (+5,024 / +7,944) |


## ABI and storage review

The direct map contains 69 files: 40 sources/interfaces/libraries/modules, 20 ABI files, 8 selected scripts/interfaces, and 1 reviewed suppression policy. The exact private inventory has no first-party source/interface/library/module/ABI path outside the map. All 69 mapped files, including the suppression policy, match the exact private source. Nineteen ABI files have compiler source definitions; `FoundationTreasury.json` remains the source-less orphan.

```bash
forge inspect --root openforage_smart_contracts Allowlist abi --json
forge inspect --root openforage_smart_contracts Allowlist storageLayout --build-info --json
```

Repeat ABI inspection for each source-backed artifact. The latest recorded source-matched storage comparison is red at 17 OK rows and 7 historical divergences; no baseline changed, and this update did not run a fresh public-tree storage check. No layout comparison proves an old proxy's storage or migration safety.

## Static review and test boundary

The earlier public table retains 72 source-triage rows (28 Queue, 17 Semgrep, 27 Slither); all 72 independent-review statuses remain pending. The separate analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to the current candidate-file blob. The previous PR #9 head and base of this update is `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; its parent `01f4abe7768f03d2a21e6ab0a0221795d315d79b` is historical. `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and older commits are historical. Forty rows have bounded source-only review and seven stale or unresolved rows remain pending. `SL-28` still needs a current-source rebind. No fresh full `audit-static` pass is established; retained analyzer findings remain, the public suppression validator passes against the retained raw scan, and the public Semgrep preflight remains red on the stale source manifest.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The retained Slither and Semgrep results remain red; per-ID Slither the public suppression validator passes against the retained raw scan; no fresh scanner run is claimed, and the scanner-coverage gap remains open. The two Windows CLI rows remain failed; no Visual Studio license or toolchain was installed, purchased, or accepted. No first-party contract test, fuzz/formal campaign, Forge test, Anvil, runtime, gas, RPC, chain, deployment, or Octane command was run. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved.
