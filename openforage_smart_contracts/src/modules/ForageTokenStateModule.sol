pragma solidity ^0.8.20;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAllowlist, IAllowlistVestingRegistry, IVestingBeneficiarySource} from "../interfaces/IAllowlist.sol";
import {IAllowlistSystemRegistrar} from "../interfaces/IAllowlistSystemRegistrar.sol";
import {IBlocklist, IBlocklistVoteEligibility} from "../interfaces/IBlocklist.sol";

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
    address rememberedBeneficiary;
}

interface IForageTokenSourceView {
    function balanceOf(address account) external view returns (uint256);

    function delegates(address account) external view returns (address);

    function allowlist() external view returns (address);

    function clock() external view returns (uint48);

    function sourceEligibilityForBlocklist(
        address source,
        address registeredBeneficiary,
        bool registrationKnown,
        address blocklist,
        address allowlist
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
}

contract ForageTokenStateModule {
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MAX_LOCKERS_PER_ACCOUNT = 32;
    uint256 private constant BLOCKLIST_ROTATION_PAGE_SIZE = 8;
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

    constructor() {
        _SELF = address(this);
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
            state.inventoryVersion != 1 || state.projectionSchemaVersion != 3
                || state.vestingMembershipSchemaVersion != 1 || state.epochs.length == 0
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
                || _voteEligibilitySyncCount != 0 || _voteEligibilitySyncTimepoint != 0
        ) revert BlocklistRotationUnavailable();
        state.inventoryVersion = 1;
        state.projectionSchemaVersion = 3;
        state.vestingMembershipSchemaVersion = 1;
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
        status.inventorySupported = state.inventoryVersion == 1 && state.projectionSchemaVersion == 3
            && state.vestingMembershipSchemaVersion == 1 && state.epochs.length != 0;
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
        if (state.inventoryVersion != 1 || state.projectionSchemaVersion != 3) {
            revert LegacySourceInventoryUnavailable(_blocklist, blocklist);
        }
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
        emit BlocklistRotationStarted(_blocklist, blocklist, state.pendingGeneration, state.pendingSnapshotLength);
    }

