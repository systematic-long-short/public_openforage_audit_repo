# OpenForage public contract review

This repository is a selective source snapshot for independent review. It is not a deployment repository or a copy of the private monorepo.

## 2026-10-11 post-scan source update

Analysis 14 scanned the previously published PR #9 head `1c1085499239962b543dae724f041414a2d4eecd`. This update records OpenForage's own source review, not an Octane result. No Octane analysis has run on this tree, and no future scan is promised or authorized. See the [Analysis 14 dispositions](documentation/smart_contract_audits/2026-10-11-analysis-14-dispositions.md) and the [2026-10-11 post-scan update](documentation/smart_contract_audits/2026-10-11-post-scan-update.md) for the source changes, independent-review status, measurements, and limits.

## Snapshot scope

The direct map contains 70 files: 40 Solidity source, interface, library, and module files; 21 ABI files; 8 selected deployment-script and interface files; and 1 reviewed suppression policy. Every first-party source, interface, library, module, and ABI path is mapped. The new ABI is `abi/ForageGovernorTimelockGuard.json`; all 21 ABI paths and all 40 source paths were rechecked. The eight Solidity files changed since the scan are listed with public source lines in the post-scan update. The linked migration-guard address matches the private build in both profiles and the deployment script. Both root dependency Gitlinks and all nine recursive pins remain unchanged. Vendor source stays behind those pins. Private audit records, run logs, packet text, deployment state, credentials, and non-allowlisted scripts and tooling are excluded.

No first-party contract test path is copied.

## Analyses 9–14 status

The Analysis 9–13 disposition pages retain each finding and related case with its latest completed critique verdict, source lines, and bounded reason. The [Analysis 14 dispositions](documentation/smart_contract_audits/2026-10-11-analysis-14-dispositions.md) add the 17 visible findings and the three separately listed findings Octane marked Automatically Acknowledged. Source review does not change an Octane status or mark a finding resolved. The 155 Analysis 1–8 identities remain unchanged in [`the historical record`](documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md). Warning 28 retains its dated missing-capture gap.

The linked disposition pages state the current bounded outcomes and remaining limits for earlier findings, including cash-backed withdrawal pricing, fresh-only deployment, the shared daily-cap behavior, and source-only gas bounds. Analysis 14 adds the weekly-exit reservation rule, a 40-epoch catch-up bound, a small-basis rounding limit, and the guardian and queue limits. No legacy-proxy, deployment, or current Octane closure is claimed.

The post-scan update reports the retained static evidence, the exact two-scan suppression check, and the measured public Semgrep and receipt-checker outcomes. It does not claim a fresh full analyzer pass.

## Policy boundaries

Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported. In the Blocklist, the legacy importer and interval-translation path are removed; fresh initialization sets the layout version and every state-changing entrypoint checks it before effects. The historical checkpoint lookup uses `wasBlockedAt`; the retained pre-checkpoint mapping is inert and remains only for layout. An independent source review accepts this Blocklist repair within a source-only bound; it proves no old-proxy or deployed-state behavior. The first upgrade still uses the authorizer in the implementation already installed. These rules do not prove every deployed proxy or upgrade path.

Profit belongs to the holders at recognition. Unpaid profit stays a separate claim and is paid only when cash arrives. Withdrawals use cash-backed share value and available cash; they promise no payment date. A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid that loss stay frozen through settlement.

The distributor is the trusted payer, not the recipient. Payment grants no system-account status or restricted-call permission.

## Build and verification limits

