# Per-Contract Review Matrix

| Contract file | Primary concerns reviewed | Result |
| --- | --- | --- |
| `Blocklist.sol` | expiry, finalize delay, fail-loud block checks | No open finding |
| `CustodianRegistry.sol` | custodian ids, caps, source/chain config | No open finding |
| `DelegatingVestingWallet.sol` | release schedule, delegatee, token binding | No open finding |
| `FORAGETreasury.sol` | distributions, vesting wallet calls, blocklist dependency | No open finding |
| `FinalizeDelayProfile.sol` | mainnet/testnet delay selection | No open finding |
| `ForageGovernor.sol` | proposal lifecycle, quorum, timelock-only setters | No open finding |
| `ForageToken.sol` | lock accounting, burn/unlock/delegation | No open finding |
| `GuardianModule.sol` | tighten-only emergency controls and role rotation | No open finding |
| `IForageGovernorPause.sol` | interface consistency | No open finding |
| `RISKUSD.sol` | minter/governor controls and transfer gates | No open finding |
| `RISKUSDVault.sol` | custody deployment, stale NAV/loss pending, storage layout, principal-return accounting | M-01 and R6-H-01 fixed |
| `StakingQueue.sol` | queue ordering, caps, tier accounting | No open finding |
| `USDCTreasury.sol` | PnL split, depositor claim idempotence, earmarks, principal bookkeeping boundary | M-02 and R6-H-01 fixed |
| `VaultRegistry.sol` | vault status/caps/yield splits | No open finding |
| `atRISKUSD.sol` | ERC4626 accounting, withdrawals, lockups | No open finding |
| `hyperliquid/HLTradingBridge.sol` | custody route, return reconciliation, deploy forwarding, storage layout, dust resistance, vault- and registry-accounted principal return | H-01, H-02, R2-H-01, R2-H-02, R3-M-01, R4-M-01, R5-H-01, R6-H-01, P12-H-01, R8-M-01, R9-M-01 fixed |
| `interfaces/IBlocklist.sol` | blocklist port | No open finding |
| `interfaces/IForageVotes.sol` | vote port | No open finding |
| `interfaces/IVaultRegistry.sol` | registry port | No open finding |
