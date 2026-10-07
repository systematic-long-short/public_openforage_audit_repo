# Octane Analyses 1–8 — Historical Identity and Remediation Record

This document records a selective public source snapshot and the current limits of its evidence. It is not a security audit, a finding-clearance record, or an Octane analysis result.

## Public identity and status

The previous PR #9 head and base of this update is `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; its parent `01f4abe7768f03d2a21e6ab0a0221795d315d79b` and older commits are historical. `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and earlier commits are historical. The current source map contains 69 files: 40 source/interface/library/module files, 20 ABI files, 8 selected script/interface files, and 1 reviewed suppression policy. The private inventory has no first-party source/interface/library/module/ABI path outside the explicit map; `GuardianAuthorityClassifier.sol` and `IRISKUSDSettlement.sol` are included.

This file keeps all 155 exact `(analysis, UUID)` identities from analyses 1–8. The counts remain 55, 11, 9, 14, 9, 5, 28, and 24. The row codes and UUIDs are unchanged. Analyses 9, 10, and 11 have separate disposition documents; none is added to this historical identity table.

The retained Analysis 9 export records 21 findings: 15 vulnerabilities and 6 warnings. It records 21 acknowledgements as `Other`, with no finding marked resolved. Analysis 10 records 16 vulnerabilities and one warning. Analysis 11 records 9 vulnerabilities, 2 warnings, and 3 related cases. Acknowledgements and source reviews do not prove finding closure. A9-02's helper-readiness correction is bounded and not full closure; A10-17 remains open. A11-04 has a bounded candidate-first declassification and remembered-wallet handoff review; A11-05 is bounded only to classification of retired Registry selectors. The separate no-UUID rotation rule is not A11-05, and the CANCELLER preflight boundary belongs to A10-04. No legacy-proxy, deployment, or current Octane proof exists. See the separate Analysis 9, Analysis 10, and Analysis 11 disposition documents and the dated pre-scan review.

Warning 28 retains UUID `3c2ba48b-3798-4f57-beba-90dc904af4d8`. The later description capture is identified, but the original 2026-09-24 capture bytes are unavailable. No description has been reconstructed.

## Finding identity census

These rows preserve identity only. The source-family review below gives the candidate change, counterargument, and unresolved condition for each source group. It does not change any Octane UI label.

