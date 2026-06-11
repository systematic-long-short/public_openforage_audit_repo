// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/TimelockControllerTestBase.sol";

// ============================================================
// TC-13: Deployment Configuration Lifecycle
// ============================================================
contract TimelockController_TC13_Lifecycle is TimelockControllerTestBase {
    function test_TC13_phase1DeployerRoles() public view {
        assertTrue(timelock.hasRole(PROPOSER_ROLE, deployer), "Phase 1: deployer must have PROPOSER_ROLE");
        assertTrue(timelock.hasRole(CANCELLER_ROLE, deployer), "Phase 1: deployer must have CANCELLER_ROLE");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Phase 1: deployer must NOT have admin");
    }

    function test_TC13_phase2GrantGovernorProposer() public {
        // Grant PROPOSER_ROLE to governor via timelock-scheduled operation
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt = keccak256("p2_grant_proposer");
        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertTrue(timelock.hasRole(PROPOSER_ROLE, governor), "Governor must have PROPOSER_ROLE after Phase 2 grant");
    }

    function test_TC13_phase2GrantGovernorCanceller() public {
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (CANCELLER_ROLE, governor));
        bytes32 salt = keccak256("p2_grant_canceller");
        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertTrue(timelock.hasRole(CANCELLER_ROLE, governor), "Governor must have CANCELLER_ROLE after Phase 2 grant");
    }

    function test_TC13_phase2RevokeDeployerProposer() public {
        // First grant governor PROPOSER_ROLE so someone can still propose
        bytes memory grantData = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt1 = keccak256("p2_grant_first");
        _scheduleOperation(address(timelock), 0, grantData, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, grantData, bytes32(0), salt1);

        // Revoke deployer's PROPOSER_ROLE
        bytes memory revokeData = abi.encodeCall(IAccessControl.revokeRole, (PROPOSER_ROLE, deployer));
        bytes32 salt2 = keccak256("p2_revoke_proposer");
        _scheduleOperation(address(timelock), 0, revokeData, bytes32(0), salt2, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, revokeData, bytes32(0), salt2);

        assertFalse(
            timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must NOT have PROPOSER_ROLE after Phase 2 revoke"
        );
    }

    function test_TC13_phase2RevokeDeployerCanceller() public {
        // Revoke deployer's CANCELLER_ROLE
        bytes memory revokeData = abi.encodeCall(IAccessControl.revokeRole, (CANCELLER_ROLE, deployer));
        bytes32 salt = keccak256("p2_revoke_canceller");
        _scheduleOperation(address(timelock), 0, revokeData, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, revokeData, bytes32(0), salt);

        assertFalse(
            timelock.hasRole(CANCELLER_ROLE, deployer), "Deployer must NOT have CANCELLER_ROLE after Phase 2 revoke"
        );
    }

    function test_TC13_phase2DeployerCannotSchedule() public {
        _setupPhase2();

        // Deployer no longer has PROPOSER_ROLE
        bytes memory data = _doSomethingCalldata();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, PROPOSER_ROLE)
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), keccak256("denied"), MIN_DELAY);
    }

    function test_TC13_phase2GovernorCanSchedule() public {
        _setupPhase2();

        // Governor now has PROPOSER_ROLE
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("gov_schedule");
        vm.prank(governor);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id), "Governor-scheduled operation must be pending");
    }

    function test_TC13_phase2AdminUnchanged() public {
        _setupPhase2();

        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "TimelockController must still have DEFAULT_ADMIN_ROLE after Phase 2"
        );
        assertFalse(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Deployer must still NOT have DEFAULT_ADMIN_ROLE after Phase 2"
        );
    }

    function test_TC13_phase2ExecutorUnchanged() public {
        _setupPhase2();

        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0)), "Open execution must remain after Phase 2");
    }
}

