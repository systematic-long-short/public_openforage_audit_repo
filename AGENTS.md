# OpenForage Audit Snapshot Agent Guide

This repository is a public-safe smart-contract audit snapshot. It must never
be refreshed by copying broad private-monorepo directories or by importing
private history. Refreshes are append-only through pull requests so reviewers
can audit the diff, scans, and merge trace.

## Refresh Procedure

1. Start from a fresh clone of the private OpenForage source repository and a
   fresh clone of this audit repository.
2. Create a named refresh branch from the current `origin/main`.
3. Stage only the allowlisted paths below. Do not use `git add -A` from a
   private-monorepo checkout.
4. Run the disclosure scans below against the branch working tree and commit.
5. Push the branch, open a pull request, and put the scan/test evidence in the
   PR body or a PR comment.
6. Merge the PR only after the forbidden-path scans return no matches and the
   public diff has been reviewed. Do not force-push or rewrite `main`.

## Allowlist

Only these paths may be present in the public snapshot:

- `README.md`
- `AGENTS.md`
- `.gitmodules`
- `openforage_smart_contracts/`, excluding deployment manifests, generated
  output, local caches, private env files, ad-hoc operation scripts with
  deployed addresses, and vendored dependency contents
- `documentation/audit_scope.md`
- `documentation/review_commands.md`
- `documentation/mainnet_readiness_2026-06-09.md`
- `documentation/cantina_v12_remediation.md`
- `documentation/smart_contract/`
- `documentation/smart_contract_audits/2026-06-09-audit/`, with private
  absolute paths scrubbed from retained logs
- `documentation/smart_contract_audits/2026-06-12-external-audit/`, with
  external-audit triage and overlap analysis only

## Never Export

Never include these private-monorepo surfaces:

- `openforage_library/`
- `web/`
- `plans/`
- `projects/`
- `.claude/`
- `.codex/`
- `.env*` or files containing environment assignments for credentials
- `openforage_smart_contracts/deployments/`
- `openforage_smart_contracts/broadcast/`
- `openforage_smart_contracts/cache/`
- `openforage_smart_contracts/out/`
- ad-hoc proposal, upgrade, or recovery scripts that embed deployed addresses
- vendored dependency trees under `openforage_smart_contracts/lib/`

The dependency paths under `openforage_smart_contracts/lib/` must remain git
submodule pins only.

## Required Scans

Run these before pushing a refreshed snapshot:

```bash
git status --short
git ls-tree -r --name-only HEAD | rg '^(openforage_library|web|plans|projects|\\.claude|\\.codex)(/|$)'
rg -n --pcre2 '0x[a-fA-F0-9]{40}' openforage_smart_contracts/script
rg -n --hidden --glob '!**/.git/**' --glob '!AGENTS.md' --glob '!openforage_smart_contracts/lib/**' '(/home/[^[:space:]]+|private_openforage|\\.claude/worktrees)' .
rg -n --hidden --glob '!**/.git/**' --glob '!AGENTS.md' --glob '!openforage_smart_contracts/lib/**' --pcre2 "(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|ya29\\.[0-9A-Za-z_-]+|xox[baprs]-[0-9A-Za-z-]{20,}|ghp_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(?:ql)?://[^[:space:]\"']+|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,})" .
```

Expected result: the working tree contains only the intended refresh diff; the
tree-path scan returns no matches; the script address scan returns no raw
deployed-address literals; the content and secret scans outside `AGENTS.md`
and outside pinned third-party submodules return no live-looking private source,
local path, credential, or token material. Example credentials in documentation
should be placeholders only.
