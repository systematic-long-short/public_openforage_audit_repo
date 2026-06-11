// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/TimelockControllerTestBase.sol";

/// @title TimelockInvariantHandler - Drives state changes for invariant testing
/// Exercises schedule/execute/cancel/warp AND role-change pathways via scheduled self-targeted ops
contract TimelockInvariantHandler is Test {
    TimelockController public timelock;
    MockTarget public mockTarget;
    address public deployer;

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    uint256 public constant MIN_DELAY = 0; // Launch phase: 0 seconds

    uint256 public scheduleCount;
    uint256 public executeCount;
    uint256 public cancelCount;
    uint256 public roleGrantExecutedCount;

    // Track operation IDs, salts, targets, and payloads for correct execution
    bytes32[] public operationIds;
    mapping(bytes32 => bytes32) public operationSalts;
    mapping(bytes32 => address) public operationTargets;
    mapping(bytes32 => bytes) public operationPayloads;
    mapping(bytes32 => bool) public isExecuted;
    mapping(bytes32 => bool) public isCancelled;

    // Track addresses that attempted direct grantRole (should never succeed)
    address[] public directGrantAttempts;
    // Track grantees from executed scheduled grantRole ops
    mapping(bytes32 => address) public granteeForOp;
    address[] public executedGrantees;

    constructor(TimelockController _timelock, MockTarget _mockTarget, address _deployer) {
        timelock = _timelock;
        mockTarget = _mockTarget;
        deployer = _deployer;
    }

    function scheduleOperation(uint256 seed) external {
        bytes memory data = abi.encodeCall(MockTarget.doSomething, ());
        bytes32 salt = keccak256(abi.encodePacked("inv_schedule", scheduleCount, seed));
        address target = address(mockTarget);
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), salt);

        if (timelock.isOperation(id)) return;

        vm.prank(deployer);
        timelock.schedule(target, 0, data, bytes32(0), salt, MIN_DELAY);

        operationIds.push(id);
        operationSalts[id] = salt;
        operationTargets[id] = target;
        operationPayloads[id] = data;
        scheduleCount++;
    }

    /// @dev Schedule a self-targeted grantRole operation (R-09: role changes via scheduled ops)
    function scheduleGrantRole(uint256 seed) external {
        address grantee = address(uint160(uint256(keccak256(abi.encodePacked("role_target", seed)))));
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, grantee));
        bytes32 salt = keccak256(abi.encodePacked("inv_grant", scheduleCount, seed));
        address target = address(timelock);
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), salt);

        if (timelock.isOperation(id)) return;

        vm.prank(deployer);
        try timelock.schedule(target, 0, data, bytes32(0), salt, MIN_DELAY) {
            operationIds.push(id);
            operationSalts[id] = salt;
            operationTargets[id] = target;
            operationPayloads[id] = data;
            granteeForOp[id] = grantee;
            scheduleCount++;
        } catch {}
    }

    /// @dev Attempt direct grantRole — MUST revert (deployer has no DEFAULT_ADMIN_ROLE)
    function attemptDirectGrantRole(uint256 seed) external {
        address grantee = address(uint160(uint256(keccak256(abi.encodePacked("direct_grant", seed)))));
        directGrantAttempts.push(grantee);
        vm.prank(deployer);
        vm.expectRevert();
        timelock.grantRole(PROPOSER_ROLE, grantee);
    }

    /// @dev Attempt direct revokeRole — MUST revert (deployer has no DEFAULT_ADMIN_ROLE)
    function attemptDirectRevokeRole() external {
        vm.prank(deployer);
        vm.expectRevert();
        timelock.revokeRole(PROPOSER_ROLE, deployer);
    }

    /// @dev Execute a ready operation using its stored target and payload
    function executeRandomReady(uint256 index) external {
        if (operationIds.length == 0) return;
        index = index % operationIds.length;

        bytes32 id = operationIds[index];
        if (!timelock.isOperationReady(id)) return;
        if (isExecuted[id]) return;

        address target = operationTargets[id];
        bytes memory data = operationPayloads[id];
        bytes32 salt = operationSalts[id];

        try timelock.execute(target, 0, data, bytes32(0), salt) {
            isExecuted[id] = true;
            executeCount++;
            if (target == address(timelock) && granteeForOp[id] != address(0)) {
                executedGrantees.push(granteeForOp[id]);
                roleGrantExecutedCount++;
            }
        } catch {}
    }

    function cancelRandom(uint256 index) external {
        if (operationIds.length == 0) return;
        index = index % operationIds.length;

        bytes32 id = operationIds[index];
        if (!timelock.isOperationPending(id)) return;
        if (isCancelled[id]) return;

        vm.prank(deployer);
        try timelock.cancel(id) {
            isCancelled[id] = true;
            cancelCount++;
        } catch {}
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    function getOperationCount() external view returns (uint256) {
        return operationIds.length;
    }

    function getDirectGrantAttemptCount() external view returns (uint256) {
        return directGrantAttempts.length;
    }

    function getExecutedGranteeCount() external view returns (uint256) {
        return executedGrantees.length;
    }
}

