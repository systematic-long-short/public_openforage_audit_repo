# Review commands and build results

These commands compile production sources and deployment scripts. They do not run tests or deployment scripts. The current source dispositions are in [`Analysis 9`](smart_contract_audits/2026-09-29-analysis-9-dispositions.md), [`Analysis 10`](smart_contract_audits/2026-09-30-analysis-10-dispositions.md), [`Analysis 11`](smart_contract_audits/2026-10-01-analysis-11-dispositions.md), [`Analysis 12`](smart_contract_audits/2026-10-07-analysis-12-dispositions.md), and [`Analysis 13`](smart_contract_audits/2026-10-09-analysis-13-dispositions.md); the 2026-10-09 whole-source update and declared limits are in [`post-scan review`](smart_contract_audits/2026-10-09-post-scan-update.md), while the whole-source review and its declared limits are in the [`pre-scan review`](smart_contract_audits/2026-10-07-pre-scan-review.md).

## 2026-10-09 measured checks

The two Forge profiles compiled 137 source inputs each and produced 39 first-party runtime/initcode artifacts. The Default size child exited 1 on the six listed EIP-170 runtime rows; Deploy exited 0 with all artifacts fitting. The complete current table appears above.

The public suppression policy is byte-equal to the private policy at the source ref: 523 R37 entries, 521 `idDigest` and two `stableIdentity`. The public checker passed each of the two retained raw Slither scans with `OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37_PASS detectors=523 suppressions=523` (exit 0). The retained raw scan run IDs are `01118ef7-77f3-4e80-892d-b9f375ee89ec` and `e4aa1de9-6b4a-4067-b051-7925c596c788`; each had `success=true` and 523 detectors, while its Slither child exited 255. This is not a fresh analyzer run.

`node script/check_semgrep_rule_coverage.js --preflight` exited 1 on both the published base and candidate with `OPENFORAGE_PUBLIC_SEMGREP_COVERAGE_FAIL public source/import/policy input changed abi/Allowlist.json`. The audit-receipt checker is absent on both: its `--help` command exited 1 with `MODULE_NOT_FOUND`. The four `.semgrep` manifest/config inputs are byte-identical on base and candidate, and the source manifest is stale for changed `abi/Allowlist.json`. No receipt/reuse inventory file or receipt checker exists on either tree. The retained static triage records 139 Slither MATCH rows, one justified new default-empty deferral row, and four Semgrep MATCH rows. Newly introduced analyzer rows have per-row review status in the public analyzer table; pre-existing rows remain. No Semgrep pass or receipt-checker pass is claimed.

`check_i15_setters.js --json` passed on both trees with 15/15 checks. `check_no_legacy_transport.js` passed on both with 50 files, 11 targets, 13 patterns, and zero matches. The 20 public ABIs are byte-equal to private; 19 match compiler definitions and `FoundationTreasury.json` remains source-less.

## Pinned profiles

From the public repository root, initialize the existing dependency Gitlinks and compile both profiles:

```bash
git submodule update --init --recursive
FOUNDRY_PROFILE=default forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
FOUNDRY_PROFILE=deploy forge build --root openforage_smart_contracts --sizes --build-info --skip 'test/**' --offline
```

