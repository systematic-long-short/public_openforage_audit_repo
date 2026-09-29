# Analysis 9: source dispositions and proof limits

This record maps all 21 captured findings and 11 related cases to the public source. It does not change an Octane label, approve deployment, or claim security clearance.

## Candidate identity and finding status

This candidate continues PR #9 from public head `fbcdda4fc95adc6d345786787ce4ea7557df86a4`. Its direct map remains 59 files: 33 Solidity source/interface/module files, 18 ABI files, and 8 selected deployment-script/interface files. It includes the three source paths previously added to PR #9, including `USDCTreasuryAccountingModule.sol`. C9 changes the already-mapped `RISKUSDVault.sol`; no mapped ABI or selected script changed, and no new first-party source/interface/module/ABI path was added. Two root dependency pins and nine recursive pins remain unchanged. Private audit records, build state, run records, and non-allowlisted tooling are excluded.

The retained Analysis 9 export records 15 vulnerabilities, 6 warnings, and 11 related cases. All 21 findings were acknowledged as `Other`; none was marked resolved. An acknowledgement can hide later automation output. It does not prove a fix. This record changes no Octane status.

The separate historical record retains all 155 exact analysis 1–8 identities. Warning 28 remains listed. Its original capture bytes from 2026-09-24 are unavailable; no description was reconstructed.

## Primary findings

