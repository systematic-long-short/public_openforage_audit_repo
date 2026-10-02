# Analysis 11: source dispositions and proof limits

This record covers 9 vulnerabilities, 2 warnings, and 3 related cases. One case sits under A11-02; two under A11-07. Source review is not Octane closure or deployment proof.

Base of this update: `01f4abe7768f03d2a21e6ab0a0221795d315d79b`. `6efd4cd86a9b2fec7f484c0da073f71385900308` and older commits are historical. Source lines refer to this candidate.

See the [whole-source pre-scan review](2026-10-02-pre-scan-review.md) for rounds 1–10 and the declared limits. Its source dispositions do not change Octane labels or close findings.

## Finding dispositions

`ACCEPT_BOUNDED` accepts only the source behavior and limits named in its row. It does not resolve an Octane finding or change its label.

| Finding and UUID | Public source lines | Latest review and source disposition |
|---|---|---|
| A11-01 Medium `a7af1595-ccda-406e-ae1c-b71b1ba14c0d` | `openforage_smart_contracts/src/ForageGovernor.sol:106,221,243-289,278-281,328-395,354-363,918-970,962-992` | **ACCEPT_BOUNDED for the per-proposal lifetime trace only; finding remains open.** The ordinary cap is three per address and ten globally; repeated address rotation can refill it. Below-threshold Pending/Active proposals can be released, minority proposals end after voting delay and voting period plus the deadline tick, and Queued proposals retain the 30-day stale bound. A Succeeded-but-unqueued proposal has no expiry and remains counted. Reject the per-wallet `caseRef` quota because it is not a stable identity key. No live proposal state was read.
| A11-02 Medium `a1128474-2005-43d8-8ffc-2de9ce722ed0` | `openforage_smart_contracts/src/RISKUSDVault.sol:408-438,446-461,1319-1362` | **ACCEPT_BOUNDED.** A successful first redemption anchors both cap bases to current supply; a reverted dust attempt stores no anchor. This applies only to fresh version-two state. Reject a fallback that counts current-window mints in the basis. No runtime or deployed-state proof exists. |
| A11-03 Medium `a5bd8652-d2e0-4fce-aa6d-92f676bfb199` | `openforage_smart_contracts/src/ForageToken.sol:396-414,437-445,767-780`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:578-634` | **ACCEPT_BOUNDED.** Compliance changes queue vote-synchronization work one source at a time. Vote reads and later-timepoint actions refuse while work remains. Reject a bare catch that could leave voting power stale. Whole-call gas remains unmeasured. |
| A11-04 Low `92464e14-f90f-41ee-bdd0-57783b40383e` | `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:432-467,448-467,480-495,560-576,858-864,1087-1109,1204-1216`; `openforage_smart_contracts/src/FORAGETreasury.sol:95-98,268-289,433-459` | **ACCEPT_BOUNDED.** Candidate-first declassification does not copy beneficiary approval. The remembered vesting beneficiary keeps the wallet-pointer handoff obligation after declassification; bounded pointer pages and the existing typed refusal block activation until the recorded wallet is forwarded to the candidate and read back. Review accepts these exact source slices only. No live wallet/reindex state was read.
| A11-05 Low `eb4f1fa1-3a4e-485d-9928-5c2e16f391c4` | `openforage_smart_contracts/src/CustodianRegistry.sol:276-288,699-705,1254-1274`; `openforage_smart_contracts/src/libraries/GuardianAuthorityClassifier.sol:104-135,133-143`; `openforage_smart_contracts/src/GuardianModule.sol:228-240,903-973,961-973` | **ACCEPT_BOUNDED for the selector-only retired-Registry classification.** The scanner uses only the canonical Registry; its retired `proposeGuardianModule` and `finalizeGuardianModule` entrypoints always revert and are excluded from downstream-mutation classification. The Registry's Timelock ownership pin is an additional defense, not the selector correction. The separate absent/expired rotation predicate has no Analysis 11 UUID, and the state-dependent CANCELLER grant/revoke residual belongs to A10-04 preflight, not A11-05. Reject conflating those mechanisms with this finding. No Octane status changed.
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

The ABI and storage results remain separate evidence. No contract test, runtime or gas simulation, RPC, chain, deployment, legacy-proxy, or live-state proof is claimed.

The same three contracts already exceeded the Default runtime limit at the previous PR head. Relative to that head, the ForageGovernor overage narrowed from 4,070 to 3,860 bytes; the StakingQueue overage widened from 2,806 to 2,863 bytes; and the USDCTreasury overage widened from 3,203 to 3,329 bytes. No other first-party contract became size-red.

Static results remain red or incomplete. The copied-source control for Registry selectors can accept a reintroduced retired selector, though current Solidity has no such branch. This is a checker gap, not a current source defect or a full static pass.

No Octane label changes here. All limits in this record are source-review bounds, not finding closure or security clearance.