// ============================================================
// TC-14: Non-Upgradeability
// ============================================================
contract TimelockController_TC14_NonUpgradeable is TimelockControllerTestBase {
    function test_TC14_noUpgradeToAndCall() public view {
        // TimelockController does NOT have upgradeToAndCall
        // Verify by scanning deployed bytecode for the UUPS upgradeToAndCall selector
        bytes4 upgradeSelector = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
        bytes memory code = address(timelock).code;

        bool selectorFound = false;
        for (uint256 i = 0; i + 3 < code.length; i++) {
            if (
                code[i] == upgradeSelector[0] && code[i + 1] == upgradeSelector[1] && code[i + 2] == upgradeSelector[2]
                    && code[i + 3] == upgradeSelector[3]
            ) {
                selectorFound = true;
                break;
            }
        }
        assertFalse(selectorFound, "upgradeToAndCall selector must not exist in TimelockController bytecode");
    }

    function test_TC14_noProxiableUUID() public view {
        // UUPS proxies implement proxiableUUID() which returns the implementation slot
        // Verify by scanning deployed bytecode for the proxiableUUID selector
        bytes4 proxiableSelector = bytes4(keccak256("proxiableUUID()"));
        bytes memory code = address(timelock).code;

        bool selectorFound = false;
        for (uint256 i = 0; i + 3 < code.length; i++) {
            if (
                code[i] == proxiableSelector[0] && code[i + 1] == proxiableSelector[1]
                    && code[i + 2] == proxiableSelector[2] && code[i + 3] == proxiableSelector[3]
            ) {
                selectorFound = true;
                break;
            }
        }
        assertFalse(selectorFound, "proxiableUUID selector must not exist in TimelockController bytecode");
    }

    function test_TC14_noImplementationSlot() public {
        // ERC-1967 implementation slot
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 slotValue = vm.load(address(timelock), implSlot);
        assertEq(slotValue, bytes32(0), "ERC-1967 implementation slot must be empty (not a proxy)");
    }

    function test_TC14_standardDeployment() public view {
        // Verify the timelock has code (it's a concrete contract, not a proxy)
        uint256 codeSize;
        address timelockAddr = address(timelock);
        assembly {
            codeSize := extcodesize(timelockAddr)
        }
        assertGt(codeSize, 0, "TimelockController must have code at its address");

        // Verify it supports AccessControl interface
        assertTrue(
            timelock.supportsInterface(type(IAccessControl).interfaceId), "Must support IAccessControl interface"
        );
    }
}

// ============================================================
// TC-15: Ownership Model
// ============================================================
contract TimelockController_TC15_Ownership is TimelockControllerTestBase {
    function test_TC15_timelockOwnsContract() public view {
        assertEq(mockOwnable.owner(), address(timelock), "TimelockController must be owner of MockOwnable");
    }

    function test_TC15_attackerCannotCallOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MockOwnable.OwnableUnauthorizedAccount.selector, attacker));
        mockOwnable.setProtectedValue(42);
    }

    function test_TC15_deployerCannotCallOnlyOwner() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(MockOwnable.OwnableUnauthorizedAccount.selector, deployer));
        mockOwnable.setProtectedValue(42);
    }

    function test_TC15_timelockCanCallOnlyOwner() public {
        // Schedule operation to call setProtectedValue via timelock
        bytes memory data = abi.encodeCall(MockOwnable.setProtectedValue, (42));
        bytes32 salt = keccak256("set_value");
        _scheduleOperation(address(mockOwnable), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockOwnable), 0, data, bytes32(0), salt);

        assertEq(mockOwnable.protectedValue(), 42, "TimelockController must be able to call onlyOwner");
    }

    function test_TC15_governorStyleOwnership() public {
        // TimelockController as owner pattern: schedule -> wait -> execute
        // With delay=0 (launch phase), operations are immediately Ready and executable.
        // Use PRODUCTION_DELAY to test the full governance flow with waiting.
        // First update the timelock to production delay
        bytes memory updateData = abi.encodeCall(TimelockController.updateDelay, (PRODUCTION_DELAY));
        bytes32 updateSalt = keccak256("set_prod_delay");
        _scheduleOperation(address(timelock), 0, updateData, bytes32(0), updateSalt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, updateData, bytes32(0), updateSalt);

        bytes memory data = abi.encodeCall(MockOwnable.setProtectedValue, (100));
        bytes32 salt = keccak256("gov_ownership");

        // Schedule with production delay
        bytes32 id = _scheduleOperation(address(mockOwnable), 0, data, bytes32(0), salt, PRODUCTION_DELAY);
        assertTrue(timelock.isOperationPending(id), "Operation must be pending");

        // Cannot execute yet — still in Waiting state
        vm.expectRevert();
        _executeOperation(address(mockOwnable), 0, data, bytes32(0), salt);

        // Wait past production delay
        vm.warp(block.timestamp + PRODUCTION_DELAY);
        assertTrue(timelock.isOperationReady(id), "Operation must be ready");

        // Execute
        _executeOperation(address(mockOwnable), 0, data, bytes32(0), salt);
        assertEq(mockOwnable.protectedValue(), 100, "Value must be updated after governance flow");
    }
}

