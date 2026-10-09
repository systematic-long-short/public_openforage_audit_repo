# 2026-10-09 post-scan update

## What this update says

Analysis 13 scanned the previously published PR #9 head `78a465cba5a47bbb4f542a6f305f482ddc73b0e9`. The source update below is OpenForage's own source review, not an Octane result. No Octane analysis has run on this tree. No future scan is promised or authorized by this update. The contract design was kept as it was when scanned; Octane's proposed fix was the default for each finding, and any different disposition gives its reason in the linked [Analysis 13 dispositions](2026-10-09-analysis-13-dispositions.md).

The old PR head `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae` and `01f4abe7768f03d2a21e6ab0a0221795d315d79b` are historical only. This update is based on the published head named above.

## Mapping and reviewed source changes

The public allowlist contains 40 Solidity source, interface, library, and module files; 20 ABI files; eight selected script/interface files; and one Slither suppression policy. Nine source/ABI paths were added since the earlier source/ABI map: `src/GuardianEmergencyPrincipalLane.sol`, `src/interfaces/IEmergencyPrincipalLane.sol`, `src/interfaces/IRISKUSDSettlement.sol`, `src/libraries/GuardianAuthorityClassifier.sol`, `src/modules/AtRiskUSDWeeklyExitModule.sol`, `src/modules/CustodianRegistryCapitalModule.sol`, `src/modules/USDCTreasuryProfitPolicyModule.sol`, `abi/GuardianEmergencyPrincipalLane.json`, and `abi/USDCTreasuryAccountingModule.json`. The current private inventory has no unlisted first-party source or ABI path. Private audit records, run logs, scan tooling, and non-allowlisted scripts remain excluded. No first-party contract tests are included.

Every included source change received an independent source review. Changes first rejected were corrected before inclusion and reviewed again. After the fixes, adversarial sweeps of each changed contract family found two further defects: manual NAV recovery after a settled total loss, and a queue scan-position rewind on priority demotion. Both were fixed and independently reviewed. These are bounded source reviews, not runtime proof.

## Fixed Analysis 13 findings by contract family

| Contract family | Findings fixed | Public source lines |
|---|---|---|
| atRISKUSD weekly exits and profit epochs | A13-01, A13-01-r1, A13-14 | `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:406-427,414-427,540-560,728-735,737-755,758-764,797-813`; `openforage_smart_contracts/src/atRISKUSD.sol:454-466`; `openforage_smart_contracts/src/AllowlistGatedUpgradeable.sol:36-39,87-95`; `openforage_smart_contracts/src/modules/AtRiskUSDProfitModule.sol:523-560` |
| StakingQueue order, capacity, and events | A13-02, A13-02-r1, A13-12, A13-13-r1, A13-17, A13-21 | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:467-480,483-525,869-968,1014-1017,1113-1117,1134-1143,1314-1337,1399-1413`; `openforage_smart_contracts/src/StakingQueue.sol:207-209,240,958-1004,1002-1004,904-930,1234-1245` |
| vault deployment buffer, zero-principal custody, and NAV recovery | A13-06, A13-09, A13-16, A13-22 | `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:1188-1219`; `openforage_smart_contracts/src/interfaces/IVaultRegistry.sol:34`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:202-245,260-285,362-385,945-969,1460-1475,1496-1511,1539`; `openforage_smart_contracts/src/USDCTreasury.sol:223,411-420,719-743,1019-1025` |
| atRISKUSD approval reset | A13-07 | `openforage_smart_contracts/src/atRISKUSD.sol:234-235,923-954` |
| Guardian emergency result events | A13-18 | `openforage_smart_contracts/src/GuardianModule.sol:63,249-301` |
| FORAGETreasury sweep and distributor events | A13-20, A13-23 | `openforage_smart_contracts/src/FORAGETreasury.sol:231,236-237,443,456,459-475` |

## Items retained as intended or monitoring-only

