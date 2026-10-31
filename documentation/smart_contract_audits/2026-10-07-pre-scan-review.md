# 2026-10-07 pre-scan review: source changes and limits

Line references (note of 2026-10-11): the source-line ranges on this page were written for earlier commits. For the 2026-10-11 update, the ranges that point into the eight source files changed by that update were re-checked and the ones found stale were corrected. A range that was not found stale, or that points into another file, can still be a few lines away from the code it describes. The file identities in the source-pin table are exact. The two 2026-10-11 pages carry the checked ranges for the Analysis 14 changes.
Line references (note of 2026-10-28): the 2026-10-28 update changed 22 source files and added one. Ranges on this page that point into those files were not re-checked and may have moved; the [2026-10-28 pre-scan review](2026-10-28-pre-scan-review.md) lists the changed files and carries checked ranges for its own changes.

The source-line citations in this historical record are re-pinned to the mapped public source blobs listed in the [2026-10-11 post-scan update](2026-10-11-post-scan-update.md). Their prior review statuses remain historical; current Analysis 9–13 status is recorded in the linked disposition documents.

Dated snapshot note: this record predates the Analysis 13 scan. The 2026-10-11 post-scan update is the current public status; the earlier scan and commit identities below remain historical.
Dated note (2026-10-28): the [2026-10-28 pre-scan review](2026-10-28-pre-scan-review.md) is now the current public status.

