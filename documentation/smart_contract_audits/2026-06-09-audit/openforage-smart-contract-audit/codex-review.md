# Codex Review

Primary adversarial review thread: `019ead51-b8c1-79d0-b3ff-bf7d1532e361`.
Replacement final-review thread after the original thread expired: `019eaffc-f58f-7502-977d-37c2e5f413af`.

| Round | Verdict | Findings |
| --- | --- | --- |
| 1 | REJECT | H-01 bridge stranded deployed USDC; H-02 withdrawal intents not capped/pinned; M-01 stale NAV/loss-pending state blocked exits but not deploys; M-02 repeated PnL could double-fund depositor claims. |
| 2 | REJECT | R2-H-01 returned cash could be marked consumed while return functions used executor cash; R2-H-02 UUPS variables inserted in existing storage layouts. |
| 3 | REJECT | R3-M-01 total-balance checkpoint could make later real returned USDC unreconcilable after prior liquidity was returned. |
| 4 | REJECT | R4-M-01 second intent could checkpoint cash that arrived for an older intent before the older intent was reconciled. |
| 5 | REJECT | R5-H-01 raw bridge-balance gating let unsolicited 1-unit USDC dust permanently block new withdrawal intents. |
| 6 | REJECT | R6-H-01 principal returns bypassed `RISKUSDVault.returnCapital`, leaving vault deployed-principal accounting stale. |
| 7 | PASS | No findings; residual limitation is off-chain HyperLiquid provenance at the keeper/trust boundary. |
| 8 | REJECT | R8-M-01 HyperLiquid deploys bypassed the `CustodianRegistry` approved-destination/accounting gate required by the target design. |
| 9 | REJECT | R9-M-01 HyperLiquid deploy accounting became one-way: deployments incremented `CustodianRegistry.deployed`, but principal returns did not reduce it. |
| 10 | REJECT | R10-L-01 target design still described registry return caps as dead config; R10-L-02 saved static log lacked captured Semgrep summary. |
| 11 | REJECT | R11-L-01 target user-journey projection still said registry return caps were not checked on returns. |
| 12 | PASS | No findings; Round 11 remediation, R8/R9 source/tests/logs, captured Semgrep evidence, and full validation evidence verified. |
| R16 phase review | REJECT | R16-M-01 mainnet dry-run did not prove route consistency/finalizability: registry peer used the bridge address instead of the configured HyperLiquid source account, and the initial custodian config could remain pending through governance handoff. |
| R16 security review | REJECT | R16-M-02 initial mainnet HyperLiquid config was proposed before production timelock target registration, but finalization ran after the 8-day registrations could advance dry-run time past `PROPOSAL_EXPIRY`; tests did not assert expiry-safe timing. |
| 13 | PASS | No findings after the R16-M02 fix; reviewer checked the shared proposal hook, mainnet expiry-safe finalization, route/timing assertions, R16-M02 red/green logs, deploy-mainnet target log, and consolidated/retest evidence. |

Supplemental implementation review thread: `019ead33-bf1e-7293-9cd6-8db18b160593`, which accepted the gate/deploy repair after earlier deploy-evidence gaps were closed.

Phase-12 security review after Round 7 found `P12-H-01`: pre-existing unreconciled bridge dust equal to a later intent amount could satisfy reconciliation. The fix stores `balanceCheckpoint` as the unreconciled balance at intent open and requires `currentUnreconciled >= checkpoint + arrivedAmount`.

Supplemental pashov-style Codex MCP review: thread `019eae1e-ed33-7491-bcf3-9d7dee4e8a0b`, `AUDIT_RESULT: PASS`, no new C/H/M/L findings.

Supplemental nemesis-style Codex MCP review: thread `019eae28-c0de-7c23-a2f4-f0e813e06dcf`, `AUDIT_RESULT: PASS`, no new C/H/M/L findings.

Round 8 remediation: `HLTradingBridge.deployToHyperLiquid` now records every deploy through `CustodianRegistry.recordDeployment(HYPERLIQUID_CUSTODIAN_ID(), amount)` before capital leaves the bridge. Red evidence: `_audit_work/logs/red-r8-m01-registry-gate.log`. Green evidence: `_audit_work/logs/green-r8-m01-registry-gate.log` and `_audit_work/logs/forge-test-hl-bridge-target-r8-m01.log`.