- **A13-01-r2:** tier moves remain outside the weekly holder-exit budget; destination capacity and lock rules still apply.
- **A13-02-r2:** standard processing remains closed until the complete priority pass finishes, preserving priority ordering.
- **A13-03 and A13-03-r1:** vote reads fail closed while global eligibility work is queued. No queue-wide liveness redesign was authorized.
- **A13-04:** ordinary Pending and Active proposals remain cancellable below the proposer threshold.
- **A13-05:** an attested loss is borne by holders at report time; exits that could avoid a pending reported loss stay frozen through settlement. Holders are not frozen before report-time evidence exists.
- **A13-05-r1:** holders at profit recognition own the separate recognized-but-unpaid entitlement; withdrawal pricing remains cash-backed.
- **A13-08:** automatic expired-tier return to Tier 0 stays cap-exempt; the cap still limits new admissions.
- **A13-10:** same-ID priority demotion and the strict priority completion gate remain; the reported partial-minimum condition is unreachable under the reviewed source preconditions.
- **A13-11:** a healthy NAV does not clear an open reported-loss nonce; exits stay frozen until settlement.
- **A13-13:** an admitted priority lock is retained when a later Oracle or sequencer read is unavailable; the entry is not repriced.
- **A13-15:** lapsed standard entries retain their original ID and position until expiry. Total queue size and whole-call gas remain unbounded or unmeasured.
- **A13-19:** events emitted in a reverting frame do not persist, so no on-chain event change was made. Failed-receipt/error monitoring or health-view polling is the operational option; no monitoring configuration was supplied as evidence.
- **A13-24:** the shared per-day deployment cap and per-custodian `maxDeployed` remain; no separate per-custodian daily cap was added.

Each Analysis 11, 12, and 13 disposition remains bounded to its stated source path and assumptions. None is an unconditional finding-closure claim.

## Verification and static evidence

The public Default and Deploy builds used Forge 1.3.5 and Solc 0.8.24, offline, with the test tree skipped. Each compiled 137 source inputs and produced 39 first-party runtime/initcode artifacts. The Default child exited 1 only on six EIP-170 runtime size rows; Deploy exited 0 and every artifact fit. Exact runtime/initcode sizes and margins are below.

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

The public `slither_suppressions.json` is byte-equal to the private policy: 523 R37 entries, 521 `idDigest`, two `stableIdentity`, exactly one selector per entry. The public candidate checker was run with that candidate file against each of the two retained raw Slither scans. Each raw JSON had `success=true` and 523 detectors; the Slither child had exited 255. Both validator commands exited 0 and printed `OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37_PASS detectors=523 suppressions=523`. This validates only those two retained scans; no fresh Slither run is claimed. The exact retained raw scans have run IDs `01118ef7-77f3-4e80-892d-b9f375ee89ec` and `e4aa1de9-6b4a-4067-b051-7925c596c788`; both report `success=true` and 523 detectors. The public `.semgrep` source manifest, exceptions file, and two rule configs are byte-identical on base and candidate; the manifest is stale for the changed `abi/Allowlist.json`. No receipt/reuse-named inventory file or `check_audit_reuse_receipts.js` exists in either tree.

The mapped Semgrep preflight was measured on both the published base and candidate. Both exited 1 with `OPENFORAGE_PUBLIC_SEMGREP_COVERAGE_FAIL public source/import/policy input changed abi/Allowlist.json`. No Semgrep pass or fresh analyzer run is claimed. The public audit-receipt checker is absent on both trees: `node script/check_audit_reuse_receipts.js --help` exited 1 with `MODULE_NOT_FOUND` on each; there is no receipt/reuse-named inventory file in either tree. The four `.semgrep` manifest/config inputs are byte-identical between base and candidate. The retained private static triage lists 139 Slither `MATCH` rows, one justified new row for a default-empty deferral mapping, and four Semgrep `MATCH` rows; the introduced row has a per-row disposition and independent review, while pre-existing rows remain.

`check_i15_setters.js --json` passed on both trees with `{"checked":15,"minChecked":15,"delayChecked":15,"cancelChecked":15,"guardianCancelChecked":0,"registryRecheckChecked":0}`. `check_no_legacy_transport.js` passed on both with 50 files scanned, 11 targets, 13 patterns, and zero matches.

The public-source comparison has 69/69 mapped byte matches: 40 Solidity source files, 20 ABIs, eight selected scripts/interfaces, and the suppression policy. The public ABI directory has 20 files; 19 match compiler definitions and `FoundationTreasury.json` remains source-less. A retained private storage-check run against the byte-mapped source exited 1 with 26 matching rows and seven inherited baseline divergences. The checker is absent from the public tree, so no fresh public-tree storage run is claimed; no new divergence is claimed.

