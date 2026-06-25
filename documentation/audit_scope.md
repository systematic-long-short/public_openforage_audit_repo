# Audit Scope

## Source Scope

This snapshot is limited to one component tree:

- `openforage_smart_contracts/`

The source files are copied from the current working tree of the private
OpenForage repository's smart-contract/audit surface at commit
`bb4228378ff6ab83066f9d17c82b1b9a9abb747c`. Local generated artifacts,
environment files, and unrelated private monorepo trees are intentionally
omitted.

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

## Out Of Scope

- Private monorepo modules outside the exported smart-contract tree.
- Non-public environment files and signing or API credentials.
- Internal planning material and strategic documentation unrelated to this
  smart-contract audit campaign.
- Internal project/spec/tasklist/prompt artifacts.
- Raw external portal exports containing local reproduction paths or internal
  provenance discussion.
- Deployment manifests, keeper configuration, public cloud resource names, and
  generated broadcast output.
- Ad-hoc proposal, upgrade, or recovery scripts that embed deployed addresses.
- Private remediation scratchpads and unrelated historical audit trees.
- Generated build output, dependency installs, local caches, local state, and
  machine-specific files.
- Actual mainnet deployment or transaction broadcast. The included
  `DeployMainnet` path is a no-broadcast dry-run and source-readiness surface.