| Analysis row | Octane finding UUID |
|---|---|
| A1-01 | 59cc2c7b-c705-478a-9b5c-4c81852e2ca4 |
| A1-02 | 63266f24-cc5c-4b12-8ca8-f08c3fca8289 |
| A1-03 | 2b86e9e5-d2ce-43d5-9bf4-3504a86d3d0f |
| A1-04 | 14db57a9-5c7d-4e59-8864-318b1b60707c |
| A1-05 | 272097fd-7e4d-4ce2-bae0-2f667cd46ad2 |
| A1-06 | 0bd7344c-e2b7-4845-8e6c-c1fca5048e31 |
| A1-07 | ed458c2d-8edb-4022-bf72-c46b1017180d |
| A1-08 | 08ee489e-ff8f-4de2-b1be-8f22be63a0a0 |
| A1-09 | 8fa40f66-e776-4e73-a5af-396afa401a58 |
| A1-10 | 4926c2fb-653f-4484-b656-e31d21ec5959 |
| A1-11 | f85cecc8-adc2-4c5b-ad58-96c558b6799f |
| A1-12 | 5a1a97c8-9501-4b26-8307-f9ca909d51ef |
| A1-13 | 78601c46-9f93-4d9c-bbe3-4de7fb530e9f |
| A1-14 | 4bf23e00-5f7b-49e8-927f-e76e4aaa12cd |
| A1-15 | edc582f2-3353-4927-b0a0-8859e3018016 |
| A1-16 | 3bc10e85-6eca-44fd-8184-b6978a5e367c |
| A1-17 | fe46cf0d-d9e8-4a54-9cbd-d80e39c0fa30 |
| A1-18 | 884b1a5c-0abe-4a0a-b333-5ed2c602d828 |
| A1-19 | 1ae41a25-8a8a-4f0e-bb35-320a300fbcca |
| A1-20 | c0c4f3da-70c0-48f4-a858-4615cc569c24 |
| A1-21 | 07811fa9-e841-4818-8966-d9a22a92aa50 |
| A1-22 | 39fd53df-76ec-401d-8794-2e33593ffcb7 |
| A1-23 | 3b2796d1-d998-40d4-8552-aa01f6a27cf6 |
| A1-24 | e0fbc60c-0cae-4c94-8420-bb0465d68010 |
| A1-25 | 72ffe733-2e89-4e25-b0fb-645408d8af37 |
| A1-26 | 8b4b1385-a2eb-4e66-8ccf-702a1e8d3c77 |
| A1-27 | e822860c-fdb8-4f23-b0e6-6094068b629e |
| A1-28 | 72399f57-973a-4d2f-80f6-a23515794dbe |
| A1-29 | 4d28683f-94a0-46c0-909d-18cd46e81038 |
| A1-30 | 862bec22-7809-4ed1-b3df-61e73f0a5b78 |
| A1-31 | f1216b2a-cd15-40f5-a06f-3143d3322828 |
| A1-32 | 7816a4e7-5efd-44ad-be33-89ecfd839b4a |
| A1-33 | 6a412ee1-c146-4aeb-9912-b63f878ef51a |
| A1-34 | 8178c7b9-ec4e-47b6-8826-fd7270357d97 |
| A1-35 | 481d5a07-8cee-483b-b0be-4be12e174887 |
| A1-36 | 403ea954-193e-4c9c-82d9-405d653a35ab |
| A1-37 | d4c4fb38-5efe-40eb-af69-68113ac6777b |
| A1-38 | 41888dc6-5ea5-4d22-8eaa-8117d140c837 |
| A1-39 | 50436a08-5504-420b-8bd9-bafc80fdcacf |
| A1-40 | e2308b22-9b6e-44a0-9a73-74bab90b3c84 |
| A1-41 | 3fceb221-c568-4ff1-b940-25c36bfe254c |
| A1-42 | 85f83488-d5e0-4b3f-9291-836b08503406 |
| A1-43 | 6b05391a-bf92-4382-848a-c91583286ca1 |
| A1-44 | 9124f1f3-8101-47d2-b95e-8df1e41e5c8a |
| A1-45 | dcbe42db-ccd1-4615-af6d-8e1a71e493e9 |
| A1-46 | a3aef90e-4dca-4d21-bc78-beebb92ae39c |
| A1-47 | 241a7816-b435-4faf-b790-50e984173eab |
| A1-48 | d1871706-1ea1-465f-8257-735fb524b8f8 |
| A1-49 | 1e4e01bb-f15c-4f11-afb1-dcea0820d8e3 |
| A1-50 | 6845347b-cef8-4b5f-a217-e907ac9b5603 |
| A1-51 | b67fa6d9-f6de-4858-9595-1704837057f6 |
| A1-52 | 67ae9a98-bcf6-4f00-bfb8-c6dd09af38d4 |
| A1-53 | 1453ef39-1201-482a-a60b-4a4822bcb61d |
| A1-54 | 41e95c4e-b714-433b-9b2c-70fe1edffd94 |
| A1-55 | 66c8880e-c23b-42b2-b7f8-1001caab0c0f |
| A2-01 | 87ebbe5d-3b00-4f61-acde-e072110584bc |
| A2-02 | f11b7ee1-5ea1-4bf0-adee-bbdee807d60c |
| A2-03 | 1bb97d40-aa37-4666-9b0d-8e922bc30711 |
| A2-04 | f6d24ffd-62cf-401e-aac3-52b839dc0df2 |
| A2-05 | d68c7f01-43ef-46ce-bd79-21a4c9bf9960 |
| A2-06 | bf05bf7d-38b0-4499-82a2-1b1ea6279761 |
| A2-07 | 36500fc6-6782-4200-a827-b8f5f7166e3b |
| A2-08 | 209c8494-264b-44c1-900a-3a3a0c86c306 |
| A2-09 | e8d90f45-abb0-4405-b2bd-e7e3aab52824 |
| A2-10 | df9b3535-cc05-45b0-80a6-20d72d5c54c1 |
| A2-11 | 4b17baad-40b1-413a-b0c6-5068fbf5a4c1 |
| A3-01 | 5579e530-2b20-4fac-8220-4f239ad55e09 |
| A3-02 | 7ce8d440-c5a2-4588-bdcc-2b215b6576ee |
| A3-03 | 3dca29b3-4cb7-46a3-aa3b-e606e8a91e76 |
| A3-04 | 6c7b35f0-c0e2-4f44-ba84-bca66393629b |
| A3-05 | 3e6d8750-4268-4948-abcf-bad1661a7200 |
| A3-06 | db03ce74-23f8-42c4-af83-4ae97eee5f41 |
| A3-07 | e0530286-51fa-4ab1-871d-7b4a0bbaf82b |
| A3-08 | 9cafea15-2d5e-4928-83b5-d356e3ada613 |
| A3-09 | c89f1782-6e8c-4c0a-ac1f-6a288b3613cb |
| A4-01 | bc9efe1c-9d07-425b-ac3b-7e2fcb9e7b47 |
| A4-02 | 79d30a9d-1be3-4022-b196-5ea15fda3293 |
| A4-03 | 834bbefb-6a22-4522-8068-8a81cb12cfa1 |
| A4-04 | de8fce57-c3f9-42ce-acaf-1964134893bb |
| A4-05 | aa2229db-1851-4c38-9b7e-027a8d3d0b3d |
| A4-06 | 6ec652e1-07ae-4b75-aa75-1326e1aa5554 |
| A4-07 | 3a4c0aaa-405c-445b-8ade-b8c97c55e875 |
| A4-08 | 08f5cd1c-64f8-4aaa-9115-b642c5dfe79a |
| A4-09 | 124339b6-93fe-4a95-9eba-b09c41dcc0a1 |
| A4-10 | 1f5ba605-e28b-4322-af31-a753ae681624 |
| A4-11 | 55724a13-9720-482a-806e-d80364102ddd |
| A4-12 | e90aa1a0-8d04-474a-9739-abdcc7015a50 |
| A4-13 | afa3abf4-78b3-4f2c-83ab-e05ca5778d4b |
| A4-14 | 29f495e3-194c-4b1c-8ae3-50b924d8d78c |
| A5-01 | b44bc4fb-69fe-4c6b-b7d7-ad793c7e4c32 |
| A5-02 | bb5e2c7f-693e-4380-bb17-442096846f54 |
| A5-03 | 7bc1afc9-6c34-463d-aeae-468caaca24eb |
| A5-04 | 73b18c82-ebc0-4447-80e0-e59034bf47d4 |
| A5-05 | aa4eb13f-2f42-44ea-ba48-54dec90c0fe1 |
| A5-06 | c22912f3-715e-4c5c-a0c6-616ff61d115b |
| A5-07 | 019ffe74-1c4c-4f1e-912d-09842c8a5d8a |
| A5-08 | bbcfba09-90ee-4147-8de2-2dc02721a381 |
| A5-09 | 1dd0a716-919e-4688-9eb7-8e12c14344c0 |
| A6-01 | 89f28250-5d6e-4a23-8fa1-b7226b0fd993 |
| A6-02 | fa0c85d9-db11-440e-a7ca-b1108cfcfa29 |
| A6-03 | f0d64089-f9b3-45d5-9abe-dae5a402368b |
| A6-04 | 8b96400f-16e2-4d24-a9ce-2eebb2bcc3d9 |
| A6-05 | 5363e986-c6af-4c42-986f-96c6a80c675f |
| A7-01 | e64b69c8-2663-498f-982d-b5159380fb31 |
| A7-02 | 0195648c-b35e-47d2-863f-211fde988d65 |
| A7-03 | b108f799-a997-4f81-a38c-4cb33ce49b28 |
| A7-04 | 80f11132-d7fc-4235-a3a1-0946eead15a5 |
| A7-05 | 57c74278-2ec3-4399-8843-c861c3c50ae1 |
| A7-06 | bc4b7e20-a79e-4009-a635-11673d4d3510 |
| A7-07 | c4f7c8f3-bf24-4734-a8aa-dabaa8024e68 |
| A7-08 | e2c12c5e-35ef-42e4-9936-5c1a7cadc49c |
| A7-09 | 3e0411b7-ba0b-4e64-a7dc-4e9b6956d8ce |
| A7-10 | 1d4d02bf-66f0-4081-8152-c99e65019339 |
| A7-11 | d5797e0f-c245-4faa-b99b-e4e1f30565df |
| A7-12 | 203f1949-2db2-4c7f-bd7d-c91a197e1e3c |
| A7-13 | b7da9369-c7be-486f-9f65-179f87c43f27 |
| A7-14 | 69138faf-565f-43ed-ba31-ba5852161cf8 |
| A7-15 | c976985a-c5da-44ca-b865-cb0cf0db8b86 |
| A7-16 | 7ec269c7-f9e7-4ba7-aec8-6ab74a5c26e6 |
| A7-17 | 45812f22-2f98-4abf-93f6-f84439894804 |
| A7-18 | eae7e3cd-3883-4659-8161-6a6ccdfcaf2c |
| A7-19 | 5415b347-d1fc-4eb2-b3d6-f27bb334505b |
| A7-20 | 18bcd926-fda0-40ef-b8c3-c65ba9ccb5b9 |
| A7-21 | 2195c715-4fbf-452d-962c-2a711114dd69 |
| A7-22 | 4907bac5-ae69-49d1-b4c0-c0e922599c2e |
| A7-23 | 7ef22ba5-d19a-45a9-89c6-398092deef3c |
| A7-24 | 47d9e10d-2649-4223-8d29-fc04b8578baa |
| A7-25 | 26f0eceb-75db-4d40-bf2a-7a72e262703d |
| A7-26 | 94171772-1a39-44ba-91bd-cfc2188f93c4 |
| A7-27 | a8d476c9-3e5c-4396-ac61-59a1c334a408 |
| A7-28 | 3c2ba48b-3798-4f57-beba-90dc904af4d8 |
| A8-01 | 4a86495c-4c0e-46b9-97ed-793dff876167 |
| A8-02 | 7bb132ef-a11f-4190-9645-47c837c6916c |
| A8-03 | d4800b62-2591-42bb-a320-a279302afd5d |
| A8-04 | f0ad82ad-9872-4cab-9022-648489fa06c2 |
| A8-05 | f53038d7-80f0-4568-9953-b6d34aee8db5 |
| A8-06 | 51a33ea5-468a-4c48-8ed9-9ccdadd7f5fb |
| A8-07 | 82006f2b-3d58-49d7-9165-e572dff69a59 |
| A8-08 | 1f235ff2-953f-4b28-a1ee-2af2e4be0e87 |
| A8-09 | a1a1aaa1-1a1e-47a1-b8dc-9b272395f039 |
| A8-10 | 2c19bd5b-0bee-4a06-af90-70788dfe3853 |
| A8-11 | c06396b0-d3ea-4053-ac59-2bb05fa59ea6 |
| A8-12 | f3f436ed-e79b-4595-b26a-fe4993f4e246 |
| A8-13 | d5a7dbfe-a9be-495d-99f0-90fd8a290f12 |
| A8-14 | b74e2d7d-6f0c-40f7-bd67-8e60e0945540 |
| A8-15 | 2d937598-7670-4d3d-9113-7a90c68672cb |
| A8-16 | f37dc02d-8b1e-46ee-a1f7-15a0687c5893 |
| A8-17 | 0dc1a611-378a-4688-8bc3-cc858e8221ed |
| A8-18 | 0b9c165a-d573-4f90-bea5-7b535de9d202 |
| A8-19 | 633cf560-9684-4116-bcff-42e052e4f0c8 |
| A8-20 | 5748484f-f893-49b1-ac99-d3902a1fa924 |
| A8-21 | bb6cc9a2-52cb-48f3-a559-9a4afede6b44 |
| A8-22 | 38267a31-638d-41d6-b910-cd82548dd9c5 |
| A8-23 | f9676c73-cfa1-4cbf-b1e4-ca9ca78296ba |
| A8-24 | f5fcbf9c-c855-4727-adb8-0c16d438850a |