## Complete declared limits and proof gaps

| Limit or retained boundary | Reason and scope |
|---|---|
| Six Default EIP-170 size reds | Exact current-run runtime sizes: ForageGovernor 27,212 bytes (2,636 over); HLTradingBridge 24,787 (211 over); RISKUSDVaultModule 24,820 (244 over); StakingQueue 27,953 (3,377 over); StakingQueueModule 25,148 (572 over); USDCTreasury 24,905 (329 over). Default has no EIP-3860 initcode overage; Deploy fits all 39 first-party runtime/initcode artifacts. |
| Storage baseline | The public storage checker retains seven inherited divergences: atRISKUSD emergency-override slot and gap type; USDCTreasury gap label; VaultRegistry gap type; Bridge guardianModule label, legacy guardian slot, and gap type. No claim of a clean storage baseline. |
| Windows | Both Windows x86_64 CLI rows remain failed under DEC-16 because no Visual Studio license is available; none was installed, purchased, or accepted. |
| Dynamic and deployed-state proof | No first-party contract tests, mocks, fuzz/formal harness, Forge test, EVM/Anvil/runtime/gas simulation, RPC/chain access, deployed-state inspection, or legacy-proxy proof was run. Source checks do not establish live behavior. |
| Fresh-only UUPS boundary and A9-02 | Funded legacy proxy upgrades are unsupported. The installed implementation authorizer controls the first installation; the implementation must fail loud before state change if legacy storage reaches a new path. Fresh initialization establishes new invariants. A9-02 is not described as fully closed. |
| A9-21, A10-17, A11-10 gas | A9-21 whole-query gas and A10-17 whole-call gas fit remain unmeasured; A11-10 source bounds do not measure whole-proposal gas. The A10-17 32-source callback bound is not a whole-call gas guarantee. |
| NEW-1108-01 / DEC-24 | Global voting reads fail closed while vote-eligibility work is queued; no queue-wide liveness redesign is claimed. |
| NEW-1316-01 / DEC-24 | Allowlist reindex activation walks every registered vesting source and has no total-source bound. |
| Timelock deposits / DEC-21 | ETH and NFT receive/receiver paths stay open as an accepted permission-rule exception; deposits grant no protocol use. |
| Profit-index rounding / DEC-26 | About one raw unit (0.000001 USD) may remain per recognition and per partial funding/write-down tick. It stays in funded reserve and is not transferred to another holder or cohort. |
| DEC-32 compliance operation count | Blocklist blocking and Allowlist revocation remain unlimited in count as the accepted gap. |
| NEW-1120-01 | The double-partial-index calculation typed-refuses outside its demonstrated operating range; no operating cap was added. |
| NEW-1173-01 | The first same-window Registry deployment seeds an empty return basis; cash must reconcile before a return. |
| A12-15 permission lapse | A lapsed wallet is frozen from gated interactions until approval is renewed, with no grace path. Plain FORAGE, RISKUSD and tier-share transfers and approvals remain ungated. |
| A12-05 / A10-01 | Vault redemption charges the full gross request against cap use; there is no mint offset or refund. |
| A1-18 / A7-15 / DEC-28 queue ordering | An oversized live standard entry may be skipped while later fitting entries proceed; the older entry retries next pass. Same-lane order has no per-entry fairness or eventual-fill guarantee. |
| A11-01 global proposal quota | Qualified identities share the explicit global proposal quota; a Succeeded-but-unqueued proposal has no expiry and remains counted. |
| DEC-10 loss-rate cap | The loss-rate cap counts losses charged to depositor tiers and excludes reserve-absorbed loss. |
| DEC-33 / DEC-34 NAV controls | Profit recognition is capped by fresh accepted NAV headroom after principal and unreturned recognized profit; negative recognition cannot exceed the unreturned amount above NAV-backed value. The upward postNAV ceiling base includes recognized profit retained in the trading account. |
| DEC-14 / DEC-15 profit and loss timing | Attested loss is borne by holders at report time; exits that avoid a pending reported loss stay frozen until settlement. Recognized-but-unpaid profit remains a separate entitlement of recognition-time holders; withdrawal pricing uses cash-backed value. |
| A13-01-r2 / DEC-42 | Tier moves remain outside the weekly holder-exit budget; destination capacity and lock rules still apply. |
| A13-02 bounded queue frontier | With maxEntries=1, the reviewed source trace is capped at 65 candidate units per call and assumes priority processing completes without an earlier standard STOP. This is not runtime or gas proof; priority completion remains required. |
| A13-14 permission exception / DEC-59 | Any holder may catch up only their own closed profit epochs, at most eight per call; the route moves no value. Claims remain allowlist-gated. The existing allowlisted keeper route remains available. |
| A13-09 / DEC-60 held Treasury funds | Reconciled zero-principal USDC is held in a non-distributable Treasury balance; its later use remains unassigned pending a founder decision. |
| A13-19 monitoring | Events emitted in a reverting frame do not persist. Monitoring is the operational option; no monitoring configuration was supplied as proof. |
| A13-06 zero deployment-buffer setting | A zero buffer setting returns before Registry lookup and disables this check. With a nonzero value, lookup failures refuse and enumeration covers only the four OF-TARGET tier vaults. |
| A13-15 queue scan | Lapsed standard rows retain their ID and position until expiry; total queue size and whole-call gas remain unbounded or unmeasured. |
| A13-16 NAV recovery | Zero previous or interval-start NAV uses deployed principal as the cap basis. After settled total loss, recovery uses the last nonzero principal basis; unresolved-loss guards remain and no cap is removed. |
| Static analyzer and receipt evidence | No fresh Slither or Semgrep run is claimed. The public Semgrep preflight exits 1 on both base and candidate because the Allowlist ABI digest is stale; the audit-receipt checker is absent on both. Suppression validation passes only against the two identified retained private raw Slither scans. |

