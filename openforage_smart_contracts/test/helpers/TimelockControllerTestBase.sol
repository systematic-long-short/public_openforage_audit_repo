// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "./MockTarget.sol";
import "./RevertTarget.sol";
import "./MockPausable.sol";
import "./MockOwnable.sol";

/// @title TimelockControllerTestBase - Shared setup for all TimelockController tests
abstract contract TimelockControllerTestBase is Test {
    TimelockController public timelock;

    address public deployer;
    address public governor;
    address public attacker;
    address public executor1;
    address public executor2;

    MockTarget public mockTarget;
    RevertTarget public revertTarget;
    MockPausable public mockPausable;
    MockOwnable public mockOwnable;

    // Two-phase governance: Launch: 0s delay (team controls all votes).
    // Production (June 2026): 691200s (8 days). See forage_governor.md § Governance Parameter Phases.
    uint256 public constant MIN_DELAY = 0; // Launch phase: 0 seconds
    uint256 public constant PRODUCTION_DELAY = 691200; // Production phase: 8 days
    uint256 public constant SEVEN_DAYS = 604800; // 7 days in seconds

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function setUp() public virtual {
        // OF-001: Warp past timestamp 1 — OZ TimelockController uses timestamp=1
        // as the _DONE_TIMESTAMP sentinel. With delay=0 (launch phase), scheduling
        // at block.timestamp=1 collides with the sentinel. Warp to t=100.
        vm.warp(100);

        deployer = makeAddr("deployer");
        governor = makeAddr("governor");
        attacker = makeAddr("attacker");
        executor1 = makeAddr("executor1");
        executor2 = makeAddr("executor2");

        // Deploy TimelockController per OpenForage launch config:
        // - minDelay: 0 (launch phase; team controls all votes)
        // - proposers: [deployer] (temporary)
        // - executors: [address(0)] (open execution)
        // - admin: address(0) (no external admin)
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;

        address[] memory executors = new address[](1);
        executors[0] = address(0);

        vm.prank(deployer);
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // Deploy mock contracts
        mockTarget = new MockTarget();
        revertTarget = new RevertTarget();
        mockPausable = new MockPausable(address(timelock), governor);
        mockOwnable = new MockOwnable(address(timelock));
    }

    /// @dev Schedule a single operation via the timelock
    function _scheduleOperation(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) internal returns (bytes32) {
        vm.prank(deployer);
        timelock.schedule(target, value, data, predecessor, salt, delay);
        return timelock.hashOperation(target, value, data, predecessor, salt);
    }

    /// @dev Schedule a batch operation via the timelock
    function _scheduleBatchOperation(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) internal returns (bytes32) {
        vm.prank(deployer);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    /// @dev Execute a single operation via the timelock
    function _executeOperation(address target, uint256 value, bytes memory data, bytes32 predecessor, bytes32 salt)
        internal
    {
        timelock.execute(target, value, data, predecessor, salt);
    }

    /// @dev Warp past the minimum delay
    function _warpPastDelay() internal {
        vm.warp(block.timestamp + MIN_DELAY);
    }

    /// @dev Schedule and execute an operation to grant governor the PROPOSER_ROLE
    /// and CANCELLER_ROLE, then revoke deployer's roles (Phase 2 config)
    function _setupPhase2() internal {
        // 1. Grant PROPOSER_ROLE to governor
        bytes memory grantProposerData = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt1 = keccak256("grant_proposer_governor");
        _scheduleOperation(address(timelock), 0, grantProposerData, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, grantProposerData, bytes32(0), salt1);

        // 2. Grant CANCELLER_ROLE to governor
        bytes memory grantCancellerData = abi.encodeCall(IAccessControl.grantRole, (CANCELLER_ROLE, governor));
        bytes32 salt2 = keccak256("grant_canceller_governor");
        _scheduleOperation(address(timelock), 0, grantCancellerData, bytes32(0), salt2, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, grantCancellerData, bytes32(0), salt2);

        // 3. Revoke PROPOSER_ROLE from deployer
        bytes memory revokeProposerData = abi.encodeCall(IAccessControl.revokeRole, (PROPOSER_ROLE, deployer));
        bytes32 salt3 = keccak256("revoke_proposer_deployer");
        // Now governor can schedule too, use deployer one last time
        _scheduleOperation(address(timelock), 0, revokeProposerData, bytes32(0), salt3, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, revokeProposerData, bytes32(0), salt3);

        // 4. Revoke CANCELLER_ROLE from deployer (governor must schedule this)
        bytes memory revokeCancellerData = abi.encodeCall(IAccessControl.revokeRole, (CANCELLER_ROLE, deployer));
        bytes32 salt4 = keccak256("revoke_canceller_deployer");
        vm.prank(governor);
        timelock.schedule(address(timelock), 0, revokeCancellerData, bytes32(0), salt4, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, revokeCancellerData, bytes32(0), salt4);
    }

    /// @dev Helper to build a simple doSomething() call
    function _doSomethingCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(MockTarget.doSomething, ());
    }

    /// @dev Helper to encode a state bitmap for expected revert matching
    function _encodeStateBitmap(TimelockController.OperationState state) internal pure returns (bytes32) {
        return bytes32(1 << uint8(state));
    }
}
