# OpenForage Smart Contracts

This repository contains the OpenForage smart contract source code, ABIs, deployment scripts, and static-analysis configuration for independent security review. It contains smart contracts only and is not a copy of the private monorepo.

## Repository Layout

- `openforage_smart_contracts/src/` — 42 Solidity source, interface, library, and module files (Solc `0.8.24`).
- `openforage_smart_contracts/abi/` — 22 contract ABI files (21 compiler-matched to `src/`; `FoundationTreasury.json` is retained as a source-less historical artifact).
- `openforage_smart_contracts/script/` — 5 Solidity deployment/setup scripts and interfaces (`Deploy.s.sol`, `DeployMainnet.s.sol`, `DeployMainnetBroadcast.s.sol`, `RegisterAllowlist.s.sol`, `interfaces/IAllowlistSettable.sol`), `deploy_target_sc_gap.sh`, and 5 static-check helper scripts.
- `openforage_smart_contracts/lib/` — pinned Git submodule dependencies (`openzeppelin-contracts-upgradeable`, `chainlink-ccip`).
- `openforage_smart_contracts/foundry.toml`, `foundry.lock`, `remappings.txt`, `Makefile`, `slither.config.json`, `slither_suppressions.json`, `.semgrep/` — compiler profiles and static-analysis configuration.

No first-party contract test directory is included in this repository.

## Linked Libraries (CREATE2)

Both `[profile.default]` and `[profile.deploy]` link the two external libraries at their deterministic CREATE2 addresses (verified in `script/Deploy.s.sol`):

- `ForageGovernorTimelockMigrationGuard`: `0x46d318eb6a8c2635599e5b61e07a81c15a11381e`
- `GuardianAuthorityClassifier`: `0x6399CCAE7229A7dFa193401984BED90086471BAe`

## Core Design Boundaries

- **Fresh deployments only.** Upgradeable contracts enforce fresh-deployment initialization invariants and refuse uninitialized or legacy state before mutating storage.
- **Cash-backed withdrawals and rate caps.** Central vault deposits and redemptions enforce daily and weekly supply-based rate caps; current-window and one-window carried-over mints offset redemption cap charges without inflating current-window mint room. Tiered `atRISKUSD` withdrawals use a 7-day request/claim cycle subject to weekly tier exit caps and cash availability; no fixed payout date is promised.
- **Profit and custody-loss accounting.** Recognized profit belongs to holders at recognition time, while unpaid profit remains a separate claim funded only as cash arrives. Reported custodian losses are borne by holders at report time, and transfers/exits that could avoid a pending loss remain frozen through settlement.
- **Access control and governance.** The Allowlist gates entry/exit actions (deposits, queue joins, withdrawals, redemptions, and profit recipients), managed through `AllowlistRegistrarForwarder`. Governance actions flow through `ForageGovernor` and `TimelockController`, guarded by `ForageGovernorTimelockGuard` and `GuardianModule`.

## Build and Static Checks

Initialize submodules and build using Solc `0.8.24`:

```bash
git submodule update --init --recursive
cd openforage_smart_contracts
FOUNDRY_PROFILE=deploy forge build --sizes --skip 'test/**'
make no-tests audit-i15 audit-legacy
```

`FOUNDRY_PROFILE=deploy` (`via_ir = true`, `optimizer_runs = 0`, `revert_strings = "strip"`, `bytecode_hash = "none"`) is the production build profile. `FOUNDRY_PROFILE=default` is not deployed and exceeds EIP-170/EIP-3860 on several contracts.

## Contract Bytecode Sizes (Solc 0.8.24)

All 45 first-party Deploy runtime and initcode artifacts fit within EIP-170 (24,576 B) and EIP-3860 (49,152 B). `ForageToken` has the tightest Deploy runtime margin at +434 bytes.

