# Analysis 11: source dispositions and proof limits

The source-line citations in this historical record are re-pinned to the mapped public source blobs listed in the [2026-10-09 post-scan update](2026-10-09-post-scan-update.md). Their prior review statuses remain historical; current Analysis 9–13 status is recorded in the linked disposition documents.


> Current follow-up: the 2026-10-09 [Analysis 13 dispositions](2026-10-09-analysis-13-dispositions.md) and [post-scan update](2026-10-09-post-scan-update.md) record the later source status and limits. This page retains its dated finding-level verdicts; its scan identity is historical. Current source-file blobs for the Solidity line references are listed at the end.

This record covers 9 vulnerabilities, 2 warnings, and 3 related cases. One case sits under A11-02; two under A11-07. Source review is not Octane closure or deployment proof.

This Analysis 11 record is historical. Analysis 12 scanned `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; Analysis 13 later scanned the current public base identified in the post-scan update. `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`, `01f4abe7768f03d2a21e6ab0a0221795d315d79b` and older commits are historical only. Source line references are re-pinned to the current candidate in the post-scan update.

See the [whole-source pre-scan review](2026-10-07-pre-scan-review.md) for rounds 3–5 and the declared limits. Its source dispositions do not change Octane labels or close findings.

## Finding dispositions

`ACCEPT_BOUNDED` accepts only the source behavior and limits named in its row. It does not resolve an Octane finding or change its label.

| Finding and UUID | Public source lines | Latest review and source disposition |
|---|---|---|
| A11-01 Medium `a7af1595-ccda-406e-ae1c-b71b1ba14c0d` | `openforage_smart_contracts/src/ForageGovernor.sol:106,221,243-289,278-281,328-395,354-363,892-927` | **ACCEPT_BOUNDED for the per-proposal lifetime trace only; finding remains open.** The ordinary cap is three per address and ten globally; repeated address rotation can refill it. Below-threshold Pending/Active proposals can be released, minority proposals end after voting delay and voting period plus the deadline tick, and Queued proposals retain the 30-day stale bound. A Succeeded-but-unqueued proposal has no expiry and remains counted. Reject the per-wallet `caseRef` quota because it is not a stable identity key. No live proposal state was read.
| A11-02 Medium `a1128474-2005-43d8-8ffc-2de9ce722ed0` | `openforage_smart_contracts/src/RISKUSDVault.sol:408-438,446-461,1319-1362` | **ACCEPT_BOUNDED.** A successful first redemption anchors both cap bases to current supply; a reverted dust attempt stores no anchor. This applies only to fresh version-two state. Reject a fallback that counts current-window mints in the basis. No runtime or deployed-state proof exists. |
| A11-03 Medium `a5bd8652-d2e0-4fce-aa6d-92f676bfb199` | `openforage_smart_contracts/src/ForageToken.sol:396-414,437-445,767-780`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:578-634` | **ACCEPT_BOUNDED.** Compliance changes queue vote-synchronization work one source at a time. Vote reads and later-timepoint actions refuse while work remains. Reject a bare catch that could leave voting power stale. Whole-call gas remains unmeasured. |
| A11-04 Low `92464e14-f90f-41ee-bdd0-57783b40383e` | `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:432-467,448-467,480-495,560-576,858-864,1087-1109,1204-1216`; `openforage_smart_contracts/src/FORAGETreasury.sol:95-98,268-289,433-459` | **ACCEPT_BOUNDED.** Candidate-first declassification does not copy beneficiary approval. The remembered vesting beneficiary keeps the wallet-pointer handoff obligation after declassification; bounded pointer pages and the existing typed refusal block activation until the recorded wallet is forwarded to the candidate and read back. Review accepts these exact source slices only. No live wallet/reindex state was read.
| A11-05 Low `eb4f1fa1-3a4e-485d-9928-5c2e16f391c4` | `openforage_smart_contracts/src/CustodianRegistry.sol:276-288,669-674,699-705`; `openforage_smart_contracts/src/libraries/GuardianAuthorityClassifier.sol:104-135,133-143`; `openforage_smart_contracts/src/GuardianModule.sol:228-240,903-973,961-973` | **ACCEPT_BOUNDED for the selector-only retired-Registry classification.** The scanner uses only the canonical Registry; its retired `proposeGuardianModule` and `finalizeGuardianModule` entrypoints always revert and are excluded from downstream-mutation classification. The Registry's Timelock ownership pin is an additional defense, not the selector correction. The separate absent/expired rotation predicate has no Analysis 11 UUID, and the state-dependent CANCELLER grant/revoke residual belongs to A10-04 preflight, not A11-05. Reject conflating those mechanisms with this finding. No Octane status changed.
| A11-06 Low `a975b9ef-0da0-45db-b329-ed7e062ef0c8` | `openforage_smart_contracts/src/ForageToken.sol:663-695`; `openforage_smart_contracts/src/FORAGETreasury.sol:212-232`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:1112-1176` | **ACCEPT_BOUNDED.** Transfers still synchronize both endpoints so the indexed voting view follows token checkpoints. Reject skipping this work; it can leave votes stale. The full claim path's gas cost is unmeasured. |
| A11-07 Low `731a1a4e-4d2b-4916-a4fd-80ad1e252b57` | `openforage_smart_contracts/src/RISKUSDVault.sol:421-432,1319-1342`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:897-917,928-937,1123-1153` | **ACCEPT_BOUNDED.** Fresh version-two state records post-anchor mints and consumes each offset once. Loss reduces the basis only by the amount not covered by the offset. Reject a second all-mint counter. No legacy-proxy or runtime proof exists. |
| A11-08 Low `2096e504-2141-462f-a2eb-e946e3cd13c0` | `openforage_smart_contracts/src/CustodianRegistry.sol:516-525,883-895`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:355-411,1113-1117` | **ACCEPT_BOUNDED.** One basis-aware return route skips only a duplicate NAV-reference reduction. A paused return also emits the ordinary return event; outside consumers are unknown. Adopt one existing selector, not another. No external-consumer or deployed-state proof exists. |
| A11-09 Informational `6d7f858a-c0a7-4ced-94a7-7853642eb15e` | `openforage_smart_contracts/src/CustodianRegistry.sol:527-542,614-679,936-939`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:424-448` | **ACCEPT_BOUNDED.** An amount-only loss marks that custodian's relation unbound. Relation and NAV routes then refuse. Reject a clearing shortcut; empty identity fields cannot restore missing history. No funds-loss or deployed-state conclusion follows. |
| A11-10 Medium warning `f6982688-1669-4adf-a120-18957f97ddf7` | `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol:4-8,315-316,345-457,572-644,792-803,894-952` | **ACCEPT_BOUNDED for bounded work only; warning remains open.** One shared limit covers root and future Timelock scans: 100 actions, 65,536 bytes, 100 nested visits, and depth 16. Authority reads are capped at 30,000 gas and fail closed on failed, malformed, or out-of-gas replies. This bounds callee work, not the whole proposal's gas. Reject a role-only check that would miss encoded direct/nested operations. No EVM, whole-call gas, or deployment proof exists. |
| A11-11 Low warning `cb440e18-6837-4f96-ad57-35a11a9eb734` | `openforage_smart_contracts/src/USDCTreasury.sol:335-358,575-588,662-689,796-825`; `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol:84-105` | **ACCEPT_BOUNDED.** After the claim clamp, the source moves only the canceled excess to the existing agent-payment earmark. It moves no cash and changes no payout rate or claim order. No payout or deployment behavior was exercised. |

