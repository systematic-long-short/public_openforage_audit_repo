// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./FinalizeDelayProfile.sol";

/// @title GuardianModule — Extracted guardian logic for ForageGovernor
/// @notice Manages guardian permissions, pause actions, proposal cancellation,
///         and emergency execution. Deployed as a separate contract to keep
///         ForageGovernor under the EIP-170 contract size limit (24,576 bytes).
/// @dev OF-I09: The governor intentionally cannot pause itself. Self-pause would create an
/// irrecoverable deadlock — the governor would be unable to unpause itself since proposals
/// require an active (unpaused) governor. Guardian pause targets are restricted to protocol
/// contracts via the _pausableTargets whitelist (OF-M01).
contract GuardianModule is Initializable, UUPSUpgradeable, FinalizeDelayProfile {
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
    error FinalizeDelayNotElapsed(); // OF-NEW-07 (12th audit)
    error ProposalExpired(); // OF-NEW-07 (12th audit)
    error GuardianCannotLoosen();
    error GuardianCannotMoveFunds();
    error SuccessorNotPreCommitted();
    error RotationNotReady();

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
    bytes4 private constant _UPGRADE_TO_AND_CALL_SELECTOR = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    bytes4 private constant _SET_GOVERNOR_GUARDIAN_MODULE_SELECTOR = bytes4(keccak256("setGuardianModule(address)"));
    bytes4 private constant _PROPOSE_DOWNSTREAM_GUARDIAN_MODULE_SELECTOR =
        bytes4(keccak256("proposeGuardianModule(address)"));
    bytes4 private constant _FINALIZE_DOWNSTREAM_GUARDIAN_MODULE_SELECTOR =
        bytes4(keccak256("finalizeGuardianModule()"));
    bytes4 private constant _GOVERNOR_RELAY_SELECTOR = bytes4(keccak256("relay(address,uint256,bytes)"));
    bytes4 private constant _TIMELOCK_SCHEDULE_SELECTOR =
        bytes4(keccak256("schedule(address,uint256,bytes,bytes32,bytes32,uint256)"));
    bytes4 private constant _TIMELOCK_SCHEDULE_BATCH_SELECTOR =
        bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)"));
    bytes4 private constant _GUARDIAN_MODULE_VIEW_SELECTOR = bytes4(keccak256("guardianModule()"));
    uint256 private constant _GUARDIAN_MODULE_LOOKUP_GAS = 30_000;

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

    /// @dev Reserved storage gap for future upgrades.
    uint256[36] private __gap;

    // ── Constructor ──────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer ──────────────────────────────────────────────────────

    function initialize(
        address governor_,
        address timelock_,
        address[] calldata initialGuardians_,
        uint256[] calldata initialGuardianPermissions_
    ) external initializer {
        if (governor_ == address(0)) revert ZeroAddress();
        if (timelock_ == address(0)) revert ZeroAddress();
        if (initialGuardians_.length != initialGuardianPermissions_.length) revert ArrayLengthMismatch();

        governor = governor_;
        timelock = timelock_;

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
    }

    // ── Guardian functions ───────────────────────────────────────────────

    function guardianPause(address target) external {
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
    function guardianCancel(uint256 proposalId) external {
        _requireCurrentGuardianModule();
        uint256 permissions = guardianPermissions[msg.sender];
        if (permissions == 0) revert NotGuardian();
        if ((permissions & PERMISSION_CAN_CANCEL) == 0) {
            revert InsufficientPermissions();
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            IForageGovernorMinimal(governor).getProposalParams(proposalId);
        if (targets.length == 0) revert EmptyProposal();

        // V7: guardian-proposed spam is cancelable by the guardian set. For ordinary
        // governance proposals, keep the older protected-mutation cancellation guard.
        if (!_isGuardianProposedProposal(proposalId)) {
            _revertIfSelfTargetingGuardianMutation(msg.sender, targets, calldatas);
        }

        // Cancel via governor (governor._validateCancel authorizes this module)
        IForageGovernorMinimal(governor).cancel(targets, values, calldatas, descriptionHash);

        emit GuardianCanceled(msg.sender, proposalId);
    }

    function guardianExecuteEmergency(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas)
        external
    {
        _requireCurrentGuardianModule();
        uint256 permissions = guardianPermissions[msg.sender];
        if (permissions == 0) revert NotGuardian();
        if ((permissions & PERMISSION_CAN_EXECUTE_EMERGENCY) == 0) {
            revert InsufficientPermissions();
        }
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
    function setGuardianPermissions(address guardian_, uint256 permissions) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (guardian_ == address(0)) revert ZeroAddress();
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

    function removeGuardian(address guardian_) external {
        if (msg.sender != timelock) revert Unauthorized();
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
    function setPausableTarget(address target, bool allowed) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (target == address(0)) revert ZeroAddress();
        _pausableTargets[target] = allowed;
        emit PausableTargetUpdated(target, allowed);
        emit GuardianFastPathRationale(GuardianModule.setPausableTarget.selector, RATIONALE_PAUSABLE_TARGET_FAST_PATH);
    }

    function setPreCommittedSuccessor(bytes32 slot, address current, address successor) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (slot == bytes32(0) || current == address(0) || successor == address(0)) revert ZeroAddress();
        preCommittedSuccessor[slot][current] = successor;
        if (activeSlotHolder[slot] == address(0)) {
            activeSlotHolder[slot] = current;
        }
    }

    function proposeAcceleratedRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
        _requireGuardian(msg.sender);
        if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
        bytes32 operationId = keccak256(abi.encode("accelerated", slot, current, successor));
        Rotation storage rotation = _rotations[operationId];
        if (!rotation.exists) {
            rotation.slot = slot;
            rotation.current = current;
            rotation.successor = successor;
            rotation.proposedAt = block.timestamp;
            rotation.exists = true;
        }
        return operationId;
    }

    function approveAcceleratedRotation(bytes32 operationId) external {
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

    function executeAcceleratedRotation(bytes32 operationId) external {
        Rotation storage rotation = _rotations[operationId];
        if (rotation.readyAt == 0 || block.timestamp < rotation.readyAt || rotation.executed) {
            revert RotationNotReady();
        }
        rotation.executed = true;
        activeSlotHolder[rotation.slot] = rotation.successor;
        if (rotation.slot == SLOT_GUARDIAN_SEAT) {
            _replaceGuardianSeat(rotation.current, rotation.successor);
        }
    }

    function proposeRoutineRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
        if (msg.sender != governor) revert Unauthorized();
        if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
        bytes32 operationId = keccak256(abi.encode("routine", slot, current, successor));
        Rotation storage rotation = _rotations[operationId];
        rotation.slot = slot;
        rotation.current = current;
        rotation.successor = successor;
        rotation.proposedAt = block.timestamp;
        rotation.exists = true;
        return operationId;
    }

    function finalizeRoutineRotation(bytes32 operationId) external {
        if (msg.sender != timelock) revert Unauthorized();
        Rotation storage rotation = _rotations[operationId];
        if (!rotation.exists || rotation.executed) revert RotationNotReady();
        if (block.timestamp < rotation.proposedAt + ROUTINE_ROTATION_DELAY) revert FinalizeDelayNotElapsed();
        rotation.executed = true;
        activeSlotHolder[rotation.slot] = rotation.successor;
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
    function updateGovernor(address newGovernor) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = governor;
        governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    /// @notice OF-L04: Propose a new timelock address. Only callable by the current timelock.
    /// Two-step pattern prevents irrecoverable loss from setting a wrong timelock address.
    /// @dev OF-NEW-07 (12th audit): Records proposal timestamp for FINALIZE_DELAY enforcement.
    function proposeTimelock(address newTimelock) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (newTimelock == address(0)) revert ZeroAddress();
        pendingTimelock = newTimelock;
        timelockProposedAt = block.timestamp; // OF-NEW-07 (12th audit)
        emit TimelockProposed(timelock, newTimelock);
    }

    /// @notice OF-L04: Accept the pending timelock role. Only callable by the pending timelock.
    /// @dev OF-NEW-07 (12th audit): Enforces FINALIZE_DELAY and PROPOSAL_EXPIRY.
    function acceptTimelock() external {
        if (msg.sender != pendingTimelock) revert NotPendingTimelock();
        if (block.timestamp < timelockProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > timelockProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldTimelock = timelock;
        timelock = pendingTimelock;
        pendingTimelock = address(0);
        timelockProposedAt = 0;
        emit TimelockUpdated(oldTimelock, timelock);
    }

    function _requireGuardian(address account) internal view {
        if (guardianPermissions[account] == 0) revert NotGuardian();
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

    /// @dev OF-011: Only the timelock can authorize upgrades.
    /// OF-031: Clear pendingTimelock on upgrade to prevent stale two-step state.
    function _authorizeUpgrade(address) internal override {
        if (msg.sender != timelock) revert Unauthorized();
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
                || selector == IEmergencyRiskVaultCaps.tightenMaxDeploymentRatioBps.selector
                || selector == IEmergencyRiskVaultCaps.tightenDeploymentBufferBps.selector
                || selector == IEmergencyAtRiskCaps.shrinkWeeklyWithdrawalCapBps.selector
                || selector == IEmergencyHLBridgeCaps.shrinkPerBlockDeployCap.selector
                || selector == IEmergencyHLBridgeCaps.shrinkPerDayDeployCap.selector
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
        return _executeEmergencyHLBridgeCalldata(target, data, selector);
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

    /// @dev OF-001: Reverts if any action in the proposal would modify the calling
    /// guardian's own permissions or route a protected governance mutation through
    /// relay/timelock scheduling. Prevents governance entrenchment.
    function _revertIfSelfTargetingGuardianMutation(
        address guardian_,
        address[] memory targets,
        bytes[] memory calldatas
    ) internal view {
        for (uint256 i; i < targets.length;) {
            if (_isProtectedGuardianMutation(guardian_, targets[i], calldatas[i])) {
                revert SelfTargetingGuardianMutation();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isGuardianProposedProposal(uint256 proposalId) internal view returns (bool) {
        try IForageGovernorMinimal(governor).proposalProposer(proposalId) returns (address proposer) {
            return (guardianPermissions[proposer] & PERMISSION_CAN_PROPOSE) != 0;
        } catch {
            return false;
        }
    }

    function _isProtectedGuardianMutation(address guardian_, address target, bytes memory data)
        internal
        view
        returns (bool)
    {
        if (data.length < 4) return false;

        bytes4 selector = _selectorOf(data);
        if (target == governor) {
            if (selector == _SET_GOVERNOR_GUARDIAN_MODULE_SELECTOR) return true;
            if (selector == _GOVERNOR_RELAY_SELECTOR) {
                (bool ok, address nestedTarget, bytes memory nestedData) = _tryDecodeRelayForGuardianScan(data);
                return ok && nestedData.length < data.length
                    && _isProtectedGuardianMutation(guardian_, nestedTarget, nestedData);
            }
        }

        if (target == timelock) {
            if (selector == _TIMELOCK_SCHEDULE_SELECTOR) {
                (bool ok, address nestedTarget, bytes memory nestedData) = _tryDecodeScheduleForGuardianScan(data);
                return ok && nestedData.length < data.length
                    && _isProtectedGuardianMutation(guardian_, nestedTarget, nestedData);
            }
            if (selector == _TIMELOCK_SCHEDULE_BATCH_SELECTOR) {
                (bool ok, address[] memory nestedTargets, bytes[] memory nestedCalldatas) =
                    _tryDecodeScheduleBatchForGuardianScan(data);
                if (!ok || nestedTargets.length != nestedCalldatas.length) return false;
                for (uint256 i; i < nestedTargets.length;) {
                    if (
                        nestedCalldatas[i].length < data.length
                            && _isProtectedGuardianMutation(guardian_, nestedTargets[i], nestedCalldatas[i])
                    ) {
                        return true;
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        bool protectedDownstreamSelector = selector == _SET_GOVERNOR_GUARDIAN_MODULE_SELECTOR
            || selector == _PROPOSE_DOWNSTREAM_GUARDIAN_MODULE_SELECTOR
            || selector == _FINALIZE_DOWNSTREAM_GUARDIAN_MODULE_SELECTOR;
        if (protectedDownstreamSelector && _isCurrentDownstreamGuardianModuleTarget(target)) return true;

        if (target != address(this)) return false;

        if (selector == GuardianModule.setGuardianPermissions.selector && data.length >= 68) {
            // setGuardianPermissions(address,uint256): 4 + 32 + 32 = 68 bytes
            address targetGuardian = _firstAddressArgument(data);
            if (targetGuardian == guardian_) return true;
        } else if (selector == GuardianModule.removeGuardian.selector && data.length >= 36) {
            // removeGuardian(address): 4 + 32 = 36 bytes
            address targetGuardian = _firstAddressArgument(data);
            if (targetGuardian == guardian_) return true;
        }

        // OF-004 (11th audit): Any proposal that would upgrade, change governor,
        // propose a new timelock, or modify pausable targets on this module is blocked.
        return selector == _UPGRADE_TO_AND_CALL_SELECTOR || selector == GuardianModule.updateGovernor.selector
            || selector == GuardianModule.proposeTimelock.selector
            || selector == GuardianModule.setPausableTarget.selector;
    }

    function _selectorOf(bytes memory data) internal pure returns (bytes4 selector) {
        assembly { selector := mload(add(data, 0x20)) }
    }

    function _firstAddressArgument(bytes memory data) internal pure returns (address account) {
        assembly {
            // OF-NEW-06 (12th audit): Mask upper 12 bytes to prevent dirty-bits bypass.
            account := and(mload(add(data, 0x24)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _isCurrentDownstreamGuardianModuleTarget(address target) internal view returns (bool) {
        if (target == address(this) || target == governor || target.code.length == 0 || !_pausableTargets[target]) {
            return false;
        }
        bool ok;
        uint256 returnSize;
        address module_;
        bytes4 selector = _GUARDIAN_MODULE_VIEW_SELECTOR;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(_GUARDIAN_MODULE_LOOKUP_GAS, target, ptr, 0x04, ptr, 0x20)
            returnSize := returndatasize()
            module_ := and(mload(ptr), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        return ok && returnSize >= 32 && module_ == address(this);
    }

    function _tryDecodeRelayForGuardianScan(bytes memory data)
        internal
        pure
        returns (bool ok, address nestedTarget, bytes memory nestedData)
    {
        if (!_hasRange(data, 4, 96)) return (false, address(0), nestedData);

        (bool targetOk, address decodedTarget) = _tryReadAddress(data, 4);
        if (!targetOk) return (false, address(0), nestedData);

        (bool dataOk, bytes memory decodedData) = _tryReadBytes(data, 4, _wordAt(data, 68), 96);
        if (!dataOk) return (false, address(0), nestedData);

        return (true, decodedTarget, decodedData);
    }

    function _tryDecodeScheduleForGuardianScan(bytes memory data)
        internal
        pure
        returns (bool ok, address nestedTarget, bytes memory nestedData)
    {
        if (!_hasRange(data, 4, 192)) return (false, address(0), nestedData);

        (bool targetOk, address decodedTarget) = _tryReadAddress(data, 4);
        if (!targetOk) return (false, address(0), nestedData);

        (bool dataOk, bytes memory decodedData) = _tryReadBytes(data, 4, _wordAt(data, 68), 192);
        if (!dataOk) return (false, address(0), nestedData);

        return (true, decodedTarget, decodedData);
    }

    function _tryDecodeScheduleBatchForGuardianScan(bytes memory data)
        internal
        pure
        returns (bool ok, address[] memory nestedTargets, bytes[] memory nestedCalldatas)
    {
        if (!_hasRange(data, 4, 192)) return (false, nestedTargets, nestedCalldatas);

        (bool targetsOk, address[] memory decodedTargets) = _tryReadAddressArray(data, 4, _wordAt(data, 4), 192);
        if (!targetsOk) return (false, nestedTargets, nestedCalldatas);

        (bool valuesOk, uint256 valuesLength) = _tryReadUint256ArrayLength(data, 4, _wordAt(data, 36), 192);
        if (!valuesOk || valuesLength != decodedTargets.length) return (false, nestedTargets, nestedCalldatas);

        (bool calldatasOk, bytes[] memory decodedCalldatas) = _tryReadBytesArray(data, 4, _wordAt(data, 68), 192);
        if (!calldatasOk || decodedCalldatas.length != decodedTargets.length) {
            return (false, nestedTargets, nestedCalldatas);
        }

        return (true, decodedTargets, decodedCalldatas);
    }

    function _tryReadAddress(bytes memory data, uint256 offset) internal pure returns (bool ok, address account) {
        if (!_hasRange(data, offset, 32)) return (false, address(0));
        uint256 word = _wordAt(data, offset);
        if (word > type(uint160).max) return (false, address(0));
        return (true, address(uint160(word)));
    }

    function _tryReadAddressArray(bytes memory data, uint256 baseOffset, uint256 dynamicOffset, uint256 minTailOffset)
        internal
        pure
        returns (bool ok, address[] memory accounts)
    {
        (bool headOk, uint256 arrayHead) = _tryReadDynamicHead(data, baseOffset, dynamicOffset, minTailOffset);
        if (!headOk) return (false, accounts);

        uint256 count = _wordAt(data, arrayHead);
        uint256 elementsHead = arrayHead + 32;
        if (elementsHead > data.length || count > (data.length - elementsHead) / 32) return (false, accounts);

        accounts = new address[](count);
        for (uint256 i; i < count;) {
            (bool elementOk, address account) = _tryReadAddress(data, elementsHead + i * 32);
            if (!elementOk) return (false, accounts);
            accounts[i] = account;
            unchecked {
                ++i;
            }
        }
        return (true, accounts);
    }

    function _tryReadUint256ArrayLength(
        bytes memory data,
        uint256 baseOffset,
        uint256 dynamicOffset,
        uint256 minTailOffset
    ) internal pure returns (bool ok, uint256 count) {
        (bool headOk, uint256 arrayHead) = _tryReadDynamicHead(data, baseOffset, dynamicOffset, minTailOffset);
        if (!headOk) return (false, 0);

        count = _wordAt(data, arrayHead);
        uint256 elementsHead = arrayHead + 32;
        if (elementsHead > data.length || count > (data.length - elementsHead) / 32) return (false, 0);
        return (true, count);
    }

    function _tryReadBytesArray(bytes memory data, uint256 baseOffset, uint256 dynamicOffset, uint256 minTailOffset)
        internal
        pure
        returns (bool ok, bytes[] memory values)
    {
        (bool headOk, uint256 arrayHead) = _tryReadDynamicHead(data, baseOffset, dynamicOffset, minTailOffset);
        if (!headOk) return (false, values);

        uint256 count = _wordAt(data, arrayHead);
        uint256 elementsHead = arrayHead + 32;
        if (elementsHead > data.length || count > (data.length - elementsHead) / 32) return (false, values);

        values = new bytes[](count);
        uint256 minElementTailOffset = count * 32;
        for (uint256 i; i < count;) {
            (bool elementOk, bytes memory value) =
                _tryReadBytesArrayElement(data, elementsHead, minElementTailOffset, i);
            if (!elementOk) return (false, values);
            values[i] = value;
            unchecked {
                ++i;
            }
        }
        return (true, values);
    }

    function _tryReadBytesArrayElement(
        bytes memory data,
        uint256 elementsHead,
        uint256 minElementTailOffset,
        uint256 index
    ) internal pure returns (bool ok, bytes memory value) {
        uint256 elementHead = elementsHead + index * 32;
        return _tryReadBytes(data, elementsHead, _wordAt(data, elementHead), minElementTailOffset);
    }

    function _tryReadBytes(bytes memory data, uint256 baseOffset, uint256 dynamicOffset, uint256 minTailOffset)
        internal
        pure
        returns (bool ok, bytes memory value)
    {
        (bool headOk, uint256 lengthHead) = _tryReadDynamicHead(data, baseOffset, dynamicOffset, minTailOffset);
        if (!headOk) return (false, value);

        uint256 byteLength = _wordAt(data, lengthHead);
        uint256 valueOffset = lengthHead + 32;
        if (!_hasRange(data, valueOffset, byteLength)) return (false, value);

        uint256 paddedLength = byteLength;
        uint256 remainder = byteLength % 32;
        if (remainder != 0) {
            unchecked {
                paddedLength += 32 - remainder;
            }
        }
        if (!_hasRange(data, valueOffset, paddedLength)) return (false, value);

        return (true, _copyBytes(data, valueOffset, byteLength));
    }

    function _tryReadDynamicHead(bytes memory data, uint256 baseOffset, uint256 dynamicOffset, uint256 minTailOffset)
        internal
        pure
        returns (bool ok, uint256 headOffset)
    {
        if (dynamicOffset < minTailOffset || dynamicOffset % 32 != 0) return (false, 0);
        if (baseOffset > data.length || dynamicOffset > data.length - baseOffset) return (false, 0);

        headOffset = baseOffset + dynamicOffset;
        if (!_hasRange(data, headOffset, 32)) return (false, 0);
        return (true, headOffset);
    }

    function _hasRange(bytes memory data, uint256 offset, uint256 length) internal pure returns (bool) {
        return offset <= data.length && length <= data.length - offset;
    }

    function _wordAt(bytes memory data, uint256 offset) internal pure returns (uint256 word) {
        assembly { word := mload(add(add(data, 0x20), offset)) }
    }

    function _copyBytes(bytes memory data, uint256 offset, uint256 length) internal pure returns (bytes memory value) {
        value = new bytes(length);
        for (uint256 i; i < length;) {
            assembly {
                mstore(add(add(value, 0x20), i), mload(add(add(data, 0x20), add(offset, i))))
            }
            unchecked {
                i += 32;
            }
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
