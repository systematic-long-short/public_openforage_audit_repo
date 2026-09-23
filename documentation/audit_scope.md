# Audit Scope

## Source Scope

This snapshot is limited to the public-safe portion of one component tree:

- `openforage_smart_contracts/`

The production Solidity files in `contracts/src/` and ABI files in
`contracts/abi/` are copied byte-for-byte from private OpenForage commit
`e5c2c76d55e197044e30392c407b52af598a1681` (26 Solidity files and 18 ABI
files). A deterministic per-file SHA-256 inventory comparison confirmed exact
parity. Tests and helpers were selected individually for the current source
changes and investor eligibility gate; the private `contracts/` tree was not
copied wholesale. Generated artifacts, deployment manifests, local caches,
private environment files, private audit provenance, and unrelated monorepo
trees are omitted.

The refresh includes the `Allowlist` registry and caller-gate mixin, plus the
RISKUSD vault and staking-queue delegate modules. The mainnet dry-run script
contains no hard-coded sequencer feed address; the feed is supplied by
configuration, with a deterministic placeholder in the dry-run path.

## Documentation Scope

Documentation in this repository is intentionally narrow. It should help a
reviewer identify what is present, how to install Solidity dependencies, and
which local smart-contract checks to run.

Included documentation is scoped to:

- the June 9/10, 2026 mainnet-readiness audit package under
  `documentation/smart_contract_audits/2026-06-09-audit/`;
- the June 12, 2026 external-audit triage package under
  `documentation/smart_contract_audits/2026-06-12-external-audit/`;
- the June 17, 2026 external-audit closeout package under
  `documentation/smart_contract_audits/2026-06-17-external-audit/`, limited to
  public-safe assessments, fix records, acknowledgment worksheets, and overlap
  analysis;
- the target architecture and target user-journey projections used by that
  audit's design-conformance pass;
- the historical Cantina V12 remediation summary.

It does not include unrelated implementation plans, operational runbooks,
company records, benchmark notes, memory records, or private deployment
procedures.

When code and documentation disagree, treat the code in this snapshot as the
review target and ask the repository owner for clarification.

## Submodules

The Solidity dependency directories are Git submodules pinned to the source
repository's current dependency commits:

- Chainlink CCIP: `bccdd15b734ea6c0e6d1b3d36c482e64ced2d441`
- OpenZeppelin upgradeable contracts:
  `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf`

Run `git submodule update --init --recursive` before building or testing the
smart contracts.

The source repository's vendored dependency trees were not exported. Their Git
tree hashes did not match the root trees of the existing pinned commits, so the
public submodule pins were left unchanged.

## Out Of Scope

- Private monorepo modules outside the exported smart-contract tree.
- Non-public environment files and signing or API credentials.
- Internal planning material and strategic documentation unrelated to this
  smart-contract audit campaign.
- Internal project/spec/tasklist/prompt artifacts.
- Raw external portal exports containing local reproduction paths or internal
  provenance discussion.
- Private-only suppression/waiver refreshes and their generated audit
  baselines. The pre-existing public suppression/waiver files are retained as
  historical snapshot data and were not revalidated against the current source.
- Deployment manifests, keeper configuration, public cloud resource names, and
  generated broadcast output.
- Ad-hoc proposal, upgrade, or recovery scripts that embed deployed addresses.
- Private remediation scratchpads and unrelated historical audit trees.
- Generated build output, dependency installs, local caches, local state, and
  machine-specific files.
- Actual mainnet deployment or transaction broadcast. The included
  `DeployMainnet` path is a no-broadcast dry-run and source-readiness surface.
