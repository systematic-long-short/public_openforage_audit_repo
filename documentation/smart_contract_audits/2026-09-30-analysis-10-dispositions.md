# Analysis 10: source dispositions and proof limits

This record maps all 17 findings and the related case under A10-11 to public source lines, the latest completed independent review, the source change, and its limits. The whole-source review and its declared limits are summarized in the [pre-scan review](2026-10-02-pre-scan-review.md). This record does not change an Octane status or claim deployment or security clearance.

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

The latest recorded source-matched storage comparison is red at 17 OK and 7 historical divergences; no baseline changed, and this update did not run a fresh public-tree storage check. Two Windows CLI rows remain failed. No first-party contract test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane status change is claimed. A10-17 remains open without whole-call gas-fit evidence.

## Policy and evidence limits

Only fresh deployments are supported. Code for a new installation refuses unsupported older storage before changing it; no migration claim or old-proxy proof is made. The first upgrade remains subject to the authorization of the implementation already installed. Recognized unpaid profit remains a separate entitlement of the holders at recognition and is paid when cash arrives; withdrawals use cash-backed value. Custodian losses are borne by holders at report time, and exits that could avoid a reported loss remain frozen through settlement.

The profile builds, exact size table, ABI comparison, historical identity result, and disclosure limits are reported in [`review_commands.md`](../review_commands.md). No first-party contract tests, runtime or gas simulation, chain access, deployment, or Octane status change is claimed.
