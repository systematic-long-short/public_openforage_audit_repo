pragma solidity ^0.8.20;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAllowlist, IAllowlistVestingRegistry, IAllowlistVoteEligibility} from "../interfaces/IAllowlist.sol";
import {IAllowlistSystemRegistrar} from "../interfaces/IAllowlistSystemRegistrar.sol";
import {IBlocklistVoteEligibility} from "../interfaces/IBlocklist.sol";

struct ForageTokenSourceEligibility {
    bool allowlisted;
    bool systemAccount;
    bool blocked;
    uint64 allowedUntil;
    uint256 blockedUntil;
}

struct ForageTokenSourceEligibilityQuery {
    address source;
    address registeredBeneficiary;
    bool registrationKnown;
    address blocklist;
    address allowlist;
    uint48 timepoint;
    address rememberedBeneficiary;
}

interface IForageTokenSourceView {
    function balanceOf(address account) external view returns (uint256);

    function delegates(address account) external view returns (address);

    function allowlist() external view returns (address);

    function blocklist() external view returns (address);

    function clock() external view returns (uint48);

    function sourceEligibilityForBlocklist(
        address source,
        address registeredBeneficiary,
        bool registrationKnown,
        address blocklist,
        address allowlist,
        uint48 timepoint
    ) external view returns (ForageTokenSourceEligibility memory);
}

interface IVestingSourceAllowlist {
    function allowlist() external view returns (address);
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
    address registeredBeneficiary;
}

struct ForageTokenRotationStatus {
    bool inventorySupported;
    bool rotationActive;
    uint256 activeGeneration;
    uint256 pendingGeneration;
    uint256 cursor;
    uint256 inventoryLength;
    uint256 processed;
    uint256 dirty;
    uint256 epochCount;
    address activeBlocklist;
    address pendingBlocklist;
    bool allowlistReindexActive;
    address pendingAllowlist;
}

struct ForageTokenActiveProjection {
    uint256 indexedVotes;
    uint256 generation;
}

struct ForageTokenPastProjection {
    uint256 indexedVotes;
    uint256 generation;
    address blocklist;
    address allowlist;
    bool blocked;
}

struct ForageTokenVoteSyncTarget {
    uint256 generation;
    address blocklist;
    address allowlist;
}

struct ForageTokenVoteSyncTaskContext {
    address provider;
    ForageTokenVoteSyncTarget primary;
    ForageTokenVoteSyncTarget secondary;
    bool hasSecondary;
}

interface IForageTokenQueueSourceSync {
    function syncQueuedSource(address source, uint48 timepoint, uint256 balance) external;

    function registerPendingProjectionSource(address source) external;
}

