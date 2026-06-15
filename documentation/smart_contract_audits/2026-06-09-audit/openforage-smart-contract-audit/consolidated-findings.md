# Consolidated Findings

Current status: all known Critical/High/Medium/Low findings are fixed in source, tests, and audit artifacts. Codex Round 12 passed after the Round 11 user-journey projection fix; post-R12 phase/security review then found R16-M-01 and R16-M-02, both fixed with red/green deploy evidence and post-R16-M02 validation logs. Fresh post-M02 confirmatory Codex Round 13 under public review reference R13 returned PASS with zero findings.

| ID | Severity | Status | Fix evidence |
| --- | --- | --- | --- |
| H-01 | High | Fixed | `HLTradingBridge.deployToHyperLiquid` forwards verified USDC delta to `coldAccount`; bridge target test asserts bridge balance zero and cold-account receipt. |
| H-02 | High | Fixed | `HLTradingBridge.RouteConfig` pins cold/source/chain; withdrawal intents require bridge recipient, expected source, expected chain, and caps. |
| M-01 | Medium | Fixed | `RISKUSDVault.deployCapital` reverts on loss-pending state; rolling daily vault regression covers the block. |
| M-02 | Medium | Fixed | `USDCTreasury.fundedDepositorClaim` prevents duplicate depositor-claim top-ups; treasury regression covers repeated PnL. |
| R2-H-01 | High | Fixed | Bridge return functions consume `_reconciledReturnLiquidity` and no longer pull executor cash; bridge tests cover insufficient liquidity and actual arrival reconciliation. |
| R2-H-02 | High | Fixed | New UUPS state is append-only in touched contracts; Python harness checks storage layout placement. |
| R3-M-01 | Medium | Fixed | Reconciliation uses unreconciled bridge balance and tests cover prior reconciled liquidity returned before later arrival. |
| R4-M-01 | Medium | Fixed | Bridge tracks one explicit open withdrawal intent; reconciliation must match that intent before a new intent can open. |
| R5-H-01 | High | Fixed | Unsolicited bridge USDC dust no longer blocks new intents; new intents are blocked by explicit open-intent state, not raw token balance. |
| R6-H-01 | High | Fixed | Principal returns consume reconciled bridge liquidity through `RISKUSDVault.returnCapital` before treasury bookkeeping, keeping vault deployed accounting current. |
| P12-H-01 | High | Fixed | Withdrawal reconciliation checkpoints unreconciled bridge balance at intent open; pre-existing dust cannot satisfy a later intent. Red evidence: `_audit_work/logs/red-dust-checkpoint-reconciliation.log`; green evidence: `_audit_work/logs/forge-test-hl-bridge-target.log`. |
| R8-M-01 | Medium | Fixed | `HLTradingBridge.deployToHyperLiquid` records every deploy against `CustodianRegistry.HYPERLIQUID_CUSTODIAN_ID()` before capital leaves the bridge, so the approved-destination pause/role/cap/accounting gate applies. Red evidence: `_audit_work/logs/red-r8-m01-registry-gate.log`; green evidence: `_audit_work/logs/green-r8-m01-registry-gate.log` and `_audit_work/logs/forge-test-hl-bridge-target-r8-m01.log`. |
| R9-M-01 | Medium | Fixed | `HLTradingBridge.returnPrincipalUSDC` records principal returns against `CustodianRegistry.HYPERLIQUID_CUSTODIAN_ID()` using normal or emergency return accounting, so registry deployed exposure and capacity are restored when principal returns. Red evidence: `_audit_work/logs/red-r9-m01-registry-return.log`; green evidence: `_audit_work/logs/green-r9-m01-registry-return.log` and `_audit_work/logs/forge-test-hl-bridge-target-r9-m01.log`. |
| R16-M-01 | Medium | Fixed | Mainnet dry-run wiring now initializes the bridge and `CustodianRegistry` with the configured HyperLiquid source account as the allowed peer, finalizes the initial HyperLiquid custodian config before governance handoff, and proves no pending config remains. Red evidence: `_audit_work/logs/red-r16-m01-mainnet-route-finalization.log`; green evidence: `_audit_work/logs/green-r16-m01-mainnet-route-finalization.log` and `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m01.log`. |
| R16-M-02 | Medium | Fixed | Initial mainnet HyperLiquid config finalization now happens through the shared deploy hook immediately after proposal, before production timelock target registration can advance time past `PROPOSAL_EXPIRY`; the deploy test asserts proposal/finalization timestamps remain monotonic and before expiry. Red evidence: `_audit_work/logs/red-r16-m02-mainnet-config-finalizes-before-expiry.log`; green evidence: `_audit_work/logs/green-r16-m02-mainnet-config-finalizes-before-expiry.log` and `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m02.log`. |
| R10-L-01 | Low | Fixed | `target_smart_contract_architecture.html` now documents registry return caps as live 10%/10% gates that restore deployed exposure and enforce return rate alongside the bridge. |
| R10-L-02 | Low | Fixed | `_audit_work/logs/make-audit-static.log` was recaptured with stderr included; the Semgrep scan summary and 0-findings line are now present in the saved evidence. |
| R11-L-01 | Low | Fixed | `target_smart_contract_user_journeys.html` K-13 now states registry return caps are live on principal returns through `recordReturn` / `recordEmergencyReturn`, matching the target architecture and source. |

Open Critical/High/Medium/Low findings: none known after the R16-M02 remediation and post-R16-M02 validation evidence.

Informational/Gas findings: existing static-analysis findings remain documented in `slither_suppressions.json`; no new Info/Gas remediation is required by the final code path.
