// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

contract ForageGovernorTimelockGuard {
    error MalformedTimelockCalldata();
    error TimelockDelayBelowMinimum(uint256 requested, uint256 minimum);
    error TimelockSelfProposerGrant();
    error TimelockExternalProposerGrant(address account);

    bytes4 private constant _GUARDIAN_PROPOSE_TIMELOCK_SELECTOR = bytes4(keccak256("proposeTimelock(address)"));
    bytes4 private constant _GUARDIAN_UPGRADE_SELECTOR = bytes4(keccak256("upgradeToAndCall(address,bytes)"));

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

    struct TimelockGuardContext {
        address executor;
        address allowedProposer;
        address guardianModule;
        uint256 delayFloor;
        uint256 nestingBound;
        uint256 depth;
        FutureTimelockQueue futureTimelockCalls;
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

    function enforceOperations(
        address executor,
        address allowedProposer,
        address guardianModule,
        uint256 delayFloor,
        uint256 nestingBound,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external pure {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _validateProposalBounds(targets, values, calldatas, budget);
        FutureTimelockQueue memory futureTimelockCalls = _newFutureTimelockQueue(targets.length);
        TimelockPolicyCollection memory policies = _newPolicyCollection(targets.length);
        TimelockGuardContext memory context = TimelockGuardContext(
            executor, allowedProposer, guardianModule, delayFloor, nestingBound, 0, futureTimelockCalls
        );
        for (uint256 i; i < targets.length; ++i) {
            _collectTimelockPolicies(context, targets[i], calldatas[i], budget, policies);
        }
        _enforceTimelockPolicies(policies, executor, allowedProposer, delayFloor);
        _enforceFutureTimelockExecutors(context, budget, targets, calldatas);
    }

    function _enforceFutureTimelockExecutors(
        TimelockGuardContext memory context,
        GovernancePayloadBudget.Budget memory budget,
        address[] memory targets,
        bytes[] memory calldatas
    ) private pure {
        for (uint256 i; i < targets.length; ++i) {
            if (
                targets[i] != context.executor && targets[i] != context.allowedProposer
                    && _isTimelockScheduleCall(calldatas[i])
            ) {
                _enqueueFutureTimelockCall(context.futureTimelockCalls, targets[i], targets[i], calldatas[i], 0);
            }
        }
        for (uint256 i; i < context.futureTimelockCalls.count[0]; ++i) {
            FutureTimelockCall memory candidate = context.futureTimelockCalls.calls[i];
            TimelockGuardContext memory candidateContext = TimelockGuardContext(
                candidate.executor,
                context.allowedProposer,
                context.guardianModule,
                context.delayFloor,
                context.nestingBound,
                candidate.depth,
                context.futureTimelockCalls
            );
            TimelockPolicyCollection memory policies = _newPolicyCollection(1);
            _collectTimelockPolicies(candidateContext, candidate.target, candidate.data, budget, policies);
            _enforceTimelockPolicies(policies, candidate.executor, context.allowedProposer, context.delayFloor);
        }
    }

    function _newFutureTimelockQueue(uint256 rootActions) private pure returns (FutureTimelockQueue memory queue) {
        queue.calls = new FutureTimelockCall[](rootActions + GovernancePayloadBudget.MAX_NESTED_ACTION_VISITS);
        queue.count = new uint256[](1);
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
                || !_isTimelockScheduleCall(data)
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
    ) external pure {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _addActionBytes(budget, data.length);
        FutureTimelockQueue memory futureTimelockCalls = _newFutureTimelockQueue(1);
        TimelockGuardContext memory context = TimelockGuardContext(
            executor, allowedProposer, guardianModule, delayFloor, nestingBound, 0, futureTimelockCalls
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
    ) private pure {
        if (data.length < 4) return;
        bytes4 selector = _operationSelector(data);
        _revertIfMalformedGuardianMutation(context.guardianModule, target, data, selector);
        if (target == context.allowedProposer && selector == _governorRelaySelector()) {
            _consumeNestedVisits(budget, 1);
            (bool valid, GovernancePayloadBudget.OperationPayload memory relayed) =
                GovernancePayloadBudget.tryDecodeRelay(data);
            if (!valid) revert MalformedTimelockCalldata();
            if (relayed.data.length >= data.length) revert MalformedTimelockCalldata();
            if (relayed.target == context.guardianModule && relayed.target != address(0)) {
                _collectTimelockPolicies(context, relayed.target, relayed.data, budget, policies);
            } else if (relayed.target == context.executor || relayed.target == context.allowedProposer) {
                _collectTimelockPolicies(
                    _nestedTimelockContext(context), relayed.target, relayed.data, budget, policies
                );
            } else {
                _queueRelayedTimelock(context, relayed.target, relayed.data);
            }
            return;
        }
        if (target != context.executor) return;
        if (selector == _updateDelaySelector()) {
            _appendDelay(policies, _readWord(_operationPayload(data), 0));
            return;
        }
        if (selector == _timelockGrantRoleSelector()) {
            bytes memory payload = _operationPayload(data);
            _appendGrant(policies, bytes32(_readWord(payload, 0)), _readAddress(payload, 32));
            return;
        }
        if (selector == _timelockScheduleSelector()) {
            _consumeNestedVisits(budget, 1);
            (bool valid, GovernancePayloadBudget.OperationPayload memory scheduled) =
                GovernancePayloadBudget.tryDecodeSchedule(data);
            if (!valid) revert MalformedTimelockCalldata();
            if (scheduled.data.length >= data.length) revert MalformedTimelockCalldata();
            if (scheduled.target == context.guardianModule && scheduled.target != address(0)) {
                _collectTimelockPolicies(context, scheduled.target, scheduled.data, budget, policies);
            } else if (scheduled.target == context.executor || scheduled.target == context.allowedProposer) {
                _collectTimelockPolicies(
                    _nestedTimelockContext(context), scheduled.target, scheduled.data, budget, policies
                );
            } else {
                _queueNestedTimelockSchedule(context, scheduled.target, scheduled.data, data.length);
            }
            return;
        }
        if (selector == _timelockScheduleBatchSelector()) {
            _collectTimelockBatchPolicies(context, data, budget, policies);
        }
    }

    function _revertIfMalformedGuardianMutation(
        address guardianModule,
        address target,
        bytes memory data,
        bytes4 selector
    ) private pure {
        if (guardianModule == address(0) || target != guardianModule) return;
        if (selector == _GUARDIAN_PROPOSE_TIMELOCK_SELECTOR) {
            if (data.length < 36 || _readAddress(data, 4) == address(0)) revert MalformedTimelockCalldata();
        } else if (selector == _GUARDIAN_UPGRADE_SELECTOR && !GovernancePayloadBudget.isValidAddressAndBytes(data)) {
            revert MalformedTimelockCalldata();
        }
    }

    function _collectTimelockBatchPolicies(
        TimelockGuardContext memory context,
        bytes memory data,
        GovernancePayloadBudget.Budget memory budget,
        TimelockPolicyCollection memory policies
    ) private pure {
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
    ) private pure {
        for (uint256 i; i < batch.targets.length; ++i) {
            address scheduledTarget = batch.targets[i];
            if (scheduledTarget == context.executor || scheduledTarget == context.allowedProposer) {
                bytes memory scheduledData = batch.calldatas[i];
                if (scheduledData.length >= data.length) revert MalformedTimelockCalldata();
                _collectTimelockPolicies(
                    _nestedTimelockContext(context), scheduledTarget, scheduledData, budget, policies
                );
            } else if (scheduledTarget == context.guardianModule && scheduledTarget != address(0)) {
                _collectTimelockPolicies(context, scheduledTarget, batch.calldatas[i], budget, policies);
            } else {
                _queueNestedTimelockSchedule(context, scheduledTarget, batch.calldatas[i], data.length);
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

    function _nestedTimelockContext(TimelockGuardContext memory context)
        private
        pure
        returns (TimelockGuardContext memory nested)
    {
        if (context.depth >= context.nestingBound) revert MalformedTimelockCalldata();
        nested = TimelockGuardContext(
            context.executor,
            context.allowedProposer,
            context.guardianModule,
            context.delayFloor,
            context.nestingBound,
            context.depth + 1,
            context.futureTimelockCalls
        );
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
