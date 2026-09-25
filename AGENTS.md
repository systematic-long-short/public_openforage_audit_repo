# OpenForage Audit Snapshot Agent Guide

This repository is a public-safe production-source snapshot for external smart-contract review. It contains no first-party Solidity tests, fuzz harnesses, or formal harnesses. Do not add or run those suites; their removal does not clear any finding.

## Refresh Procedure

1. Start with a fresh clone of this public repository and record the current `origin/main` commit and pull-request state.
2. Obtain only production-source files named by an approved source manifest. Never copy a broad private tree or private repository history into this clone.
3. Create a named local refresh branch from the observed public `origin/main`.
4. Stage only the allowlisted paths below. Do not use `git add -A` from a private-monorepo checkout.
5. Run the production build, no-tests inventory guard, ABI/layout/import review, static checks, and disclosure scans below. Never run `forge test`, Echidna, Halmos, fuzz, invariant, or formal campaigns.
6. Commit the reviewed diff locally. Public publication and pull-request work belong to the authorized operator workflow; never push `main` or force-push a refresh branch.

## Allowlist

Only these paths may be present in the public snapshot:

- `README.md`, `AGENTS.md`, and `.gitmodules`
- `openforage_smart_contracts/src/` and `openforage_smart_contracts/abi/`
- `openforage_smart_contracts/script/` production deployment and static-checker files only; first-party test scripts and harnesses are forbidden
- `openforage_smart_contracts/.semgrep/`, `Makefile`, `.gitignore`, `foundry.lock`, `foundry.toml`, `remappings.txt`, `slither.config.json`, `slither_suppressions.json`, `simplify_waivers.json`, and `simplify_baseline.json`
- `openforage_smart_contracts/lib/` as the two pinned Git submodules only
- `documentation/audit_scope.md` and `documentation/review_commands.md`
- `documentation/mainnet_readiness_2026-06-09.md`
- `documentation/cantina_v12_remediation.md`
- `documentation/smart_contract/`
- `documentation/smart_contract_audits/2026-06-09-audit/`, with private absolute paths scrubbed from retained logs
- `documentation/smart_contract_audits/2026-06-12-external-audit/`, with external-audit triage and overlap analysis only
- `documentation/smart_contract_audits/2026-06-17-external-audit/`, with public-safe assessments, fix attribution, acknowledgment worksheets, overlap analysis, and the public-safe Octane remediation status only

## Never Export

Never include these private or test-only surfaces:

- `openforage_library/`, `web/`, `plans/`, `projects/`, `.claude/`, or `.codex/`
- `.env*` or files containing environment assignments for credentials
- `openforage_smart_contracts/test/` or first-party test helpers, PoCs, fuzz, invariant, or formal sources
- `openforage_smart_contracts/script/DeployTestEnv.s.sol`
- `openforage_smart_contracts/script/FinalAuditWetPrimaryFlow.s.sol`
- `openforage_smart_contracts/script/TestContracts.sol`
- `openforage_smart_contracts/script/gen_selector_sweep.py`
- `openforage_smart_contracts/script/hyperliquid/HyperCoreAgentApprovalProbe.sol`
- `openforage_smart_contracts/echidna.yaml` or `openforage_smart_contracts/halmos.toml`
- `openforage_smart_contracts/deployments/`, `broadcast/`, `cache/`, or `out/`
- ad-hoc proposal, upgrade, or recovery scripts that embed deployed addresses
- vendored dependency contents under `openforage_smart_contracts/lib/`

The dependency paths under `openforage_smart_contracts/lib/` must remain the exact Chainlink and OpenZeppelin submodule pins.

## Production Review Commands

From the public repository root, run `make -C openforage_smart_contracts no-tests`, then `forge build --root openforage_smart_contracts --skip test`. From `openforage_smart_contracts/`, run `make no-tests`, `make audit-static`, and `make audit-simplify` after the build. The first-party test tree is absent by design; do not substitute a different test command.

## Required Disclosure Scans

Run these against both the branch working tree and the proposed commit:

```bash
git status --short
git ls-tree -r --name-only HEAD | rg '^(openforage_library|web|plans|projects|\.claude|\.codex)(/|$)'
rg -n --pcre2 '0x[a-fA-F0-9]{40}' openforage_smart_contracts/script
rg -n --hidden --glob '!**/.git/**' --glob '!AGENTS.md' --glob '!openforage_smart_contracts/lib/**' '(/home/[^[:space:]]+|private_openforage|\.claude/worktrees)' .
rg -n --hidden --glob '!**/.git/**' --glob '!AGENTS.md' --glob '!openforage_smart_contracts/lib/**' --pcre2 "(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|ya29\\.[0-9A-Za-z_-]+|xox[baprs]-[0-9A-Za-z-]{20,}|ghp_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(?:ql)?://[^[:space:]\"']+|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,})" .
```

Expected result: the public tree contains only the intended reviewed paths; the tree-path and script-address scans return no matches; and the local-path and secret scans outside this guide and the pinned third-party submodules return no live-looking private source, credential, or token material. Example credentials in documentation must be placeholders only.