contract ForageTokenVoteEligibilitySyncReplay {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;

    error DirectCallForbidden();
    error VoteEligibilitySyncPending(uint48 timepoint);
    error VestingSourceRegistrationRequired(address source, address beneficiary);
    error UnsupportedLegacyVestingBeneficiary(address source);
    error InvalidBlocklist(address target);
    error EligibilityAccountingUnderflow(address delegatee, uint256 available, uint256 requested);
    error EligibilityAccountingOverflow(address delegatee, uint256 value);
    error TooManyVestingSources(address beneficiary, uint256 count, uint256 maximum);

    event VoteSourceInventoried(address indexed source, uint256 inventoryLength);

    uint256 private constant MAX_VESTING_SOURCES_PER_PROJECTION = 32;
    uint256[13] private __statePrefix;
    mapping(address => address) private _vestingBeneficiaryBySource;
    mapping(address => EnumerableSet.AddressSet) private _vestingSourcesByBeneficiary;
    uint256[3] private __stateMiddle;
    uint256 private _voteEligibilitySyncCount;
    uint48 private _voteEligibilitySyncTimepoint;

    struct VoteSourceState {
        address delegatee;
        uint208 baseVotes;
        uint48 firstTransitionTime;
        int256 firstTransitionDelta;
        uint48 secondTransitionTime;
        int256 secondTransitionDelta;
    }

    struct ReplayProjection {
        mapping(address => VoteSourceState) sourceStates;
        mapping(address => Checkpoints.Trace208) eligibleVotes;
        mapping(address => mapping(uint256 => int256)) transitionTree;
        mapping(address => bool) processedSources;
        mapping(address => bool) projectedSources;
        mapping(address => bool) legacySources;
        mapping(address => EnumerableSet.AddressSet) vestingSourcesByBeneficiary;
        mapping(address => bool) vestingSourceAllowlistHandoffs;
        uint256 vestingSourceAllowlistHandoffCount;
        mapping(address => address) vestingBeneficiariesBySource;
    }

    struct ProjectionEpoch {
        uint48 startTime;
        uint256 generation;
        address blocklist;
    }

    struct ReplayBlocklistRotationStorage {
        uint256 inventoryVersion;
        address[] sources;
        mapping(address => bool) sourceSeen;
        address pendingBlocklist;
        uint256 activeGeneration;
        uint256 pendingGeneration;
        uint256 cursor;
        uint256 processed;
        uint256 dirty;
        ProjectionEpoch[] epochs;
        mapping(uint256 => ReplayProjection) projections;
        mapping(uint256 => address) generationAllowlists;
        uint256 pendingSnapshotLength;
        uint256 latestGeneration;
        address pendingAllowlist;
        uint256 projectionSchemaVersion;
        mapping(address => bool) pendingVoteEligibilitySyncs;
        mapping(address => uint256) pendingVoteEligibilitySyncCursors;
        uint256 candidateAllowlistPointerCursor;
        uint256 vestingMembershipSchemaVersion;
        uint256 voteEligibilitySyncSchemaVersion;
        uint256 pendingVoteSyncHeadTaskId;
        uint256 pendingVoteSyncTailTaskId;
        mapping(uint256 => uint256) pendingVoteSyncNextTaskIds;
        mapping(uint256 => address) pendingVoteSyncTaskAccounts;
        mapping(uint256 => uint48) pendingVoteSyncTaskTimepoints;
        mapping(uint256 => uint256) pendingVoteSyncTaskCursors;
        mapping(uint256 => bool) pendingVoteSyncTaskTransfers;
        mapping(uint256 => uint256) pendingVoteSyncTaskBeforeBalances;
        mapping(uint256 => uint256) pendingVoteSyncTaskAfterBalances;
        mapping(uint48 => mapping(address => uint256)) pendingVoteSyncObserverTaskIds;
        mapping(address => uint256) pendingVoteTransferHeadTaskIds;
        mapping(address => uint256) pendingVoteTransferTailTaskIds;
        mapping(uint256 => uint256) pendingVoteTransferNextTaskIds;
        mapping(uint256 => address[]) pendingVoteSyncTaskVestingSources;
        mapping(uint256 => address[]) pendingVoteSyncTaskActiveSources;
        mapping(uint256 => address[]) pendingVoteSyncTaskPendingSources;
        mapping(uint256 => uint256) pendingVoteSyncTaskPendingCursors;
        bool pendingProjectionPageIsPointer;
        uint256 pendingProjectionPageEnd;
        uint256 pendingProjectionPageBarrier;
    }

    struct SourceSync {
        address source;
        address newDelegate;
        address registeredBeneficiary;
        uint256 votes;
        bool systemAccount;
        bool registrationPending;
        bool unsupportedRegistration;
        bool relevant;
    }

    struct VoteTransitions {
        uint48 firstTime;
        int256 firstDelta;
        uint48 secondTime;
        int256 secondDelta;
    }

    bytes32 private constant BLOCKLIST_ROTATION_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.ForageTokenStateModule.BlocklistRotation")) - 1)
    ) & ~bytes32(uint256(0xff));

    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    function syncQueuedSource(
        address source,
        uint48 timepoint,
        uint256 balance,
        ForageTokenVoteSyncTarget calldata target
    ) external onlyDelegateCall {
        if (source == address(0)) return;
        ReplayBlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        SourceSync memory sync = _prepareReplaySourceSync(rotation, source, timepoint, balance, target);
        if (!sync.relevant) return;
        ForageTokenStateUpdate memory update = _sourceUpdate(sync, timepoint, target);
        _applyProjectionSourceUpdate(rotation, target.generation, update, timepoint);
        _updateProjectionVestingSourceMembership(
            rotation, target.generation, source, sync.registeredBeneficiary, target.allowlist
        );
    }

    function _prepareReplaySourceSync(
        ReplayBlocklistRotationStorage storage rotation,
        address source,
        uint48 timepoint,
        uint256 balance,
        ForageTokenVoteSyncTarget calldata target
    ) private returns (SourceSync memory sync) {
        if (target.allowlist == address(0)) revert IAllowlist.AllowlistUnavailable();
        sync.source = source;
        sync.newDelegate = IForageTokenSourceView(address(this)).delegates(source);
        sync.votes = sync.newDelegate == address(0) ? 0 : balance;
        try IAllowlistVoteEligibility(target.allowlist).eligibilityStateAt(source, timepoint) returns (
            uint64, bool systemAccount
        ) {
            sync.systemAccount = systemAccount;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        (sync.registeredBeneficiary, sync.registrationPending, sync.unsupportedRegistration) =
            _historicalRegistration(target.allowlist, source, timepoint);
        if (sync.registeredBeneficiary != address(0) && !sync.systemAccount) {
            revert VestingSourceRegistrationRequired(source, sync.registeredBeneficiary);
        }
        ReplayProjection storage projection = rotation.projections[target.generation];
        sync.relevant = sync.newDelegate != address(0) || rotation.sourceSeen[source]
            || projection.sourceStates[source].delegatee != address(0) || projection.processedSources[source]
            || projection.vestingBeneficiariesBySource[source] != address(0) || sync.registeredBeneficiary != address(0);
        if (!sync.relevant) return sync;
        if (sync.newDelegate != address(0) && sync.votes != 0) {
            if (sync.registrationPending) revert VestingSourceRegistrationRequired(source, sync.registeredBeneficiary);
            if (sync.systemAccount && sync.unsupportedRegistration) {
                revert UnsupportedLegacyVestingBeneficiary(source);
            }
        }
        if (!rotation.sourceSeen[source]) {
            rotation.sourceSeen[source] = true;
            rotation.sources.push(source);
            emit VoteSourceInventoried(source, rotation.sources.length);
        }
    }

    function _historicalRegistration(address allowlist_, address source, uint48 timepoint)
        private
        view
        returns (address beneficiary, bool registrationPending, bool unsupportedBeneficiary)
    {
        try IAllowlistVestingRegistry(allowlist_).vestingSourceRegistrationAt(source, timepoint) returns (
            address registered, bool pending, bool unsupported
        ) {
            return (registered, pending, unsupported);
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _sourceUpdate(SourceSync memory sync, uint48 timepoint, ForageTokenVoteSyncTarget calldata target)
        private
        returns (ForageTokenStateUpdate memory update)
    {
        update.source = sync.source;
        update.newDelegate = sync.newDelegate;
        update.votes = sync.votes;
        update.registeredBeneficiary = sync.registeredBeneficiary;
        if (sync.newDelegate == address(0) || sync.votes == 0) return update;
        address remembered = _vestingBeneficiaryBySource[sync.source];
        _vestingBeneficiaryBySource[sync.source] = sync.registeredBeneficiary;
        ForageTokenSourceEligibility memory eligibility = IForageTokenSourceView(address(this))
            .sourceEligibilityForBlocklist(
            sync.source,
            sync.registeredBeneficiary,
            sync.registeredBeneficiary != address(0),
            target.blocklist,
            target.allowlist,
            timepoint
        );
        _vestingBeneficiaryBySource[sync.source] = remembered;
        eligibility.allowlisted = eligibility.systemAccount || eligibility.allowedUntil >= timepoint;
        eligibility.blocked = eligibility.blockedUntil != 0 && eligibility.blockedUntil >= timepoint;
        if (eligibility.allowlisted && !eligibility.blocked) update.newBaseVotes = sync.votes;
        VoteTransitions memory transitions = _planVoteTransitions(eligibility, sync.votes, timepoint);
        update.firstTransitionTime = transitions.firstTime;
        update.firstTransitionDelta = transitions.firstDelta;
        update.secondTransitionTime = transitions.secondTime;
        update.secondTransitionDelta = transitions.secondDelta;
    }

    function _planVoteTransitions(ForageTokenSourceEligibility memory eligibility, uint256 votes, uint48 timepoint)
        private
        pure
        returns (VoteTransitions memory transitions)
    {
        if (votes == 0 || !eligibility.allowlisted) return transitions;
        int256 signedVotes = int256(votes);
        uint256 maximum = uint256(type(uint48).max);
        if (!eligibility.blocked) {
            if (!eligibility.systemAccount && eligibility.allowedUntil >= timepoint) {
                uint256 expiry = eligibility.allowedUntil;
                if (expiry < maximum) {
                    transitions.firstTime = uint48(expiry + 1);
                    transitions.firstDelta = signedVotes;
                }
            }
            return transitions;
        }
        uint256 blockedUntil = eligibility.blockedUntil;
        if (blockedUntil >= timepoint && blockedUntil < maximum) {
            if (eligibility.systemAccount || uint256(eligibility.allowedUntil) > blockedUntil) {
                transitions.firstTime = uint48(blockedUntil + 1);
                transitions.firstDelta = -signedVotes;
            }
        }
        if (
            !eligibility.systemAccount && eligibility.allowedUntil >= timepoint
                && uint256(eligibility.allowedUntil) < maximum && blockedUntil < eligibility.allowedUntil
        ) {
            transitions.secondTime = uint48(uint256(eligibility.allowedUntil) + 1);
            transitions.secondDelta = signedVotes;
        }
    }

    function _applyProjectionSourceUpdate(
        ReplayBlocklistRotationStorage storage rotation,
        uint256 generation,
        ForageTokenStateUpdate memory update,
        uint48 timepoint
    ) private {
        ReplayProjection storage projection = rotation.projections[generation];
        bool pending = rotation.pendingGeneration != 0 && generation == rotation.pendingGeneration;
        if (!projection.processedSources[update.source]) {
            projection.processedSources[update.source] = true;
            if (pending) ++rotation.processed;
        }
        projection.projectedSources[update.source] = true;
        if (pending) ++rotation.dirty;
        _syncProjectionSource(projection, update, timepoint);
        if (pending) --rotation.dirty;
    }

    function _updateProjectionVestingSourceMembership(
        ReplayBlocklistRotationStorage storage rotation,
        uint256 generation,
        address source,
        address beneficiary,
        address allowlist_
    ) private {
        ReplayProjection storage projection = rotation.projections[generation];
        address previous = projection.vestingBeneficiariesBySource[source];
        if (previous == beneficiary) return;
        if (previous != address(0)) {
            projection.vestingSourcesByBeneficiary[previous].remove(source);
            delete projection.vestingBeneficiariesBySource[source];
            _updateVestingSourceUnion(rotation, source, previous);
        }
        if (beneficiary == address(0)) return;
        EnumerableSet.AddressSet storage sources = projection.vestingSourcesByBeneficiary[beneficiary];
        if (!sources.contains(source)) {
            uint256 maximum = _maxVestingSources(allowlist_);
            uint256 count = sources.length();
            if (count >= maximum) revert TooManyVestingSources(beneficiary, count, maximum);
            sources.add(source);
        }
        projection.vestingBeneficiariesBySource[source] = beneficiary;
        _updateVestingSourceUnion(rotation, source, beneficiary);
    }

    function _updateVestingSourceUnion(
        ReplayBlocklistRotationStorage storage rotation,
        address source,
        address beneficiary
    ) private {
        bool registered =
            rotation.projections[rotation.activeGeneration].vestingSourcesByBeneficiary[beneficiary].contains(source);
        if (rotation.pendingGeneration != 0) {
            registered = registered
                || rotation.projections[rotation.pendingGeneration].vestingSourcesByBeneficiary[beneficiary].contains(
                    source
                );
        }
        EnumerableSet.AddressSet storage sources = _vestingSourcesByBeneficiary[beneficiary];
        if (registered) sources.add(source);
        else sources.remove(source);
    }

    function _maxVestingSources(address allowlist_) private view returns (uint256 maximum) {
        try IAllowlistVestingRegistry(allowlist_).maxVestingSourcesPerBeneficiary() returns (uint256 value) {
            maximum = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _syncProjectionSource(
        ReplayProjection storage projection,
        ForageTokenStateUpdate memory update,
        uint48 timepoint
    ) private {
        VoteSourceState storage state = projection.sourceStates[update.source];
        address oldDelegate = state.delegatee;
        if (oldDelegate != address(0)) {
            _adjustProjectionTransition(
                projection, oldDelegate, state.firstTransitionTime, state.firstTransitionDelta, timepoint, false
            );
            _adjustProjectionTransition(
                projection, oldDelegate, state.secondTransitionTime, state.secondTransitionDelta, timepoint, false
            );
            if (oldDelegate == update.newDelegate) {
                _changeProjectionVotes(projection, update.newDelegate, state.baseVotes, update.newBaseVotes, timepoint);
            } else {
                _changeProjectionVotes(projection, oldDelegate, state.baseVotes, 0, timepoint);
                _changeProjectionVotes(projection, update.newDelegate, 0, update.newBaseVotes, timepoint);
            }
        } else {
            _changeProjectionVotes(projection, update.newDelegate, 0, update.newBaseVotes, timepoint);
        }
        state.delegatee = update.newDelegate;
        state.baseVotes = uint208(update.newBaseVotes);
        state.firstTransitionTime = update.firstTransitionTime;
        state.firstTransitionDelta = update.firstTransitionDelta;
        state.secondTransitionTime = update.secondTransitionTime;
        state.secondTransitionDelta = update.secondTransitionDelta;
        _adjustProjectionTransition(
            projection, update.newDelegate, update.firstTransitionTime, update.firstTransitionDelta, timepoint, true
        );
        _adjustProjectionTransition(
            projection, update.newDelegate, update.secondTransitionTime, update.secondTransitionDelta, timepoint, true
        );
    }

    function _adjustProjectionTransition(
        ReplayProjection storage projection,
        address delegatee,
        uint48 transitionTime,
        int256 delta,
        uint48 timepoint,
        bool adding
    ) private {
        if (transitionTime == 0 || delta == 0) return;
        uint48 effectiveTime = adding || transitionTime > timepoint ? transitionTime : timepoint;
        _projectionFenwickUpdate(projection, delegatee, effectiveTime, adding ? delta : -delta);
    }

    function _projectionFenwickUpdate(
        ReplayProjection storage projection,
        address delegatee,
        uint48 timepoint,
        int256 delta
    ) private {
        uint256 maximum = uint256(1) << 48;
        uint256 index = uint256(timepoint) + 1;
        while (index <= maximum) {
            projection.transitionTree[delegatee][index] += delta;
            uint256 step = index & (~index + 1);
            if (index > maximum - step) break;
            index += step;
        }
    }

    function _changeProjectionVotes(
        ReplayProjection storage projection,
        address delegatee,
        uint256 removed,
        uint256 added,
        uint48 timepoint
    ) private {
        if (delegatee == address(0) || (removed == 0 && added == 0)) return;
        uint256 currentVotes = projection.eligibleVotes[delegatee].latest();
        if (currentVotes < removed) revert EligibilityAccountingUnderflow(delegatee, currentVotes, removed);
        uint256 nextVotes = currentVotes - removed + added;
        if (nextVotes > type(uint208).max) revert EligibilityAccountingOverflow(delegatee, nextVotes);
        projection.eligibleVotes[delegatee].push(timepoint, uint208(nextVotes));
    }

    function _blocklistRotationStorage() private pure returns (ReplayBlocklistRotationStorage storage layout) {
        bytes32 slot = BLOCKLIST_ROTATION_SLOT;
        assembly ("memory-safe") {
            layout.slot := slot
        }
    }
}

contract ForageTokenVoteEligibilitySyncQueue {
    using EnumerableSet for EnumerableSet.AddressSet;

    error DirectCallForbidden();
    error VoteEligibilitySyncPending(uint48 timepoint);
    error NoPendingVoteEligibilitySync(address account);
    error TooManyVestingSources(address beneficiary, uint256 count, uint256 maximum);

    event VoteEligibilitySyncQueued(address indexed account, uint48 timepoint, uint256 pendingCount);
    event VoteEligibilitySyncProgress(address indexed account, uint256 remainingSources, bool complete);

    uint256 private constant MAX_VESTING_SOURCES_PER_PROJECTION = 32;
    uint256 private constant BLOCKLIST_ROTATION_PAGE_SIZE = 8;

    uint256[14] private __statePrefix;
    mapping(address => EnumerableSet.AddressSet) private _vestingSourcesByBeneficiary;
    uint256[3] private __stateMiddle;
    uint256 private _voteEligibilitySyncCount;
    uint48 private _voteEligibilitySyncTimepoint;

    struct QueueProjection {
        mapping(address => bytes32) sourceStates;
        mapping(address => bytes32) eligibleVotes;
        mapping(address => mapping(uint256 => int256)) transitionTree;
        mapping(address => bool) processedSources;
        mapping(address => bool) projectedSources;
        mapping(address => bool) legacySources;
        mapping(address => EnumerableSet.AddressSet) vestingSourcesByBeneficiary;
        mapping(address => bool) vestingSourceAllowlistHandoffs;
        uint256 vestingSourceAllowlistHandoffCount;
        mapping(address => address) vestingBeneficiariesBySource;
    }

    struct BlocklistRotationStorage {
        uint256 inventoryVersion;
        address[] sources;
        mapping(address => bool) sourceSeen;
        address pendingBlocklist;
        uint256 activeGeneration;
        uint256 pendingGeneration;
        uint256 cursor;
        uint256 processed;
        uint256 dirty;
        bytes32[] epochs;
        mapping(uint256 => QueueProjection) projections;
        mapping(uint256 => address) generationAllowlists;
        uint256 pendingSnapshotLength;
        uint256 latestGeneration;
        address pendingAllowlist;
        uint256 projectionSchemaVersion;
        mapping(address => bool) pendingVoteEligibilitySyncs;
        mapping(address => uint256) pendingVoteEligibilitySyncCursors;
        uint256 candidateAllowlistPointerCursor;
        uint256 vestingMembershipSchemaVersion;
        uint256 voteEligibilitySyncSchemaVersion;
        uint256 pendingVoteSyncHeadTaskId;
        uint256 pendingVoteSyncTailTaskId;
        mapping(uint256 => uint256) pendingVoteSyncNextTaskIds;
        mapping(uint256 => address) pendingVoteSyncTaskAccounts;
        mapping(uint256 => uint48) pendingVoteSyncTaskTimepoints;
        mapping(uint256 => uint256) pendingVoteSyncTaskCursors;
        mapping(uint256 => bool) pendingVoteSyncTaskTransfers;
        mapping(uint256 => uint256) pendingVoteSyncTaskBeforeBalances;
        mapping(uint256 => uint256) pendingVoteSyncTaskAfterBalances;
        mapping(uint48 => mapping(address => uint256)) pendingVoteSyncObserverTaskIds;
        mapping(address => uint256) pendingVoteTransferHeadTaskIds;
        mapping(address => uint256) pendingVoteTransferTailTaskIds;
        mapping(uint256 => uint256) pendingVoteTransferNextTaskIds;
        mapping(uint256 => address[]) pendingVoteSyncTaskVestingSources;
        mapping(uint256 => address[]) pendingVoteSyncTaskActiveSources;
        mapping(uint256 => address[]) pendingVoteSyncTaskPendingSources;
        mapping(uint256 => uint256) pendingVoteSyncTaskPendingCursors;
        bool pendingProjectionPageIsPointer;
        uint256 pendingProjectionPageEnd;
        uint256 pendingProjectionPageBarrier;
    }

    bytes32 private constant BLOCKLIST_ROTATION_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.ForageTokenStateModule.BlocklistRotation")) - 1)
    ) & ~bytes32(uint256(0xff));

    address private immutable _SELF;
    ForageTokenVoteEligibilitySyncReplay private immutable _REPLAY_MODULE;

    constructor() {
        _SELF = address(this);
        _REPLAY_MODULE = new ForageTokenVoteEligibilitySyncReplay();
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    function queueObserver(address account, uint48 timepoint) external onlyDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        _queueObserver(state, account, timepoint, _observerContext(state, msg.sender));
    }

    function processRotationPage(address stateModule) external onlyDelegateCall returns (bool ready) {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (!_completeProjectionPage(state)) return false;
        uint256 snapshot = state.pendingSnapshotLength;
        if (state.cursor > snapshot) {
            revert BlocklistRotationIncomplete(state.cursor, snapshot, state.processed, state.dirty);
        }
        uint256 remaining = snapshot - state.cursor;
        uint256 length = remaining > BLOCKLIST_ROTATION_PAGE_SIZE ? BLOCKLIST_ROTATION_PAGE_SIZE : remaining;
        _queueProjectionPage(
            stateModule,
            state,
            state.cursor,
            state.cursor + length,
            IForageTokenSourceView(address(this)).clock(),
            false
        );
        return true;
    }

    function processAllowlistPage(address stateModule)
        external
        onlyDelegateCall
        returns (bool ready, uint256 progress)
    {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (!_completeProjectionPage(state)) return (false, state.cursor);
        if (state.cursor < state.pendingSnapshotLength) {
            uint256 remaining = state.pendingSnapshotLength - state.cursor;
            uint256 length = remaining > BLOCKLIST_ROTATION_PAGE_SIZE ? BLOCKLIST_ROTATION_PAGE_SIZE : remaining;
            _queueProjectionPage(
                stateModule,
                state,
                state.cursor,
                state.cursor + length,
                IForageTokenSourceView(address(this)).clock(),
                false
            );
            return (true, state.cursor);
        }
        uint256 total = state.sources.length;
        uint256 start = state.candidateAllowlistPointerCursor;
        QueueProjection storage candidate = state.projections[state.pendingGeneration];
        if (start >= total) {
            if (candidate.vestingSourceAllowlistHandoffCount == 0) {
                _queueProjectionPage(
                    stateModule, state, start, start, IForageTokenSourceView(address(this)).clock(), true
                );
                return (true, start);
            }
            start = 0;
        }
        uint256 remaining = total - start;
        uint256 length = remaining > BLOCKLIST_ROTATION_PAGE_SIZE ? BLOCKLIST_ROTATION_PAGE_SIZE : remaining;
        _queueProjectionPage(
            stateModule, state, start, start + length, IForageTokenSourceView(address(this)).clock(), true
        );
        return (true, state.candidateAllowlistPointerCursor);
    }

    function ensureProjectionComplete() external onlyDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingProjectionPageBarrier == 0 || !_completeProjectionPage(state)) {
            revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
        }
    }

    function _completeProjectionPage(BlocklistRotationStorage storage state) private returns (bool) {
        uint256 barrierPlusOne = state.pendingProjectionPageBarrier;
        uint256 head = state.pendingVoteSyncHeadTaskId;
        if (state.pendingProjectionPageEnd == 0 && barrierPlusOne == 0) return true;
        uint256 barrier = barrierPlusOne - 1;
        if (head != 0 && head <= barrier) return false;
        uint256 end = state.pendingProjectionPageEnd;
        if (end != 0) {
            if (state.pendingProjectionPageIsPointer) {
                state.candidateAllowlistPointerCursor = end;
            } else {
                state.cursor = end;
            }
        }
        state.pendingProjectionPageEnd = 0;
        state.pendingProjectionPageBarrier = 0;
        return true;
    }

    function _queueProjectionPage(
        address stateModule,
        BlocklistRotationStorage storage state,
        uint256 start,
        uint256 end,
        uint48 timepoint,
        bool pointerPage
    ) private {
        if (start == end) {
            state.pendingProjectionPageBarrier = state.pendingVoteSyncTailTaskId + 1;
            return;
        }
        while (start < end) {
            address source = state.sources[start];
            _registerPendingProjectionSourceThroughModule(stateModule, source);
            _queueObserver(state, source, timepoint);
            ++start;
        }
        state.pendingProjectionPageIsPointer = pointerPage;
        state.pendingProjectionPageEnd = end;
        state.pendingProjectionPageBarrier = state.pendingVoteSyncTailTaskId + 1;
    }

    error BlocklistRotationIncomplete(uint256 cursor, uint256 snapshot, uint256 processed, uint256 dirty);

    function _queueObserver(BlocklistRotationStorage storage state, address account, uint48 timepoint) private {
        _queueObserver(state, account, timepoint, _pageContext(state));
    }

    function _queueObserver(
        BlocklistRotationStorage storage state,
        address account,
        uint48 timepoint,
        ForageTokenVoteSyncTaskContext memory context
    ) private {
        uint256 taskId = state.pendingVoteSyncObserverTaskIds[timepoint][account];
        if (taskId != 0 && _sameContext(_storedTaskContext(state, taskId), context)) {
            delete state.pendingVoteSyncTaskActiveSources[taskId];
            delete state.pendingVoteSyncTaskPendingSources[taskId];
            state.pendingVoteSyncTaskCursors[taskId] = type(uint256).max;
            state.pendingVoteSyncTaskPendingCursors[taskId] = type(uint256).max;
            emit VoteEligibilitySyncQueued(account, timepoint, _voteEligibilitySyncCount);
            return;
        }
        taskId = _appendTask(state, account, timepoint, false, context);
        state.pendingVoteSyncObserverTaskIds[timepoint][account] = taskId;
        state.pendingVoteSyncTaskCursors[taskId] = type(uint256).max;
        state.pendingVoteSyncTaskPendingCursors[taskId] = type(uint256).max;
    }

    function _observerContext(BlocklistRotationStorage storage state, address provider)
        private
        view
        returns (ForageTokenVoteSyncTaskContext memory context)
    {
        context.provider = provider;
        context.primary = _activeTarget(state);
        if (state.pendingGeneration == 0) return context;
        ForageTokenVoteSyncTarget memory pending = _pendingTarget(state);
        bool sharedBlocklist = provider == context.primary.blocklist && provider == pending.blocklist;
        bool sharedAllowlist = provider == context.primary.allowlist && provider == pending.allowlist;
        if (sharedBlocklist || sharedAllowlist) {
            context.secondary = pending;
            context.hasSecondary = true;
        } else if (provider == pending.blocklist || provider == pending.allowlist) {
            context.primary = pending;
        }
    }

    function _pageContext(BlocklistRotationStorage storage state)
        private
        view
        returns (ForageTokenVoteSyncTaskContext memory context)
    {
        context.primary = _pendingTarget(state);
    }

    function _activeTarget(BlocklistRotationStorage storage state)
        private
        view
        returns (ForageTokenVoteSyncTarget memory target)
    {
        IForageTokenSourceView token = IForageTokenSourceView(address(this));
        target.generation = state.activeGeneration;
        target.blocklist = token.blocklist();
        target.allowlist = state.generationAllowlists[state.activeGeneration];
        if (target.allowlist == address(0)) target.allowlist = token.allowlist();
    }

    function _pendingTarget(BlocklistRotationStorage storage state)
        private
        view
        returns (ForageTokenVoteSyncTarget memory target)
    {
        target.generation = state.pendingGeneration;
        target.blocklist = state.pendingBlocklist;
        target.allowlist = state.pendingAllowlist;
        if (target.allowlist == address(0)) target.allowlist = IForageTokenSourceView(address(this)).allowlist();
    }

    function _sameContext(ForageTokenVoteSyncTaskContext memory stored, ForageTokenVoteSyncTaskContext memory incoming)
        private
        pure
        returns (bool)
    {
        return stored.provider == incoming.provider && stored.hasSecondary == incoming.hasSecondary
            && _sameTarget(stored.primary, incoming.primary)
            && (!stored.hasSecondary || _sameTarget(stored.secondary, incoming.secondary));
    }

    function _sameTarget(ForageTokenVoteSyncTarget memory stored, ForageTokenVoteSyncTarget memory incoming)
        private
        pure
        returns (bool)
    {
        return stored.generation == incoming.generation && stored.blocklist == incoming.blocklist
            && stored.allowlist == incoming.allowlist;
    }

    function _registerPendingProjectionSourceThroughModule(address stateModule, address source) private {
        _delegateToStateModule(
            stateModule, abi.encodeCall(IForageTokenQueueSourceSync.registerPendingProjectionSource, (source))
        );
    }

    function queueTransfer(address from, address to, uint256 amount, uint48 timepoint) external onlyDelegateCall {
        if (amount == 0 || from == to) return;
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (from != address(0) && _endpointCanChangeVotes(state, from)) {
            _queueTransferEndpoint(from, from, to, amount, timepoint);
        }
        if (to != address(0) && _endpointCanChangeVotes(state, to)) {
            _queueTransferEndpoint(to, from, to, amount, timepoint);
        }
    }

    function _endpointCanChangeVotes(BlocklistRotationStorage storage state, address source)
        private
        view
        returns (bool)
    {
        if (state.pendingVoteTransferHeadTaskIds[source] != 0) return true;
        QueueProjection storage active = state.projections[state.activeGeneration];
        if (active.sourceStates[source] != bytes32(0)) return true;
        uint256 pendingGeneration = state.pendingGeneration;
        if (pendingGeneration != 0) {
            QueueProjection storage pending = state.projections[pendingGeneration];
            if (pending.sourceStates[source] != bytes32(0)) return true;
        }
        return IForageTokenSourceView(address(this)).delegates(source) != address(0);
    }

    function process(address, address account) external onlyDelegateCall returns (bool complete) {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        uint256 taskId = state.pendingVoteSyncHeadTaskId;
        if (taskId == 0) revert NoPendingVoteEligibilitySync(account);
        if (state.pendingVoteSyncTaskAccounts[taskId] != account) {
            revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
        }
        uint48 timepoint = state.pendingVoteSyncTaskTimepoints[taskId];
        ForageTokenVoteSyncTaskContext memory context = _storedTaskContext(state, taskId);
        if (state.pendingVoteSyncTaskTransfers[taskId]) {
            return _processTransfer(state, taskId, account, timepoint, context);
        }
        return _processObserver(state, taskId, account, timepoint, context);
    }

    function _processObserver(
        BlocklistRotationStorage storage state,
        uint256 taskId,
        address account,
        uint48 timepoint,
        ForageTokenVoteSyncTaskContext memory context
    ) private returns (bool complete) {
        uint256 activeCursor = state.pendingVoteSyncTaskCursors[taskId];
        uint256 pendingCursor = state.pendingVoteSyncTaskPendingCursors[taskId];
        bool snapshotPending = activeCursor == type(uint256).max;
        if (snapshotPending != (pendingCursor == type(uint256).max)) {
            revert VoteEligibilitySyncPending(timepoint);
        }
        if (snapshotPending) {
            uint256 balance = _balanceAtTimepoint(state, account, timepoint);
            _syncQueuedSourceThroughReplay(account, timepoint, balance, context.primary);
            if (context.hasSecondary) {
                _syncQueuedSourceThroughReplay(account, timepoint, balance, context.secondary);
            }
            activeCursor = _snapshotProjectionSources(
                state.projections[context.primary.generation].vestingSourcesByBeneficiary[account],
                account,
                state.pendingVoteSyncTaskActiveSources[taskId]
            );
            pendingCursor = context.hasSecondary
                ? _snapshotProjectionSources(
                    state.projections[context.secondary.generation].vestingSourcesByBeneficiary[account],
                    account,
                    state.pendingVoteSyncTaskPendingSources[taskId]
                )
                : 0;
        } else if (activeCursor != 0) {
            activeCursor = _processVestingSource(
                state, timepoint, state.pendingVoteSyncTaskActiveSources[taskId], activeCursor, context.primary
            );
        } else if (pendingCursor != 0) {
            pendingCursor = _processVestingSource(
                state, timepoint, state.pendingVoteSyncTaskPendingSources[taskId], pendingCursor, context.secondary
            );
        }
        complete = activeCursor == 0 && pendingCursor == 0;
        if (complete) {
            _removeTask(state, taskId);
        } else {
            state.pendingVoteSyncTaskCursors[taskId] = activeCursor;
            state.pendingVoteSyncTaskPendingCursors[taskId] = pendingCursor;
        }
        emit VoteEligibilitySyncProgress(account, activeCursor + pendingCursor, complete);
    }

    function _snapshotProjectionSources(
        EnumerableSet.AddressSet storage sources,
        address beneficiary,
        address[] storage taskSources
    ) private returns (uint256 sourceCount) {
        sourceCount = sources.length();
        if (sourceCount > MAX_VESTING_SOURCES_PER_PROJECTION) {
            revert TooManyVestingSources(beneficiary, sourceCount, MAX_VESTING_SOURCES_PER_PROJECTION);
        }
        for (uint256 index; index < sourceCount; ++index) {
            taskSources.push(sources.at(index));
        }
    }

    function _processVestingSource(
        BlocklistRotationStorage storage state,
        uint48 timepoint,
        address[] storage sources,
        uint256 cursor,
        ForageTokenVoteSyncTarget memory target
    ) private returns (uint256) {
        if (cursor > sources.length) cursor = sources.length;
        if (cursor == 0) return 0;
        address source = sources[cursor - 1];
        _syncQueuedSourceThroughReplay(source, timepoint, _balanceAtTimepoint(state, source, timepoint), target);
        return cursor - 1;
    }

    function _processTransfer(
        BlocklistRotationStorage storage state,
        uint256 taskId,
        address account,
        uint48 timepoint,
        ForageTokenVoteSyncTaskContext memory context
    ) private returns (bool) {
        uint256 balance = state.pendingVoteSyncTaskAfterBalances[taskId];
        _syncQueuedSourceThroughReplay(account, timepoint, balance, context.primary);
        if (context.hasSecondary) _syncQueuedSourceThroughReplay(account, timepoint, balance, context.secondary);
        _removeTransferSnapshot(state, account, taskId);
        _removeTask(state, taskId);
        emit VoteEligibilitySyncProgress(account, 0, true);
        return true;
    }

    function _balanceAtTimepoint(BlocklistRotationStorage storage state, address source, uint48 timepoint)
        private
        view
        returns (uint256)
    {
        uint256 taskId = state.pendingVoteTransferHeadTaskIds[source];
        if (taskId == 0) return IForageTokenSourceView(address(this)).balanceOf(source);
        uint48 transferTimepoint = state.pendingVoteSyncTaskTimepoints[taskId];
        if (transferTimepoint == timepoint) return state.pendingVoteSyncTaskAfterBalances[taskId];
        if (transferTimepoint > timepoint) return state.pendingVoteSyncTaskBeforeBalances[taskId];
        revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
    }

    function _queueTransferEndpoint(address source, address from, address to, uint256 amount, uint48 timepoint)
        private
    {
        if (source == address(0)) return;
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        uint256 balance = IForageTokenSourceView(address(this)).balanceOf(source);
        uint256 previousBalance = _previousBalance(source, from, to, amount, balance);
        uint256 tailTask = state.pendingVoteTransferTailTaskIds[source];
        ForageTokenVoteSyncTaskContext memory context = _transferContext(state);
        if (
            tailTask != 0 && state.pendingVoteSyncTaskTimepoints[tailTask] == timepoint
                && _sameContext(_storedTaskContext(state, tailTask), context)
        ) {
            state.pendingVoteSyncTaskAfterBalances[tailTask] = balance;
            emit VoteEligibilitySyncQueued(source, timepoint, _voteEligibilitySyncCount);
            return;
        }
        uint256 taskId = _appendTask(state, source, timepoint, true, context);
        state.pendingVoteSyncTaskBeforeBalances[taskId] = previousBalance;
        state.pendingVoteSyncTaskAfterBalances[taskId] = balance;
        if (tailTask == 0) {
            state.pendingVoteTransferHeadTaskIds[source] = taskId;
        } else {
            if (timepoint < state.pendingVoteSyncTaskTimepoints[tailTask]) {
                revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
            }
            state.pendingVoteTransferNextTaskIds[tailTask] = taskId;
        }
        state.pendingVoteTransferTailTaskIds[source] = taskId;
    }

    function _transferContext(BlocklistRotationStorage storage state)
        private
        view
        returns (ForageTokenVoteSyncTaskContext memory context)
    {
        context.primary = _activeTarget(state);
        if (state.pendingGeneration != 0) {
            context.secondary = _pendingTarget(state);
            context.hasSecondary = true;
        }
    }

    function _previousBalance(address source, address from, address to, uint256 amount, uint256 balance)
        private
        pure
        returns (uint256)
    {
        if (from == to) return balance;
        return source == from ? balance + amount : balance - amount;
    }

    function _appendTask(
        BlocklistRotationStorage storage state,
        address account,
        uint48 timepoint,
        bool transfer,
        ForageTokenVoteSyncTaskContext memory context
    ) private returns (uint256 taskId) {
        uint256 tailTask = state.pendingVoteSyncTailTaskId;
        taskId = tailTask + 1;
        if (state.pendingVoteSyncHeadTaskId == 0) {
            state.pendingVoteSyncHeadTaskId = taskId;
            _voteEligibilitySyncTimepoint = timepoint;
        } else {
            if (timepoint < state.pendingVoteSyncTaskTimepoints[tailTask]) {
                revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
            }
            state.pendingVoteSyncNextTaskIds[tailTask] = taskId;
        }
        state.pendingVoteSyncTailTaskId = taskId;
        state.pendingVoteSyncTaskAccounts[taskId] = account;
        state.pendingVoteSyncTaskTimepoints[taskId] = timepoint;
        state.pendingVoteSyncTaskTransfers[taskId] = transfer;
        _storeTaskContext(state, taskId, context);
        ++_voteEligibilitySyncCount;
        emit VoteEligibilitySyncQueued(account, timepoint, _voteEligibilitySyncCount);
    }

    function _removeTransferSnapshot(BlocklistRotationStorage storage state, address source, uint256 taskId) private {
        if (state.pendingVoteTransferHeadTaskIds[source] != taskId) {
            revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
        }
        uint256 nextTask = state.pendingVoteTransferNextTaskIds[taskId];
        if (nextTask == 0) {
            state.pendingVoteTransferHeadTaskIds[source] = 0;
            state.pendingVoteTransferTailTaskIds[source] = 0;
        } else {
            state.pendingVoteTransferHeadTaskIds[source] = nextTask;
        }
        delete state.pendingVoteTransferNextTaskIds[taskId];
    }

    function _removeTask(BlocklistRotationStorage storage state, uint256 taskId) private {
        address account = state.pendingVoteSyncTaskAccounts[taskId];
        uint48 timepoint = state.pendingVoteSyncTaskTimepoints[taskId];
        bool transfer = state.pendingVoteSyncTaskTransfers[taskId];
        if (!transfer && state.pendingVoteSyncObserverTaskIds[timepoint][account] == taskId) {
            delete state.pendingVoteSyncObserverTaskIds[timepoint][account];
        }
        --_voteEligibilitySyncCount;
        uint256 nextTask = state.pendingVoteSyncNextTaskIds[taskId];
        if (_voteEligibilitySyncCount == 0) {
            state.pendingVoteSyncHeadTaskId = 0;
            _voteEligibilitySyncTimepoint = 0;
        } else {
            if (nextTask == 0) revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
            state.pendingVoteSyncHeadTaskId = nextTask;
            _voteEligibilitySyncTimepoint = state.pendingVoteSyncTaskTimepoints[nextTask];
        }
        delete state.pendingVoteSyncNextTaskIds[taskId];
        delete state.pendingVoteSyncTaskAccounts[taskId];
        delete state.pendingVoteSyncTaskTimepoints[taskId];
        delete state.pendingVoteSyncTaskCursors[taskId];
        delete state.pendingVoteSyncTaskPendingCursors[taskId];
        delete state.pendingVoteSyncTaskTransfers[taskId];
        delete state.pendingVoteSyncTaskBeforeBalances[taskId];
        delete state.pendingVoteSyncTaskAfterBalances[taskId];
        delete state.pendingVoteSyncTaskVestingSources[taskId];
        delete state.pendingVoteSyncTaskActiveSources[taskId];
        delete state.pendingVoteSyncTaskPendingSources[taskId];
    }

    function _storeTaskContext(
        BlocklistRotationStorage storage state,
        uint256 taskId,
        ForageTokenVoteSyncTaskContext memory context
    ) private {
        address[] storage encoded = state.pendingVoteSyncTaskVestingSources[taskId];
        delete state.pendingVoteSyncTaskVestingSources[taskId];
        encoded.push(context.provider);
        _storeTarget(encoded, context.primary);
        if (context.hasSecondary) _storeTarget(encoded, context.secondary);
    }

    function _storeTarget(address[] storage encoded, ForageTokenVoteSyncTarget memory target) private {
        encoded.push(address(uint160(target.generation >> 128)));
        encoded.push(address(uint160(target.generation)));
        encoded.push(target.blocklist);
        encoded.push(target.allowlist);
    }

    function _storedTaskContext(BlocklistRotationStorage storage state, uint256 taskId)
        private
        view
        returns (ForageTokenVoteSyncTaskContext memory context)
    {
        address[] storage encoded = state.pendingVoteSyncTaskVestingSources[taskId];
        if (encoded.length != 5 && encoded.length != 9) {
            revert VoteEligibilitySyncPending(state.pendingVoteSyncTaskTimepoints[taskId]);
        }
        context.provider = encoded[0];
        context.primary = _storedTarget(encoded, 1);
        context.hasSecondary = encoded.length == 9;
        if (context.hasSecondary) context.secondary = _storedTarget(encoded, 5);
    }

    function _storedTarget(address[] storage encoded, uint256 offset)
        private
        view
        returns (ForageTokenVoteSyncTarget memory target)
    {
        target.generation = (uint256(uint160(encoded[offset])) << 128) | uint256(uint128(uint160(encoded[offset + 1])));
        target.blocklist = encoded[offset + 2];
        target.allowlist = encoded[offset + 3];
    }

    function _syncQueuedSourceThroughReplay(
        address source,
        uint48 timepoint,
        uint256 balance,
        ForageTokenVoteSyncTarget memory target
    ) private {
        _delegateToReplayModule(
            abi.encodeCall(ForageTokenVoteEligibilitySyncReplay.syncQueuedSource, (source, timepoint, balance, target))
        );
    }

    function _delegateToReplayModule(bytes memory data) private {
        (bool success, bytes memory result) = address(_REPLAY_MODULE).delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _delegateToStateModule(address stateModule, bytes memory data) private {
        (bool success, bytes memory result) = stateModule.delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _blocklistRotationStorage() private pure returns (BlocklistRotationStorage storage layout) {
        bytes32 slot = BLOCKLIST_ROTATION_SLOT;
        assembly ("memory-safe") {
            layout.slot := slot
        }
    }
}

contract ForageTokenStateModule {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MAX_LOCKERS_PER_ACCOUNT = 32;
    bytes32 private constant BLOCKLIST_ROTATION_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.ForageTokenStateModule.BlocklistRotation")) - 1)
    ) & ~bytes32(uint256(0xff));
    bytes32 private constant ELIGIBILITY_TRANSITION_OVERLAY_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.ForageTokenStateModule.EligibilityTransitionOverlay")) - 1)
    ) & ~bytes32(uint256(0xff));

    error DirectCallForbidden();
    error TooManyAccountLockers(address account, uint256 maximum);
    error EligibilityAccountingUnderflow(address delegatee, uint256 available, uint256 requested);
    error EligibilityAccountingOverflow(address delegatee, uint256 value);
    error TooManyVestingSources(address beneficiary, uint256 count, uint256 maximum);
    error LockBalanceExceedsBalance(address account, uint256 locked, uint256 balance);
    error InsufficientLockedBalance(address account, uint256 available, uint256 required);
    error NoLockerBalance();
    error ZeroAddress();
    error LegacySourceInventoryUnavailable(address currentBlocklist, address proposedBlocklist);
    error BlocklistRotationInProgress(address pendingBlocklist);
    error BlocklistRotationUnavailable();
    error BlocklistRotationIncomplete(uint256 cursor, uint256 inventoryLength, uint256 processed, uint256 dirty);
    error AllowlistReindexUnavailable();
    error UnsupportedLegacyVestingBeneficiary(address source);
    error ProjectionGenerationExhausted();
    error InvalidBlocklist(address blocklist);
    error VestingSourceRegistrationRequired(address source, address beneficiary);
    error VoteEligibilitySyncPending(uint48 timepoint);
    error NoPendingVoteEligibilitySync(address account);
    error VestingSourceAllowlistHandoffIncomplete(uint256 pendingSources);

    event AuthorizedBurnerUpdated(address indexed burner, bool authorized);
    event AuthorizedLockerUpdated(address indexed locker, bool authorized);
    event ForageLocked(address indexed account, uint256 amount, address indexed locker);
    event ForageUnlocked(address indexed account, uint256 amount, address indexed locker);
    event VoteSourceInventoried(address indexed source, uint256 inventoryLength);
    event BlocklistRotationStarted(
        address indexed currentBlocklist,
        address indexed candidateBlocklist,
        uint256 indexed generation,
        uint256 inventoryLength
    );
    event BlocklistRotationProgress(
        uint256 indexed generation, uint256 cursor, uint256 inventoryLength, uint256 processed, uint256 dirty
    );
    event BlocklistRotationActivated(
        address indexed oldBlocklist, address indexed newBlocklist, uint256 indexed generation, uint48 activationTime
    );
    event AllowlistReindexStarted(
        address indexed currentAllowlist,
        address indexed candidateAllowlist,
        uint256 indexed generation,
        uint256 snapshotLength
    );
    event AllowlistReindexProgress(
        uint256 indexed generation,
        uint256 cursor,
        uint256 snapshotLength,
        uint256 inventoryLength,
        uint256 processed,
        uint256 dirty
    );
    event AllowlistReindexActivated(
        address indexed oldAllowlist, address indexed newAllowlist, uint256 indexed generation, uint48 activationTime
    );
    event AllowlistReindexCancelled(address indexed candidateAllowlist, uint256 indexed generation);
    event VoteEligibilitySyncQueued(address indexed account, uint48 timepoint, uint256 pendingCount);
    event VoteEligibilitySyncProgress(address indexed account, uint256 remainingSources, bool complete);

    struct VoteSourceState {
        address delegatee;
        uint208 baseVotes;
        uint48 firstTransitionTime;
        int256 firstTransitionDelta;
        uint48 secondTransitionTime;
        int256 secondTransitionDelta;
    }

    struct EligibilityTransitionOverlayStorage {
        mapping(address => mapping(uint256 => int256)) radixDeltas;
    }

    struct Projection {
        mapping(address => VoteSourceState) sourceStates;
        mapping(address => Checkpoints.Trace208) eligibleVotes;
        mapping(address => mapping(uint256 => int256)) transitionTree;
        mapping(address => bool) processedSources;
        mapping(address => bool) projectedSources;
        mapping(address => bool) legacySources;
        mapping(address => EnumerableSet.AddressSet) vestingSourcesByBeneficiary;
        mapping(address => bool) vestingSourceAllowlistHandoffs;
        uint256 vestingSourceAllowlistHandoffCount;
        mapping(address => address) vestingBeneficiariesBySource;
    }

    struct ProjectionEpoch {
        uint48 startTime;
        uint256 generation;
        address blocklist;
    }

    struct BlocklistRotationStorage {
        uint256 inventoryVersion;
        address[] sources;
        mapping(address => bool) sourceSeen;
        address pendingBlocklist;
        uint256 activeGeneration;
        uint256 pendingGeneration;
        uint256 cursor;
        uint256 processed;
        uint256 dirty;
        ProjectionEpoch[] epochs;
        mapping(uint256 => Projection) projections;
        mapping(uint256 => address) generationAllowlists;
        uint256 pendingSnapshotLength;
        uint256 latestGeneration;
        address pendingAllowlist;
        uint256 projectionSchemaVersion;
        mapping(address => bool) pendingVoteEligibilitySyncs;
        mapping(address => uint256) pendingVoteEligibilitySyncCursors;
        uint256 candidateAllowlistPointerCursor;
        uint256 vestingMembershipSchemaVersion;
        uint256 voteEligibilitySyncSchemaVersion;
        uint256 pendingVoteSyncHeadTaskId;
        uint256 pendingVoteSyncTailTaskId;
        mapping(uint256 => uint256) pendingVoteSyncNextTaskIds;
        mapping(uint256 => address) pendingVoteSyncTaskAccounts;
        mapping(uint256 => uint48) pendingVoteSyncTaskTimepoints;
        mapping(uint256 => uint256) pendingVoteSyncTaskCursors;
        mapping(uint256 => bool) pendingVoteSyncTaskTransfers;
        mapping(uint256 => uint256) pendingVoteSyncTaskBeforeBalances;
        mapping(uint256 => uint256) pendingVoteSyncTaskAfterBalances;
        mapping(uint48 => mapping(address => uint256)) pendingVoteSyncObserverTaskIds;
        mapping(address => uint256) pendingVoteTransferHeadTaskIds;
        mapping(address => uint256) pendingVoteTransferTailTaskIds;
        mapping(uint256 => uint256) pendingVoteTransferNextTaskIds;
        mapping(uint256 => address[]) pendingVoteSyncTaskVestingSources;
        mapping(uint256 => address[]) pendingVoteSyncTaskActiveSources;
        mapping(uint256 => address[]) pendingVoteSyncTaskPendingSources;
        mapping(uint256 => uint256) pendingVoteSyncTaskPendingCursors;
        bool pendingProjectionPageIsPointer;
        uint256 pendingProjectionPageEnd;
        uint256 pendingProjectionPageBarrier;
    }

    struct VoteTransitions {
        uint48 firstTime;
        int256 firstDelta;
        uint48 secondTime;
        int256 secondDelta;
    }

    struct SourceSync {
        address source;
        address newDelegate;
        address registeredBeneficiary;
        uint256 votes;
        bool systemAccount;
        bool registrationPending;
        bool unsupportedRegistration;
        bool relevant;
        uint48 timepoint;
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
    mapping(address => mapping(address => bool)) private _explicitZeroResetRequired;
    uint256 private _voteEligibilitySyncCount;
    uint48 private _voteEligibilitySyncTimepoint;
    uint256[34] private __gap;

    address private immutable _SELF;
    ForageTokenVoteEligibilitySyncQueue private immutable _VOTE_SYNC_QUEUE;

    constructor() {
        _SELF = address(this);
        _VOTE_SYNC_QUEUE = new ForageTokenVoteEligibilitySyncQueue();
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    modifier onlyFreshDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _requireFreshInventory();
        _;
    }

    function _requireFreshInventory() private view {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (
            state.inventoryVersion != 1 || state.projectionSchemaVersion != 4
                || state.vestingMembershipSchemaVersion != 1 || state.voteEligibilitySyncSchemaVersion != 6
                || state.epochs.length == 0
        ) {
            revert LegacySourceInventoryUnavailable(_blocklist, address(0));
        }
    }

    function _applyEligibilityTransition(uint256 baseVotes, int256 delta) private pure returns (uint256) {
        if (delta >= 0) {
            uint256 deduction = uint256(delta);
            return deduction >= baseVotes ? 0 : baseVotes - deduction;
        }
        uint256 addition = uint256(-(delta + 1)) + 1;
        return baseVotes + addition;
    }

    function _blocklistRotationStorage() private pure returns (BlocklistRotationStorage storage layout) {
        bytes32 slot = BLOCKLIST_ROTATION_SLOT;
        assembly ("memory-safe") {
            layout.slot := slot
        }
    }

    function initializeSourceInventory() external onlyDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (
            state.inventoryVersion != 0 || state.epochs.length != 0 || state.sources.length != 0
                || state.pendingBlocklist != address(0) || state.activeGeneration != 0 || state.pendingSnapshotLength != 0
                || state.latestGeneration != 0 || state.pendingAllowlist != address(0) || state.projectionSchemaVersion != 0
                || state.candidateAllowlistPointerCursor != 0 || state.vestingMembershipSchemaVersion != 0
                || state.voteEligibilitySyncSchemaVersion != 0 || state.pendingProjectionPageIsPointer
                || state.pendingProjectionPageEnd != 0 || state.pendingProjectionPageBarrier != 0
                || state.pendingVoteSyncHeadTaskId != 0 || state.pendingVoteSyncTailTaskId != 0
                || _voteEligibilitySyncCount != 0 || _voteEligibilitySyncTimepoint != 0
        ) revert BlocklistRotationUnavailable();
        state.inventoryVersion = 1;
        state.projectionSchemaVersion = 4;
        state.vestingMembershipSchemaVersion = 1;
        state.voteEligibilitySyncSchemaVersion = 6;
        state.pendingProjectionPageIsPointer = false;
        state.pendingProjectionPageEnd = 0;
        state.pendingProjectionPageBarrier = 0;
        _voteEligibilitySyncCount = 0;
        _voteEligibilitySyncTimepoint = 0;
        state.epochs.push(ProjectionEpoch({startTime: 0, generation: 0, blocklist: address(0)}));
    }

    function blocklistRotationStatus()
        external
        view
        onlyDelegateCall
        returns (ForageTokenRotationStatus memory status)
    {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        status.inventorySupported = state.inventoryVersion == 1 && state.projectionSchemaVersion == 4
            && state.vestingMembershipSchemaVersion == 1 && state.voteEligibilitySyncSchemaVersion == 6
            && state.epochs.length != 0;
        status.rotationActive = state.pendingBlocklist != address(0) && state.pendingAllowlist == address(0);
        status.activeGeneration = state.activeGeneration;
        status.pendingGeneration = state.pendingGeneration;
        status.cursor = state.cursor;
        status.inventoryLength =
            state.pendingBlocklist == address(0) ? state.sources.length : state.pendingSnapshotLength;
        status.processed = state.processed;
        status.dirty = state.dirty;
        status.epochCount = state.epochs.length;
        status.activeBlocklist = _blocklist;
        status.pendingBlocklist = state.pendingBlocklist;
        status.allowlistReindexActive = state.pendingAllowlist != address(0);
        status.pendingAllowlist = state.pendingAllowlist;
    }

    function bindInitialBlocklist(address blocklist, uint48 activationTime) external onlyFreshDelegateCall {
        if (blocklist == address(0)) revert ZeroAddress();
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (!_canBindInitialBlocklist(state)) revert LegacySourceInventoryUnavailable(_blocklist, blocklist);
        _blocklist = blocklist;
        state.generationAllowlists[0] = allowlistAddress();
        state.epochs.push(ProjectionEpoch({startTime: activationTime, generation: 0, blocklist: blocklist}));
    }

    function _canBindInitialBlocklist(BlocklistRotationStorage storage state) private view returns (bool) {
        return state.inventoryVersion == 1 && state.sources.length == 0 && state.pendingBlocklist == address(0)
            && state.activeGeneration == 0 && _blocklist == address(0);
    }

    function beginBlocklistRotation(address blocklist) external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingBlocklist != address(0)) revert BlocklistRotationInProgress(state.pendingBlocklist);
        if (blocklist == address(0) || blocklist == _blocklist) revert InvalidBlocklist(blocklist);
        if (state.latestGeneration < state.activeGeneration) {
            revert LegacySourceInventoryUnavailable(_blocklist, blocklist);
        }
        if (state.latestGeneration == type(uint256).max) revert ProjectionGenerationExhausted();
        state.pendingBlocklist = blocklist;
        state.pendingGeneration = state.latestGeneration + 1;
        state.latestGeneration = state.pendingGeneration;
        state.pendingSnapshotLength = state.sources.length;
        state.cursor = 0;
        state.processed = 0;
        state.dirty = 0;
        state.candidateAllowlistPointerCursor = 0;
        state.pendingProjectionPageEnd = 0;
        state.pendingProjectionPageBarrier = state.pendingVoteSyncTailTaskId + 1;
        emit BlocklistRotationStarted(_blocklist, blocklist, state.pendingGeneration, state.pendingSnapshotLength);
    }

    function beginAllowlistReindex(address allowlist_) external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingBlocklist != address(0)) revert BlocklistRotationInProgress(state.pendingBlocklist);
        if (_blocklist == address(0) || allowlist_ == address(0) || allowlist_ == allowlistAddress()) {
            revert AllowlistReindexUnavailable();
        }
        _historicalVestingSourceRegistration(allowlist_, address(this), IForageTokenSourceView(address(this)).clock());
        if (state.latestGeneration < state.activeGeneration) {
            revert LegacySourceInventoryUnavailable(_blocklist, allowlist_);
        }
        if (state.latestGeneration == type(uint256).max) revert ProjectionGenerationExhausted();
        state.pendingBlocklist = _blocklist;
        state.pendingAllowlist = allowlist_;
        state.pendingGeneration = state.latestGeneration + 1;
        state.latestGeneration = state.pendingGeneration;
        state.pendingSnapshotLength = state.sources.length;
        state.cursor = 0;
        state.processed = 0;
        state.dirty = 0;
        state.candidateAllowlistPointerCursor = 0;
        state.pendingProjectionPageEnd = 0;
        state.pendingProjectionPageBarrier = state.pendingVoteSyncTailTaskId + 1;
        emit AllowlistReindexStarted(
            allowlistAddress(), allowlist_, state.pendingGeneration, state.pendingSnapshotLength
        );
    }

    function processBlocklistRotation() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingBlocklist == address(0) || state.pendingAllowlist != address(0)) {
            revert BlocklistRotationUnavailable();
        }
        bool ready = abi.decode(
            _delegateVoteSyncQueue(abi.encodeCall(ForageTokenVoteEligibilitySyncQueue.processRotationPage, (_SELF))),
            (bool)
        );
        if (!ready) {
            emit BlocklistRotationProgress(
                state.pendingGeneration, state.cursor, state.pendingSnapshotLength, state.processed, state.dirty
            );
            return;
        }
        emit BlocklistRotationProgress(
            state.pendingGeneration, state.cursor, state.pendingSnapshotLength, state.processed, state.dirty
        );
    }

    function processAllowlistReindex() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingAllowlist == address(0)) revert AllowlistReindexUnavailable();
        (bool ready, uint256 progress) = abi.decode(
            _delegateVoteSyncQueue(abi.encodeCall(ForageTokenVoteEligibilitySyncQueue.processAllowlistPage, (_SELF))),
            (bool, uint256)
        );
        if (!ready) {
            emit AllowlistReindexProgress(
                state.pendingGeneration,
                progress,
                state.pendingSnapshotLength,
                state.sources.length,
                state.processed,
                state.dirty
            );
            return;
        }
        emit AllowlistReindexProgress(
            state.pendingGeneration,
            progress,
            state.pendingSnapshotLength,
            state.sources.length,
            state.processed,
            state.dirty
        );
    }

    function activateBlocklistRotation() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        address nextBlocklist = state.pendingBlocklist;
        if (nextBlocklist == address(0) || state.pendingAllowlist != address(0)) {
            revert BlocklistRotationUnavailable();
        }
        address previousBlocklist = _blocklist;
        (uint256 generation, uint48 activationTime) = _activateProjection(state, nextBlocklist, allowlistAddress());
        emit BlocklistRotationActivated(previousBlocklist, nextBlocklist, generation, activationTime);
    }

    function activateAllowlistReindex() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        address nextAllowlist = state.pendingAllowlist;
        if (nextAllowlist == address(0) || state.pendingBlocklist != _blocklist) {
            revert AllowlistReindexUnavailable();
        }
        if (allowlistAddress() != nextAllowlist) revert AllowlistReindexUnavailable();
        Projection storage candidate = state.projections[state.pendingGeneration];
        if (state.candidateAllowlistPointerCursor > state.sources.length) revert AllowlistReindexUnavailable();
        uint256 unscanned = state.sources.length - state.candidateAllowlistPointerCursor;
        uint256 pendingSources = candidate.vestingSourceAllowlistHandoffCount + unscanned;
        if (pendingSources != 0) revert VestingSourceAllowlistHandoffIncomplete(pendingSources);
        _requireVestingSourceAllowlists(state, nextAllowlist);
        address previousAllowlist = state.generationAllowlists[state.activeGeneration];
        (uint256 generation, uint48 activationTime) = _activateProjection(state, _blocklist, nextAllowlist);
        emit AllowlistReindexActivated(previousAllowlist, nextAllowlist, generation, activationTime);
    }

    function cancelAllowlistReindex() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        address candidateAllowlist = state.pendingAllowlist;
        uint256 generation = state.pendingGeneration;
        if (candidateAllowlist == address(0)) revert AllowlistReindexUnavailable();
        _requireVestingSourceAllowlists(state, allowlistAddress());
        state.pendingBlocklist = address(0);
        state.pendingAllowlist = address(0);
        state.pendingGeneration = 0;
        state.pendingSnapshotLength = 0;
        state.cursor = 0;
        state.processed = 0;
        state.dirty = 0;
        state.candidateAllowlistPointerCursor = 0;
        state.pendingProjectionPageEnd = 0;
        state.pendingProjectionPageBarrier = 0;
        emit AllowlistReindexCancelled(candidateAllowlist, generation);
    }

    function _activateProjection(BlocklistRotationStorage storage state, address nextBlocklist, address nextAllowlist)
        private
        returns (uint256 generation, uint48 activationTime)
    {
        uint256 snapshot = state.pendingSnapshotLength;
        _delegateVoteSyncQueue(abi.encodeCall(ForageTokenVoteEligibilitySyncQueue.ensureProjectionComplete, ()));
        if (state.cursor != snapshot || state.processed < snapshot || state.dirty != 0) {
            revert BlocklistRotationIncomplete(state.cursor, snapshot, state.processed, state.dirty);
        }
        generation = state.pendingGeneration;
        activationTime = IForageTokenSourceView(address(this)).clock();
        state.epochs.push(
            ProjectionEpoch({startTime: activationTime, generation: generation, blocklist: nextBlocklist})
        );
        state.generationAllowlists[generation] = nextAllowlist;
        _blocklist = nextBlocklist;
        state.activeGeneration = generation;
        state.pendingBlocklist = address(0);
        state.pendingAllowlist = address(0);
        state.pendingGeneration = 0;
        state.pendingSnapshotLength = 0;
        state.cursor = 0;
        state.processed = 0;
        state.dirty = 0;
        state.candidateAllowlistPointerCursor = 0;
        state.pendingProjectionPageEnd = 0;
        state.pendingProjectionPageBarrier = 0;
    }

    function setAuthorizedBurner(address burner, bool authorized) external onlyFreshDelegateCall {
        if (burner == address(0)) revert ZeroAddress();
        _authorizedBurners[burner] = authorized;
        emit AuthorizedBurnerUpdated(burner, authorized);
    }

    function setAuthorizedLocker(address locker, bool authorized) external onlyFreshDelegateCall {
        if (locker == address(0)) revert ZeroAddress();
        _authorizedLockers[locker] = authorized;
        emit AuthorizedLockerUpdated(locker, authorized);
    }

    function syncSourceFromToken(address from, address to, uint256 amount) external onlyFreshDelegateCall {
        uint48 timepoint = IForageTokenSourceView(address(this)).clock();
        if (_voteEligibilitySyncCount != 0) {
            _delegateVoteSyncQueue(
                abi.encodeCall(ForageTokenVoteEligibilitySyncQueue.queueTransfer, (from, to, amount, timepoint))
            );
        } else {
            _syncTransferEndpoint(from, timepoint);
            if (to != from) _syncTransferEndpoint(to, timepoint);
        }
    }

    function syncDelegation(address source, address newDelegate) external onlyFreshDelegateCall {
        _syncSource(source, newDelegate, true, false, IForageTokenSourceView(address(this)).clock());
    }

    function _registerPendingVestingSource(address source, address candidateAllowlist, bool allowRegistration)
        private
    {
        if (source.code.length == 0) return;
        address activeAllowlist = allowlistAddress();
        if (candidateAllowlist == address(0)) candidateAllowlist = activeAllowlist;
        (bool activeSystem, address beneficiary) = _currentVestingSourceRegistration(source, activeAllowlist);
        if (!activeSystem || beneficiary == address(0)) return;
        (bool candidateSystem, address candidateBeneficiary) =
            _currentVestingSourceRegistration(source, candidateAllowlist);
        if (candidateSystem && candidateBeneficiary == beneficiary) return;
        if (!allowRegistration) revert VestingSourceRegistrationRequired(source, beneficiary);
        IAllowlistSystemRegistrar(candidateAllowlist).setSystemAccount(source, true);
        (candidateSystem, candidateBeneficiary) = _currentVestingSourceRegistration(source, candidateAllowlist);
        if (!candidateSystem || candidateBeneficiary != beneficiary) {
            revert VestingSourceRegistrationRequired(source, beneficiary);
        }
    }

    function syncVoteEligibility(address account) external onlyFreshDelegateCall {
        if (account == address(0)) return;
        uint48 timepoint = IForageTokenSourceView(address(this)).clock();
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingAllowlist != address(0) && msg.sender == allowlistAddress()) {
            _registerPendingVestingSource(account, state.pendingAllowlist, true);
        }
        _delegateVoteSyncQueue(abi.encodeCall(ForageTokenVoteEligibilitySyncQueue.queueObserver, (account, timepoint)));
    }

    function processPendingVoteEligibilitySync(address account)
        external
        onlyFreshDelegateCall
        returns (bool complete)
    {
        bytes memory result =
            _delegateVoteSyncQueue(abi.encodeCall(ForageTokenVoteEligibilitySyncQueue.process, (_SELF, account)));
        return abi.decode(result, (bool));
    }

    function syncQueuedSource(address source, uint48 timepoint, uint256 balance) external onlyFreshDelegateCall {
        _syncSourceAtBalance(source, timepoint, balance);
    }

    function registerPendingProjectionSource(address source) external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        _registerPendingVestingSource(source, state.pendingAllowlist, true);
    }

    function _syncTransferEndpoint(address source, uint48 timepoint) private {
        if (source == address(0)) return;
        uint256 balance = IForageTokenSourceView(address(this)).balanceOf(source);
        _syncSourceAtBalance(source, timepoint, balance);
    }

    function _delegateVoteSyncQueue(bytes memory data) private returns (bytes memory result) {
        address target = address(_VOTE_SYNC_QUEUE);
        assembly ("memory-safe") {
            let success := delegatecall(gas(), target, add(data, 32), mload(data), 0, 0)
            let size := returndatasize()
            let pointer := mload(0x40)
            mstore(pointer, size)
            returndatacopy(add(pointer, 32), 0, size)
            mstore(0x40, and(add(add(pointer, 63), size), not(31)))
            result := pointer
            if iszero(success) { revert(add(pointer, 32), size) }
        }
    }

    function syncInitialVestingSources() external onlyFreshDelegateCall {
        _historicalVestingSourceRegistration(
            allowlistAddress(), address(this), IForageTokenSourceView(address(this)).clock()
        );
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        if (rotation.activeGeneration == 0 && rotation.pendingBlocklist == address(0)) {
            rotation.generationAllowlists[0] = allowlistAddress();
        }
        address teamSource = _initialTeamVestingSource;
        if (teamSource != address(0)) {
            _syncSource(teamSource, address(0), false, false, IForageTokenSourceView(address(this)).clock());
        }
        address treasurySource = _initialTreasurySource;
        if (treasurySource != address(0) && treasurySource != teamSource) {
            _syncSource(treasurySource, address(0), false, false, IForageTokenSourceView(address(this)).clock());
        }
    }

    function liveIndexedProjection(address delegatee)
        external
        view
        onlyFreshDelegateCall
        returns (ForageTokenActiveProjection memory projection)
    {
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        projection.generation = rotation.activeGeneration;
        projection.indexedVotes = _liveIndexedEligibleVotes(delegatee, projection.generation);
    }

    function pastIndexedProjection(address delegatee, uint256 timepoint)
        external
        view
        onlyFreshDelegateCall
        returns (ForageTokenPastProjection memory projection)
    {
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        (projection.generation, projection.blocklist) = _epochAt(timepoint);
        projection.allowlist = rotation.generationAllowlists[projection.generation];
        projection.indexedVotes = _pastIndexedEligibleVotes(delegatee, timepoint, projection.generation);
        projection.blocked = _wasBlockedAtTimepoint(delegatee, timepoint, projection.blocklist, projection.allowlist);
    }

    function _wasBlockedAtTimepoint(address account, uint256 timepoint, address blocklist, address allowlist_)
        private
        view
        returns (bool)
    {
        if (blocklist == address(0)) return false;
        uint256 sourceBlockedUntil = _blockedUntilAt(blocklist, account, timepoint);
        if (sourceBlockedUntil != 0 && sourceBlockedUntil >= timepoint) return true;
        (address beneficiary,,) = _historicalVestingSourceRegistration(allowlist_, account, timepoint);
        if (beneficiary == address(0)) return false;
        uint256 beneficiaryBlockedUntil = _blockedUntilAt(blocklist, beneficiary, timepoint);
        return beneficiaryBlockedUntil != 0 && beneficiaryBlockedUntil >= timepoint;
    }

    function _blockedUntilAt(address blocklist, address account, uint256 timepoint)
        private
        view
        returns (uint256 blockedUntil_)
    {
        if (blocklist == address(0)) revert InvalidBlocklist(blocklist);
        try IBlocklistVoteEligibility(blocklist).blockedUntilAt(account, timepoint) returns (uint256 expiry) {
            blockedUntil_ = expiry;
        } catch {
            revert InvalidBlocklist(blocklist);
        }
    }

    function sourceEligibilityForBlocklistModule(ForageTokenSourceEligibilityQuery calldata query)
        external
        view
        onlyFreshDelegateCall
        returns (ForageTokenSourceEligibility memory eligibility)
    {
        uint48 timepoint = query.timepoint;
        (eligibility.allowlisted, eligibility.systemAccount, eligibility.allowedUntil) =
            _allowlistAccountEligibility(query.allowlist, query.source, timepoint);
        address beneficiary = query.registeredBeneficiary;
        (address registered, bool registrationPending, bool unsupportedBeneficiary) =
            _historicalVestingSourceRegistration(query.allowlist, query.source, timepoint);
        if (registered != beneficiary || query.registrationKnown != (registered != address(0))) {
            revert VestingSourceRegistrationRequired(query.source, beneficiary);
        }
        if (registrationPending) revert VestingSourceRegistrationRequired(query.source, beneficiary);
        if (unsupportedBeneficiary) revert UnsupportedLegacyVestingBeneficiary(query.source);
        if (beneficiary != address(0)) {
            if (!eligibility.systemAccount) {
                revert VestingSourceRegistrationRequired(query.source, beneficiary);
            }
            if (query.rememberedBeneficiary != address(0) && query.rememberedBeneficiary != beneficiary) {
                revert IAllowlist.AllowlistUnavailable();
            }
            (bool beneficiaryAllowed, bool beneficiarySystem, uint64 beneficiaryUntil) =
                _allowlistAccountEligibility(query.allowlist, beneficiary, timepoint);
            bool sourceSystem = eligibility.systemAccount;
            eligibility.allowlisted = eligibility.allowlisted && beneficiaryAllowed;
            eligibility.systemAccount = sourceSystem && beneficiarySystem;
            if (sourceSystem) {
                eligibility.allowedUntil = beneficiaryUntil;
            } else if (!beneficiarySystem && beneficiaryUntil < eligibility.allowedUntil) {
                eligibility.allowedUntil = beneficiaryUntil;
            }
        }
        address blocklist = query.blocklist;
        if (blocklist == address(0)) return eligibility;
        try IBlocklistVoteEligibility(blocklist).blockedUntilAt(query.source, timepoint) returns (uint256 blockedUntil_)
        {
            eligibility.blockedUntil = blockedUntil_;
        } catch {
            revert InvalidBlocklist(blocklist);
        }
        eligibility.blocked = eligibility.blockedUntil != 0 && eligibility.blockedUntil >= timepoint;
        if (beneficiary != address(0)) {
            uint256 beneficiaryBlockedUntil;
            try IBlocklistVoteEligibility(blocklist).blockedUntilAt(beneficiary, timepoint) returns (
                uint256 blockedUntil_
            ) {
                beneficiaryBlockedUntil = blockedUntil_;
            } catch {
                revert InvalidBlocklist(blocklist);
            }
            if (beneficiaryBlockedUntil != 0 && beneficiaryBlockedUntil >= timepoint) {
                eligibility.blocked = true;
            }
            if (beneficiaryBlockedUntil > eligibility.blockedUntil) {
                eligibility.blockedUntil = beneficiaryBlockedUntil;
            }
        }
    }

    function _epochAt(uint256 timepoint) private view returns (uint256 generation, address provider) {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        uint256 length = state.epochs.length;
        if (state.inventoryVersion != 1 || length == 0) {
            revert LegacySourceInventoryUnavailable(_blocklist, address(0));
        }
        uint256 lower;
        uint256 upper = length;
        while (lower < upper) {
            uint256 middle = lower + (upper - lower) / 2;
            if (state.epochs[middle].startTime <= timepoint) lower = middle + 1;
            else upper = middle;
        }
        if (lower == 0) revert LegacySourceInventoryUnavailable(_blocklist, address(0));
        ProjectionEpoch storage epoch = state.epochs[lower - 1];
        return (epoch.generation, epoch.blocklist);
    }

    function _planVoteTransitions(ForageTokenSourceEligibility memory eligibility, uint256 votes, uint48 currentTime)
        private
        pure
        returns (VoteTransitions memory transitions)
    {
        if (votes == 0 || !eligibility.allowlisted) return transitions;
        int256 signedVotes = int256(votes);
        uint256 maximumTime = uint256(type(uint48).max);
        if (!eligibility.blocked) {
            if (!eligibility.systemAccount && eligibility.allowedUntil >= currentTime) {
                uint256 expiry = eligibility.allowedUntil;
                if (expiry < maximumTime) {
                    transitions.firstTime = uint48(expiry + 1);
                    transitions.firstDelta = signedVotes;
                }
            }
            return transitions;
        }
        uint256 blockedUntil_ = eligibility.blockedUntil;
        if (blockedUntil_ >= currentTime && blockedUntil_ < maximumTime) {
            if (eligibility.systemAccount || uint256(eligibility.allowedUntil) > blockedUntil_) {
                transitions.firstTime = uint48(blockedUntil_ + 1);
                transitions.firstDelta = -signedVotes;
            }
        }
        if (
            !eligibility.systemAccount && eligibility.allowedUntil >= currentTime
                && uint256(eligibility.allowedUntil) < maximumTime && blockedUntil_ < eligibility.allowedUntil
        ) {
            transitions.secondTime = uint48(uint256(eligibility.allowedUntil) + 1);
            transitions.secondDelta = signedVotes;
        }
    }

    function _currentVestingSourceRegistration(address source, address allowlist_)
        private
        view
        returns (bool systemAccount, address beneficiary)
    {
        if (source.code.length == 0) return (false, address(0));
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlist(allowlist_).isSystemAccount(source) returns (bool currentSystem) {
            systemAccount = currentSystem;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (systemAccount) beneficiary = _registeredVestingBeneficiary(allowlist_, source);
    }

    function _vestingSourceRegistrationAt(address source, address allowlist_, uint48 timepoint)
        private
        view
        returns (bool systemAccount, address beneficiary, bool registrationPending, bool unsupportedBeneficiary)
    {
        (, systemAccount,) = _allowlistAccountEligibility(allowlist_, source, timepoint);
        (beneficiary, registrationPending, unsupportedBeneficiary) =
            _historicalVestingSourceRegistration(allowlist_, source, timepoint);
        if (beneficiary != address(0) && !systemAccount) {
            revert VestingSourceRegistrationRequired(source, beneficiary);
        }
    }

    function _historicalVestingSourceRegistration(address allowlist_, address source, uint256 timepoint)
        private
        view
        returns (address beneficiary, bool registrationPending, bool unsupportedBeneficiary)
    {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVestingRegistry(allowlist_).vestingSourceRegistrationAt(source, timepoint) returns (
            address registered, bool pending, bool unsupported
        ) {
            return (registered, pending, unsupported);
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _registeredVestingBeneficiary(address allowlist_, address source)
        private
        view
        returns (address beneficiary)
    {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVestingRegistry(allowlist_).vestingSourceBeneficiary(source) returns (address registered) {
            beneficiary = registered;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _allowlistAccountEligibility(address allowlist_, address account, uint48 timepoint)
        private
        view
        returns (bool allowed, bool systemAccount, uint64 allowedUntil)
    {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVoteEligibility(allowlist_).eligibilityStateAt(account, timepoint) returns (
            uint64 historicalAllowedUntil, bool historicalSystemAccount
        ) {
            allowedUntil = historicalAllowedUntil;
            systemAccount = historicalSystemAccount;
            allowed = systemAccount || allowedUntil >= timepoint;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _rememberRegisteredBeneficiary(address source, address beneficiary) private {
        if (beneficiary == address(0)) return;
        _vestingBeneficiaryBySource[source] = beneficiary;
    }

    function allowlistAddress() private view returns (address) {
        return IForageTokenSourceView(address(this)).allowlist();
    }

    function _maxVestingSourcesPerBeneficiary(address allowlist_) private view returns (uint256 maximum) {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVestingRegistry(allowlist_).maxVestingSourcesPerBeneficiary() returns (uint256 value) {
            maximum = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _liveIndexedEligibleVotes(address delegatee, uint256 generation) private view returns (uint256) {
        uint48 currentTime = IForageTokenSourceView(address(this)).clock();
        Projection storage projection = _blocklistRotationStorage().projections[generation];
        return _applyEligibilityTransition(
            projection.eligibleVotes[delegatee].latest(), _projectionFenwickPrefix(projection, delegatee, currentTime)
        );
    }

    function _pastIndexedEligibleVotes(address delegatee, uint256 timepoint, uint256 generation)
        private
        view
        returns (uint256)
    {
        if (timepoint > type(uint48).max) return 0;
        Projection storage projection = _blocklistRotationStorage().projections[generation];
        return _applyEligibilityTransition(
            projection.eligibleVotes[delegatee].upperLookupRecent(uint48(timepoint)),
            _projectionFenwickPrefix(projection, delegatee, timepoint)
        );
    }

    function burn(address from, uint256 amount) external onlyFreshDelegateCall {
        uint256 currentBalance = IForageTokenSourceView(address(this)).balanceOf(from);
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

    function lock(address account, uint256 amount) external onlyFreshDelegateCall {
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

    function unlock(address account, uint256 amount) external onlyFreshDelegateCall {
        address locker = msg.sender;
        uint256 lockerBalance = _lockerBalances[account][locker];
        if (lockerBalance < amount) revert InsufficientLockedBalance(account, lockerBalance, amount);
        _lockerBalances[account][locker] -= amount;
        _lockedBalances[account] -= amount;
        if (_lockerBalances[account][locker] == 0) _accountLockers[account].remove(locker);
        emit ForageUnlocked(account, amount, locker);
    }

    function setLockExempt(address account, bool exempt) external onlyFreshDelegateCall {
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
        uint256 accountBalance = IForageTokenSourceView(address(this)).balanceOf(account);
        if (reconciledSum > accountBalance) {
            revert LockBalanceExceedsBalance(account, reconciledSum, accountBalance);
        }
        _lockedBalances[account] = reconciledSum;
        _lockExempt[account] = exempt;
    }

    function emergencyUnlock(address account, address locker) external onlyFreshDelegateCall {
        uint256 lockerBalance = _lockerBalances[account][locker];
        if (lockerBalance == 0) revert NoLockerBalance();
        _lockedBalances[account] -= lockerBalance;
        _lockerBalances[account][locker] = 0;
        _accountLockers[account].remove(locker);
        emit ForageUnlocked(account, lockerBalance, locker);
    }

    function _syncSource(
        address source,
        address requestedDelegate,
        bool isDelegation,
        bool forceInventory,
        uint48 timepoint
    ) private {
        uint256 balance = IForageTokenSourceView(address(this)).balanceOf(source);
        SourceSync memory sync =
            _prepareSourceSync(source, requestedDelegate, isDelegation, forceInventory, balance, timepoint);
        _applySourceSync(sync, timepoint);
    }

    function _syncSourceAtBalance(address source, uint48 timepoint, uint256 balance) private {
        SourceSync memory sync = _prepareSourceSync(source, address(0), false, false, balance, timepoint);
        _applySourceSync(sync, timepoint);
    }

    function _applySourceSync(SourceSync memory sync, uint48 timepoint) private {
        sync.timepoint = timepoint;
        if (!sync.relevant) return;
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        _syncActiveProjection(rotation, sync);
        _syncPendingProjection(rotation, sync);
    }

    function _prepareSourceSync(
        address source,
        address requestedDelegate,
        bool isDelegation,
        bool forceInventory,
        uint256 sourceBalance,
        uint48 timepoint
    ) private returns (SourceSync memory sync) {
        if (source == address(0)) return sync;
        IForageTokenSourceView token = IForageTokenSourceView(address(this));
        sync.source = source;
        sync.newDelegate = isDelegation ? requestedDelegate : token.delegates(source);
        sync.votes = sync.newDelegate == address(0) ? 0 : sourceBalance;
        sync.timepoint = timepoint;
        (sync.systemAccount, sync.registeredBeneficiary, sync.registrationPending, sync.unsupportedRegistration) =
            _vestingSourceRegistrationAt(source, token.allowlist(), timepoint);
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        Projection storage active = rotation.projections[rotation.activeGeneration];
        sync.relevant = forceInventory || sync.newDelegate != address(0) || rotation.sourceSeen[source]
            || active.sourceStates[source].delegatee != address(0) || active.processedSources[source]
            || _vestingBeneficiaryBySource[source] != address(0) || sync.registeredBeneficiary != address(0);
        if (!sync.relevant && rotation.pendingAllowlist != address(0)) {
            (bool candidateSystem, address candidateBeneficiary,,) =
                _vestingSourceRegistrationAt(source, rotation.pendingAllowlist, timepoint);
            sync.relevant = candidateSystem && candidateBeneficiary != address(0);
        }
        if (!sync.relevant) return sync;
        if (sync.newDelegate != address(0) && sync.votes != 0) {
            if (sync.registrationPending) {
                revert VestingSourceRegistrationRequired(source, sync.registeredBeneficiary);
            }
            if (sync.systemAccount && sync.unsupportedRegistration) {
                revert UnsupportedLegacyVestingBeneficiary(source);
            }
        }
        _recordVoteSource(rotation, source);
        _rememberRegisteredBeneficiary(source, sync.registeredBeneficiary);
    }

    function _syncActiveProjection(BlocklistRotationStorage storage rotation, SourceSync memory sync) private {
        uint256 generation = rotation.activeGeneration;
        address activeAllowlist = allowlistAddress();
        ForageTokenStateUpdate memory update = _sourceUpdate(sync, _blocklist, activeAllowlist, sync.timepoint);
        _applyProjectionSourceUpdate(rotation, generation, update, sync.timepoint);
        _updateProjectionVestingSourceMembership(
            rotation, generation, sync.source, sync.registeredBeneficiary, activeAllowlist
        );
    }

    function _syncPendingProjection(BlocklistRotationStorage storage rotation, SourceSync memory sync) private {
        uint256 generation = rotation.pendingGeneration;
        if (generation == 0) return;
        address pendingAllowlist = rotation.pendingAllowlist;
        address allowlist_ =
            pendingAllowlist == address(0) ? IForageTokenSourceView(address(this)).allowlist() : pendingAllowlist;
        SourceSync memory pendingSync = sync;
        if (pendingAllowlist != address(0)) {
            (
                pendingSync.systemAccount,
                pendingSync.registeredBeneficiary,
                pendingSync.registrationPending,
                pendingSync.unsupportedRegistration
            ) = _vestingSourceRegistrationAt(sync.source, allowlist_, sync.timepoint);
            _rememberRegisteredBeneficiary(sync.source, pendingSync.registeredBeneficiary);
        }
        if (pendingSync.newDelegate != address(0) && pendingSync.votes != 0) {
            if (pendingSync.registrationPending) {
                revert VestingSourceRegistrationRequired(sync.source, pendingSync.registeredBeneficiary);
            }
            if (pendingSync.systemAccount && pendingSync.unsupportedRegistration) {
                revert UnsupportedLegacyVestingBeneficiary(sync.source);
            }
        }
        ForageTokenStateUpdate memory update =
            _sourceUpdate(pendingSync, rotation.pendingBlocklist, allowlist_, sync.timepoint);
        _applyProjectionSourceUpdate(rotation, generation, update, sync.timepoint);
        _updateProjectionVestingSourceMembership(
            rotation, generation, sync.source, pendingSync.registeredBeneficiary, allowlist_
        );
        if (pendingAllowlist != address(0)) {
            _updateVestingSourceAllowlistHandoff(rotation.projections[generation], sync.source, pendingAllowlist);
        }
    }

    function _recordVoteSource(BlocklistRotationStorage storage rotation, address source) private {
        if (rotation.sourceSeen[source]) return;
        rotation.sourceSeen[source] = true;
        rotation.sources.push(source);
        emit VoteSourceInventoried(source, rotation.sources.length);
    }

    function _sourceUpdate(SourceSync memory sync, address blocklist, address allowlist_, uint48 timepoint)
        private
        view
        returns (ForageTokenStateUpdate memory update)
    {
        update.source = sync.source;
        update.newDelegate = sync.newDelegate;
        update.votes = sync.votes;
        update.registeredBeneficiary = sync.registeredBeneficiary;
        if (sync.newDelegate == address(0) || sync.votes == 0) return update;
        ForageTokenSourceEligibility memory eligibility = IForageTokenSourceView(address(this))
            .sourceEligibilityForBlocklist(
            sync.source,
            sync.registeredBeneficiary,
            sync.registeredBeneficiary != address(0),
            blocklist,
            allowlist_,
            timepoint
        );
        eligibility.allowlisted = eligibility.systemAccount || eligibility.allowedUntil >= timepoint;
        eligibility.blocked = eligibility.blockedUntil != 0 && eligibility.blockedUntil >= timepoint;
        if (eligibility.allowlisted && !eligibility.blocked) update.newBaseVotes = sync.votes;
        VoteTransitions memory transitions = _planVoteTransitions(eligibility, sync.votes, timepoint);
        update.firstTransitionTime = transitions.firstTime;
        update.firstTransitionDelta = transitions.firstDelta;
        update.secondTransitionTime = transitions.secondTime;
        update.secondTransitionDelta = transitions.secondDelta;
    }

    function _updateProjectionVestingSourceMembership(
        BlocklistRotationStorage storage rotation,
        uint256 generation,
        address source,
        address registeredBeneficiary,
        address allowlist_
    ) private {
        Projection storage projection = rotation.projections[generation];
        address previous = projection.vestingBeneficiariesBySource[source];
        if (previous == registeredBeneficiary) return;
        if (previous != address(0)) {
            projection.vestingSourcesByBeneficiary[previous].remove(source);
            delete projection.vestingBeneficiariesBySource[source];
            _updateVestingSourceUnion(rotation, source, previous);
        }
        if (registeredBeneficiary == address(0)) return;
        EnumerableSet.AddressSet storage sources = projection.vestingSourcesByBeneficiary[registeredBeneficiary];
        if (!sources.contains(source)) {
            uint256 maximum = _maxVestingSourcesPerBeneficiary(allowlist_);
            uint256 count = sources.length();
            if (count >= maximum) revert TooManyVestingSources(registeredBeneficiary, count, maximum);
            sources.add(source);
        }
        projection.vestingBeneficiariesBySource[source] = registeredBeneficiary;
        _updateVestingSourceUnion(rotation, source, registeredBeneficiary);
    }

    function _updateVestingSourceUnion(BlocklistRotationStorage storage rotation, address source, address beneficiary)
        private
    {
        bool registered =
            rotation.projections[rotation.activeGeneration].vestingSourcesByBeneficiary[beneficiary].contains(source);
        if (rotation.pendingGeneration != 0) {
            registered = registered
                || rotation.projections[rotation.pendingGeneration].vestingSourcesByBeneficiary[beneficiary].contains(
                    source
                );
        }
        EnumerableSet.AddressSet storage sources = _vestingSourcesByBeneficiary[beneficiary];
        if (registered) sources.add(source);
        else sources.remove(source);
    }

    function _updateVestingSourceAllowlistHandoff(
        Projection storage projection,
        address source,
        address expectedAllowlist
    ) private {
        bool incomplete =
            _vestingBeneficiaryBySource[source] != address(0) && _vestingSourceAllowlist(source) != expectedAllowlist;
        bool previous = projection.vestingSourceAllowlistHandoffs[source];
        if (incomplete == previous) return;
        projection.vestingSourceAllowlistHandoffs[source] = incomplete;
        if (incomplete) ++projection.vestingSourceAllowlistHandoffCount;
        else --projection.vestingSourceAllowlistHandoffCount;
    }

    function _vestingSourceAllowlist(address source) private view returns (address currentAllowlist) {
        if (source.code.length == 0) revert IAllowlist.AllowlistUnavailable();
        try IVestingSourceAllowlist(source).allowlist() returns (address value) {
            currentAllowlist = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _requireVestingSourceAllowlists(BlocklistRotationStorage storage state, address expectedAllowlist)
        private
        view
    {
        uint256 sourceCount = state.sources.length;
        for (uint256 index; index < sourceCount; ++index) {
            address source = state.sources[index];
            if (
                _vestingBeneficiaryBySource[source] != address(0)
                    && _vestingSourceAllowlist(source) != expectedAllowlist
            ) revert VestingSourceAllowlistHandoffIncomplete(1);
        }
        if (_vestingSourceAllowlist(_initialTreasurySource) != expectedAllowlist) {
            revert VestingSourceAllowlistHandoffIncomplete(1);
        }
    }

    function _applyProjectionSourceUpdate(
        BlocklistRotationStorage storage rotation,
        uint256 generation,
        ForageTokenStateUpdate memory update,
        uint48 timepoint
    ) private {
        Projection storage projection = rotation.projections[generation];
        bool pending = rotation.pendingBlocklist != address(0) && generation == rotation.pendingGeneration;
        if (!projection.processedSources[update.source]) {
            projection.processedSources[update.source] = true;
            if (pending) ++rotation.processed;
        }
        projection.projectedSources[update.source] = true;
        if (pending) ++rotation.dirty;
        _syncProjectionSource(projection, update, timepoint);
        if (pending) --rotation.dirty;
    }

    function _syncProjectionSource(
        Projection storage projection,
        ForageTokenStateUpdate memory update,
        uint48 currentTime
    ) private {
        VoteSourceState storage state = projection.sourceStates[update.source];
        address oldDelegate = state.delegatee;
        if (oldDelegate != address(0)) {
            _adjustProjectionTransition(
                projection, oldDelegate, state.firstTransitionTime, state.firstTransitionDelta, currentTime, false
            );
            _adjustProjectionTransition(
                projection, oldDelegate, state.secondTransitionTime, state.secondTransitionDelta, currentTime, false
            );
            if (oldDelegate == update.newDelegate) {
                _changeProjectionVotes(
                    projection, update.newDelegate, state.baseVotes, update.newBaseVotes, currentTime
                );
            } else {
                _changeProjectionVotes(projection, oldDelegate, state.baseVotes, 0, currentTime);
                _changeProjectionVotes(projection, update.newDelegate, 0, update.newBaseVotes, currentTime);
            }
        } else {
            _changeProjectionVotes(projection, update.newDelegate, 0, update.newBaseVotes, currentTime);
        }
        state.delegatee = update.newDelegate;
        state.baseVotes = uint208(update.newBaseVotes);
        state.firstTransitionTime = update.firstTransitionTime;
        state.firstTransitionDelta = update.firstTransitionDelta;
        state.secondTransitionTime = update.secondTransitionTime;
        state.secondTransitionDelta = update.secondTransitionDelta;
        _adjustProjectionTransition(
            projection, update.newDelegate, update.firstTransitionTime, update.firstTransitionDelta, currentTime, true
        );
        _adjustProjectionTransition(
            projection, update.newDelegate, update.secondTransitionTime, update.secondTransitionDelta, currentTime, true
        );
    }

    function _adjustProjectionTransition(
        Projection storage projection,
        address delegatee,
        uint48 transitionTime,
        int256 delta,
        uint48 currentTime,
        bool adding
    ) private {
        if (transitionTime == 0 || delta == 0) return;
        uint48 effectiveTime = adding || transitionTime > currentTime ? transitionTime : currentTime;
        int256 adjustment = adding ? delta : -delta;
        _projectionFenwickUpdate(projection, delegatee, effectiveTime, adjustment);
    }

    function _projectionFenwickUpdate(Projection storage projection, address delegatee, uint48 timepoint, int256 delta)
        private
    {
        uint256 maximum = uint256(1) << 48;
        uint256 index = uint256(timepoint) + 1;
        while (index <= maximum) {
            projection.transitionTree[delegatee][index] += delta;
            uint256 step = index & (~index + 1);
            if (index > maximum - step) break;
            index += step;
        }
    }

    function _projectionFenwickPrefix(Projection storage projection, address delegatee, uint256 timepoint)
        private
        view
        returns (int256 delta)
    {
        uint256 index = timepoint + 1;
        while (index != 0) {
            delta += projection.transitionTree[delegatee][index];
            index -= index & (~index + 1);
        }
    }

    function _changeProjectionVotes(
        Projection storage projection,
        address delegatee,
        uint256 removed,
        uint256 added,
        uint48 timepoint
    ) private {
        if (delegatee == address(0) || (removed == 0 && added == 0)) return;
        uint256 currentVotes = projection.eligibleVotes[delegatee].latest();
        if (currentVotes < removed) revert EligibilityAccountingUnderflow(delegatee, currentVotes, removed);
        uint256 nextVotes = currentVotes - removed + added;
        if (nextVotes > type(uint208).max) revert EligibilityAccountingOverflow(delegatee, nextVotes);
        projection.eligibleVotes[delegatee].push(timepoint, uint208(nextVotes));
    }
}