This is OpenForage’s own 2026-10-07 source review of the public candidate before Analysis 13. It is not an Octane result, a finding-closure claim, deployment approval, or security-clearance statement. At that time the most recent full scan was Analysis 12 on `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; Analysis 13 later scanned the head identified in the post-scan update. No Octane analysis has run on the current candidate.

## Public source and review scope

At the time of this 2026-10-07 review, PR #9 head `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae` was the base and the commit scanned by Analysis 12. The later Analysis 13 scan covered the head identified in the post-scan update. Commit `01f4abe7768f03d2a21e6ab0a0221795d315d79b` and older commits are historical. The current public map has 70 entries: 40 first-party Solidity files, 21 ABI artifacts, eight selected deployment/script/interface files, and one suppression policy. It includes the five previously added source paths and two ABI artifacts listed below, plus `ForageGovernorTimelockGuard.json`. The eight changed Solidity files and their current source lines are in the 2026-10-11 post-scan update. The suppression file is byte-equal to the private source, and all 70 mapped files are compared with the exact private source. No first-party contract tests or private audit records, packet records, run logs, deployment state, or private tooling are copied.

## Work since the Analysis 12 scan

The final source has the following reviewed changes. Each statement is limited to the cited source; it does not establish live or deployed behavior. Source paths in the table are relative to `openforage_smart_contracts/` unless a full public path is shown.

| Change | Public source lines and bounded behavior |
|---|---|
| Profit recognition uses fresh accepted NAV headroom after deployed principal and unreturned recognized profit; negative recognition is limited to unreturned profit above NAV headroom. Cash-out uses fresh NAV and lifetime unreturned-profit bounds. | `openforage_smart_contracts/src/USDCTreasury.sol:368-394,449-463`; `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol:357-414,468-478`. |
| The Bridge pause covers deployment, intents, principal and PnL returns, reconciliation, `settleLoss`, and manual NAV routes. The owner controls unpause; the bounded 4-of-7 emergency principal lane is the recorded exception. | `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:713-727,762-827,877-942,950-1065,1095-1102,1261-1274,1382-1435`; `GuardianEmergencyPrincipalLane.sol:21-67`. |
| PnL uses a dedicated `PNL_ATTESTOR`; role separation is checked at runtime, including refusal when it aliases keeper or executor. | `USDCTreasury.sol:310-314,361-364`; `modules/USDCTreasuryAccountingModule.sol:276-314`; `script/Deploy.s.sol:261,341`. |
| Agent pay is available only in the first 14 UTC days after quarter end. Cumulative paid amount cannot exceed cumulative agent share credited from PnL returned as cash; the daily cap is removed while the earmark check remains. | `openforage_smart_contracts/src/modules/USDCTreasuryProfitPolicyModule.sol:151-192,212`; `USDCTreasury.sol:609-650`. |
| Guardian cancel-only wallets are separate from pause wallets and use the cancel role; Deploy accepts seven cancel addresses. | `openforage_smart_contracts/src/GuardianModule.sol:86,226-230,303-307,665-669`; `Deploy.s.sol:1243-1270`. |
| Four-of-seven emergency principal return uses a seven-day lane, a fixed RISKUSD destination, and remains available while paused; profit withdrawals stay blocked. | `openforage_smart_contracts/src/GuardianEmergencyPrincipalLane.sol:21-67`; `HLTradingBridge.sol:321-328,792-801,925-947,1311-1324,1607-1611`. |
| Weekly holder exits use a pooled, pro-rata matured cohort; tier moves do not consume the holder exit budget. Vault mint limits use daily and weekly basis caps with the recorded floor. | `openforage_smart_contracts/src/modules/AtRiskUSDWeeklyExitModule.sol:12-24`; `AtRiskUSDStateModule.sol:397-435,736-828`; `RISKUSDVault.sol:387-400,1156-1169,1511-1522`; `RISKUSDVaultModule.sol:1110-1121`. |
| Compliance actions and plain token transfers do not wait for queued vote-eligibility synchronization; vote reads remain fail-closed while work is pending. | `openforage_smart_contracts/src/ForageToken.sol:402-420,442-465,682-709,820-827`; `ForageTokenStateModule.sol:983-1025,1605-1619,2375-2390`. |

Rounds 3–5 of the contract-family sweeps recorded each change and its independent source review. The regression check covered 277 earlier findings with zero regressions. Each added or changed source slice received independent review; the per-finding Analysis 9–12 tables state its bounded verdict and reason. The count is a regression review count, not a clean scanner count or a finding-closure count.

## Static evidence

The public candidate’s `check_slither_suppressions.js` and `slither_suppressions.json` are checked together against the canonical raw Slither scan retained for the exact private source. The measured pass below is limited to that exact pair and scan; it does not establish a fresh Slither scan or remove pre-existing analyzer findings.

**Validator result:** `OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37_PASS detectors=518 suppressions=518` (exit 0). The exact public checker and public suppression file passed against the retained canonical raw scan for this private source. The retained scanner receipt records child exit 255; this is a suppression-policy reconciliation result, not a clean fresh Slither run.

Introduced analyzer rows have per-row dispositions and the status of their independent review; pre-existing analyzer rows remain separate. Public Semgrep preflight exited 1 with `OPENFORAGE_PUBLIC_SEMGREP_COVERAGE_FAIL public source/import/policy input changed abi/Allowlist.json`; the public source manifest has not been rebound to this source. The audit-reuse receipt checker is absent from the public script tree. No fresh full Semgrep or Slither scan is claimed. The suppression validator proves only that the public checker and public policy file reconcile the retained raw scan.

## Build evidence

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

## Declared limits from the private register

| Limit | Retained boundary and reason |
|---|---|
| the founder's recorded decision Timelock deposits | ETH and NFT receipt remain open as an accepted donation exception. A deposit grants no protocol use; no wrapper or deployment change is authorized. |
| the founder's recorded decision rounding | About one raw unit (0.000001 USD) per profit recognition and partial funding/write-down tick remains in funded reserve. No cross-holder sweep is added. |
| the founder's recorded decision unlimited blocking/revocation | Blocklist blocking and Allowlist revocation remain unlimited in count as the accepted gap. |
| related source finding under the founder's recorded decision | Queued vote-sync work can keep `getVotes` and `getPastVotes` and dependent governance calls unavailable. Compliance writes and plain token transfers remain live; a query-scoped replay fix is not part of this source. |
| related source finding under the founder's recorded decision | Allowlist activation checks every registered vesting source in one O(N) call with no total-source bound; whole-call gas is unmeasured. |
| related source finding | `_doublePartialIndexPlan` typed-refuses outside the demonstrated range; the recorded scale example is 49 doublings with about 66 bits of uint256 headroom. No operating cap was established. |
| related source finding | An empty Registry return window uses the first same-window deployment as its basis; the bounded example remains source-recorded. |
| A9-02 / related source finding / related source record under the founder's recorded decision | A new implementation can guard old state only after the installed implementation authorizes the first UUPS installation. Use fresh proxies; no legacy upgrade or live proxy proof is claimed. |
| A12-15 KYC lapse | A lapsed holder remains frozen from gated exits/claims until renewal; no grace route exists. |
| A10-17 gas | The bounded callback count does not prove whole-call gas fit or out-of-gas safety. |
| A12-05 / A10-01 gross redemption | Gross requested redemption consumes weekly cap; no mint offset or cap refund is applied. |
| A1-18 / A7-15 / the founder's recorded decision queue order | A too-large standard entry is skipped and retried; later smaller fitting entries may go first. No per-entry fairness or eventual-fill guarantee is claimed. |
| A11-01 proposal slot | Multiple qualified proposal identities can consume the explicit global quota; a succeeded ordinary proposal that is never queued can remain counted and queued expiry does not apply. This is separate from the below-threshold cancellation decision. |
| Default size limits | The current 2026-10-11 source build has eight runtime overages and one initcode overage; exact byte counts and margins are in the current build table. Deploy fits all 39 artifacts. |
| Storage baseline | Seven inherited layout divergences remain: atRISKUSD `_emergencyLossPendingOverrideUntil` slot and gap type; USDCTreasury gap label; VaultRegistry gap type; HLTradingBridge `guardianModule` label, `_legacyGuardianModule` slot and gap type. No baseline change or waiver is claimed; no fresh public storage comparison ran. |
| the founder's recorded decision Windows | Both Windows x86_64 CLI rows remain failed; no Visual Studio license is installed, purchased, or accepted. |
| Gas measurements | No transaction or whole-call gas measurement is established for Token callback/read paths, queue scans, Registry traversal, or governance walks; source bounds are not gas proofs. |

## Other proof limits

A9-21 whole-query gas and A10-17 whole-call gas fit are unmeasured. No first-party contract runtime tests, mocks, fuzz/formal harness, Forge test, EVM/Anvil/runtime/gas simulation, RPC/chain, deployed-state, or legacy-proxy proof is claimed. the founder's recorded decision fresh-only deployment remains in force; the first legacy upgrade is governed by the installed implementation’s authorizer. The bounded Analysis 11 and 12 dispositions are not unconditional fixes. The public text does not claim A9-02 is fully closed. Warning 28’s dated capture gap remains historical. No security clearance or Octane closure is claimed.

## Current public source blob pins

The source line references in this record resolve to these exact mapped Solidity file blobs in the public candidate.

| Public source file | Git blob |
|---|---|
| `openforage_smart_contracts/src/ForageToken.sol` | `2fd8d00e6c58775e2b0c2662796cbfe5b1c7f122` |
| `openforage_smart_contracts/src/GuardianEmergencyPrincipalLane.sol` | `743fc89e8f4486860a572269b2b56be8771bc43a` |
| `openforage_smart_contracts/src/GuardianModule.sol` | `8c1be68aaf5eb2a92949a705f33bf7a12e687711` |
| `openforage_smart_contracts/src/USDCTreasury.sol` | `25cb223f201be6892be3ae99501a275a6de37a76` |
| `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol` | `dc14acccca669f4e0d7903eef479a8b708519d7b` |
| `openforage_smart_contracts/src/modules/AtRiskUSDWeeklyExitModule.sol` | `a19345a466362619ed61dfaef6ae3891d6a5afb9` |
| `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol` | `a35a15c93ce055f48827b3caf07f1564e73b9074` |
| `openforage_smart_contracts/src/modules/USDCTreasuryProfitPolicyModule.sol` | `ba78a8eded831314e9c8ede679d5514ec58873ad` |
