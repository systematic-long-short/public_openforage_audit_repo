// Materialized from documentation/smart_contract_audits/2026-05-30-cantina-audit/openforage_audit_repo — Scan #4 — findings.md lines 2103-2164.
// Original audit path: test/POC_ForageGovernorProtectedSlotMonopoly_e2850162.t.sol. Finding: OPEN-62 (Medium).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForageGovernor} from "../../../src/ForageGovernor.sol";
import {GuardianModule} from "../../../src/GuardianModule.sol";
import {CantinaScan4RealGovernanceTestBase} from "./CantinaScan4RealGovernanceTestBase.sol";

interface ExpectedGuardianProposalQuota {
    error GuardianActiveProposalQuotaReached(address guardian, uint256 active, uint256 maximum);
}

/**
 * @title Fix-proof: Protected guardian-mutation spam is cancelable and quota-limited
 * @notice Proof Statement: Proves that a guardian with zero voting power but `PERMISSION_CAN_PROPOSE`
 * cannot monopolize governance slots with `GuardianModule.setPausableTarget` proposals, because a
 * different cancel-capable guardian can clear guardian-proposed protected-mutation spam and the
 * guardian proposer is limited to one active proposal.
 */
contract POC_ForageGovernorProtectedSlotMonopoly_e2850162 is CantinaScan4RealGovernanceTestBase {
    function test_fix_guardianProtectedSpamCancelableAndQuotaLimited() public {
        assertEq(token.balanceOf(guardian1), 0, "guardian proposer should have zero voting tokens");

        address[] memory spamTargets = new address[](1);
        spamTargets[0] = address(guardianModuleContract);
        uint256[] memory spamValues = new uint256[](1);
        spamValues[0] = 0;
        bytes[] memory spamCalldatas = new bytes[](1);
        spamCalldatas[0] = abi.encodeCall(GuardianModule.setPausableTarget, (address(token), true));

        vm.prank(guardian1);
        uint256 firstProposalId = governor.propose(spamTargets, spamValues, spamCalldatas, "protected-spam-0");
        assertEq(governor.activeProposalCount(), 1, "first guardian spam consumes one active slot");
        assertEq(governor.proposalProposer(firstProposalId), guardian1, "guardian bypass should create proposals");

        vm.prank(guardian3);
        guardianModuleContract.guardianCancel(firstProposalId);
        assertEq(governor.activeProposalCount(), 0, "cancel guardian should clear protected guardian-proposed spam");

        vm.prank(guardian1);
        governor.propose(spamTargets, spamValues, spamCalldatas, "protected-spam-quota-0");

        vm.expectRevert(
            abi.encodeWithSelector(
                ExpectedGuardianProposalQuota.GuardianActiveProposalQuotaReached.selector, guardian1, 1, 1
            )
        );
        vm.prank(guardian1);
        governor.propose(spamTargets, spamValues, spamCalldatas, "protected-spam-quota-1");

        address[] memory recoveryTargets = new address[](1);
        recoveryTargets[0] = address(guardianModuleContract);
        uint256[] memory recoveryValues = new uint256[](1);
        recoveryValues[0] = 0;
        bytes[] memory recoveryCalldatas = new bytes[](1);
        recoveryCalldatas[0] = abi.encodeCall(GuardianModule.removeGuardian, (guardian1));

        vm.prank(proposer);
        uint256 recoveryProposalId =
            governor.propose(recoveryTargets, recoveryValues, recoveryCalldatas, "remove compromised guardian");
        assertEq(governor.proposalProposer(recoveryProposalId), proposer, "threshold proposer keeps recovery access");
    }
}
