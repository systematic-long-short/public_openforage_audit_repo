# OpenForage Public Smart Contract Audit Snapshot

This public repository is a selective source snapshot for external review of
the OpenForage smart contracts. It is not the private monorepo and is not a
deployment repository.

Agent export rules live in `AGENTS.md`. Any future refresh must be built as a
fresh single-commit snapshot from the allowlist in that file, not by pushing
private-monorepo history or by pruning paths from an existing public branch.

Smart-contract source and audit documentation surface copied from private
OpenForage commit `a2ec106acab846ef766dffc58b54fbd54bddd4ab`
(`T-SCMA close merge-push evidence row`). The private repository HEAD at export
time was `4b192e60ba1a08a12a83a17ad203a51af4e0de19`; there were no later
changes to the exported smart-contract/audit surface.

## Readiness Status

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

This scoped audit repository intentionally excludes surrounding private-monorepo
web/keeper/config paths. Because of that, the wholesale `forge test --summary`
command has one known export-scope failure in
`HLLegacyTransportStaticTest.test_noLegacyTransportIdentifiersInActiveSurface`:
the static checker sees fewer scanned files than it sees in the private
monorepo. The contract build and focused readiness suites pass in this export;
the private audit package retains the full source-environment `forge test
--summary` pass evidence.

## Included

- `openforage_smart_contracts/`: Solidity contracts, Foundry tests, generic
  deploy scripts, static-analysis configuration, and pinned Solidity
  dependencies.
- `documentation/smart_contract_audits/2026-06-09-audit/`: latest audit report,
  finding consolidation, conformance, retest, review, and validation evidence.
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
