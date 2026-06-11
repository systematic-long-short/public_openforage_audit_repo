# Review Commands

These commands are intended as starting points for local smart-contract review.
They do not replace reviewer-specific tooling.

## Smart Contracts

```bash
git submodule update --init --recursive
cd openforage_smart_contracts
forge build --force
forge test --match-path test/DeployMainnet.target.t.sol
forge test --match-path test/hyperliquid/HLTradingBridge.target.t.sol
forge test --match-path test/USDCTreasury.target.t.sol
make audit-static
make audit-formal
make audit-fuzz
make audit-foundry
```

The suite includes active red/regression guards. Treat any failures as review
inputs against this smart-contract snapshot rather than as documentation setup
requirements.

The latest retained evidence for these gates is under
`documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/`.

`forge test --summary` is intentionally not listed as a default command for this
scoped export. The transferred source is byte-identical to the private
smart-contract tree, but this repository excludes private-monorepo
web/keeper/config paths that the `HLLegacyTransportStaticTest` scan-count guard
expects. Running the full summary here produces one known export-scope failure:
`static scan scope regressed: 34 < 40`. In the private source environment, the
same checker scans 75 files and the retained audit evidence records the full
summary as passing.
