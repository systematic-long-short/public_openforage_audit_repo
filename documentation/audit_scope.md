# Audit scope

## 2026-10-11 post-scan source update

Analysis 14 scanned the previously published PR #9 head `1c1085499239962b543dae724f041414a2d4eecd`. This page and the [2026-10-11 post-scan update](smart_contract_audits/2026-10-11-post-scan-update.md) record OpenForage's own source review, not an Octane result. No Octane analysis has run on this tree, and no future scan is promised or authorized. Per-finding status and source lines are in [Analysis 14 dispositions](smart_contract_audits/2026-10-11-analysis-14-dispositions.md).

## Candidate and source map

This update is based on the published head named above. The previous Analysis 13 scan head `78a465cba5a47bbb4f542a6f305f482ddc73b0e9`, `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`, `01f4abe7768f03d2a21e6ab0a0221795d315d79b`, and older commits are historical identities. This review does not update the remote branch or PR.

The direct map contains 70 files: 40 production source, interface, library, and module files; 21 ABI artifacts; 8 selected deployment-script and interface files; and 1 reviewed suppression policy. It explicitly includes `GuardianAuthorityClassifier.sol`, `IRISKUSDSettlement.sol`, and `ForageGovernorTimelockGuard.json`. The exact private inventory has no unmapped first-party source, interface, library, module, or ABI path. All mapped files, including the suppression policy, are byte-checked against the exact source. The two root Gitlinks and all nine recursive pins stay unchanged.

Only the eight selected script/interface paths in the explicit map are copied. All other private scripts and tools, audit records, packet text, run logs, credentials, deployment records, and unlisted paths remain excluded. No first-party contract test path is copied.

## Finding scope and review status

The historical record preserves all 155 Analysis 1–8 identities and their original counts. Warning 28 keeps its dated missing-capture gap. Analysis 9 has 21 findings and 11 related cases; see its [source dispositions](smart_contract_audits/2026-09-29-analysis-9-dispositions.md). Analysis 10 has 17 findings and one related case; see its [source dispositions](smart_contract_audits/2026-09-30-analysis-10-dispositions.md). Analysis 11 has 11 findings and three related cases; see its [source dispositions](smart_contract_audits/2026-10-01-analysis-11-dispositions.md). The [Analysis 12 dispositions](smart_contract_audits/2026-10-07-analysis-12-dispositions.md), [Analysis 13 dispositions](smart_contract_audits/2026-10-09-analysis-13-dispositions.md), and [Analysis 14 dispositions](smart_contract_audits/2026-10-11-analysis-14-dispositions.md) record latest completed independent-review status and source disposition. Analysis 9 acknowledgements remain `Other`; source review does not mark findings resolved.

The linked finding-level pages give each earlier finding and related case its latest completed critique verdict, source lines, and stated limit. The new post-scan update records the additional weekly-exit reservation rule, the 40-epoch catch-up bound, return-cap rounding, guardian limits, queue cost, and remaining proof gaps. No legacy-proxy, deployment, or current Octane closure is claimed.

The post-scan update classifies the public head and historical identities, reports the retained static evidence and measured public checker results, and lists all remaining proof limits. It does not claim a fresh full analyzer pass.

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

No fresh full `audit-static` pass is established for this public materialization. The public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither; 40 have bounded source-only review and seven remain pending. All independent reviews in the earlier 72-row table remain pending. Retained Slither and Semgrep results are red, the public suppression validator passes against the retained raw scan; no fresh scanner run is claimed, and the scanner-coverage gap remains open. A copied-source control for the Guardian Registry selector set remains incomplete; that gap does not show the current Solidity contains the retired branch. Two Windows CLI rows remain failed. No first-party test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. No live-proxy or deployed-state claim is made.
