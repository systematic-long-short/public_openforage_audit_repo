# OpenForage public contract review

This repository is a selective source snapshot for independent review. It is not a deployment repository or a copy of the private monorepo.

## 2026-10-09 post-scan source update

The latest public source status is recorded in [Analysis 13 dispositions](documentation/smart_contract_audits/2026-10-09-analysis-13-dispositions.md), with the bounded source fixes and proof limits in the [2026-10-09 post-scan update](documentation/smart_contract_audits/2026-10-09-post-scan-update.md). Analysis 13 scanned the previously published PR #9 head; its exact identity is classified in the linked audit scope and post-scan update. This update covers the privately reviewed source mapped after that scan. No Octane status is changed by publication.

## Snapshot scope

The direct map contains 69 files: 40 Solidity source, interface, library, and module files; 20 ABI files; 8 selected deployment-script and interface files; and 1 reviewed suppression policy. The current 69-entry map has no unlisted first-party source, interface, library, module, or ABI path. Since the earlier 51-path source/ABI map, it deliberately adds these seven Solidity files and two ABI artifacts: `src/GuardianEmergencyPrincipalLane.sol`, `src/interfaces/IEmergencyPrincipalLane.sol`, `src/interfaces/IRISKUSDSettlement.sol`, `src/libraries/GuardianAuthorityClassifier.sol`, `src/modules/AtRiskUSDWeeklyExitModule.sol`, `src/modules/CustodianRegistryCapitalModule.sol`, `src/modules/USDCTreasuryProfitPolicyModule.sol`, `abi/GuardianEmergencyPrincipalLane.json`, and `abi/USDCTreasuryAccountingModule.json`. All 40 source and 20 ABI paths were rechecked against the private inventory. The public `foundry.toml` pins both linked libraries to the same deterministic addresses as the private build. Both root dependency Gitlinks and all nine recursive pins remain unchanged. Vendor source stays behind those pins. Private audit records, run logs, packet text, deployment state, credentials, and non-allowlisted scripts and tooling are excluded.

No first-party contract test path is copied.

## Analyses 9–13 status

See [`Analysis 9 dispositions`](documentation/smart_contract_audits/2026-09-29-analysis-9-dispositions.md) for 21 primary findings and 11 related cases. See [`Analysis 10 dispositions`](documentation/smart_contract_audits/2026-09-30-analysis-10-dispositions.md) for 17 findings and one related case. See [`Analysis 11 dispositions`](documentation/smart_contract_audits/2026-10-01-analysis-11-dispositions.md) for 11 findings and three related cases. See [`Analysis 12 dispositions`](documentation/smart_contract_audits/2026-10-07-analysis-12-dispositions.md) for 28 finding and related-case rows, each with its latest review status and bound. See [`Analysis 13 dispositions`](documentation/smart_contract_audits/2026-10-09-analysis-13-dispositions.md) for 24 findings and seven related cases, with current independent-review status and source pins. [`Analysis 12 dispositions`](documentation/smart_contract_audits/2026-10-07-analysis-12-dispositions.md) and [`the 2026-10-07 pre-scan review`](documentation/smart_contract_audits/2026-10-07-pre-scan-review.md) summarize the whole-source rounds and their declared limits. These records state the limits of each bounded source review. The 155 Analysis 1–8 identities remain unchanged in [`the historical record`](documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md). Warning 28 retains its dated missing-capture gap. Analysis 9 acknowledgements remain `Other`; no finding is marked resolved by publication or source review.

The Analysis 9 source findings remain bounded. The Treasury helper-readiness guard is accepted only as a source correction; A9-02 is not fully closed. A9-03 and its related case remain `ACCEPT_BOUNDED` within the reviewed accounting limits: ordinary redemption leaves active-window public mint use consumed, so shared headroom can remain occupied until reset. This is temporary aggregate-cap contention, not a fairness guarantee. A9-06, A9-09, A9-10, A9-14, A9-19, and A9-20 retain their specific source limits. A9-21 whole-query gas remains unmeasured. The 16 Analysis 10 vulnerabilities have bounded source dispositions and review within their limits. A10-17 remains open; whole-call gas fit is unmeasured. A11-01 remains open for repeated ordinary-slot refill and a Succeeded-but-unqueued expiry gap; A11-10 remains an open warning with whole-call gas unmeasured. A11-04 has a bounded remembered-wallet handoff review. A11-05 is limited to retired Registry selectors; the separate rotation predicate and A10-04 CANCELLER residual are not part of its UUID. No legacy-proxy, deployment, or current Octane closure is claimed.

The public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to candidate-file blobs. The previous-head, parent, and historical commit identities are classified in the audit scope and post-scan update. `6efd4cd86a9b2fec7f484c0da073f71385900308` and older commits are historical. Forty rows have bounded source-only review; seven stale or unresolved rows remain pending. The earlier 72-row table remains separate with all reviews pending. No fresh full `audit-static` pass is established; retained analyzer findings remain, the public suppression validator passes against the retained raw scan, and the public Semgrep preflight remains red on the stale source manifest.

## Policy boundaries

Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported. In the Blocklist, the legacy importer and interval-translation path are removed; fresh initialization sets the layout version and every state-changing entrypoint checks it before effects. The historical checkpoint lookup uses `wasBlockedAt`; the retained pre-checkpoint mapping is inert and remains only for layout. An independent source review accepts this Blocklist repair within a source-only bound; it proves no old-proxy or deployed-state behavior. The first upgrade still uses the authorizer in the implementation already installed. These rules do not prove every deployed proxy or upgrade path.

Profit belongs to the holders at recognition. Unpaid profit stays a separate claim and is paid only when cash arrives. Withdrawals use cash-backed share value and available cash; they promise no payment date. A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid that loss stay frozen through settlement.

The distributor is the trusted payer, not the recipient. Payment grants no system-account status or restricted-call permission.

## Build and verification limits

Forge 1.3.5 and Solc 0.8.24 compiled 137 public source inputs in each profile. Default code generation completed with zero compiler errors; its size child exited 1 on six EIP-170 runtime overages: ForageGovernor 27,212 bytes (2,636 over), HLTradingBridge 24,787 bytes (211 over), RISKUSDVaultModule 24,820 bytes (244 over), StakingQueue 27,953 bytes (3,377 over), StakingQueueModule 25,148 bytes (572 over), and USDCTreasury 24,905 bytes (329 over). The Default initcode rows have no EIP-3860 overage. Deploy exited 0 and all 39 first-party runtime/initcode artifacts fit. No Default EIP-3860 initcode overage. Deploy exited 0; all 39 first-party runtime/initcode artifacts fit.

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

All 20 ABI files match the mapped source; 19 have compiler source definitions and `FoundationTreasury.json` remains source-less. An earlier 2026-10-08 source-matched storage comparison recorded 17 matching rows and seven inherited divergences; that result is a dated snapshot. The later retained private checker run against byte-mapped source exited 1 with 26 matching rows and the same seven inherited divergences. The checker is absent from the public tree, so no fresh public-tree storage run is claimed.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The 47-row analyzer table records 7 Semgrep and 40 Slither identities; 40 are bounded source-only dispositions and seven remain pending. The earlier 72-row table remains separate with all independent reviews pending. Retained Slither and Semgrep results remain red; per-ID the public suppression validator passes against the retained raw scan; no fresh scanner run is claimed, the scanner-coverage gap remains open, and `SL-28` still needs a current `RISKUSDVault.sol` source rebind. Two Windows CLI rows remain failed. No first-party contract test, runtime, deployed-state, chain, or Octane result is claimed.
