// Materialized from documentation/smart_contract_audits/2026-05-30-cantina-audit/openforage_audit_repo — Scan #4 — findings.md lines 1918-2005.
// Original audit path: test/audit/POC_TimelockDirectScheduleBypass_a646ac1c.t.sol. Finding: OPEN-67 (Medium).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import {ForageGovernor} from "../../../src/ForageGovernor.sol";
import {CantinaScan4RealGovernanceTestBase} from "./CantinaScan4RealGovernanceTestBase.sol";

contract POC_TimelockDirectScheduleBypass_a646ac1c is CantinaScan4RealGovernanceTestBase {
    bytes4 internal constant TIMELOCK_SELF_PROPOSER_GRANT_SELECTOR = bytes4(keccak256("TimelockSelfProposerGrant()"));

    /**
     * @notice Fix Statement: A successful governance proposal cannot directly grant the timelock
     * its own `PROPOSER_ROLE` and then call the timelock's `schedule()` entrypoint to queue
     * `updateDelay(0)`. The direct-timelock path must be scanned before the timelock executes
     * the proposal batch.
     */
    function test_fix_directTimelockScheduleUpdateDelayBelowFloorReverts() public {
        bytes32 proposerRole = keccak256("PROPOSER_ROLE");
        uint256 productionDelay = PRODUCTION_TIMELOCK_DELAY;

        assertEq(governor.MIN_TIMELOCK_DELAY(), 1 days, "fixture expects a one-day floor");
        assertEq(timelock.getMinDelay(), TIMELOCK_MIN_DELAY, "fixture starts in launch phase");
        assertFalse(timelock.hasRole(proposerRole, address(timelock)), "timelock should not start as proposer");

        _setTimelockDelayViaGovernance(productionDelay);
        assertEq(timelock.getMinDelay(), productionDelay, "setup must raise the live timelock delay");

        bytes32 nestedSalt = keccak256("poc_nested_update_delay_zero");
        bytes memory lowerDelayCall = abi.encodeCall(timelock.updateDelay, (0));
        bytes32 nestedOpId = timelock.hashOperation(address(timelock), 0, lowerDelayCall, bytes32(0), nestedSalt);

        address[] memory targets = new address[](2);
        targets[0] = address(timelock);
        targets[1] = address(timelock);

        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeCall(timelock.grantRole, (proposerRole, address(timelock)));
        calldatas[1] = abi.encodeCall(
            timelock.schedule, (address(timelock), 0, lowerDelayCall, bytes32(0), nestedSalt, productionDelay)
        );

        string memory description = "POC: direct timelock schedule bypasses updateDelay floor";
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + productionDelay + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.TimelockDelayBelowMinimum.selector, 0, governor.MIN_TIMELOCK_DELAY())
        );
        governor.execute(targets, values, calldatas, descriptionHash);

        assertFalse(timelock.hasRole(proposerRole, address(timelock)), "proposal must not self-grant proposer role");
        assertEq(timelock.getMinDelay(), productionDelay, "delay remains at production floor");
        assertEq(
            uint256(timelock.getOperationState(nestedOpId)),
            uint256(TimelockController.OperationState.Unset),
            "nested updateDelay(0) must not be queued"
        );
    }

    function test_fix_directTimelockScheduleBatchUpdateDelayBelowFloorReverts() public {
        bytes32 proposerRole = keccak256("PROPOSER_ROLE");
        uint256 productionDelay = PRODUCTION_TIMELOCK_DELAY;

        _setTimelockDelayViaGovernance(productionDelay);

        bytes32 nestedSalt = keccak256("poc_nested_batch_update_delay_zero");
        bytes memory lowerDelayCall = abi.encodeCall(timelock.updateDelay, (0));
        (bytes memory nestedScheduleBatchCall, bytes32 nestedOpId) =
            _singleUpdateDelayScheduleBatchCall(lowerDelayCall, nestedSalt, productionDelay);

        address[] memory targets = new address[](2);
        targets[0] = address(timelock);
        targets[1] = address(timelock);

        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeCall(timelock.grantRole, (proposerRole, address(timelock)));
        calldatas[1] = nestedScheduleBatchCall;

        string memory description = "FIX: direct timelock scheduleBatch rejects updateDelay below floor";
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + productionDelay + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.TimelockDelayBelowMinimum.selector, 0, governor.MIN_TIMELOCK_DELAY())
        );
        governor.execute(targets, values, calldatas, descriptionHash);

        assertFalse(timelock.hasRole(proposerRole, address(timelock)), "proposal must not self-grant proposer role");
        assertEq(
            uint256(timelock.getOperationState(nestedOpId)),
            uint256(TimelockController.OperationState.Unset),
            "nested batch updateDelay(0) must not be queued"
        );
    }

    function test_fix_timelockCannotSelfGrantProposerRoleDirectly() public {
        bytes32 proposerRole = keccak256("PROPOSER_ROLE");
        uint256 productionDelay = PRODUCTION_TIMELOCK_DELAY;

        _setTimelockDelayViaGovernance(productionDelay);

        address[] memory targets = new address[](1);
        targets[0] = address(timelock);

        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(timelock.grantRole, (proposerRole, address(timelock)));

        string memory description = "FIX: timelock cannot self-grant proposer role";
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = _createProposalWithParams(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + productionDelay + 1);
        vm.expectRevert(abi.encodeWithSelector(TIMELOCK_SELF_PROPOSER_GRANT_SELECTOR));
        governor.execute(targets, values, calldatas, descriptionHash);

        assertFalse(timelock.hasRole(proposerRole, address(timelock)), "timelock must not become its own proposer");
    }

    function _singleUpdateDelayScheduleBatchCall(
        bytes memory lowerDelayCall,
        bytes32 nestedSalt,
        uint256 productionDelay
    ) internal view returns (bytes memory scheduleBatchCall, bytes32 nestedOpId) {
        address[] memory scheduledTargets = new address[](1);
        scheduledTargets[0] = address(timelock);
        uint256[] memory scheduledValues = new uint256[](1);
        bytes[] memory scheduledPayloads = new bytes[](1);
        scheduledPayloads[0] = lowerDelayCall;

        nestedOpId =
            timelock.hashOperationBatch(scheduledTargets, scheduledValues, scheduledPayloads, bytes32(0), nestedSalt);
        scheduleBatchCall = abi.encodeCall(
            timelock.scheduleBatch,
            (scheduledTargets, scheduledValues, scheduledPayloads, bytes32(0), nestedSalt, productionDelay)
        );
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
