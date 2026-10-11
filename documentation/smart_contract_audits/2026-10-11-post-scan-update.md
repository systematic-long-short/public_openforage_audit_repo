# 2026-10-11 post-scan update

## What changed

Analysis 14 scanned the previously published PR #9 head `1c1085499239962b543dae724f041414a2d4eecd`. This update records OpenForage's own source review, not an Octane result. No Octane analysis has run on this tree. No future Octane scan is promised or authorized by this update.

The contract design stayed as it was in the scanned tree except for the weekly-exit rule needed to correct the prior exit-cap change. For each other finding, Octane's recommendation was the default; a different fix has a specific written reason in the [Analysis 14 dispositions](2026-10-11-analysis-14-dispositions.md). Reviewer-requested corrections were applied and reviewed. No broader redesign or new mechanism was added.

The public source map contains 70 files: 40 Solidity source, interface, library, and module files; 21 ABI files; eight selected deployment-script and interface files; and one suppression policy. All 40 first-party source files are mapped. The new Timelock guard ABI is included; 20 ABIs match compiler definitions, and `FoundationTreasury.json` remains the source-less ABI. The eight changed Solidity files are `ForageGovernor.sol`, `ForageGovernorTimelockGuard.sol`, `GuardianModule.sol`, `atRISKUSD.sol`, `HLTradingBridge.sol`, `AtRiskUSDStateModule.sol`, `RISKUSDVaultModule.sol`, and `StakingQueueModule.sol`. The update also adds `ForageGovernorTimelockGuard.json`, refreshes the linked migration-guard pins in both profiles and the deployment script, and carries the exact 525-entry private suppression file. No first-party contract test path is included.

## Ten fixed findings by contract family

| Contract family | Findings | Public source lines |
|---|---|---|
| Weekly exits and withdrawal-window snapshots | A14-01, A14-17 | `openforage_smart_contracts/src/atRISKUSD.sol:291,295-300,415-440,701-710,779-785,1135-1155`; `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:398-440,460-465,737-798` |
| Queue catch-up | A14-03 | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:1156-1166` |
| Governor and Timelock protection | A14-04, A14-11, A14-12, A14-16 | `openforage_smart_contracts/src/ForageGovernor.sol:557-560,901-923,933`; `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol:1006-1037,1119-1136,1262-1306,1421-1463,1485-1519,1726-1767,1883-1889,2376-2392` |
| Fresh initialization | A14-05 | `openforage_smart_contracts/src/atRISKUSD.sol:291,295-300` |
| Bridge and vault return caps | A14-06 | `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:27-28,731-732,939-1000,1542-1588`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:1327-1394` |
| Guardian rotation | A14-13 | `openforage_smart_contracts/src/GuardianModule.sol:416-440,617-630` |

The [Analysis 14 dispositions](2026-10-11-analysis-14-dispositions.md) page lists the UUID, exact title, severity, latest review status, Octane proposal, action taken, and source lines for every visible finding. It records five items as intended and two as declared limits. It also lists the three findings Octane marked Automatically Acknowledged, with their separate dispositions.

## Five behaviors retained as intended

| Finding | Public source lines | Reason retained |
|---|---|---|
| A14-02 | `openforage_smart_contracts/src/USDCTreasury.sol:465-469,776`; `openforage_smart_contracts/src/modules/AtRiskUSDProfitModule.sol:417-475,499-514` | Holders at profit recognition own the profit; an unpaid amount remains a separate entitlement until cash arrives. |
| A14-07 | `openforage_smart_contracts/src/StakingQueue.sol:646-650`; `openforage_smart_contracts/src/modules/StakingQueueModule.sol:390-399` | A lapsed wallet stays frozen until renewal; owner-only blocked-depositor recovery remains available. |
| A14-08 | `openforage_smart_contracts/src/atRISKUSD.sol:458-468`; `openforage_smart_contracts/src/modules/AtRiskUSDProfitModule.sol:499-514,523-527` | Profit claims stay self-only and allowlist-gated; profit remains owned by holders at recognition. |
| A14-14 | `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:2375-2390` | The final vesting-source verification remains O(N); no redesign or total-source gas bound was authorized. |
| A14-15 | `openforage_smart_contracts/src/USDCTreasury.sol:143,419` | Reconciled zero-principal cash stays held and non-distributable. |