## Source review and residual conditions

The analyses 1–8 family notes below are historical source descriptions. The separate Analysis 9, Analysis 10, and Analysis 11 records describe current source dispositions and remaining proof limits.

The candidate changes below document the reviewed source paths. They do not show that a contract was deployed, that a legacy proxy is compatible, or that Octane marked a finding resolved. A source fix and an unresolved state or policy condition can coexist.

### Current policy boundary

The supported deployment model is fresh-only. Any state-changing path that would run the new implementation over pre-fresh storage must refuse before it changes state. No legacy migration engine is supported.

An attested custodian loss belongs to holders at report time. Exits that could avoid a reported loss stay frozen until settlement. Recognized profit that has not arrived as cash remains a separate claim for the holders at recognition. Withdrawals use cash-backed value only.

These rules do not prove that every current source path satisfies them. The first upgrade still uses the authorizer in the implementation already installed. The new implementation cannot prove or authorize that first upgrade. See the separate Analysis 9 and Analysis 10 disposition records for source and evidence limits.

### Analyses 1–6

| Finding rows | Candidate source change | Actual unresolved condition |
|---|---|---|
| A1-11, A1-27, A1-28 | `ForageGovernor.sol`, `ForageGovernorTimelockGuard.sol`, and `GuardianModule.sol` bound proposal actions, nested visits, calldata bytes, and depth before proposal storage and on later queue, execution, relay, and cancellation paths. A separate Guardian proposal slot remains reserved. | The bounded source walk is not gas evidence. No live Timelock roles, queued proposals, controlled proposer count, or current slot configuration were read. Guardian self-authority protection remains intentional. |
| A1-02, A1-05, A1-07, A1-21, A2-01, A2-03, A2-08, A4-02, A4-03 | `ForageToken.sol` and its state module filter voting sources and use bounded historical-source paths. `ForageGovernor.sol` retains its selected quorum denominator and disables signature voting. | Those source-family notes describe the historical analyses 1–8 candidate. The current source supports fresh inventory only and typed-refuses older layouts; no old proxy history was observed. Total-supply quorum effects are policy-dependent. The described A4-02 same-second sequence is incompatible with the reviewed pinned Governor state/casting order, but no finding label is changed. |
| A2-07, A2-11, A3-02, A4-11, A4-12 | `Allowlist.sol`, `Blocklist.sol`, and `ForageToken.sol` carry timepoint-aware eligibility and source tracking. | Historical Blocklist intervals and Token checkpoints on existing proxies are unknown. A setter or current source index does not prove migration of old source histories. |
| A1-40 | `GuardianModule.sol` includes generation-bound routine and accelerated rotation IDs. | No live Guardian roster or pending rotation state was inspected. |
| A1-48, A2-10 | `HLTradingBridge.sol` resolves guardian authority through current governance/Registry wiring rather than relying only on an initialization-time address. | No deployed pointer or guardian-rotation state was read. |
| A1-15 | `FORAGETreasury.sol` wires newly created partnership wallets to the Blocklist before funding and completing setup; the wallet retains its own caller and Blocklist checks. | Existing partnership-wallet addresses and any earlier retrofit state are unknown. External vesting approval does not change partnership-wallet controls. |
| A1-55 | `ForageToken.approve` retains zero-first allowance changes. | Single-call nonzero replacement remains an integration-compatibility constraint. No allowance-race mitigation was removed. |
| A1-52 | `RISKUSD.sol` keeps the sender-side pause rule. | An inbound transfer from a non-exempt sender may wait for unpause. The source review does not establish a deployed pause or a bypass. |
| A1-03, A1-54 | `atRISKUSD.sol` uses indexed expiry tracking and a bounded share-return recovery route when the configured yield source is unreachable. | Old heap/mapping state and deployed recovery eligibility are unknown. Recovery is not a general loss or pause bypass. |
| A1-08, A1-09, A1-12, A1-18, A2-02, A3-01, A3-07, A3-09, A4-01, A4-10, A6-02 | `StakingQueue.sol` and `StakingQueueModule.sol` use admission bounds, finite new-entry deadlines, same-ID processing, bounded scans, and terminal-entry advancement. | A live eligible processor may settle an entry before a cancel transaction lands. Valid live heads can preserve FIFO while waiting for capacity. No universal queue-progress or target-chain gas claim is made. |
| A1-42, A2-04, A2-09, A5-05 | The historical candidate retained queue IDs and bounds. The current fresh-only source rejects pre-fresh queue storage before writes and does not migrate legacy priority rows. | No old queue entry, locker balance, or migration state was read. The fresh-only refusal does not establish behavior for a deployed legacy queue. |
| A1-31, A1-49, A1-50, A3-05 | Queue Oracle pricing includes sequencer/feed checks, revalidation before priority use, same-ID demotion, and a pre-multiplication scale bound. | Oracle behavior is conditional on its provider and configuration. No gas simulation or arbitrary-provider guarantee is established. Same-ID demotion preserves order; it does not cancel or refund the entry. |
| A1-29, A1-32, A1-37, A1-39, A4-05, A4-06, A5-09 | Queue expiry handling distinguishes authorized automatic expiry processing from manual self-reversion. Tier 0 cap exemption is limited to the automatic expired-higher-tier path. Registry zero slots are handled by the candidate queue code. | A blocked depositor may have a FORAGE unlock deferred until eligibility returns. No deployed keeper authorization, lock state, or tier configuration is asserted. |
| A1-44 | `StakingQueue.compactQueue` remains an optional linear maintenance operation; ordinary processing has separate bounded scan logic. | No current lane length or measured gas limit establishes an OOG failure of normal processing. Compaction is not described as a bounded operation. |
| A1-01, A1-14, A1-25, A2-05, A3-03, A3-04, A3-08, A4-04, A4-09, A5-01, A5-02, A6-01 | `HLTradingBridge.sol`, `RISKUSDVault.sol`, and `RISKUSDVaultModule.sol` carry observation-time NAV, current-book return accounting, and nonce-bound loss settlement paths. | A loss that exists only off-chain cannot be read by the contracts before it is reported. No live NAV, Registry status, proxy history, nonce, or settlement balance was inspected. |
| A1-13, A2-06, A3-06, A5-06, A6-05 | The Bridge and Vault expose typed manual NAV normalization and the candidate carries timestamp and book-basis checks. | The current manual fallback and stale-book behavior remain conditional on the exact final public code and external provider. No deployed manual-rescue event or old proxy state is established. |
| A1-20, A1-34, A1-35, A1-41, A1-43, A4-13, A4-14, A5-03, A5-07 | `HLTradingBridge.sol` and `CustodianRegistry.sol` track intent credits, cancellation, late arrivals, reconciled return liquidity, and principal updates through typed accounting paths. Keeper reconciliation stays on the existing checked path. | Same-window cap shrink can delay operator actions. No arbitrary balance credit, transfer-identity proof, current cash balance, open intent, or legacy principal reconciliation is established. |
| A1-06, A1-10, A1-17, A1-19, A1-23, A1-46, A4-08, A5-04, A6-03 | `RISKUSDVault.sol` charges cap use against the actual burn and refreshes the active basis at rollover. Fixed time windows remain explicit. | Window caps are not a fairness guarantee or a rolling-window limit. The current candidate's default size remains red, and no deployed cap state was inspected. |
| A1-24, A1-33, A1-45, A1-47, A1-53, A4-07, A5-08 | `RISKUSDVaultModule.sol` and `VaultRegistry.sol` use an O(1) active funded-asset aggregate for required buffer checks; release logic defers tiers that retain shares or assets. | Fresh initialization seeds the Registry cache. Pre-fresh Registry layouts fail with a typed refusal before state changes. No legacy proxy or live cache was inspected. The optional full-list view remains unbounded. |
| A1-04, A1-16, A1-22, A1-26, A1-38 | `USDCTreasury.sol` tracks funded and recognized tier claims; `atRISKUSD.sol` prices shares from cash-backed assets and keeps unpaid claims separate. | A1-22's timing around profit recognition is not established. Zero-supply residual assets, zero-asset legacy supply, old claim maps, and existing proxy states remain conditional. The separate Analysis 9 record keeps cooldown-escrow attribution and gross-loss-cap gaps open. No forced burn or sweep is authorized. |
| A1-30 | `USDCTreasury.sol` has an earmark payout-window cap. | A shrinking balance can make later same-window disbursements fail. This is a trusted-operator liveness condition, not loss of funds. A fixed window-start basis is not adopted here. |
| A1-36, A1-51, A6-04 | Current source uses fresh-only guards and rejects pre-fresh state before mutation; no legacy migration is supported. | The historical layout checker remains red on five rows and lacks a compiler-identity baseline. No proxy slot history, live storage word, migration, or upgrade-safety proof is supplied. |

