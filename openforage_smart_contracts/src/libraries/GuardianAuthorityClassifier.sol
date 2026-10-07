pragma solidity ^0.8.20;

import "../ForageGovernorTimelockGuard.sol";

interface IGuardianModuleAllowlist {
    function allowlist() external view returns (address);
}

library GuardianAuthorityClassifier {
    error CustodianRegistryUnavailable(address registry);
    error GovernorTimelockViewUnavailable(address governor);
    error InvalidGuardianRosterMutation(uint8 operation);
    error GuardianRosterTooLarge(uint256 entries, uint256 maximum);
    error GuardianRoleCapacityExceeded(uint256 pauseGuardians, uint256 cancelGuardians, uint256 maximum);
    error GuardianProposalGuardianCountInvalid(uint256 observed);
    error GuardianProposalGuardianNotVerified(address guardian);
    error ZeroAddress();
    error InvalidParameter();
    error ArrayLengthMismatch();
    error DuplicateGuardian();
    error InvalidPermissionBitmask();
    error PauseAndCancelForbidden();

    event GuardianPermissionsUpdated(address indexed guardian, uint256 oldPermissions, uint256 newPermissions);

    struct CustodianRegistryStorage {
        address canonical;
    }

    struct InitializationConfig {
        address governor;
        address timelock;
        address custodianRegistry;
        address candidateAllowlist;
        address[] guardians;
        uint256[] permissions;
    }

    struct InitialGuardianRoleCounts {
        uint256 pauseGuardians;
        uint256 cancelGuardians;
        uint256 proposalGuardians;
        address proposalGuardian;
    }

    bytes4 private constant _UPGRADE_TO_AND_CALL = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    bytes4 private constant _OWNER = bytes4(keccak256("owner()"));
    bytes4 private constant _TIMELOCK_VIEW = bytes4(keccak256("timelock()"));
    bytes4 private constant _SET_GUARDIAN_MODULE = bytes4(keccak256("setGuardianModule(address)"));
    bytes4 private constant _UPDATE_TIMELOCK = bytes4(keccak256("updateTimelock(address)"));
    bytes4 private constant _SET_ALLOWLIST = bytes4(keccak256("setAllowlist(address)"));
    bytes4 private constant _PROPOSE_FORAGE_GOVERNOR = bytes4(keccak256("proposeForageGovernor(address)"));
    bytes4 private constant _FINALIZE_FORAGE_GOVERNOR = bytes4(keccak256("finalizeForageGovernor()"));
    bytes4 private constant _SET_GUARDIAN_PERMISSIONS = bytes4(keccak256("setGuardianPermissions(address,uint256)"));
    bytes4 private constant _REMOVE_GUARDIAN = bytes4(keccak256("removeGuardian(address)"));
    bytes4 private constant _SET_PRECOMMITTED_SUCCESSOR =
        bytes4(keccak256("setPreCommittedSuccessor(bytes32,address,address)"));
    bytes4 private constant _PROPOSE_ROUTINE_ROTATION =
        bytes4(keccak256("proposeRoutineRotation(bytes32,address,address)"));
    bytes4 private constant _UPDATE_GOVERNOR = bytes4(keccak256("updateGovernor(address)"));
    bytes4 private constant _SET_PAUSABLE_TARGET = bytes4(keccak256("setPausableTarget(address,bool)"));
    bytes4 private constant _EXECUTE_ACCELERATED_ROTATION = bytes4(keccak256("executeAcceleratedRotation(bytes32)"));
    bytes4 private constant _FINALIZE_ROUTINE_ROTATION = bytes4(keccak256("finalizeRoutineRotation(bytes32)"));
    bytes4 private constant _ACCEPT_TIMELOCK = bytes4(keccak256("acceptTimelock()"));
    bytes4 private constant _PROPOSE_TIMELOCK = bytes4(keccak256("proposeTimelock(address)"));
    bytes4 private constant _GRANT_ROLE = bytes4(keccak256("grantRole(bytes32,address)"));
    bytes4 private constant _REVOKE_ROLE = bytes4(keccak256("revokeRole(bytes32,address)"));
    bytes4 private constant _RENOUNCE_ROLE = bytes4(keccak256("renounceRole(bytes32,address)"));
    bytes4 private constant _UPDATE_DELAY = bytes4(keccak256("updateDelay(uint256)"));
    bytes4 private constant _IS_ALLOWED = bytes4(keccak256("isAllowed(address)"));
    bytes4 private constant _EMERGENCY_PAUSE = bytes4(keccak256("pause()"));
    bytes4 private constant _EMERGENCY_SHRINK_WEEKLY_REDEMPTION =
        bytes4(keccak256("shrinkWeeklyRedemptionCapBps(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_WEEKLY_MINT = bytes4(keccak256("shrinkWeeklyMintCapBps(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_DAILY_MINT = bytes4(keccak256("shrinkDailyMintCapBps(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_PER_BLOCK_MINT =
        bytes4(keccak256("shrinkPerBlockMintCap(uint256,uint256)"));
    bytes4 private constant _EMERGENCY_TIGHTEN_MAX_DEPLOYMENT_RATIO =
        bytes4(keccak256("tightenMaxDeploymentRatioBps(uint256)"));
    bytes4 private constant _EMERGENCY_TIGHTEN_DEPLOYMENT_BUFFER =
        bytes4(keccak256("tightenDeploymentBufferBps(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_WITHDRAWAL = bytes4(keccak256("shrinkWeeklyWithdrawalCapBps(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_PER_BLOCK_DEPLOY = bytes4(keccak256("shrinkPerBlockDeployCap(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_PER_DAY_DEPLOY = bytes4(keccak256("shrinkPerDayDeployCap(uint256)"));
    bytes4 private constant _EMERGENCY_TIGHTEN_RETURN_CAPS =
        bytes4(keccak256("tightenReturnCapitalCaps(uint16,uint16)"));
    bytes4 private constant _EMERGENCY_FREEZE_ATTESTATIONS = bytes4(keccak256("freezeAttestations()"));
    bytes4 private constant _EMERGENCY_REVOKE = bytes4(keccak256("revoke(address)"));
    bytes4 private constant _EMERGENCY_SHRINK_APPROVALS = bytes4(keccak256("shrinkApprovalsPerDayCap(uint32)"));
    bytes4 private constant _EMERGENCY_SHRINK_LOSS_RATE = bytes4(keccak256("shrinkLossRateCapBps(uint256)"));
    bytes4 private constant _EMERGENCY_SHRINK_DISTRIBUTOR_DAILY =
        bytes4(keccak256("shrinkDistributorDailyCap(uint256)"));
    uint256 private constant _GUARDIAN_SETUP_VIEW_GAS = 30_000;
    uint256 private constant _GUARDIAN_ROTATION = 2;
    uint256 private constant _GOVERNOR_TARGET = 4;
    uint256 private constant _TIMELOCK_TARGET = 8;
    uint256 private constant _MODULE_TARGET = 16;
    uint256 private constant _REGISTRY_TARGET = 32;
    bytes32 private constant _CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 private constant _DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 private constant _PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 private constant _EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 private constant _PAUSE_PERMISSION = 1;
    uint256 private constant _CANCEL_PERMISSION = 2;
    uint256 private constant _EMERGENCY_PERMISSION = 4;
    uint256 private constant _PROPOSAL_PERMISSION = 8;
    uint256 private constant _MAX_VALID_PERMISSIONS =
        _PAUSE_PERMISSION | _CANCEL_PERMISSION | _EMERGENCY_PERMISSION | _PROPOSAL_PERMISSION;
    uint256 private constant _MAX_GUARDIAN_ENTRIES = 14;
    uint256 private constant _MAX_ROLE_GUARDIANS = 7;

    struct Context {
        address guardian;
        address effectiveCaller;
        address governor;
        address guardianModule;
        address timelock;
        bytes32 guardianSeatSlot;
        uint256 flags;
    }

    struct GuardianSeatTransitionState {
        uint256 currentPermissions;
        uint256 successorPermissions;
        uint256 currentEntries;
        uint256 successorEntries;
    }

    function isAuthorityMutation(
        bytes memory data,
        Context memory context,
        mapping(address => uint256) storage guardianPermissions,
        mapping(address => uint256) storage guardianRosterEntryCount,
        mapping(bytes32 => mapping(address => address)) storage preCommittedSuccessors,
        address allowlist
    ) public view returns (bool) {
        if (data.length < 4) return false;
        bytes4 selector = _selector(data);
        if ((context.flags & _GOVERNOR_TARGET) != 0) return _isGovernorMutation(selector, data);
        if ((context.flags & _TIMELOCK_TARGET) != 0) return _isTimelockMutation(selector, data, context);
        if ((context.flags & _MODULE_TARGET) != 0) {
            return _isModuleMutation(
                selector,
                data,
                context,
                guardianPermissions,
                guardianRosterEntryCount,
                preCommittedSuccessors,
                allowlist
            );
        }
        if ((context.flags & _REGISTRY_TARGET) == 0) return false;
        return _isDownstreamMutation(selector, data);
    }

    function guardianSeatTransition(
        address current,
        address successor,
        mapping(address => uint256) storage guardianPermissions,
        mapping(address => uint256) storage guardianRosterEntryCount
    ) public view returns (GuardianSeatTransitionState memory state, bool valid) {
        state = _guardianSeatTransitionState(current, successor, guardianPermissions, guardianRosterEntryCount);
        valid = _guardianSeatTransitionIsValid(current, successor, state);
    }

    function mutateGuardianRoster(
        address[] storage guardianList,
        mapping(address => uint256) storage guardianRosterEntryCount,
        mapping(address => uint256) storage guardianPermissions,
        address guardian,
        address successor,
        uint8 operation
    ) public returns (bool changed) {
        if (operation == 4) {
            guardianList.push(guardian);
            guardianRosterEntryCount[guardian] += 1;
            return true;
        }
        if (operation > 3) revert InvalidGuardianRosterMutation(operation);
        if (operation != 2) {
            _requireGuardianRosterBounds(guardianList, guardianPermissions, guardian, operation);
        }
        if (operation == 3) return true;
        if (operation == 0) {
            guardianList.push(guardian);
            guardianRosterEntryCount[guardian] += 1;
            return true;
        }
        uint256 length = guardianList.length;
        for (uint256 i; i < length;) {
            if (guardianList[i] == guardian) {
                if (operation == 1) {
                    guardianList[i] = guardianList[length - 1];
                    guardianList.pop();
                    guardianRosterEntryCount[guardian] -= 1;
                } else {
                    guardianList[i] = successor;
                    guardianRosterEntryCount[guardian] -= 1;
                    guardianRosterEntryCount[successor] += 1;
                    _requireGuardianRosterBounds(guardianList, guardianPermissions, address(0), 3);
                }
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function initializeGuardianRoster(
        address[] storage guardianList,
        mapping(address => uint256) storage guardianRosterEntryCount,
        mapping(address => uint256) storage guardianPermissions,
        InitializationConfig memory config
    ) public {
        _validateInitialGuardianRoster(config);
        _seedInitialGuardianRoster(guardianList, guardianRosterEntryCount, guardianPermissions, config);
    }

    function validateProposalGuardianAllowlist(
        address[] storage guardianList,
        mapping(address => uint256) storage guardianPermissions,
        address candidateAllowlist
    ) public view {
        uint256 proposalGuardians;
        address proposalGuardian;
        for (uint256 i; i < guardianList.length;) {
            address guardian = guardianList[i];
            if ((guardianPermissions[guardian] & _PROPOSAL_PERMISSION) != 0) {
                proposalGuardians += 1;
                proposalGuardian = guardian;
            }
            unchecked {
                ++i;
            }
        }
        _requireExactlyOneProposalGuardian(proposalGuardians);
        _requireVerifiedProposalGuardian(candidateAllowlist, proposalGuardian);
    }

    function custodianRegistryOwner(CustodianRegistryStorage storage registrySlot)
        public
        view
        returns (address owner)
    {
        address registry = registrySlot.canonical;
        if (registry == address(0) || registry.code.length == 0) revert CustodianRegistryUnavailable(registry);
        (bool ok, bytes memory result) = registry.staticcall(abi.encodeWithSelector(_OWNER));
        if (!ok || result.length != 32) revert CustodianRegistryUnavailable(registry);
        uint256 ownerWord = _word(result, 0);
        if (ownerWord == 0 || ownerWord > type(uint160).max) revert CustodianRegistryUnavailable(registry);
        owner = address(uint160(ownerWord));
    }

    function governorTimelock(address governor) public view returns (address timelock) {
        bytes memory request = abi.encodeWithSelector(_TIMELOCK_VIEW);
        bool ok;
        uint256 governorWord;
        assembly ("memory-safe") {
            ok := staticcall(_GUARDIAN_SETUP_VIEW_GAS, governor, add(request, 0x20), mload(request), 0, 0x20)
            let returnSize := returndatasize()
            if and(ok, eq(returnSize, 0x20)) { governorWord := mload(0) }
            if iszero(and(ok, eq(returnSize, 0x20))) { ok := 0 }
        }
        if (!ok || governorWord > type(uint160).max) revert GovernorTimelockViewUnavailable(governor);
        timelock = address(uint160(governorWord));
    }

    function validateEmergencyCalldata(bytes calldata data) public pure returns (bool valid, bytes4 selector) {
        if (data.length < 4) return (false, selector);
        selector = bytes4(data[:4]);
        if (selector == _EMERGENCY_PAUSE || selector == _EMERGENCY_FREEZE_ATTESTATIONS) {
            return (data.length == 4, selector);
        }
        if (
            selector == _EMERGENCY_SHRINK_WEEKLY_REDEMPTION || selector == _EMERGENCY_SHRINK_WEEKLY_MINT
                || selector == _EMERGENCY_SHRINK_DAILY_MINT || selector == _EMERGENCY_TIGHTEN_MAX_DEPLOYMENT_RATIO
                || selector == _EMERGENCY_TIGHTEN_DEPLOYMENT_BUFFER || selector == _EMERGENCY_SHRINK_WITHDRAWAL
                || selector == _EMERGENCY_SHRINK_PER_BLOCK_DEPLOY || selector == _EMERGENCY_SHRINK_PER_DAY_DEPLOY
                || selector == _EMERGENCY_SHRINK_LOSS_RATE || selector == _EMERGENCY_REVOKE
                || selector == _EMERGENCY_SHRINK_APPROVALS || selector == _EMERGENCY_SHRINK_DISTRIBUTOR_DAILY
        ) {
            return (data.length == 36, selector);
        }
        if (selector == _EMERGENCY_SHRINK_PER_BLOCK_MINT || selector == _EMERGENCY_TIGHTEN_RETURN_CAPS) {
            return (data.length == 68, selector);
        }
        return (false, selector);
    }

    function tryDecodeRelay(bytes memory data)
        public
        pure
        returns (bool, GovernancePayloadBudget.OperationPayload memory)
    {
        return GovernancePayloadBudget.tryDecodeRelay(data);
    }

    function tryDecodeSchedule(bytes memory data)
        public
        pure
        returns (bool, GovernancePayloadBudget.OperationPayload memory)
    {
        return GovernancePayloadBudget.tryDecodeSchedule(data);
    }

    function tryReadScheduleBatchHeader(bytes memory data)
        public
        pure
        returns (bool, GovernancePayloadBudget.ScheduleBatchHeader memory)
    {
        return GovernancePayloadBudget.tryReadScheduleBatchHeader(data);
    }

    function tryReadScheduleBatchTargets(bytes memory data, GovernancePayloadBudget.ScheduleBatchHeader memory header)
        public
        pure
        returns (bool, address[] memory)
    {
        return GovernancePayloadBudget.tryReadScheduleBatchTargets(data, header);
    }

    function tryDecodeScheduleBatch(
        bytes memory data,
        GovernancePayloadBudget.ScheduleBatchHeader memory header,
        address[] memory targets
    ) public pure returns (bool, GovernancePayloadBudget.ScheduleBatchPayload memory) {
        return GovernancePayloadBudget.tryDecodeScheduleBatch(data, header, targets);
    }

    function _isGovernorMutation(bytes4 selector, bytes memory data) private pure returns (bool) {
        if (selector == _UPGRADE_TO_AND_CALL) return _isCanonicalUpgradeToAndCall(data);
        return selector == _SET_GUARDIAN_MODULE || selector == _UPDATE_TIMELOCK || selector == _SET_ALLOWLIST;
    }

    function _isTimelockMutation(bytes4 selector, bytes memory data, Context memory context)
        private
        pure
        returns (bool)
    {
        if (selector == _UPGRADE_TO_AND_CALL) return _isCanonicalUpgradeToAndCall(data);
        if (selector == _UPDATE_DELAY) return true;
        if (selector != _GRANT_ROLE && selector != _REVOKE_ROLE && selector != _RENOUNCE_ROLE) return false;
        if (data.length < 68) return false;
        bytes32 role = bytes32(_word(data, 4));
        if (role != _CANCELLER_ROLE && role != _DEFAULT_ADMIN_ROLE && role != _PROPOSER_ROLE && role != _EXECUTOR_ROLE)
        {
            return false;
        }
        return selector != _RENOUNCE_ROLE || address(uint160(_word(data, 36))) == context.effectiveCaller;
    }

    function _isDownstreamMutation(bytes4 selector, bytes memory data) private pure returns (bool) {
        if (selector == _PROPOSE_FORAGE_GOVERNOR) {
            if (data.length < 36) return false;
            uint256 proposedGovernor = _word(data, 4);
            if (proposedGovernor == 0 || proposedGovernor > type(uint160).max) return false;
        } else if (selector == _UPGRADE_TO_AND_CALL) {
            return _isCanonicalUpgradeToAndCall(data);
        } else if (selector != _FINALIZE_FORAGE_GOVERNOR && selector != _SET_ALLOWLIST) {
            return false;
        }
        return true;
    }

    function _isModuleMutation(
        bytes4 selector,
        bytes memory data,
        Context memory context,
        mapping(address => uint256) storage guardianPermissions,
        mapping(address => uint256) storage guardianRosterEntryCount,
        mapping(bytes32 => mapping(address => address)) storage preCommittedSuccessors,
        address allowlist
    ) private view returns (bool) {
        if (selector == _SET_GUARDIAN_PERMISSIONS && data.length >= 68) {
            return _firstAddress(data) == context.guardian;
        }
        if (selector == _REMOVE_GUARDIAN && data.length >= 36) return _firstAddress(data) == context.guardian;
        if (selector == _EXECUTE_ACCELERATED_ROTATION || selector == _FINALIZE_ROUTINE_ROTATION) {
            return (context.flags & _GUARDIAN_ROTATION) != 0;
        }
        if (selector == _SET_PRECOMMITTED_SUCCESSOR || selector == _PROPOSE_ROUTINE_ROTATION) {
            return _isSelfTargetingGuardianSeatSetup(
                selector,
                data,
                context,
                guardianPermissions,
                guardianRosterEntryCount,
                preCommittedSuccessors,
                allowlist
            );
        }
        if (selector == _UPGRADE_TO_AND_CALL) return _isCanonicalUpgradeToAndCall(data);
        if (selector == _PROPOSE_TIMELOCK) return _isCanonicalAddressCall(data);
        return selector == _UPDATE_GOVERNOR || selector == _SET_ALLOWLIST || selector == _SET_PAUSABLE_TARGET
            || selector == _ACCEPT_TIMELOCK;
    }

    function _isSelfTargetingGuardianSeatSetup(
        bytes4 selector,
        bytes memory data,
        Context memory context,
        mapping(address => uint256) storage guardianPermissions,
        mapping(address => uint256) storage guardianRosterEntryCount,
        mapping(bytes32 => mapping(address => address)) storage preCommittedSuccessors,
        address allowlist
    ) private view returns (bool) {
        if (data.length < 100) return false;
        uint256 slotWord = _word(data, 4);
        uint256 currentWord = _word(data, 36);
        uint256 successorWord = _word(data, 68);
        if (
            slotWord != uint256(context.guardianSeatSlot) || currentWord > type(uint160).max
                || successorWord > type(uint160).max
        ) return false;
        address current = address(uint160(currentWord));
        address successor = address(uint160(successorWord));
        if (current != context.guardian) return false;
        if (selector == _SET_PRECOMMITTED_SUCCESSOR) {
            if (context.effectiveCaller != context.timelock) return false;
        } else if (
            context.effectiveCaller != context.governor
                || preCommittedSuccessors[context.guardianSeatSlot][current] != successor
        ) {
            return false;
        }
        if (current == address(0) || successor == address(0) || current == successor) return false;
        if (guardianPermissions[current] == 0 || guardianPermissions[successor] != 0) return false;
        if (!_isVerifiedGuardianSuccessor(allowlist, successor)) return false;
        GuardianSeatTransitionState memory state =
            _guardianSeatTransitionState(current, successor, guardianPermissions, guardianRosterEntryCount);
        return _guardianSeatTransitionIsValid(current, successor, state);
    }

    function _guardianSeatTransitionState(
        address current,
        address successor,
        mapping(address => uint256) storage guardianPermissions,
        mapping(address => uint256) storage guardianRosterEntryCount
    ) private view returns (GuardianSeatTransitionState memory state) {
        state.currentPermissions = guardianPermissions[current];
        state.successorPermissions = guardianPermissions[successor];
        state.currentEntries = guardianRosterEntryCount[current];
        state.successorEntries = guardianRosterEntryCount[successor];
    }

    function _guardianSeatTransitionIsValid(
        address current,
        address successor,
        GuardianSeatTransitionState memory state
    ) private pure returns (bool) {
        return current != address(0) && successor != address(0) && current != successor && state.currentPermissions != 0
            && state.currentEntries == 1 && state.successorPermissions == 0 && state.successorEntries == 0;
    }

    function _isVerifiedGuardianSuccessor(address allowlist, address successor) private view returns (bool) {
        if (allowlist == address(0) || allowlist.code.length == 0) return false;
        bytes4 allowedSelector = _IS_ALLOWED;
        bool ok;
        uint256 result;
        assembly ("memory-safe") {
            mstore(0, allowedSelector)
            mstore(4, successor)
            ok := staticcall(_GUARDIAN_SETUP_VIEW_GAS, allowlist, 0, 0x24, 0, 0x20)
            let returnSize := returndatasize()
            if and(ok, eq(returnSize, 0x20)) { result := mload(0) }
            if iszero(and(ok, eq(returnSize, 0x20))) { ok := 0 }
        }
        return ok && result == 1;
    }

    function _requireVerifiedProposalGuardian(address allowlist, address guardian) private view {
        if (!_isVerifiedGuardianSuccessor(allowlist, guardian)) revert GuardianProposalGuardianNotVerified(guardian);
    }

    function _validateInitialGuardianRoster(InitializationConfig memory config) private view {
        if (config.governor == address(0) || config.timelock == address(0) || config.custodianRegistry == address(0)) {
            revert ZeroAddress();
        }
        uint256 entries = config.permissions.length;
        if (entries != config.guardians.length) revert ArrayLengthMismatch();
        if (entries > _MAX_GUARDIAN_ENTRIES) revert GuardianRosterTooLarge(entries, _MAX_GUARDIAN_ENTRIES);
        InitialGuardianRoleCounts memory counts = _countInitialGuardianRoles(config);
        _requireExactlyOneProposalGuardian(counts.proposalGuardians);
        _requireVerifiedProposalGuardian(config.candidateAllowlist, counts.proposalGuardian);
        _revertIfRoleCapacityExceeded(counts.pauseGuardians, counts.cancelGuardians);
    }

    function _countInitialGuardianRoles(InitializationConfig memory config)
        private
        pure
        returns (InitialGuardianRoleCounts memory counts)
    {
        for (uint256 i; i < config.permissions.length;) {
            uint256 permissions = config.permissions[i];
            _validateInitialGuardian(config.guardians, i, permissions);
            counts.pauseGuardians += _permissionCount(permissions, _PAUSE_PERMISSION);
            counts.cancelGuardians += _permissionCount(permissions, _CANCEL_PERMISSION);
            if ((permissions & _PROPOSAL_PERMISSION) != 0) {
                counts.proposalGuardians += 1;
                counts.proposalGuardian = config.guardians[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _validateInitialGuardian(address[] memory guardians, uint256 index, uint256 permissions) private pure {
        if (guardians[index] == address(0)) revert ZeroAddress();
        if (permissions == 0) revert InvalidParameter();
        if (permissions > _MAX_VALID_PERMISSIONS) revert InvalidPermissionBitmask();
        if ((permissions & _PAUSE_PERMISSION) != 0 && (permissions & _CANCEL_PERMISSION) != 0) {
            revert PauseAndCancelForbidden();
        }
        _requireUniqueInitialGuardian(guardians, index);
    }

    function _requireUniqueInitialGuardian(address[] memory guardians, uint256 index) private pure {
        for (uint256 previous; previous < index;) {
            if (guardians[previous] == guardians[index]) revert DuplicateGuardian();
            unchecked {
                ++previous;
            }
        }
    }

    function _seedInitialGuardianRoster(
        address[] storage guardianList,
        mapping(address => uint256) storage guardianRosterEntryCount,
        mapping(address => uint256) storage guardianPermissions,
        InitializationConfig memory config
    ) private {
        for (uint256 i; i < config.guardians.length;) {
            address guardian = config.guardians[i];
            uint256 permissions = config.permissions[i];
            guardianPermissions[guardian] = permissions;
            guardianList.push(guardian);
            guardianRosterEntryCount[guardian] += 1;
            emit GuardianPermissionsUpdated(guardian, 0, permissions);
            unchecked {
                ++i;
            }
        }
    }

    function _requireGuardianRosterBounds(
        address[] storage guardianList,
        mapping(address => uint256) storage guardianPermissions,
        address guardian,
        uint8 operation
    ) private view {
        uint256 entries = guardianList.length;
        uint256 listLength = entries;
        if (operation == 0 && listLength >= _MAX_GUARDIAN_ENTRIES) {
            revert GuardianRosterTooLarge(listLength + 1, _MAX_GUARDIAN_ENTRIES);
        }
        uint256 pauseGuardians;
        uint256 cancelGuardians;
        uint256 proposalGuardians;
        address proposalGuardian;
        bool found;
        for (uint256 i; i < listLength;) {
            address member = guardianList[i];
            if (operation == 1 && member == guardian) {
                found = true;
            } else {
                uint256 permissions = guardianPermissions[member];
                pauseGuardians += _permissionCount(permissions, _PAUSE_PERMISSION);
                cancelGuardians += _permissionCount(permissions, _CANCEL_PERMISSION);
                if ((permissions & _PROPOSAL_PERMISSION) != 0) {
                    proposalGuardians += 1;
                    proposalGuardian = member;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (operation == 1 && found) entries -= 1;
        if (operation == 0) {
            uint256 newPermissions = guardianPermissions[guardian];
            pauseGuardians += _permissionCount(newPermissions, _PAUSE_PERMISSION);
            cancelGuardians += _permissionCount(newPermissions, _CANCEL_PERMISSION);
            if ((newPermissions & _PROPOSAL_PERMISSION) != 0) {
                proposalGuardians += 1;
                proposalGuardian = guardian;
            }
            entries += 1;
        }
        if (entries > _MAX_GUARDIAN_ENTRIES) revert GuardianRosterTooLarge(entries, _MAX_GUARDIAN_ENTRIES);
        _requireExactlyOneProposalGuardian(proposalGuardians);
        if (!_isVerifiedGuardianSuccessor(IGuardianModuleAllowlist(address(this)).allowlist(), proposalGuardian)) {
            revert GuardianProposalGuardianNotVerified(proposalGuardian);
        }
        _revertIfRoleCapacityExceeded(pauseGuardians, cancelGuardians);
    }

    function _requireExactlyOneProposalGuardian(uint256 observed) private pure {
        if (observed != 1) revert GuardianProposalGuardianCountInvalid(observed);
    }

    function _permissionCount(uint256 permissions, uint256 permission) private pure returns (uint256) {
        return (permissions & permission) == 0 ? 0 : 1;
    }

    function _isCanonicalAddressCall(bytes memory data) private pure returns (bool) {
        if (data.length < 36) return false;
        uint256 argument = _word(data, 4);
        return argument != 0 && argument <= type(uint160).max;
    }

    function _isCanonicalUpgradeToAndCall(bytes memory data) private pure returns (bool) {
        if (data.length < 100) return false;
        uint256 implementation = _word(data, 4);
        uint256 offset = _word(data, 36);
        if (implementation == 0 || implementation > type(uint160).max) return false;
        return _hasCanonicalBytesTail(data, offset);
    }

    function _hasCanonicalBytesTail(bytes memory data, uint256 offset) private pure returns (bool) {
        if (offset > data.length - 36) return false;
        uint256 lengthIndex = 4 + offset;
        uint256 length = _word(data, lengthIndex);
        return length <= data.length - lengthIndex - 32;
    }

    function _revertIfRoleCapacityExceeded(uint256 pauseGuardians, uint256 cancelGuardians) private pure {
        if (pauseGuardians > _MAX_ROLE_GUARDIANS || cancelGuardians > _MAX_ROLE_GUARDIANS) {
            revert GuardianRoleCapacityExceeded(pauseGuardians, cancelGuardians, _MAX_ROLE_GUARDIANS);
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _firstAddress(bytes memory data) private pure returns (address account) {
        assembly {
            account := and(mload(add(data, 0x24)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _word(bytes memory data, uint256 offset) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), offset))
        }
    }
}