Forge 1.3.5 and Solc 0.8.24 compiled 137 public source inputs in each profile. Default code generation completed with zero compiler errors; its size child exited 1 on six EIP-170 runtime overages: ForageGovernor 27,212 bytes (2,636 over), HLTradingBridge 24,787 bytes (211 over), RISKUSDVaultModule 24,820 bytes (244 over), StakingQueue 27,953 bytes (3,377 over), StakingQueueModule 25,148 bytes (572 over), and USDCTreasury 24,905 bytes (329 over). The Default initcode rows have no EIP-3860 overage. Deploy exited 0 and all 39 first-party runtime/initcode artifacts fit.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 15,058 / 15,314 (+9,518 / +33,838) | 13,303 / 13,513 (+11,273 / +35,639) |
| AtRiskUSDProfitModule | 16,270 / 16,604 (+8,306 / +32,548) | 14,794 / 15,117 (+9,782 / +34,035) |
| AtRiskUSDStateModule | 23,267 / 23,907 (+1,309 / +25,245) | 20,642 / 21,205 (+3,934 / +27,947) |
| AtRiskUSDWeeklyExitModule | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| Blocklist | 9,711 / 9,967 (+14,865 / +39,185) | 8,175 / 8,384 (+16,401 / +40,768) |
| CustodianRegistry | 21,533 / 34,516 (+3,043 / +14,636) | 17,435 / 28,865 (+7,141 / +20,287) |
| CustodianRegistryCapitalModule | 12,545 / 12,651 (+12,031 / +36,501) | 11,030 / 11,125 (+13,546 / +38,027) |
| CustodianRegistryCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| DelegatingVestingWallet | 7,333 / 9,505 (+17,243 / +39,647) | 6,246 / 7,733 (+18,330 / +41,419) |
| FORAGETreasury | 24,295 / 27,665 (+281 / +21,487) | 20,054 / 22,729 (+4,522 / +26,423) |
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
| GuardianModule | 24,297 / 24,553 (+279 / +24,599) | 19,808 / 20,022 (+4,768 / +29,130) |
| HLTradingBridge | 24,787 / 34,095 (-211 / +15,057) | 23,072 / 31,235 (+1,504 / +17,917) |
| HLTradingBridgeCapitalModule | 8,826 / 8,926 (+15,750 / +40,226) | 7,722 / 7,818 (+16,854 / +41,334) |
| HLTradingBridgeCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsHostStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsModule | 1,536 / 1,579 (+23,040 / +47,573) | 1,240 / 1,279 (+23,336 / +47,873) |
| HLTradingBridgeReturnCapsModuleStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| RISKUSD | 12,324 / 12,616 (+12,252 / +36,536) | 10,418 / 10,663 (+14,158 / +38,489) |
| RISKUSDVault | 22,135 / 22,427 (+2,441 / +26,725) | 18,655 / 18,905 (+5,921 / +30,247) |
| RISKUSDVaultModule | 24,820 / 25,285 (-244 / +23,867) | 20,830 / 21,283 (+3,746 / +27,869) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,953 / 28,245 (-3,377 / +20,907) | 23,934 / 24,184 (+642 / +24,968) |
| StakingQueueModule | 25,148 / 25,277 (-572 / +23,875) | 24,376 / 24,501 (+200 / +24,651) |
| USDCTreasury | 24,905 / 29,445 (-329 / +19,707) | 21,641 / 25,386 (+2,935 / +23,766) |
| USDCTreasuryAccountingModule | 12,879 / 12,958 (+11,697 / +36,194) | 11,086 / 11,161 (+13,490 / +37,991) |
| USDCTreasuryProfitPolicyModule | 4,121 / 4,165 (+20,455 / +44,987) | 3,353 / 3,392 (+21,223 / +45,760) |
| VaultRegistry | 21,051 / 21,307 (+3,525 / +27,845) | 18,681 / 18,895 (+5,895 / +30,257) |
| atRISKUSD | 23,803 / 48,291 (+773 / +861) | 19,850 / 41,534 (+4,726 / +7,618) |


## ABI and storage review

The direct map contains 69 files: 40 sources/interfaces/libraries/modules, 20 ABI files, 8 selected scripts/interfaces, and 1 reviewed suppression policy. The exact private inventory has no first-party source/interface/library/module/ABI path outside the map. All 69 mapped files, including the suppression policy, match the exact private source. Nineteen ABI files have compiler source definitions; `FoundationTreasury.json` remains the source-less orphan.

```bash
forge inspect --root openforage_smart_contracts Allowlist abi --json
forge inspect --root openforage_smart_contracts Allowlist storageLayout --build-info --json
```

Repeat ABI inspection for each source-backed artifact. The earlier 2026-10-08 source-matched comparison recorded 17 OK rows and seven inherited divergences; that is a dated snapshot. The later retained private checker run against byte-mapped source exited 1 with 26 matching rows and the same seven inherited divergences. The checker is absent from the public tree; no baseline change or fresh public-tree storage run is claimed. No layout comparison proves an old proxy's storage or migration safety.

## Static review and test boundary

The earlier public table retains 72 source-triage rows (28 Queue, 17 Semgrep, 27 Slither); all 72 independent-review statuses remain pending. The separate analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to the current candidate-file blob. The current previous-head and historical commit identities are classified in the audit scope and post-scan update. `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and older commits are historical. Forty rows have bounded source-only review and seven stale or unresolved rows remain pending. `SL-28` still needs a current-source rebind. No fresh full `audit-static` pass is established; retained analyzer findings remain, the public suppression validator passes against the retained raw scan, and the public Semgrep preflight remains red on the stale source manifest.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The retained Slither and Semgrep results remain red; per-ID Slither the public suppression validator passes against the retained raw scan; no fresh scanner run is claimed, and the scanner-coverage gap remains open. The two Windows CLI rows remain failed; no Visual Studio license or toolchain was installed, purchased, or accepted. No first-party contract test, fuzz/formal campaign, Forge test, Anvil, runtime, gas, RPC, chain, deployment, or Octane command was run. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved.
