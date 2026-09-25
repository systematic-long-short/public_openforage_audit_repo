# Audit Scope

## Source scope

The review target is the public-safe production Solidity snapshot under `openforage_smart_contracts/`. Its runtime-source identity is private commit `8d4a 2d4c 44ba 7d83 cdc5 1d93 4e11 8655 049c 78ca`.

The source comparison accounted for all 26 production Solidity files and 18 ABI artifacts. In the measured 20-file production-source set, 19 source files differed from the observed public `main` and were copied from the runtime-source identity; `DelegatingVestingWallet.sol` was already identical. The other six production-source files were also already identical. Fifteen ABI files differed and were synchronized; the remaining three matched already. The new `script/interfaces/IAllowlistSettable.sol` contains the unchanged interface signature extracted from a test-only helper; the retained `Deploy.s.sol` import alone was redirected to this standalone interface.

The public snapshot preparation is a later selective change. It removes the 235-file first-party test tree, five test-only scripts, and two fuzz/formal campaign configuration files. The test tree's simplify baseline was relocated to `openforage_smart_contracts/simplify_baseline.json` byte-for-byte. No first-party Solidity tests, fuzz, invariant, formal, or deployment commands are part of this snapshot or its preparation proof. This source sync does not claim that the complete public tree equals the private runtime-source tree.

## Documentation scope

Documentation is limited to review scope, reviewer commands, public-safe historical records, and the current public remediation status. Private project records, raw portal exports, private paths, private run captures, deployment manifests, and unrelated monorepo documentation are excluded.

The code in this snapshot is the review target. Historical audit packages describe earlier code and must not be treated as current verification. The Octane Analysis 7 status document records current preparation evidence and the known static limitations; it does not claim that the findings are cleared.

## Submodules and imports

The Solidity dependencies are git submodules at the observed public pins:

- Chainlink CCIP: `bccd d15b 734e a6c0 e6d1 b3d3 6c48 2e64 ced2 d441`
- OpenZeppelin upgradeable contracts: `7bf4 727a acdb faa0 f36c bd66 4654 d0c9 e1dc 52bf`

The repository contains only those public gitlinks under `openforage_smart_contracts/lib/`; dependency contents are not vendored into this repository. Initialize the pins before the production build.

## Out of scope

- First-party contract tests, helpers, audit PoCs, fuzz and invariant harnesses, and formal harnesses
- Echidna or Halmos campaigns, Forge test commands, Anvil, deployment, RPC, and chain actions
- Private monorepo modules, project records, prompts, run logs, and raw external portal material
- Environment files, credentials, deployed-address manifests, generated broadcast output, and local caches
- Public publication, pull-request mutation, main-branch changes, and any Octane analysis trigger

The public build and static outputs are review evidence only. They do not authorize deployment, clear an audit finding, or replace an independent security review.