Forge 1.3.5 and Solc 0.8.24 compiled 137 public source inputs in each offline profile with the test tree skipped. Default had zero compiler errors and its size child exited 1 on eight EIP-170 runtime overages: ForageGovernor 28,053 bytes (3,477 over), ForageGovernorTimelockMigrationGuard 24,690 (114 over), GuardianModule 24,632 (56 over), HLTradingBridge 24,673 (97 over), RISKUSDVaultModule 24,820 (244 over), StakingQueue 27,953 (3,377 over), StakingQueueModule 25,421 (845 over), and USDCTreasury 24,905 (329 over). ForageGovernor initcode is 49,498 bytes (346 over). Deploy exited 0 and all 39 first-party runtime/initcode artifacts fit; StakingQueueModule has the tightest runtime margin at 65 bytes.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 15,058 / 15,314 (+9,518 / +33,838) | 13,303 / 13,513 (+11,273 / +35,639) |
| AtRiskUSDProfitModule | 16,270 / 16,604 (+8,306 / +32,548) | 14,794 / 15,117 (+9,782 / +34,035) |
| AtRiskUSDStateModule | 23,611 / 24,251 (+965 / +24,901) | 20,896 / 21,459 (+3,680 / +27,693) |
| AtRiskUSDWeeklyExitModule | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| Blocklist | 9,711 / 9,967 (+14,865 / +39,185) | 8,175 / 8,384 (+16,401 / +40,768) |
| CustodianRegistry | 21,533 / 34,516 (+3,043 / +14,636) | 17,435 / 28,865 (+7,141 / +20,287) |
| CustodianRegistryCapitalModule | 12,545 / 12,651 (+12,031 / +36,501) | 11,030 / 11,125 (+13,546 / +38,027) |
| CustodianRegistryCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| DelegatingVestingWallet | 7,333 / 9,505 (+17,243 / +39,647) | 6,246 / 7,733 (+18,330 / +41,419) |
| FORAGETreasury | 24,295 / 27,665 (+281 / +21,487) | 20,054 / 22,729 (+4,522 / +26,423) |
| FORAGETreasuryModule | 2,930 / 2,981 (+21,646 / +46,171) | 2,261 / 2,308 (+22,315 / +46,844) |
| ForageGovernor | 28,053 / 49,498 (-3,477 / -346) | 23,853 / 43,271 (+723 / +5,881) |
| ForageGovernorTimelockGuard | 20,771 / 20,993 (+3,805 / +28,159) | 18,843 / 19,033 (+5,733 / +30,119) |
| ForageGovernorTimelockMigrationGuard | 24,690 / 24,743 (-114 / +24,409) | 22,027 / 22,060 (+2,549 / +27,092) |
| ForageToken | 24,553 / 24,986 (+23 / +24,166) | 23,917 / 24,278 (+659 / +24,874) |
| ForageTokenStateModule | 24,525 / 40,292 (+51 / +8,860) | 22,223 / 37,544 (+2,353 / +11,608) |
| ForageTokenVoteEligibilitySyncQueue | 9,044 / 15,436 (+15,532 / +33,716) | 8,094 / 14,993 (+16,482 / +34,159) |
| ForageTokenVoteEligibilitySyncReplay | 6,191 / 6,234 (+18,385 / +42,918) | 6,700 / 6,739 (+17,876 / +42,413) |
| GovernancePayloadBudget | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| GuardianAuthorityClassifier | 12,838 / 12,891 (+11,738 / +36,261) | 10,855 / 10,888 (+13,721 / +38,264) |
| GuardianEmergencyPrincipalLane | 2,590 / 2,915 (+21,986 / +46,237) | 2,306 / 2,585 (+22,270 / +46,567) |
| GuardianModule | 24,632 / 24,888 (-56 / +24,264) | 20,118 / 20,332 (+4,458 / +28,820) |
| HLTradingBridge | 24,673 / 33,981 (-97 / +15,171) | 23,242 / 31,405 (+1,334 / +17,747) |
| HLTradingBridgeCapitalModule | 8,826 / 8,926 (+15,750 / +40,226) | 7,722 / 7,818 (+16,854 / +41,334) |
| HLTradingBridgeCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsHostStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsModule | 1,668 / 1,711 (+22,908 / +47,441) | 1,369 / 1,408 (+23,207 / +47,744) |
| HLTradingBridgeReturnCapsModuleStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| RISKUSD | 12,324 / 12,616 (+12,252 / +36,536) | 10,418 / 10,663 (+14,158 / +38,489) |
| RISKUSDVault | 22,135 / 22,427 (+2,441 / +26,725) | 18,655 / 18,905 (+5,921 / +30,247) |
| RISKUSDVaultModule | 24,820 / 25,285 (-244 / +23,867) | 20,830 / 21,283 (+3,746 / +27,869) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,953 / 28,245 (-3,377 / +20,907) | 23,934 / 24,184 (+642 / +24,968) |
| StakingQueueModule | 25,421 / 25,550 (-845 / +23,602) | 24,511 / 24,636 (+65 / +24,516) |
| USDCTreasury | 24,905 / 29,445 (-329 / +19,707) | 21,641 / 25,386 (+2,935 / +23,766) |
| USDCTreasuryAccountingModule | 12,879 / 12,958 (+11,697 / +36,194) | 11,086 / 11,161 (+13,490 / +37,991) |
| USDCTreasuryProfitPolicyModule | 4,121 / 4,165 (+20,455 / +44,987) | 3,353 / 3,392 (+21,223 / +45,760) |
| VaultRegistry | 21,051 / 21,307 (+3,525 / +27,845) | 18,681 / 18,895 (+5,895 / +30,257) |
| atRISKUSD | 24,069 / 48,901 (+507 / +251) | 20,182 / 42,120 (+4,394 / +7,032) |

All 21 ABI files match the mapped source; 20 have compiler source definitions and `FoundationTreasury.json` remains source-less. An earlier 2026-10-08 source-matched storage comparison recorded 17 matching rows and seven inherited divergences; that result is a dated snapshot. The later retained private checker run against byte-mapped source exited 1 with 26 matching rows and the same seven inherited divergences. The checker is absent from the public tree, so no fresh public-tree storage run is claimed.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The 47-row analyzer table records 7 Semgrep and 40 Slither identities; 40 are bounded source-only dispositions and seven remain pending. The earlier 72-row table remains separate with all independent reviews pending. Retained Slither and Semgrep results remain red; per-ID the public suppression validator passes against the retained raw scan; no fresh scanner run is claimed, the scanner-coverage gap remains open, and `SL-28` still needs a current `RISKUSDVault.sol` source rebind. Two Windows CLI rows remain failed. No first-party contract test, runtime, deployed-state, chain, or Octane result is claimed.
