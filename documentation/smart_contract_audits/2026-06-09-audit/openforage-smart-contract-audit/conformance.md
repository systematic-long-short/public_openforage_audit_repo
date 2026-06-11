# Design Conformance

Reference documents:

- `documentation/smart_contract/target_smart_contract_architecture.html`
- `documentation/smart_contract/target_smart_contract_user_journeys.html`

## Conformance Results

| Requirement | Implementation | Result |
| --- | --- | --- |
| Mainnet finalize delay is 2 days | `FinalizeDelayProfile` returns production delay off testnet/local chain ids; deploy tests assert mainnet profile. | PASS |
| Mainnet governance uses 1-day voting delay, 5-day voting period, 8-day timelock | `DeployMainnet.s.sol` overrides deploy timings and dry-run tests assert deployed state. | PASS |
| Mainnet deploy path is no-broadcast | `DeployMainnet.run()` uses `runWithConfig` without `startBroadcast`, and harness checks no broadcast cheatcodes in mainnet script. | PASS |
| Mainnet HyperLiquid route is finalized before governance handoff | `Deploy.s.sol` calls the initial-config proposal hook immediately after proposal, and `DeployMainnet.s.sol` finalizes the initial `CustodianRegistry` HyperLiquid config before handoff or production timelock target registration can expire it; deploy tests assert registry bridge/executor/remote/peer state, bridge route config, absence of pending config, and finalization timestamps before expiry. | PASS |
| HyperLiquid deploys route to approved cold account | `Deploy.s.sol` accepts `coldAccount`; `HLTradingBridge` records the approved registry deployment and forwards the verified deploy delta. | PASS |
| HyperLiquid returns are custody-reconciled | Bridge intents pin route and require reconciled return liquidity; principal returns reduce bridge, vault, and `CustodianRegistry` deployed accounting, while PnL returns stay treasury-only. | PASS |
| Guardian emergency controls are tighten-only/freeze-only | Bridge and guardian target tests cover shrink/freeze behavior and loosen reverts. | PASS |
| Loss/stale NAV prevents unsafe deployment | `RISKUSDVault.deployCapital` rejects loss-pending state. | PASS |
| PnL claim funding is idempotent | `USDCTreasury.fundedDepositorClaim` tracks already funded claim. | PASS |

Unresolved design divergences: none known after current remediation.

Owner-escalated design changes: none required; all findings were resolved toward the existing target design.