### Analyses 7–8

| Finding rows | Candidate source change or policy | Actual unresolved condition |
|---|---|---|
| A7-01, A7-14, A8-11 | Vault cap basis follows the actual redeemed burn and rollover supply. | The final default size result is red. No legacy cap words or live supply-window state are known. |
| A7-02, A7-15 | Queue admission rejects an impossible minimum before storage; valid same-lane FIFO remains. | A live reachable head can wait for capacity. This is not universal queue liveness. |
| A7-03 | Governor proposal checks bound nested Timelock actions before storage and execution. | External Timelock roles, queued operations, and deployed role configuration remain unknown. |
| A7-04, A7-06, A8-02, A8-18 | Withdrawal requests reserve the weekly cap at request time and retain caller checks on execute/cancel paths. | The reservation is not cash. Long pauses, loss settlement, available liquidity, and old request state can delay payment; no return date is promised. |
| A7-05 | The historical candidate used an indexed path and a bounded legacy fallback. The current fresh-only source does not enumerate unsupported legacy sources. | No pre-fresh source history is supported or migrated. Whole-query gas and deployed proxy state remain unmeasured. |
| A7-07 | The persistent ordinary-exit bypass is not present in the reviewed source; the recovery route is limited to its stated unreachable-source conditions. | The exact old proxy and override state are unknown. |
| A7-08, A7-19, A7-26, A8-05, A8-08 | Profit claims belong to holders at recognition. `USDCTreasury.sol` records per-tier claims; `atRISKUSD.sol` prices shares from cash-backed assets and pays separate claims only when funded. | Recognition-time policy is not a deployment proof. The Analysis 9 record keeps cooldown-escrow attribution and gross-loss-cap gaps open; old claim maps and proxy state remain unknown. |
| A7-09, A8-04 | Ordinary proposal slots are bounded and a separate designated Guardian proposal slot remains reserved under normal voting and timelock rules. | Multiple controlled proposers and live proposal/guardian state were not assessed as deployed state. Guardian self-authority changes remain subject to normal protections. |
| A7-10 | The Governor checks the exact proposer suffix against the caller. | This is source evidence only; the saved static route remains red. |
| A7-11 | Required deployment-buffer accounting uses the Registry's O(1) funded-asset aggregate. | Legacy Registry layouts fail loudly before use; fresh registration establishes the cache. The full-list view remains an optional unbounded interface. |
| A7-12, A8-09 | Pending-withdrawal reads fail closed when raw state is ambiguous or uses the older layout. | No deployed raw words, implementation history, or migration policy is supplied. |
| A7-13 | Transfers between non-blocklisted holders remain available under the selected holder-transfer policy. | Transfer permission does not create protocol eligibility or system-account status. The historical focused result is not current runtime proof. |
| A7-16, A8-15, A8-20 | Zero-asset recovery remains self-only and guarded; the code does not force-burn shares or sweep claims. | Old supply, funded assets, claims, escrow, and loss state are unknown. No residual-asset cleanup is authorized. |
| A7-17, A7-25 | Guardian rotation checks current eligibility and generation before completing an operation. | No deployed Guardian, Allowlist, or Timelock state is known. |
| A7-18, A7-20, A7-27, A8-07, A8-19, A8-24 | Bridge and Treasury paths bind returns, NAV basis, loss nonce, and principal accounting; A8-07 separates caller permission from stale-amount accounting. | No live nonce, principal, acknowledged-loss balance, or legacy proxy state is available. Current-cap and provider behavior remain open. |
| A8-03, A8-21 | Tier-charged loss consumes the tier budget; the candidate refuses positive claims for a zero-supply tier. | This is source and policy evidence only. No live reserve, loss-window, or tier-supply state is known. |
| A8-13 | Fresh Treasury initialization marks an empty claim map ready; readers fail loud when readiness is unavailable. | Existing Treasury claim maps and upgrade history are unknown. The supported deployment scope is fresh-only: pre-fresh storage fails before mutation, and no legacy migration is supported. |
| A7-21, A7-23, A8-12, A8-23 | Token history checks fail loud on missing history; the distributor path separates recipient payout from beneficiary and system status. | Pre-history behavior, old Blocklist intervals, legacy source lists, and existing proxy state remain unresolved. |
| A7-22 | Max views consult current withdrawal, capacity, and funded-cash limits. | A max view cannot reserve future cash or promise later eligibility. No same-block deployed view result was observed. |
| A7-24 | Guardian emergency cap handling is typed and shrink-only. | No deployed guardian role or emergency selector run was observed. |
| A7-28, A8-10, A8-22 | Oracle priority is revalidated; failed revalidation demotes the same queue ID to standard FIFO, and scale-up overflow is checked before multiplication. | A8-14 gas is separate. Warning 28's original capture bytes remain missing. The new source path has no runtime or public scan result. |
| A8-01 | A narrow split-minimum failure permits standard work only if the same failed priority ID remains the priority head and current limits permit it. | A valid priority head may still block standard processing. No universal progress or refund is promised. |
| A8-06 | New queue deadlines have a finite ceiling; processing uses the stored deadline. | Pre-fresh entries are unsupported and fail loudly; no historical deadline is reconstructed. |
| A8-16 | External vesting approval does not bypass Queue reversion caller, Blocklist, cooldown, or loss checks. | No deployed beneficiary, lock, or eligibility state is known. |
| A8-17 | Loss settlement retains caller, pause, and exact-nonce checks. | The current source freezes share transfers after report time and uses a fixed-basis partial-settlement path. Independent review accepts bounded fresh-state behavior but rejects full fresh-only coverage. No runtime or legacy-proxy result is claimed. |
| A8-14 | The source has bounded source-cardinality and per-helper transition work. The retained calculation reports 31,555,113 required and 29,061,962 spent against a dated 32,000,000 cap. | This is a conditional calculation, not measured execution or a complete transaction-envelope bound. The current cap, arbitrary providers, legacy funded proxies, and complete execution cost are unresolved. Keep `Other` and open. |