// ============================================================
// TC-16: Governance Defense (Timing)
// Tests use PRODUCTION_DELAY (691200s = 8 days), the delay that will be
// activated after launch phase. The depositor exit window analysis only
// applies to production phase when the timelock has a non-zero delay.
// ============================================================
contract TimelockController_TC16_GovernanceDefense is TimelockControllerTestBase {
    TimelockController public prodTimelock;

    function setUp() public override {
        super.setUp();
        // Deploy a production-configured timelock for governance defense tests
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        vm.prank(deployer);
        prodTimelock = new TimelockController(PRODUCTION_DELAY, proposers, executors, address(0));
    }

    function test_TC16_eightDayExceedsSevenDay() public view {
        // Production phase: 8-day timelock delay must exceed 7-day atRISKUSD cooldown
        assertGt(PRODUCTION_DELAY, SEVEN_DAYS, "8-day delay (691200s) must exceed 7-day cooldown (604800s)");
        assertEq(PRODUCTION_DELAY - SEVEN_DAYS, 86400, "Difference must be exactly 1 day (86400s)");
    }

    function test_TC16_depositorExitsBeforeGovernance() public {
        // Simulate: depositor sees governance proposal, has 7 days to exit
        // Governance proposal takes 8 days to become executable
        // Depositor has at least 1 full day to exit after seeing the proposal

        uint256 proposalTime = block.timestamp;

        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("gov_proposal");
        vm.prank(deployer);
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, PRODUCTION_DELAY);

        // After 7 days (depositor cooldown expires), operation is still Waiting
        vm.warp(proposalTime + SEVEN_DAYS);
        bytes32 id = prodTimelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(
            uint256(prodTimelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Waiting),
            "After 7 days, operation must still be Waiting (depositor can still exit)"
        );

        // After 8 days, operation becomes Ready
        vm.warp(proposalTime + PRODUCTION_DELAY);
        assertEq(
            uint256(prodTimelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Ready),
            "After 8 days, operation must be Ready"
        );
    }

    function test_TC16_boundaryDepositorOneDayLate() public {
        // Even if a depositor starts cooldown 1 day after seeing the proposal,
        // their 7-day cooldown (proposal_time + 1 day + 7 days = 8 days) still completes
        // exactly when the governance action becomes executable
        uint256 proposalTime = block.timestamp;

        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("boundary_late");
        vm.prank(deployer);
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, PRODUCTION_DELAY);
        bytes32 id = prodTimelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);

        // Depositor starts cooldown 1 day late
        uint256 depositorCooldownEnd = proposalTime + 1 days + SEVEN_DAYS;
        // Governance becomes executable at proposal_time + PRODUCTION_DELAY
        uint256 governanceExecutable = proposalTime + PRODUCTION_DELAY;

        // Depositor cooldown ends at exactly the same time governance becomes executable
        assertEq(
            depositorCooldownEnd,
            governanceExecutable,
            "Depositor who starts 1 day late finishes cooldown when governance becomes executable"
        );

        // At that moment, operation is Ready but depositor has just finished exiting
        vm.warp(governanceExecutable);
        assertEq(uint256(prodTimelock.getOperationState(id)), uint256(TimelockController.OperationState.Ready));
    }

    function test_TC16_boundaryDepositorAlmostOneDayLate() public {
        // Depositor who waits until T + 86399 (almost 1 day) still has time:
        // 86399 + 604800 = 691199 < 691200 (governance execution time)
        uint256 proposalTime = block.timestamp;

        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("boundary_almost_late");
        vm.prank(deployer);
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, PRODUCTION_DELAY);

        uint256 depositorReactionDelay = 86399; // almost 1 day
        uint256 depositorCooldownEnd = proposalTime + depositorReactionDelay + SEVEN_DAYS;
        uint256 governanceExecutable = proposalTime + PRODUCTION_DELAY;

        // Depositor exits 1 second BEFORE governance becomes executable
        assertLt(
            depositorCooldownEnd,
            governanceExecutable,
            "Depositor reacting at T+86399 must exit before governance executes"
        );
        assertEq(governanceExecutable - depositorCooldownEnd, 1, "Safety margin must be exactly 1 second");
    }

    function test_TC16_boundaryDepositorExactlyOneDayLate() public {
        // Depositor who waits until T + 86400 (exactly 1 day) does NOT have time:
        // 86400 + 604800 = 691200 == governance execution time (front-run risk)
        uint256 proposalTime = block.timestamp;

        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("boundary_exactly_one_day");
        vm.prank(deployer);
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, PRODUCTION_DELAY);

        uint256 depositorReactionDelay = 86400; // exactly 1 day
        uint256 depositorCooldownEnd = proposalTime + depositorReactionDelay + SEVEN_DAYS;
        uint256 governanceExecutable = proposalTime + PRODUCTION_DELAY;

        // Depositor exits at EXACTLY the same time as governance — attacker can front-run
        assertEq(
            depositorCooldownEnd,
            governanceExecutable,
            "Depositor reacting at T+86400 finishes at exact governance execution time (front-run risk)"
        );
    }

    function test_TC16_safetyMarginIsOneDay() public pure {
        // The minimum safety margin is exactly 1 day (86400 seconds)
        // Uses PRODUCTION_DELAY, not MIN_DELAY (which is 0 in launch phase)
        uint256 safetyMargin = PRODUCTION_DELAY - SEVEN_DAYS;
        assertEq(safetyMargin, 86400, "Safety margin must be exactly 1 day");
        assertEq(safetyMargin, 24 * 60 * 60, "Safety margin must be 24 hours");
    }
}