| Contract or library | Default runtime / initcode (margin) | Deploy runtime / initcode (margin) |
|---|---:|---:|
| Allowlist | 15,058 / 15,314 (+9,518 / +33,838) | 13,303 / 13,513 (+11,273 / +35,639) |
| AllowlistRegistrarForwarder | 811 / 1,156 (+23,765 / +47,996) | 755 / 1,050 (+23,821 / +48,102) |
| atRISKUSD | 24,442 / 49,533 (+134 / -381) | 20,486 / 42,738 (+4,090 / +6,414) |
| AtRiskUSDProfitModule | 16,532 / 16,873 (+8,044 / +32,279) | 15,018 / 15,349 (+9,558 / +33,803) |
| AtRiskUSDStateModule | 23,870 / 24,510 (+706 / +24,642) | 21,210 / 21,773 (+3,366 / +27,379) |
| AtRiskUSDWeeklyExitModule | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| Blocklist | 9,711 / 9,967 (+14,865 / +39,185) | 8,175 / 8,384 (+16,401 / +40,768) |
| CustodianRegistry | 21,588 / 34,928 (+2,988 / +14,224) | 17,420 / 29,126 (+7,156 / +20,026) |
| CustodianRegistryCapitalModule | 12,902 / 13,008 (+11,674 / +36,144) | 11,306 / 11,401 (+13,270 / +37,751) |
| CustodianRegistryCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| DelegatingVestingWallet | 7,333 / 9,505 (+17,243 / +39,647) | 6,246 / 7,733 (+18,330 / +41,419) |
| ForageGovernor | 28,053 / 49,546 (-3,477 / -394) | 23,853 / 43,313 (+723 / +5,839) |
| ForageGovernorTimelockGuard | 20,819 / 21,041 (+3,757 / +28,111) | 18,885 / 19,075 (+5,691 / +30,077) |
| ForageGovernorTimelockMigrationGuard | 24,790 / 24,843 (-214 / +24,309) | 22,113 / 22,146 (+2,463 / +27,006) |
| ForageToken | 24,757 / 25,190 (-181 / +23,962) | 24,142 / 24,503 (+434 / +24,649) |
| ForageTokenSourceVerificationStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| ForageTokenStateModule | 25,169 / 40,943 (-593 / +8,209) | 22,809 / 38,137 (+1,767 / +11,015) |
| ForageTokenVoteEligibilitySyncQueue | 9,044 / 15,436 (+15,532 / +33,716) | 8,094 / 14,993 (+16,482 / +34,159) |
| ForageTokenVoteEligibilitySyncReplay | 6,191 / 6,234 (+18,385 / +42,918) | 6,700 / 6,739 (+17,876 / +42,413) |
| FORAGETreasury | 24,295 / 27,665 (+281 / +21,487) | 20,054 / 22,729 (+4,522 / +26,423) |
| FORAGETreasuryModule | 2,930 / 2,981 (+21,646 / +46,171) | 2,261 / 2,308 (+22,315 / +46,844) |
| GovernancePayloadBudget | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| GuardianAuthorityClassifier | 12,817 / 12,870 (+11,759 / +36,282) | 10,851 / 10,884 (+13,725 / +38,268) |
| GuardianEmergencyPrincipalLane | 2,656 / 2,987 (+21,920 / +46,165) | 2,385 / 2,671 (+22,191 / +46,481) |
| GuardianModule | 24,701 / 24,957 (-125 / +24,195) | 20,116 / 20,330 (+4,460 / +28,822) |
| HLTradingBridge | 25,089 / 34,791 (-513 / +14,361) | 23,575 / 32,038 (+1,001 / +17,114) |
| HLTradingBridgeCapitalModule | 9,213 / 9,313 (+15,363 / +39,839) | 8,015 / 8,111 (+16,561 / +41,041) |
| HLTradingBridgeCapitalStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsHostStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| HLTradingBridgeReturnCapsModule | 1,930 / 1,973 (+22,646 / +47,179) | 1,583 / 1,622 (+22,993 / +47,530) |
| HLTradingBridgeReturnCapsModuleStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| RISKUSD | 12,324 / 12,616 (+12,252 / +36,536) | 10,418 / 10,663 (+14,158 / +38,489) |
| RISKUSDVault | 23,161 / 23,453 (+1,415 / +25,699) | 19,706 / 19,956 (+4,870 / +29,196) |
| RISKUSDVaultModule | 25,304 / 25,769 (-728 / +23,383) | 21,247 / 21,700 (+3,329 / +27,452) |
| RISKUSDVaultRedemptionBufferStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| StakingQueue | 27,992 / 28,284 (-3,416 / +20,868) | 23,964 / 24,214 (+612 / +24,938) |
| StakingQueueLockupModule | 12,711 / 12,797 (+11,865 / +36,355) | 11,291 / 11,373 (+13,285 / +37,779) |
| StakingQueueModule | 19,018 / 19,278 (+5,558 / +29,874) | 19,088 / 19,321 (+5,488 / +29,831) |
| USDCTreasury | 26,554 / 31,232 (-1,978 / +17,920) | 23,957 / 27,835 (+619 / +21,317) |
| USDCTreasuryAccountingModule | 14,631 / 14,717 (+9,945 / +34,435) | 12,403 / 12,485 (+12,173 / +36,667) |
| USDCTreasuryPnLCashOutStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| USDCTreasuryProfitPolicyModule | 4,259 / 4,303 (+20,317 / +44,849) | 3,486 / 3,525 (+21,090 / +45,627) |
| USDCTreasuryRecognitionStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |
| VaultRegistry | 21,894 / 22,150 (+2,682 / +27,002) | 19,373 / 19,587 (+5,203 / +29,565) |
| VaultRegistryTierAssetEpochStorage | 85 / 135 (+24,491 / +49,017) | 16 / 44 (+24,560 / +49,108) |

## Static Verification Notes

- `make no-tests`, `make audit-i15`, and `make audit-legacy` pass.
- All 21 source-backed ABIs in `abi/` match compiler output (`FoundationTreasury.json` remains source-less).
- Slither `0.11.6` reports 540 findings matched against 540 entries in `slither_suppressions.json` (2 `StakingQueueModule` `reentrancy-no-eth` findings have run-to-run hash-order nondeterminism in Slither ID generation).
- Semgrep against `.semgrep/openforage.yml` and `.semgrep/disjointness-grant-role.yml` reports 86 matches (unchanged from prior baseline).
- `make audit-static` and `make audit-simplify` do not pass as-is because `.semgrep/source-manifest.json` and `simplify_baseline.json` predate later contract rounds.
