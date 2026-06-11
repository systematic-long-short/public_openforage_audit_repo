// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";

// ============================================================
// TC-01: Initialization
// Requirements: R-01, R-02, R-03, R-04, R-05, R-06, R-07,
//               R-08, R-09, R-10, R-11, R-12
// ============================================================
contract ForageGovernor_TC01_Initialization is ForageGovernorTestBase {
    /// @dev Happy path: Governor name is "ForageGovernor" (R-06)
    function test_TC01_initializeSetsGovernorName() public view {
        assertEq(governor.name(), "ForageGovernor", "Governor name must be ForageGovernor");
    }

    /// @dev Happy path: votingDelay set correctly (R-06)
    function test_TC01_initializeSetsVotingDelay() public view {
        assertEq(governor.votingDelay(), DEFAULT_VOTING_DELAY, "votingDelay must match init param");
    }

    /// @dev Happy path: votingPeriod set correctly (R-06)
    function test_TC01_initializeSetsVotingPeriod() public view {
        assertEq(governor.votingPeriod(), DEFAULT_VOTING_PERIOD, "votingPeriod must match init param");
    }

    /// @dev Happy path: quorum computed from quorumBps (R-33, R-06)
    function test_TC01_initializeSetsQuorum() public view {
        uint256 expectedQuorum = TOTAL_SUPPLY * DEFAULT_QUORUM_BPS / 10_000;
        assertEq(governor.quorum(block.number - 1), expectedQuorum, "quorum must equal 4% of total supply");
    }

    /// @dev Happy path: proposalThreshold computed from proposalThresholdBps (R-06)
    function test_TC01_initializeSetsProposalThreshold() public view {
        uint256 expectedThreshold = TOTAL_SUPPLY * DEFAULT_THRESHOLD_BPS / 10_000;
        assertEq(governor.proposalThreshold(), expectedThreshold, "proposalThreshold must equal 1% of total supply");
    }

    /// @dev Happy path: token address set correctly
    function test_TC01_initializeSetsToken() public view {
        assertEq(address(governor.token()), address(token), "token must be MockForageTokenVotes");
    }

    /// @dev Happy path: maxActiveProposals defaults to 10 (R-12)
    function test_TC01_initializeSetsMaxActiveProposals() public view {
        assertEq(governor.maxActiveProposals(), DEFAULT_MAX_ACTIVE, "maxActiveProposals must be 10 after init");
        assertEq(governor.activeProposalCount(), 0, "activeProposalCount must start at 0");
    }

    /// @dev Happy path: initial guardians set with correct permissions (R-07)
    function test_TC01_initializeSetsGuardians() public view {
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 must be a guardian");
        assertTrue(guardianModuleContract.isGuardian(guardian2), "guardian2 must be a guardian");
        assertTrue(guardianModuleContract.isGuardian(guardian3), "guardian3 must be a guardian");
        assertTrue(guardianModuleContract.isGuardian(guardian4), "guardian4 must be a guardian");
        assertFalse(guardianModuleContract.isGuardian(nonGuardian), "nonGuardian must not be a guardian");

        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian1),
            14,
            "guardian1 permissions must be 14 (CANCEL+EMERGENCY+PROPOSE, OF-19-001: no PAUSE+CANCEL)"
        );
        assertEq(guardianModuleContract.getGuardianPermissions(guardian2), 1, "guardian2 permissions must be 1 (PAUSE)");
        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian3), 2, "guardian3 permissions must be 2 (CANCEL)"
        );
        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian4), 4, "guardian4 permissions must be 4 (EMERGENCY)"
        );

        address[] memory guardianList = guardianModuleContract.getGuardians();
        assertEq(guardianList.length, 4, "Must have exactly 4 guardians");
    }

    /// @dev Double-init reverts InvalidInitialization (R-02)
    function test_TC01_doubleInitReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        governor.initialize(
            address(token),
            address(timelock),
            DEFAULT_VOTING_DELAY,
            DEFAULT_VOTING_PERIOD,
            DEFAULT_THRESHOLD_BPS,
            DEFAULT_QUORUM_BPS,
            address(0)
        );
    }

    /// @dev Direct impl init reverts InvalidInitialization (R-01)
    function test_TC01_directImplInitReverts() public {
        ForageGovernor freshImpl = new ForageGovernor();

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        freshImpl.initialize(
            address(token),
            address(timelock),
            DEFAULT_VOTING_DELAY,
            DEFAULT_VOTING_PERIOD,
            DEFAULT_THRESHOLD_BPS,
            DEFAULT_QUORUM_BPS,
            address(0)
        );
    }

    /// @dev Zero address forageToken reverts ZeroAddress (R-03)
    function test_TC01_zeroAddressTokenReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(0),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.ZeroAddress.selector));
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev Zero address timelockController reverts ZeroAddress (R-03)
    function test_TC01_zeroAddressTimelockReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(0),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.ZeroAddress.selector));
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev OF-001 two-phase governance: votingDelay=0 is accepted at launch (no hardcoded minimum).
    ///      Contract relies on timelock delay to protect against malicious parameter changes.
    function test_TC01_votingDelayZeroAccepted() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                uint48(0),
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        // Must NOT revert — votingDelay=0 is valid in launch phase (OF-001)
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        ForageGovernor gov2 = ForageGovernor(payable(address(proxy2)));
        assertEq(gov2.votingDelay(), 0, "votingDelay=0 must be accepted in launch phase");
    }

    /// @dev OF-001 two-phase governance: votingPeriod=0 still reverts (OZ internal check),
    ///      but any value > 0 is accepted — no hardcoded minimum in the contract.
    function test_TC01_votingPeriodZeroReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                uint32(0),
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.VotingPeriodBelowMinimum.selector, 0, governor.MIN_VOTING_PERIOD())
        );
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev votingPeriod below the one-hour launch minimum reverts.
    function test_TC01_votingPeriodBelowLaunchMinimumReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                uint32(1),
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.VotingPeriodBelowMinimum.selector, 1, governor.MIN_VOTING_PERIOD())
        );
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev quorumBps == 0 reverts InvalidParameter (R-05)
    function test_TC01_quorumBpsZeroReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                0,
                address(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.InvalidParameter.selector));
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev quorumBps == 5001 reverts InvalidParameter (R-05)
    function test_TC01_quorumBpsTooHighReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                5001,
                address(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.InvalidParameter.selector));
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev proposalThresholdBps == 0 reverts InvalidParameter (R-05)
    function test_TC01_thresholdBpsZeroReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                0,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.InvalidParameter.selector));
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev proposalThresholdBps == 5001 reverts InvalidParameter (R-05)
    function test_TC01_thresholdBpsTooHighReverts() public {
        ForageGovernor impl2 = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                5001,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.InvalidParameter.selector));
        new ERC1967Proxy(address(impl2), initData);
    }

    /// @dev Guardian array length mismatch reverts ArrayLengthMismatch (R-08)
    /// Now tests GuardianModule.initialize since guardians moved to GuardianModule
    function test_TC01_guardianArrayMismatchReverts() public {
        GuardianModule moduleImpl = new GuardianModule();
        address[] memory guardians = new address[](2);
        guardians[0] = makeAddr("g1");
        guardians[1] = makeAddr("g2");
        uint256[] memory permissions = new uint256[](1);
        permissions[0] = 5; // PAUSE + EMERGENCY (OF-19-001: was 7, PAUSE+CANCEL forbidden)

        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        vm.expectRevert(abi.encodeWithSelector(GuardianModule.ArrayLengthMismatch.selector));
        new ERC1967Proxy(address(moduleImpl), initData);
    }

    /// @dev Zero address guardian reverts ZeroAddress (R-09)
    /// Now tests GuardianModule.initialize since guardians moved to GuardianModule
    function test_TC01_zeroAddressGuardianReverts() public {
        GuardianModule moduleImpl = new GuardianModule();
        address[] memory guardians = new address[](1);
        guardians[0] = address(0);
        uint256[] memory permissions = new uint256[](1);
        permissions[0] = 5; // PAUSE + EMERGENCY (OF-19-001: was 7, PAUSE+CANCEL forbidden)

        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        vm.expectRevert(abi.encodeWithSelector(GuardianModule.ZeroAddress.selector));
        new ERC1967Proxy(address(moduleImpl), initData);
    }

    /// @dev Zero permission guardian reverts InvalidParameter (R-10)
    /// Now tests GuardianModule.initialize since guardians moved to GuardianModule
    function test_TC01_zeroPermissionGuardianReverts() public {
        GuardianModule moduleImpl = new GuardianModule();
        address[] memory guardians = new address[](1);
        guardians[0] = makeAddr("someGuardian");
        uint256[] memory permissions = new uint256[](1);
        permissions[0] = 0;

        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        vm.expectRevert(abi.encodeWithSelector(GuardianModule.InvalidParameter.selector));
        new ERC1967Proxy(address(moduleImpl), initData);
    }

    /// @dev Duplicate guardian reverts DuplicateGuardian (R-11)
    /// Now tests GuardianModule.initialize since guardians moved to GuardianModule
    function test_TC01_duplicateGuardianReverts() public {
        GuardianModule moduleImpl = new GuardianModule();
        address dup = makeAddr("dupGuardian");
        address[] memory guardians = new address[](2);
        guardians[0] = dup;
        guardians[1] = dup;
        uint256[] memory permissions = new uint256[](2);
        permissions[0] = 5; // PAUSE + EMERGENCY (OF-19-001: was 7, PAUSE+CANCEL forbidden)
        permissions[1] = 2; // CANCEL only (OF-19-001: was 3, PAUSE+CANCEL forbidden)

        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        vm.expectRevert(abi.encodeWithSelector(GuardianModule.DuplicateGuardian.selector));
        new ERC1967Proxy(address(moduleImpl), initData);
    }

    /// @dev R-07: Initialization emits GuardianPermissionsUpdated for each guardian
    /// Now tests GuardianModule.initialize since guardian events moved to GuardianModule
    function test_TC01_initEmitsGuardianEvents() public {
        // Deploy fresh GuardianModule impl + proxy to capture init events
        GuardianModule freshModuleImpl = new GuardianModule();

        address[] memory guardians = new address[](4);
        uint256[] memory permissions = new uint256[](4);
        guardians[0] = guardian1; // PAUSE + EMERGENCY + PROPOSE (OF-19-001: was 7)
        permissions[0] = 13;
        guardians[1] = guardian2;
        permissions[1] = 1;
        guardians[2] = guardian3;
        permissions[2] = 2;
        guardians[3] = guardian4;
        permissions[3] = 4;

        // Expect 4 GuardianPermissionsUpdated events (old=0 for all)
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian1, 0, 13);
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian2, 0, 1);
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian3, 0, 2);
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian4, 0, 4);

        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        new ERC1967Proxy(address(freshModuleImpl), initData);
    }

    /// @dev Empty guardian arrays succeed on GuardianModule (R-07, R-12)
    function test_TC01_emptyGuardianArraysSucceed() public {
        // Deploy a GuardianModule with empty guardian arrays
        GuardianModule moduleImpl = new GuardianModule();
        address[] memory emptyGuardians = new address[](0);
        uint256[] memory emptyPermissions = new uint256[](0);

        bytes memory moduleInitData = abi.encodeCall(
            GuardianModule.initialize, (address(governor), address(timelock), emptyGuardians, emptyPermissions)
        );
        ERC1967Proxy moduleProxy = new ERC1967Proxy(address(moduleImpl), moduleInitData);
        GuardianModule emptyModule = GuardianModule(address(moduleProxy));

        // Verify no guardians
        address[] memory guardianList = emptyModule.getGuardians();
        assertEq(guardianList.length, 0, "No guardians with empty init arrays");
    }
}

