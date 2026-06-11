# Cross-Contract Findings

## Bridge, Vault, Treasury

- `HLTradingBridge.deployToHyperLiquid` now receives USDC from `RISKUSDVault.deployCapital`, verifies the exact bridge balance delta, forwards that delta to `coldAccount`, and then updates deployed principal.
- `HLTradingBridge.postNAV` feeds `RISKUSDVault.recordCustodianNAV`, and `RISKUSDVault.deployCapital` fails while loss-pending state is active.
- `HLTradingBridge.reconcileWithdrawalArrival` is the only path that increases reconciled return liquidity.
- `HLTradingBridge.reconcileWithdrawalArrival` compares unreconciled bridge balance against the intent's request-time checkpoint plus the expected arrival amount, so pre-existing dust remains unreconciled.
- `HLTradingBridge.returnPrincipalUSDC` reduces bridge principal, consumes reconciled bridge liquidity, records `CustodianRegistry` return accounting, calls `RISKUSDVault.returnCapital`, then records treasury bookkeeping without moving principal through `USDCTreasury`.
- `HLTradingBridge.returnPnLUSDC` consumes reconciled bridge liquidity and sends only PnL to `USDCTreasury`.
- `USDCTreasury.returnPnLUSDC` tracks already funded depositor claim to prevent duplicate vault top-ups.

## Governance And Emergency Controls

- Production deploy dry-run uses mainnet timings and transfers production ownership to timelock.
- Guardian bridge controls remain tighten-only or freeze-only; owner/timelock is required to loosen.
- Mainnet `FINALIZE_DELAY()` remains 2 days via `FinalizeDelayProfile`.

## Open Cross-Contract Findings

None known after checkpoint remediation and the supplemental pashov/nemesis Codex MCP reviews.
