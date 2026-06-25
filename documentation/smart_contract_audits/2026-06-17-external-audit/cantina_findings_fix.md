# Cantina Findings Fix Record — 2026-06-17

### OPEN-80
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/FORAGETreasury.sol:156 wires the partnership wallet blocklist.

### OPEN-84
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/DelegatingVestingWallet.sol:151 gates release through blocklist checks.

### OPEN-94
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/DelegatingVestingWallet.sol:167 gates delegation through the wallet blocklist.

### OPEN-79
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:141 appends the nonce storage slot after existing custom bridge state, and openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:242 creates a loss nonce for negative NAV.

### OPEN-91
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/FORAGETreasury.sol:152 rejects blocked partnership beneficiaries/delegates.

### OPEN-90
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/GuardianModule.sol:298 removes compromised guardians.

### OPEN-73
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/DelegatingVestingWallet.sol:279 centralizes blocklist checks.

### OPEN-83
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/GuardianModule.sol:342 requires accelerated rotation successors to be pre-committed.

### OPEN-97
Disposition: valid-documentation-scope
No-fix rationale: OPEN-97 is provenance/documentation scope; this public snapshot omits the raw portal exports and broad internal memo that carry the provenance detail, with no Solidity change.

### OPEN-101
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/CustodianRegistry.sol:318 finalizes custodian role updates only after delay.

### OPEN-75
Disposition: valid-live-fixed-in-phase7
Fix citation: openforage_smart_contracts/src/RISKUSDVault.sol:453 records nonce-bearing custodian NAV.

### OPEN-98
Disposition: valid-live-fixed-through-phase9
Fix citation: openforage_smart_contracts/src/Blocklist.sol:148 exposes snapshot-time blocklist history and openforage_smart_contracts/src/ForageToken.sol:531 uses it for historical past votes.

### OPEN-102
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/GuardianModule.sol:715 detects protected guardian mutation paths.

### OPEN-74
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/GuardianModule.sol:264 enforces guardian permission separation.

### OPEN-82
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/RISKUSD.sol:129 starts delayed minter handoff.

### OPEN-89
Disposition: valid-live-fixed-through-phase9
Fix citation: openforage_smart_contracts/src/ForageToken.sol:540 iterates historical delegate sources and openforage_smart_contracts/src/ForageToken.sol:547 subtracts only sources blocked at the queried snapshot.

### OPEN-69
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/GuardianModule.sol:380 executes accelerated rotation only when ready.

### OPEN-81
Disposition: valid-current-source-fixed
Fix citation: openforage_smart_contracts/src/ForageToken.sol:374 provides batch unlock for active locks.