// ============================================================
// TC-02: Proposal Creation
// Requirements: R-13, R-14, R-15, R-16, R-17, R-65
// ============================================================
contract ForageGovernor_TC02_ProposalCreation is ForageGovernorTestBase {
    /// @dev Guardian proposes without tokens (R-13)
    function test_TC02_guardianProposesWithoutTokens() public {
        // guardian1 has 0 FORAGE, but is a guardian (permissions=14, includes CAN_PROPOSE, OF-19-001)
        assertEq(token.balanceOf(guardian1), 0, "guardian1 must have 0 tokens");

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(guardian1);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Guardian proposal");
        assertTrue(proposalId != 0, "Guardian proposal must succeed");
    }

    /// @dev Token holder proposes at threshold (R-14)
    function test_TC02_tokenHolderProposesAtThreshold() public {
        // proposer has exactly 1% = PROPOSER_TOKENS
        uint256 proposalId = _createProposal();
        assertTrue(proposalId != 0, "Proposer at threshold must succeed");
    }

    /// @dev Below-threshold non-guardian reverts InsufficientVotingPower (R-14)
    function test_TC02_belowThresholdReverts() public {
        // voter5 has 500K < 1M threshold and is not a guardian
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(voter5);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.InsufficientVotingPower.selector));
        governor.propose(targets, values, calldatas, "Under-threshold proposal");
    }

    /// @dev MaxActiveProposals limit hit reverts MaxActiveProposalsReached (R-15)
    function test_TC02_maxActiveProposalsReverts() public {
        // Create DEFAULT_MAX_ACTIVE (10) proposals
        for (uint256 i = 0; i < DEFAULT_MAX_ACTIVE; i++) {
            address[] memory targets = new address[](1);
            targets[0] = address(governor);
            uint256[] memory values = new uint256[](1);
            values[0] = 0;
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
            string memory desc = string(abi.encodePacked("Proposal-", vm.toString(i)));

            vm.prank(proposer);
            governor.propose(targets, values, calldatas, desc);
        }

        // 11th proposal should revert
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.MaxActiveProposalsReached.selector));
        governor.propose(targets, values, calldatas, "Overflow proposal");
    }

    /// @dev Lazy cleanup of Defeated proposals (R-16)
    function test_TC02_lazyCleanupOfDefeatedProposals() public {
        // Create DEFAULT_MAX_ACTIVE proposals
        uint256[] memory proposalIds = new uint256[](DEFAULT_MAX_ACTIVE);
        for (uint256 i = 0; i < DEFAULT_MAX_ACTIVE; i++) {
            address[] memory targets = new address[](1);
            targets[0] = address(governor);
            uint256[] memory values = new uint256[](1);
            values[0] = 0;
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
            string memory desc = string(abi.encodePacked("Cleanup-", vm.toString(i)));

            vm.prank(proposer);
            proposalIds[i] = governor.propose(targets, values, calldatas, desc);
        }

        // Advance past voting delay + voting period so proposals become Defeated (no votes cast)
        vm.roll(block.number + governor.votingDelay() + governor.votingPeriod() + 1);

        // Verify proposals are Defeated
        assertEq(
            uint8(governor.state(proposalIds[0])),
            uint8(IGovernor.ProposalState.Defeated),
            "Proposals must be Defeated after period with no votes"
        );

        // Now create a new proposal - lazy cleanup should allow it
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(proposer);
        uint256 newId = governor.propose(targets, values, calldatas, "After cleanup");
        assertTrue(newId != 0, "New proposal after lazy cleanup must succeed");
    }

    /// @dev proposalSnapshot() == creationBlock + votingDelay (R-17, OZ inherited per L2 line 281)
    function test_TC02_snapshotBlockIsCreationBlockPlusVotingDelay() public {
        uint256 creationBlock = block.number;
        uint256 proposalId = _createProposal();

        assertEq(
            governor.proposalSnapshot(proposalId),
            creationBlock + governor.votingDelay(),
            "proposalSnapshot must equal creationBlock + votingDelay (OZ inherited)"
        );
    }

    /// @dev ProposalCreated event emitted with correct payload (R-65)
    function test_TC02_proposalCreatedEventEmitted() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        uint256 creationBlock = block.number;

        vm.prank(proposer);
        vm.recordLogs();
        uint256 proposalId = governor.propose(targets, values, calldatas, "Event test");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 proposalCreatedTopic =
            keccak256("ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == proposalCreatedTopic) {
                found = true;
                // Decode and validate the full event payload
                (
                    uint256 pid,
                    address prop,, // targets
                    , // values
                    , // signatures
                    , // calldatas
                    uint256 voteStart,
                    uint256 voteEnd,
                    string memory desc
                ) = abi.decode(
                    logs[i].data, (uint256, address, address[], uint256[], string[], bytes[], uint256, uint256, string)
                );
                assertEq(pid, proposalId, "ProposalCreated proposalId must match");
                assertEq(prop, proposer, "ProposalCreated proposer must match");
                assertEq(voteStart, creationBlock + governor.votingDelay(), "ProposalCreated voteStart must match");
                assertEq(voteEnd, voteStart + governor.votingPeriod(), "ProposalCreated voteEnd must match");
                assertEq(
                    keccak256(bytes(desc)), keccak256(bytes("Event test")), "ProposalCreated description must match"
                );
                break;
            }
        }
        assertTrue(found, "ProposalCreated event must be emitted");
    }

    /// @dev Mismatched array lengths revert
    function test_TC02_mismatchedArrayLengthsRevert() public {
        address[] memory targets = new address[](2);
        targets[0] = address(governor);
        targets[1] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInvalidProposalLength.selector, targets.length, calldatas.length, values.length
            )
        );
        governor.propose(targets, values, calldatas, "Mismatched arrays");
    }

    /// @dev Empty targets revert
    function test_TC02_emptyTargetsRevert() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](0);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInvalidProposalLength.selector, uint256(0), uint256(0), uint256(0))
        );
        governor.propose(targets, values, calldatas, "Empty proposal");
    }

    /// @dev Exactly at threshold succeeds (R-14)
    function test_TC02_exactlyAtThresholdSucceeds() public {
        // proposer has exactly PROPOSER_TOKENS = 1% of supply
        uint256 votingPower = token.getVotes(proposer);
        uint256 threshold = governor.proposalThreshold();
        assertEq(votingPower, threshold, "Proposer voting power must equal threshold");

        uint256 proposalId = _createProposal();
        assertTrue(proposalId != 0, "Proposer with exact threshold must succeed");
    }

    /// @dev OF-010: Guardian with only PAUSE bit (no PERMISSION_CAN_PROPOSE) cannot propose.
    function test_TC02_guardianPauseOnlyCannotPropose() public {
        // guardian2 has permissions=1 (PAUSE only), 0 FORAGE
        assertEq(token.balanceOf(guardian2), 0, "guardian2 must have 0 tokens");

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(guardian2);
        vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
        governor.propose(targets, values, calldatas, "PAUSE-only guardian proposal");
    }

    /// @dev activeProposalCount incremented on propose
    function test_TC02_activeProposalCountIncremented() public {
        uint256 countBefore = governor.activeProposalCount();
        _createProposal();
        assertEq(governor.activeProposalCount(), countBefore + 1, "activeProposalCount must increment on propose");
    }
}

