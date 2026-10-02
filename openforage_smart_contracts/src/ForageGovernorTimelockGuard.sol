// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

library GovernancePayloadBudget {
    uint256 internal constant MAX_TOP_LEVEL_ACTIONS = 100;
    uint256 internal constant MAX_NESTED_ACTION_VISITS = 100;
    uint256 internal constant MAX_TOP_LEVEL_ACTION_BYTES = 65_536;
    uint256 internal constant MAX_TIMELOCK_DEPTH = 16;

    struct Budget {
        uint256 nestedVisits;
        uint256 actionBytes;
    }

    struct OperationPayload {
        address target;
        bytes data;
    }

    struct GuardianSeatSetupCandidate {
        address current;
        address successor;
        bool routine;
        bool found;
    }

    bytes4 private constant _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR =
        bytes4(keccak256("setPreCommittedSuccessor(bytes32,address,address)"));
    bytes4 private constant _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR =
        bytes4(keccak256("proposeRoutineRotation(bytes32,address,address)"));

    struct ScheduleBatchHeader {
        uint256 targetsOffset;
        uint256 targetsLength;
        uint256 targetsElementsHead;
        uint256 targetsEnd;
    }

    struct ScheduleBatchPayload {
        address[] targets;
        bytes[] calldatas;
    }

    function tryDecodeRelay(bytes memory data) internal pure returns (bool, OperationPayload memory) {
        return _tryDecodeOperation(data, 96, true, 68);
    }

    function tryDecodeSchedule(bytes memory data) internal pure returns (bool, OperationPayload memory) {
        return _tryDecodeOperation(data, 192, false, 68);
    }

    function isValidAddressAndBytes(bytes memory data) internal pure returns (bool) {
        (bool valid,) = _tryDecodeOperation(data, 64, false, 36);
        return valid;
    }

    function guardianSeatSetupCandidate(
        bytes memory data,
        address target,
        address guardianModule,
        bytes32 guardianSeatSlot
    ) internal pure returns (GuardianSeatSetupCandidate memory candidate) {
        if (target != guardianModule || data.length < 100) return candidate;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
        bool routine = selector == _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR;
        if (!routine && selector != _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR) return candidate;
        (bool slotOk, uint256 slot) = _tryReadWord(data, 4);
        (bool currentOk, uint256 current) = _tryReadWord(data, 36);
        (bool successorOk, uint256 successor) = _tryReadWord(data, 68);
        if (
            !slotOk || !currentOk || !successorOk || slot != uint256(guardianSeatSlot) || current == 0
                || current > type(uint160).max || successor == 0 || successor > type(uint160).max || current == successor
        ) return candidate;
        candidate.current = address(uint160(current));
        candidate.successor = address(uint160(successor));
        candidate.routine = routine;
        candidate.found = true;
    }

    function _tryDecodeOperation(bytes memory data, uint256 headLength, bool readValue, uint256 offsetPosition)
        private
        pure
        returns (bool, OperationPayload memory decoded)
    {
        if (data.length < 4 || data.length - 4 < headLength) return (false, decoded);
        (bool targetOk, address target) = _tryReadAddress(data, 4);
        if (!targetOk) return (false, decoded);
        if (readValue && !_hasRange(data, 36, 32)) return (false, decoded);
        (bool offsetOk, uint256 dataOffset) = _tryReadWord(data, offsetPosition);
        if (!offsetOk) return (false, decoded);
        (bool dataOk, bytes memory nestedData) = _tryReadDynamicBytes(data, 4, data.length - 4, dataOffset, headLength);
        if (!dataOk) return (false, decoded);
        decoded.target = target;
        decoded.data = nestedData;
        return (true, decoded);
    }

    function tryReadScheduleBatchHeader(bytes memory data)
        internal
        pure
        returns (bool, ScheduleBatchHeader memory header)
    {
        if (data.length < 196) return (false, header);
        (bool offsetOk, uint256 targetsOffset) = _tryReadWord(data, 4);
        if (!offsetOk) return (false, header);
        (bool arrayOk, uint256 targetsLength, uint256 elementsHead, uint256 targetsEnd) =
            _tryReadArray(data, data.length - 4, targetsOffset, 192);
        if (!arrayOk) return (false, header);
        header.targetsOffset = targetsOffset;
        header.targetsLength = targetsLength;
        header.targetsElementsHead = elementsHead;
        header.targetsEnd = targetsEnd;
        return (true, header);
    }

    function tryReadScheduleBatchTargets(bytes memory data, ScheduleBatchHeader memory header)
        internal
        pure
        returns (bool, address[] memory targets)
    {
        uint256 payloadLength = data.length - 4;
        if (
            header.targetsEnd > payloadLength
                || header.targetsLength > (payloadLength - header.targetsElementsHead) / 32
        ) {
            return (false, targets);
        }
        targets = new address[](header.targetsLength);
        for (uint256 i; i < header.targetsLength;) {
            (bool targetOk, address target) = _tryReadAddress(data, 4 + header.targetsElementsHead + i * 32);
            if (!targetOk) return (false, targets);
            targets[i] = target;
            unchecked {
                ++i;
            }
        }
        return (true, targets);
    }

    function tryDecodeScheduleBatch(bytes memory data, ScheduleBatchHeader memory header, address[] memory targets)
        internal
        pure
        returns (bool, ScheduleBatchPayload memory batch)
    {
        if (data.length < 196 || targets.length != header.targetsLength) return (false, batch);
        (bool arraysOk, bytes[] memory calldatas) = _tryReadScheduleBatchArrays(data, header);
        if (!arraysOk) return (false, batch);
        batch.targets = targets;
        batch.calldatas = calldatas;
        return (true, batch);
    }

    function _tryReadScheduleBatchArrays(bytes memory data, ScheduleBatchHeader memory header)
        private
        pure
        returns (bool, bytes[] memory calldatas)
    {
        uint256 payloadLength = data.length - 4;
        (bool valuesOk, uint256 valuesEnd) = _tryReadScheduleBatchValues(data, payloadLength, header);
        if (!valuesOk) return (false, calldatas);
        (bool offsetOk, uint256 calldatasOffset) = _tryReadWord(data, 68);
        if (!offsetOk) return (false, calldatas);
        return _tryReadScheduleBatchCalldatas(data, payloadLength, calldatasOffset, valuesEnd, header.targetsLength);
    }

    function _tryReadScheduleBatchValues(bytes memory data, uint256 payloadLength, ScheduleBatchHeader memory header)
        private
        pure
        returns (bool, uint256 valuesEnd)
    {
        (bool offsetOk, uint256 valuesOffset) = _tryReadWord(data, 36);
        if (!offsetOk) return (false, 0);
        (bool arrayOk, uint256 valuesLength,, uint256 end) = _tryReadArray(data, payloadLength, valuesOffset, 192);
        if (!arrayOk || valuesLength != header.targetsLength || valuesOffset < header.targetsEnd) return (false, 0);
        return (true, end);
    }

    function _tryReadScheduleBatchCalldatas(
        bytes memory data,
        uint256 payloadLength,
        uint256 calldatasOffset,
        uint256 valuesEnd,
        uint256 expectedLength
    ) private pure returns (bool, bytes[] memory calldatas) {
        (bool arrayOk, uint256 count, uint256 elementsHead,) = _tryReadArray(data, payloadLength, calldatasOffset, 192);
        if (
            !arrayOk || count != expectedLength || calldatasOffset < valuesEnd
                || !_tryValidateBytesArray(data, payloadLength, elementsHead, count)
        ) {
            return (false, calldatas);
        }
        calldatas = new bytes[](count);
        for (uint256 i; i < count;) {
            (bool itemOk, bytes memory item) = _tryReadBytesArrayElement(data, payloadLength, elementsHead, i);
            if (!itemOk) return (false, calldatas);
            calldatas[i] = item;
            unchecked {
                ++i;
            }
        }
        return (true, calldatas);
    }

    function _tryReadArray(bytes memory data, uint256 payloadLength, uint256 offset, uint256 minimumTail)
        private
        pure
        returns (bool, uint256 count, uint256 elementsHead, uint256 end)
    {
        if (!_validDynamicOffset(offset, payloadLength, minimumTail)) return (false, 0, 0, 0);
        elementsHead = offset + 32;
        (bool countOk, uint256 decodedCount) = _tryReadWord(data, 4 + offset);
        if (!countOk || elementsHead > payloadLength || decodedCount > (payloadLength - elementsHead) / 32) {
            return (false, 0, 0, 0);
        }
        count = decodedCount;
        end = elementsHead + count * 32;
        return (true, count, elementsHead, end);
    }

    function _tryValidateBytesArray(bytes memory data, uint256 payloadLength, uint256 elementsHead, uint256 count)
        private
        pure
        returns (bool)
    {
        if (elementsHead > payloadLength || count > (payloadLength - elementsHead) / 32) return false;
        uint256 available = payloadLength - elementsHead;
        uint256 previousEnd = count * 32;
        for (uint256 i; i < count;) {
            (bool offsetOk, uint256 relativeOffset) = _tryReadWord(data, 4 + elementsHead + i * 32);
            if (
                !offsetOk || relativeOffset < previousEnd || relativeOffset % 32 != 0 || relativeOffset > available
                    || available - relativeOffset < 32
            ) {
                return false;
            }
            (bool itemOk, uint256 itemLength, uint256 paddedLength) =
                _tryDynamicBytesLength(data, 4 + elementsHead + relativeOffset, available - relativeOffset);
            if (!itemOk) return false;
            previousEnd = relativeOffset + 32 + paddedLength;
            if (itemLength > paddedLength) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function _tryReadBytesArrayElement(bytes memory data, uint256 payloadLength, uint256 elementsHead, uint256 index)
        private
        pure
        returns (bool, bytes memory item)
    {
        uint256 elementHead = 4 + elementsHead + index * 32;
        (bool offsetOk, uint256 relativeOffset) = _tryReadWord(data, elementHead);
        if (!offsetOk || elementsHead + relativeOffset > payloadLength) return (false, item);
        uint256 lengthHead = elementsHead + relativeOffset;
        (bool lengthOk, uint256 itemLength) = _tryReadWord(data, 4 + lengthHead);
        if (!lengthOk || itemLength > payloadLength - lengthHead - 32) return (false, item);
        item = _copyBytes(data, 4 + lengthHead + 32, itemLength);
        return (true, item);
    }

    function _tryReadDynamicBytes(
        bytes memory data,
        uint256 baseOffset,
        uint256 payloadLength,
        uint256 offset,
        uint256 minimumTail
    ) private pure returns (bool, bytes memory value) {
        if (!_validDynamicOffset(offset, payloadLength, minimumTail)) return (false, value);
        uint256 lengthHead = baseOffset + offset;
        (bool lengthOk, uint256 byteLength) = _tryReadWord(data, lengthHead);
        if (!lengthOk) return (false, value);
        uint256 dataOffset = offset + 32;
        uint256 available = payloadLength - dataOffset;
        if (byteLength > available) return (false, value);
        uint256 padding = (32 - (byteLength % 32)) % 32;
        if (padding > available - byteLength) return (false, value);
        value = _copyBytes(data, baseOffset + dataOffset, byteLength);
        return (true, value);
    }

    function _tryDynamicBytesLength(bytes memory data, uint256 lengthHead, uint256 available)
        private
        pure
        returns (bool, uint256 byteLength, uint256 paddedLength)
    {
        (bool lengthOk, uint256 decodedLength) = _tryReadWord(data, lengthHead);
        if (!lengthOk || decodedLength > available - 32) return (false, 0, 0);
        uint256 padding = (32 - (decodedLength % 32)) % 32;
        if (padding > available - 32 - decodedLength) return (false, 0, 0);
        return (true, decodedLength, decodedLength + padding);
    }

    function _tryReadAddress(bytes memory data, uint256 offset) private pure returns (bool, address account) {
        (bool wordOk, uint256 encoded) = _tryReadWord(data, offset);
        if (!wordOk || encoded > type(uint160).max) return (false, address(0));
        return (true, address(uint160(encoded)));
    }

    function _tryReadWord(bytes memory data, uint256 offset) private pure returns (bool, uint256 word) {
        if (!_hasRange(data, offset, 32)) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), offset))
        }
        return (true, word);
    }

    function _validDynamicOffset(uint256 offset, uint256 payloadLength, uint256 minimumTail)
        private
        pure
        returns (bool)
    {
        return offset >= minimumTail && offset % 32 == 0 && offset <= payloadLength && payloadLength - offset >= 32;
    }

    function _hasRange(bytes memory data, uint256 offset, uint256 length) private pure returns (bool) {
        return offset <= data.length && length <= data.length - offset;
    }

    function _copyBytes(bytes memory data, uint256 offset, uint256 length) private pure returns (bytes memory value) {
        value = new bytes(length);
        for (uint256 i; i < length;) {
            value[i] = data[offset + i];
            unchecked {
                ++i;
            }
        }
    }
}