The absent/already-expired accelerated-rotation predicate has no Analysis 11 UUID and is a separate source correction. The state-dependent CANCELLER grant/revoke residual belongs to A10-04 preflight, not A11-05. These boundaries do not change either Octane status.

## Related cases

These cases have no separate UUID. Each remains under its named Analysis 11 finding.

| Related case | Public source lines | Latest review and source disposition |
|---|---|---|
| A11-02-related-1, Medium: bootstrap mint/basis mismatch can enlarge redemption caps and crowd out holders | `openforage_smart_contracts/src/RISKUSDVault.sol:1319-1362`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:897-917,1123-1153` | **ACCEPT_BOUNDED for fresh version-two state.** Pre-anchor deposits remain in the basis; later mints offset once. Reject a first-mint-only condition. No runtime proof. |
| A11-07-related-1, Low: loss offsets and weekly rollover can leave a temporarily inflated cap | `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:928-933`; `openforage_smart_contracts/src/RISKUSDVault.sol:1406-1417` | **ACCEPT_BOUNDED.** Clamp the post-burn basis to surviving supply. No runtime or gas proof. |
| A11-07-related-2, Low: mint-buffer exclusion and strict seeding can pause public redemptions after a full-supply burn | `openforage_smart_contracts/src/RISKUSDVault.sol:1417-1430`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:1155-1168` | **ACCEPT_BOUNDED.** A true zero-supply reset clears redemption state and restores its sentinel, not public mint use. Reject an unconditional current-supply fallback. No legacy-proxy proof. |