## Two declared limits

| Finding | Public source lines | Declared limit |
|---|---|---|
| A14-09 | `openforage_smart_contracts/src/StakingQueue.sol:646-677`; `openforage_smart_contracts/src/modules/StakingQueueModule.sol:870-937,1114-1118` | Repeated small entries can use bounded keeper work and delay other entries. No per-entry minimum, per-user limit, or whole-call gas measurement was added. |
| A14-10 | `openforage_smart_contracts/src/GuardianModule.sol:991-1014` | The retained guardian-rotation protection can sometimes prevent a guardian from cancelling a proposal that rotates another seat. The narrowing attempts either left some rotations uncancellable even when they could not execute, or let a guardian cancel a proposal that restored enough approvals to rotate that guardian out, which the design forbids. |

With no contract change, a guardian removed and later re-added can have an earlier approval counted again for the same pending rotation, but only until that rotation expires. The earlier disposition was retained for the split-review redemption-cap item; the three automatically acknowledged rows and their statuses are listed separately in the Analysis 14 page.

## Independent review and retained static evidence

Two independent reviewers classified every Analysis 14 finding. Every source change received independent review; several changes went through further correction rounds requested by reviewers. An adversarial sweep covered each changed contract family. The sweep-found side effects were fixed and reviewed again before this update.

The private source's retained Slither evidence is two raw scans on the same Deploy BuildInfo, with 258 artifacts. Each Slither child exited 255; each JSON result was successful and contained 525 detector rows. The public 525-entry R37 suppression file is byte-equal to the private file, has exactly one selector per entry, and contains 522 `idDigest` entries and three `stableIdentity` entries. The public checker passed on each of those two exact retained raw scans: `OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37_PASS detectors=525 suppressions=525` (exit 0 for each). This validates only the two retained scans; it is not a new Slither run on the public candidate.

The retained private Semgrep source/import preflight exited 0 with 40 roots, 77 imports, and 117 inputs. Its 1.177.0 scan exited 1 with 117 targets and 132 findings, with zero errors and zero skips. Scan validation exited 0 with 65 exceptions and 61 exception overlaps; manifest validation exited 0 for 40 sources, 77 transitive imports, and 117 inputs. The mapped public Semgrep preflight was also measured on the published base and this candidate: both exited 1 with `OPENFORAGE_PUBLIC_SEMGREP_COVERAGE_FAIL public source/import/policy input changed abi/Allowlist.json`. The four `.semgrep` manifest/config files are byte-identical between those trees. No Semgrep pass or fresh public analyzer run is claimed.

The public audit-receipt checker is absent on both trees. `node script/check_audit_reuse_receipts.js --help` exited 1 with `MODULE_NOT_FOUND` on each tree, and neither tree contains a receipt/reuse-named inventory file. The 15-check setter checker passed on both trees with `{"checked":15,"minChecked":15,"delayChecked":15,"cancelChecked":15,"guardianCancelChecked":0,"registryRecheckChecked":0}`. The legacy-transport checker passed on both with `{"sentinel":"NO_LEGACY_TRANSPORT_PASS","filesScanned":50,"targetsScanned":11,"forbiddenPatterns":13,"matches":0,"details":[]}`. These results describe only the named scripts and inputs.

## Default and Deploy build evidence

Forge 1.3.5 and Solc 0.8.24 compiled 137 public source inputs in each offline profile with the test tree skipped. Default compiled with zero compiler errors; its size child exited 1. Six previously reported Default runtime overages remain: ForageGovernor 28,053 bytes (3,477 over), HLTradingBridge 24,673 (97 over), RISKUSDVaultModule 24,820 (244 over), StakingQueue 27,953 (3,377 over), StakingQueueModule 25,421 (845 over), and USDCTreasury 24,905 (329 over). This build also reports two further Default runtime overages: GuardianModule 24,632 bytes (56 over) and ForageGovernorTimelockMigrationGuard 24,690 (114 over). ForageGovernor initcode is 49,498 bytes, 346 over the EIP-3860 limit. Deploy exited 0; all 39 first-party runtime/initcode artifacts fit. Its tightest runtime margin is 65 bytes for StakingQueueModule.

