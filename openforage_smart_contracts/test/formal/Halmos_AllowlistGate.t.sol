// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Allowlist} from "../../src/Allowlist.sol";
import {atRISKUSD} from "../../src/atRISKUSD.sol";
import {ForageGovernor} from "../../src/ForageGovernor.sol";
import {ForageToken} from "../../src/ForageToken.sol";
import {FORAGETreasury} from "../../src/FORAGETreasury.sol";
import {RISKUSD} from "../../src/RISKUSD.sol";
import {RISKUSDVault} from "../../src/RISKUSDVault.sol";
import {StakingQueue} from "../../src/StakingQueue.sol";
import {RISKUSDVaultModule} from "../../src/modules/RISKUSDVaultModule.sol";
import {StakingQueueModule} from "../../src/modules/StakingQueueModule.sol";
import {IAllowlist} from "../../src/interfaces/IAllowlist.sol";
import {AllowlistHarness} from "../helpers/AllowlistHarness.sol";
import {MockVaultRegistry} from "../mocks/MockVaultRegistry.sol";

/// @dev Minimal 6-decimal mint/burn ERC20 for the bounded Halmos model.
contract HalmosGateERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Halmos caller-gate harness (KYC-01 / DEC-1074).
/// @notice Proves, for a named representative set of gated entry points on the five
///         subject contracts, that a symbolic caller that is neither approved nor a
///         system account reverts `CallerNotAllowed` before any state write, that the
///         exempt ERC-20 selectors of the three tokens are not gate-checked, and that
///         the gate still admits the approved concrete investor.
contract Halmos_AllowlistGate is Test, SymTest {
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040_f15088dc2f81fe39_1c3923bec73e23a9_662efc9c229c6a00;
    uint256 internal constant MAX_AMOUNT = 1e6;
    uint256 internal constant FUNDING = 1e6;
    uint256 internal constant DEPOSIT_AMOUNT = 1e5;
    uint256 internal constant QUEUE_AMOUNT = 1e5;

    Allowlist internal allowlist;
    HalmosGateERC20 internal usdc;
    RISKUSD internal riskusd;
    atRISKUSD internal atRisk;
    ForageToken internal forage;
    RISKUSDVault internal vault;
    StakingQueue internal queue;
    FORAGETreasury internal treasury;
    ForageGovernor internal governor;
    MockVaultRegistry internal registry;

    address internal investor;
    address internal timelock;
    uint256 internal proposalId;

    function setUp() public {
        investor = address(uint160(0xA11CE));
        timelock = address(uint160(0x71BE11));

        allowlist = Allowlist(AllowlistHarness.deploy(address(this), address(this)));

        usdc = new HalmosGateERC20("USD Coin", "USDC");
        registry = new MockVaultRegistry();

        riskusd = new RISKUSD();
        _resetInitializable(address(riskusd));
        forage = new ForageToken();
        _resetInitializable(address(forage));
        treasury = new FORAGETreasury();
        _resetInitializable(address(treasury));
        queue = new StakingQueue();
        _resetInitializable(address(queue));
        atRisk = new atRISKUSD();
        _resetInitializable(address(atRisk));
        vault = new RISKUSDVault();
        _resetInitializable(address(vault));
        governor = new ForageGovernor();
        _resetInitializable(address(governor));

        riskusd.initialize(address(this));
        treasury.initialize(address(forage), investor);
        forage.initialize(investor, address(treasury), address(this));
        atRisk.initialize(address(riskusd), address(registry), address(queue), 0, 0, 0, "0D", address(this));

        address[4] memory tierVaults = [address(atRisk), address(atRisk), address(atRisk), address(atRisk)];
        queue.initialize(address(riskusd), address(forage), tierVaults, address(registry), address(this));
        vault.initialize(address(usdc), address(riskusd), address(this));
        vault.setVaultModule(address(new RISKUSDVaultModule()));
        queue.setQueueModule(address(new StakingQueueModule()));
        governor.initialize(address(forage), timelock, 0, 3600, 1, 1, address(0));

        registry.setTestRISKUSDVault(address(vault));
        uint256[4] memory lockups;
        uint16[4] memory yieldBps;
        uint16[4] memory fundingBps;
        registry.addTestVault("Gate Vault", "GV", tierVaults, address(queue), 10_000_000e6, lockups, yieldBps, fundingBps);

        address[] memory systemAccounts = new address[](9);
        systemAccounts[0] = address(this);
        systemAccounts[1] = address(riskusd);
        systemAccounts[2] = address(forage);
        systemAccounts[3] = address(atRisk);
        systemAccounts[4] = address(vault);
        systemAccounts[5] = address(queue);
        systemAccounts[6] = address(treasury);
        systemAccounts[7] = address(governor);
        systemAccounts[8] = address(registry);
        AllowlistHarness.setSystemAccounts(address(allowlist), systemAccounts);

        address[] memory investors = new address[](1);
        investors[0] = investor;
        AllowlistHarness.approveActors(address(allowlist), investors);

        riskusd.setAllowlist(address(allowlist));
        forage.setAllowlist(address(allowlist));
        atRisk.setAllowlist(address(allowlist));
        vault.setAllowlist(address(allowlist));
        queue.setAllowlist(address(allowlist));
        vm.prank(investor);
        treasury.setAllowlist(address(allowlist));
        vm.prank(timelock);
        governor.setAllowlist(address(allowlist));

        riskusd.setMinter(address(vault));
        vm.warp(block.timestamp + 3 days);
        riskusd.finalizeMinter();

        queue.setVaultId(1);

        usdc.mint(investor, FUNDING);
        vm.startPrank(investor);
        usdc.approve(address(vault), FUNDING);
        vault.deposit(FUNDING);
        riskusd.approve(address(queue), FUNDING);
        vm.stopPrank();

        vm.prank(investor);
        forage.delegate(investor);
        vm.warp(block.timestamp + 1);
        proposalId = _propose();
    }

    // --- Gate checks: symbolic unapproved caller always hits CallerNotAllowed ---

    function check_riskusdVault_deposit_revertsForUnapprovedCaller(address actor, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.deposit, (amount)));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_redeem_revertsForUnapprovedCaller(address actor, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.redeem, (amount)));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_deployCapital_revertsForUnapprovedCaller(address actor, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.deployCapital, (amount)));
        _assertBlockedByGate(ok, ret);
    }

    function check_stakingQueue_joinQueue_revertsForUnapprovedCaller(address actor, uint256 amount, uint8 tier)
        public
    {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(queue).call(abi.encodeCall(StakingQueue.joinQueue, (amount, tier)));
        _assertBlockedByGate(ok, ret);
    }

    function check_forageToken_delegate_revertsForUnapprovedCaller(address actor, address delegatee) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(forage).call(abi.encodeCall(ForageToken.delegate, (delegatee)));
        _assertBlockedByGate(ok, ret);
    }

    function check_forageToken_burn_revertsForUnapprovedCaller(address actor, address from, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(forage).call(abi.encodeCall(ForageToken.burn, (from, amount)));
        _assertBlockedByGate(ok, ret);
    }

    function check_forageTreasury_publishAgentRoot_revertsForUnapprovedCaller(
        address actor,
        uint256 roundId,
        bytes32 root,
        uint256 totalAmount,
        uint64 deadline
    ) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(treasury).call(abi.encodeCall(FORAGETreasury.publishAgentRoot, (roundId, root, totalAmount, deadline)));
        _assertBlockedByGate(ok, ret);
    }

    function check_forageTreasury_sweepExpiredAgentRound_revertsForUnapprovedCaller(
        address actor,
        uint256 roundId,
        address recipient
    ) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(treasury).call(abi.encodeCall(FORAGETreasury.sweepExpiredAgentRound, (roundId, recipient)));
        _assertBlockedByGate(ok, ret);
    }

    function check_forageGovernor_cancel_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        address[] memory targets = new address[](1);
        targets[0] = address(treasury);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(governor).call(abi.encodeCall(ForageGovernor.cancel, (targets, values, calldatas, bytes32(0))));
        _assertBlockedByGate(ok, ret);
    }

    function check_forageGovernor_castVote_revertsForUnapprovedCaller(address actor, uint256 proposalId_, uint8 support)
        public
    {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(governor).call(abi.encodeCall(ForageGovernor.castVote, (proposalId_, support)));
        _assertBlockedByGate(ok, ret);
    }

    // --- Moved-selector gate checks: the forwarder blocks the caller before any delegatecall ---

    function check_riskusdVault_pause_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.pause, ()));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_unpause_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.unpause, ()));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_setBlocklist_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(RISKUSDVault.setBlocklist, (address(0xBEEF))));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_setDailyMintCapBps_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.setDailyMintCapBps, (uint256(1))));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_setDailyRedemptionCapBps_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(RISKUSDVault.setDailyRedemptionCapBps, (uint256(1))));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_burnForLoss_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(RISKUSDVault.burnForLoss, (uint256(0), uint256(1))));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_replenish_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(RISKUSDVault.replenish, (uint256(1))));
        _assertBlockedByGate(ok, ret);
    }

    function check_riskusdVault_recordCustodianNAV_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("recordCustodianNAV(uint256,uint256,uint256)", uint256(0), uint256(0), uint256(0))
        );
        _assertBlockedByGate(ok, ret);
    }

    function check_stakingQueue_joinQueueWithBounds_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(queue).call(
            abi.encodeCall(
                StakingQueue.joinQueueWithBounds, (uint256(1), uint8(0), uint256(1), uint256(block.timestamp + 1))
            )
        );
        _assertBlockedByGate(ok, ret);
    }

    function check_stakingQueue_cancelQueue_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(queue).call(abi.encodeCall(StakingQueue.cancelQueue, (uint256(0))));
        _assertBlockedByGate(ok, ret);
    }

    function check_stakingQueue_processQueue_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(queue).call(abi.encodeCall(StakingQueue.processQueue, (uint8(0), uint256(1))));
        _assertBlockedByGate(ok, ret);
    }

    function check_stakingQueue_processExpiredLockups_revertsForUnapprovedCaller(address actor) public {
        _assumeUnapproved(actor);
        address[] memory depositors = new address[](1);
        depositors[0] = actor;
        vm.prank(actor);
        (bool ok, bytes memory ret) =
            address(queue).call(abi.encodeCall(StakingQueue.processExpiredLockups, (depositors, uint8(1))));
        _assertBlockedByGate(ok, ret);
    }

    // --- Exempt selectors: never CallerNotAllowed for an unapproved, funded actor ---

    function check_riskusd_transfer_notGatedByAllowlist(address actor, address to, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.assume(to != address(0));
        amount = _boundedAmount(amount);
        _fundRiskusd(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(riskusd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        _assertNotGated(ok, ret);
    }

    function check_riskusd_approve_notGatedByAllowlist(address actor, address spender, uint256 amount) public {
        _assumeUnapproved(actor);
        amount = _boundedAmount(amount);
        _fundRiskusd(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(riskusd).call(abi.encodeCall(RISKUSD.approve, (spender, amount)));
        _assertNotGated(ok, ret);
    }

    function check_riskusd_transferFrom_notGatedByAllowlist(address actor, address from, address to, uint256 amount)
        public
    {
        _assumeUnapproved(actor);
        vm.assume(from != address(0));
        vm.assume(to != address(0));
        amount = _boundedAmount(amount);
        _fundRiskusd(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(riskusd).call(abi.encodeCall(RISKUSD.transferFrom, (from, to, amount)));
        _assertNotGated(ok, ret);
    }

    function check_atRISKUSD_transfer_notGatedByAllowlist(address actor, address to, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.assume(to != address(0));
        amount = _boundedAmount(amount);
        _fundAtRisk(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(atRisk).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        _assertNotGated(ok, ret);
    }

    function check_atRISKUSD_approve_notGatedByAllowlist(address actor, address spender, uint256 amount) public {
        _assumeUnapproved(actor);
        amount = _boundedAmount(amount);
        _fundAtRisk(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(atRisk).call(abi.encodeCall(atRISKUSD.approve, (spender, amount)));
        _assertNotGated(ok, ret);
    }

    function check_atRISKUSD_transferFrom_notGatedByAllowlist(address actor, address from, address to, uint256 amount)
        public
    {
        _assumeUnapproved(actor);
        vm.assume(from != address(0));
        vm.assume(to != address(0));
        amount = _boundedAmount(amount);
        _fundAtRisk(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(atRisk).call(abi.encodeCall(atRISKUSD.transferFrom, (from, to, amount)));
        _assertNotGated(ok, ret);
    }

    function check_forageToken_transfer_notGatedByAllowlist(address actor, address to, uint256 amount) public {
        _assumeUnapproved(actor);
        vm.assume(to != address(0));
        amount = _boundedAmount(amount);
        _fundForage(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(forage).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        _assertNotGated(ok, ret);
    }

    function check_forageToken_approve_notGatedByAllowlist(address actor, address spender, uint256 amount) public {
        _assumeUnapproved(actor);
        amount = _boundedAmount(amount);
        _fundForage(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(forage).call(abi.encodeCall(ForageToken.approve, (spender, amount)));
        _assertNotGated(ok, ret);
    }

    function check_forageToken_transferFrom_notGatedByAllowlist(address actor, address from, address to, uint256 amount)
        public
    {
        _assumeUnapproved(actor);
        vm.assume(from != address(0));
        vm.assume(to != address(0));
        amount = _boundedAmount(amount);
        _fundForage(actor, amount);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(forage).call(abi.encodeCall(ForageToken.transferFrom, (from, to, amount)));
        _assertNotGated(ok, ret);
    }

    // --- Positive controls: the approved concrete investor passes the gate ---

    function check_riskusdVault_deposit_allowsApprovedCaller() public {
        vm.roll(block.number + 1);
        usdc.mint(investor, DEPOSIT_AMOUNT);
        vm.prank(investor);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vm.prank(investor);
        vault.deposit(DEPOSIT_AMOUNT);
    }

    function check_stakingQueue_joinQueue_allowsApprovedCaller() public {
        vm.prank(investor);
        queue.joinQueue(QUEUE_AMOUNT, 0);
    }

    function check_forageToken_delegate_allowsApprovedCaller() public {
        vm.prank(investor);
        forage.delegate(investor);
    }

    function check_forageTreasury_publishAgentRoot_allowsApprovedCaller() public {
        vm.prank(investor);
        treasury.publishAgentRoot(1, bytes32(uint256(1)), 1, uint64(block.timestamp + 1 days));
    }

    function check_forageGovernor_castVote_allowsApprovedCaller() public {
        vm.warp(block.timestamp + 1);
        vm.prank(investor);
        governor.castVote(proposalId, 2);
    }

    // --- Helpers ---

    function _resetInitializable(address target) internal {
        vm.store(target, INITIALIZABLE_STORAGE_SLOT, bytes32(0));
    }

    function _propose() internal returns (uint256) {
        address[] memory targets = new address[](1);
        targets[0] = address(treasury);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        vm.prank(investor);
        return governor.propose(targets, values, calldatas, "gate positive control");
    }

    function _assumeUnapproved(address actor) internal view {
        vm.assume(actor != address(0));
        vm.assume(!allowlist.isAllowed(actor));
        vm.assume(!allowlist.isSystemAccount(actor));
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4 selector) {
        if (ret.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(ret, 0x20))
        }
    }

    function _assertBlockedByGate(bool ok, bytes memory ret) internal pure {
        assert(!ok);
        assert(_selectorOf(ret) == IAllowlist.CallerNotAllowed.selector);
    }

    function _assertNotGated(bool ok, bytes memory ret) internal pure {
        assert(ok || _selectorOf(ret) != IAllowlist.CallerNotAllowed.selector);
    }

    function _boundedAmount(uint256 amount) internal pure returns (uint256) {
        return 1 + (amount % MAX_AMOUNT);
    }

    function _fundRiskusd(address actor, uint256 amount) internal {
        vm.prank(investor);
        riskusd.transfer(actor, amount);
    }

    function _fundForage(address actor, uint256 amount) internal {
        vm.prank(investor);
        forage.transfer(actor, amount);
    }

    function _fundAtRisk(address actor, uint256 amount) internal {
        vm.prank(investor);
        riskusd.transfer(address(queue), amount);
        vm.prank(address(queue));
        riskusd.approve(address(atRisk), amount);
        vm.prank(address(queue));
        atRisk.deposit(amount, actor);
    }
}