// ============================================================
// TC-03: Voting
// Requirements: R-18, R-19, R-20, R-21, R-22, R-23, R-63, R-66
// ============================================================
contract ForageGovernor_TC03_Voting is ForageGovernorTestBase {
    uint256 proposalId;

    function setUp() public override {
        super.setUp();
        // Create a proposal and advance to Active state
        proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);
    }

    /// @dev Cast For vote with correct weight (R-18)
    function test_TC03_castForVoteWithCorrectWeight() public {
        uint256 expectedWeight = token.getVotes(voter1);

        vm.prank(voter1);
        uint256 weight = governor.castVote(proposalId, 1); // For

        assertEq(weight, expectedWeight, "Vote weight must equal voting power at snapshot");
        assertTrue(governor.hasVoted(proposalId, voter1), "hasVoted must return true after voting");

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertEq(forVotes, expectedWeight, "For votes must equal voter weight");
        assertEq(against, 0, "Against votes must be 0");
        assertEq(abstain, 0, "Abstain votes must be 0");
    }

    /// @dev Cast Against vote (R-18)
    function test_TC03_castAgainstVote() public {
        vm.prank(voter1);
        governor.castVote(proposalId, 0); // Against

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertGt(against, 0, "Against votes must be > 0");
        assertEq(forVotes, 0, "For votes must be 0");
        assertEq(abstain, 0, "Abstain votes must be 0");
    }

    /// @dev Cast Abstain vote (R-18)
    function test_TC03_castAbstainVote() public {
        vm.prank(voter1);
        governor.castVote(proposalId, 2); // Abstain

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertEq(against, 0, "Against votes must be 0");
        assertEq(forVotes, 0, "For votes must be 0");
        assertGt(abstain, 0, "Abstain votes must be > 0");
    }

    /// @dev Double vote reverts GovernorAlreadyCastVote (R-19)
    function test_TC03_doubleVoteReverts() public {
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, voter1));
        governor.castVote(proposalId, 0); // Attempt Against after For
    }

    /// @dev Vote immutability - cannot change vote (R-20)
    function test_TC03_voteImmutabilityCannotChangeVote() public {
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For

        // Try all three vote types - all should revert with GovernorAlreadyCastVote
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, voter1));
        governor.castVote(proposalId, 0); // Against

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, voter1));
        governor.castVote(proposalId, 1); // For again

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, voter1));
        governor.castVote(proposalId, 2); // Abstain
    }

    /// @dev Non-Active proposal reverts GovernorUnexpectedProposalState (R-21)
    function test_TC03_voteOnPendingProposalReverts() public {
        // Create a new proposal that is still Pending (don't advance blocks)
        uint256 pendingProposal = _createProposal();

        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                pendingProposal,
                IGovernor.ProposalState.Pending,
                bytes32(1 << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVote(pendingProposal, 1);
    }

    /// @dev Zero voting power voter cannot vote (R-22)
    function test_TC03_zeroVotingPowerReverts() public {
        // attacker has 0 FORAGE and 0 voting power
        assertEq(token.getVotes(attacker), 0, "attacker must have 0 voting power");

        vm.prank(attacker);
        vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
        governor.castVote(proposalId, 1);
    }

    /// @dev Invalid support (3) reverts GovernorInvalidVoteType (R-23)
    function test_TC03_invalidSupportReverts() public {
        vm.prank(voter1);
        vm.expectRevert(IGovernor.GovernorInvalidVoteType.selector);
        governor.castVote(proposalId, 3);
    }

    /// @dev Snapshot-based power: tokens acquired after snapshot give 0 power (R-18, R-63)
    function test_TC03_tokensAcquiredAfterSnapshotGiveZeroPower() public {
        // Transfer tokens to a new address AFTER the proposal was created
        address lateBuyer = makeAddr("lateBuyer");
        vm.prank(deployer);
        token.transfer(lateBuyer, 2_000_000 * 1e18);
        vm.prank(lateBuyer);
        token.delegate(lateBuyer);
        vm.roll(block.number + 1); // Need at least 1 block for delegation

        // lateBuyer has current balance but 0 power at snapshot
        assertGt(token.getVotes(lateBuyer), 0, "lateBuyer must have current voting power");

        // Voting power at snapshot should be 0 (didn't have tokens at snapshot block)
        vm.prank(lateBuyer);
        vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
        governor.castVote(proposalId, 1);
    }

    /// @dev Snapshot-based power: tokens transferred after snapshot still count at snapshot (R-18, R-63)
    function test_TC03_tokensTransferredAfterSnapshotStillCount() public {
        // voter2 has 3M tokens at snapshot. Transfer them away.
        uint256 snapshotPower = token.getPastVotes(voter2, governor.proposalSnapshot(proposalId));
        assertGt(snapshotPower, 0, "voter2 must have power at snapshot");

        // Transfer all tokens away (use startPrank so balanceOf doesn't consume prank)
        uint256 voter2Balance = token.balanceOf(voter2);
        vm.prank(voter2);
        token.transfer(attacker, voter2Balance);
        assertEq(token.balanceOf(voter2), 0, "voter2 current balance must be 0");

        // voter2 can still vote with snapshot power
        vm.prank(voter2);
        uint256 weight = governor.castVote(proposalId, 1);
        assertEq(weight, snapshotPower, "Vote weight must use snapshot power, not current balance");
    }

    /// @dev castVoteWithReason emits VoteCast event with full payload (R-66)
    function test_TC03_castVoteWithReasonEmitsEvent() public {
        string memory reason = "I support this proposal";
        uint256 voterPower = token.getPastVotes(voter1, governor.proposalSnapshot(proposalId));

        // VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 weight, string reason)
        vm.expectEmit(true, false, false, true);
        emit IGovernor.VoteCast(voter1, proposalId, 1, voterPower, reason);

        vm.prank(voter1);
        governor.castVoteWithReason(proposalId, 1, reason);
    }

    /// @dev castVoteWithReasonAndParams emits VoteCastWithParams with full payload
    function test_TC03_castVoteWithReasonAndParams() public {
        uint256 voterPower = token.getPastVotes(voter1, governor.proposalSnapshot(proposalId));
        bytes memory params = abi.encode(uint256(42));

        // Expect VoteCastWithParams event with full payload validation
        vm.expectEmit(true, true, false, true);
        emit IGovernor.VoteCastWithParams(voter1, proposalId, 1, voterPower, "test reason", params);

        vm.prank(voter1);
        uint256 weight = governor.castVoteWithReasonAndParams(proposalId, 1, "test reason", params);
        assertEq(weight, voterPower, "castVoteWithReasonAndParams must return voter's snapshot power");
        assertTrue(governor.hasVoted(proposalId, voter1), "hasVoted must be true after castVoteWithReasonAndParams");
    }

    /// @dev Delegation: Alice delegates to Bob, Bob votes with combined power
    function test_TC03_delegationAffectsVotingPower() public {
        // Set up fresh proposal after delegation
        // voter3 (2M) delegates to voter4 (1M) - need to do before proposal creation for snapshot
        vm.prank(voter3);
        token.delegate(voter4);

        // Roll forward so delegation checkpoint is recorded
        vm.roll(block.number + 1);

        // Create a new proposal (snapshot captures delegation)
        uint256 newProposal = _createProposal();

        // Advance to Active
        vm.roll(block.number + governor.votingDelay() + 1);

        // voter4 should have combined power (1M own + 2M from voter3 = 3M)
        vm.prank(voter4);
        uint256 weight = governor.castVote(newProposal, 1);
        assertEq(weight, 3_000_000 * 1e18, "voter4 must vote with combined power (own + delegated from voter3)");

        // voter3 should not be able to vote (delegated away, 0 power at snapshot)
        vm.prank(voter3);
        vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
        governor.castVote(newProposal, 1);
    }

    /// @dev Vote on Defeated proposal reverts GovernorUnexpectedProposalState (R-21)
    function test_TC03_voteOnDefeatedProposalReverts() public {
        // Advance past voting period without anyone voting -> Defeated
        vm.roll(block.number + governor.votingPeriod() + 1);

        assertEq(
            uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated), "Proposal must be Defeated"
        );

        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Defeated,
                bytes32(1 << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVote(proposalId, 1);
    }
}

