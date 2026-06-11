# Cantina V12 Remediation Summary

Current source snapshot: private OpenForage smart-contract/audit surface commit
`a2ec106acab846ef766dffc58b54fbd54bddd4ab`.

Primary remediation commit in the private repository:
`c066e3b34be07b847e5749201d229c63451da4bb`.

This file is retained as predecessor context. The current readiness gate for
this repository is the June 9/10, 2026 mainnet-readiness audit package under
`documentation/smart_contract_audits/2026-06-09-audit/`.

## Scope

This note summarizes the smart-contract changes included in this audit
snapshot. It is intentionally narrow and excludes private workpapers, local
logs, deployment secrets, and non-smart-contract source trees.

## Remediated Areas

- `DelegatingVestingWallet`: blocklist health checks now probe the release-path
  accounts, not only `address(0)`, so account-selective blocklist failures are
  detected before a blocklist is accepted or kept.
- `ProtocolTreasury`: tier-yield classification now uses the shared classifier
  path for quote and deposit flows, removing duplicate classification logic.
- Hyperliquid test risk helper: `HLImmediateTestRiskCore` moved out of
  production `src/` and into test helpers.
- Static analysis controls: Slither suppressions were re-triaged with concrete
  rationale, and the suppression checker now rejects placeholder waiver text.
- Audit tests: V12 regression suites and Cantina scan guards were added for the
  remediated findings.

## Verification Recorded Before Publication

- Full Forge suite: `4278` tests passed, `0` failed.
- `make audit`: passed.
- Final-run journey suites: `15` tests passed.
- HL CCIP wet proof: `2` tests passed.
- Independent phase reviews for implementation, security, architecture, reuse,
  and CTO approval were recorded as pass in the private remediation workflow.

## Reviewer Notes

The canonical review target is the code under `openforage_smart_contracts/`.
Run `git submodule update --init --recursive` before building or testing.