The historical Analysis 1–8 identity census remains byte-equal, all 155 UUID identities remain, and Warning 28's dated missing-capture gap is preserved. No Octane label, deployment state, security clearance, or finding closure is claimed.

See [Analysis 13 dispositions](2026-10-09-analysis-13-dispositions.md) for all 24 findings and seven related cases, their UUID availability, latest independent critique verdict, public source lines, source status, and Octane-suggestion decision.

## Current public source blob pins

Every public source-line reference in the Analysis 9–13 dispositions resolves against the mapped source blobs below. The table records the exact public file blob identity; line ranges are relative to that blob.

| Public source file | Git blob |
|---|---|
| `openforage_smart_contracts/src/Allowlist.sol` | `6ec03daf0336ba1f52ea4bf28e082feb114b9c6a` |
| `openforage_smart_contracts/src/AllowlistGatedUpgradeable.sol` | `5f23a84abe861a87da4309dabca99ea80f66f422` |
| `openforage_smart_contracts/src/Blocklist.sol` | `ebf9fe539917dd9841fb1eb298411c4f178bb057` |
| `openforage_smart_contracts/src/CustodianRegistry.sol` | `46847287613d4cfd17c5104771872fe151ed7afe` |
| `openforage_smart_contracts/src/DelegatingVestingWallet.sol` | `6e0e513fa7c29097dff976dc1279ba43ff6c0c9e` |
| `openforage_smart_contracts/src/FORAGETreasury.sol` | `320a60d5183e8f21912f0f0ff832a5d7f593a254` |
| `openforage_smart_contracts/src/FinalizeDelayProfile.sol` | `d8c28d9b3a42e4dfb0d82496ae21bdf2ac5832c3` |
| `openforage_smart_contracts/src/ForageGovernor.sol` | `3a4728d1eba330228e03bd6c37d4cb111d147605` |
| `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol` | `0a8e4d2c204182a460f08a4254617b6e5a7f6e07` |
| `openforage_smart_contracts/src/ForageToken.sol` | `2fd8d00e6c58775e2b0c2662796cbfe5b1c7f122` |
| `openforage_smart_contracts/src/GuardianEmergencyPrincipalLane.sol` | `743fc89e8f4486860a572269b2b56be8771bc43a` |
| `openforage_smart_contracts/src/GuardianModule.sol` | `f9ebd4226bb291220c346343db2c0506b7d94b74` |
| `openforage_smart_contracts/src/IForageGovernorPause.sol` | `a0e929ca5fdda6c5f8be4c280d59cf43ba237899` |
| `openforage_smart_contracts/src/RISKUSD.sol` | `8b2d2eeefe3419d9e96b2eb52f90387cdefb78c4` |
| `openforage_smart_contracts/src/RISKUSDVault.sol` | `7244cdb90fe10dfd102c01c5c1b81215660fa7e6` |
| `openforage_smart_contracts/src/StakingQueue.sol` | `a9268e056a2b1e1a2bfb0cab65552f6d52360bc3` |
| `openforage_smart_contracts/src/USDCTreasury.sol` | `25cb223f201be6892be3ae99501a275a6de37a76` |
| `openforage_smart_contracts/src/VaultRegistry.sol` | `44cbd0a1ad09450f897d00df7f25ca9bedf5f3b6` |
| `openforage_smart_contracts/src/atRISKUSD.sol` | `4523cf1e96307a5a81966009fa94bfcc99c0c4aa` |
| `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol` | `dc34e056118dddd74f5ac5a0b835457d6cc18e5d` |
| `openforage_smart_contracts/src/interfaces/IAllowlist.sol` | `3725ea44345cc72a0746e63bc3c59e5f2917672c` |
| `openforage_smart_contracts/src/interfaces/IAllowlistSystemRegistrar.sol` | `4178bfe514ca5349386d4d3e00ba5dd55e072915` |
| `openforage_smart_contracts/src/interfaces/IAtRiskUSDProfitClaims.sol` | `44ddf9d9febb4e33b6c55b630ebeeec69a7366cb` |
| `openforage_smart_contracts/src/interfaces/IBlocklist.sol` | `966cdfa32a353d9a7d5ac38c99b85e57c1b3b22c` |
| `openforage_smart_contracts/src/interfaces/IEmergencyPrincipalLane.sol` | `8897ae68a17716e233c5724abb13effa68a264b5` |
| `openforage_smart_contracts/src/interfaces/IForageVotes.sol` | `8232516e12f5e5c0ff7b1db77609756452b57eed` |
| `openforage_smart_contracts/src/interfaces/IRISKUSDSettlement.sol` | `f81cac3da4516e643595044758bcdd18198deda1` |
| `openforage_smart_contracts/src/interfaces/ISequencerUptimeFeed.sol` | `30e4112a176337979dcce65506e1a0f8dd0d6747` |
| `openforage_smart_contracts/src/interfaces/IUSDCTreasuryYieldClaims.sol` | `959fcea5e2327bac65436ac08b514a4da99d855e` |
| `openforage_smart_contracts/src/interfaces/IVaultRegistry.sol` | `07fb5ac1031e9df740f09adfdb45facf17922ef4` |
| `openforage_smart_contracts/src/libraries/GuardianAuthorityClassifier.sol` | `7ad471b979c40ca8334cf41a014615a4ac994331` |
| `openforage_smart_contracts/src/modules/AtRiskUSDProfitModule.sol` | `45501007752f124044e0e3193f398d42a2f7fb80` |
| `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol` | `df9f457d70e505b2a37a10cb9c59224a7a5c3a57` |
| `openforage_smart_contracts/src/modules/AtRiskUSDWeeklyExitModule.sol` | `a19345a466362619ed61dfaef6ae3891d6a5afb9` |
| `openforage_smart_contracts/src/modules/CustodianRegistryCapitalModule.sol` | `1bdef18bd31102f7fc7d8b2e052d94c109fcd4ab` |
| `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol` | `59021b0d9eea55803b88dfa192283c05aa12cbd6` |
| `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol` | `4e365adf2048f77ec354c1cf336b105e11a61366` |
| `openforage_smart_contracts/src/modules/StakingQueueModule.sol` | `b4a9135966e819f2b29f5437be4461c853a89b3d` |
| `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol` | `a35a15c93ce055f48827b3caf07f1564e73b9074` |
| `openforage_smart_contracts/src/modules/USDCTreasuryProfitPolicyModule.sol` | `ba78a8eded831314e9c8ede679d5514ec58873ad` |