## Current public build and evidence limits

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



The current source map contains 69 files: 40 first-party sources/interfaces/libraries/modules, 20 ABI files, 8 selected script/interface files, and 1 reviewed suppression policy. All 69 mapped bytes, including the suppression policy, match the exact private source. Nineteen ABI files have compiler source definitions; `FoundationTreasury.json` remains source-less. The latest recorded source-matched storage comparison is red at 17 OK and 7 historical divergences; no baseline changed, and this update did not run a fresh public-tree storage check.

The public analyzer table records 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to the current candidate-file blob. The previous PR #9 head and base of this update is `d075a36bebafd17ceace9fe4b0fb21aed81fe1ae`; its parent `01f4abe7768f03d2a21e6ab0a0221795d315d79b` is historical. `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and older commits are historical. Forty have bounded source-only review; seven stale or unresolved identities remain pending. The earlier 72-row table stays separate with all independent reviews pending. No fresh full `audit-static` pass is established. The public suppression checker and policy pass against the retained raw scan; no fresh Slither scan is claimed. The Semgrep preflight remains red because the public source manifest is stale for the changed ABI input. The scanner-coverage gap remains open, and `SL-28` still needs a current-source rebind. Two Windows CLI rows remain failed, no Windows license or toolchain was installed or accepted, and no first-party contract test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. A9-21 whole-query gas, A10-17 whole-call gas fit, old-proxy state, and deployed behavior remain unproved.

## External reviewer next steps

Review the 155 exact identity pairs against their original Octane entries and the source-family disposition above. Keep every unresolved provider, old-proxy, migration, state, static, size, and gas condition visible. A missing or acknowledged result is not evidence that an issue was fixed. Do not use this document as deployment authority or as a claim of Octane clearance.
