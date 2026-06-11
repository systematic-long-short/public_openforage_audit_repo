# Security Model

## Assets

- USDC held by `RISKUSDVault`, `USDCTreasury`, and the HyperLiquid custody return path.
- RISKUSD and atRISKUSD supply/backing invariants.
- FORAGE governance voting power, delegation, and timelock authority.
- Guardian and keeper authority surfaces.
- Mainnet deployment configuration, especially production governance timings and no-broadcast dry-run behavior.

## Trust Boundaries

- Governance/timelock owns production configuration and upgrades.
- Guardian routes may tighten or freeze but must not loosen production controls.
- Keeper posts NAV and reconciles external return arrivals but cannot create custody cash.
- Executor initiates deploy/return flows but cannot self-fund returns or bypass reconciliation.
- HyperLiquid/off-chain custody is represented on-chain only by configured cold/source/chain route values and returned USDC arrival reconciliation.

## Required Invariants

- No capital deployment when stale NAV or loss-pending state makes backing unverifiable.
- Deployed USDC leaves the bridge and reaches the configured cold account.
- Returned principal/PnL can only be consumed after a matching withdrawal arrival is reconciled.
- New withdrawal intents cannot reserve or checkpoint unrelated unreconciled cash.
- PnL cannot double-fund the same recognized depositor claim.
- Upgradeable storage changes must be append-only.
- Mainnet deployment path must use production governance timings and perform no broadcast.

## Main Threats Reviewed

- Accounting drift between vault principal, NAV, returned cash, PnL, and depositor claims.
- Custodian route spoofing or mismatched source/recipient/chain selector.
- Executor-funded or keeper-forged returns.
- Stale NAV deployment that deepens loss or blocks honest exits while allowing new risk.
- UUPS storage corruption from inserted state.
- Deployment script accidentally using testnet timings or broadcasting on mainnet.
