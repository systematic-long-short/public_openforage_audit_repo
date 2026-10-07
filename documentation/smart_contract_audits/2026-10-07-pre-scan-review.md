# 2026-10-07 pre-scan review: source changes and limits

This is OpenForage’s own source review of the public candidate before the next full scan. It is not an Octane result, a finding-closure claim, deployment approval, or security-clearance statement. The sole completed full scan remains the scan of PR #9 head `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; no further scan is authorized by this packet.

## Public source and review scope

This update starts from PR #9 head `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`, which is also the commit scanned by Analysis 12. Commit `01f4abe7768f03d2a21e6ab0a0221795d315d79b` and older commits are historical. The explicit map has 40 first-party Solidity files, 20 ABI artifacts, eight selected deployment/script/interface files, and one suppression policy. Added sources: `GuardianEmergencyPrincipalLane.sol`, `interfaces/IEmergencyPrincipalLane.sol`, `modules/AtRiskUSDWeeklyExitModule.sol`, `modules/CustodianRegistryCapitalModule.sol`, and `modules/USDCTreasuryProfitPolicyModule.sol`. Added ABIs: `GuardianEmergencyPrincipalLane.json` and `USDCTreasuryAccountingModule.json`. `contracts/slither_suppressions.json` is byte-equal to the public `slither_suppressions.json`. The separately mapped suppression file is the compatible public input to the mapped checker. The map has 69 entries; all 69 mapped bytes are compared with the exact private source. The five source and two ABI files were absent from the previous public map; no first-party contract tests or private audit records, packet records, run logs, deployment state, or private tooling are copied. 

## Work since the Analysis 12 scan

The final source has the following reviewed changes. Each statement is limited to the cited source; it does not establish live or deployed behavior. Source paths in the table are relative to `openforage_smart_contracts/` unless a full public path is shown.

| Change | Public source lines and bounded behavior |
|---|---|
| Profit recognition uses fresh accepted NAV headroom after deployed principal and unreturned recognized profit; negative recognition is limited to unreturned profit above NAV headroom. Cash-out uses fresh NAV and lifetime unreturned-profit bounds. | `openforage_smart_contracts/src/USDCTreasury.sol:368-394,449-463`; `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol:357-414,468-478`. |
| The Bridge pause covers deployment, intents, principal and PnL returns, reconciliation, `settleLoss`, and manual NAV routes. The owner controls unpause; the bounded 4-of-7 emergency principal lane is the recorded exception. | `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:711-725,759-824,874-937,945-1060,1090-1097,1256-1269,1377-1430`; `GuardianEmergencyPrincipalLane.sol:21-67`. |
| PnL uses a dedicated `PNL_ATTESTOR`; role separation is checked at runtime, including refusal when it aliases keeper or executor. | `USDCTreasury.sol:310-314,361-364`; `modules/USDCTreasuryAccountingModule.sol:276-314`; `script/Deploy.s.sol:261,341`. |
| Agent pay is available only in the first 14 UTC days after quarter end. Cumulative paid amount cannot exceed cumulative agent share credited from PnL returned as cash; the daily cap is removed while the earmark check remains. | `openforage_smart_contracts/src/modules/USDCTreasuryProfitPolicyModule.sol:151-192,212`; `USDCTreasury.sol:609-650`. |
| Guardian cancel-only wallets are separate from pause wallets and use the cancel role; Deploy accepts seven cancel addresses. | `openforage_smart_contracts/src/GuardianModule.sol:86,226-230,303-307,656-660`; `Deploy.s.sol:1243-1270`. |
| Four-of-seven emergency principal return uses a seven-day lane, a fixed RISKUSD destination, and remains available while paused; profit withdrawals stay blocked. | `openforage_smart_contracts/src/GuardianEmergencyPrincipalLane.sol:21-67`; `HLTradingBridge.sol:296-308,1256-1269,1525-1534`. |
| Weekly holder exits use a pooled, pro-rata matured cohort; tier moves do not consume the holder exit budget. Vault mint limits use daily and weekly basis caps with the recorded floor. | `openforage_smart_contracts/src/modules/AtRiskUSDWeeklyExitModule.sol:12-24`; `AtRiskUSDStateModule.sol:397-429,727-813`; `RISKUSDVault.sol:387-400,1156-1169,1511-1522`; `RISKUSDVaultModule.sol:1110-1121`. |
| Compliance actions and plain token transfers do not wait for queued vote-eligibility synchronization; vote reads remain fail-closed while work is pending. | `openforage_smart_contracts/src/ForageToken.sol:402-420,442-465,682-709,820-827`; `ForageTokenStateModule.sol:983-1025,1605-1619,2375-2390`. |

Rounds 3–5 of the contract-family sweeps recorded each change and its independent source review. The regression check covered 277 earlier findings with zero regressions. Each added or changed source slice received independent review; the per-finding Analysis 9–12 tables state its bounded verdict and reason. The count is a regression review count, not a clean scanner count or a finding-closure count.

