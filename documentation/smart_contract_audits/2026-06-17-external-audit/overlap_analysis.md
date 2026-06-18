# External Audit Overlap Analysis — 2026-06-17

This file groups Cantina `OPEN-*` and Octane `OCTANE-*` items by current-code root cause. It is a triage map, not a second verdict source; verdicts live in the assessment files.

## Cluster: partnership-blocklist

Findings: OPEN-80, OPEN-84, OPEN-94, OPEN-91, OPEN-73.

Current-code anchor: openforage_smart_contracts/src/FORAGETreasury.sol:141 and openforage_smart_contracts/src/DelegatingVestingWallet.sol:82.

Decision: valid historical cluster, current source already wires partnership vesting wallets to the live blocklist and gates release/delegation. No false-positive-driven change.

## Cluster: loss-settlement

Findings: OPEN-79, OPEN-75, OCTANE-05, OCTANE-06.

Current-code anchor: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:141, openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:242, openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:599, and openforage_smart_contracts/src/RISKUSDVault.sol:453.

Decision: live true positives for zero bridge loss nonce and stale manual NAV baseline were fixed in phase 7. The stale zero-vault assertion in the external bridge-loss repro remains a P47 caveat because it conflicts with nonce-bound vault design.

## Cluster: guardian/executor revocation

Findings: OPEN-90, OPEN-101, OPEN-102, OPEN-74, OCTANE-10.

Current-code anchor: openforage_smart_contracts/src/GuardianModule.sol:298, openforage_smart_contracts/src/GuardianModule.sol:715, and openforage_smart_contracts/src/CustodianRegistry.sol:318.

Decision: valid historical cluster, current source carries guardian removal, protected-mutation detection, and delayed custodian role finalization.

## Cluster: accelerated rotation

Findings: OPEN-83, OPEN-69.

Current-code anchor: openforage_smart_contracts/src/GuardianModule.sol:336, openforage_smart_contracts/src/GuardianModule.sol:342, and openforage_smart_contracts/src/GuardianModule.sol:380.

Decision: valid historical cluster, current source constrains accelerated rotation to pre-committed successors and bounded ready time.

## Cluster: blocklist-vote re-inclusion

Findings: OPEN-98, OPEN-89, OCTANE-01, OCTANE-07, OCTANE-08, OCTANE-11.

Current-code anchor: openforage_smart_contracts/src/ForageToken.sol:531.

Decision: live true positive fixed through phase 9 by adding Blocklist snapshot history and using it for historical past-vote snapshots while keeping live vote filtering separate.

## Cluster: StakingQueue denial-of-service

Findings: OCTANE-02, OCTANE-03, OCTANE-04, OCTANE-09.

Current-code anchor: openforage_smart_contracts/src/StakingQueue.sol:388, openforage_smart_contracts/src/StakingQueue.sol:546, and openforage_smart_contracts/src/StakingQueue.sol:1519.

Decision: live true positive fixed in phase 7 by making impossible standard-lane depositor bounds skip deterministically instead of reverting the whole lane.

## Other Mapped Findings

OPEN-97: documentation provenance; public snapshot omits the provenance-bearing raw portal exports and broad internal memo.

OPEN-82: deployment/admin handoff; current anchor openforage_smart_contracts/src/RISKUSD.sol:129.

OPEN-81: FORAGE unlock lifecycle; current anchor openforage_smart_contracts/src/ForageToken.sol:321.