Round 9 remediation: `HLTradingBridge.returnPrincipalUSDC` now closes registry deployed exposure through `recordReturn` or `recordEmergencyReturn` after local principal/liquidity accounting and before vault return/treasury bookkeeping. `requestWithdrawalIntent` is also `nonReentrant` for defense-in-depth on the bridge return surface. Red evidence: `_audit_work/logs/red-r9-m01-registry-return.log`. Green evidence: `_audit_work/logs/green-r9-m01-registry-return.log` and `_audit_work/logs/forge-test-hl-bridge-target-r9-m01.log`.

Round 10 remediation: `target_smart_contract_architecture.html` now states that HyperLiquid registry return caps are live 10%/10% gates aligned with the bridge return caps, and `make-audit-static.log` was refreshed with stderr captured so the Semgrep zero-finding summary is present in the evidence artifact.

Round 11 remediation: `target_smart_contract_user_journeys.html` K-13 now matches the target architecture and implementation: both bridge-local and registry return gates are live 10%/10% controls, and registry return accounting restores deployed exposure/capacity.

Final confirmatory review after `R11-L-01`: Round 12 on replacement thread `019eaffc-f58f-7502-977d-37c2e5f413af` returned `AUDIT_RESULT {"task_id":"T-SCMA-18-final-run","verdict":"PASS","round":12,"findings":[]}`.

R16-M-01 remediation: `Deploy.s.sol` now wires `CustodianRegistry.hyperLiquidLaunchConfig` with the configured HyperLiquid source account, and `DeployMainnet.s.sol` finalizes the initial HyperLiquid custodian config before governance handoff. Red evidence: `_audit_work/logs/red-r16-m01-mainnet-route-finalization.log`. Green evidence: `_audit_work/logs/green-r16-m01-mainnet-route-finalization.log` and `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m01.log`.

R16-M-02 remediation: `Deploy.s.sol` invokes `_afterInitialCustodianConfigProposed()` immediately after the initial HyperLiquid config proposal, and `DeployMainnet.s.sol` overrides that hook to finalize the config as soon as the production `FINALIZE_DELAY` matures and before production timelock target registration/handoff can expire it. Red evidence: `_audit_work/logs/red-r16-m02-mainnet-config-finalizes-before-expiry.log`. Green evidence: `_audit_work/logs/green-r16-m02-mainnet-config-finalizes-before-expiry.log` and `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m02.log`. Post-R16-M02 validation evidence: `_audit_work/logs/make-audit-static-final-r16.log`, `_audit_work/logs/make-audit-formal-final-r16.log`, `_audit_work/logs/make-audit-fuzz-final-r16.log`, `_audit_work/logs/make-audit-foundry-final-r16.log`, and both full `forge test --summary` reruns.

Final confirmatory review after `R16-M-02`: Round 13 on thread `019eb0bd-a47d-7db1-a6c8-923ad77db635` returned `AUDIT_RESULT {"task_id":"T-SCMA-18-final-run","verdict":"PASS","round":13,"findings":[]}`. Evidence checked by the reviewer included `Deploy.s.sol:618-627`, `DeployMainnet.s.sol:118-131`, `DeployMainnet.target.t.sol:129-157`, R16-M02 red/green logs, the deploy-mainnet target log, `retest-results.md`, and `consolidated-findings.md`.

Post-M02 phase re-reviews: Phase 13 security PASS on thread `019eb0c5-fc57-76e0-aa4e-bc9d37e1ee25`; Phase 9 reuse PASS on thread `019eb0cb-2081-7c90-8d22-f8aab90e01b9`; Phase 8 architecture PASS on thread `019eb0ce-f16a-76c1-a143-16b8ea89a2d8`.

Artifact-retention clarification: `round-retention.md` records that the durable full audit package is cumulative, while Codex adversarial iterations are retained as review records here rather than as separate copied `_audit_work/` directories.
