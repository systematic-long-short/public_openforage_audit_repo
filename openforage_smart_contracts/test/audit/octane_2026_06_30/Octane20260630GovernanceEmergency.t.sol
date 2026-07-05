// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/Blocklist.sol";
import "../../../src/ForageGovernor.sol";
import "../../../src/ForageToken.sol";
import "../../helpers/ForageGovernorTestBase.sol";

contract Octane20260630GovernanceEmergencyPublicAudit001 is ForageGovernorTestBase {
    bytes32 private constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes4 private constant TIMELOCK_DELAY_BELOW_MINIMUM_SELECTOR =
        bytes4(keccak256("TimelockDelayBelowMinimum(uint256,uint256)"));
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant RAISED_DELAY = 2 days;

    struct QueuedOldTimelockBatch {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        bytes32 salt;
        address staleGuardian;
        address originalGuardianImplementation;
        address replacementGuardianImplementation;
    }

    function test_GOVEXP_governorScannerRejectsNestedDelayFloorWhilePathStaysInGovernor() public {
        bytes memory nestedDelayCut = abi.encodeCall(timelock.updateDelay, (0));
        bytes memory scheduleDelayCut = abi.encodeCall(
            timelock.schedule,
            (address(timelock), 0, nestedDelayCut, bytes32(0), keccak256("nested_delay_cut"), 0)
        );

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _singleAction(address(timelock), scheduleDelayCut, "GOV-EXP nested timelock delay cut");
        uint256 proposalId = _proposeAndPass(targets, values, calldatas, "GOV-EXP nested timelock delay cut");
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.expectRevert(
            abi.encodeWithSelector(TIMELOCK_DELAY_BELOW_MINIMUM_SELECTOR, 0, governor.MIN_TIMELOCK_DELAY())
        );
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(timelock.getMinDelay(), TIMELOCK_MIN_DELAY, "governor scanner must block nested delay cut");
        assertTrue(proposalId != 0, "proposal must be created before guarded execution");
    }

    function test_GOVEXP_governorScannerRejectsTimelockSelfProposerGrant() public {
        bytes memory grantSelfProposer =
            abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(timelock)));

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _singleAction(address(timelock), grantSelfProposer, "GOV-EXP timelock self proposer grant");
        _proposeAndPass(targets, values, calldatas, "GOV-EXP timelock self proposer grant");
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.expectRevert(ForageGovernor.TimelockSelfProposerGrant.selector);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertFalse(timelock.hasRole(PROPOSER_ROLE, address(timelock)), "self proposer grant must be blocked");
    }

    function test_GOVEXP_arbitraryProposerGrantBypassesGovernorDelayScannerAfterGrant() public {
        _executeGovernance(address(timelock), abi.encodeCall(timelock.updateDelay, (RAISED_DELAY)), "raise delay");
        assertEq(timelock.getMinDelay(), RAISED_DELAY, "setup must raise timelock delay");

        _executeGovernance(
            address(timelock), abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, attacker)), "grant attacker proposer"
        );
        assertTrue(timelock.hasRole(PROPOSER_ROLE, attacker), "governance can grant external proposer");

        bytes memory bypassDelayCut = abi.encodeCall(timelock.updateDelay, (0));
        bytes32 bypassSalt = keccak256("attacker_delay_cut");
        uint256 currentDelay = timelock.getMinDelay();

        vm.prank(attacker);
        timelock.schedule(address(timelock), 0, bypassDelayCut, bytes32(0), bypassSalt, currentDelay);
        vm.warp(block.timestamp + currentDelay + 1);
        timelock.execute(address(timelock), 0, bypassDelayCut, bytes32(0), bypassSalt);

        assertEq(timelock.getMinDelay(), 0, "external proposer bypasses governor execution scanner");
    }

    function test_GOVEXP_governorTimelockRotationRevokesOldGuardianTimelockAuthority() public {
        address oldTimelock = address(timelock);
        QueuedOldTimelockBatch memory staleBatch = _queueOldTimelockGuardianBatch();
        TimelockController replacementTimelock = _deployReplacementTimelock(RAISED_DELAY);

        _rotateGovernorTimelock(replacementTimelock);

        assertEq(address(governor.timelock()), address(replacementTimelock), "governor timelock rotates");
        assertEq(guardianModuleContract.timelock(), oldTimelock, "guardian module remains on old timelock");
        _executeAndAssertOldTimelockBatchReverts(staleBatch);
    }

    function _rotateGovernorTimelock(TimelockController replacementTimelock) private {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _singleAction(
            address(governor),
            abi.encodeWithSelector(ForageGovernor.updateTimelock.selector, address(replacementTimelock)),
            "rotate governor timelock"
        );
        _proposeAndPass(targets, values, calldatas, "rotate governor timelock");
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function _queueOldTimelockGuardianBatch() private returns (QueuedOldTimelockBatch memory batch) {
        batch.staleGuardian = makeAddr("stale-guardian-guardian");
        batch.originalGuardianImplementation = _erc1967Implementation(address(guardianModuleContract));
        batch.replacementGuardianImplementation = address(new GuardianModule());
        batch.targets = new address[](2);
        batch.targets[0] = address(guardianModuleContract);
        batch.targets[1] = address(guardianModuleContract);
        batch.values = new uint256[](2);
        batch.calldatas = new bytes[](2);
        batch.calldatas[0] = abi.encodeCall(
            GuardianModule.setGuardianPermissions,
            (batch.staleGuardian, guardianModuleContract.PERMISSION_CAN_CANCEL())
        );
        batch.calldatas[1] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", batch.replacementGuardianImplementation, bytes("")
        );

        string memory description = "pre-rotation old timelock guardian stale-guardian batch";
        bytes32 descriptionHash = keccak256(bytes(description));
        _proposeAndPass(batch.targets, batch.values, batch.calldatas, description);
        governor.queue(batch.targets, batch.values, batch.calldatas, descriptionHash);
        batch.salt = bytes20(address(governor)) ^ descriptionHash;

        bytes32 operationId =
            timelock.hashOperationBatch(batch.targets, batch.values, batch.calldatas, bytes32(0), batch.salt);
        assertTrue(timelock.isOperationReady(operationId), "old timelock batch must be queued before rotation");
    }

    function _executeAndAssertOldTimelockBatchReverts(QueuedOldTimelockBatch memory batch) private {
        assertEq(
            guardianModuleContract.guardianPermissions(batch.staleGuardian), 0, "stale guardian starts without power"
        );
        assertEq(
            _erc1967Implementation(address(guardianModuleContract)),
            batch.originalGuardianImplementation,
            "guardian implementation must not change before stale batch"
        );

        vm.expectRevert();
        timelock.executeBatch(batch.targets, batch.values, batch.calldatas, bytes32(0), batch.salt);

        assertEq(
            guardianModuleContract.guardianPermissions(batch.staleGuardian),
            0,
            "old timelock must not mutate guardian permissions after rotation"
        );
        assertEq(
            _erc1967Implementation(address(guardianModuleContract)),
            batch.originalGuardianImplementation,
            "old timelock must not authorize guardian module upgrade after rotation"
        );
    }

    function test_GOVEXP_delegateSourceVoteReadGasGrowsWithHistoricalSourceCount() public {
        (ForageToken realToken,, address treasury,,) = _deployRealTokenWithBlocklist();
        address oneDelegatee = makeAddr("one-delegatee");
        address manyDelegatee = makeAddr("many-delegatee");

        vm.warp(10_000);
        _seedDelegateSources(realToken, treasury, oneDelegatee, 1, "one");
        uint256 oneSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        uint256 oneGasStart = gasleft();
        uint256 oneVotes = realToken.getPastVotes(oneDelegatee, oneSnapshot);
        uint256 oneGas = oneGasStart - gasleft();

        vm.warp(20_000);
        _seedDelegateSources(realToken, treasury, manyDelegatee, 24, "many");
        uint256 manySnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        uint256 manyGasStart = gasleft();
        uint256 manyVotes = realToken.getPastVotes(manyDelegatee, manySnapshot);
        uint256 manyGas = manyGasStart - gasleft();

        emit log_named_uint("GOVEXP one historical delegate-source getPastVotes gas", oneGas);
        emit log_named_uint("GOVEXP 24 historical delegate-source getPastVotes gas", manyGas);

        assertEq(oneVotes, 1e18, "one delegate source should contribute one token");
        assertEq(manyVotes, 24e18, "many delegate sources should contribute all tokens");
        assertGt(manyGas, oneGas, "vote-read gas must grow with historical source count");
    }

    function test_GOVEXP_historicalBlocklistFilteringRemovesBlockedSourceVotesAtSnapshot() public {
        (ForageToken realToken, Blocklist blocklist, address treasury,, address blockGuardian) =
            _deployRealTokenWithBlocklist();
        address delegatee = makeAddr("historical-delegatee");
        address blockedSource = makeAddr("blocked-source");
        address unblockedSource = makeAddr("unblocked-source");

        vm.warp(30_000);
        _fundAndDelegate(realToken, treasury, blockedSource, delegatee, 10e18);
        _fundAndDelegate(realToken, treasury, unblockedSource, delegatee, 20e18);
        uint256 beforeBlockSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        assertEq(realToken.getPastVotes(delegatee, beforeBlockSnapshot), 30e18, "pre-block snapshot has both sources");

        vm.prank(blockGuardian);
        blocklist.blockAddress(blockedSource);
        uint256 blockedSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);

        assertEq(
            realToken.getPastVotes(delegatee, blockedSnapshot),
            20e18,
            "historical blocklist filtering must remove blocked source votes"
        );
    }

    function _executeGovernance(address target, bytes memory data, string memory label) private {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _singleAction(target, data, label);
        _proposeAndPass(targets, values, calldatas, label);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function _proposeAndPass(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
        _passProposal(proposalId);
    }

    function _singleAction(address target, bytes memory data, string memory description)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = target;
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = data;
        descriptionHash = keccak256(bytes(description));
    }

    function _deployReplacementTimelock(uint256 minDelay) private returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = address(governor);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        return new TimelockController(minDelay, proposers, executors, address(0));
    }

    function _deployRealTokenWithBlocklist()
        private
        returns (ForageToken realToken, Blocklist blocklist, address treasury, address owner, address blockGuardian)
    {
        address team = makeAddr("real-token-team");
        treasury = makeAddr("real-token-treasury");
        owner = makeAddr("real-token-owner");
        blockGuardian = makeAddr("real-block-guardian");

        ForageToken tokenImplementation = new ForageToken();
        bytes memory tokenInit = abi.encodeCall(ForageToken.initialize, (team, treasury, owner));
        realToken = ForageToken(address(new ERC1967Proxy(address(tokenImplementation), tokenInit)));

        Blocklist blocklistImplementation = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (blockGuardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImplementation), blocklistInit)));

        vm.prank(owner);
        realToken.setBlocklist(address(blocklist));
    }

    function _seedDelegateSources(
        ForageToken realToken,
        address treasury,
        address delegatee,
        uint256 count,
        string memory namespace
    ) private {
        for (uint256 i; i < count; ++i) {
            address source = makeAddr(string.concat(namespace, "-", vm.toString(i)));
            _fundAndDelegate(realToken, treasury, source, delegatee, 1e18);
        }
    }

    function _fundAndDelegate(
        ForageToken realToken,
        address treasury,
        address source,
        address delegatee,
        uint256 amount
    ) private {
        vm.prank(treasury);
        realToken.transfer(source, amount);
        vm.prank(source);
        realToken.delegate(delegatee);
    }

    function _erc1967Implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }
}
