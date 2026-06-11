# Inventory

Audit target: every first-party Solidity file under `openforage_smart_contracts/src/`.

| File | Primary surface | Phase coverage |
| --- | --- | --- |
| `src/Blocklist.sol` | Blocklist governance, expiry, transfer gate dependency | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/CustodianRegistry.sol` | Custodian config registry and launch defaults | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/DelegatingVestingWallet.sol` | Vesting wallet and delegation controls | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/FORAGETreasury.sol` | FORAGE treasury distribution | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/FinalizeDelayProfile.sol` | chain-sensitive finalize delay | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/ForageGovernor.sol` | governance proposal/vote/timelock integration | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/ForageToken.sol` | FORAGE token, lock, delegation | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/GuardianModule.sol` | emergency controls and tighten-only routes | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/IForageGovernorPause.sol` | governor pause interface | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/RISKUSD.sol` | RISKUSD token minter/governor controls | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/RISKUSDVault.sol` | RISKUSD mint/redeem/custodian/loss accounting | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/StakingQueue.sol` | queue routing, caps, tier accounting | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/USDCTreasury.sol` | PnL accounting, earmarks, claim funding | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/VaultRegistry.sol` | vault registry, caps, yield splits | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/atRISKUSD.sol` | ERC4626 tier vaults, lockups, withdrawals | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/hyperliquid/HLTradingBridge.sol` | HyperLiquid custody bridge | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/interfaces/IBlocklist.sol` | blocklist interface | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/interfaces/IForageVotes.sol` | voting interface | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |
| `src/interfaces/IVaultRegistry.sol` | vault registry interface | static, pattern, manual logic, cross-contract, checklist, regression sweep, Codex review |

Notes:

- Third-party code under `lib/` and generated build outputs under `out/` are out of scope.
- Deployment scripts and tests were reviewed as support surfaces for the mainnet-readiness acceptance proofs, but not as per-contract audit targets.
- "manual logic" means source-level Feynman/state-machine/data-flow review by the implementer, followed by Codex adversarial review and the supplemental independent Codex MCP pashov/nemesis-style reviews recorded in `pashov-supplement.md` and `nemesis-supplement.md`.