interface IForageGovernorMigrationTimelock {
    function PROPOSER_ROLE() external view returns (bytes32);

    function CANCELLER_ROLE() external view returns (bytes32);

    function EXECUTOR_ROLE() external view returns (bytes32);

    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IForageGovernorMigrationProposals {
    function state(uint256 proposalId) external view returns (IGovernor.ProposalState);

    function getProposalParams(uint256 proposalId)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash);
}

interface IForageGovernorMigrationGuard {
    function canonicalRegistryAddress() external view returns (address);

    function hasMixedGuardianSelfAuthorityForMigration(
        address executor,
        address governor,
        address guardianModule,
        address registryOwner,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external view returns (bool);
}

library ForageGovernorTimelockMigrationGuard {
    error TimelockRoleMissing(bytes32 role, address account);
    error GuardianTimelockMigrationNotPrepared(address requestedTimelock, address pendingTimelock);
    error GuardianTimelockStateUnavailable(address guardianModule);
    error QueuedProposalBlocksTimelockUpdate(uint256 queuedCount, uint256 proposalId);
    error ActiveProposalListExceedsCap(uint256 observed, uint256 maximum);
    error CanonicalRegistryOwnerUnavailable(address registry);
    error StoredProposalWouldBecomeGuardianProtectedWhileMixed(uint256 proposalId);

    bytes4 private constant _PENDING_TIMELOCK_SELECTOR = bytes4(keccak256("pendingTimelock()"));
    bytes4 private constant _OWNER_SELECTOR = bytes4(keccak256("owner()"));
    uint256 private constant _AUTHORITY_VIEW_GAS = 30_000;
    uint256 private constant _MAX_ACTIVE_PROPOSAL_IDS = 101;
    bytes32 private constant _EXECUTING_PROPOSAL_ID_SLOT =
        keccak256("openforage.forager.governor.executing-proposal-id");
    bytes32 private constant _EXECUTING_PROPOSAL_ACTIVE_SLOT =
        keccak256("openforage.forager.governor.executing-proposal-active");

    function validate(
        uint256[] storage proposalIds,
        address guardianModule,
        address newTimelock,
        address governor,
        address timelockGuard
    ) public view {
        _validateTimelockRoles(newTimelock, governor);
        _validateGuardianTimelock(guardianModule, newTimelock);
        _requireNoOtherQueuedProposal(proposalIds, guardianModule, newTimelock, governor, timelockGuard);
    }

    function _validateTimelockRoles(address newTimelock, address governor) private view {
        IForageGovernorMigrationTimelock timelockController = IForageGovernorMigrationTimelock(newTimelock);
        bytes32 proposerRole = timelockController.PROPOSER_ROLE();
        if (!timelockController.hasRole(proposerRole, governor)) revert TimelockRoleMissing(proposerRole, governor);
        bytes32 cancellerRole = timelockController.CANCELLER_ROLE();
        if (!timelockController.hasRole(cancellerRole, governor)) revert TimelockRoleMissing(cancellerRole, governor);
        bytes32 executorRole = timelockController.EXECUTOR_ROLE();
        if (
            !timelockController.hasRole(executorRole, address(0)) && !timelockController.hasRole(executorRole, governor)
        ) {
            revert TimelockRoleMissing(executorRole, governor);
        }
    }

    function _validateGuardianTimelock(address guardianModule, address newTimelock) private view {
        if (guardianModule == address(0)) return;
        address pendingTimelock = _readPendingTimelock(guardianModule);
        if (pendingTimelock != newTimelock) {
            revert GuardianTimelockMigrationNotPrepared(newTimelock, pendingTimelock);
        }
    }

    function _readPendingTimelock(address guardianModule) private view returns (address pendingTimelock) {
        bytes memory request = abi.encodeWithSelector(_PENDING_TIMELOCK_SELECTOR);
        bool ok;
        uint256 pendingWord;
        assembly ("memory-safe") {
            ok := staticcall(_AUTHORITY_VIEW_GAS, guardianModule, add(request, 0x20), mload(request), 0, 0x20)
            let returnSize := returndatasize()
            if and(ok, eq(returnSize, 0x20)) { pendingWord := mload(0) }
            if iszero(and(ok, eq(returnSize, 0x20))) { ok := 0 }
        }
        if (!ok || pendingWord > type(uint160).max) revert GuardianTimelockStateUnavailable(guardianModule);
        pendingTimelock = address(uint160(pendingWord));
    }

    function _requireNoOtherQueuedProposal(
        uint256[] storage proposalIds,
        address guardianModule,
        address newTimelock,
        address governor,
        address timelockGuard
    ) private view {
        _reclassifyActiveProposalTrees(proposalIds, guardianModule, newTimelock, governor, timelockGuard);
        uint256 executingProposalId;
        uint256 executionActive;
        bytes32 executionSlot = _EXECUTING_PROPOSAL_ID_SLOT;
        bytes32 executionActiveSlot = _EXECUTING_PROPOSAL_ACTIVE_SLOT;
        assembly ("memory-safe") {
            executingProposalId := tload(executionSlot)
            executionActive := tload(executionActiveSlot)
        }
        uint256 queuedCount;
        uint256 firstQueuedProposalId;
        uint256 len = proposalIds.length;
        for (uint256 i; i < len;) {
            uint256 proposalId = proposalIds[i];
            if (
                (executionActive == 0 || proposalId != executingProposalId)
                    && IGovernor(address(this)).state(proposalId) == IGovernor.ProposalState.Queued
            ) {
                if (queuedCount == 0) firstQueuedProposalId = proposalId;
                ++queuedCount;
            }
            unchecked {
                ++i;
            }
        }
        if (queuedCount != 0) revert QueuedProposalBlocksTimelockUpdate(queuedCount, firstQueuedProposalId);
    }

    function _reclassifyActiveProposalTrees(
        uint256[] storage proposalIds,
        address guardianModule,
        address newTimelock,
        address governor,
        address timelockGuard
    ) private view {
        uint256 len = proposalIds.length;
        if (len > _MAX_ACTIVE_PROPOSAL_IDS) revert ActiveProposalListExceedsCap(len, _MAX_ACTIVE_PROPOSAL_IDS);
        address registry = IForageGovernorMigrationGuard(timelockGuard).canonicalRegistryAddress();
        address registryOwner = _readCanonicalRegistryOwner(registry);
        IForageGovernorMigrationProposals proposals = IForageGovernorMigrationProposals(governor);
        IForageGovernorMigrationGuard guard = IForageGovernorMigrationGuard(timelockGuard);
        for (uint256 i; i < len;) {
            uint256 proposalId = proposalIds[i];
            if (_isNonterminalProposal(proposals.state(proposalId))) {
                _reclassifyProposal(proposalId, proposals, guard, guardianModule, newTimelock, governor, registryOwner);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isNonterminalProposal(IGovernor.ProposalState proposalState) private pure returns (bool) {
        return proposalState == IGovernor.ProposalState.Pending || proposalState == IGovernor.ProposalState.Active
            || proposalState == IGovernor.ProposalState.Succeeded || proposalState == IGovernor.ProposalState.Queued;
    }

    function _reclassifyProposal(
        uint256 proposalId,
        IForageGovernorMigrationProposals proposals,
        IForageGovernorMigrationGuard guard,
        address guardianModule,
        address newTimelock,
        address governor,
        address registryOwner
    ) private view {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) =
            proposals.getProposalParams(proposalId);
        bool mixed = guard.hasMixedGuardianSelfAuthorityForMigration(
            newTimelock, governor, guardianModule, registryOwner, targets, values, calldatas
        );
        if (mixed) revert StoredProposalWouldBecomeGuardianProtectedWhileMixed(proposalId);
    }

    function _readCanonicalRegistryOwner(address registry) private view returns (address owner) {
        bytes memory request = abi.encodeWithSelector(_OWNER_SELECTOR);
        bool ok;
        uint256 ownerWord;
        assembly ("memory-safe") {
            ok := staticcall(_AUTHORITY_VIEW_GAS, registry, add(request, 0x20), mload(request), 0, 0x20)
            let returnSize := returndatasize()
            if and(ok, eq(returnSize, 0x20)) { ownerWord := mload(0) }
            if iszero(and(ok, eq(returnSize, 0x20))) { ok := 0 }
        }
        if (registry == address(0) || !ok || ownerWord == 0 || ownerWord > type(uint160).max) {
            revert CanonicalRegistryOwnerUnavailable(registry);
        }
        owner = address(uint160(ownerWord));
    }
}

contract ForageGovernorTimelockGuard {
    error MalformedTimelockCalldata();
    error TimelockDelayBelowMinimum(uint256 requested, uint256 minimum);
    error TimelockSelfProposerGrant();
    error TimelockExternalProposerGrant(address account);
    error CanonicalCustodianRegistryUnavailable(address registry);
    error ProtectedCallAuthorityUnavailable(address target);
    error ProtectedCallCallerMismatch(address target, address caller, address requiredCaller);
    error CanonicalTimelockUpgradeUnsupported(address target);
    error GuardianSeatSetupBundledWithUnrelatedAction(address current, address successor);
    error GuardianSelfAuthorityBundledWithUnrelatedAction(address target, bytes4 selector);

    bytes4 private constant _GUARDIAN_PROPOSE_TIMELOCK_SELECTOR = bytes4(keccak256("proposeTimelock(address)"));
    bytes4 private constant _GUARDIAN_UPGRADE_SELECTOR = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    bytes4 private constant _TIMELOCK_REVOKE_ROLE_SELECTOR = bytes4(keccak256("revokeRole(bytes32,address)"));
    bytes4 private constant _TIMELOCK_RENOUNCE_ROLE_SELECTOR = bytes4(keccak256("renounceRole(bytes32,address)"));
    bytes4 private constant _OWNER_SELECTOR = bytes4(keccak256("owner()"));
    bytes4 private constant _PENDING_TIMELOCK_SELECTOR = bytes4(keccak256("pendingTimelock()"));
    bytes4 private constant _GET_ROLE_ADMIN_SELECTOR = bytes4(keccak256("getRoleAdmin(bytes32)"));
    bytes4 private constant _HAS_ROLE_SELECTOR = bytes4(keccak256("hasRole(bytes32,address)"));
    uint256 private constant _AUTHORITY_VIEW_GAS = 30_000;
    bytes32 private constant _GUARDIAN_SEAT_SLOT = keccak256("GUARDIAN_SEAT");
    bytes32 private constant _DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 private constant _CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 private constant _PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 private constant _EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    address private immutable _canonicalCustodianRegistry;

    bytes4 private constant _REGISTRY_PROPOSE_FORAGE_GOVERNOR_SELECTOR =
        bytes4(keccak256("proposeForageGovernor(address)"));
    bytes4 private constant _REGISTRY_FINALIZE_FORAGE_GOVERNOR_SELECTOR = bytes4(keccak256("finalizeForageGovernor()"));
    bytes4 private constant _REGISTRY_SET_ALLOWLIST_SELECTOR = bytes4(keccak256("setAllowlist(address)"));
    bytes4 private constant _GOVERNOR_SET_GUARDIAN_MODULE_SELECTOR = bytes4(keccak256("setGuardianModule(address)"));
    bytes4 private constant _GOVERNOR_UPDATE_TIMELOCK_SELECTOR = bytes4(keccak256("updateTimelock(address)"));
    bytes4 private constant _GOVERNOR_SET_ALLOWLIST_SELECTOR = bytes4(keccak256("setAllowlist(address)"));
    bytes4 private constant _GUARDIAN_SET_GUARDIAN_PERMISSIONS_SELECTOR =
        bytes4(keccak256("setGuardianPermissions(address,uint256)"));
    bytes4 private constant _GUARDIAN_REMOVE_GUARDIAN_SELECTOR = bytes4(keccak256("removeGuardian(address)"));
    bytes4 private constant _GUARDIAN_UPDATE_GOVERNOR_SELECTOR = bytes4(keccak256("updateGovernor(address)"));
    bytes4 private constant _GUARDIAN_SET_ALLOWLIST_SELECTOR = bytes4(keccak256("setAllowlist(address)"));
    bytes4 private constant _GUARDIAN_SET_PAUSABLE_TARGET_SELECTOR =
        bytes4(keccak256("setPausableTarget(address,bool)"));
    bytes4 private constant _GUARDIAN_EXECUTE_ACCELERATED_ROTATION_SELECTOR =
        bytes4(keccak256("executeAcceleratedRotation(bytes32)"));
    bytes4 private constant _GUARDIAN_PROPOSE_ACCELERATED_ROTATION_SELECTOR =
        bytes4(keccak256("proposeAcceleratedRotation(bytes32,address,address)"));
    bytes4 private constant _GUARDIAN_FINALIZE_ROUTINE_ROTATION_SELECTOR =
        bytes4(keccak256("finalizeRoutineRotation(bytes32)"));
    bytes4 private constant _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR =
        bytes4(keccak256("setPreCommittedSuccessor(bytes32,address,address)"));
    bytes4 private constant _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR =
        bytes4(keccak256("proposeRoutineRotation(bytes32,address,address)"));
    bytes4 private constant _GUARDIAN_ACCEPT_TIMELOCK_SELECTOR = bytes4(keccak256("acceptTimelock()"));

    struct FutureTimelockCall {
        address executor;
        address target;
        bytes data;
        uint256 depth;
    }

    struct FutureTimelockQueue {
        FutureTimelockCall[] calls;
        uint256[] count;
    }

    struct GuardianSeatSetupState {
        address current;
        address successor;
        address protectedTarget;
        bytes4 protectedSelector;
        bool found;
        bool hasProtectedAction;
        bool unrelatedAction;
        bool precommitSeen;
        bool routineProposalSeen;
    }

    struct GuardianSeatSetupTracker {
        GuardianSeatSetupState[] states;
    }

    struct TimelockGuardContext {
        address executor;
        address canonicalTimelock;
        address allowedProposer;
        address guardianModule;
        address canonicalRegistry;
        address custodianRegistryOwner;
        address effectiveCaller;
        uint256 delayFloor;
        uint256 nestingBound;
        uint256 depth;
        FutureTimelockQueue futureTimelockCalls;
        GuardianSeatSetupTracker guardianSeatSetupTracker;
        bool trackGuardianSeatSetup;
        bool guardianClassificationOnly;
    }

    enum PolicyKind {
        Delay,
        Grant
    }

    struct TimelockPolicy {
        PolicyKind kind;
        uint256 delay;
        bytes32 role;
        address account;
    }

    struct TimelockPolicyCollection {
        TimelockPolicy[] entries;
        uint256 length;
    }

    constructor(address canonicalCustodianRegistry) {
        if (canonicalCustodianRegistry == address(0)) {
            revert CanonicalCustodianRegistryUnavailable(canonicalCustodianRegistry);
        }
        _canonicalCustodianRegistry = canonicalCustodianRegistry;
    }

    function canonicalRegistryAddress() external view returns (address) {
        return _canonicalCustodianRegistry;
    }

    function enforceOperations(
        address executor,
        address allowedProposer,
        address guardianModule,
        uint256 delayFloor,
        uint256 nestingBound,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external view {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _validateProposalBounds(targets, values, calldatas, budget);
        address custodianRegistryOwner = _readAuthorityAddress(_canonicalCustodianRegistry, _OWNER_SELECTOR);
        FutureTimelockQueue memory futureTimelockCalls = _newFutureTimelockQueue(targets.length);
        GuardianSeatSetupTracker memory setupTracker = _newGuardianSeatSetupTracker();
        TimelockPolicyCollection memory policies = _newPolicyCollection(targets.length);
        TimelockGuardContext memory context = TimelockGuardContext(
            executor,
            executor,
            allowedProposer,
            guardianModule,
            _canonicalCustodianRegistry,
            custodianRegistryOwner,
            executor,
            delayFloor,
            nestingBound,
            0,
            futureTimelockCalls,
            setupTracker,
            true,
            false
        );
        for (uint256 i; i < targets.length; ++i) {
            _collectTimelockPolicies(context, targets[i], calldatas[i], budget, policies);
        }
        _enforceTimelockPolicies(policies, executor, allowedProposer, delayFloor);
        _enforceFutureTimelockExecutors(context, budget, targets, calldatas);
        _revertIfBundledGuardianSeatSetup(setupTracker);
    }

    function hasMixedGuardianSelfAuthorityForMigration(
        address executor,
        address governor,
        address guardianModule,
        address registryOwner,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external view returns (bool) {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _validateProposalBounds(targets, values, calldatas, budget);
        TimelockGuardContext memory context = TimelockGuardContext(
            executor,
            executor,
            governor,
            guardianModule,
            _canonicalCustodianRegistry,
            registryOwner,
            executor,
            0,
            GovernancePayloadBudget.MAX_TIMELOCK_DEPTH,
            0,
            _newFutureTimelockQueue(targets.length),
            _newGuardianSeatSetupTracker(),
            true,
            true
        );
        TimelockPolicyCollection memory policies = _newPolicyCollection(targets.length);
        for (uint256 i; i < targets.length; ++i) {
            _collectTimelockPolicies(context, targets[i], calldatas[i], budget, policies);
        }
        _enforceFutureTimelockExecutors(context, budget, targets, calldatas);
        return _hasBundledGuardianSelfAuthority(context.guardianSeatSetupTracker);
    }

    function _enforceFutureTimelockExecutors(
        TimelockGuardContext memory context,
        GovernancePayloadBudget.Budget memory budget,
        address[] memory targets,
        bytes[] memory calldatas
    ) private view {
        for (uint256 i; i < targets.length; ++i) {
            if (
                targets[i] != context.executor && targets[i] != context.allowedProposer
                    && targets[i] != context.guardianModule && targets[i] != context.canonicalRegistry
                    && _isTimelockScheduleCall(calldatas[i])
            ) {
                _enqueueFutureTimelockCall(context.futureTimelockCalls, targets[i], targets[i], calldatas[i], 0);
            }
        }
        for (uint256 i; i < context.futureTimelockCalls.count[0]; ++i) {
            FutureTimelockCall memory candidate = context.futureTimelockCalls.calls[i];
            TimelockGuardContext memory candidateContext = TimelockGuardContext(
                candidate.executor,
                context.canonicalTimelock,
                context.allowedProposer,
                context.guardianModule,
                context.canonicalRegistry,
                context.custodianRegistryOwner,
                context.effectiveCaller,
                context.delayFloor,
                context.nestingBound,
                candidate.depth,
                context.futureTimelockCalls,
                context.guardianSeatSetupTracker,
                true,
                context.guardianClassificationOnly
            );
            TimelockPolicyCollection memory policies = _newPolicyCollection(1);
            _collectTimelockPolicies(candidateContext, candidate.target, candidate.data, budget, policies);
            if (!context.guardianClassificationOnly) {
                _enforceTimelockPolicies(policies, candidate.executor, context.allowedProposer, context.delayFloor);
            }
        }
    }

    function _newFutureTimelockQueue(uint256 rootActions) private pure returns (FutureTimelockQueue memory queue) {
        queue.calls = new FutureTimelockCall[](rootActions + GovernancePayloadBudget.MAX_NESTED_ACTION_VISITS);
        queue.count = new uint256[](1);
    }

    function _newGuardianSeatSetupTracker() private pure returns (GuardianSeatSetupTracker memory tracker) {
        tracker.states = new GuardianSeatSetupState[](1);
    }

    function _enqueueFutureTimelockCall(
        FutureTimelockQueue memory queue,
        address executor,
        address target,
        bytes memory data,
        uint256 depth
    ) private pure {
        uint256 count = queue.count[0];
        if (count >= queue.calls.length) revert MalformedTimelockCalldata();
        queue.calls[count] = FutureTimelockCall(executor, target, data, depth);
        queue.count[0] = count + 1;
    }

    function _isTimelockScheduleCall(bytes memory data) private pure returns (bool) {
        if (data.length < 4) return false;
        bytes4 selector = _operationSelector(data);
        return selector == _timelockScheduleSelector() || selector == _timelockScheduleBatchSelector();
    }

    function _recordGuardianSeatSetupAction(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        bytes4 selector
    ) private pure {
        if (!context.trackGuardianSeatSetup) return;
        if (context.custodianRegistryOwner != context.canonicalTimelock && target == context.custodianRegistryOwner) {
            _recordGuardianSelfAuthorityCandidate(context.guardianSeatSetupTracker, target, selector);
            return;
        }
        if (_isGuardianSeatSetupWrapper(context, target, selector)) return;
        if (!_isGuardianSelfAuthorityCandidate(context, target, data, selector)) {
            _markGuardianSeatActionUnrelated(context);
            return;
        }
        _recordGuardianSelfAuthorityCandidate(context.guardianSeatSetupTracker, target, selector);
        GovernancePayloadBudget.GuardianSeatSetupCandidate memory candidate = GovernancePayloadBudget
            .guardianSeatSetupCandidate(data, target, context.guardianModule, _GUARDIAN_SEAT_SLOT);
        if (!candidate.found) return;
        _recordGuardianSeatSetupCandidate(
            context.guardianSeatSetupTracker, candidate.current, candidate.successor, candidate.routine
        );
    }

    function _isGuardianSelfAuthorityCandidate(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        bytes4 selector
    ) private pure returns (bool) {
        if (target == context.allowedProposer) return _isGovernorProtectedSelector(selector);
        if (target == context.executor) return _isTimelockSelfAuthorityCandidate(context, data, selector);
        if (target == context.guardianModule && target != address(0)) {
            return _isGuardianModuleSelfAuthorityCandidate(context, data, selector);
        }
        if (target == context.canonicalRegistry && target != address(0)) return _isRegistryMutation(selector);
        return false;
    }

    function _isTimelockSelfAuthorityCandidate(TimelockGuardContext memory context, bytes memory data, bytes4 selector)
        private
        pure
        returns (bool)
    {
        if (selector == _updateDelaySelector() || selector == _GUARDIAN_UPGRADE_SELECTOR) return true;
        if (
            selector != _timelockGrantRoleSelector() && selector != _TIMELOCK_REVOKE_ROLE_SELECTOR
                && selector != _TIMELOCK_RENOUNCE_ROLE_SELECTOR
        ) return false;
        if (data.length < 68) return false;
        bytes32 role = bytes32(_readWord(data, 4));
        if (!_isProtectedTimelockRole(role)) return false;
        return selector != _TIMELOCK_RENOUNCE_ROLE_SELECTOR
            || address(uint160(_readWord(data, 36))) == context.effectiveCaller;
    }

    function _isGuardianModuleSelfAuthorityCandidate(
        TimelockGuardContext memory context,
        bytes memory data,
        bytes4 selector
    ) private pure returns (bool) {
        if (
            _isGuardianModuleAddressMutation(selector) || selector == _GUARDIAN_ACCEPT_TIMELOCK_SELECTOR
                || selector == _GUARDIAN_EXECUTE_ACCELERATED_ROTATION_SELECTOR
                || selector == _GUARDIAN_FINALIZE_ROUTINE_ROTATION_SELECTOR
        ) return true;
        if (
            selector == _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR
                || selector == _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR
        ) {
            GovernancePayloadBudget.GuardianSeatSetupCandidate memory candidate = GovernancePayloadBudget
                .guardianSeatSetupCandidate(data, context.guardianModule, context.guardianModule, _GUARDIAN_SEAT_SLOT);
            if (candidate.found) return true;
            return selector == _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR
                && _isGuardianRotationProposalCandidate(data, selector);
        }
        return selector == _GUARDIAN_PROPOSE_ACCELERATED_ROTATION_SELECTOR
            && _isGuardianRotationProposalCandidate(data, selector);
    }

    function _isGuardianRotationProposalCandidate(bytes memory data, bytes4 selector) private pure returns (bool) {
        if (data.length < 100) return false;
        uint256 slot = _readWord(data, 4);
        address current = _readAddress(data, 36);
        address successor = _readAddress(data, 68);
        if (slot == 0 || current == address(0) || successor == address(0)) return false;
        if (selector == _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR) {
            return slot == uint256(_GUARDIAN_SEAT_SLOT) && current != successor;
        }
        return selector == _GUARDIAN_PROPOSE_ACCELERATED_ROTATION_SELECTOR;
    }

    function _recordGuardianSelfAuthorityCandidate(
        GuardianSeatSetupTracker memory tracker,
        address target,
        bytes4 selector
    ) private pure {
        GuardianSeatSetupState[] memory states = tracker.states;
        if (!states[0].hasProtectedAction) {
            states[0].protectedTarget = target;
            states[0].protectedSelector = selector;
            states[0].hasProtectedAction = true;
        }
    }

    function _isGuardianSeatSetupWrapper(TimelockGuardContext memory context, address target, bytes4 selector)
        private
        pure
        returns (bool)
    {
        bool schedule = selector == _timelockScheduleSelector() || selector == _timelockScheduleBatchSelector();
        bool currentExecutor = target == context.executor;
        return target == context.allowedProposer && selector == _governorRelaySelector()
            || schedule && (currentExecutor || _isFutureTimelockExecutor(context, target));
    }

    function _isFutureTimelockExecutor(TimelockGuardContext memory context, address target)
        private
        pure
        returns (bool)
    {
        return target != address(0) && target != context.executor && target != context.allowedProposer
            && target != context.guardianModule && target != context.canonicalRegistry;
    }

    function _recordGuardianSeatSetupCandidate(
        GuardianSeatSetupTracker memory tracker,
        address current,
        address successor,
        bool routine
    ) private pure {
        GuardianSeatSetupState[] memory states = tracker.states;
        if (!states[0].found) {
            states[0].found = true;
            states[0].current = current;
            states[0].successor = successor;
        } else if (states[0].current != current || states[0].successor != successor) {
            states[0].unrelatedAction = true;
            return;
        }
        if (routine) {
            if (states[0].routineProposalSeen) {
                states[0].unrelatedAction = true;
                return;
            }
            states[0].routineProposalSeen = true;
        } else {
            if (states[0].precommitSeen) {
                states[0].unrelatedAction = true;
                return;
            }
            states[0].precommitSeen = true;
        }
    }

    function _markGuardianSeatActionUnrelated(TimelockGuardContext memory context) private pure {
        if (!context.trackGuardianSeatSetup) return;
        GuardianSeatSetupState[] memory states = context.guardianSeatSetupTracker.states;
        states[0].unrelatedAction = true;
    }

    function _revertIfBundledGuardianSeatSetup(GuardianSeatSetupTracker memory tracker) private pure {
        if (!_hasBundledGuardianSelfAuthority(tracker)) return;
        GuardianSeatSetupState memory state = tracker.states[0];
        if (state.found) {
            revert GuardianSeatSetupBundledWithUnrelatedAction(state.current, state.successor);
        }
        revert GuardianSelfAuthorityBundledWithUnrelatedAction(state.protectedTarget, state.protectedSelector);
    }

    function _hasBundledGuardianSelfAuthority(GuardianSeatSetupTracker memory tracker) private pure returns (bool) {
        GuardianSeatSetupState memory state = tracker.states[0];
        return state.hasProtectedAction && state.unrelatedAction;
    }

    function _nextTimelockDepth(TimelockGuardContext memory context) private pure returns (uint256) {
        if (context.depth >= context.nestingBound) revert MalformedTimelockCalldata();
        return context.depth + 1;
    }

    function _queueNestedTimelockSchedule(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        uint256 parentLength
    ) private pure {
        if (
            target == context.executor || target == context.allowedProposer || target == context.guardianModule
                || target == context.canonicalRegistry || !_isTimelockScheduleCall(data)
        ) return;
        if (data.length >= parentLength) revert MalformedTimelockCalldata();
        _enqueueFutureTimelockCall(context.futureTimelockCalls, target, target, data, _nextTimelockDepth(context));
    }

    function _queueRelayedTimelock(TimelockGuardContext memory context, address target, bytes memory data)
        private
        pure
    {
        if (target == address(0) || target == context.executor || target == context.allowedProposer) return;
        _enqueueFutureTimelockCall(context.futureTimelockCalls, target, target, data, _nextTimelockDepth(context));
    }

    function enforceOperation(
        address executor,
        address allowedProposer,
        address guardianModule,
        uint256 delayFloor,
        uint256 nestingBound,
        address target,
        bytes memory data
    ) external view {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _addActionBytes(budget, data.length);
        FutureTimelockQueue memory futureTimelockCalls = _newFutureTimelockQueue(1);
        TimelockGuardContext memory context = TimelockGuardContext(
            executor,
            executor,
            allowedProposer,
            guardianModule,
            _canonicalCustodianRegistry,
            address(0),
            allowedProposer,
            delayFloor,
            nestingBound,
            0,
            futureTimelockCalls,
            GuardianSeatSetupTracker(new GuardianSeatSetupState[](0)),
            false,
            false
        );
        TimelockPolicyCollection memory policies = _newPolicyCollection(1);
        _collectTimelockPolicies(context, target, data, budget, policies);
        _enforceTimelockPolicies(policies, executor, allowedProposer, delayFloor);
        address[] memory targets = new address[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;
        _enforceFutureTimelockExecutors(context, budget, targets, calldatas);
    }

    function _validateProposalBounds(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        GovernancePayloadBudget.Budget memory budget
    ) private pure {
        uint256 actionCount = targets.length;
        if (actionCount != values.length || actionCount != calldatas.length) revert MalformedTimelockCalldata();
        if (actionCount > GovernancePayloadBudget.MAX_TOP_LEVEL_ACTIONS) revert MalformedTimelockCalldata();
        for (uint256 i; i < actionCount; ++i) {
            _addActionBytes(budget, calldatas[i].length);
        }
    }

    function _addActionBytes(GovernancePayloadBudget.Budget memory budget, uint256 actionBytes) private pure {
        uint256 maximum = GovernancePayloadBudget.MAX_TOP_LEVEL_ACTION_BYTES;
        if (actionBytes > maximum - budget.actionBytes) revert MalformedTimelockCalldata();
        budget.actionBytes += actionBytes;
    }

    function _consumeNestedVisits(GovernancePayloadBudget.Budget memory budget, uint256 visits) private pure {
        uint256 maximum = GovernancePayloadBudget.MAX_NESTED_ACTION_VISITS;
        if (visits > maximum - budget.nestedVisits) revert MalformedTimelockCalldata();
        budget.nestedVisits += visits;
    }

    function _collectTimelockPolicies(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        GovernancePayloadBudget.Budget memory budget,
        TimelockPolicyCollection memory policies
    ) private view {
        if (data.length < 4) {
            _recordGuardianSeatSetupAction(context, target, data, bytes4(0));
            return;
        }
        bytes4 selector = _operationSelector(data);
        if (!context.guardianClassificationOnly) {
            _revertIfMalformedGuardianMutation(context, target, data, selector);
            _revertIfUnauthorizedProtectedCall(context, target, data, selector);
        }
        _recordGuardianSeatSetupAction(context, target, data, selector);
        if (target == context.allowedProposer && selector == _governorRelaySelector()) {
            _consumeNestedVisits(budget, 1);
            (bool valid, GovernancePayloadBudget.OperationPayload memory relayed) =
                GovernancePayloadBudget.tryDecodeRelay(data);
            if (!valid) revert MalformedTimelockCalldata();
            if (relayed.data.length >= data.length) revert MalformedTimelockCalldata();
            TimelockGuardContext memory relayContext = _contextWithEffectiveCaller(context, context.allowedProposer);
            if (relayed.target == context.executor || relayed.target == context.allowedProposer) {
                _collectTimelockPolicies(
                    _nestedTimelockContext(relayContext, relayContext.effectiveCaller),
                    relayed.target,
                    relayed.data,
                    budget,
                    policies
                );
            } else if (relayed.target == context.guardianModule && relayed.target != address(0)) {
                _collectTimelockPolicies(relayContext, relayed.target, relayed.data, budget, policies);
            } else if (relayed.target == context.canonicalRegistry && relayed.target != address(0)) {
                _collectTimelockPolicies(relayContext, relayed.target, relayed.data, budget, policies);
            } else {
                _queueRelayedTimelock(relayContext, relayed.target, relayed.data);
            }
            return;
        }
        if (target != context.executor) return;
        if (selector == _updateDelaySelector()) {
            if (!context.guardianClassificationOnly) _appendDelay(policies, _readWord(_operationPayload(data), 0));
            return;
        }
        if (selector == _timelockGrantRoleSelector()) {
            if (!context.guardianClassificationOnly) {
                bytes memory payload = _operationPayload(data);
                _appendGrant(policies, bytes32(_readWord(payload, 0)), _readAddress(payload, 32));
            }
            return;
        }
        if (selector == _timelockScheduleSelector()) {
            _consumeNestedVisits(budget, 1);
            (bool valid, GovernancePayloadBudget.OperationPayload memory scheduled) =
                GovernancePayloadBudget.tryDecodeSchedule(data);
            if (!valid) revert MalformedTimelockCalldata();
            if (scheduled.data.length >= data.length) revert MalformedTimelockCalldata();
            TimelockGuardContext memory scheduleContext = _contextWithEffectiveCaller(context, context.executor);
            if (scheduled.target == context.executor || scheduled.target == context.allowedProposer) {
                _collectTimelockPolicies(
                    _nestedTimelockContext(scheduleContext, context.executor),
                    scheduled.target,
                    scheduled.data,
                    budget,
                    policies
                );
            } else if (scheduled.target == context.guardianModule && scheduled.target != address(0)) {
                _collectTimelockPolicies(scheduleContext, scheduled.target, scheduled.data, budget, policies);
            } else if (scheduled.target == context.canonicalRegistry && scheduled.target != address(0)) {
                _collectTimelockPolicies(scheduleContext, scheduled.target, scheduled.data, budget, policies);
            } else {
                _queueNestedTimelockSchedule(scheduleContext, scheduled.target, scheduled.data, data.length);
            }
            return;
        }
        if (selector == _timelockScheduleBatchSelector()) {
            _collectTimelockBatchPolicies(context, data, budget, policies);
        }
    }

    function _revertIfMalformedGuardianMutation(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        bytes4 selector
    ) private pure {
        if (target == context.allowedProposer) {
            _revertIfMalformedGovernorMutation(data, selector);
            return;
        }
        if (target == context.executor) {
            _revertIfMalformedTimelockMutation(data, selector);
            return;
        }
        if (context.guardianModule != address(0) && target == context.guardianModule) {
            _revertIfMalformedGuardianModuleMutation(data, selector);
            return;
        }
        if (context.canonicalRegistry != address(0) && target == context.canonicalRegistry) {
            _revertIfMalformedRegistryMutation(data, selector);
        }
    }

    function _revertIfUnauthorizedProtectedCall(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        bytes4 selector
    ) private view {
        if (target == context.canonicalTimelock && selector == _GUARDIAN_UPGRADE_SELECTOR) {
            revert CanonicalTimelockUpgradeUnsupported(target);
        }
        if (target == context.allowedProposer) {
            _revertIfUnauthorizedGovernorCall(context, target, selector);
            return;
        }
        if (target == context.executor) {
            _revertIfUnauthorizedTimelockCall(context, target, data, selector);
            return;
        }
        if (context.guardianModule != address(0) && target == context.guardianModule) {
            _revertIfUnauthorizedGuardianModuleCall(context, target, selector);
            return;
        }
        if (context.canonicalRegistry != address(0) && target == context.canonicalRegistry) {
            _revertIfUnauthorizedRegistryCall(context, target, selector);
        }
    }

    function _revertIfUnauthorizedGovernorCall(TimelockGuardContext memory context, address target, bytes4 selector)
        private
        view
    {
        if (!_isGovernorProtectedSelector(selector) && selector != _governorRelaySelector()) return;
        _requireCallerMatch(target, context.effectiveCaller, context.executor);
    }

    function _isGovernorProtectedSelector(bytes4 selector) private pure returns (bool) {
        return _isGovernorAddressMutation(selector) || selector == _GUARDIAN_UPGRADE_SELECTOR;
    }

    function _revertIfUnauthorizedTimelockCall(
        TimelockGuardContext memory context,
        address target,
        bytes memory data,
        bytes4 selector
    ) private view {
        if (selector == _updateDelaySelector() || selector == _GUARDIAN_UPGRADE_SELECTOR) {
            _requireCallerMatch(target, context.effectiveCaller, target);
            return;
        }
        if (selector == _TIMELOCK_RENOUNCE_ROLE_SELECTOR) {
            bytes32 role = bytes32(_readWord(data, 4));
            if (_isProtectedTimelockRole(role)) {
                _requireCallerMatch(target, context.effectiveCaller, _readTimelockRoleAccount(data));
            }
            return;
        }
        if (selector == _timelockGrantRoleSelector() || selector == _TIMELOCK_REVOKE_ROLE_SELECTOR) {
            _revertIfCallerLacksTimelockAdmin(target, context.effectiveCaller, bytes32(_readWord(data, 4)));
        }
    }

    function _isProtectedTimelockRole(bytes32 role) private pure returns (bool) {
        return
            role == _CANCELLER_ROLE || role == _DEFAULT_ADMIN_ROLE || role == _PROPOSER_ROLE || role == _EXECUTOR_ROLE;
    }

    function _revertIfCallerLacksTimelockAdmin(address target, address caller, bytes32 role) private view {
        if (!_isProtectedTimelockRole(role)) return;
        bytes32 adminRole = bytes32(_readAuthorityWord(target, abi.encodeWithSelector(_GET_ROLE_ADMIN_SELECTOR, role)));
        bytes memory request = abi.encodeWithSelector(_HAS_ROLE_SELECTOR, adminRole, caller);
        uint256 answer = _readAuthorityWord(target, request);
        if (answer > 1) revert ProtectedCallAuthorityUnavailable(target);
        if (answer == 0) revert ProtectedCallCallerMismatch(target, caller, target);
    }

    function _revertIfUnauthorizedGuardianModuleCall(
        TimelockGuardContext memory context,
        address target,
        bytes4 selector
    ) private view {
        if (selector == _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR) {
            _requireCallerMatch(target, context.effectiveCaller, context.allowedProposer);
            return;
        }
        if (selector == _GUARDIAN_ACCEPT_TIMELOCK_SELECTOR) {
            address pendingTimelock = _readPendingTimelock(target);
            _requireCallerMatch(target, context.effectiveCaller, pendingTimelock);
            return;
        }
        if (_isGuardianModuleTimelockMutation(selector)) _requireGuardianTimelockCaller(context, target);
    }

    function _requireGuardianTimelockCaller(TimelockGuardContext memory context, address target) private pure {
        _requireCallerMatch(target, context.effectiveCaller, context.executor);
    }

    function _revertIfUnauthorizedRegistryCall(TimelockGuardContext memory context, address target, bytes4 selector)
        private
        view
    {
        if (!_isRegistryMutation(selector)) return;
        if (target.code.length == 0) revert CanonicalCustodianRegistryUnavailable(target);
        address registryOwner = _readAuthorityAddress(target, _OWNER_SELECTOR);
        _requireCallerMatch(target, context.effectiveCaller, registryOwner);
    }

    function _isRegistryMutation(bytes4 selector) private pure returns (bool) {
        return selector == _REGISTRY_PROPOSE_FORAGE_GOVERNOR_SELECTOR
            || selector == _REGISTRY_FINALIZE_FORAGE_GOVERNOR_SELECTOR || selector == _REGISTRY_SET_ALLOWLIST_SELECTOR
            || selector == _GUARDIAN_UPGRADE_SELECTOR;
    }

    function _requireCallerMatch(address target, address caller, address requiredCaller) private pure {
        if (caller != requiredCaller) revert ProtectedCallCallerMismatch(target, caller, requiredCaller);
    }

    function _readAuthorityAddress(address target, bytes4 selector) private view returns (address account) {
        uint256 word = _readAuthorityWord(target, abi.encodeWithSelector(selector));
        if (word == 0 || word > type(uint160).max) revert ProtectedCallAuthorityUnavailable(target);
        account = address(uint160(word));
    }

    function _readPendingTimelock(address target) private view returns (address account) {
        uint256 word = _readAuthorityWord(target, abi.encodeWithSelector(_PENDING_TIMELOCK_SELECTOR));
        if (word > type(uint160).max) revert ProtectedCallAuthorityUnavailable(target);
        account = address(uint160(word));
    }

    function _readAuthorityWord(address target, bytes memory request) private view returns (uint256 value) {
        bool ok;
        uint256 result;
        assembly ("memory-safe") {
            ok := staticcall(_AUTHORITY_VIEW_GAS, target, add(request, 0x20), mload(request), 0, 0x20)
            let returnSize := returndatasize()
            if and(ok, eq(returnSize, 0x20)) { result := mload(0) }
            if iszero(and(ok, eq(returnSize, 0x20))) { ok := 0 }
        }
        if (!ok) revert ProtectedCallAuthorityUnavailable(target);
        value = result;
    }

    function _revertIfMalformedTimelockMutation(bytes memory data, bytes4 selector) private pure {
        if (selector == _GUARDIAN_UPGRADE_SELECTOR) {
            _revertIfMalformedUpgrade(data);
            return;
        }
        if (selector == _updateDelaySelector()) {
            _readWord(data, 4);
            return;
        }
        if (selector == _timelockGrantRoleSelector()) {
            _readTimelockRoleAccount(data);
            return;
        }
        if (selector == _TIMELOCK_REVOKE_ROLE_SELECTOR) {
            _readTimelockRoleAccount(data);
            return;
        }
        if (selector == _TIMELOCK_RENOUNCE_ROLE_SELECTOR) _readTimelockRoleAccount(data);
    }

    function _revertIfMalformedRegistryMutation(bytes memory data, bytes4 selector) private pure {
        if (selector == _REGISTRY_PROPOSE_FORAGE_GOVERNOR_SELECTOR || selector == _REGISTRY_SET_ALLOWLIST_SELECTOR) {
            _revertIfZeroAddressArgument(data);
            return;
        }
        if (selector == _REGISTRY_FINALIZE_FORAGE_GOVERNOR_SELECTOR) {
            if (data.length < 4) revert MalformedTimelockCalldata();
            return;
        }
        if (selector == _GUARDIAN_UPGRADE_SELECTOR) _revertIfMalformedUpgrade(data);
    }

    function _readTimelockRoleAccount(bytes memory data) private pure returns (address account) {
        _readWord(data, 4);
        account = _readAddress(data, 36);
    }

    function _revertIfMalformedGovernorMutation(bytes memory data, bytes4 selector) private pure {
        if (_isGovernorAddressMutation(selector)) {
            _revertIfZeroAddressArgument(data);
        } else if (selector == _GUARDIAN_UPGRADE_SELECTOR) {
            _revertIfMalformedUpgrade(data);
        }
    }

    function _isGovernorAddressMutation(bytes4 selector) private pure returns (bool) {
        return selector == _GOVERNOR_SET_GUARDIAN_MODULE_SELECTOR || selector == _GOVERNOR_UPDATE_TIMELOCK_SELECTOR
            || selector == _GOVERNOR_SET_ALLOWLIST_SELECTOR;
    }

    function _revertIfMalformedGuardianModuleMutation(bytes memory data, bytes4 selector) private pure {
        if (
            selector == _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR
                || selector == _GUARDIAN_PROPOSE_ROUTINE_ROTATION_SELECTOR
        ) {
            _revertIfMalformedGuardianSeatSetup(data, selector);
            return;
        }
        if (selector == _GUARDIAN_ACCEPT_TIMELOCK_SELECTOR) return;
        if (_isGuardianModuleAddressMutation(selector)) _revertIfZeroAddressArgument(data);
        _revertIfMalformedGuardianModuleArguments(data, selector);
    }

    function _isGuardianModuleAddressMutation(bytes4 selector) private pure returns (bool) {
        return selector == _GUARDIAN_SET_GUARDIAN_PERMISSIONS_SELECTOR || selector == _GUARDIAN_REMOVE_GUARDIAN_SELECTOR
            || selector == _GUARDIAN_UPDATE_GOVERNOR_SELECTOR || selector == _GUARDIAN_SET_ALLOWLIST_SELECTOR
            || selector == _GUARDIAN_SET_PAUSABLE_TARGET_SELECTOR || selector == _GUARDIAN_PROPOSE_TIMELOCK_SELECTOR
            || selector == _GUARDIAN_UPGRADE_SELECTOR;
    }

    function _isGuardianModuleTimelockMutation(bytes4 selector) private pure returns (bool) {
        return _isGuardianModuleAddressMutation(selector) || selector == _GUARDIAN_FINALIZE_ROUTINE_ROTATION_SELECTOR
            || selector == _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR;
    }

    function _revertIfMalformedGuardianSeatSetup(bytes memory data, bytes4 selector) private pure {
        if (data.length < 100) revert MalformedTimelockCalldata();
        uint256 slot = _readWord(data, 4);
        address current = _readAddress(data, 36);
        address successor = _readAddress(data, 68);
        if (successor == address(0)) revert MalformedTimelockCalldata();
        if (selector == _GUARDIAN_SET_PRECOMMITTED_SUCCESSOR_SELECTOR && (slot == 0 || current == address(0))) {
            revert MalformedTimelockCalldata();
        }
    }

    function _revertIfMalformedGuardianModuleArguments(bytes memory data, bytes4 selector) private pure {
        if (selector == _GUARDIAN_SET_GUARDIAN_PERMISSIONS_SELECTOR) {
            _revertIfInvalidGuardianPermissions(_readWord(data, 36));
        } else if (selector == _GUARDIAN_SET_PAUSABLE_TARGET_SELECTOR) {
            if (_readWord(data, 36) > 1) revert MalformedTimelockCalldata();
        } else if (selector == _GUARDIAN_EXECUTE_ACCELERATED_ROTATION_SELECTOR) {
            _readWord(data, 4);
        } else if (selector == _GUARDIAN_FINALIZE_ROUTINE_ROTATION_SELECTOR) {
            _readWord(data, 4);
        } else if (selector == _GUARDIAN_UPGRADE_SELECTOR) {
            _revertIfMalformedUpgrade(data);
        }
    }

    function _revertIfInvalidGuardianPermissions(uint256 permissions) private pure {
        if (permissions > 15 || (permissions & 3) == 3) revert MalformedTimelockCalldata();
    }

    function _revertIfZeroAddressArgument(bytes memory data) private pure {
        if (_readAddress(data, 4) == address(0)) revert MalformedTimelockCalldata();
    }

    function _revertIfMalformedUpgrade(bytes memory data) private pure {
        if (!GovernancePayloadBudget.isValidAddressAndBytes(data) || _readAddress(data, 4) == address(0)) {
            revert MalformedTimelockCalldata();
        }
    }

    function _collectTimelockBatchPolicies(
        TimelockGuardContext memory context,
        bytes memory data,
        GovernancePayloadBudget.Budget memory budget,
        TimelockPolicyCollection memory policies
    ) private view {
        (bool headerOk, GovernancePayloadBudget.ScheduleBatchHeader memory header) =
            GovernancePayloadBudget.tryReadScheduleBatchHeader(data);
        if (!headerOk) revert MalformedTimelockCalldata();
        _consumeNestedVisits(budget, header.targetsLength);
        (bool targetsOk, address[] memory targets) = GovernancePayloadBudget.tryReadScheduleBatchTargets(data, header);
        if (!targetsOk) revert MalformedTimelockCalldata();
        _requireBatchRecursionDepth(context, targets);
        (bool batchOk, GovernancePayloadBudget.ScheduleBatchPayload memory batch) =
            GovernancePayloadBudget.tryDecodeScheduleBatch(data, header, targets);
        if (!batchOk) revert MalformedTimelockCalldata();
        _collectTimelockBatchChildren(context, data, batch, budget, policies);
    }

    function _requireBatchRecursionDepth(TimelockGuardContext memory context, address[] memory targets) private pure {
        for (uint256 i; i < targets.length; ++i) {
            if (
                (targets[i] == context.executor || targets[i] == context.allowedProposer)
                    && context.depth >= context.nestingBound
            ) {
                revert MalformedTimelockCalldata();
            }
        }
    }

    function _collectTimelockBatchChildren(
        TimelockGuardContext memory context,
        bytes memory data,
        GovernancePayloadBudget.ScheduleBatchPayload memory batch,
        GovernancePayloadBudget.Budget memory budget,
        TimelockPolicyCollection memory policies
    ) private view {
        TimelockGuardContext memory scheduleContext = _contextWithEffectiveCaller(context, context.executor);
        for (uint256 i; i < batch.targets.length; ++i) {
            address scheduledTarget = batch.targets[i];
            if (scheduledTarget == context.executor || scheduledTarget == context.allowedProposer) {
                bytes memory scheduledData = batch.calldatas[i];
                if (scheduledData.length >= data.length) revert MalformedTimelockCalldata();
                _collectTimelockPolicies(
                    _nestedTimelockContext(scheduleContext, context.executor),
                    scheduledTarget,
                    scheduledData,
                    budget,
                    policies
                );
            } else if (scheduledTarget == context.guardianModule && scheduledTarget != address(0)) {
                _collectTimelockPolicies(scheduleContext, scheduledTarget, batch.calldatas[i], budget, policies);
            } else if (scheduledTarget == context.canonicalRegistry && scheduledTarget != address(0)) {
                _collectTimelockPolicies(scheduleContext, scheduledTarget, batch.calldatas[i], budget, policies);
            } else {
                _queueNestedTimelockSchedule(scheduleContext, scheduledTarget, batch.calldatas[i], data.length);
            }
        }
    }

    function _newPolicyCollection(uint256 topLevelActions)
        private
        pure
        returns (TimelockPolicyCollection memory policies)
    {
        uint256 capacity = topLevelActions + GovernancePayloadBudget.MAX_NESTED_ACTION_VISITS;
        policies.entries = new TimelockPolicy[](capacity);
    }

    function _appendDelay(TimelockPolicyCollection memory policies, uint256 delay) private pure {
        if (policies.length >= policies.entries.length) revert MalformedTimelockCalldata();
        policies.entries[policies.length] = TimelockPolicy(PolicyKind.Delay, delay, bytes32(0), address(0));
        ++policies.length;
    }

    function _appendGrant(TimelockPolicyCollection memory policies, bytes32 role, address account) private pure {
        if (policies.length >= policies.entries.length) revert MalformedTimelockCalldata();
        policies.entries[policies.length] = TimelockPolicy(PolicyKind.Grant, 0, role, account);
        ++policies.length;
    }

    function _enforceTimelockPolicies(
        TimelockPolicyCollection memory policies,
        address executor,
        address allowedProposer,
        uint256 delayFloor
    ) private pure {
        for (uint256 i; i < policies.length; ++i) {
            TimelockPolicy memory policy = policies.entries[i];
            if (policy.kind == PolicyKind.Delay) _revertIfDelayBelowFloor(policy.delay, delayFloor);
        }
        bytes32 proposerRole = _timelockProposerRole();
        for (uint256 i; i < policies.length; ++i) {
            TimelockPolicy memory policy = policies.entries[i];
            if (policy.kind == PolicyKind.Grant && policy.role == proposerRole) {
                if (policy.account == executor) revert TimelockSelfProposerGrant();
                if (policy.account != allowedProposer) revert TimelockExternalProposerGrant(policy.account);
            }
        }
    }

    function _contextWithEffectiveCaller(TimelockGuardContext memory context, address effectiveCaller)
        private
        pure
        returns (TimelockGuardContext memory nested)
    {
        nested = context;
        nested.effectiveCaller = effectiveCaller;
    }

    function _nestedTimelockContext(TimelockGuardContext memory context, address effectiveCaller)
        private
        pure
        returns (TimelockGuardContext memory nested)
    {
        if (context.depth >= context.nestingBound) revert MalformedTimelockCalldata();
        nested = context;
        nested.effectiveCaller = effectiveCaller;
        nested.depth = context.depth + 1;
    }

    function _readAddress(bytes memory data, uint256 offset) private pure returns (address account) {
        uint256 encoded = _readWord(data, offset);
        if (encoded > type(uint160).max) revert MalformedTimelockCalldata();
        account = address(uint160(encoded));
    }

    function _readWord(bytes memory data, uint256 offset) private pure returns (uint256 value) {
        if (offset > data.length || data.length - offset < 32) revert MalformedTimelockCalldata();
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _operationSelector(bytes memory data) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _operationPayload(bytes memory data) private pure returns (bytes memory payload) {
        uint256 payloadLength = data.length - 4;
        payload = new bytes(payloadLength);
        for (uint256 i; i < payloadLength;) {
            payload[i] = data[i + 4];
            unchecked {
                ++i;
            }
        }
    }

    function _revertIfDelayBelowFloor(uint256 newDelay, uint256 delayFloor) private pure {
        if (newDelay < delayFloor) {
            revert TimelockDelayBelowMinimum(newDelay, delayFloor);
        }
    }

    function _updateDelaySelector() private pure returns (bytes4) {
        return bytes4(keccak256("updateDelay(uint256)"));
    }

    function _timelockScheduleSelector() private pure returns (bytes4) {
        return bytes4(keccak256("schedule(address,uint256,bytes,bytes32,bytes32,uint256)"));
    }

    function _timelockScheduleBatchSelector() private pure returns (bytes4) {
        return bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)"));
    }

    function _governorRelaySelector() private pure returns (bytes4) {
        return bytes4(keccak256("relay(address,uint256,bytes)"));
    }

    function _timelockGrantRoleSelector() private pure returns (bytes4) {
        return bytes4(keccak256("grantRole(bytes32,address)"));
    }

    function _timelockProposerRole() private pure returns (bytes32) {
        return keccak256("PROPOSER_ROLE");
    }
}