// ============================================================
// TC-20: Invariant Tests
// ============================================================
contract TimelockController_TC20_Invariants is TimelockControllerTestBase {
    TimelockInvariantHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new TimelockInvariantHandler(timelock, mockTarget, deployer);
        targetContract(address(handler));
    }

    /// @dev DEFAULT_ADMIN_ROLE must only be held by address(this) (the timelock itself) (R-08)
    function invariant_defaultAdminOnlySelf() public view {
        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "TimelockController must always hold DEFAULT_ADMIN_ROLE"
        );
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Deployer must never have DEFAULT_ADMIN_ROLE");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, attacker), "Attacker must never have DEFAULT_ADMIN_ROLE");
    }

    /// @dev EXECUTOR_ROLE for address(0) (open execution) must never be revoked (R-07)
    function invariant_openExecution() public view {
        assertTrue(
            timelock.hasRole(EXECUTOR_ROLE, address(0)),
            "Open execution (EXECUTOR_ROLE for address(0)) must always be maintained"
        );
    }

    /// @dev Deployer must always retain PROPOSER_ROLE (handler never executes revoke ops) (R-05, R-09)
    function invariant_proposerRoleConservation() public view {
        assertTrue(
            timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must retain PROPOSER_ROLE (no revoke scheduled)"
        );
    }

    /// @dev Direct grantRole attempts must never succeed — only scheduled ops can grant roles (R-09)
    /// Checks that addresses targeted by direct grantRole do NOT have PROPOSER_ROLE
    /// (unless they also received it via an executed scheduled op)
    function invariant_noDirectRoleGrants() public view {
        uint256 attemptCount = handler.getDirectGrantAttemptCount();
        uint256 executedCount = handler.getExecutedGranteeCount();
        for (uint256 i = 0; i < attemptCount; i++) {
            address attempted = handler.directGrantAttempts(i);
            // Check if this address was also granted via scheduled op
            bool grantedViaScheduled = false;
            for (uint256 j = 0; j < executedCount; j++) {
                if (handler.executedGrantees(j) == attempted) {
                    grantedViaScheduled = true;
                    break;
                }
            }
            if (!grantedViaScheduled) {
                assertFalse(
                    timelock.hasRole(PROPOSER_ROLE, attempted),
                    "Direct grantRole must never succeed - address should NOT have PROPOSER_ROLE"
                );
            }
        }
    }

    /// @dev getMinDelay() must not change without a scheduled updateDelay operation
    function invariant_minDelayConserved() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY, "minDelay must not change without scheduled operation");
    }

    /// @dev All tracked operations must be in a valid state with consistent timestamps
    function invariant_validStateTransitions() public view {
        uint256 count = handler.getOperationCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.operationIds(i);
            TimelockController.OperationState state = timelock.getOperationState(id);

            assertTrue(uint256(state) <= 3, "Operation state must be a valid OperationState enum value");

            if (state == TimelockController.OperationState.Unset) {
                assertEq(timelock.getTimestamp(id), 0, "Unset operation must have timestamp 0");
            }

            if (state == TimelockController.OperationState.Done) {
                assertEq(timelock.getTimestamp(id), 1, "Done operation must have timestamp 1");
            }

            if (state == TimelockController.OperationState.Waiting) {
                assertGt(
                    timelock.getTimestamp(id),
                    block.timestamp,
                    "Waiting operation must have timestamp > block.timestamp"
                );
            }

            if (state == TimelockController.OperationState.Ready) {
                uint256 ts = timelock.getTimestamp(id);
                assertLe(ts, block.timestamp, "Ready operation must have timestamp <= block.timestamp");
                assertGt(ts, 1, "Ready operation must have timestamp > 1");
            }
        }
    }
}