## Static evidence

The public candidate’s `check_slither_suppressions.js` and `slither_suppressions.json` are checked together against the canonical raw Slither scan retained for the exact private source. The measured pass below is limited to that exact pair and scan; it does not establish a fresh Slither scan or remove pre-existing analyzer findings.

**Validator result:** `OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37_PASS detectors=518 suppressions=518` (exit 0). The exact public checker and public suppression file passed against the retained canonical raw scan for this private source. The retained scanner receipt records child exit 255; this is a suppression-policy reconciliation result, not a clean fresh Slither run.

Introduced analyzer rows have per-row dispositions and the status of their independent review; pre-existing analyzer rows remain separate. Public Semgrep preflight exited 1 with `OPENFORAGE_PUBLIC_SEMGREP_COVERAGE_FAIL public source/import/policy input changed abi/Allowlist.json`; the public source manifest has not been rebound to this source. The audit-reuse receipt checker is absent from the public script tree. No fresh full Semgrep or Slither scan is claimed. The suppression validator proves only that the public checker and public policy file reconcile the retained raw scan.

## Build evidence

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

## Declared limits from the private register

| Limit | Retained boundary and reason |
|---|---|
| DEC-21 Timelock deposits | ETH and NFT receipt remain open as an accepted donation exception. A deposit grants no protocol use; no wrapper or deployment change is authorized. |
| DEC-26 rounding | About one raw unit (0.000001 USD) per profit recognition and partial funding/write-down tick remains in funded reserve. No cross-holder sweep is added. |
| DEC-32 unlimited blocking/revocation | Blocklist blocking and Allowlist revocation remain unlimited in count as the accepted gap. |
| NEW-1108-01 under DEC-24 | Queued vote-sync work can keep `getVotes` and `getPastVotes` and dependent governance calls unavailable. Compliance writes and plain token transfers remain live; a query-scoped replay fix is not part of this source. |
| NEW-1316-01 under DEC-24 | Allowlist activation checks every registered vesting source in one O(N) call with no total-source bound; whole-call gas is unmeasured. |
| NEW-1120-01 | `_doublePartialIndexPlan` typed-refuses outside the demonstrated range; the recorded scale example is 49 doublings with about 66 bits of uint256 headroom. No operating cap was established. |
| NEW-1173-01 | An empty Registry return window uses the first same-window deployment as its basis; the bounded example remains source-recorded. |
| A9-02 / NEW-1217-02 / R1268-01 under DEC-13 | A new implementation can guard old state only after the installed implementation authorizes the first UUPS installation. Use fresh proxies; no legacy upgrade or live proxy proof is claimed. |
| A12-15 KYC lapse | A lapsed holder remains frozen from gated exits/claims until renewal; no grace route exists. |
| A10-17 gas | The bounded callback count does not prove whole-call gas fit or out-of-gas safety. |
| A12-05 / A10-01 gross redemption | Gross requested redemption consumes weekly cap; no mint offset or cap refund is applied. |
| A1-18 / A7-15 / DEC-28 queue order | A too-large standard entry is skipped and retried; later smaller fitting entries may go first. No per-entry fairness or eventual-fill guarantee is claimed. |
| A11-01 proposal slot | Multiple qualified proposal identities can consume the explicit global quota; a succeeded ordinary proposal that is never queued can remain counted and queued expiry does not apply. This is separate from the below-threshold cancellation decision. |
| Default EIP-170 size | ForageGovernor is 27,212 bytes (2,636 over) and StakingQueue is 27,697 bytes (3,121 over); USDCTreasury is 24,197 bytes (379 below). No Default initcode overage; all Deploy artifacts fit. Exact table follows below. |
| Storage baseline | Seven inherited layout divergences remain: atRISKUSD `_emergencyLossPendingOverrideUntil` slot and gap type; USDCTreasury gap label; VaultRegistry gap type; HLTradingBridge `guardianModule` label, `_legacyGuardianModule` slot and gap type. No baseline change or waiver is claimed; no fresh public storage comparison ran. |
| DEC-16 Windows | Both Windows x86_64 CLI rows remain failed; no Visual Studio license is installed, purchased, or accepted. |
| Gas measurements | No transaction or whole-call gas measurement is established for Token callback/read paths, queue scans, Registry traversal, or governance walks; source bounds are not gas proofs. |

## Other proof limits

A9-21 whole-query gas and A10-17 whole-call gas fit are unmeasured. No first-party contract runtime tests, mocks, fuzz/formal harness, Forge test, EVM/Anvil/runtime/gas simulation, RPC/chain, deployed-state, or legacy-proxy proof is claimed. DEC-13 fresh-only deployment remains in force; the first legacy upgrade is governed by the installed implementation’s authorizer. The bounded Analysis 11 and 12 dispositions are not unconditional fixes. The public text does not claim A9-02 is fully closed. Warning 28’s dated capture gap remains historical. No security clearance or Octane closure is claimed.