The table gives runtime and initcode byte counts; values in parentheses are the margins below the 24,576-byte runtime and 49,152-byte initcode limits. A negative margin is an overage.

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

## Complete declared limits and proof gaps

| Limit or retained boundary | Reason and scope |
|---|---|
| Default size limits | This run has eight EIP-170 runtime overages and one EIP-3860 initcode overage; exact counts and margins are in the build table above. Deploy fits all 39 first-party runtime/initcode artifacts. |
| Storage baseline | `python3 contracts/script/check_storage_layout.py --check` against the private source mapped into this update exited 1 with `SUMMARY ok=26 divergences=7`. The divergences are atRISKUSD emergency-override slot and gap type; USDCTreasury gap label; VaultRegistry gap type; HLTradingBridge guardianModule label, legacy guardian slot, and gap type. The checker is absent from the public tree, so no public storage check is claimed. |
| Windows | Both Windows x86_64 CLI rows remain failed under the founder's recorded decision because no Visual Studio license is available; none was installed, purchased, or accepted. |
| Dynamic and deployed-state proof | No first-party contract tests, mocks, fuzz/formal harness, Forge test, EVM/Anvil/runtime/gas simulation, RPC/chain access, deployed-state inspection, or legacy-proxy proof was run. Source checks do not establish live behavior. |
| Fresh-only UUPS boundary and A9-02 | Funded legacy proxy upgrades are unsupported. The installed implementation authorizer controls the first installation; the implementation must fail loud before state change if legacy storage reaches a new path. Fresh initialization establishes new invariants. A9-02 is not described as fully closed. |
| A9-21, A10-17, A11-10 gas | A9-21 whole-query gas and A10-17 whole-call gas fit remain unmeasured; A11-10 source bounds do not measure whole-proposal gas. The A10-17 32-source callback bound is not a whole-call gas guarantee. |
| Queued vote-eligibility work | Global voting reads fail closed while vote-eligibility work is queued; no queue-wide liveness redesign is claimed. |
| Final vesting-source verification | Allowlist reindex activation walks every registered vesting source and has no total-source bound. |
| Timelock deposits (accepted exception) | ETH and NFT receive/receiver paths stay open; deposits grant no protocol use. |
| Profit-index rounding (declared limit) | About one raw unit (0.000001 USD) may remain per recognition and per partial funding/write-down tick. It stays in funded reserve and is not transferred to another holder or cohort. |
| Compliance operation count | Blocklist blocking and Allowlist revocation remain unlimited in count as the accepted gap. |
| Double-partial-index bound | The double-partial-index calculation typed-refuses outside its demonstrated operating range; no operating cap was added. |
| First same-window Registry deployment | The first same-window Registry deployment seeds an empty return basis; cash must reconcile before a return. |
| A12-15 permission lapse | A lapsed wallet is frozen from gated interactions until approval is renewed, with no grace path. Plain FORAGE, RISKUSD and tier-share transfers and approvals remain ungated. |
| A12-05 / A10-01 | Vault redemption charges the full gross request against cap use; there is no mint offset or refund. |
| Queue order and same-lane FIFO | An oversized live standard entry may be skipped while later fitting entries proceed; the older entry retries next pass. Same-lane order has no per-entry fairness or eventual-fill guarantee. |
| A11-01 global proposal quota | Qualified identities share the explicit global proposal quota; a Succeeded-but-unqueued proposal has no expiry and remains counted. |
| Loss-rate cap basis | The loss-rate cap counts losses charged to depositor tiers and excludes reserve-absorbed loss. |
| NAV controls | Profit recognition is capped by fresh accepted NAV headroom after principal and unreturned recognized profit; negative recognition cannot exceed the unreturned amount above NAV-backed value. The upward postNAV ceiling base includes recognized profit retained in the trading account. |
| Recognized profit and loss timing | Attested loss is borne by holders at report time; exits that avoid a pending reported loss stay frozen until settlement. Recognized-but-unpaid profit remains a separate entitlement of recognition-time holders; withdrawal pricing uses cash-backed value. |
| Tier moves and the weekly exit budget | Tier moves remain outside the weekly holder-exit budget; destination capacity and lock rules still apply. |
| A13-02 bounded queue frontier | With maxEntries=1, the reviewed source trace is capped at 65 candidate units per call and assumes priority processing completes without an earlier standard STOP. This is not runtime or gas proof; priority completion remains required. |
| Self catch-up boundary | Any holder may catch up only their own closed profit epochs, at most eight per call; the route moves no value. Claims remain allowlist-gated, and the existing allowlisted keeper route remains available. |
| Held Treasury funds | Reconciled zero-principal USDC is held in a non-distributable Treasury balance; its later use remains unassigned pending a founder decision. |
| A13-19 monitoring | Events emitted in a reverting frame do not persist. Monitoring is the operational option; no monitoring configuration was supplied as proof. |
| A13-06 zero deployment-buffer setting | A zero buffer setting returns before Registry lookup and disables this check. With a nonzero value, lookup failures refuse and enumeration covers only the four OF-TARGET tier vaults. |
| A13-15 queue scan | Lapsed standard rows retain their ID and position until expiry; total queue size and whole-call gas remain unbounded or unmeasured. |
| A13-16 NAV recovery | Zero previous or interval-start NAV uses deployed principal as the cap basis. After settled total loss, recovery uses the last nonzero principal basis; unresolved-loss guards remain and no cap is removed. |
| Static analyzer and receipt evidence | No fresh Slither or Semgrep run is claimed. The public Semgrep preflight exits 1 on both base and candidate because the Allowlist ABI digest is stale; the audit-receipt checker is absent on both. Suppression validation passes only against the two identified retained private raw Slither scans. |
| Weekly exit reservations | Each cohort's approved amount is reserved once against the following collection week's saved cap. It can be collected only in that calendar week; a full-week freeze or pause lapses it, later settlement restores nothing, and unfilled shares return. The caller triggers settlement; claim order can matter if share value moves, and the strict cap wins over equal shares. The owner-set cap defaults to 500 basis points; higher configured values remain published behavior. |
| Queue catch-up | Up to 40 missed epochs are processed. More than 40 makes the deposit revert. |
| Small return-cap basis | A lifetime basis of 1-9 raw units rounds the 10% return cap to zero. |
| Timelock cleanup | Each cleanup handles one operation ID, not a batch. |
| Classification gas | The bounded policy check used static-call caps up to 1,515,000,000 gas; the concrete 199-candidate case used 3,014,850,000. Whole-scan gas is unmeasured. |
| Guardian rotation | The retained protection can leave a guardian unable to cancel a proposal that rotates another seat. |
| Guardian approval reuse | With no contract change, a guardian removed and later re-added can have an earlier approval counted again for the same pending rotation, but only until that rotation expires. |
| Queue admission and keeper work | There is no per-entry minimum or per-user limit. Repeated small entries can consume bounded keeper work and delay others; whole-call gas is unmeasured. |
| Weekly snapshot sentinel | The zero-basis sentinel is conservative by one raw unit after a full loss. |
| Line references in earlier pages | The dispositions pages for Analyses 9 to 13, the two pre-scan reviews and the 2026-10-09 post-scan update carry source-line ranges written for earlier commits. Ranges into the eight source files changed by this update were re-checked and 133 were corrected; a range that was not found stale can still be a few lines off. Pinned file identities are exact. The ranges on this page and on the Analysis 14 page were all checked. |