    function beginAllowlistReindex(address allowlist_) external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.inventoryVersion != 1 || state.projectionSchemaVersion != 3) {
            revert LegacySourceInventoryUnavailable(_blocklist, allowlist_);
        }
        if (state.pendingBlocklist != address(0)) revert BlocklistRotationInProgress(state.pendingBlocklist);
        if (_blocklist == address(0) || allowlist_ == address(0) || allowlist_ == allowlistAddress()) {
            revert AllowlistReindexUnavailable();
        }
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
        emit AllowlistReindexStarted(
            allowlistAddress(), allowlist_, state.pendingGeneration, state.pendingSnapshotLength
        );
    }

    function processBlocklistRotation() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingBlocklist == address(0) || state.pendingAllowlist != address(0)) {
            revert BlocklistRotationUnavailable();
        }
        _processProjectionPage(state);
        emit BlocklistRotationProgress(
            state.pendingGeneration, state.cursor, state.pendingSnapshotLength, state.processed, state.dirty
        );
    }

    function processAllowlistReindex() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingAllowlist == address(0)) revert AllowlistReindexUnavailable();
        uint256 progress = state.cursor;
        if (state.cursor < state.pendingSnapshotLength) {
            _processProjectionPage(state);
        } else {
            _processAllowlistPointerPage(state);
            progress = state.candidateAllowlistPointerCursor;
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

    function _processProjectionPage(BlocklistRotationStorage storage state) private {
        uint256 snapshot = state.pendingSnapshotLength;
        if (state.cursor > snapshot) {
            revert BlocklistRotationIncomplete(state.cursor, snapshot, state.processed, state.dirty);
        }
        uint256 remaining = snapshot - state.cursor;
        uint256 pageLength = remaining > BLOCKLIST_ROTATION_PAGE_SIZE ? BLOCKLIST_ROTATION_PAGE_SIZE : remaining;
        uint256 end = state.cursor + pageLength;
        while (state.cursor < end) {
            address source = state.sources[state.cursor];
            _registerPendingVestingSource(source, state.pendingAllowlist, true);
            _syncSource(source, address(0), false, true, IForageTokenSourceView(address(this)).clock());
            ++state.cursor;
        }
    }

    function _processAllowlistPointerPage(BlocklistRotationStorage storage state) private {
        uint256 length = state.sources.length;
        uint256 cursor = state.candidateAllowlistPointerCursor;
        Projection storage candidate = state.projections[state.pendingGeneration];
        if (cursor >= length) {
            if (candidate.vestingSourceAllowlistHandoffCount == 0) return;
            cursor = 0;
        }
        uint256 remaining = length - cursor;
        uint256 pageLength = remaining > BLOCKLIST_ROTATION_PAGE_SIZE ? BLOCKLIST_ROTATION_PAGE_SIZE : remaining;
        uint256 end = cursor + pageLength;
        uint48 timepoint = IForageTokenSourceView(address(this)).clock();
        while (cursor < end) {
            address source = state.sources[cursor];
            _registerPendingVestingSource(source, state.pendingAllowlist, true);
            _syncSource(source, address(0), false, true, timepoint);
            ++cursor;
        }
        state.candidateAllowlistPointerCursor = cursor;
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
        uint256 treasuryUnaligned = _vestingSourceAllowlist(_initialTreasurySource) == nextAllowlist ? 0 : 1;
        uint256 pendingSources = candidate.vestingSourceAllowlistHandoffCount + unscanned + treasuryUnaligned;
        if (pendingSources != 0) revert VestingSourceAllowlistHandoffIncomplete(pendingSources);
        address previousAllowlist = state.generationAllowlists[state.activeGeneration];
        (uint256 generation, uint48 activationTime) = _activateProjection(state, _blocklist, nextAllowlist);
        emit AllowlistReindexActivated(previousAllowlist, nextAllowlist, generation, activationTime);
    }

    function cancelAllowlistReindex() external onlyFreshDelegateCall {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        address candidateAllowlist = state.pendingAllowlist;
        uint256 generation = state.pendingGeneration;
        if (candidateAllowlist == address(0)) revert AllowlistReindexUnavailable();
        state.pendingBlocklist = address(0);
        state.pendingAllowlist = address(0);
        state.pendingGeneration = 0;
        state.pendingSnapshotLength = 0;
        state.cursor = 0;
        state.processed = 0;
        state.dirty = 0;
        state.candidateAllowlistPointerCursor = 0;
        emit AllowlistReindexCancelled(candidateAllowlist, generation);
    }

    function _activateProjection(BlocklistRotationStorage storage state, address nextBlocklist, address nextAllowlist)
        private
        returns (uint256 generation, uint48 activationTime)
    {
        uint256 snapshot = state.pendingSnapshotLength;
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

    function syncSourceFromToken(address source) external onlyFreshDelegateCall {
        _syncSource(source, address(0), false, false, IForageTokenSourceView(address(this)).clock());
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
        if (_voteEligibilitySyncCount != 0 && _voteEligibilitySyncTimepoint != timepoint) {
            revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
        }
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (state.pendingAllowlist != address(0) && msg.sender == allowlistAddress()) {
            _registerPendingVestingSource(account, state.pendingAllowlist, true);
        }
        if (state.pendingVoteEligibilitySyncs[account]) {
            state.pendingVoteEligibilitySyncCursors[account] = type(uint256).max;
            emit VoteEligibilitySyncQueued(account, timepoint, _voteEligibilitySyncCount);
            return;
        }
        if (_voteEligibilitySyncCount == 0) _voteEligibilitySyncTimepoint = timepoint;
        state.pendingVoteEligibilitySyncs[account] = true;
        state.pendingVoteEligibilitySyncCursors[account] = type(uint256).max;
        ++_voteEligibilitySyncCount;
        emit VoteEligibilitySyncQueued(account, timepoint, _voteEligibilitySyncCount);
    }

    function processPendingVoteEligibilitySync(address account)
        external
        onlyFreshDelegateCall
        returns (bool complete)
    {
        BlocklistRotationStorage storage state = _blocklistRotationStorage();
        if (!state.pendingVoteEligibilitySyncs[account]) revert NoPendingVoteEligibilitySync(account);
        uint48 timepoint = _voteEligibilitySyncTimepoint;
        uint256 cursor = state.pendingVoteEligibilitySyncCursors[account];
        if (cursor == type(uint256).max) {
            _syncSource(account, address(0), false, false, timepoint);
            cursor = _vestingSourcesByBeneficiary[account].length();
        } else if (cursor != 0) {
            EnumerableSet.AddressSet storage sources = _vestingSourcesByBeneficiary[account];
            if (cursor > sources.length()) cursor = sources.length();
            if (cursor != 0) {
                _syncSource(sources.at(cursor - 1), address(0), false, false, timepoint);
                --cursor;
            }
        }
        complete = cursor == 0;
        if (complete) {
            delete state.pendingVoteEligibilitySyncs[account];
            delete state.pendingVoteEligibilitySyncCursors[account];
            --_voteEligibilitySyncCount;
            if (_voteEligibilitySyncCount == 0) _voteEligibilitySyncTimepoint = 0;
        } else {
            state.pendingVoteEligibilitySyncCursors[account] = cursor;
        }
        emit VoteEligibilitySyncProgress(account, cursor, complete);
    }

    function syncInitialVestingSources() external onlyFreshDelegateCall {
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
    }

    function sourceEligibilityForBlocklistModule(ForageTokenSourceEligibilityQuery calldata query)
        external
        view
        onlyFreshDelegateCall
        returns (ForageTokenSourceEligibility memory eligibility)
    {
        (eligibility.allowlisted, eligibility.systemAccount, eligibility.allowedUntil) =
            _allowlistAccountEligibility(query.allowlist, query.source);
        address beneficiary = query.registeredBeneficiary;
        if (beneficiary != address(0)) {
            if (!eligibility.systemAccount) {
                revert VestingSourceRegistrationRequired(query.source, beneficiary);
            }
            address registered;
            try IAllowlistVestingRegistry(query.allowlist).vestingSourceBeneficiary(query.source) returns (
                address value
            ) {
                registered = value;
            } catch {
                revert IAllowlist.AllowlistUnavailable();
            }
            if (registered != beneficiary) revert VestingSourceRegistrationRequired(query.source, beneficiary);
        }
        if (!query.registrationKnown && eligibility.systemAccount && query.source.code.length != 0) {
            address registered;
            try IAllowlistVestingRegistry(query.allowlist).vestingSourceBeneficiary(query.source) returns (
                address value
            ) {
                registered = value;
            } catch {
                revert IAllowlist.AllowlistUnavailable();
            }
            if (registered != address(0)) revert UnsupportedLegacyVestingBeneficiary(query.source);
            if (_readOptionalVestingBeneficiary(query.source) != address(0)) {
                revert UnsupportedLegacyVestingBeneficiary(query.source);
            }
        }
        if (beneficiary != address(0)) {
            if (query.rememberedBeneficiary != address(0) && query.rememberedBeneficiary != beneficiary) {
                revert IAllowlist.AllowlistUnavailable();
            }
            (bool beneficiaryAllowed, bool beneficiarySystem, uint64 beneficiaryUntil) =
                _allowlistAccountEligibility(query.allowlist, beneficiary);
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
        try IBlocklist(blocklist).isBlocked(query.source) returns (bool blocked) {
            eligibility.blocked = blocked;
        } catch {
            revert InvalidBlocklist(blocklist);
        }
        try IBlocklistVoteEligibility(blocklist).blockedUntil(query.source) returns (uint256 blockedUntil_) {
            eligibility.blockedUntil = blockedUntil_;
        } catch {
            revert InvalidBlocklist(blocklist);
        }
        if (beneficiary != address(0)) {
            bool beneficiaryBlocked;
            uint256 beneficiaryBlockedUntil;
            try IBlocklist(blocklist).isBlocked(beneficiary) returns (bool blocked) {
                beneficiaryBlocked = blocked;
            } catch {
                revert InvalidBlocklist(blocklist);
            }
            try IBlocklistVoteEligibility(blocklist).blockedUntil(beneficiary) returns (uint256 blockedUntil_) {
                beneficiaryBlockedUntil = blockedUntil_;
            } catch {
                revert InvalidBlocklist(blocklist);
            }
            eligibility.blocked = eligibility.blocked || beneficiaryBlocked;
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

    function _allowlistAccountEligibility(address allowlist_, address account)
        private
        view
        returns (bool allowed, bool systemAccount, uint64 allowedUntil)
    {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlist(allowlist_).isAllowed(account) returns (bool currentAllowed) {
            allowed = currentAllowed;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        try IAllowlist(allowlist_).isSystemAccount(account) returns (bool currentSystem) {
            systemAccount = currentSystem;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        try IAllowlist(allowlist_).allowedUntil(account) returns (uint64 currentUntil) {
            allowedUntil = currentUntil;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _rememberRegisteredBeneficiary(address source, address beneficiary) private {
        if (beneficiary == address(0)) return;
        if (_readOptionalVestingBeneficiary(source) != beneficiary) revert IAllowlist.AllowlistUnavailable();
        address previous = _vestingBeneficiaryBySource[source];
        if (previous == address(0)) _vestingBeneficiaryBySource[source] = beneficiary;
        else if (previous != beneficiary) revert IAllowlist.AllowlistUnavailable();
    }

    function _readStrictVestingBeneficiary(address source) private view returns (address beneficiary) {
        beneficiary = _readOptionalVestingBeneficiary(source);
        if (beneficiary == address(0)) revert UnsupportedLegacyVestingBeneficiary(source);
    }

    function _readOptionalVestingBeneficiary(address source) private view returns (address beneficiary) {
        uint32 selector = uint32(IVestingBeneficiarySource.beneficiary.selector);
        uint256 encoded;
        bool ok;
        uint256 returnSize;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, shl(224, selector))
            ok := staticcall(gas(), source, pointer, 4, pointer, 32)
            returnSize := returndatasize()
            if and(ok, eq(returnSize, 32)) { encoded := mload(pointer) }
        }
        if (!ok || returnSize != 32 || encoded == 0 || encoded > type(uint160).max) return address(0);
        return address(uint160(encoded));
    }

    function _requirePendingRegistration(address source) private view {
        address allowlist_ = allowlistAddress();
        (bool ok, bytes memory result) =
            allowlist_.staticcall(abi.encodeCall(IAllowlist.isVestingSourceRegistrationPending, (source)));
        if (!ok || result.length != 32) revert IAllowlist.AllowlistUnavailable();
        if (abi.decode(result, (bool))) {
            revert VestingSourceRegistrationRequired(source, _readOptionalVestingBeneficiary(source));
        }
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
        SourceSync memory sync = _prepareSourceSync(source, requestedDelegate, isDelegation, forceInventory);
        sync.timepoint = timepoint;
        if (!sync.relevant) return;
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        _syncActiveProjection(rotation, sync);
        _syncPendingProjection(rotation, sync);
    }

    function _prepareSourceSync(address source, address requestedDelegate, bool isDelegation, bool forceInventory)
        private
        returns (SourceSync memory sync)
    {
        if (source == address(0)) return sync;
        IForageTokenSourceView token = IForageTokenSourceView(address(this));
        sync.source = source;
        sync.newDelegate = isDelegation ? requestedDelegate : token.delegates(source);
        sync.votes = sync.newDelegate == address(0) ? 0 : token.balanceOf(source);
        (sync.systemAccount, sync.registeredBeneficiary) = _currentVestingSourceRegistration(source, token.allowlist());
        BlocklistRotationStorage storage rotation = _blocklistRotationStorage();
        Projection storage active = rotation.projections[rotation.activeGeneration];
        sync.relevant = forceInventory || sync.newDelegate != address(0) || rotation.sourceSeen[source]
            || active.sourceStates[source].delegatee != address(0) || active.processedSources[source]
            || _vestingBeneficiaryBySource[source] != address(0) || sync.registeredBeneficiary != address(0);
        if (!sync.relevant && rotation.pendingAllowlist != address(0)) {
            (bool candidateSystem, address candidateBeneficiary) =
                _currentVestingSourceRegistration(source, rotation.pendingAllowlist);
            sync.relevant = candidateSystem && candidateBeneficiary != address(0);
        }
        if (!sync.relevant) return sync;
        if (sync.newDelegate != address(0) && sync.votes != 0) _requireNoPendingRegistration(source);
        _rejectUnregisteredVestingSource(source, sync.systemAccount, sync.registeredBeneficiary);
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
            (pendingSync.systemAccount, pendingSync.registeredBeneficiary) =
                _currentVestingSourceRegistration(sync.source, allowlist_);
            _rememberRegisteredBeneficiary(sync.source, pendingSync.registeredBeneficiary);
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

    function _requireNoPendingRegistration(address source) private view {
        address allowlist_ = IForageTokenSourceView(address(this)).allowlist();
        (bool ok, bytes memory result) =
            allowlist_.staticcall(abi.encodeCall(IAllowlist.isVestingSourceRegistrationPending, (source)));
        if (!ok || result.length != 32) revert IAllowlist.AllowlistUnavailable();
        if (abi.decode(result, (bool))) {
            revert VestingSourceRegistrationRequired(source, _readStrictVestingBeneficiary(source));
        }
    }

    function _rejectUnregisteredVestingSource(address source, bool systemAccount, address registeredBeneficiary)
        private
        view
    {
        if (!systemAccount || registeredBeneficiary != address(0) || source.code.length == 0) return;
        uint32 selector = uint32(IVestingBeneficiarySource.beneficiary.selector);
        bool ok;
        uint256 returnSize;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, shl(224, selector))
            ok := staticcall(gas(), source, pointer, 4, pointer, 32)
            returnSize := returndatasize()
        }
        if (ok && returnSize != 0) revert UnsupportedLegacyVestingBeneficiary(source);
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
            sync.source, sync.registeredBeneficiary, sync.registeredBeneficiary != address(0), blocklist, allowlist_
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
        address beneficiary = _vestingBeneficiaryBySource[source];
        if (registeredBeneficiary != address(0)) beneficiary = registeredBeneficiary;
        if (beneficiary == address(0)) return;
        EnumerableSet.AddressSet storage sources =
            rotation.projections[generation].vestingSourcesByBeneficiary[beneficiary];
        if (registeredBeneficiary == address(0)) {
            sources.remove(source);
        } else if (!sources.contains(source)) {
            uint256 maximum = _maxVestingSourcesPerBeneficiary(allowlist_);
            uint256 count = sources.length();
            if (count >= maximum) revert TooManyVestingSources(beneficiary, count, maximum);
            sources.add(source);
        }
        _updateVestingSourceUnion(rotation, source, beneficiary);
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
