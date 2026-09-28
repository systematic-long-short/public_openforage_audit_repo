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
}

contract ForageGovernorTimelockGuard {
    error MalformedTimelockCalldata();
    error TimelockDelayBelowMinimum(uint256 requested, uint256 minimum);
    error TimelockSelfProposerGrant();
    error TimelockExternalProposerGrant(address account);

    struct TimelockGuardContext {
        address executor;
        address allowedProposer;
        uint256 delayFloor;
        uint256 nestingBound;
        uint256 depth;
    }

    struct TimelockArray {
        uint256 offset;
        uint256 length;
        uint256 end;
    }

    struct TimelockSchedulePayload {
        address target;
        bytes data;
    }

    struct TimelockBatchPayload {
        bytes data;
        TimelockArray targets;
        TimelockArray values;
        TimelockArray calldatas;
    }

    struct TimelockRelayPayload {
        address target;
        bytes data;
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
        uint256 delayFloor,
        uint256 nestingBound,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external pure {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _validateProposalBounds(targets, values, calldatas, budget);
        TimelockPolicyCollection memory policies = _newPolicyCollection(targets.length);
        for (uint256 i; i < targets.length; ++i) {
            TimelockGuardContext memory context =
                TimelockGuardContext(executor, allowedProposer, delayFloor, nestingBound, 0);
            _collectTimelockPolicies(context, targets[i], calldatas[i], budget, policies);
        }
        _enforceTimelockPolicies(policies, executor, allowedProposer, delayFloor);
    }

    function enforceOperation(
        address executor,
        address allowedProposer,
        uint256 delayFloor,
        uint256 nestingBound,
        address target,
        bytes memory data
    ) external pure {
        GovernancePayloadBudget.Budget memory budget = GovernancePayloadBudget.Budget(0, 0);
        _addActionBytes(budget, data.length);
        TimelockPolicyCollection memory policies = _newPolicyCollection(1);
        _collectTimelockPolicies(
            TimelockGuardContext(executor, allowedProposer, delayFloor, nestingBound, 0), target, data, budget, policies
        );
        _enforceTimelockPolicies(policies, executor, allowedProposer, delayFloor);
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
        if (target == context.allowedProposer && selector == _governorRelaySelector()) {
            address relayedTarget = _readAddress(data, 4);
            TimelockGuardContext memory nestedContext = context;
            if (relayedTarget == context.executor || relayedTarget == context.allowedProposer) {
                nestedContext = _nestedTimelockContext(context);
            }
            _consumeNestedVisits(budget, 1);
            TimelockRelayPayload memory relayed = _decodeTimelockRelay(data);
            if (relayed.data.length >= data.length) revert MalformedTimelockCalldata();
            if (relayed.target == context.executor || relayed.target == context.allowedProposer) {
                _collectTimelockPolicies(nestedContext, relayed.target, relayed.data, budget, policies);
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
            address scheduledTarget = _readAddress(data, 4);
            TimelockGuardContext memory nestedContext = context;
            if (scheduledTarget == context.executor || scheduledTarget == context.allowedProposer) {
                nestedContext = _nestedTimelockContext(context);
            }
            _consumeNestedVisits(budget, 1);
            TimelockSchedulePayload memory scheduled = _decodeTimelockSchedule(data);
            if (scheduled.data.length >= data.length) revert MalformedTimelockCalldata();
            if (scheduled.target == context.executor || scheduled.target == context.allowedProposer) {
                _collectTimelockPolicies(nestedContext, scheduled.target, scheduled.data, budget, policies);
            }
            return;
        }
        if (selector == _timelockScheduleBatchSelector()) {
            uint256 childCount = _timelockBatchTargetCount(data);
            _consumeNestedVisits(budget, childCount);
            uint256 targetsOffset = _readWord(data, 4);
            uint256 targetsHead = 4 + targetsOffset + 32;
            for (uint256 i; i < childCount; ++i) {
                address nestedTarget = _readAddress(data, targetsHead + i * 32);
                if (
                    (nestedTarget == context.executor || nestedTarget == context.allowedProposer)
                        && context.depth >= context.nestingBound
                ) {
                    revert MalformedTimelockCalldata();
                }
            }
            TimelockBatchPayload memory batch = _decodeTimelockBatch(data);
            for (uint256 i; i < batch.targets.length; ++i) {
                address scheduledTarget = _readAddress(batch.data, batch.targets.offset + i * 32);
                if (scheduledTarget == context.executor || scheduledTarget == context.allowedProposer) {
                    bytes memory scheduledData = _readBytesArrayElement(batch.data, batch.calldatas, i);
                    if (scheduledData.length >= data.length) revert MalformedTimelockCalldata();
                    _collectTimelockPolicies(
                        _nestedTimelockContext(context), scheduledTarget, scheduledData, budget, policies
                    );
                }
            }
        }
    }

    function _timelockBatchTargetCount(bytes memory data) private pure returns (uint256 count) {
        if (data.length < 196) revert MalformedTimelockCalldata();
        uint256 offset = _readWord(data, 4);
        if (offset < 192 || offset % 32 != 0 || offset > data.length - 4) {
            revert MalformedTimelockCalldata();
        }
        uint256 arrayHead = 4 + offset;
        if (arrayHead > data.length || data.length - arrayHead < 32) revert MalformedTimelockCalldata();
        count = _readWord(data, arrayHead);
        uint256 elementsHead = arrayHead + 32;
        if (elementsHead > data.length || count > (data.length - elementsHead) / 32) {
            revert MalformedTimelockCalldata();
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
            context.executor, context.allowedProposer, context.delayFloor, context.nestingBound, context.depth + 1
        );
    }

    function _decodeTimelockSchedule(bytes memory data)
        private
        pure
        returns (TimelockSchedulePayload memory scheduled)
    {
        bytes memory payload = _operationPayload(data);
        if (payload.length < 192) revert MalformedTimelockCalldata();
        scheduled.target = _readAddress(payload, 0);
        uint256 dataOffset = _validatedDynamicOffset(payload, 64, 192);
        scheduled.data = _readDynamicBytes(payload, dataOffset);
    }

    function _decodeTimelockRelay(bytes memory data) private pure returns (TimelockRelayPayload memory relayed) {
        bytes memory payload = _operationPayload(data);
        if (payload.length < 128) revert MalformedTimelockCalldata();
        relayed.target = _readAddress(payload, 0);
        _readWord(payload, 32);
        uint256 dataOffset = _validatedDynamicOffset(payload, 64, 96);
        relayed.data = _readDynamicBytes(payload, dataOffset);
    }

    function _decodeTimelockBatch(bytes memory data) private pure returns (TimelockBatchPayload memory batch) {
        batch.data = _operationPayload(data);
        if (batch.data.length < 192) revert MalformedTimelockCalldata();

        uint256 targetsArrayOffset = _validatedDynamicOffset(batch.data, 0, 192);
        uint256 valuesArrayOffset = _validatedDynamicOffset(batch.data, 32, 192);
        uint256 calldatasArrayOffset = _validatedDynamicOffset(batch.data, 64, 192);
        batch.targets = _decodeTimelockArray(batch.data, targetsArrayOffset);
        batch.values = _decodeTimelockArray(batch.data, valuesArrayOffset);
        batch.calldatas = _decodeTimelockArray(batch.data, calldatasArrayOffset);

        if (
            batch.targets.length != batch.values.length || batch.targets.length != batch.calldatas.length
                || batch.values.offset < batch.targets.end || batch.calldatas.offset < batch.values.end
        ) {
            revert MalformedTimelockCalldata();
        }
        _validateTimelockAddressArray(batch.data, batch.targets);
        _validateTimelockBytesArray(batch.data, batch.calldatas);
    }

    function _decodeTimelockArray(bytes memory payload, uint256 arrayOffset)
        private
        pure
        returns (TimelockArray memory array)
    {
        array.length = _readWord(payload, arrayOffset);
        array.offset = arrayOffset + 32;
        uint256 available = payload.length - array.offset;
        if (array.length > available / 32) revert MalformedTimelockCalldata();
        array.end = array.offset + array.length * 32;
    }

    function _validateTimelockAddressArray(bytes memory payload, TimelockArray memory array) private pure {
        for (uint256 i; i < array.length; ++i) {
            _readAddress(payload, array.offset + i * 32);
        }
    }

    function _validateTimelockBytesArray(bytes memory payload, TimelockArray memory array) private pure {
        uint256 available = payload.length - array.offset;
        uint256 previousEnd = array.length * 32;
        for (uint256 i; i < array.length; ++i) {
            uint256 relativeOffset = _readWord(payload, array.offset + i * 32);
            if (
                relativeOffset < previousEnd || relativeOffset % 32 != 0 || relativeOffset > available
                    || available - relativeOffset < 32
            ) {
                revert MalformedTimelockCalldata();
            }
            (,, uint256 paddedLength) = _validateDynamicBytes(payload, array.offset + relativeOffset);
            previousEnd = relativeOffset + 32 + paddedLength;
        }
    }

    function _readBytesArrayElement(bytes memory payload, TimelockArray memory array, uint256 index)
        private
        pure
        returns (bytes memory)
    {
        if (index >= array.length) revert MalformedTimelockCalldata();
        uint256 relativeOffset = _readWord(payload, array.offset + index * 32);
        return _readDynamicBytes(payload, array.offset + relativeOffset);
    }

    function _validatedDynamicOffset(bytes memory payload, uint256 headOffset, uint256 headLength)
        private
        pure
        returns (uint256 offset)
    {
        offset = _readWord(payload, headOffset);
        if (offset < headLength || offset % 32 != 0 || offset > payload.length || payload.length - offset < 32) {
            revert MalformedTimelockCalldata();
        }
    }

    function _readDynamicBytes(bytes memory payload, uint256 offset) private pure returns (bytes memory value) {
        (uint256 length, uint256 dataOffset,) = _validateDynamicBytes(payload, offset);
        value = new bytes(length);
        for (uint256 i; i < length; ++i) {
            value[i] = payload[dataOffset + i];
        }
    }

    function _validateDynamicBytes(bytes memory payload, uint256 offset)
        private
        pure
        returns (uint256 length, uint256 dataOffset, uint256 paddedLength)
    {
        length = _readWord(payload, offset);
        dataOffset = offset + 32;
        uint256 available = payload.length - dataOffset;
        if (length > available) revert MalformedTimelockCalldata();
        uint256 padding = (32 - (length % 32)) % 32;
        if (padding > available - length) revert MalformedTimelockCalldata();
        paddedLength = length + padding;
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
