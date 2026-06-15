# Deep Logic Findings

This file records the manual Feynman/state-machine/data-flow pass plus the supplemental independent Codex MCP review that applied the local nemesis-auditor workflow.

## Reviewed State Machines

- `RISKUSDVault`: deposit, redemption, weekly/daily caps, custodian deployment, NAV attestation, loss pending/replenish, upgrade storage.
- `HLTradingBridge`: deploy-to-cold-account, NAV post, withdrawal intent, arrival reconciliation, return principal/PnL, keeper rotation, directional freeze.
- `USDCTreasury`: principal/PnL receipt, depositor claim funding, earmark window accounting.
- `StakingQueue` and `atRISKUSD`: tier queue routing, lockup/cooldown, backing-per-share invariants.
- Governance, guardian, registry, token, and blocklist contracts: authority and fail-loud routes.

## Deep Logic Outcomes

- The primary coupled-state risk was bridge-vault-treasury accounting, not isolated arithmetic.
- The accepted final design separates three balances: deployed principal, reconciled bridge liquidity, and unreconciled bridge token balance.
- New withdrawal intents are rejected while an explicit older intent remains open; unsolicited bridge dust does not block new intents.
- Intent reconciliation now checkpoints unreconciled bridge balance at request time, so pre-existing dust cannot be counted as a later HyperLiquid arrival.
- Return functions spend only reconciled bridge liquidity and never pull executor cash.
- Principal returns flow through `RISKUSDVault.returnCapital` before treasury bookkeeping, so vault deployed accounting and loss-pending checks stay aligned.
- PnL return funding is idempotent per vault claim by tracking `fundedDepositorClaim`.
- Deployment under stale/loss-pending NAV now fails before further principal leaves the vault.

Supplemental nemesis-style Codex review under public reference nemesis-review-A returned `AUDIT_RESULT: PASS` with no new C/H/M/L findings. Transcript summary is retained in `nemesis-supplement.md`.

Open deep-logic findings: none known after the checkpoint remediation and current green gates.
