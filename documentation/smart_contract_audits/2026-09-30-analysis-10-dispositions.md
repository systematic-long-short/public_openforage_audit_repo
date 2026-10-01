# Analysis 10: source dispositions and proof limits

This record maps all 17 findings and the related case under A10-11 to public source lines, the latest completed independent review, the source change, and its limits. It does not change an Octane status or claim deployment or security clearance.

## Finding dispositions

Source paths are relative to the public contract tree. `ACCEPT_BOUNDED` describes only the stated source review; it is not a finding closure.

| Finding and UUID | Public source lines | Latest review and source disposition |
|---|---|---|
| A10-01 High `7dc86b0b-872d-4d8e-890f-753c91704717` | `src/RISKUSDVault.sol:403-438,442-483,1394-1441` | **ACCEPT_BOUNDED.** Gross redemption consumes cap use; public mint use is not refunded. Reject the refund suggestion because it would permit free cap reuse. No fairness or runtime proof. |
| A10-02 High `aa8151f8-d53f-42a5-86f5-583ee48e5c66` | `src/RISKUSDVault.sol:1069-1114,1235-1247,1394-1441,1533-1535` | **ACCEPT_BOUNDED.** The cap check preserves the matched basis debit. Reject deleting that debit. No deployed-state proof. |
| A10-03 Medium `293e6c02-6d90-4106-90b8-0d5b61fbb2b6` | `src/atRISKUSD.sol:207-209`; `src/modules/AtRiskUSDStateModule.sol:384-402,642-720,760-778,878-938` | **ACCEPT_BOUNDED.** New requests reserve no weekly capacity; funded payouts consume the existing seven-day cap. Only a matching prior fresh reservation can be consumed or returned in its active window. No live request inventory. |
| A10-04 Medium `5811eccb-9a63-4cd1-a8fc-2511569f630f` | `src/ForageGovernor.sol:237-307`; `src/ForageGovernorTimelockGuard.sol:483-550`; `src/GuardianModule.sol:213-231,894-962` | **ACCEPT_BOUNDED.** Malformed Guardian mutation data is rejected before proposal storage; self-authority protection remains. Adopt the bounds in substance, not a specific calldata offset. No arbitrary-target or gas proof. |
| A10-05 Medium `abbcb346-6ab8-4249-a5ac-38c8b439cdf8` | `src/modules/ForageTokenStateModule.sol:324-344,371-380,411-421,898-945`; `script/Deploy.s.sol:683-697` | **ACCEPT_BOUNDED.** Rotation uses a fixed snapshot and updates later sources during the transition. Adopt staging and dual writes. No total inventory or gas bound. |
| A10-06 Medium `289de892-137a-414f-ad82-f36f5b6f89d2` | `src/modules/AtRiskUSDProfitModule.sol:29,92,179-208,216-267,289-356,368-390,419-423`; `src/atRISKUSD.sol:212-213,267-269,289-294,426-429`; `src/interfaces/IAtRiskUSDProfitClaims.sol:4-8` | **ACCEPT_BOUNDED.** Account catch-up settles finalized periods in order, at most eight per call; strict paths refuse before mutation when more progress is needed. Reject unbounded catch-up. Wallet ABI, rounding, runtime, and gas remain unproved. |
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

