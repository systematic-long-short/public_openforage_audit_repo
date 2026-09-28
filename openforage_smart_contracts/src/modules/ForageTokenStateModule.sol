pragma solidity ^0.8.20;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IForageTokenBalanceView {
    function balanceOf(address account) external view returns (uint256);
}

struct ForageTokenStateUpdate {
    address source;
    address newDelegate;
    uint256 votes;
    uint256 newBaseVotes;
    uint48 firstTransitionTime;
    int256 firstTransitionDelta;
    uint48 secondTransitionTime;
    int256 secondTransitionDelta;
    bool unindexedLegacyVestingSource;
}

contract ForageTokenStateModule {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MAX_DELEGATE_SOURCES = 128;
    uint256 private constant MAX_LOCKERS_PER_ACCOUNT = 32;
    bytes32 private constant ELIGIBILITY_TRANSITION_OVERLAY_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.ForageTokenStateModule.EligibilityTransitionOverlay")) - 1)
    ) & ~bytes32(uint256(0xff));

    error DirectCallForbidden();
    error DelegateSourceTrackingFailed(address delegatee, address source);
    error TooManyDelegateSources(address delegatee, uint256 count, uint256 maximum);
    error TooManyAccountLockers(address account, uint256 maximum);
    error EligibilityAccountingUnderflow(address delegatee, uint256 available, uint256 requested);
    error EligibilityAccountingOverflow(address delegatee, uint256 value);
    error TooManyVestingSources(address beneficiary, uint256 count, uint256 maximum);
    error LockBalanceExceedsBalance(address account, uint256 locked, uint256 balance);
    error InsufficientLockedBalance(address account, uint256 available, uint256 required);
    error NoLockerBalance();
    error ZeroAddress();

    event AuthorizedBurnerUpdated(address indexed burner, bool authorized);
    event AuthorizedLockerUpdated(address indexed locker, bool authorized);
    event ForageLocked(address indexed account, uint256 amount, address indexed locker);
    event ForageUnlocked(address indexed account, uint256 amount, address indexed locker);

    struct VoteSourceState {
        address delegatee;
        uint208 baseVotes;
        uint48 firstTransitionTime;
        int256 firstTransitionDelta;
        uint48 secondTransitionTime;
        int256 secondTransitionDelta;
    }

    struct TransitionPath {
        address delegatee;
        uint256 point;
        uint8 cursor;
        uint8 pathId;
        bool active;
    }

    struct TransitionSlot {
        address delegatee;
        uint256 key;
        int256 original;
        int256 value;
        bool loaded;
    }

    struct EligibilityTransitionOverlayStorage {
        mapping(address => mapping(uint256 => int256)) radixDeltas;
    }

    mapping(address => bool) internal _authorizedBurners;
    mapping(address => bool) internal _authorizedLockers;
    mapping(address => uint256) internal _lockedBalances;
    mapping(address => bool) private _lockExempt;
    mapping(address => mapping(address => uint256)) internal _lockerBalances;
    mapping(address => EnumerableSet.AddressSet) private _accountLockers;
    address internal _blocklist;
    mapping(address => EnumerableSet.AddressSet) private _delegateSources;
    mapping(address => EnumerableSet.AddressSet) private _historicalDelegateSources;
    mapping(address => mapping(address => Checkpoints.Trace208)) private _delegateSourceCheckpoints;
    mapping(address => VoteSourceState) private _voteSourceStates;
    mapping(address => Checkpoints.Trace208) private _eligibleDelegateVotes;
    mapping(address => mapping(uint256 => int256)) private _eligibilityTransitionTree;
    mapping(address => address) private _vestingBeneficiaryBySource;
    mapping(address => EnumerableSet.AddressSet) private _vestingSourcesByBeneficiary;
    address private _initialTeamVestingSource;
    address private _initialTreasurySource;
    uint256[37] private __gap;

    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    function eligibilityTransitionPrefix(address delegatee, uint256 timepoint)
        external
        view
        onlyDelegateCall
        returns (int256)
    {
        if (timepoint > type(uint48).max) return 0;
        int256 fenwickPrefix = _fenwickTransitionPrefix(delegatee, timepoint);
        int256 radixPrefix = _radixTransitionPrefix(delegatee, timepoint);
        return fenwickPrefix + radixPrefix;
    }

    function _fenwickTransitionPrefix(address delegatee, uint256 timepoint) private view returns (int256 delta) {
        uint256 index = timepoint + 1;
        while (index != 0) {
            delta += _eligibilityTransitionTree[delegatee][index];
            index -= index & (~index + 1);
        }
    }

    function _radixTransitionPrefix(address delegatee, uint256 timepoint) private view returns (int256 delta) {
        uint256 point = timepoint + 1;
        EligibilityTransitionOverlayStorage storage overlay = _eligibilityTransitionOverlayStorage();
        delta = overlay.radixDeltas[delegatee][(uint256(1) << 50) | point];
        for (uint256 depth = 5; depth > 0; --depth) {
            uint256 shift = 50 - depth * 10;
            uint256 prefix = point >> shift;
            uint256 minimum = prefix & ~uint256(1023);
            if (depth == 5 && minimum == 0) minimum = 1;
            uint256 marker = uint256(1) << (depth * 10);
            while (prefix > minimum) {
                --prefix;
                delta += overlay.radixDeltas[delegatee][marker | prefix];
            }
        }
    }

    function _eligibilityTransitionOverlayStorage()
        private
        pure
        returns (EligibilityTransitionOverlayStorage storage layout)
    {
        bytes32 slot = ELIGIBILITY_TRANSITION_OVERLAY_SLOT;
        assembly ("memory-safe") {
            layout.slot := slot
        }
    }

    function rememberVestingBeneficiary(address source, address beneficiary) external onlyDelegateCall {
        _vestingBeneficiaryBySource[source] = beneficiary;
    }

    function setAuthorizedBurner(address burner, bool authorized) external onlyDelegateCall {
        if (burner == address(0)) revert ZeroAddress();
        _authorizedBurners[burner] = authorized;
        emit AuthorizedBurnerUpdated(burner, authorized);
    }

    function setAuthorizedLocker(address locker, bool authorized) external onlyDelegateCall {
        if (locker == address(0)) revert ZeroAddress();
        _authorizedLockers[locker] = authorized;
        emit AuthorizedLockerUpdated(locker, authorized);
    }

    function prepareDelegateSourceChange(address source, address oldDelegate) external onlyDelegateCall {
        if (oldDelegate == address(0)) return;
        if (_historicalDelegateSources[oldDelegate].contains(source)) {
            _delegateSources[oldDelegate].remove(source);
            _writeDelegateSourceCheckpoint(oldDelegate, source, 0);
        } else {
            _clearNewVoteContribution(source);
        }
    }

    function applyDelegateSourceUpdate(ForageTokenStateUpdate calldata update, bool isDelegation)
        external
        onlyDelegateCall
    {
        if (isDelegation) {
            if (update.newDelegate == address(0) || update.votes == 0) {
                _clearNewVoteContribution(update.source);
                return;
            }
            if (_historicalDelegateSources[update.newDelegate].contains(update.source)) {
                _clearNewVoteContribution(update.source);
                _recordActiveDelegateSource(update.newDelegate, update.source);
                _writeDelegateSourceCheckpoint(update.newDelegate, update.source, update.votes);
                return;
            }
        } else {
            if (update.newDelegate == address(0)) {
                _clearNewVoteContribution(update.source);
                return;
            }
            if (_historicalDelegateSources[update.newDelegate].contains(update.source)) {
                if (update.votes == 0) {
                    _delegateSources[update.newDelegate].remove(update.source);
                    _writeDelegateSourceCheckpoint(update.newDelegate, update.source, 0);
                    return;
                }
                _recordActiveDelegateSource(update.newDelegate, update.source);
                _writeDelegateSourceCheckpoint(update.newDelegate, update.source, update.votes);
                return;
            }
        }
        if (update.unindexedLegacyVestingSource) {
            _syncLegacyVestingContribution(update.source, update.newDelegate, update.votes);
            return;
        }
        _syncNewVoteContribution(update);
    }

    function updateVestingSourceMembership(address source, address delegatee, uint256 votes, uint256 maximum)
        external
        onlyDelegateCall
    {
        _updateVestingSourceMembership(source, delegatee, votes, maximum, true);
    }

    function updateRegisteredVestingSourceMembership(
        address source,
        address delegatee,
        uint256 votes,
        uint256 maximum,
        bool currentlyRegistered
    ) external onlyDelegateCall {
        _updateVestingSourceMembership(source, delegatee, votes, maximum, currentlyRegistered);
    }

    function burn(address from, uint256 amount) external onlyDelegateCall {
        uint256 currentBalance = IForageTokenBalanceView(address(this)).balanceOf(from);
        if (currentBalance < amount) return;
        uint256 newBalance = currentBalance - amount;
        uint256 locked = _lockedBalances[from];
        if (newBalance >= locked) return;
        uint256 excess = locked - newBalance;
        uint256 length = _accountLockers[from].length();
        if (length == 0) {
            emit ForageUnlocked(from, excess, msg.sender);
            _lockedBalances[from] = newBalance;
            return;
        }
        uint256 reduced;
        for (uint256 i; i < length; i++) {
            address locker = _accountLockers[from].at(i);
            uint256 lockerBalance = _lockerBalances[from][locker];
            uint256 reduction;
            if (i == length - 1) {
                reduction = excess - reduced;
            } else {
                reduction = (lockerBalance * excess) / locked;
            }
            if (reduction > lockerBalance) reduction = lockerBalance;
            _lockerBalances[from][locker] -= reduction;
            reduced += reduction;
            if (reduction > 0) emit ForageUnlocked(from, reduction, locker);
        }
        uint256 shortfall = excess - reduced;
        if (shortfall > 0) {
            for (uint256 j; j < length && shortfall > 0; j++) {
                address locker = _accountLockers[from].at(j);
                uint256 remaining = _lockerBalances[from][locker];
                if (remaining > 0) {
                    uint256 take = shortfall > remaining ? remaining : shortfall;
                    _lockerBalances[from][locker] -= take;
                    reduced += take;
                    shortfall -= take;
                    if (take > 0) emit ForageUnlocked(from, take, locker);
                }
            }
        }
        for (uint256 i = length; i > 0; i--) {
            address locker = _accountLockers[from].at(i - 1);
            if (_lockerBalances[from][locker] == 0) _accountLockers[from].remove(locker);
        }
        _lockedBalances[from] -= reduced;
    }

    function lock(address account, uint256 amount) external onlyDelegateCall {
        address locker = msg.sender;
        if (_lockerBalances[account][locker] == 0 && !_accountLockers[account].contains(locker)) {
            uint256 lockerCount = _accountLockers[account].length();
            if (lockerCount >= MAX_LOCKERS_PER_ACCOUNT) {
                revert TooManyAccountLockers(account, MAX_LOCKERS_PER_ACCOUNT);
            }
            _accountLockers[account].add(locker);
        }
        _lockedBalances[account] += amount;
        _lockerBalances[account][locker] += amount;
        emit ForageLocked(account, amount, locker);
    }

    function unlock(address account, uint256 amount) external onlyDelegateCall {
        address locker = msg.sender;
        uint256 lockerBalance = _lockerBalances[account][locker];
        if (lockerBalance < amount) revert InsufficientLockedBalance(account, lockerBalance, amount);
        _lockerBalances[account][locker] -= amount;
        _lockedBalances[account] -= amount;
        if (_lockerBalances[account][locker] == 0) _accountLockers[account].remove(locker);
        emit ForageUnlocked(account, amount, locker);
    }

    function setLockExempt(address account, bool exempt) external onlyDelegateCall {
        if (exempt) {
            _lockExempt[account] = true;
            return;
        }
        uint256 length = _accountLockers[account].length();
        uint256 reconciledSum;
        for (uint256 i = 0; i < length; i++) {
            address locker = _accountLockers[account].at(i);
            reconciledSum += _lockerBalances[account][locker];
        }
        uint256 accountBalance = IForageTokenBalanceView(address(this)).balanceOf(account);
        if (reconciledSum > accountBalance) {
            revert LockBalanceExceedsBalance(account, reconciledSum, accountBalance);
        }
        _lockedBalances[account] = reconciledSum;
        _lockExempt[account] = exempt;
    }

    function setBlocklist(address blocklist) external onlyDelegateCall {
        _blocklist = blocklist;
    }

    function emergencyUnlock(address account, address locker) external onlyDelegateCall {
        uint256 lockerBalance = _lockerBalances[account][locker];
        if (lockerBalance == 0) revert NoLockerBalance();
        _lockedBalances[account] -= lockerBalance;
        _lockerBalances[account][locker] = 0;
        _accountLockers[account].remove(locker);
        emit ForageUnlocked(account, lockerBalance, locker);
    }

    function _recordActiveDelegateSource(address delegatee, address source) private {
        bool added = _delegateSources[delegatee].add(source);
        if (!added && !_delegateSources[delegatee].contains(source)) {
            revert DelegateSourceTrackingFailed(delegatee, source);
        }
    }

    function _syncLegacyVestingContribution(address source, address delegatee, uint256 votes) private {
        if (votes == 0) return;
        EnumerableSet.AddressSet storage historicalSources = _historicalDelegateSources[delegatee];
        if (!historicalSources.contains(source)) {
            uint256 sourceCount = historicalSources.length();
            if (sourceCount >= MAX_DELEGATE_SOURCES) {
                revert TooManyDelegateSources(delegatee, sourceCount, MAX_DELEGATE_SOURCES);
            }
            historicalSources.add(source);
        }
        _recordActiveDelegateSource(delegatee, source);
        _writeDelegateSourceCheckpoint(delegatee, source, votes);
    }

    function _syncNewVoteContribution(ForageTokenStateUpdate calldata update) private {
        VoteSourceState storage state = _voteSourceStates[update.source];
        address oldDelegatee = state.delegatee;
        uint48 currentTime = uint48(block.timestamp);
        TransitionPath[4] memory paths;
        _initializeTransitionPaths(paths);
        if (oldDelegatee != address(0)) {
            if (state.firstTransitionTime != 0) {
                uint48 firstTime = state.firstTransitionTime > currentTime ? state.firstTransitionTime : currentTime;
                _prepareTransitionPath(paths, 0, oldDelegatee, firstTime, state.firstTransitionDelta);
            }
            if (state.secondTransitionTime != 0) {
                uint48 secondTime = state.secondTransitionTime > currentTime ? state.secondTransitionTime : currentTime;
                _prepareTransitionPath(paths, 1, oldDelegatee, secondTime, state.secondTransitionDelta);
            }
        }
        _prepareTransitionPath(paths, 2, update.newDelegate, update.firstTransitionTime, update.firstTransitionDelta);
        _prepareTransitionPath(paths, 3, update.newDelegate, update.secondTransitionTime, update.secondTransitionDelta);
        TransitionSlot[20] memory slots;
        uint8[5][4] memory pathIds;
        uint256 uniqueSlots = _buildTransitionSlots(paths, slots, pathIds);

        if (oldDelegatee != address(0)) {
            if (state.firstTransitionTime != 0) {
                _replayTransitionPath(slots, pathIds, 0, _transitionPathLength(paths, 0), -state.firstTransitionDelta);
            }
            if (state.secondTransitionTime != 0) {
                _replayTransitionPath(slots, pathIds, 1, _transitionPathLength(paths, 1), -state.secondTransitionDelta);
            }
            if (oldDelegatee == update.newDelegate) {
                _changeIndexedVotes(update.newDelegate, state.baseVotes, update.newBaseVotes);
            } else {
                _changeIndexedVotes(oldDelegatee, state.baseVotes, 0);
                _changeIndexedVotes(update.newDelegate, 0, update.newBaseVotes);
            }
        } else {
            _changeIndexedVotes(update.newDelegate, 0, update.newBaseVotes);
        }
        state.delegatee = update.newDelegate;
        state.baseVotes = uint208(update.newBaseVotes);
        state.firstTransitionTime = update.firstTransitionTime;
        state.firstTransitionDelta = update.firstTransitionDelta;
        state.secondTransitionTime = update.secondTransitionTime;
        state.secondTransitionDelta = update.secondTransitionDelta;
        if (update.firstTransitionTime != 0) {
            _replayTransitionPath(slots, pathIds, 2, _transitionPathLength(paths, 2), update.firstTransitionDelta);
        }
        if (update.secondTransitionTime != 0) {
            _replayTransitionPath(slots, pathIds, 3, _transitionPathLength(paths, 3), update.secondTransitionDelta);
        }
        _flushTransitionSlots(slots, uniqueSlots);
    }

    function _clearNewVoteContribution(address source) private {
        VoteSourceState storage state = _voteSourceStates[source];
        address delegatee = state.delegatee;
        if (delegatee == address(0)) return;
        uint48 currentTime = uint48(block.timestamp);
        TransitionPath[4] memory paths;
        _initializeTransitionPaths(paths);
        if (state.firstTransitionTime != 0) {
            uint48 firstTime = state.firstTransitionTime > currentTime ? state.firstTransitionTime : currentTime;
            _prepareTransitionPath(paths, 0, delegatee, firstTime, state.firstTransitionDelta);
        }
        if (state.secondTransitionTime != 0) {
            uint48 secondTime = state.secondTransitionTime > currentTime ? state.secondTransitionTime : currentTime;
            _prepareTransitionPath(paths, 1, delegatee, secondTime, state.secondTransitionDelta);
        }
        TransitionSlot[20] memory slots;
        uint8[5][4] memory pathIds;
        uint256 uniqueSlots = _buildTransitionSlots(paths, slots, pathIds);
        if (state.firstTransitionTime != 0) {
            _replayTransitionPath(slots, pathIds, 0, _transitionPathLength(paths, 0), -state.firstTransitionDelta);
        }
        if (state.secondTransitionTime != 0) {
            _replayTransitionPath(slots, pathIds, 1, _transitionPathLength(paths, 1), -state.secondTransitionDelta);
        }
        _changeIndexedVotes(delegatee, state.baseVotes, 0);
        delete _voteSourceStates[source];
        _updateVestingSourceMembership(source, address(0), 0, 0, false);
        _flushTransitionSlots(slots, uniqueSlots);
    }

    function _prepareTransitionPath(
        TransitionPath[4] memory paths,
        uint8 pathId,
        address delegatee,
        uint48 timepoint,
        int256 delta
    ) private pure {
        paths[pathId].pathId = pathId;
        if (timepoint == 0 || delta == 0) return;
        paths[pathId].delegatee = delegatee;
        paths[pathId].point = uint256(timepoint) + 1;
        paths[pathId].active = true;
    }

    function _buildTransitionSlots(
        TransitionPath[4] memory paths,
        TransitionSlot[20] memory slots,
        uint8[5][4] memory pathIds
    ) private pure returns (uint256 slotCount) {
        uint256 heapLength = _buildTransitionHeap(paths);
        while (heapLength != 0) {
            heapLength = _mergeTransitionGroup(paths, slots, pathIds, heapLength, slotCount);
            slotCount += 1;
        }
    }

    function _buildTransitionHeap(TransitionPath[4] memory paths) private pure returns (uint256 heapLength) {
        for (uint8 pathId; pathId < 4; ++pathId) {
            if (!paths[pathId].active) continue;
            _swapTransitionPaths(paths, pathId, heapLength);
            _siftUpTransitionPaths(paths, heapLength);
            heapLength += 1;
        }
    }

    function _mergeTransitionGroup(
        TransitionPath[4] memory paths,
        TransitionSlot[20] memory slots,
        uint8[5][4] memory pathIds,
        uint256 heapLength,
        uint256 slotId
    ) private pure returns (uint256) {
        slots[slotId].delegatee = paths[0].delegatee;
        slots[slotId].key = _transitionTreeIndex(paths[0].point, uint256(paths[0].cursor) + 1);
        return _consumeEqualTransitionHeads(paths, slots, pathIds, heapLength, slotId);
    }

    function _consumeEqualTransitionHeads(
        TransitionPath[4] memory paths,
        TransitionSlot[20] memory slots,
        uint8[5][4] memory pathIds,
        uint256 heapLength,
        uint256 slotId
    ) private pure returns (uint256) {
        bool firstHead = true;
        while (heapLength != 0) {
            if (
                !firstHead
                    && (
                        paths[0].delegatee != slots[slotId].delegatee
                            || _transitionTreeIndex(paths[0].point, uint256(paths[0].cursor) + 1) != slots[slotId].key
                    )
            ) {
                return heapLength;
            }
            firstHead = false;
            heapLength = _advanceTransitionHead(paths, pathIds, heapLength, slotId);
        }
        return heapLength;
    }

    function _advanceTransitionHead(
        TransitionPath[4] memory paths,
        uint8[5][4] memory pathIds,
        uint256 heapLength,
        uint256 slotId
    ) private pure returns (uint256) {
        uint8 pathId = paths[0].pathId;
        uint8 pathCursor = paths[0].cursor;
        pathIds[pathId][pathCursor] = uint8(slotId);
        paths[0].cursor = pathCursor + 1;
        if (paths[0].cursor == 5) {
            heapLength -= 1;
            if (heapLength != 0) {
                _swapTransitionPaths(paths, 0, heapLength);
                _siftDownTransitionPaths(paths, heapLength);
            }
            return heapLength;
        }
        _siftDownTransitionPaths(paths, heapLength);
        return heapLength;
    }

    function _initializeTransitionPaths(TransitionPath[4] memory paths) private pure {
        for (uint8 pathId; pathId < 4; ++pathId) {
            paths[pathId].pathId = pathId;
        }
    }

    function _swapTransitionPaths(TransitionPath[4] memory paths, uint256 first, uint256 second) private pure {
        address delegatee = paths[first].delegatee;
        uint256 point = paths[first].point;
        uint8 cursor = paths[first].cursor;
        uint8 pathId = paths[first].pathId;
        bool active = paths[first].active;
        paths[first].delegatee = paths[second].delegatee;
        paths[first].point = paths[second].point;
        paths[first].cursor = paths[second].cursor;
        paths[first].pathId = paths[second].pathId;
        paths[first].active = paths[second].active;
        paths[second].delegatee = delegatee;
        paths[second].point = point;
        paths[second].cursor = cursor;
        paths[second].pathId = pathId;
        paths[second].active = active;
    }

    function _siftUpTransitionPaths(TransitionPath[4] memory paths, uint256 index) private pure {
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (!_transitionPathBefore(paths[index], paths[parent])) return;
            _swapTransitionPaths(paths, index, parent);
            index = parent;
        }
    }

    function _siftDownTransitionPaths(TransitionPath[4] memory paths, uint256 heapLength) private pure {
        uint256 index;
        while (index < heapLength / 2) {
            uint256 child = index * 2 + 1;
            uint256 right = child + 1;
            if (right < heapLength && _transitionPathBefore(paths[right], paths[child])) {
                child = right;
            }
            if (!_transitionPathBefore(paths[child], paths[index])) return;
            _swapTransitionPaths(paths, child, index);
            index = child;
        }
    }

    function _transitionPathLength(TransitionPath[4] memory paths, uint8 pathId) private pure returns (uint8 length) {
        for (uint8 descriptor; descriptor < 4; ++descriptor) {
            if (paths[descriptor].pathId == pathId) return paths[descriptor].cursor;
        }
    }

    function _transitionPathBefore(TransitionPath memory first, TransitionPath memory second)
        private
        pure
        returns (bool)
    {
        if (first.delegatee != second.delegatee) return uint160(first.delegatee) < uint160(second.delegatee);
        uint256 firstKey = _transitionTreeIndex(first.point, uint256(first.cursor) + 1);
        uint256 secondKey = _transitionTreeIndex(second.point, uint256(second.cursor) + 1);
        return firstKey < secondKey;
    }

    function _transitionTreeIndex(uint256 point, uint256 depth) private pure returns (uint256) {
        return (uint256(1) << (depth * 10)) | (point >> (50 - depth * 10));
    }

    function _replayTransitionPath(
        TransitionSlot[20] memory slots,
        uint8[5][4] memory pathIds,
        uint8 pathId,
        uint8 pathLength,
        int256 delta
    ) private view {
        for (uint8 cursor; cursor < pathLength; ++cursor) {
            uint8 slotId = pathIds[pathId][cursor];
            if (!slots[slotId].loaded) {
                EligibilityTransitionOverlayStorage storage overlay = _eligibilityTransitionOverlayStorage();
                int256 original = overlay.radixDeltas[slots[slotId].delegatee][slots[slotId].key];
                slots[slotId].original = original;
                slots[slotId].value = original;
                slots[slotId].loaded = true;
            }
            slots[slotId].value += delta;
        }
    }

    function _flushTransitionSlots(TransitionSlot[20] memory slots, uint256 uniqueSlots) private {
        EligibilityTransitionOverlayStorage storage overlay = _eligibilityTransitionOverlayStorage();
        for (uint256 slotId; slotId < uniqueSlots; ++slotId) {
            if (slots[slotId].loaded && slots[slotId].value != slots[slotId].original) {
                overlay.radixDeltas[slots[slotId].delegatee][slots[slotId].key] = slots[slotId].value;
            }
        }
    }

    function _changeIndexedVotes(address delegatee, uint256 removed, uint256 added) private {
        if (delegatee == address(0) || (removed == 0 && added == 0)) return;
        uint256 currentVotes = _eligibleDelegateVotes[delegatee].latest();
        if (currentVotes < removed) {
            revert EligibilityAccountingUnderflow(delegatee, currentVotes, removed);
        }
        uint256 nextVotes = currentVotes - removed + added;
        if (nextVotes > type(uint208).max) revert EligibilityAccountingOverflow(delegatee, nextVotes);
        _eligibleDelegateVotes[delegatee].push(uint48(block.timestamp), uint208(nextVotes));
    }

    function _updateVestingSourceMembership(
        address source,
        address delegatee,
        uint256 votes,
        uint256 maximum,
        bool currentlyRegistered
    ) private {
        address beneficiary = _vestingBeneficiaryBySource[source];
        if (beneficiary == address(0)) return;
        EnumerableSet.AddressSet storage sources = _vestingSourcesByBeneficiary[beneficiary];
        if (currentlyRegistered && delegatee != address(0) && votes != 0) {
            if (!sources.contains(source)) {
                uint256 sourceCount = sources.length();
                if (sourceCount >= maximum) revert TooManyVestingSources(beneficiary, sourceCount, maximum);
                sources.add(source);
            }
        } else {
            sources.remove(source);
        }
    }

    function _writeDelegateSourceCheckpoint(address delegatee, address source, uint256 votes) private {
        _delegateSourceCheckpoints[delegatee][source].push(uint48(block.timestamp), uint208(votes));
    }
}