| Finding and UUID | Exact public source | Current source disposition, independent review, and suggestion decision |
|---|---|---|
| A9-01, Critical — `eb60011b-9072-4a87-a304-e56e8416144b` | `openforage_smart_contracts/src/VaultRegistry.sol:189-237,240-328,337-440,550-644,682-709,954-968` | **Latest review: ACCEPT_BOUNDED.** Fresh registration seeds the tier cache and aggregates. Legacy state refuses before mutation. Reject migration and lazy scanning. No funded legacy proxy state was observed. |
| A9-02, Critical — `f7454b39-bd84-49f6-a3d7-e64382e0bb60` | `openforage_smart_contracts/src/USDCTreasury.sol:230-248,250-284,335-358,412-504,542-568,975-979` | **Latest review: ACCEPT_BOUNDED for helper readiness; REJECT as full closure.** Fresh initialization sets the helper, and helper-reaching entrypoints typed-refuse when it is missing. Reject legacy backfill under the fresh-only policy. No legacy-proxy, deployment, or current Octane proof exists; the first upgrade remains governed by the installed implementation's authorizer. |
| A9-03, High — `7b07338f-1c67-4d18-8a5a-91f967e50fd9` | `openforage_smart_contracts/src/RISKUSDVault.sol:452-486,1235-1248,1300-1359,1428-1500` | **Latest review: ACCEPT_BOUNDED.** Daily and weekly bases move by the actual cap charge. Temporary aggregate-cap contention remains possible; no fairness or in-window capacity guarantee is claimed. Reject disabling redemption/mint accounting. |
| A9-04, High — `fb3acbef-baa9-467b-b4d1-6d090e11ab30` | `openforage_smart_contracts/src/atRISKUSD.sol:234-291`; `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:177-215,999-1094` | **Latest review: ACCEPT_BOUNDED.** Fresh initialization establishes indexed expiry state. Host and module check the same marker before writes. Reject legacy heap migration and state translation. No old proxy state was inspected. |
| A9-05, High — `2ee12460-a955-4d2f-9ebe-9ae754d6a324` | `openforage_smart_contracts/src/StakingQueue.sol:328-397,624-638`; `openforage_smart_contracts/src/modules/StakingQueueModule.sol:312-316,709-735` | **Latest review: ACCEPT_BOUNDED.** Fresh Queue initialization establishes accounting readiness. Existing state without fresh progress refuses rather than being translated. Reject legacy backfill. No legacy Queue state was observed. |
| A9-06, High — `69b3891b-513c-4e4b-888d-70c5fadbba39` | `openforage_smart_contracts/src/USDCTreasury.sol:335-358,696-734,800-822,868-907`; `openforage_smart_contracts/src/modules/USDCTreasuryAccountingModule.sol:51-187`; `openforage_smart_contracts/src/modules/AtRiskUSDProfitModule.sol:104-203`; `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:656-761,1145-1176`; `openforage_smart_contracts/src/atRISKUSD.sol:898-902` | **Latest review: ACCEPT_BOUNDED, not closed.** Recognition-time entitlements include pending cooldown shares; attested-loss write-down occurs once per nonce; share value uses funded cash. Reject blanket claim cancellation and deposit pauses. Cross-tier fairness, collectibility, and deployed behavior remain open. |
| A9-07, Medium — `1383af99-f4bf-4f17-b38d-1738da7930d8` | `openforage_smart_contracts/src/GuardianModule.sol:213-229,643-684,964-1018`; `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol:4-490` | **Latest review: ACCEPT_BOUNDED for the source-bounded parser behavior.** Admission and cancellation use the same bounded decoding rules. The separate scanner-coverage issue remains under private repair; no clean or exact-bound scan is claimed. Reject a narrower encoding than the admitted path accepts. |
| A9-08, Medium — `745f1960-d9cc-4b4d-a7da-34663e3ee1e9` | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:385-416,790-934` | **Latest review: ACCEPT_BOUNDED.** The priority scan is bounded and resumable. Standard work stays closed while the scan is incomplete. Reject blind head advancement and cross-lane fallback. No universal progress or gas claim is made. |
| A9-09, Medium — `24e9cdce-4922-4a23-aaf2-4c9822e7e644` | `openforage_smart_contracts/src/atRISKUSD.sol:340-360,898-902`; `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:297-349,800-825,874-876` | **Latest review: ACCEPT_BOUNDED for cash-backed pricing only.** Cooldown execution caps a whole-share slice at funded cash and retains the request if a slice cannot execute. No runtime or deployed-state proof exists; the finding is not closed. Reject pricing against unpaid claims. |
| A9-10, Medium — `48122dd5-ab35-45df-9d9e-d440f520b736` | `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:1113-1159`; `openforage_smart_contracts/src/USDCTreasury.sol:542-568,853-907`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:315-349,453-474,1180-1184` | **Latest review: ACCEPT_BOUNDED, not closed.** Transfers freeze after a reported loss. Settlement uses the report-time tier basis, a configured keeper, and retained cover. Keep the report-time cohort and keeper boundary; reject an off-chain freeze-first policy under DEC-14. No old-proxy or deployment proof exists. |
| A9-11, Low — `4b0e6e03-ba41-4230-8daa-c1692feae3bb` | `openforage_smart_contracts/src/atRISKUSD.sol:281-285,340-360,432-457`; `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:391-431,724-761,1113-1159` | **Latest review: ACCEPT_BOUNDED.** After the loss freeze clears, an existing holder can execute or cancel its own request. The loss freeze remains. Reject removing it. No live request or freeze was observed. |
| A9-12, Low — `aac441dc-e62a-4ea1-8d48-92186b4933a6` | `openforage_smart_contracts/src/StakingQueue.sol:501-523,1004-1009`; `openforage_smart_contracts/src/modules/StakingQueueModule.sol:613-626,709-735` | **Latest review: ACCEPT_BOUNDED.** Unknown admission tags refuse. Retry uses recorded lock state instead of guessing a historical mode. Reject historical mode inference. No old Queue entry was read. |
| A9-13, Low — `2d4144db-812b-46e0-b38e-ae886c9d7974` | `openforage_smart_contracts/src/GuardianModule.sol:373-452` | **Latest review: ACCEPT_BOUNDED for the source-bounded generation guard.** Keep generation advancement and reject a colliding ID before a new write. No live rotation state was read; the outstanding scanner-coverage issue is separate. |
| A9-14, Informational — `4fe7068c-1288-4468-b4f6-bbff9262855e` | `openforage_smart_contracts/src/USDCTreasury.sol:542-568,921-934`; `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:453-474` | **Latest review: ACCEPT_BOUNDED.** Completion checks the requested nonce and zero remaining amount. Reject an aggregate `lossPending()` completion postcondition; no runtime result is claimed. |
| A9-15, Informational — `91264859-4be7-4e63-aa98-583870ad171e` | `openforage_smart_contracts/src/atRISKUSD.sol:461-465`; `openforage_smart_contracts/src/modules/AtRiskUSDStateModule.sol:763-770` | **Latest review: ACCEPT_BOUNDED.** The host forwards once. The delegate module burns and emits once; reject a duplicate wrapper emission. No runtime event trace was recorded. |
| A9-16, Medium warning — `092b5691-647b-400b-b4dc-486fcaf89b1b` | `openforage_smart_contracts/src/StakingQueue.sol:486-523,1004-1009`; `openforage_smart_contracts/src/modules/StakingQueueModule.sol:790-825,867-934` | **Latest review: ACCEPT_BOUNDED.** Revalidation does not force a new FORAGE lock. An unavailable quote reverts; a valid insufficient quote can demote the same ID. Reject top-up or demotion on unavailable data. No live oracle or lock was inspected. |
| A9-17, Low warning — `53bcb61d-78ff-4d34-bc44-e5a9a8827a66` | `openforage_smart_contracts/src/Allowlist.sol:110-170,172-206,247-260` | **Latest review: ACCEPT_BOUNDED for fresh eligible ownership.** An old Allowlist layout refuses. Reject upgrade-time self-bootstrap. The separate Blocklist fresh-only repair is **ACCEPT_BOUNDED by completed review 0645 at source level only**: typed refusal precedes effects, and its legacy importer/translation path is removed. No old-proxy or deployed-state proof exists; no legacy owner or Blocklist state was observed. |
| A9-18, Low warning — `571c2515-f2df-434d-a576-d79916bda60c` | `openforage_smart_contracts/src/ForageToken.sol:267-271,332-347,527-553`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:651-695`; `openforage_smart_contracts/script/Deploy.s.sol:672-696`; `openforage_smart_contracts/src/Blocklist.sol:59-85,87-174,188-213,241-263`; `openforage_smart_contracts/src/interfaces/IBlocklist.sol:4-18` | **Latest review: ACCEPT_BOUNDED for the reviewed fresh-source path.** Fresh Deploy completes bounded Blocklist rotation before vesting delegation. The completed 0645 review ACCEPT_BOUNDED the Blocklist fresh-only repair at source level only: its legacy importer/translation is removed and its state mutators are version-guarded. Token uses checkpoint-only history. No old-proxy or deployed-state proof exists. Reject suspension flags and legacy beneficiary fallback. |
| A9-19, Informational warning — `1f7f3ca1-0e8e-4bbb-b0c3-7187f1919224` | `openforage_smart_contracts/src/CustodianRegistry.sol:313-376,532-547,619-684,1026-1057` | **Latest review: ACCEPT_BOUNDED.** Keep identity-aware NAV/loss accounting: reduce the reference only for loss not already in NAV. Reject removing every loss-side reference adjustment. Amount-only loss remains unbound and later NAV refuses. No live caller or state was observed. |
| A9-20, Informational warning — `f7868eeb-8e57-47f3-9336-6b9a96d3bc92` | `openforage_smart_contracts/src/CustodianRegistry.sol:313-376,640-684,1197-1229`; `openforage_smart_contracts/script/Deploy.s.sol:761-763` | **Latest review: ACCEPT_BOUNDED.** A delayed owner-approved configuration supplies the initial reference; an NAV attester cannot seed it. Reject an unconstrained first report and legacy translation. This is not an oracle or deployment proof. |
| A9-21, Informational warning — `ac1c4d11-be07-4265-a862-251c4fc08b16` | `openforage_smart_contracts/src/ForageToken.sol:342-348`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:387-412,539-550,864-874` | **Latest review: ACCEPT_BOUNDED.** Fresh voting queries use an indexed projection. Whole-query gas, repeated Governor queries, and out-of-gas behavior remain unmeasured. Reject unsupported gas-fit claims. |

