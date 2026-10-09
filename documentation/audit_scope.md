# Audit scope

## 2026-10-09 post-scan source update

The latest public source status is recorded in [Analysis 13 dispositions](documentation/smart_contract_audits/2026-10-09-analysis-13-dispositions.md), with the bounded source fixes and proof limits in the [2026-10-09 post-scan update](documentation/smart_contract_audits/2026-10-09-post-scan-update.md). Analysis 13 scanned the previously published PR #9 head `78a465cba5a47bbb4f542a6f305f482ddc73b0e9`; this update covers the privately reviewed source mapped after that scan. No Octane status is changed by publication.

## Candidate and source map

This update is based on the previous PR #9 head `78a465cba5a47bbb4f542a6f305f482ddc73b0e9`, the commit Analysis 13 scanned. The prescribed commit parent is `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`, `01f4abe7768f03d2a21e6ab0a0221795d315d79b` and older commits are historical identities. The materializer uses the exact published tree from the head named above. This review does not update the remote branch or PR.

The direct map contains 69 files: 40 production source, interface, library, and module files; 20 ABI artifacts; 8 selected deployment-script and interface files; and 1 reviewed suppression policy. It explicitly includes `GuardianAuthorityClassifier.sol` and `IRISKUSDSettlement.sol`. The exact private inventory has no unmapped first-party source, interface, library, module, or ABI path. All 69 mapped files, including the suppression policy, are byte-checked against the exact source. The two root Gitlinks and all nine recursive pins stay unchanged.

Only the eight selected script/interface paths in the explicit map are copied. All other private scripts and tools, audit records, packet text, run logs, credentials, deployment records, and unlisted paths remain excluded. No first-party contract test path is copied.

## Finding scope and review status

The historical record preserves all 155 Analysis 1–8 identities and their original counts. Warning 28 keeps its dated missing-capture gap. Analysis 9 has 21 findings and 11 related cases; see its [source dispositions](smart_contract_audits/2026-09-29-analysis-9-dispositions.md). Analysis 10 has 17 findings and one related case; see its [source dispositions](smart_contract_audits/2026-09-30-analysis-10-dispositions.md). Analysis 11 has 11 findings and three related cases; see its [source dispositions](smart_contract_audits/2026-10-01-analysis-11-dispositions.md). The [Analysis 12 dispositions](smart_contract_audits/2026-10-07-analysis-12-dispositions.md) and [2026-10-07 pre-scan review](smart_contract_audits/2026-10-07-pre-scan-review.md) record the latest source verdicts, rounds 3–5 and declared limits. Analysis 9 acknowledgements remain `Other`; no finding is marked resolved.

The Analysis 10 record says A10-17 remains open and whole-call gas fit remains unmeasured. The Treasury helper-readiness guard is accepted only as a bounded source correction; A9-02 is not fully closed. A9-03 remains bounded to net-basis accounting. Its related case is bounded at source level: ordinary redemption no longer refunds active-window public mint use. A redeemed position can leave daily or weekly mint headroom occupied until the window resets; no fairness guarantee is claimed. A9-06 remains open on cross-tier fairness and collectibility. A9-09 is accepted only for cash-backed pricing. A9-10 and A9-14 are bounded to fresh-state settlement and exact-nonce paths. A9-19 and A9-20 remain bounded source findings, not live-state proof. A9-21 whole-query gas remains unmeasured. A11-01 remains open because repeated address rotation can refill the bounded ordinary proposal cap and a Succeeded-but-unqueued proposal lacks expiry; A11-10 remains an open warning with no whole-call gas result. A11-04's latest bounded review includes remembered-wallet handoff continuity after candidate-first declassification. A11-05 is limited to selector-only classification of the retired Registry routes; the separate absent/already-expired rotation predicate and A10-04 CANCELLER preflight boundary are not part of that UUID. No legacy-proxy, deployment, or current Octane closure is claimed.

The earlier 72-row table retains 28 Queue and 44 Token triage items; all 72 independent-review statuses remain pending. The separate public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to the current candidate-file blob. The previous-head, parent, and historical commit identities are classified in this section and the linked post-scan update. `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and older commits are historical. Forty rows have bounded source-only review and seven remain pending. `SL-28` still needs a current `RISKUSDVault.sol` source rebind. No fresh full `audit-static` pass is established; retained analyzer findings remain, the public suppression validator passes against the retained raw scan, and the public Semgrep preflight remains red on the stale source manifest.

## Policy boundaries

- Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported.
- The first upgrade is authorized by the implementation already installed. A source guard in the new implementation cannot prove the first upgrade path.
- The Blocklist's legacy importer and interval-translation path are removed. Fresh initialization establishes its layout version, and each state-changing entrypoint requires that version before effects. The historical lookup uses checkpoint-only `wasBlockedAt`; the retained pre-checkpoint mapping is inert layout storage. An independent source review accepts this fresh-only repair at source level only; it proves no deployed or old-proxy state.
- Holders at recognition own profit. Unpaid profit remains a separate claim and is payable only after cash arrives.
- Withdrawal share pricing uses cash-backed value. Withdrawals pay available cash only and promise no payment date.
- A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid it stay frozen through settlement.
- Loss settlement uses the configured keeper and existing checked return path. Reserve-covered loss does not use the depositor-tier loss-rate cap.
- Fractional fee remainders carry across payments. Queue demotion keeps its original ID and standard-queue position.
- One designated Guardian keeps one proposal slot under ordinary voting and timelock controls. It cannot veto its own authority change.
- Only automatic expiry return from a higher tier is exempt from the Tier 0 admission cap. New admissions and manual reversions remain capped.
- External vesting recipients need renewable approval and remain registered. Payment grants no system-account status.
- The distributor is the trusted payer, not the recipient. A recipient gains no restricted-call permission.
- Two Windows CLI rows remain failed. No Visual Studio license or toolchain was installed, purchased, or accepted.

These policy choices do not prove that every path follows them. The disposition record lists the source paths and remaining evidence gaps.

## Build, ABI, storage, and proof limits

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

No fresh full `audit-static` pass is established for this public materialization. The public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither; 40 have bounded source-only review and seven remain pending. All independent reviews in the earlier 72-row table remain pending. Retained Slither and Semgrep results are red, the public suppression validator passes against the retained raw scan; no fresh scanner run is claimed, and the scanner-coverage gap remains open. A copied-source control for the Guardian Registry selector set remains incomplete; that gap does not show the current Solidity contains the retired branch. Two Windows CLI rows remain failed. No first-party test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. No live-proxy or deployed-state claim is made.
