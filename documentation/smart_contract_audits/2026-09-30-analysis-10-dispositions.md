# Analysis 10: source dispositions and proof limits

This record maps all 17 findings and the related case under A10-11 to public source lines, the latest completed independent review, the source change, and its limits. The latest Analysis 12 rows are in [Analysis 12 dispositions](2026-10-07-analysis-12-dispositions.md); source changes and declared limits are in the [2026-10-07 pre-scan review](2026-10-07-pre-scan-review.md). This record does not change an Octane status or claim deployment or security clearance.

## Finding dispositions

Source paths are relative to the public contract tree. `ACCEPT_BOUNDED` describes only the stated source review; it is not a finding closure.

| Finding and UUID | Public source lines | Latest review and source disposition |
|---|---|---|
| A10-01 High `7dc86b0b-872d-4d8e-890f-753c91704717` | `src/RISKUSDVault.sol:403-438,442-483,1394-1441` | **ACCEPT_BOUNDED.** Gross redemption consumes cap use; public mint use is not refunded. Reject the refund suggestion because it would permit free cap reuse. No fairness or runtime proof. |
| A10-02 High `aa8151f8-d53f-42a5-86f5-583ee48e5c66` | `src/RISKUSDVault.sol:1069-1114,1235-1247,1394-1441,1533-1535` | **ACCEPT_BOUNDED.** The cap check preserves the matched basis debit. Reject deleting that debit. No deployed-state proof. |
| A10-03 Medium `293e6c02-6d90-4106-90b8-0d5b61fbb2b6` | `src/atRISKUSD.sol:207-209`; `src/modules/AtRiskUSDStateModule.sol:384-402,642-720,760-778,878-938` | **ACCEPT_BOUNDED.** New requests reserve no weekly capacity; funded payouts consume the existing seven-day cap. Only a matching prior fresh reservation can be consumed or returned in its active window. No live request inventory. |
| A10-04 Medium `5811eccb-9a63-4cd1-a8fc-2511569f630f` | `openforage_smart_contracts/src/ForageGovernor.sol:291-307,639-657`; `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol:59-83,471-514,517-529,650-699,805-827,830-896,967-979`; `openforage_smart_contracts/src/GuardianModule.sol:961-1035`; `openforage_smart_contracts/src/libraries/GuardianAuthorityClassifier.sol:104-135,271-341` | **ACCEPT_BOUNDED.** The current preflight rejects statically malformed or impossible protected calls before proposal storage across root, relay, nested schedule/batch, and future-executor walks. Preserve the existing aligned-gap/trailing-tail grammar; reject offset-64-only parsing. Execution-time roles, code presence, and target behavior are outside this source review. No whole-call gas or execution proof. |
| A10-05 Medium `abbcb346-6ab8-4249-a5ac-38c8b439cdf8` | `src/modules/ForageTokenStateModule.sol:324-344,371-380,411-421,898-945`; `script/Deploy.s.sol:683-697` | **ACCEPT_BOUNDED.** Rotation uses a fixed snapshot and updates later sources during the transition. Adopt staging and dual writes. No total inventory or gas bound. |
| A10-06 Medium `289de892-137a-414f-ad82-f36f5b6f89d2` | `src/modules/AtRiskUSDProfitModule.sol:29,92,179-208,216-267,289-356,368-390,419-423`; `src/atRISKUSD.sol:212-213,267-269,289-294,426-429`; `src/interfaces/IAtRiskUSDProfitClaims.sol:4-8` | **ACCEPT_BOUNDED.** Account catch-up settles finalized periods in order, at most eight per call; strict paths refuse before mutation when more progress is needed. Reject unbounded catch-up. Founder decision 19 retains floor-rounded per-holder closed-epoch accounting: at most one raw unit per holder per payout epoch can remain in funded reserve; no holder is overpaid. Wallet ABI, whole-call gas, and runtime remain unproved. |
| A10-07 Medium `e98e6f0b-380c-4906-b0ba-61a5fbb1f33c` | `src/hyperliquid/HLTradingBridge.sol:985-1019` | **ACCEPT_BOUNDED.** Manual NAV checks the observed time against the principal-book anchor before either nonce path. No live reporter or proxy proof. |
| A10-08 Medium `62896824-6b1d-48dc-a9ca-6c0045c951fb` | `src/ForageToken.sol:727-764`; `src/modules/ForageTokenStateModule.sol:345-369,382-447,898-945,993-1028` | **ACCEPT_BOUNDED.** Allowlist reindex is paged and dual-written before activation. Adopt staged activation, not an immediate pointer switch. No live tally or gas proof. |
| A10-09 Medium `becef064-a855-45f1-8deb-f754675c92fc` | `src/USDCTreasury.sol:427-433,486-504,542-568,796-824,844-856` | **ACCEPT_BOUNDED for the clamp only.** A claim write-down releases only pending top-up above outstanding claims and reduces the earmark by the same excess; insufficient earmark refuses. No future cash-collection proof. |
| A10-10 Medium `5e413851-382d-4012-90b1-a678f76363d3` | `src/ForageToken.sol:155-170,268-306,324-327,468-477,684-691,702-720,778-780,790-800`; `src/modules/ForageTokenStateModule.sol:231-255,274-284,314-338,535-617,700-750` | **ACCEPT_BOUNDED for fresh schema-three state only.** The zero-first marker is mirrored and checked before the guarded module operation. Reject revocation-only and current-allowance-only rules. The first upgrade remains governed by the implementation already installed; no funded legacy proxy was observed. |
| A10-11 Medium `249b3b9b-371c-4a9b-b4ab-b1c04cbca448` | `src/RISKUSDVault.sol:451-456,1069-1114,1334-1371,1394-1441,1508-1518,1533-1535` | **ACCEPT_BOUNDED.** The lazy snapshot removes consumed and remaining mint amounts; the stored active-supply value remains authoritative when set. Reject another netting marker. No loss-settlement runtime proof. |
| A10-11 related case, Medium, no UUID | `src/modules/RISKUSDVaultModule.sol:857-917,1105-1141` | **ACCEPT_BOUNDED.** Loss burning consumes each offset once and debits the basis by the amount less that offset. This is separate from the parent finding and is not runtime proof. |
| A10-12 Medium `075dcadb-9f53-4505-891c-79c936fe4092` | `src/ForageGovernor.sol:237-307,603-637,648`; `src/ForageGovernorTimelockGuard.sol:332-400,413-432,477-480,561-568` | **ACCEPT_BOUNDED.** Admission preflights each non-current relay destination, including destinations without code, before proposal storage. Preserve the existing action, visit, byte, and depth limits. No arbitrary-target or gas proof. |
| A10-13 Low `59340c7b-3bbd-41f4-98b7-ad6d6485c834` | `src/USDCTreasury.sol:335-357,412-425,542-564,796-829,875-913`; `src/modules/AtRiskUSDProfitModule.sol:139-157,179-194` | **ACCEPT_BOUNDED.** Custodian loss uses report-time assets and retained cover without writing down unpaid claims or reducing the gross return cap. Negative profit accounting remains separate. No status or future cash-collection proof. |
| A10-14 Low `0a6433bc-7a07-4af4-bf53-4c429dee854d` | `src/RISKUSDVault.sol:339-400,1289-1295`; `src/VaultRegistry.sol:640-667,731-738` | **ACCEPT_BOUNDED.** Fresh construction accepts only the current or exact pending Registry route. No arbitrary-factory, live Registry, or old-proxy proof. |
| A10-15 Low `8358e11b-ae7f-4785-98d5-66c22aef11bd` | `src/modules/StakingQueueModule.sol:527-620`; `src/modules/AtRiskUSDStateModule.sol:361-382` | **ACCEPT_BOUNDED.** Automatic expiry may return free shares while preserving pending escrow. Keep manual return and new Tier 0 admission limits. Other cash and risk gates may still refuse progress. |
| A10-16 Low `121c68cb-8daf-4c53-a4b1-10112a8fe940` | `src/atRISKUSD.sol:236-269,525-570`; `src/modules/AtRiskUSDStateModule.sol:404-425,428-435,438-497,579-625` | **ACCEPT_BOUNDED.** Fresh initialization may skip reads of an absent current source; successor, caller, Bridge, Blocklist, and funding checks still precede the write. No deployed zero-source or runtime proof. |
| A10-17 Low warning `32a6d0a7-0efb-4832-a908-7d1da3883b2f` | `src/Allowlist.sol:63,431-433,521-528`; `src/modules/ForageTokenStateModule.sol:781-839,855-924,948-956,993-1013` | **OPEN.** Synchronous callbacks can update both vote projections. Reject the blocked-beneficiary shortcut. No whole-call gas fit, execution, or out-of-gas proof. |

## Build results

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



## Policy and evidence limits

Only fresh deployments are supported. Code for a new installation refuses unsupported older storage before changing it; no migration claim or old-proxy proof is made. The first upgrade remains subject to the authorization of the implementation already installed. Recognized unpaid profit remains a separate entitlement of the holders at recognition and is paid when cash arrives; withdrawals use cash-backed value. Custodian losses are borne by holders at report time, and exits that could avoid a reported loss remain frozen through settlement.

The profile builds, exact size table, ABI comparison, historical identity result, and disclosure limits are reported in [`review_commands.md`](../review_commands.md). No first-party contract tests, runtime or gas simulation, chain access, deployment, or Octane status change is claimed.
