# Phase Coverage Matrix

| Phase | Coverage | Evidence |
| --- | --- | --- |
| Inventory | All 19 first-party `src/**/*.sol` files listed | `_audit_work/inventory.md` |
| Security model | Assets, trust boundaries, threats documented | `security-model.md` |
| Automated tools | Foundry, Slither, Semgrep, Halmos, Echidna | `automated-results.md`, `_audit_work/logs/` |
| Pattern scan | Manual source pattern pass over all target files plus independent Codex MCP pashov-style supplement | `pattern-findings.md`, `pashov-supplement.md` |
| Deep logic | Manual state-machine/data-flow pass plus independent Codex MCP nemesis-style supplement | `nemesis-findings.md`, `nemesis-supplement.md` |
| Per-contract review | All contracts mapped to concerns/results | `_audit_work/per-contract/all-contracts.md` |
| Cross-contract 4A/4B | Bridge/vault/treasury/governance coupling reviewed | `cross-contract-findings.md` |
| DeFi checklist | Access, upgrade, accounting, caps, deployment safety | `checklist-results.md` |
| Regression/variant | Finding-specific red/green and variant tests | `regression-variant-results.md` |
| Codex adversarial | Multi-round independent review | `codex-review.md` |
| Consolidation | Findings and dispositions | `consolidated-findings.md` |
| Retest | Fresh command evidence | `retest-results.md` |
| Final report | Summary and source-readiness conclusion | `report.md` |
| Round retention | Artifact-retention interpretation and limitation | `round-retention.md` |

Limitations:

- The Codex runtime did not expose Claude's Agent surface for literal pashov/nemesis subagent spawning. The gap is closed by fresh independent Codex MCP reviewers that applied the local pashov and nemesis skill instructions in read-only mode: pashov thread `019eae1e-ed33-7491-bcf3-9d7dee4e8a0b`; nemesis thread `019eae28-c0de-7c23-a2f4-f0e813e06dcf`.
- Final clean confirmatory status after `R16-M-02` is Codex Round 13 PASS on thread `019eb0bd-a47d-7db1-a6c8-923ad77db635`. Post-R12 phase/security review found R16-M-01 and R16-M-02, both fixed by the mainnet route/finalization remediation. Post-R16-M02 validation passes: full `forge test --summary` twice with 219 suites / 2092 tests, updated bridge target suite 19 tests, deploy-mainnet target suite 6 tests, static/formal/fuzz/audit-foundry, and harness/parity tests. Post-M02 Phase 13 security, Phase 9 reuse, and Phase 8 architecture re-reviews passed on threads `019eb0c5-fc57-76e0-aa4e-bc9d37e1ee25`, `019eb0cb-2081-7c90-8d22-f8aab90e01b9`, and `019eb0ce-f16a-76c1-a143-16b8ea89a2d8`.