// ============================================================
// TC-17: Attack Vectors (Post-Phase 2)
// ============================================================
contract TimelockController_TC17_AttackVectors is TimelockControllerTestBase {
    function setUp() public override {
        super.setUp();
        _setupPhase2();
    }

    function test_TC17_postPhase2GovernorIsSoleProposer() public view {
        assertTrue(timelock.hasRole(PROPOSER_ROLE, governor), "Governor must be sole proposer");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must NOT be proposer");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, attacker), "Attacker must NOT be proposer");
    }

    function test_TC17_postPhase2DeployerNoRoles() public view {
        assertFalse(timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must NOT have PROPOSER_ROLE");
        assertFalse(timelock.hasRole(CANCELLER_ROLE, deployer), "Deployer must NOT have CANCELLER_ROLE");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Deployer must NOT have DEFAULT_ADMIN_ROLE");
    }

    function test_TC17_attackerCannotGrantProposer() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(PROPOSER_ROLE, attacker);
    }

    function test_TC17_deployerCannotGrantProposer() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(PROPOSER_ROLE, deployer);
    }

    function test_TC17_adminRoleOnlySelf() public view {
        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), "Only timelock itself must have DEFAULT_ADMIN_ROLE"
        );
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, governor));
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, attacker));
    }

    function test_TC17_attackerCannotGrantViaDirectCall() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(CANCELLER_ROLE, attacker);
    }

    function test_TC17_onlyTimelockCanGrantRoles() public {
        // The only way to grant roles is via a scheduled operation through the timelock
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, executor1));
        bytes32 salt = keccak256("timelock_grant");

        vm.prank(governor); // governor is the proposer now
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        _executeOperation(address(timelock), 0, data, bytes32(0), salt);
        assertTrue(timelock.hasRole(PROPOSER_ROLE, executor1), "Role must be grantable only via scheduled operation");
    }
}

