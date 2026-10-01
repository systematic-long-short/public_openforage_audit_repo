# Analysis 11: source dispositions and proof limits

This record covers 9 vulnerabilities, 2 warnings, and 3 related cases. One case sits under A11-02; two under A11-07. Source review is not Octane closure or deployment proof.

Base of this update: `6efd4cd86a9b2fec7f484c0da073f71385900308`. Source lines refer to this candidate.

## Finding dispositions

`ACCEPT_BOUNDED` accepts only the source behavior and limits named in its row. It does not resolve an Octane finding or change its label.

| Finding and UUID | Public source lines | Latest review and source disposition |
|---|---|---|
| A11-01 Medium `a7af1595-ccda-406e-ae1c-b71b1ba14c0d` | `openforage_smart_contracts/src/ForageGovernor.sol:238-307,328-395,918-970` | **ACCEPT_BOUNDED.** The reviewed candidate removes eligible ordinary proposals below the voting threshold before counting slots. Guardian proposals remain separate. The review does not establish a live proposal state. A succeeded proposal that is not queued has no source-enforced expiry and can keep its slot. Reject a per-wallet quota based on a changeable wallet reference. |
| A11-02 Medium `a1128474-2005-43d8-8ffc-2de9ce722ed0` | `openforage_smart_contracts/src/RISKUSDVault.sol:408-438,446-461,1319-1362` | **ACCEPT_BOUNDED.** A successful first redemption anchors both cap bases to current supply; a reverted dust attempt stores no anchor. This applies only to fresh version-two state. Reject a fallback that counts current-window mints in the basis. No runtime or deployed-state proof exists. |
| A11-03 Medium `a5bd8652-d2e0-4fce-aa6d-92f676bfb199` | `openforage_smart_contracts/src/ForageToken.sol:396-414,437-445,767-780`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:578-634` | **ACCEPT_BOUNDED.** Compliance changes queue vote-synchronization work one source at a time. Vote reads and later-timepoint actions refuse while work remains. Reject a bare catch that could leave voting power stale. Whole-call gas remains unmeasured. |
| A11-04 Low `92464e14-f90f-41ee-bdd0-57783b40383e` | `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:432-466,480-496,560-576,1087-1109,1209-1221`; `openforage_smart_contracts/src/FORAGETreasury.sol:95-98,268-289,433-459` | **ACCEPT_BOUNDED.** Reindex checks the candidate's own vesting-source registration and verifies the updated provider. It does not copy a beneficiary's approval. Activation still fails closed. No live reindex state was read. |
| A11-05 Low `eb4f1fa1-3a4e-485d-9928-5c2e16f391c4` | `openforage_smart_contracts/src/CustodianRegistry.sol:681-706`; `openforage_smart_contracts/src/libraries/GuardianAuthorityClassifier.sol:117-143`; `openforage_smart_contracts/src/GuardianModule.sol:228-240,903-970,977-1027`; `openforage_smart_contracts/src/ForageGovernor.sol:962-970` | **ACCEPT_BOUNDED for the selector-only classification.** The Registry's retired `proposeGuardianModule` and `finalizeGuardianModule` selectors revert. The classifier's Registry set protects `proposeForageGovernor`, `finalizeForageGovernor`, `upgradeToAndCall`, and `setAllowlist`; it excludes those retired selectors. The Registry's Timelock ownership pin at `CustodianRegistry.sol:276-288,1254-1274` is an additional defense, not the A11-05 fix. The classifier still treats two effectless proposal shapes as protected: an already-expired Governor rotation and a Timelock CANCELLER grant or revoke that changes nothing. The Guardian cannot cancel either shape. A succeeded, unqueued proposal can hold its proposer's slot because the source sets no expiry. This is a known limit, not a fix. |
| A11-06 Low `a975b9ef-0da0-45db-b329-ed7e062ef0c8` | `openforage_smart_contracts/src/ForageToken.sol:663-695`; `openforage_smart_contracts/src/FORAGETreasury.sol:212-232`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:1112-1176` | **ACCEPT_BOUNDED.** Transfers still synchronize both endpoints so the indexed voting view follows token checkpoints. Reject skipping this work; it can leave votes stale. The full claim path's gas cost is unmeasured. |
| A11-07 Low `731a1a4e-4d2b-4916-a4fd-80ad1e252b57` | `openforage_smart_contracts/src/RISKUSDVault.sol:421-432,1319-1342`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:897-917,928-937,1123-1153` | **ACCEPT_BOUNDED.** Fresh version-two state records post-anchor mints and consumes each offset once. Loss reduces the basis only by the amount not covered by the offset. Reject a second all-mint counter. No legacy-proxy or runtime proof exists. |
| A11-08 Low `2096e504-2141-462f-a2eb-e946e3cd13c0` | `openforage_smart_contracts/src/CustodianRegistry.sol:516-525,883-895`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:355-411,1113-1117` | **ACCEPT_BOUNDED.** One basis-aware return route skips only a duplicate NAV-reference reduction. A paused return also emits the ordinary return event; outside consumers are unknown. Adopt one existing selector, not another. No external-consumer or deployed-state proof exists. |
| A11-09 Informational `6d7f858a-c0a7-4ced-94a7-7853642eb15e` | `openforage_smart_contracts/src/CustodianRegistry.sol:527-542,614-679,936-939`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:424-448` | **ACCEPT_BOUNDED.** An amount-only loss marks that custodian's relation unbound. Relation and NAV routes then refuse. Reject a clearing shortcut; empty identity fields cannot restore missing history. No funds-loss or deployed-state conclusion follows. |
| A11-10 Medium warning `f6982688-1669-4adf-a120-18957f97ddf7` | `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol:4-8,345-398,490-499,502-625` | **ACCEPT_BOUNDED; warning remains open.** One shared limit covers root and future Timelock scans: 100 actions, 65,536 bytes, 100 nested visits, and depth 16. Reject a role-only check that would miss encoded operations. No EVM, gas, or deployment proof exists. |
| A11-11 Low warning `cb440e18-6837-4f96-ad57-35a11a9eb734` | `openforage_smart_contracts/src/USDCTreasury.sol:335-358,575-588,662-689,796-825`; `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol:84-105` | **ACCEPT_BOUNDED.** After the claim clamp, the source moves only the canceled excess to the existing agent-payment earmark. It moves no cash and changes no payout rate or claim order. No payout or deployment behavior was exercised. |

## Related cases

These cases have no separate UUID. Each remains under its named Analysis 11 finding.

| Related case | Public source lines | Latest review and source disposition |
|---|---|---|
| A11-02-related-1, Medium: bootstrap mint/basis mismatch can enlarge redemption caps and crowd out holders | `openforage_smart_contracts/src/RISKUSDVault.sol:1319-1362`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:897-917,1123-1153` | **ACCEPT_BOUNDED for fresh version-two state.** Pre-anchor deposits remain in the basis; later mints offset once. Reject a first-mint-only condition. No runtime proof. |
| A11-07-related-1, Low: loss offsets and weekly rollover can leave a temporarily inflated cap | `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:928-933`; `openforage_smart_contracts/src/RISKUSDVault.sol:1406-1417` | **ACCEPT_BOUNDED.** Clamp the post-burn basis to surviving supply. No runtime or gas proof. |
| A11-07-related-2, Low: mint-buffer exclusion and strict seeding can pause public redemptions after a full-supply burn | `openforage_smart_contracts/src/RISKUSDVault.sol:1417-1430`; `openforage_smart_contracts/src/modules/RISKUSDVaultModule.sol:1155-1168` | **ACCEPT_BOUNDED.** A true zero-supply reset clears redemption state and restores its sentinel, not public mint use. Reject an unconditional current-supply fallback. No legacy-proxy proof. |

## Build and evidence limits

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

The ABI and storage results remain separate evidence. No contract test, runtime or gas simulation, RPC, chain, deployment, legacy-proxy, or live-state proof is claimed.

The same three contracts already exceeded the Default runtime limit at the previous PR head. No other first-party contract became size-red. The current build shows the Governor and Treasury margins narrowed; the StakingQueue margin is unchanged.

Static results remain red or incomplete. The copied-source control for Registry selectors can accept a reintroduced retired selector, though current Solidity has no such branch. This is a checker gap, not a current source defect or a full static pass.

No Octane label changes here. All limits in this record are source-review bounds, not finding closure or security clearance.
