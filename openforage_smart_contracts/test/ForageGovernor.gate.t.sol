// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";
import "./mocks/MockAllowlist.sol";
import "../src/Allowlist.sol";
import "../src/interfaces/IAllowlist.sol";

contract ForageGovernorGateTest is ForageGovernorTestBase {
    function test_gate_unverifiedProposeRevertsCallerNotAllowed() public {
        allowlistMock.setAllAllowed(false);
        address caller = makeAddr("gateUnverifiedCaller");

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposalParams();

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        vm.prank(caller);
        governor.propose(targets, values, calldatas, "gate: unverified proposer");

        allowlistMock.setAllAllowed(true);
        vm.prank(deployer);
        token.transfer(caller, PROPOSER_TOKENS);
        vm.prank(caller);
        token.delegate(caller);
        vm.roll(block.number + 1);

        vm.prank(caller);
        uint256 proposalId = governor.propose(targets, values, calldatas, "gate: allowed proposer");
        assertTrue(proposalId != 0, "allowlisted proposer must succeed");
    }

    function test_gate_unverifiedCastVoteRevertsCallerNotAllowed() public {
        uint256 proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);

        allowlistMock.setAllowed(voter1, false);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, voter1));
        vm.prank(voter1);
        governor.castVote(proposalId, 1);
    }

    function test_gate_setAllowlistOnlyExecutor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        governor.setAllowlist(address(allowlistMock));

        MockAllowlist replacement = new MockAllowlist();
        vm.prank(address(timelock));
        governor.setAllowlist(address(replacement));
        assertEq(governor.allowlist(), address(replacement), "timelock must be able to replace the allowlist");
    }

    function test_gate_bySigVotingDisabled() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposalParams();
        uint256 proposalId = governor.hashProposal(targets, values, calldatas, keccak256(bytes("gate: by-sig")));

        vm.expectRevert(ForageGovernor.SignatureVotingDisabled.selector);
        governor.castVoteBySig(proposalId, 1, voter1, "");

        vm.expectRevert(ForageGovernor.SignatureVotingDisabled.selector);
        governor.castVoteWithReasonAndParamsBySig(proposalId, 1, voter1, "reason", "", "");
    }

    function test_gate_unverifiedSetProposalThresholdRevertsCallerNotAllowed() public {
        allowlistMock.setAllowed(attacker, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        vm.prank(attacker);
        governor.setProposalThreshold(1);
    }

    function test_gate_unverifiedOnERC721ReceivedRevertsCallerNotAllowed() public {
        allowlistMock.setAllowed(attacker, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        vm.prank(attacker);
        governor.onERC721Received(address(0), address(0), 1, "");
    }

    function test_gate_unverifiedOnERC1155ReceivedRevertsCallerNotAllowed() public {
        allowlistMock.setAllowed(attacker, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        vm.prank(attacker);
        governor.onERC1155Received(address(0), address(0), 1, 1, "");
    }

    function test_gate_unverifiedOnERC1155BatchReceivedRevertsCallerNotAllowed() public {
        allowlistMock.setAllowed(attacker, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory values = new uint256[](1);
        values[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        vm.prank(attacker);
        governor.onERC1155BatchReceived(address(0), address(0), ids, values, "");
    }

    function test_gate_timelockSystemAccountExecutesSetProposalThreshold() public {
        Allowlist registryImpl = new Allowlist();
        Allowlist registry = Allowlist(
            address(
                new ERC1967Proxy(
                    address(registryImpl),
                    abi.encodeCall(Allowlist.initialize, (deployer, deployer, uint64(registryImpl.FINALIZE_DELAY())))
                )
            )
        );

        vm.startPrank(deployer);
        registry.setSystemAccount(address(timelock), true);
        registry.setSystemAccount(proposer, true);
        registry.setSystemAccount(voter1, true);
        registry.setSystemAccount(address(this), true);
        vm.stopPrank();

        vm.prank(address(timelock));
        governor.setAllowlist(address(registry));

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setProposalThreshold, (200));
        string memory description = "gate: timelock executes setProposalThreshold";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter1);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        vm.expectEmit(address(governor));
        emit GovernorSettingsUpgradeable.ProposalThresholdSet(0, 200);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed), "proposal must execute");
    }
}