## Build and evidence limits

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



Forge 1.3.5 and Solc 0.8.24 compiled 137 public source inputs in each profile. Default code generation completed with zero compiler errors; its size child exited 1 on six EIP-170 runtime overages: ForageGovernor 27,212 bytes (2,636 over), HLTradingBridge 24,787 bytes (211 over), RISKUSDVaultModule 24,820 bytes (244 over), StakingQueue 27,953 bytes (3,377 over), StakingQueueModule 25,148 bytes (572 over), and USDCTreasury 24,905 bytes (329 over). The Default initcode rows have no EIP-3860 overage. Deploy exited 0 and all 39 first-party runtime/initcode artifacts fit. No Default EIP-3860 initcode overage. Deploy exited 0; all 39 first-party runtime/initcode artifacts fit.

Static results remain red or incomplete. The copied-source control for Registry selectors can accept a reintroduced retired selector, though current Solidity has no such branch. This is a checker gap, not a current source defect or a full static pass.

No Octane label changes here. All limits in this record are source-review bounds, not finding closure or security clearance.

## Current public source blob pins

The source line references in this record resolve to these exact mapped Solidity file blobs in the public candidate.

| Public source file | Git blob |
|---|---|
| `openforage_smart_contracts/src/CustodianRegistry.sol` | `46847287613d4cfd17c5104771872fe151ed7afe` |
| `openforage_smart_contracts/src/FORAGETreasury.sol` | `320a60d5183e8f21912f0f0ff832a5d7f593a254` |
| `openforage_smart_contracts/src/ForageGovernor.sol` | `3a4728d1eba330228e03bd6c37d4cb111d147605` |
| `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol` | `0a8e4d2c204182a460f08a4254617b6e5a7f6e07` |
| `openforage_smart_contracts/src/ForageToken.sol` | `2fd8d00e6c58775e2b0c2662796cbfe5b1c7f122` |
| `openforage_smart_contracts/src/GuardianModule.sol` | `f9ebd4226bb291220c346343db2c0506b7d94b74` |
| `openforage_smart_contracts/src/RISKUSDVault.sol` | `7244cdb90fe10dfd102c01c5c1b81215660fa7e6` |
| `openforage_smart_contracts/src/USDCTreasury.sol` | `25cb223f201be6892be3ae99501a275a6de37a76` |
| `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol` | `dc34e056118dddd74f5ac5a0b835457d6cc18e5d` |
| `openforage_smart_contracts/src/libraries/GuardianAuthorityClassifier.sol` | `7ad471b979c40ca8334cf41a014615a4ac994331` |
| `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol` | `59021b0d9eea55803b88dfa192283c05aa12cbd6` |
| `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol` | `4e365adf2048f77ec354c1cf336b105e11a61366` |
| `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol` | `a35a15c93ce055f48827b3caf07f1564e73b9074` |

