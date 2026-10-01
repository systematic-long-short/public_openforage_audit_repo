// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./FinalizeDelayProfile.sol";
import "./AllowlistGatedUpgradeable.sol";
import "./ForageGovernorTimelockGuard.sol";
import "./interfaces/IAllowlist.sol";
import "./libraries/GuardianAuthorityClassifier.sol";

/// @title GuardianModule — Extracted guardian logic for ForageGovernor
/// @notice Manages guardian permissions, pause actions, proposal cancellation,
///         and emergency execution. Deployed as a separate contract to keep
///         ForageGovernor under the EIP-170 contract size limit (24,576 bytes).
/// @dev OF-I09: The governor intentionally cannot pause itself. Self-pause would create an
/// irrecoverable deadlock — the governor would be unable to unpause itself since proposals
/// require an active (unpaused) governor. Guardian pause targets are restricted to protocol
/// contracts via the _pausableTargets whitelist (OF-M01).
contract GuardianModule is Initializable, UUPSUpgradeable, FinalizeDelayProfile, AllowlistGatedUpgradeable {
    // ── Custom errors ────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidParameter();
    error ArrayLengthMismatch();
    error DuplicateGuardian();
    error NotGuardian();
    error InsufficientPermissions();
    error InvalidEmergencyAction();
    error EmptyProposal();
    error Unauthorized();
    error TargetNotWhitelisted(address target);
    error TargetHasNoCode(address target);
    error SelfTargetingGuardianMutation();
    error InvalidPermissionBitmask(); // OF-16-014
    error PauseAndCancelForbidden(); // OF-16-005
    error ProtectedGovernanceTarget(address target); // OF-13-044: infrastructure-protection reverts
    error NotPendingTimelock();
    error StaleTimelockAuthority();
    error FinalizeDelayNotElapsed(); // OF-NEW-07 (12th audit)
    error ProposalExpired(); // OF-NEW-07 (12th audit)
    error GuardianCannotLoosen();
    error GuardianCannotMoveFunds();
    error SuccessorNotPreCommitted();
    error RotationNotReady();
    error RoutineRotationIdOccupied(bytes32 operationId);
    error GuardianFreshDeploymentRequired(uint256 observedVersion);
    error CustodianRegistryUnavailable(address registry);
    error CanonicalCustodianRegistryRequired();

    // ── Custom events ────────────────────────────────────────────────────
    event GuardianPaused(address indexed guardian, address indexed target);
    event GuardianCanceled(address indexed guardian, uint256 proposalId);
    event GuardianEmergencyExecuted(address indexed guardian, address[] targets);
    /// @dev OF-16-013: Summary event when emergency execution has failures.
    event EmergencyExecutionSummary(address indexed guardian, uint256 totalCalls, uint256 failureCount);
    /// @dev OF-004 (8th audit): Per-target success/failure events for emergency batch.
    event EmergencyCallSucceeded(address indexed target, bytes4 selector);
    event EmergencyCallFailed(address indexed target, bytes4 selector, bytes reason);
    event GuardianPermissionsUpdated(address indexed guardian, uint256 oldPermissions, uint256 newPermissions);
    event PausableTargetUpdated(address indexed target, bool allowed);
    event GuardianFastPathRationale(bytes4 indexed selector, bytes32 indexed rationaleId);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);
    event TimelockUpdated(address indexed oldTimelock, address indexed newTimelock);
    event TimelockProposed(address indexed currentTimelock, address indexed pendingTimelock);
    event CustodianRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    /// @dev OF-16-021: Emitted when a pending timelock transfer is silently cancelled by upgrade.
    event PendingTimelockClearedByUpgrade(address indexed cancelledPendingTimelock);

    // ── Delay constants ─────────────────────────────────────────────────
    uint256 public constant ROUTINE_ROTATION_DELAY = 8 days;
    uint256 public constant ACCELERATED_ROTATION_FLOOR = 10 minutes;
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-NEW-07 (12th audit)

    // ── Permission constants ─────────────────────────────────────────────
    uint256 public constant PERMISSION_CAN_PAUSE = 1 << 0;
    uint256 public constant PERMISSION_CAN_CANCEL = 1 << 1;
    uint256 public constant PERMISSION_CAN_EXECUTE_EMERGENCY = 1 << 2;
    uint256 public constant PERMISSION_CAN_PROPOSE = 1 << 3;
    /// @dev OF-16-014: Max valid bitmask = all defined permission bits OR'd together.
    /// Prevents granting undefined future permission bits via type(uint256).max.
    uint256 public constant MAX_VALID_PERMISSIONS =
        PERMISSION_CAN_PAUSE | PERMISSION_CAN_CANCEL | PERMISSION_CAN_EXECUTE_EMERGENCY | PERMISSION_CAN_PROPOSE;
    bytes32 public constant RATIONALE_GUARDIAN_PERMISSIONS_FAST_PATH = "GUARDIAN_PERMISSIONS_FAST_PATH";
    bytes32 public constant RATIONALE_PAUSABLE_TARGET_FAST_PATH = "PAUSABLE_TARGET_FAST_PATH";
    bytes32 public constant SLOT_GUARDIAN_SEAT = keccak256("GUARDIAN_SEAT");
    bytes32 public constant SLOT_VOTING_DELEGATION = keccak256("VOTING_DELEGATION");
    bytes32 public constant SLOT_LARGE_DELEGATOR = keccak256("LARGE_DELEGATOR");
    bytes32 public constant SLOT_CUSTODY_EXECUTOR = keccak256("CUSTODY_EXECUTOR");
    bytes32 public constant SLOT_GOVERNOR = keccak256("GOVERNOR");
    bytes4 private constant _GOVERNOR_RELAY_SELECTOR = bytes4(keccak256("relay(address,uint256,bytes)"));
    bytes4 private constant _TIMELOCK_SCHEDULE_SELECTOR =
        bytes4(keccak256("schedule(address,uint256,bytes,bytes32,bytes32,uint256)"));
    bytes4 private constant _TIMELOCK_SCHEDULE_BATCH_SELECTOR =
        bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)"));
    bytes4 private constant _TIMELOCK_VIEW_SELECTOR = bytes4(keccak256("timelock()"));
    uint256 private constant _GUARDIAN_CALLER_FLAG = 1 << 8;
    uint256 private constant _GUARDIAN_DEPTH_MASK = _GUARDIAN_CALLER_FLAG - 1;
    uint256 private constant _REGISTRY_TARGET = 32;

    // ── State variables ──────────────────────────────────────────────────
    address public governor;
    address public timelock;
    mapping(address => uint256) public guardianPermissions;
    address[] internal _guardianList;
    mapping(address => bool) internal _pausableTargets;
    /// @dev OF-L04: Pending timelock for two-step transfer pattern
    address public pendingTimelock;
    /// @dev OF-NEW-07 (12th audit): Proposal timestamp for finalize delay enforcement
    uint256 public timelockProposedAt;

    struct Rotation {
        bytes32 slot;
        address current;
        address successor;
        uint256 proposedAt;
        uint256 readyAt;
        bool executed;
        bool exists;
    }

    mapping(bytes32 => mapping(address => address)) public preCommittedSuccessor;
    mapping(bytes32 => address) public activeSlotHolder;
    mapping(bytes32 => Rotation) internal _rotations;
    mapping(bytes32 => mapping(address => bool)) internal _rotationApprovals;
    mapping(bytes32 => uint256) internal _rotationApprovalCount;
    mapping(bytes32 => uint256) internal _acceleratedRotationGenerations;
    mapping(bytes32 => uint256) internal _routineRotationGenerations;

    /// @dev Reserved storage gap for future upgrades.
    uint256 private _freshLayoutVersion;
    GuardianAuthorityClassifier.CustodianRegistryStorage private _custodianRegistry;
    uint256[32] private __gap;

    // ── Constructor ──────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier freshOnly() {
        _requireFreshDeployment();
        _;
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0 || _getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    function _requireFreshDeployment() private view {
        uint256 version = _freshLayoutVersion;
        if (version != 1) revert GuardianFreshDeploymentRequired(version);
    }

    // ── Initializer ──────────────────────────────────────────────────────

    function initialize(address, address, address[] calldata, uint256[] calldata) external pure {
        revert CanonicalCustodianRegistryRequired();
    }

    function initializeWithCustodianRegistry(
        address governor_,
        address timelock_,
        address custodianRegistry_,
        address[] calldata initialGuardians_,
        uint256[] calldata initialGuardianPermissions_
    ) external onlyDuringConstructionBeforeInitialization initializer {
        if (governor_ == address(0)) revert ZeroAddress();
        if (timelock_ == address(0)) revert ZeroAddress();
        if (custodianRegistry_ == address(0)) revert ZeroAddress();
        if (initialGuardians_.length != initialGuardianPermissions_.length) revert ArrayLengthMismatch();

        governor = governor_;
        timelock = timelock_;
        _custodianRegistry.canonical = custodianRegistry_;
        emit CustodianRegistryUpdated(address(0), custodianRegistry_);

        for (uint256 i; i < initialGuardians_.length;) {
            if (initialGuardians_[i] == address(0)) revert ZeroAddress();
            if (initialGuardianPermissions_[i] == 0) revert InvalidParameter();
            if (guardianPermissions[initialGuardians_[i]] != 0) revert DuplicateGuardian();
            // OF-19-001: Validate permissions (MAX_VALID + PauseAndCancelForbidden)
            _validatePermissions(initialGuardianPermissions_[i]);

            guardianPermissions[initialGuardians_[i]] = initialGuardianPermissions_[i];
            _guardianList.push(initialGuardians_[i]);

            emit GuardianPermissionsUpdated(initialGuardians_[i], 0, initialGuardianPermissions_[i]);
            unchecked {
                ++i;
            }
        }
        _freshLayoutVersion = 1;
    }

    // ── Guardian functions ───────────────────────────────────────────────

    function guardianPause(address target) external freshOnly onlyAllowedCaller {
        _requireCurrentGuardianModule();
        uint256 permissions = guardianPermissions[msg.sender];
        if (permissions == 0) revert NotGuardian();
        if ((permissions & PERMISSION_CAN_PAUSE) == 0) {
            revert InsufficientPermissions();
        }
        if (target == address(0)) revert ZeroAddress();
        // OF-M01: Enforce pausable target whitelist
        if (!_pausableTargets[target]) revert TargetNotWhitelisted(target);

        // OF-004: Verify target has code before calling
        if (target.code.length == 0) revert TargetHasNoCode(target);

        // OF-13-045: Typed interface call instead of raw .call()
        IEmergencyPausable(target).pause();

        emit GuardianPaused(msg.sender, target);
    }

    /// @notice OF-001 (8th audit): Blocks guardian from cancelling proposals that would
    /// remove or modify their own guardian permissions (governance entrenchment prevention).
    function guardianCancel(uint256 proposalId) external freshOnly onlyAllowedCaller {
        _requireCurrentGuardianModule();
        uint256 permissions = guardianPermissions[msg.sender];
        if (permissions == 0) revert NotGuardian();
        if ((permissions & PERMISSION_CAN_CANCEL) == 0) {
            revert InsufficientPermissions();
        }
        address registryOwner = GuardianAuthorityClassifier.custodianRegistryOwner(_custodianRegistry);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            IForageGovernorMinimal(governor).getProposalParams(proposalId);
        if (targets.length == 0) revert EmptyProposal();

        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _revertIfSelfTargetingGuardianMutation(registryOwner, targets, calldatas, budget);

        // Cancel via governor (governor._validateCancel authorizes this module)
        IForageGovernorMinimal(governor).cancel(targets, values, calldatas, descriptionHash);

        emit GuardianCanceled(msg.sender, proposalId);
    }

    function guardianExecuteEmergency(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas)
        external
        freshOnly
        onlyAllowedCaller
    {
        _requireCurrentGuardianModule();
        uint256 permissions = guardianPermissions[msg.sender];
        if (permissions == 0) revert NotGuardian();
        if ((permissions & PERMISSION_CAN_EXECUTE_EMERGENCY) == 0) {
            revert InsufficientPermissions();
        }
        _requireVerifiedAccount(msg.sender);
        if (targets.length == 0) revert EmptyProposal();
        if (targets.length != values.length || targets.length != calldatas.length) {
            revert ArrayLengthMismatch();
        }

        // OF-M01: Validate all targets are whitelisted.
        for (uint256 i; i < calldatas.length;) {
            bytes4 selector = _validateEmergencyCalldata(calldatas[i]);
            // OF-M01: Enforce pausable target whitelist
            if (!_pausableTargets[targets[i]]) revert TargetNotWhitelisted(targets[i]);
            // OF-004: Verify target has code before calling
            if (targets[i].code.length == 0) revert TargetHasNoCode(targets[i]);
            if (selector == IEmergencyPausable.pause.selector && (permissions & PERMISSION_CAN_PAUSE) == 0) {
                revert InsufficientPermissions();
            }
            // Block ETH forwarding in emergency calls (OF-023)
            require(values[i] == 0, "no ETH forwarding");
            unchecked {
                ++i;
            }
        }

        // OF-004 (8th audit): Execute with try/catch — emit per-call results.
        // In an emergency, partial success is preferable to an all-or-nothing revert
        // that leaves every contract unpaused because one target failed.
        // OF-16-013: Track and emit failure count for monitoring.
        uint256 failureCount;
        for (uint256 i; i < targets.length;) {
            if (!_executeEmergencyCalldata(targets[i], calldatas[i])) ++failureCount;
            unchecked {
                ++i;
            }
        }

        emit GuardianEmergencyExecuted(msg.sender, targets);
        if (failureCount > 0) {
            emit EmergencyExecutionSummary(msg.sender, targets.length, failureCount);
        }
    }

    // ── Guardian management ──────────────────────────────────────────────

    /// @dev OF-16-014: Validates bitmask against MAX_VALID_PERMISSIONS.
    /// @dev OF-16-005: Forbids PERMISSION_CAN_PAUSE | PERMISSION_CAN_CANCEL on same guardian.
    function setGuardianPermissions(address guardian_, uint256 permissions) external freshOnly onlyAllowedCaller {
        _requireCurrentTimelockAuthority();
        if (guardian_ == address(0)) revert ZeroAddress();
        _requireVerifiedAccount(guardian_);
        // OF-19-001: Use shared helper for OF-16-014 + OF-16-005 validation
        // (permissions == 0 is a valid removal, skip validation)
        if (permissions != 0) {
            _validatePermissions(permissions);
        }

        uint256 oldPermissions = guardianPermissions[guardian_];
        guardianPermissions[guardian_] = permissions;

        if (permissions == 0 && oldPermissions != 0) {
            for (uint256 i; i < _guardianList.length;) {
                if (_guardianList[i] == guardian_) {
                    _guardianList[i] = _guardianList[_guardianList.length - 1];
                    _guardianList.pop();
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        } else if (oldPermissions == 0 && permissions != 0) {
            _guardianList.push(guardian_);
        }

        emit GuardianPermissionsUpdated(guardian_, oldPermissions, permissions);
        emit GuardianFastPathRationale(
            GuardianModule.setGuardianPermissions.selector, RATIONALE_GUARDIAN_PERMISSIONS_FAST_PATH
        );
    }

    function removeGuardian(address guardian_) external freshOnly onlyAllowedCaller {
        _requireCurrentTimelockAuthority();
        if (guardian_ == address(0)) revert ZeroAddress();
        if (guardianPermissions[guardian_] == 0) revert NotGuardian();

        uint256 oldPermissions = guardianPermissions[guardian_];
        guardianPermissions[guardian_] = 0;

        for (uint256 i; i < _guardianList.length;) {
            if (_guardianList[i] == guardian_) {
                _guardianList[i] = _guardianList[_guardianList.length - 1];
                _guardianList.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        emit GuardianPermissionsUpdated(guardian_, oldPermissions, 0);
    }

    // ── OF-M01: Pausable target whitelist management ──────────────────────

    /// @notice Add or remove an address from the pausable target whitelist.
    /// @param target The contract address to whitelist or de-whitelist.
    /// @param allowed True to add, false to remove.
    function setPausableTarget(address target, bool allowed) external freshOnly onlyAllowedCaller {
        _requireCurrentTimelockAuthority();
        if (target == address(0)) revert ZeroAddress();
        _pausableTargets[target] = allowed;
        emit PausableTargetUpdated(target, allowed);
        emit GuardianFastPathRationale(GuardianModule.setPausableTarget.selector, RATIONALE_PAUSABLE_TARGET_FAST_PATH);
    }

    function setPreCommittedSuccessor(bytes32 slot, address current, address successor)
        external
        freshOnly
        onlyAllowedCaller
    {
        _requireCurrentTimelockAuthority();
        if (slot == bytes32(0) || current == address(0) || successor == address(0)) revert ZeroAddress();
        _requireVerifiedAccount(successor);
        preCommittedSuccessor[slot][current] = successor;
        if (activeSlotHolder[slot] == address(0)) {
            activeSlotHolder[slot] = current;
        }
    }

    function proposeAcceleratedRotation(bytes32 slot, address current, address successor)
        external
        freshOnly
        onlyAllowedCaller
        returns (bytes32)
    {
        _requireGuardian(msg.sender);
        if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
        return _proposeAcceleratedRotation(slot, current, successor);
    }

    function approveAcceleratedRotation(bytes32 operationId) external freshOnly onlyAllowedCaller {
        _requireGuardian(msg.sender);
        Rotation storage rotation = _rotations[operationId];
        if (!rotation.exists) revert InvalidParameter();
        if (_rotationApprovals[operationId][msg.sender]) return;
        _rotationApprovals[operationId][msg.sender] = true;
        _rotationApprovalCount[operationId] += 1;
        if (_rotationApprovalCount[operationId] >= 4 && rotation.readyAt == 0) {
            rotation.readyAt = block.timestamp + ACCELERATED_ROTATION_FLOOR;
        }
    }

    function acceleratedRotationReady(bytes32 operationId) external view returns (bool) {
        Rotation storage rotation = _rotations[operationId];
        return rotation.readyAt != 0;
    }

    function acceleratedRotationReadyAt(bytes32 operationId) external view returns (uint256) {
        return _rotations[operationId].readyAt;
    }

    function executeAcceleratedRotation(bytes32 operationId) external freshOnly onlyAllowedCaller {
        Rotation storage rotation = _rotations[operationId];
        if (rotation.readyAt == 0 || block.timestamp < rotation.readyAt || rotation.executed) {
            revert RotationNotReady();
        }
        if (_acceleratedRotationExpired(rotation)) revert RotationNotReady();
        if (preCommittedSuccessor[rotation.slot][rotation.current] != rotation.successor) {
            revert SuccessorNotPreCommitted();
        }
        _requireVerifiedAccount(rotation.successor);
        rotation.executed = true;
        activeSlotHolder[rotation.slot] = rotation.successor;
        bytes32 tupleId = _acceleratedRotationTupleId(rotation.slot, rotation.current, rotation.successor);
        _acceleratedRotationGenerations[tupleId] += 1;
        if (rotation.slot == SLOT_GUARDIAN_SEAT) {
            _replaceGuardianSeat(rotation.current, rotation.successor);
        }
    }

    function proposeRoutineRotation(bytes32 slot, address current, address successor)
        external
        freshOnly
        onlyAllowedCaller
        returns (bytes32)
    {
        if (msg.sender != governor) revert Unauthorized();
        if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
        bytes32 tupleId = _routineRotationTupleId(slot, current, successor);
        uint256 generation = _routineRotationGenerations[tupleId];
        bytes32 operationId = _rotationOperationId(tupleId, generation);
        Rotation storage existing = _rotations[operationId];
        if (existing.exists) {
            if (!existing.executed) return operationId;
            generation += 1;
            operationId = _rotationOperationId(tupleId, generation);
            if (_rotations[operationId].exists) revert RoutineRotationIdOccupied(operationId);
            _routineRotationGenerations[tupleId] = generation;
        }
        Rotation storage next = _rotations[operationId];
        next.slot = slot;
        next.current = current;
        next.successor = successor;
        next.proposedAt = block.timestamp;
        next.exists = true;
        return operationId;
    }

    function finalizeRoutineRotation(bytes32 operationId) external freshOnly onlyAllowedCaller {
        _requireCurrentTimelockAuthority();
        Rotation storage rotation = _rotations[operationId];
        if (!rotation.exists || rotation.executed) revert RotationNotReady();
        if (block.timestamp < rotation.proposedAt + ROUTINE_ROTATION_DELAY) revert FinalizeDelayNotElapsed();
        if (preCommittedSuccessor[rotation.slot][rotation.current] != rotation.successor) {
            revert SuccessorNotPreCommitted();
        }
        _requireVerifiedAccount(rotation.successor);
        rotation.executed = true;
        activeSlotHolder[rotation.slot] = rotation.successor;
        bytes32 tupleId = _routineRotationTupleId(rotation.slot, rotation.current, rotation.successor);
        _routineRotationGenerations[tupleId] += 1;
    }

    function guardianLoosenCap(address, bytes4, uint256) external pure {
        revert GuardianCannotLoosen();
    }

    function guardianMoveFunds(address, address, uint256) external pure {
        revert GuardianCannotMoveFunds();
    }

    function guardianAt(uint256 index) external view returns (address) {
        return _guardianList[index];
    }

    function guardianCount() external view returns (uint256) {
        return _guardianList.length;
    }

    // ── OF-016: Governor/Timelock update functions ──────────────────────

    /// @notice OF-016: Update the governor address. Only callable by the timelock.
    function updateGovernor(address newGovernor) external freshOnly onlyAllowedCaller {
        _requireCurrentTimelockAuthority();
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = governor;
        governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    /// @notice OF-L04: Propose a new timelock address. Only callable by the current timelock.
    /// Two-step pattern prevents irrecoverable loss from setting a wrong timelock address.
    /// @dev OF-NEW-07 (12th audit): Records proposal timestamp for FINALIZE_DELAY enforcement.
    function proposeTimelock(address newTimelock) external freshOnly onlyAllowedCaller {
        _requireCurrentTimelockAuthority();
        if (newTimelock == address(0)) revert ZeroAddress();
        pendingTimelock = newTimelock;
        timelockProposedAt = block.timestamp; // OF-NEW-07 (12th audit)
        emit TimelockProposed(timelock, newTimelock);
    }

    /// @notice OF-L04: Accept the pending timelock role. Only callable by the pending timelock.
    /// @dev OF-NEW-07 (12th audit): Enforces FINALIZE_DELAY and PROPOSAL_EXPIRY.
    function acceptTimelock() external freshOnly onlyAllowedCaller {
        if (msg.sender != pendingTimelock) revert NotPendingTimelock();
        if (block.timestamp < timelockProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > timelockProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldTimelock = timelock;
        timelock = pendingTimelock;
        pendingTimelock = address(0);
        timelockProposedAt = 0;
        emit TimelockUpdated(oldTimelock, timelock);
    }

    /// @notice Wire the allowlist that gates every entry point. Timelock authority only.
    function setAllowlist(address allowlist_) external freshOnly {
        _requireCurrentTimelockAuthority();
        _transitionAllowlist(allowlist_);
    }

    function _proposeAcceleratedRotation(bytes32 slot, address current, address successor)
        private
        returns (bytes32 operationId)
    {
        bytes32 tupleId = _acceleratedRotationTupleId(slot, current, successor);
        uint256 generation = _acceleratedRotationGenerations[tupleId];
        operationId = _rotationOperationId(tupleId, generation);
        if (_acceleratedRotationExpired(_rotations[operationId])) {
            generation += 1;
            _acceleratedRotationGenerations[tupleId] = generation;
            operationId = _rotationOperationId(tupleId, generation);
        }
        Rotation storage rotation = _rotations[operationId];
        if (rotation.exists) return operationId;
        rotation.slot = slot;
        rotation.current = current;
        rotation.successor = successor;
        rotation.proposedAt = block.timestamp;
        rotation.exists = true;
    }

    function _acceleratedRotationExpired(Rotation storage rotation) private view returns (bool) {
        return rotation.readyAt != 0 && block.timestamp > rotation.readyAt + PROPOSAL_EXPIRY;
    }

    function _acceleratedRotationTupleId(bytes32 slot, address current, address successor)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("accelerated", slot, current, successor));
    }

    function _routineRotationTupleId(bytes32 slot, address current, address successor) private pure returns (bytes32) {
        return keccak256(abi.encode("routine", slot, current, successor));
    }

    function _rotationOperationId(bytes32 tupleId, uint256 generation) private pure returns (bytes32) {
        return generation == 0 ? tupleId : keccak256(abi.encode(tupleId, generation));
    }

    function _requireGuardian(address account) internal view {
        if (guardianPermissions[account] == 0) revert NotGuardian();
    }

    function _requireVerifiedAccount(address account) internal view {
        if (!IAllowlist(allowlist()).isAllowed(account)) revert IAllowlist.CallerNotAllowed(account);
    }

    function _replaceGuardianSeat(address current, address successor) internal {
        uint256 permissions = guardianPermissions[current];
        if (permissions == 0) revert NotGuardian();
        for (uint256 i; i < _guardianList.length;) {
            if (_guardianList[i] == current) {
                _guardianList[i] = successor;
                guardianPermissions[successor] = permissions;
                guardianPermissions[current] = 0;
                emit GuardianPermissionsUpdated(current, permissions, 0);
                emit GuardianPermissionsUpdated(successor, 0, permissions);
                return;
            }
            unchecked {
                ++i;
            }
        }
        revert NotGuardian();
    }

    // ── OF-011: UUPS upgrade authorization ────────────────────────────

    /// @dev Caller gate on the inherited upgrade entry point; runs before the proxy check.
    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        freshOnly
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    /// @dev OF-011: Only the timelock can authorize upgrades.
    /// OF-031: Clear pendingTimelock on upgrade to prevent stale two-step state.
    function _authorizeUpgrade(address) internal override {
        _requireFreshDeployment();
        _requireCurrentTimelockAuthority();
        // OF-16-021: Emit event when pending timelock is cleared by upgrade
        if (pendingTimelock != address(0)) {
            emit PendingTimelockClearedByUpgrade(pendingTimelock);
        }
        pendingTimelock = address(0);
        timelockProposedAt = 0; // OF-NEW-07 (12th audit)
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    /// @dev OF-19-001: Shared permission validation used by both initialize() and
    /// setGuardianPermissions(). Enforces MAX_VALID_PERMISSIONS (OF-16-014) and
    /// PauseAndCancelForbidden (OF-16-005) in a single place.
    function _validatePermissions(uint256 permissions) internal pure {
        if (permissions > MAX_VALID_PERMISSIONS) revert InvalidPermissionBitmask();
        if ((permissions & PERMISSION_CAN_PAUSE != 0) && (permissions & PERMISSION_CAN_CANCEL != 0)) {
            revert PauseAndCancelForbidden();
        }
    }

    function _requireCurrentGuardianModule() internal view {
        (bool ok, bytes memory data) = governor.staticcall(abi.encodeWithSignature("guardianModule()"));
        if (!ok || data.length < 32 || abi.decode(data, (address)) != address(this)) revert Unauthorized();
    }

    function _requireCurrentTimelockAuthority() internal view {
        if (msg.sender != timelock) revert Unauthorized();

        (bool ok, bytes memory data) = governor.staticcall(abi.encodeWithSelector(_TIMELOCK_VIEW_SELECTOR));
        if (!ok || data.length != 32) revert Unauthorized();
        if (abi.decode(data, (address)) != timelock) revert StaleTimelockAuthority();
    }

    function _validateEmergencyCalldata(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) revert InvalidEmergencyAction();
        selector = bytes4(data[:4]);
        if (selector == IEmergencyPausable.pause.selector) {
            if (data.length != 4) revert InvalidEmergencyAction();
            return selector;
        }

        if (
            selector == IEmergencyRiskVaultCaps.shrinkWeeklyRedemptionCapBps.selector
                || selector == IEmergencyRiskVaultCaps.shrinkWeeklyMintCapBps.selector
                || selector == IEmergencyRiskVaultCaps.shrinkDailyMintCapBps.selector
                || selector == IEmergencyRiskVaultCaps.tightenMaxDeploymentRatioBps.selector
                || selector == IEmergencyRiskVaultCaps.tightenDeploymentBufferBps.selector
                || selector == IEmergencyAtRiskCaps.shrinkWeeklyWithdrawalCapBps.selector
                || selector == IEmergencyHLBridgeCaps.shrinkPerBlockDeployCap.selector
                || selector == IEmergencyHLBridgeCaps.shrinkPerDayDeployCap.selector
                || selector == IEmergencyUSDCTreasuryCaps.shrinkLossRateCapBps.selector
                || selector == IEmergencyAllowlistCaps.revoke.selector
                || selector == IEmergencyAllowlistCaps.shrinkApprovalsPerDayCap.selector
        ) {
            if (data.length != 36) revert InvalidEmergencyAction();
            return selector;
        }

        if (
            selector == IEmergencyRiskVaultCaps.shrinkPerBlockMintCap.selector
                || selector == IEmergencyHLBridgeCaps.tightenReturnCapitalCaps.selector
        ) {
            if (data.length != 68) revert InvalidEmergencyAction();
            return selector;
        }

        if (selector == IEmergencyHLBridgeCaps.freezeAttestations.selector) {
            if (data.length != 4) revert InvalidEmergencyAction();
            return selector;
        }

        revert InvalidEmergencyAction();
    }

    function _executeEmergencyCalldata(address target, bytes calldata data) internal returns (bool success) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == IEmergencyPausable.pause.selector) {
            try IEmergencyPausable(target).pause() {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        return _executeEmergencyCapCalldata(target, data, selector);
    }

    function _executeEmergencyCapCalldata(address target, bytes calldata data, bytes4 selector)
        internal
        returns (bool success)
    {
        if (selector == IEmergencyRiskVaultCaps.shrinkWeeklyRedemptionCapBps.selector) {
            (uint256 bps) = abi.decode(data[4:], (uint256));
            try IEmergencyRiskVaultCaps(target).shrinkWeeklyRedemptionCapBps(bps) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyRiskVaultCaps.shrinkWeeklyMintCapBps.selector) {
            (uint256 bps) = abi.decode(data[4:], (uint256));
            try IEmergencyRiskVaultCaps(target).shrinkWeeklyMintCapBps(bps) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyRiskVaultCaps.shrinkDailyMintCapBps.selector) {
            return _executeEmergencyDailyMintCap(target, data, selector);
        }
        if (selector == IEmergencyRiskVaultCaps.shrinkPerBlockMintCap.selector) {
            (uint256 bps, uint256 maxAmount) = abi.decode(data[4:], (uint256, uint256));
            try IEmergencyRiskVaultCaps(target).shrinkPerBlockMintCap(bps, maxAmount) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyRiskVaultCaps.tightenMaxDeploymentRatioBps.selector) {
            (uint256 bps) = abi.decode(data[4:], (uint256));
            try IEmergencyRiskVaultCaps(target).tightenMaxDeploymentRatioBps(bps) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyRiskVaultCaps.tightenDeploymentBufferBps.selector) {
            (uint256 bps) = abi.decode(data[4:], (uint256));
            try IEmergencyRiskVaultCaps(target).tightenDeploymentBufferBps(bps) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyAtRiskCaps.shrinkWeeklyWithdrawalCapBps.selector) {
            (uint256 bps) = abi.decode(data[4:], (uint256));
            try IEmergencyAtRiskCaps(target).shrinkWeeklyWithdrawalCapBps(bps) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyAllowlistCaps.revoke.selector) {
            (address account) = abi.decode(data[4:], (address));
            try IEmergencyAllowlistCaps(target).revoke(account) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyAllowlistCaps.shrinkApprovalsPerDayCap.selector) {
            (uint32 newCap) = abi.decode(data[4:], (uint32));
            try IEmergencyAllowlistCaps(target).shrinkApprovalsPerDayCap(newCap) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        return _executeEmergencyUSDCTreasuryCalldata(target, data, selector);
    }

    function _executeEmergencyUSDCTreasuryCalldata(address target, bytes calldata data, bytes4 selector)
        internal
        returns (bool success)
    {
        if (selector == IEmergencyUSDCTreasuryCaps.shrinkLossRateCapBps.selector) {
            uint256 cap = abi.decode(data[4:], (uint256));
            try IEmergencyUSDCTreasuryCaps(target).shrinkLossRateCapBps(cap) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        return _executeEmergencyHLBridgeCalldata(target, data, selector);
    }

    function _executeEmergencyDailyMintCap(address target, bytes calldata data, bytes4 selector)
        internal
        returns (bool success)
    {
        uint256 bps = abi.decode(data[4:], (uint256));
        try IEmergencyRiskVaultCaps(target).shrinkDailyMintCapBps(bps) {
            emit EmergencyCallSucceeded(target, selector);
            return true;
        } catch (bytes memory reason) {
            emit EmergencyCallFailed(target, selector, reason);
            return false;
        }
    }

    function _executeEmergencyHLBridgeCalldata(address target, bytes calldata data, bytes4 selector)
        internal
        returns (bool success)
    {
        if (selector == IEmergencyHLBridgeCaps.freezeAttestations.selector) {
            try IEmergencyHLBridgeCaps(target).freezeAttestations() {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyHLBridgeCaps.shrinkPerBlockDeployCap.selector) {
            (uint256 cap) = abi.decode(data[4:], (uint256));
            try IEmergencyHLBridgeCaps(target).shrinkPerBlockDeployCap(cap) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyHLBridgeCaps.shrinkPerDayDeployCap.selector) {
            (uint256 cap) = abi.decode(data[4:], (uint256));
            try IEmergencyHLBridgeCaps(target).shrinkPerDayDeployCap(cap) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        if (selector == IEmergencyHLBridgeCaps.tightenReturnCapitalCaps.selector) {
            (uint16 perCallBps, uint16 perDayBps) = abi.decode(data[4:], (uint16, uint16));
            try IEmergencyHLBridgeCaps(target).tightenReturnCapitalCaps(perCallBps, perDayBps) {
                emit EmergencyCallSucceeded(target, selector);
                return true;
            } catch (bytes memory reason) {
                emit EmergencyCallFailed(target, selector, reason);
                return false;
            }
        }
        revert InvalidEmergencyAction();
    }

    /// @dev OF-001: Reverts when a proposal would change the calling guardian's authority.
    function _revertIfSelfTargetingGuardianMutation(
        address registryOwner,
        address[] memory targets,
        bytes[] memory calldatas,
        GovernancePayloadBudget.Budget memory budget
    ) internal view {
        if (targets.length != calldatas.length || targets.length > GovernancePayloadBudget.MAX_TOP_LEVEL_ACTIONS) {
            revert SelfTargetingGuardianMutation();
        }
        for (uint256 i; i < calldatas.length;) {
            uint256 length = calldatas[i].length;
            uint256 maximum = GovernancePayloadBudget.MAX_TOP_LEVEL_ACTION_BYTES;
            if (length > maximum - budget.actionBytes) revert SelfTargetingGuardianMutation();
            budget.actionBytes += length;
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < targets.length;) {
            if (_isSelfTargetingGuardianMutation(registryOwner, targets[i], calldatas[i], 0, budget)) {
                revert SelfTargetingGuardianMutation();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isSelfTargetingGuardianMutation(
        address registryOwner,
        address target,
        bytes memory data,
        uint256 depthAndCaller,
        GovernancePayloadBudget.Budget memory budget
    ) internal view returns (bool) {
        if (target == registryOwner && registryOwner != timelock) return true;
        if (data.length < 4) return false;

        bytes4 selector = _selectorOf(data);
        if (target == governor) {
            if (selector == _GOVERNOR_RELAY_SELECTOR) {
                _consumeGuardianVisits(budget, 1);
                (bool ok, GovernancePayloadBudget.OperationPayload memory nested) =
                    GuardianAuthorityClassifier.tryDecodeRelay(data);
                if (!ok) revert SelfTargetingGuardianMutation();
                if (nested.data.length >= data.length) revert SelfTargetingGuardianMutation();
                bool protectedChild = nested.target == governor || nested.target == timelock;
                uint256 nestedDepth = depthAndCaller & _GUARDIAN_DEPTH_MASK;
                if (protectedChild) {
                    _requireGuardianDepth(nestedDepth);
                    nestedDepth += 1;
                }
                nestedDepth |= _GUARDIAN_CALLER_FLAG;
                return _isSelfTargetingGuardianMutation(registryOwner, nested.target, nested.data, nestedDepth, budget);
            }
        }

        if (target == timelock) {
            if (selector == _TIMELOCK_SCHEDULE_SELECTOR) {
                _consumeGuardianVisits(budget, 1);
                (bool ok, GovernancePayloadBudget.OperationPayload memory nested) =
                    GuardianAuthorityClassifier.tryDecodeSchedule(data);
                if (!ok) revert SelfTargetingGuardianMutation();
                if (nested.data.length >= data.length) revert SelfTargetingGuardianMutation();
                bool protectedChild = nested.target == governor || nested.target == timelock;
                uint256 nestedDepth = depthAndCaller & _GUARDIAN_DEPTH_MASK;
                if (protectedChild) {
                    _requireGuardianDepth(nestedDepth);
                    nestedDepth += 1;
                }
                return _isSelfTargetingGuardianMutation(registryOwner, nested.target, nested.data, nestedDepth, budget);
            }
            if (selector == _TIMELOCK_SCHEDULE_BATCH_SELECTOR) {
                return _scanScheduleBatchForSelfMutation(registryOwner, data, depthAndCaller, budget);
            }
        }

        uint256 flags;
        if (target == governor) {
            flags = 4;
        } else if (target == timelock) {
            flags = 8;
        } else if (target == address(this)) {
            flags = 16;
            if (
                selector == GuardianModule.executeAcceleratedRotation.selector && data.length >= 36
                    && _rotationCanExecuteAgain(data)
            ) flags |= 2;
        } else if (target == _custodianRegistry.canonical) {
            flags = _REGISTRY_TARGET;
        }
        if (target == timelock && (depthAndCaller & _GUARDIAN_CALLER_FLAG) != 0) target = governor;
        GuardianAuthorityClassifier.Context memory context =
            GuardianAuthorityClassifier.Context(msg.sender, target, governor, address(this), flags);
        return GuardianAuthorityClassifier.isAuthorityMutation(data, context);
    }

    function _rotationCanExecuteAgain(bytes memory data) private view returns (bool) {
        Rotation storage rotation = _rotations[bytes32(_wordAt(data, 4))];
        return !rotation.executed;
    }

    function _scanScheduleBatchForSelfMutation(
        address registryOwner,
        bytes memory data,
        uint256 depthAndCaller,
        GovernancePayloadBudget.Budget memory budget
    ) private view returns (bool) {
        (bool headerOk, GovernancePayloadBudget.ScheduleBatchHeader memory header) =
            GuardianAuthorityClassifier.tryReadScheduleBatchHeader(data);
        if (!headerOk) revert SelfTargetingGuardianMutation();
        _consumeGuardianVisits(budget, header.targetsLength);
        (bool targetsOk, address[] memory targets) =
            GuardianAuthorityClassifier.tryReadScheduleBatchTargets(data, header);
        if (!targetsOk) revert SelfTargetingGuardianMutation();
        uint256 depth = depthAndCaller & _GUARDIAN_DEPTH_MASK;
        for (uint256 i; i < targets.length;) {
            if ((targets[i] == governor || targets[i] == timelock)) _requireGuardianDepth(depth);
            unchecked {
                ++i;
            }
        }
        (bool batchOk, GovernancePayloadBudget.ScheduleBatchPayload memory batch) =
            GuardianAuthorityClassifier.tryDecodeScheduleBatch(data, header, targets);
        if (!batchOk || batch.targets.length != batch.calldatas.length) revert SelfTargetingGuardianMutation();
        return _scanScheduleBatchChildren(registryOwner, data, depth, budget, batch);
    }

    function _scanScheduleBatchChildren(
        address registryOwner,
        bytes memory data,
        uint256 depth,
        GovernancePayloadBudget.Budget memory budget,
        GovernancePayloadBudget.ScheduleBatchPayload memory batch
    ) private view returns (bool) {
        for (uint256 i; i < batch.targets.length;) {
            address nestedTarget = batch.targets[i];
            bytes memory nestedData = batch.calldatas[i];
            bool protectedChild = nestedTarget == governor || nestedTarget == timelock;
            if (protectedChild && nestedData.length >= data.length) revert SelfTargetingGuardianMutation();
            uint256 nestedDepth = depth;
            if (protectedChild) {
                _requireGuardianDepth(nestedDepth);
                nestedDepth += 1;
            }
            if (_isSelfTargetingGuardianMutation(registryOwner, nestedTarget, nestedData, nestedDepth, budget)) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _consumeGuardianVisits(GovernancePayloadBudget.Budget memory budget, uint256 visits) private pure {
        uint256 maximum = GovernancePayloadBudget.MAX_NESTED_ACTION_VISITS;
        if (visits > maximum - budget.nestedVisits) revert SelfTargetingGuardianMutation();
        budget.nestedVisits += visits;
    }

    function _requireGuardianDepth(uint256 depth) private pure {
        if (depth >= GovernancePayloadBudget.MAX_TIMELOCK_DEPTH) revert SelfTargetingGuardianMutation();
    }

    function _selectorOf(bytes memory data) internal pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _firstAddressArgument(bytes memory data) internal pure returns (address account) {
        assembly {
            // OF-NEW-06 (12th audit): Mask upper 12 bytes to prevent dirty-bits bypass.
            account := and(mload(add(data, 0x24)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _wordAt(bytes memory data, uint256 offset) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), offset))
        }
    }

    // ── View functions ───────────────────────────────────────────────────

    /// @notice Check if an address is a whitelisted pausable target.
    function isPausableTarget(address target) external view returns (bool) {
        return _pausableTargets[target];
    }

    function isGuardian(address account) external view returns (bool) {
        return guardianPermissions[account] != 0;
    }

    function getGuardianPermissions(address account) external view returns (uint256) {
        return guardianPermissions[account];
    }

    function getGuardians() external view returns (address[] memory) {
        return _guardianList;
    }

    /// @notice Check if an address has a specific guardian permission.
    function hasPermission(address account, uint256 permission) external view returns (bool) {
        return guardianPermissions[account] & permission != 0;
    }
}

/// @dev OF-004 (8th audit): Type-safe interface for emergency pause.
interface IEmergencyPausable {
    function pause() external;
}

interface IEmergencyRiskVaultCaps {
    function shrinkWeeklyRedemptionCapBps(uint256 bps) external;
    function shrinkWeeklyMintCapBps(uint256 bps) external;
    function shrinkDailyMintCapBps(uint256 bps) external;
    function shrinkPerBlockMintCap(uint256 bps, uint256 maxAmount) external;
    function tightenMaxDeploymentRatioBps(uint256 bps) external;
    function tightenDeploymentBufferBps(uint256 bps) external;
}

interface IEmergencyAtRiskCaps {
    function shrinkWeeklyWithdrawalCapBps(uint256 bps) external;
}

interface IEmergencyHLBridgeCaps {
    function freezeAttestations() external;
    function shrinkPerBlockDeployCap(uint256 cap) external;
    function shrinkPerDayDeployCap(uint256 cap) external;
    function tightenReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) external;
}

interface IEmergencyAllowlistCaps {
    function revoke(address account) external;
    function shrinkApprovalsPerDayCap(uint32 newCap) external;
}

interface IEmergencyUSDCTreasuryCaps {
    function shrinkLossRateCapBps(uint256 newCapBps) external;
}

/// @dev Minimal interface for GuardianModule to interact with ForageGovernor.
interface IForageGovernorMinimal {
    function guardianModule() external view returns (address);

    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);

    function getProposalParams(uint256 proposalId)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash);

    function proposalProposer(uint256 proposalId) external view returns (address proposer);
}