Forge 1.3.5 and Solc 0.8.24 compiled 131 public inputs in each profile with zero compiler errors. Default code generation completed, but the child exited 1 on three EIP-170 runtime-size overages: ForageGovernor 28,646 bytes (4,070 over), StakingQueue 27,382 bytes (2,806 over), and USDCTreasury 27,779 bytes (3,203 over). Default initcode has no overage. ForageToken fits at 24,112 runtime bytes, 464 below EIP-170; its 49,125-byte initcode is 27 below EIP-3860. Deploy exited 0 and all 22 first-party contract runtime/initcode pairs fit. ForageGovernor is 24,564 runtime bytes (12 below EIP-170); USDCTreasury is 24,231 runtime bytes (345 below EIP-170). The table lists all 25 compiled contract/library artifacts. GuardianModule links GuardianAuthorityClassifier; the library is 6,658/6,711 bytes in Default and 5,756/5,787 in Deploy.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 13,833 / 14,089 (+10,743 / +35,063) | 12,214 / 12,424 (+12,362 / +36,728) |
| AtRiskUSDProfitModule | 7,710 / 8,031 (+16,866 / +41,121) | 7,033 / 7,348 (+17,543 / +41,804) |
| AtRiskUSDStateModule | 23,989 / 24,601 (+587 / +24,551) | 20,132 / 20,667 (+4,444 / +28,485) |
| Blocklist | 9,249 / 9,499 (+15,327 / +39,653) | 7,784 / 7,993 (+16,792 / +41,159) |
| CustodianRegistry | 24,374 / 24,630 (+202 / +24,522) | 20,266 / 20,480 (+4,310 / +28,672) |
| DelegatingVestingWallet | 6,865 / 9,037 (+17,711 / +40,115) | 5,914 / 7,401 (+18,662 / +41,751) |
| FORAGETreasury | 23,802 / 24,094 (+774 / +25,058) | 20,479 / 20,725 (+4,097 / +28,427) |
| ForageGovernor | 28,646 / 38,793 (-4,070 / +10,359) | 24,564 / 33,507 (+12 / +15,645) |
| ForageGovernorTimelockGuard | 9,779 / 9,808 (+14,797 / +39,344) | 8,613 / 8,640 (+15,963 / +40,512) |
| ForageToken | 24,112 / 49,125 (+464 / +27) | 23,455 / 45,828 (+1,121 / +3,324) |
| ForageTokenStateModule | 24,454 / 24,667 (+122 / +24,485) | 21,848 / 22,056 (+2,728 / +27,096) |
| GovernancePayloadBudget | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| GuardianAuthorityClassifier | 6,658 / 6,711 (+17,918 / +42,441) | 5,756 / 5,787 (+18,820 / +43,365) |
| GuardianModule | 23,073 / 23,329 (+1,503 / +25,823) | 17,972 / 18,186 (+6,604 / +30,966) |
| HLTradingBridge | 24,372 / 24,664 (+204 / +24,488) | 22,238 / 22,488 (+2,338 / +26,664) |
| RISKUSD | 10,989 / 11,281 (+13,587 / +37,871) | 9,166 / 9,411 (+15,410 / +39,741) |
| RISKUSDVault | 21,977 / 22,269 (+2,599 / +26,883) | 18,582 / 18,832 (+5,994 / +30,320) |
| RISKUSDVaultModule | 24,079 / 24,544 (+497 / +24,608) | 19,766 / 20,219 (+4,810 / +28,933) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,382 / 27,674 (-2,806 / +21,478) | 23,203 / 23,453 (+1,373 / +25,699) |
| StakingQueueModule | 24,451 / 24,573 (+125 / +24,579) | 22,853 / 22,971 (+1,723 / +26,181) |
| USDCTreasury | 27,779 / 28,071 (-3,203 / +21,081) | 24,231 / 24,481 (+345 / +24,671) |
| USDCTreasuryAccountingModule | 4,044 / 4,073 (+20,532 / +45,079) | 3,059 / 3,086 (+21,517 / +46,066) |
| VaultRegistry | 20,054 / 20,310 (+4,522 / +28,842) | 17,367 / 17,581 (+7,209 / +31,571) |
| atRISKUSD | 23,059 / 48,241 (+1,517 / +911) | 19,297 / 40,443 (+5,279 / +8,709) |

The source-matched storage-baseline comparison remains red at 16 OK and 7 historical divergences; no baseline changed. Two Windows CLI rows remain failed. No first-party contract test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane status change is claimed. A10-17 remains open without whole-call gas-fit evidence.

## Policy and evidence limits

Only fresh deployments are supported. Code for a new installation refuses unsupported older storage before changing it; no migration claim or old-proxy proof is made. The first upgrade remains subject to the authorization of the implementation already installed. Recognized unpaid profit remains a separate entitlement of the holders at recognition and is paid when cash arrives; withdrawals use cash-backed value. Custodian losses are borne by holders at report time, and exits that could avoid a reported loss remain frozen through settlement.

The profile builds, exact size table, ABI comparison, historical identity result, and disclosure limits are reported in [`review_commands.md`](../review_commands.md). No first-party contract tests, runtime or gas simulation, chain access, deployment, or Octane status change is claimed.
