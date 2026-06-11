// Materialized from documentation/smart_contract_audits/2026-05-30-cantina-audit/openforage_audit_repo — Scan #4 — findings.md lines 2549-2644.
// Original audit path: test/POC_ForageGovernor.attack_5826f8cb.t.sol. Finding: OPEN-68 (Medium).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForageGovernor} from "../../../src/ForageGovernor.sol";
import {GuardianModule} from "../../../src/GuardianModule.sol";
import {CantinaScan4RealGovernanceTestBase} from "./CantinaScan4RealGovernanceTestBase.sol";

/**
 * @title Fix-proof: Batched self-targeted guardian spam remains cancelable
 * @notice Proof Statement: Proves that a guardian with `PERMISSION_CAN_PROPOSE`
 * cannot make a batch uncancelable by including one guardian-removal action for
 * each cancel-capable guardian. Guardian-proposed spam must remain cancelable by
 * the cancel guardian set even when one action targets the cancel caller.
 */
contract POC_ForageGovernorAttack_5826f8cb is CantinaScan4RealGovernanceTestBase {
    function test_fix_batchedGuardianTargetsRemainCancelableByCancelGuardians() public {
        assertEq(token.balanceOf(guardian1), 0, "guardian proposer should have no voting power");
        assertTrue(
            guardianModuleContract.hasPermission(guardian1, guardianModuleContract.PERMISSION_CAN_PROPOSE()),
            "guardian1 should bypass threshold as proposer guardian"
        );
        assertTrue(
            guardianModuleContract.hasPermission(guardian1, guardianModuleContract.PERMISSION_CAN_CANCEL()),
            "guardian1 should also be a cancel guardian"
        );
        assertTrue(
            guardianModuleContract.hasPermission(guardian3, guardianModuleContract.PERMISSION_CAN_CANCEL()),
            "guardian3 should be a second cancel guardian"
        );

        uint256 firstProposalId = _proposeUncancelableBatch("uncancelable-batch-0");
        assertEq(governor.proposalProposer(firstProposalId), guardian1, "guardian proposer should own the proposal");

        vm.prank(guardian1);
        guardianModuleContract.guardianCancel(firstProposalId);
        assertEq(governor.activeProposalCount(), 0, "proposer guardian cancel should clear its own spam batch");

        uint256 secondProposalId = _proposeUncancelableBatch("uncancelable-batch-1");

        vm.prank(guardian3);
        guardianModuleContract.guardianCancel(secondProposalId);
        assertEq(governor.activeProposalCount(), 0, "other cancel guardian should clear the spam batch");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposal();

        vm.prank(proposer);
        uint256 honestProposalId = governor.propose(targets, values, calldatas, "honest-proposal-not-blocked");
        assertEq(governor.proposalProposer(honestProposalId), proposer, "honest proposal remains available");
    }

    function _proposeUncancelableBatch(string memory description) internal returns (uint256) {
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory calldatas = new bytes[](3);

        targets[0] = address(guardianModuleContract);
        calldatas[0] = abi.encodeCall(GuardianModule.removeGuardian, (guardian1));

        targets[1] = address(guardianModuleContract);
        calldatas[1] = abi.encodeCall(GuardianModule.removeGuardian, (guardian3));

        targets[2] = address(governor);
        calldatas[2] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (DEFAULT_MAX_ACTIVE));

        vm.prank(guardian1);
        return governor.propose(targets, values, calldatas, description);
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