The earlier identity census remains byte-equal, with all 155 Analysis 1-8 UUID identities present. `1c1085499239962b543dae724f041414a2d4eecd` is the previous PR head and the Analysis 14 scan target. `78a465cba5a47bbb4f542a6f305f482ddc73b0e9`, `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`, `01f4abe7768f03d2a21e6ab0a0221795d315d79b`, and older commits are historical. Warning 28 retains its dated missing-capture gap. No Octane label, deployment state, security clearance, or finding closure is claimed.

See [Analysis 13 dispositions](2026-10-09-analysis-13-dispositions.md) for all 24 findings and seven related cases, their UUID availability, latest independent critique verdict, public source lines, source status, and Octane-suggestion decision.

The source references are re-pinned to the current public files below. This is a source-review update; it does not state an Octane result, finding closure, security clearance, or deployment status.

| Public source file | Git blob |
|---|---|
| `openforage_smart_contracts/src/Allowlist.sol` | `6ec03daf0336ba1f52ea4bf28e082feb114b9c6a` |
| `openforage_smart_contracts/src/AllowlistGatedUpgradeable.sol` | `5f23a84abe861a87da4309dabca99ea80f66f422` |
| `openforage_smart_contracts/src/Blocklist.sol` | `ebf9fe539917dd9841fb1eb298411c4f178bb057` |
| `openforage_smart_contracts/src/CustodianRegistry.sol` | `46847287613d4cfd17c5104771872fe151ed7afe` |
| `openforage_smart_contracts/src/DelegatingVestingWallet.sol` | `6e0e513fa7c29097dff976dc1279ba43ff6c0c9e` |
| `openforage_smart_contracts/src/FORAGETreasury.sol` | `320a60d5183e8f21912f0f0ff832a5d7f593a254` |
| `openforage_smart_contracts/src/FinalizeDelayProfile.sol` | `d8c28d9b3a42e4dfb0d82496ae21bdf2ac5832c3` |
| `openforage_smart_contracts/src/ForageGovernor.sol` | `1e3d94a7f1da164e3f4e142e554d6a3a0a1e5a64` |
| `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol` | `09a5502c00137028c6ecf5083758eb64fb2c56d1` |
| `openforage_smart_contracts/src/ForageToken.sol` | `2fd8d00e6c58775e2b0c2662796cbfe5b1c7f122` |
| `openforage_smart_contracts/src/GuardianEmergencyPrincipalLane.sol` | `743fc89e8f4486860a572269b2b56be8771bc43a` |
| `openforage_smart_contracts/src/GuardianModule.sol` | `8c1be68aaf5eb2a92949a705f33bf7a12e687711` |
| `openforage_smart_contracts/src/IForageGovernorPause.sol` | `a0e929ca5fdda6c5f8be4c280d59cf43ba237899` |
| `openforage_smart_contracts/src/RISKUSD.sol` | `8b2d2eeefe3419d9e96b2eb52f90387cdefb78c4` |
| `openforage_smart_contracts/src/RISKUSDVault.sol` | `7244cdb90fe10dfd102c01c5c1b81215660fa7e6` |
| `openforage_smart_contracts/src/StakingQueue.sol` | `a9268e056a2b1e1a2bfb0cab65552f6d52360bc3` |
| `openforage_smart_contracts/src/USDCTreasury.sol` | `25cb223f201be6892be3ae99501a275a6de37a76` |
| `openforage_smart_contracts/src/VaultRegistry.sol` | `44cbd0a1ad09450f897d00df7f25ca9bedf5f3b6` |
| `openforage_smart_contracts/src/atRISKUSD.sol` | `b4dca3012cadcde35cc1ec04e812890a4e366445` |
| `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol` | `dc14acccca669f4e0d7903eef479a8b708519d7b` |
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
| `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol` | `29dc39cc98fde234b996ad9bea4b68480b51ea4b` |
| `openforage_smart_contracts/src/modules/AtRiskUSDWeeklyExitModule.sol` | `a19345a466362619ed61dfaef6ae3891d6a5afb9` |
| `openforage_smart_contracts/src/modules/CustodianRegistryCapitalModule.sol` | `1bdef18bd31102f7fc7d8b2e052d94c109fcd4ab` |
| `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol` | `59021b0d9eea55803b88dfa192283c05aa12cbd6` |
| `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol` | `03fbf04fb1f886ea2a490f1656475b78e6aed7bf` |
| `openforage_smart_contracts/src/modules/StakingQueueModule.sol` | `7abd9e4f51813bc73d6497e4f15b6afdb6c44712` |
| `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol` | `a35a15c93ce055f48827b3caf07f1564e73b9074` |
| `openforage_smart_contracts/src/modules/USDCTreasuryProfitPolicyModule.sol` | `ba78a8eded831314e9c8ede679d5514ec58873ad` |