// ============================================================
// TC-18: Self-Administration Invariant
// ============================================================
contract TimelockController_TC18_SelfAdmin is TimelockControllerTestBase {
    function test_TC18_directUpdateDelayByDeployerReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, deployer));
        timelock.updateDelay(0);
    }

    function test_TC18_directUpdateDelayByAttackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, attacker));
        timelock.updateDelay(0);
    }

    function test_TC18_directGrantRoleByDeployerReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(PROPOSER_ROLE, attacker);
    }

    function test_TC18_directGrantRoleByAttackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(PROPOSER_ROLE, attacker);
    }

    function test_TC18_directRevokeRoleByDeployerReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.revokeRole(PROPOSER_ROLE, deployer);
    }

    function test_TC18_directRevokeRoleByAttackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.revokeRole(PROPOSER_ROLE, deployer);
    }

    function test_TC18_scheduledUpdateDelaySucceeds() public {
        uint256 newDelay = 1_000_000;
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 salt = keccak256("sched_update_delay");

        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.getMinDelay(), newDelay, "updateDelay via scheduled op must succeed");
    }

    function test_TC18_scheduledGrantRoleSucceeds() public {
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, executor1));
        bytes32 salt = keccak256("sched_grant");

        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertTrue(timelock.hasRole(PROPOSER_ROLE, executor1), "grantRole via scheduled op must succeed");
    }

    function test_TC18_scheduledRevokeRoleSucceeds() public {
        // First grant executor1 PROPOSER_ROLE
        bytes memory grantData = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, executor1));
        bytes32 salt1 = keccak256("sched_grant_first");
        _scheduleOperation(address(timelock), 0, grantData, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, grantData, bytes32(0), salt1);
        assertTrue(timelock.hasRole(PROPOSER_ROLE, executor1));

        // Now revoke it
        bytes memory revokeData = abi.encodeCall(IAccessControl.revokeRole, (PROPOSER_ROLE, executor1));
        bytes32 salt2 = keccak256("sched_revoke");
        _scheduleOperation(address(timelock), 0, revokeData, bytes32(0), salt2, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, revokeData, bytes32(0), salt2);

        assertFalse(timelock.hasRole(PROPOSER_ROLE, executor1), "revokeRole via scheduled op must succeed");
    }

    function test_TC18_delayChangeSubjectToOldDelay() public {
        // First, update to a non-zero delay so we can test that scheduling
        // with a shorter delay than the current minimum reverts.
        uint256 initialNewDelay = PRODUCTION_DELAY;
        bytes memory updateData = abi.encodeCall(TimelockController.updateDelay, (initialNewDelay));
        bytes32 updateSalt = keccak256("set_prod_delay");
        // Launch phase: MIN_DELAY=0, so schedule with 0 delay
        _scheduleOperation(address(timelock), 0, updateData, bytes32(0), updateSalt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, updateData, bytes32(0), updateSalt);
        assertEq(timelock.getMinDelay(), initialNewDelay, "Delay must be updated to production delay");

        // Now changing the delay requires scheduling with the current (production) delay
        uint256 reducedDelay = 500_000; // less than current PRODUCTION_DELAY
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (reducedDelay));
        bytes32 salt = keccak256("delay_subject");

        // Must still use the current production delay to schedule
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, reducedDelay, initialNewDelay)
        );
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, reducedDelay);

        // Schedule with current delay succeeds
        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, initialNewDelay);
        vm.warp(block.timestamp + initialNewDelay);
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.getMinDelay(), reducedDelay, "Delay change must succeed when scheduled with old delay");
    }
}