## Related case dispositions

The captured index assigns 11 related cases and no separate UUID to them. This table keeps those cases under their primary finding without inventing identities.

| Parent | Related case | Exact public source | Evidence-based disposition and suggestion decision |
|---|---|---|---|
| A9-03-related-1 | Redemption-mint netting in RISKUSDVault enables reversible cap saturation and weekly basis depression. | `openforage_smart_contracts/src/RISKUSDVault.sol:443-486,1263-1359,1428-1500` | **Latest review: ACCEPT_BOUNDED at source level.** Ordinary redemption no longer refunds active-window public mint use. A redeemed position can leave shared headroom occupied until the active daily/weekly window resets; this is temporary aggregate-cap contention, not a fairness guarantee or risk acceptance. Keep mint usage monotonic and the accepted net-charge basis accounting. Reject disabling public redemption netting as a substitute. |
| A9-06-related-1 | Live spot-weighted PnL recognition and unfunded claims may affect cross-tier distribution. | `openforage_smart_contracts/src/USDCTreasury.sol:696-734`; `openforage_smart_contracts/src/modules/AtRiskUSDProfitModule.sol:104-123,190-203` | **Latest review: ACCEPT_BOUNDED under recognition-time ownership.** Cross-tier weighting remains configured. Do not add a deposit pause or cancel claims. Fairness and collectibility remain open. |
| A9-07-related-1 | GuardianModule and GovernorTimelockGuard must decode proposal calldata consistently. | `openforage_smart_contracts/src/GuardianModule.sol:213-229,643-684,964-1018`; `openforage_smart_contracts/src/ForageGovernorTimelockGuard.sol:4-490` | **Latest review: ACCEPT_BOUNDED for source-bounded parser behavior.** The separate scanner-coverage issue remains under private repair. Reject a narrower grammar than proposal admission accepts. |
| A9-08-related-1 | Priority liveness must be checked before missing bounds can stop processing. | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:385-416,867-903` | **Latest review: ACCEPT_BOUNDED.** Valid priority without required bounds remains stopped. Do not invent bounds, demote, or refund a paid entry. |
| A9-08-related-2 | Lapsed or oversized standard entries must not permanently block later bounded scans. | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:827-856,867-903` | **Latest review: ACCEPT_BOUNDED.** The cursor resumes and revisits renewed entries. Reject auto-cancel, refund, and permanent skip flags. |
| A9-08-related-3 | A strict-minimum priority head must not be bypassed by standard work. | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:385-416,906-934` | **Latest review: ACCEPT_BOUNDED.** Standard work remains closed until priority scanning completes. Reject cross-lane fallback. |
| A9-10-related-1 | Public settlement must not front-run recovery or crystallize a stale loss. | `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:315-349,453-474`; `openforage_smart_contracts/src/USDCTreasury.sol:542-568` | **Latest review: ACCEPT_BOUNDED within the keeper boundary.** Keep keeper-gated progress and allow recovery before the first successful slice. Reject public settlement. Keeper availability is not guaranteed. |
| A9-10-related-2 | Partial settlement must make progress without charging reserve cover to the tier cap. | `openforage_smart_contracts/src/USDCTreasury.sol:868-907,909-935` | **Latest review: ACCEPT_BOUNDED for fresh state with sufficient cover.** Keep progress within the reviewed basis; reject charging reserve cover to the tier cap. Pre-existing partial settlements without the new basis remain unsupported. |
| A9-16-related-1 | A resumed priority scan must not miss an earlier prefix entry. | `openforage_smart_contracts/src/modules/StakingQueueModule.sol:385-416,790-825` | **Latest review: ACCEPT_BOUNDED.** The same ID and standard position remain; an incomplete scan blocks standard work. Reject blind cursor advancement. |
| A9-16-related-2 | Unavailable pricing must not demote or forfeit a paid priority entry. | `openforage_smart_contracts/src/StakingQueue.sol:496-518`; `openforage_smart_contracts/src/modules/StakingQueueModule.sol:867-903` | **Latest review: ACCEPT_BOUNDED.** Only a valid insufficient quote can demote the same ID. Reject demotion when pricing is unavailable. |
| A9-18-related-1 | Unregistered legacy vesting sources must not gain an unbounded beneficiary fallback. | `openforage_smart_contracts/src/ForageToken.sol:681-696`; `openforage_smart_contracts/src/modules/ForageTokenStateModule.sol:662-682,725-740`; `openforage_smart_contracts/src/Blocklist.sol:59-85,87-174,188-213,241-263`; `openforage_smart_contracts/src/interfaces/IBlocklist.sol:4-18` | **Latest review: ACCEPT_BOUNDED for the reviewed fresh-source path.** Completed review 0645 ACCEPT_BOUNDED the Blocklist fresh-only repair at source level only; its legacy import/translation is removed and mutators are guarded by the fresh layout version. Token reads checkpoint history only. No old-proxy or deployed-state proof exists. Reject an unregistered legacy beneficiary fallback. |

## Introduced static-triage rows

The prior source-triage table records 28 Queue rows and 44 Token rows: 28 Queue rows are justified; 43 Token rows are justified and one Token script row is fixed. Its row-level source dispositions and independent-review status are separate from the introduced analyzer-row review below; `SL-28` still needs a current `RISKUSDVault.sol` source rebind. A separate independent review agrees with all 187 introduced analyzer-row dispositions at their stated source-bounded scope: 61 Semgrep rows, 89 reused Slither rows, and 37 rederived Slither rows. One scanner-coverage issue remains under private repair, so the final Semgrep evidence is not accepted as exact-bound. Pre-existing analyzer rows remain separate and open; no full static pass is claimed.

Paths are relative to `openforage_smart_contracts/`.

| Row | Source location | Source disposition | Independent review |
|---|---|---|---|
| Q-01 `f1aea3bb37543775` | `src/StakingQueue.sol:250` | JUSTIFIED | pending |
| Q-02 `fb18be23c62cdf2a` | `src/StakingQueue.sol:251` | JUSTIFIED | pending |
| Q-03 `d63cf957302d68a7` | `src/StakingQueue.sol:287` | JUSTIFIED | pending |
| Q-04 `1725adaa6de3a9d3` | `src/StakingQueue.sol:505` | JUSTIFIED | pending |
| Q-05 `375ad5e14edba8d6` | `src/modules/StakingQueueModule.sol:243` | JUSTIFIED | pending |
| Q-06 `6e65937f33447fe9` | `src/modules/StakingQueueModule.sol:244` | JUSTIFIED | pending |
| Q-07 `8acf0e8dc0d1446a` | `src/modules/StakingQueueModule.sol:246` | JUSTIFIED | pending |
| Q-08 `42340c2be90ee628` | `src/modules/StakingQueueModule.sol:247` | JUSTIFIED | pending |
| Q-09 `5789b617b7e275e4` | `src/modules/StakingQueueModule.sol:259` | JUSTIFIED | pending |
| Q-10 `44940e144736388c` | `src/modules/StakingQueueModule.sol:262` | JUSTIFIED | pending |
| Q-11 `c1fafba56cd829da` | `src/modules/StakingQueueModule.sol:271` | JUSTIFIED | pending |
| Q-12 `eb692d99de01bb08` | `src/modules/StakingQueueModule.sol:291` | JUSTIFIED | pending |
| Q-13 `fdac42354a62eb41` | `src/modules/StakingQueueModule.sol:294` | JUSTIFIED | pending |
| Q-14 `28190dc6e35e3329` | `src/modules/StakingQueueModule.sol:297` | JUSTIFIED | pending |
| Q-15 `8bfd055e7525ebb5` | `src/modules/StakingQueueModule.sol:385-416` | JUSTIFIED | pending |
| Q-16 `15f29b6a6def1eab` | `src/modules/StakingQueueModule.sol:385-416` | JUSTIFIED | pending |
| Q-17 `8e64f0073dddd7b4` | `src/modules/StakingQueueModule.sol:642` | JUSTIFIED | pending |
| Q-18 `47ad283431a0a126` | `src/modules/StakingQueueModule.sol:733` | JUSTIFIED | pending |
| Q-19 `ce4b8d4b79fc17ad` | `src/modules/StakingQueueModule.sol:906-934` | JUSTIFIED | pending |
| Q-20 `2d257e9ac3b9678c` | `src/modules/StakingQueueModule.sol:790-825` | JUSTIFIED | pending |
| Q-21 `bb1b9c1311ef6725` | `src/modules/StakingQueueModule.sol:799` | JUSTIFIED | pending |
| Q-22 `063e379b9909c0ae` | `src/modules/StakingQueueModule.sol:827-857` | JUSTIFIED | pending |
| Q-23 `d959b5edf9ab75f7` | `src/modules/StakingQueueModule.sol:828` | JUSTIFIED | pending |
| Q-24 `bf2cb029e967df2c` | `src/modules/StakingQueueModule.sol:831,845,854` | JUSTIFIED | pending |
| Q-25 `e8edf44ba050defd` | `src/modules/StakingQueueModule.sol:888` | JUSTIFIED | pending |
| Q-26 `5a07f65bc71ddea1` | `src/modules/StakingQueueModule.sol:867-904` | JUSTIFIED | pending |
| Q-27 `068d523a6660c8ae` | `src/modules/StakingQueueModule.sol:917` | JUSTIFIED | pending |
| Q-28 `dba8499ed9d0b9ab` | `src/modules/StakingQueueModule.sol:983` | JUSTIFIED | pending |
| SG-01 | `src/Allowlist.sol:193` | JUSTIFIED | pending |
| SG-02 | `src/ForageToken.sol:643-647` | JUSTIFIED | pending |
| SG-03 | `src/modules/ForageTokenStateModule.sol:272` | JUSTIFIED | pending |
| SG-04 | `src/modules/ForageTokenStateModule.sol:285` | JUSTIFIED | pending |
| SG-05 | `src/modules/ForageTokenStateModule.sol:299` | JUSTIFIED | pending |
| SG-06 | `src/modules/ForageTokenStateModule.sol:316` | JUSTIFIED | pending |
| SG-07 | `src/modules/ForageTokenStateModule.sol:340` | JUSTIFIED | pending |
| SG-08 | `src/modules/ForageTokenStateModule.sol:346` | JUSTIFIED | pending |
| SG-09 | `src/modules/ForageTokenStateModule.sol:352` | JUSTIFIED | pending |
| SG-10 | `src/modules/ForageTokenStateModule.sol:356` | JUSTIFIED | pending |
| SG-11 | `src/modules/ForageTokenStateModule.sol:360` | JUSTIFIED | pending |
| SG-12 | `src/modules/ForageTokenStateModule.sol:365` | JUSTIFIED | pending |
| SG-13 | `src/modules/ForageTokenStateModule.sol:550` | JUSTIFIED | pending |
| SG-14 | `src/modules/ForageTokenStateModule.sol:599` | JUSTIFIED | pending |
| SG-15 | `src/modules/ForageTokenStateModule.sol:613` | JUSTIFIED | pending |
| SG-16 | `src/modules/ForageTokenStateModule.sol:623` | JUSTIFIED | pending |
| SG-17 | `src/modules/ForageTokenStateModule.sol:642` | JUSTIFIED | pending |
| SL-18 | Excluded `script/ProposeAndVote.s.sol` | FIX | pending |
| SL-19 | `src/Allowlist.sol:110-125,465-527` | JUSTIFIED | pending |
| SL-20 | `src/ForageToken.sol:121,386-397` | JUSTIFIED | pending |
| SL-21 | `src/ForageToken.sol:122,426-448,477-505,523-525` | JUSTIFIED | pending |
| SL-22 | `src/ForageToken.sol:123,426-438,465-471,507-509,591-623` | JUSTIFIED | pending |
| SL-23 | `src/ForageToken.sol:124,426-438,591-623` | JUSTIFIED | pending |
| SL-24 | `src/ForageToken.sol:128,267-272,332-340,370-376,527-547,587-589,674-680` | JUSTIFIED | pending |
| SL-25 | `src/ForageToken.sol:135,682-741,827-833` | JUSTIFIED | pending |
| SL-26 | `src/ForageToken.sol:724` | JUSTIFIED | pending |
| SL-27 | `src/ForageToken.sol:725` | JUSTIFIED | pending |
| SL-28 | `src/RISKUSDVault.sol` | Prior triage: JUSTIFIED; current source rebind pending | pending |
| SL-29 | `src/VaultRegistry.sol:114,214-231` | JUSTIFIED | pending |
| SL-30 | `src/VaultRegistry.sol:178,214-231` | JUSTIFIED | pending |
| SL-31 | `src/modules/ForageTokenStateModule.sol:197,697-706,768-782,885-904` | JUSTIFIED | pending |
| SL-32 | `src/modules/ForageTokenStateModule.sol:198,365-372` | JUSTIFIED | pending |
| SL-33 | `src/modules/ForageTokenStateModule.sol:199,365-372` | JUSTIFIED | pending |
| SL-34 | `src/modules/ForageTokenStateModule.sol:401` | JUSTIFIED | pending |
| SL-35 | `src/modules/ForageTokenStateModule.sol:413-446,418` | JUSTIFIED | pending |
| SL-36 | `src/modules/ForageTokenStateModule.sol:550-597,594` | JUSTIFIED | pending |
| SL-37 | `src/modules/ForageTokenStateModule.sol:599-611,606` | JUSTIFIED | pending |
| SL-38 | `src/modules/ForageTokenStateModule.sol:613-621,619` | JUSTIFIED | pending |
| SL-39 | `src/modules/ForageTokenStateModule.sol:642-649,647` | JUSTIFIED | pending |
| SL-40 | `src/modules/ForageTokenStateModule.sol:742-766,751` | JUSTIFIED | pending |
| SL-41 | `src/modules/ForageTokenStateModule.sol:777` | JUSTIFIED | pending |
| SL-42 | `src/modules/ForageTokenStateModule.sol:835-847,843` | JUSTIFIED | pending |
| SL-43 | `src/modules/ForageTokenStateModule.sol:874-883,877` | JUSTIFIED | pending |
| SL-44 | `src/modules/ForageTokenStateModule.sol:874-883,882` | JUSTIFIED | pending |

## Policy represented in this review

| Topic | Public rule | Boundary |
|---|---|---|
| Deployment | Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. | This is not an in-place upgrade approval. The first upgrade remains governed by the installed implementation's authorizer. No legacy-proxy proof exists. |
| Blocklist | Fresh initialization sets its layout version; every state-changing entrypoint requires it before effects. The legacy interval importer and translation path are removed; Token history uses `wasBlockedAt`. | Completed review 0645 ACCEPT_BOUNDED this fresh-only repair at source level only. The pre-checkpoint mapping remains inert layout storage; no old-proxy or deployed-state proof is established. |
| Profit | Holders at recognition own the profit. Unpaid profit stays a separate claim until cash arrives. | The cash-backed share value excludes that separate claim. No runtime or collectibility guarantee is established. |
| Redemptions | Withdrawals use cash-backed share value and pay available cash only. They promise no payment date. | Review accepted the source pricing path; no deployed-state result exists. |
| Losses | A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid it stay frozen through settlement. | Review accepted bounded fresh-state settlement with a configured keeper and sufficient retained cover. It did not establish old-proxy applicability. |
| Keeper | Reconciliation uses the existing checked return route. | The configured keeper remains trusted to start the first settlement slice. |
| Fees and loss rate | Fractional fee remainders carry across payments. Reserve-covered loss does not use the depositor-tier loss-rate cap. | These accounting boundaries do not prove a clean static scan. |
| Guardian | One designated Guardian keeps one reserved proposal slot under ordinary voting and timelock controls. | The Guardian cannot veto a change to its own authority. No live governance state was inspected. |
| Queue | Demotion keeps the same queue ID and original standard-queue position. | Unavailable pricing reverts; valid insufficiency can demote. No refund or universal progress guarantee is implied. |
| Expiry | Only automatic return from an expired higher tier is exempt from the Tier 0 admission cap. | New admissions and manual reversions remain capped. |
| Vesting | External vesting recipients need renewable approval and remain registered. | Payment grants no system-account status or restricted-call permission. |
| Distributor | The distributor is the trusted payer, not the recipient. | A recipient gains no system-account status or restricted-call permission. |
| Windows | Two Windows CLI rows remain failed. | No Visual Studio license or toolchain was installed, purchased, or accepted. |

## Build and evidence limits

Forge 1.3.5 and Solc 0.8.24 compiled 130 inputs in both profiles with the first-party test tree excluded. Default code generation completed with zero compiler errors, but its child exited 1 on three EIP-170 runtime overages: ForageGovernor (27,458 bytes), StakingQueue (27,382 bytes), USDCTreasury (27,671 bytes). Default initcode has no overage; CustodianRegistry is 1 byte below EIP-170 and atRISKUSD initcode is 48,156 bytes, 996 bytes below EIP-3860. Deploy exited 0 with all 22 first-party runtime/initcode pairs fitting; USDCTreasury is 24,168 runtime bytes, 408 bytes below EIP-170. The full table is in [`review_commands.md`](../review_commands.md).

The public/private map contains 59 files: 33 source/interface/module files, 18 ABIs, and 8 selected script/interface files. Every mapped byte is checked against the exact source. Seventeen ABI files have source matches; `FoundationTreasury.json` remains source-less.

The retained storage result remains red at 14 OK and 7 divergences; no baseline changed. Full Slither, configured Semgrep, static-audit, and the full gate-table routes did not run on this candidate. The 187 introduced analyzer-row dispositions remain independently reviewed at their stated source-bounded scope; one scanner-coverage issue remains, and pre-existing analyzer rows remain separate. Two Windows CLI rows remain failed. A9-21 whole-query gas, old-proxy state, and deployed behavior remain unproved. No contract test, fuzz/formal campaign, EVM/Anvil/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. No finding is declared resolved.