// ============================================================
// TC-04: Queue, Execute, Cancel Lifecycle
// Requirements: R-24, R-25, R-26, R-27, R-28, R-29, R-30,
//               R-31, R-32, R-67, R-68, R-69
// ============================================================
contract ForageGovernor_TC04_QueueExecuteCancelLifecycle is ForageGovernorTestBase {
    // Standard proposal params - populated in setUp
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string description;
    bytes32 descriptionHash;

    function setUp() public override {
        super.setUp();

        // Build reusable proposal params
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        values[0] = 0;
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
        description = "TC04 lifecycle proposal";
        descriptionHash = keccak256(bytes(description));
    }

    /// @dev Internal helper to create+pass the standard proposal
    function _createAndPassStandardProposal() internal returns (uint256) {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);
        // Advance past voting delay
        vm.roll(block.number + governor.votingDelay() + 1);
        // Cast enough votes
        vm.prank(voter1);
        governor.castVote(pid, 1); // 5M For > 4M quorum
        // Advance past voting period
        vm.roll(block.number + governor.votingPeriod() + 1);
        return pid;
    }

    /// @dev Queue succeeded proposal (R-24, R-67)
    function test_TC04_queueSucceededProposal() public {
        uint256 pid = _createAndPassStandardProposal();

        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Succeeded),
            "Proposal must be Succeeded before queue"
        );

        vm.recordLogs();
        governor.queue(targets, values, calldatas, descriptionHash);

        assertEq(
            uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Queued), "Proposal must be Queued after queue()"
        );

        // Verify ProposalQueued event with full payload
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 queuedTopic = keccak256("ProposalQueued(uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == queuedTopic) {
                found = true;
                (uint256 eventPid, uint256 eventEta) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(eventPid, pid, "ProposalQueued proposalId must match");
                assertGt(eventEta, 0, "ProposalQueued eta must be > 0");
                break;
            }
        }
        assertTrue(found, "ProposalQueued event must be emitted");

        // Verify proposalEta is set
        assertGt(governor.proposalEta(pid), 0, "proposalEta must be set after queue");
    }

    /// @dev Queue non-Succeeded proposal reverts GovernorUnexpectedProposalState (R-24)
    function test_TC04_queueNonSucceededReverts() public {
        // Create proposal but don't pass it
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // Proposal is Pending
        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Pending), "Proposal must be Pending");

        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                pid,
                IGovernor.ProposalState.Pending,
                bytes32(1 << uint8(IGovernor.ProposalState.Succeeded))
            )
        );
        governor.queue(targets, values, calldatas, descriptionHash);
    }

    /// @dev Execute after delay (R-25, R-28, R-68)
    function test_TC04_executeAfterDelay() public {
        uint256 pid = _createAndPassStandardProposal();

        // Queue
        governor.queue(targets, values, calldatas, descriptionHash);

        // Advance past timelock delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        uint256 countBefore = governor.activeProposalCount();

        vm.recordLogs();
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Executed),
            "Proposal must be Executed after execute()"
        );

        // Verify activeProposalCount decremented
        assertEq(governor.activeProposalCount(), countBefore - 1, "activeProposalCount must decrement on execute");

        // Verify ProposalExecuted event with payload
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 executedTopic = keccak256("ProposalExecuted(uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == executedTopic) {
                found = true;
                uint256 eventPid = abi.decode(logs[i].data, (uint256));
                assertEq(eventPid, pid, "ProposalExecuted proposalId must match");
                break;
            }
        }
        assertTrue(found, "ProposalExecuted event must be emitted");
    }

    /// @dev OF-001 launch phase: with TIMELOCK_MIN_DELAY=0, execution is immediate after queue.
    ///      In production phase, PRODUCTION_TIMELOCK_DELAY=691200 (8 days) enforces a real delay.
    function test_TC04_executeImmediateWithZeroDelay() public {
        uint256 pid = _createAndPassStandardProposal();
        governor.queue(targets, values, calldatas, descriptionHash);

        // With delay=0 (launch phase), execute works immediately — no warp needed
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Executed),
            "With delay=0, execution must succeed immediately after queue"
        );
    }

    /// @dev OF-001 production phase: with PRODUCTION_TIMELOCK_DELAY, execute before delay reverts.
    ///      Deploys a separate timelock with production delay to verify delay enforcement.
    function test_TC04_executeBeforeProductionDelayReverts() public {
        // Deploy a separate timelock with production delay.
        // Use deployer as initial proposer so we can grant roles through it.
        address[] memory prodProposers = new address[](1);
        prodProposers[0] = deployer;
        address[] memory prodExecutors = new address[](1);
        prodExecutors[0] = address(0); // open execution

        TimelockController prodTimelock =
            new TimelockController(PRODUCTION_TIMELOCK_DELAY, prodProposers, prodExecutors, address(0));

        // Deploy a fresh governor pointing to the production timelock
        ForageGovernor prodGovernor;
        {
            ForageGovernor prodImpl = new ForageGovernor();
            bytes memory prodInitData = abi.encodeCall(
                ForageGovernor.initialize,
                (
                    address(token),
                    address(prodTimelock),
                    PRODUCTION_VOTING_DELAY,
                    PRODUCTION_VOTING_PERIOD,
                    DEFAULT_THRESHOLD_BPS,
                    DEFAULT_QUORUM_BPS,
                    address(0)
                )
            );
            ERC1967Proxy prodProxy = new ERC1967Proxy(address(prodImpl), prodInitData);
            prodGovernor = ForageGovernor(payable(address(prodProxy)));
        }

        // Grant prodGovernor PROPOSER_ROLE on prodTimelock
        {
            bytes32 role = keccak256("PROPOSER_ROLE");
            bytes memory data = abi.encodeCall(prodTimelock.grantRole, (role, address(prodGovernor)));
            bytes32 salt = keccak256("grant_proposer_prod");
            vm.prank(deployer);
            prodTimelock.schedule(address(prodTimelock), 0, data, bytes32(0), salt, PRODUCTION_TIMELOCK_DELAY);
            vm.warp(block.timestamp + PRODUCTION_TIMELOCK_DELAY);
            prodTimelock.execute(address(prodTimelock), 0, data, bytes32(0), salt);
        }

        // Create proposal on prodGovernor
        address[] memory prodTargets = new address[](1);
        prodTargets[0] = address(prodGovernor);
        uint256[] memory prodValues = new uint256[](1);
        prodValues[0] = 0;
        bytes[] memory prodCalldatas = new bytes[](1);
        prodCalldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
        bytes32 prodDescHash = keccak256(bytes("Production delay test"));

        uint256 prodPid;
        {
            vm.prank(proposer);
            prodPid = prodGovernor.propose(prodTargets, prodValues, prodCalldatas, "Production delay test");
        }

        // Pass through voting
        vm.roll(block.number + prodGovernor.votingDelay() + 1);
        vm.prank(voter1);
        prodGovernor.castVote(prodPid, 1);
        vm.roll(block.number + prodGovernor.votingPeriod() + 1);

        // Queue
        prodGovernor.queue(prodTargets, prodValues, prodCalldatas, prodDescHash);

        // Try to execute immediately (before delay) — must revert
        vm.expectRevert();
        prodGovernor.execute(prodTargets, prodValues, prodCalldatas, prodDescHash);
    }

    /// @dev Failed execution preserves Queued state (R-26, R-27)
    function test_TC04_failedExecutionPreservesState() public {
        // Create proposal that targets the RevertTarget
        address[] memory failTargets = new address[](1);
        failTargets[0] = address(revertTarget);
        uint256[] memory failValues = new uint256[](1);
        failValues[0] = 0;
        bytes[] memory failCalldatas = new bytes[](1);
        failCalldatas[0] = abi.encodeCall(RevertTarget.doSomething, ());
        string memory failDesc = "Failing proposal";
        bytes32 failDescHash = keccak256(bytes(failDesc));

        vm.prank(proposer);
        uint256 pid = governor.propose(failTargets, failValues, failCalldatas, failDesc);

        // Pass voting
        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter1);
        governor.castVote(pid, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);

        // Queue
        governor.queue(failTargets, failValues, failCalldatas, failDescHash);

        uint256 countBefore = governor.activeProposalCount();

        // Advance past delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        // Execute should revert (target reverts)
        vm.expectRevert(RevertTarget.AlwaysReverts.selector);
        governor.execute(failTargets, failValues, failCalldatas, failDescHash);

        // State must remain Queued
        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Queued),
            "State must remain Queued after failed execution"
        );

        // activeProposalCount must NOT be decremented
        assertEq(
            governor.activeProposalCount(), countBefore, "activeProposalCount must NOT decrement on failed execution"
        );
    }

    /// @dev Cancel by proposer from Pending (R-29, R-32, R-69)
    function test_TC04_cancelByProposerFromPending() public {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Pending), "Proposal must be Pending");

        uint256 countBefore = governor.activeProposalCount();

        vm.prank(proposer);
        vm.recordLogs();
        governor.cancel(targets, values, calldatas, descriptionHash);

        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Canceled),
            "Proposal must be Canceled after cancel()"
        );

        assertEq(governor.activeProposalCount(), countBefore - 1, "activeProposalCount must decrement on cancel");

        // Verify ProposalCanceled event with payload
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 canceledTopic = keccak256("ProposalCanceled(uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == canceledTopic) {
                found = true;
                uint256 eventPid = abi.decode(logs[i].data, (uint256));
                assertEq(eventPid, pid, "ProposalCanceled proposalId must match");
                break;
            }
        }
        assertTrue(found, "ProposalCanceled event must be emitted");
    }

    /// @dev Cancel by proposer after losing tokens (R-29)
    function test_TC04_cancelByProposerAfterLosingTokens() public {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // Proposer transfers all tokens away (cache balance to avoid prank consumption)
        uint256 proposerBalance = token.balanceOf(proposer);
        vm.prank(proposer);
        token.transfer(attacker, proposerBalance);
        assertEq(token.balanceOf(proposer), 0, "Proposer must have 0 tokens");

        // Proposer can still cancel (unconditional proposer cancel)
        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descriptionHash);

        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Canceled),
            "Proposer must be able to cancel even with 0 tokens"
        );
    }

    function test_V12_67818_proposerCannotCancelSucceededOrQueuedProposal() public {
        uint256 succeededPid = _createAndPassStandardProposal();

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, succeededPid, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);

        string memory queuedDescription = "TC04 queued proposer cancel restriction";
        bytes32 queuedDescriptionHash = keccak256(bytes(queuedDescription));
        vm.prank(proposer);
        uint256 queuedPid = governor.propose(targets, values, calldatas, queuedDescription);
        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter1);
        governor.castVote(queuedPid, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.queue(targets, values, calldatas, queuedDescriptionHash);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, queuedPid, proposer));
        governor.cancel(targets, values, calldatas, queuedDescriptionHash);
    }

    /// @dev Cancel by guardian with CANCEL permission via GuardianModule (R-30)
    function test_TC04_cancelByGuardianWithCancelPermission() public {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // guardian3 has PERMISSION_CAN_CANCEL (bit 1, permissions=2)
        // Guardian cancels go through the module, which calls governor.cancel
        vm.prank(guardian3);
        guardianModuleContract.guardianCancel(pid);

        assertEq(
            uint8(governor.state(pid)),
            uint8(IGovernor.ProposalState.Canceled),
            "Guardian with CANCEL permission must be able to cancel"
        );
    }

    /// @dev Cancel by guardian without CANCEL permission reverts via GuardianModule
    function test_TC04_cancelByGuardianWithoutCancelPermissionReverts() public {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // guardian2 has only PAUSE permission (bit 0, permissions=1) - NOT CANCEL
        vm.prank(guardian2);
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        guardianModuleContract.guardianCancel(pid);
    }

    /// @dev Proposer cancel on Executed proposal reverts before the widened guardian cancel path (R-31, V12 #67818)
    function test_TC04_cancelOnExecutedProposalReverts() public {
        uint256 pid = _createAndPassStandardProposal();

        // Queue and execute
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Executed), "Proposal must be Executed");

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, pid, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev Proposer cancel on already Canceled proposal reverts before the widened guardian cancel path (R-31, V12 #67818)
    function test_TC04_cancelOnCanceledProposalReverts() public {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // Cancel first time
        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, pid, proposer));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev Guardian cancellation of a queued proposal cancels the TimelockController operation
    function test_TC04_cancelQueuedProposalCancelsTimelockOp() public {
        uint256 pid = _createAndPassStandardProposal();
        governor.queue(targets, values, calldatas, descriptionHash);

        assertEq(uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Queued), "Proposal must be Queued");

        // Cancel the queued proposal through the guardian module's widened cancellation path.
        vm.prank(guardian3);
        guardianModuleContract.guardianCancel(pid);

        assertEq(
            uint8(governor.state(pid)), uint8(IGovernor.ProposalState.Canceled), "Queued proposal must be Canceled"
        );

        // Verify that executing also fails (proposal is Canceled — governor rejects before reaching timelock)
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                pid,
                IGovernor.ProposalState.Canceled,
                // execute expects Succeeded(4) or Queued(5) = (1<<4)|(1<<5) = 0x30
                bytes32(uint256(0x30))
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    /// @dev activeProposalCount decremented on execute
    function test_TC04_activeProposalCountDecrementedOnExecute() public {
        uint256 pid = _createAndPassStandardProposal();
        uint256 countAfterPropose = governor.activeProposalCount();

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(
            governor.activeProposalCount(),
            countAfterPropose - 1,
            "activeProposalCount must decrement after successful execute"
        );
    }

    /// @dev activeProposalCount decremented on cancel
    function test_TC04_activeProposalCountDecrementedOnCancel() public {
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, description);
        uint256 countAfterPropose = governor.activeProposalCount();

        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descriptionHash);

        assertEq(
            governor.activeProposalCount(), countAfterPropose - 1, "activeProposalCount must decrement after cancel"
        );
    }

    /// @dev Non-proposer non-guardian cancel reverts GovernorUnableToCancel
    function test_TC04_nonProposerNonGuardianCancelReverts() public {
        vm.prank(proposer);
        uint256 pid = governor.propose(targets, values, calldatas, description);

        // attacker is neither the proposer nor a guardian
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, pid, attacker));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev Execute decrements activeProposalCount only on success (R-27, R-28)
    function test_TC04_executeDecrementsOnlyOnSuccess() public {
        // Create 2 proposals: one that will succeed, one that will fail

        // Proposal 1: will succeed (setMaxActiveProposals on governor)
        vm.prank(proposer);
        uint256 pid1 = governor.propose(targets, values, calldatas, description);

        // Proposal 2: will fail (calls RevertTarget)
        address[] memory failTargets = new address[](1);
        failTargets[0] = address(revertTarget);
        uint256[] memory failValues = new uint256[](1);
        failValues[0] = 0;
        bytes[] memory failCalldatas = new bytes[](1);
        failCalldatas[0] = abi.encodeCall(RevertTarget.doSomething, ());
        string memory failDesc = "Failing proposal 2";
        bytes32 failDescHash = keccak256(bytes(failDesc));

        vm.prank(proposer);
        uint256 pid2 = governor.propose(failTargets, failValues, failCalldatas, failDesc);

        uint256 countWith2 = governor.activeProposalCount();

        // Pass both through voting (voter1 has 5M > 4M quorum for each)
        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter1);
        governor.castVote(pid1, 1);
        vm.prank(voter1);
        governor.castVote(pid2, 1);
        vm.roll(block.number + governor.votingPeriod() + 1);

        // Queue both
        governor.queue(targets, values, calldatas, descriptionHash);
        governor.queue(failTargets, failValues, failCalldatas, failDescHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        // Execute failing proposal - reverts, count unchanged
        vm.expectRevert(RevertTarget.AlwaysReverts.selector);
        governor.execute(failTargets, failValues, failCalldatas, failDescHash);
        assertEq(governor.activeProposalCount(), countWith2, "Count must not change on failed execute");

        // Execute succeeding proposal - count decrements
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.activeProposalCount(), countWith2 - 1, "Count must decrement on successful execute");
    }
}
