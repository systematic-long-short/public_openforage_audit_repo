# OpenForage Smart Contract Audit Report

Date: 2026-06-09 campaign, evidence refreshed 2026-06-10 local time.

## Scope

The audit covered every first-party Solidity file under `openforage_smart_contracts/src/`, plus deploy/test/tooling surfaces needed for mainnet-readiness acceptance.

## Summary

The campaign repaired the stale audit gate, added a production mainnet no-broadcast deploy path, and remediated all confirmed Critical/High/Medium/Low findings.

Confirmed fixed findings:

- H-01: bridge deploy stranded USDC instead of forwarding to cold account.
- H-02: withdrawal intents were not route-pinned or capped.
- M-01: stale/loss-pending NAV blocked exits while allowing further deployments.
- M-02: repeated PnL returns could double-fund depositor claims.
- R2-H-01: return functions could consume executor cash rather than bridge-held returned cash.
- R2-H-02: initial remediation inserted UUPS storage variables in existing layouts.
- R3-M-01: total-balance checkpoints could strand later returned USDC.
- R4-M-01: later intents could checkpoint cash that arrived for older unreconciled intents.
- R5-H-01: unsolicited bridge USDC dust could block new withdrawal intents.
- R6-H-01: principal returns bypassed vault return accounting.
- P12-H-01: pre-existing bridge dust could be misclassified as a new withdrawal arrival.
- R8-M-01: HyperLiquid deploys bypassed the `CustodianRegistry` approved-destination/accounting gate.
- R9-M-01: HyperLiquid principal returns did not reduce `CustodianRegistry` deployed exposure.
- R16-M-01: mainnet dry-run used an inconsistent HyperLiquid peer route and did not finalize the initial custodian config before governance handoff.
- R16-M-02: production timelock registration could advance dry-run time past the initial HyperLiquid config expiry before finalization.
- R10-L-01: target architecture still described registry return caps as dead config.
- R10-L-02: the saved static-analysis log did not include the Semgrep zero-finding summary.
- R11-L-01: target user-journey K-13 still said registry return caps were not checked on returns.

Current evidence:

- Static, formal, fuzz, audit-foundry, bridge target, treasury target, deploy-mainnet target, full Foundry summary, build, formatting, and Python harness gates are green after R16-M02.
- Full `forge test --summary` passed twice after R16-M02 with 219 suites and 2092 tests in both `_audit_work/logs/forge-test-summary-rerun-1.log` and `_audit_work/logs/forge-test-summary-rerun-2.log`.
- Supplemental pashov-style and nemesis-style Codex MCP reviews returned `AUDIT_RESULT: PASS`.
- R8-M-01 has red/green focused proof in `_audit_work/logs/red-r8-m01-registry-gate.log` and `_audit_work/logs/green-r8-m01-registry-gate.log`.
- R9-M-01 has red/green focused proof in `_audit_work/logs/red-r9-m01-registry-return.log` and `_audit_work/logs/green-r9-m01-registry-return.log`; the full bridge target suite passes 19 tests in `_audit_work/logs/forge-test-hl-bridge-target-r9-m01.log`.
- R16-M-01 has red/green mainnet-route proof in `_audit_work/logs/red-r16-m01-mainnet-route-finalization.log` and `_audit_work/logs/green-r16-m01-mainnet-route-finalization.log`.
- R16-M-02 has red/green expiry-ordering proof in `_audit_work/logs/red-r16-m02-mainnet-config-finalizes-before-expiry.log` and `_audit_work/logs/green-r16-m02-mainnet-config-finalizes-before-expiry.log`; the latest deploy-mainnet target suite passes 6 tests in `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m02.log`.
- R10-L-01/R10-L-02 are fixed by the target-design update and recaptured static-analysis log.
- R11-L-01 is fixed by the K-13 user-journey projection update.
- Final Codex Round 13 after the R16-M02 fix returned `AUDIT_RESULT` PASS with no findings on thread `019eb0bd-a47d-7db1-a6c8-923ad77db635`; post-M02 Phase 13 security, Phase 9 reuse, and Phase 8 architecture re-reviews also passed on threads `019eb0c5-fc57-76e0-aa4e-bc9d37e1ee25`, `019eb0cb-2081-7c90-8d22-f8aab90e01b9`, and `019eb0ce-f16a-76c1-a143-16b8ea89a2d8`.

## Conclusion

The source tree and audit artifacts have no known open Critical, High, Medium, or Low findings after the R16-M02 mainnet-route/finalization remediation and current validation gates. The remaining limitation is explicit: on-chain reconciliation proves bridge-held USDC availability, while HyperLiquid withdrawal provenance remains an off-chain keeper/trust boundary.
