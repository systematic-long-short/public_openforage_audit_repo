# Pattern Findings

Manual pattern review covered the standard Solidity/DeFi classes: access control, upgradeability, storage layout, unchecked external calls, reentrancy, stale oracle/NAV data, caps, custody route binding, token accounting, event/reconciliation consistency, and deployment safety.

Confirmed findings from this pass and Codex adversarial review:

| ID | Severity | Pattern | Status |
| --- | --- | --- | --- |
| H-01 | High | Custody deploy stranded USDC in bridge instead of forwarding to cold account | Fixed |
| H-02 | High | Withdrawal intents were not recipient/source/chain pinned or capped | Fixed |
| M-01 | Medium | Stale/loss-pending NAV blocked exits while still allowing deployment | Fixed |
| M-02 | Medium | Repeated PnL returns could double-fund one recognized depositor claim | Fixed |
| R2-H-01 | High | Return functions could mark arrivals consumed while still relying on executor cash | Fixed |
| R2-H-02 | High | Initial remediation inserted UUPS storage variables in existing layout | Fixed |
| R3-M-01 | Medium | Withdrawal checkpoints used reusable bridge balance and could strand later real returns | Fixed |
| R4-M-01 | Medium | New intents could checkpoint unreconciled cash that belonged to older intents | Fixed |
| R5-H-01 | High | Raw balance gating allowed unsolicited bridge dust to deny new withdrawal intents | Fixed |
| R6-H-01 | High | Principal return path bypassed vault return accounting | Fixed |
| P12-H-01 | High | Pre-existing unreconciled bridge dust could be misclassified as a new withdrawal arrival | Fixed |

Supplemental pashov-style Codex MCP review thread `019eae1e-ed33-7491-bcf3-9d7dee4e8a0b` returned `AUDIT_RESULT: PASS` with no new C/H/M/L findings. Transcript summary is retained in `pashov-supplement.md`.

No open Critical, High, Medium, or Low pattern findings remain in the current working set.
