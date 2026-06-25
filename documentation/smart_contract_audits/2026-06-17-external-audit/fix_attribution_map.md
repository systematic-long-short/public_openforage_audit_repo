# Fix Attribution Map — 2026-06-17

No false-positive-driven change.

## Actual Phase-7 and Phase-9 Contract Diffs

- Snapshot-time blocklist history / delegate source iteration: OPEN-98, OPEN-89, OCTANE-01, OCTANE-07, OCTANE-08, OCTANE-11. Fix citations: openforage_smart_contracts/src/Blocklist.sol:148, openforage_smart_contracts/src/interfaces/IBlocklist.sol:6, and openforage_smart_contracts/src/ForageToken.sol:531.
- StakingQueue denial-of-service: OCTANE-02, OCTANE-03, OCTANE-04, OCTANE-09. Fix citation: openforage_smart_contracts/src/StakingQueue.sol:388, openforage_smart_contracts/src/StakingQueue.sol:546, openforage_smart_contracts/src/StakingQueue.sol:606, and openforage_smart_contracts/src/StakingQueue.sol:1519.
- Loss nonce binding: OPEN-79, OPEN-75, OCTANE-05. Fix citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:141 and openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:242.
- Manual nav stale-baseline rescue: OCTANE-06. Fix citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:599.

## Current-Source Fixed Before Phase 7

- Partnership blocklist: OPEN-80, OPEN-84, OPEN-94, OPEN-91, OPEN-73. Current citation: openforage_smart_contracts/src/FORAGETreasury.sol:156 and openforage_smart_contracts/src/DelegatingVestingWallet.sol:151.
- Guardian/executor revocation: OPEN-90, OPEN-101, OPEN-102, OPEN-74, OCTANE-10. Current citation: openforage_smart_contracts/src/GuardianModule.sol:298 and openforage_smart_contracts/src/CustodianRegistry.sol:318.
- Accelerated rotation: OPEN-83, OPEN-69. Current citation: openforage_smart_contracts/src/GuardianModule.sol:342.
- Deployment/admin handoff and FORAGE unlock lifecycle: OPEN-82, OPEN-81. Current citation: openforage_smart_contracts/src/RISKUSD.sol:129 and openforage_smart_contracts/src/ForageToken.sol:374.

## Documentation-Scope

- OPEN-97: documentation-scope provenance finding only. The public snapshot omits the provenance-bearing raw portal exports and broad internal memo; no Solidity change.
