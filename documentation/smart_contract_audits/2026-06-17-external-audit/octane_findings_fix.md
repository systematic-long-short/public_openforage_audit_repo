# Octane Findings Fix Record — 2026-06-17

### OCTANE-01
Disposition: valid-live-fixed-through-phase9
Fix citation: openforage_smart_contracts/src/Blocklist.sol:148 exposes snapshot-time blocklist history, openforage_smart_contracts/src/interfaces/IBlocklist.sol:6 names the predicate, and openforage_smart_contracts/src/ForageToken.sol:531 applies it to past-vote snapshots.

### OCTANE-02
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/StakingQueue.sol:388 keeps impossible depositor minimums out of priority, and openforage_smart_contracts/src/StakingQueue.sol:546 skips impossible depositor bounds during processing.

### OCTANE-03
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/StakingQueue.sol:1519 computes whether depositor minimum shares are currently reachable.

### OCTANE-04
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/StakingQueue.sol:461 keeps queue processing bounded while openforage_smart_contracts/src/StakingQueue.sol:546 prevents a toxic entry from reverting either lane.

### OCTANE-05
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:141 appends nonce storage after existing custom bridge state, openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:242 creates a loss nonce, and openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:246 posts it to the vault.

### OCTANE-06
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:599 handles nonce-bound manual NAV rescue after a stale keeper baseline.

### OCTANE-07
Disposition: valid-live-fixed-through-phase9
Fix citation: openforage_smart_contracts/src/ForageToken.sol:540 iterates historical delegate-source checkpoints and openforage_smart_contracts/src/ForageToken.sol:547 filters sources with snapshot-time Blocklist history.

### OCTANE-08
Disposition: valid-live-fixed-through-phase9
Fix citation: openforage_smart_contracts/src/ForageToken.sol:543 reads delegate-source votes at the requested timepoint and openforage_smart_contracts/src/Blocklist.sol:148 answers whether the source was blocked at that timepoint.

### OCTANE-09
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/StakingQueue.sol:388, openforage_smart_contracts/src/StakingQueue.sol:546, and openforage_smart_contracts/src/StakingQueue.sol:1519 cover the dead-entry/min-share DoS.

### OCTANE-10
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/GuardianModule.sol:298 and openforage_smart_contracts/src/CustodianRegistry.sol:318 cover revocation/finalization.

### OCTANE-11
Disposition: valid-live-fixed-through-phase9
Fix citation: openforage_smart_contracts/src/ForageToken.sol:549 caps tracked historical votes at checkpoint votes after snapshot-time blocked-source subtraction.
