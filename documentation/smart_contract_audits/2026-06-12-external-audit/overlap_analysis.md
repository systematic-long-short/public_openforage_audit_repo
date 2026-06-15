# External Audit Overlap Analysis - 2026-06-12

## Method

This table maps co-reported root causes accepted during the June 12 external-audit triage. In this refreshed public snapshot, the accepted true positives are remediated in code and bound to fixed-behavior Foundry tests under `openforage_smart_contracts/test/audit/external_2026_06_12/ExternalAudit20260612Repros.t.sol`. The per-report triage ledgers in this directory are retained as historical audit input, not as current unremediated-status claims.

| Root cause | Cantina IDs | Octane IDs | Current disposition | Current evidence |
|---|---|---|---|---|
| Partnership blocklist vesting wallet authority | OPEN-73, OPEN-80, OPEN-84, OPEN-91, OPEN-94 | V-15 | Remediated in current snapshot | `FORAGETreasury` wires the wallet blocklist before burning child-wallet setter authority. Fixed-behavior proof: `test_partnershipWalletInheritsBlocklistAndBlocksReleaseAfterBeneficiaryBlocked`. |
| Blocked holder delegated voting persistence | OPEN-89, OPEN-98 | V-2, R-V-2-1 | Remediated in current snapshot | `ForageToken` discounts blocked-holder delegated voting power at the live vote source while preserving historical checkpoints. Fixed-behavior proof: `test_blockedHolderDelegatedVotesAreDiscountedAtLiveVoteSource`, `test_pastVotesUseHistoricalSourceCheckpointsWhileLiveVotesDiscountBlockedHolders`, and `test_ownerCanBackfillPreUpgradeDelegateSourcesWithoutMovingBlocklistSlot`. |
| Loss settlement wiring | OPEN-75, OPEN-79 | V-4 | Remediated in current snapshot | `USDCTreasury` exposes the settlement selectors needed by the configured loss-reporter wiring. Fixed-behavior proof: `test_lossReporterWiringExposesSettlementSelectors`. |
| Guardian module static binding | OPEN-90 | V-48 | Remediated in current snapshot | `HLTradingBridge` follows the live registry/governance authority source instead of relying on a stale cached guardian module. Fixed-behavior proof: `test_bridgeGuardianAuthorityFollowsLiveRegistrySourceOfTruth`. |
| HyperLiquid cached or revoked executor authority | OPEN-74, OPEN-101, OPEN-102 | No Octane TP in this triage set | Remediated in current snapshot | The bridge value-moving path no longer accepts a registry-revoked executor. Fixed-behavior proof: `test_revokedRegistryExecutorCannotControlBridgeValueMovingPath`. |

The remaining warning-level bounded-enumeration guidance is preserved in the triage ledgers. The current fixed-behavior suite also covers deterministic accelerated-rotation ID reuse, deployment pause wiring, NAV normalization fail-closed behavior, queue/deadline bounds, retry-lock accounting, and paged vault-registry enumeration.
