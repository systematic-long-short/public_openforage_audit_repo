# OpenForage Public Smart Contract Audit Snapshot

This public repository is a selective source snapshot for external review of
the OpenForage smart contracts. It is not the private monorepo and is not a
deployment repository.

Agent export rules live in `AGENTS.md`. Refreshes are built on a public pull
request branch from the allowlist in that file, with scan and review evidence
attached to the PR before merge.

## Current Source Snapshot

The pinned private source revision for this refresh is
`e5c2c76d55e197044e30392c407b52af598a1681`. All 26 production Solidity files
under `contracts/src/` and all 18 ABI files under `contracts/abi/` are
byte-identical to that revision. The refresh adds the investor `Allowlist`, its
caller-gate mixin, the RISKUSD vault and staking-queue delegate modules, and
their focused tests and support.

This refresh is a source-snapshot preparation, not a new security audit. The
historical audit packages below do not assess the current source revision.

Validation for this refresh: `forge build --force` succeeded with compiler
warnings; the bounded Allowlist and caller-gate runs passed 100 tests, including
64 fuzz runs for the focused fuzz suite. The full suite and high-depth
fuzz/invariant/formal campaigns were not run.

## Historical Audit Records

The following are records of earlier reviews and remediation. Their results
apply to the code and scope reviewed at that time, not to source revision
`e5c2c76d55e197044e30392c407b52af598a1681`.

The June 9/10, 2026 mainnet-readiness audit package records:

- no known open Critical, High, Medium, or Low findings after the R16-M02
  remediation;
- passing static, formal, fuzz, audit-foundry, bridge target, treasury target,
  DeployMainnet target, full Foundry, build, formatting, and Python harness
  gates;
- passing final Codex adversarial review and post-M02 security, reuse, and
  architecture re-reviews;
- target architecture and target user-journey conformance with no unresolved
  design divergences.

The remaining limitation is explicit in the audit report: on-chain
reconciliation proves bridge-held USDC availability, while HyperLiquid
withdrawal provenance remains an off-chain keeper/trust boundary. This snapshot
does not perform or authorize a mainnet broadcast.

The June 12, 2026 external-audit triage package records Cantina and Octane
findings review, accepted true-positive overlap, and focused Foundry
reproductions for the live overlap roots carried in this snapshot.

The June 17, 2026 external-audit closeout package records the follow-up
Cantina/Octane disposition: all retained valid findings are fixed in current
source or were already fixed by the current source, and the portal-facing
acknowledgment worksheets are included. Raw portal exports that contain local
reproduction paths or internal provenance discussion are intentionally omitted.

The full Foundry suite and high-depth audit campaigns have not been run against
this refreshed snapshot. Historical full-suite evidence in the retained audit
packages is not verification of the current source revision.

## Included

- `openforage_smart_contracts/`: production Solidity sources and ABI files,
  selected current tests/helpers and generic tooling, build/static-analysis
  configuration, and pinned Solidity dependencies.
- `documentation/smart_contract_audits/2026-06-09-audit/`: latest audit report,
  finding consolidation, conformance, retest, review, and validation evidence.
- `documentation/smart_contract_audits/2026-06-12-external-audit/`: external
  audit triage, overlap analysis, and reviewer-facing findings context.
- `documentation/smart_contract_audits/2026-06-17-external-audit/`: public-safe
  external-audit assessment, fix attribution, acknowledgment worksheets, and
  overlap analysis for the latest smart-contract closeout.
- `documentation/smart_contract/`: target smart-contract architecture and
  user-journey projections used by the conformance review.
- `documentation/cantina_v12_remediation.md`: historical remediation summary for
  the May 30, 2026 Cantina V12 pass, retained as predecessor context.

## Excluded

- Non-smart-contract source trees.
- Internal project/spec/tasklist/prompt artifacts.
- Company, strategy, benchmark, memory, and unrelated runbook documents.
- Private environment files, credentials, signing material, and deployment
  secrets.
- Deployment manifests, keeper config, generated broadcast output, and public
  cloud resource names.
- Ad-hoc proposal, upgrade, or recovery scripts that embed deployed addresses.
- Generated build output and local caches such as Foundry `cache/`, `out/`, and
  `broadcast/`.
- Vendored copies of third-party Solidity dependencies. They are represented as
  pinned Git submodules instead.

## Dependency Pins

After cloning, initialize Solidity dependencies with:

```bash
git submodule update --init --recursive
```

Pinned submodules:

- `openforage_smart_contracts/lib/chainlink-ccip`
- `openforage_smart_contracts/lib/openzeppelin-contracts-upgradeable`

See `documentation/audit_scope.md` and `documentation/review_commands.md` for
scope boundaries and suggested local checks.
