// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAllowlist, IAllowlistVoteEligibility, IVoteEligibilityObserver} from "./interfaces/IAllowlist.sol";
import {IBlocklist, IBlocklistVoteEligibility} from "./interfaces/IBlocklist.sol";
import "./AllowlistGatedUpgradeable.sol";
import {
    ForageTokenActiveProjection,
    ForageTokenPastProjection,
    ForageTokenRotationStatus,
    ForageTokenSourceEligibility,
    ForageTokenSourceEligibilityQuery,
    ForageTokenStateModule
} from "./modules/ForageTokenStateModule.sol";

contract ForageToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    Ownable2StepUpgradeable,
    ERC20VotesUpgradeable,
    UUPSUpgradeable,
    AllowlistGatedUpgradeable
{
    using Checkpoints for Checkpoints.Trace208;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Custom errors
    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedBurner(address caller);
    error UnauthorizedLocker(address caller);
    error InsufficientUnlockedBalance(address account, uint256 available, uint256 required);
    error InsufficientLockedBalance(address account, uint256 available, uint256 required);
    error DelegationBySignatureDisabled();
    error LockExemptAccount();
    error ArrayLengthMismatch();
    error RenounceOwnershipDisabled();
    error LockerStillAuthorized(); // OF-13-019: emergencyUnlock only works for deauthorized lockers
    error NoLockerBalance(); // OF-13-019: no balance to unlock
    error AccountHasActiveLocks(address account, uint256 locked); // OF-15-020: cannot exempt while locked
    error BlockedAddress(address account);
    error AllowanceChangeRequiresZero(address spender, uint256 currentAllowance, uint256 requestedAllowance);
    error LockBalanceExceedsBalance(address account, uint256 locked, uint256 balance);
    error TooManyAccountLockers(address account, uint256 maxLockers);
    error TooManyDelegateSources(address delegatee, uint256 count, uint256 maximum);
    error TooManyVestingSources(address beneficiary, uint256 count, uint256 maximum);
    error VestingSourceRegistrationRequired(address source, address beneficiary);
    error DelegateSourceTrackingFailed(address delegatee, address source);
    error TargetHasNoCode(address target);
    error InvalidBlocklist(address target);
    error UnauthorizedEligibilityObserver(address caller);
    error LegacyDelegateSourceIndexCorrupted(address delegatee, uint256 count, uint256 maximum);
    error EligibilityAccountingUnderflow(address delegatee, uint256 available, uint256 requested);
    error EligibilityAccountingOverflow(address delegatee, uint256 value);
    error LegacySourceInventoryUnavailable(address currentBlocklist, address proposedBlocklist);
    error BlocklistRotationInProgress(address pendingBlocklist);
    error BlocklistRotationUnavailable();
    error BlocklistRotationIncomplete(uint256 cursor, uint256 inventoryLength, uint256 processed, uint256 dirty);
    error AllowlistReindexInProgress(address pendingAllowlist);
    error AllowlistReindexUnavailable();
    error VestingSourceAllowlistHandoffIncomplete(uint256 pendingSources);
    error UnsupportedLegacyVestingBeneficiary(address source);
    error ProjectionGenerationExhausted();
    error InvalidProjectionGeneration(uint256 generation);
    error UnauthorizedTokenQuery(address caller);
    error VoteEligibilitySyncPending(uint48 timepoint);
    error NoPendingVoteEligibilitySync(address account);

    // Events
    event TokensReleased(address indexed to, uint256 amount);
    event ForageBurned(address indexed from, uint256 amount, address indexed burner);
    event AuthorizedBurnerUpdated(address indexed burner, bool authorized);
    event ForageLocked(address indexed account, uint256 amount, address indexed locker);
    event ForageUnlocked(address indexed account, uint256 amount, address indexed locker);
    event AuthorizedLockerUpdated(address indexed locker, bool authorized);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
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

    // Constants
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 10 ** 18;
    uint256 public constant TEAM_VESTING_ALLOCATION = 20_000_000 * 10 ** 18;
    uint256 public constant AGENT_ALLOCATION = 30_000_000 * 10 ** 18;
    uint256 public constant DEPOSITOR_ALLOCATION = 10_000_000 * 10 ** 18;
    uint256 public constant PARTNERSHIP_ALLOCATION = 40_000_000 * 10 ** 18;
    uint256 public constant FORAGE_TREASURY_ALLOCATION =
        AGENT_ALLOCATION + DEPOSITOR_ALLOCATION + PARTNERSHIP_ALLOCATION;
    uint256 public constant MAX_LOCKERS_PER_ACCOUNT = 32;
    uint256 public constant MAX_DELEGATE_SOURCES = 128;

    struct VoteSourceState {
        address delegatee;
        uint208 baseVotes;
        uint48 firstTransitionTime;
        int256 firstTransitionDelta;
        uint48 secondTransitionTime;
        int256 secondTransitionDelta;
    }

    // State
    mapping(address => bool) internal _authorizedBurners;
    mapping(address => bool) internal _authorizedLockers;
    mapping(address => uint256) internal _lockedBalances;
    mapping(address => bool) private _lockExempt;
    // OF-001: Per-locker namespace tracking
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

    /// @dev Reserved storage gap for future upgrades
    uint256[34] private __gap;

    ForageTokenStateModule private immutable _STATE_MODULE;

    modifier freshInventoryReady() {
        _requireFreshInventory();
        _;
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0 || _getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    // ── OF-001: Timestamp-based clock for Arbitrum L2 compatibility ──
    // OZ default uses block.number, but Arbitrum produces blocks at ~250ms,
    // making block-based governance periods too short (~30 min for 7200 blocks).
    // Timestamp-based clock enables governance periods specified in seconds.

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
        _STATE_MODULE = new ForageTokenStateModule();
    }

    function _delegateStateModule(bytes memory data) private {
        _delegateStateModuleCall(data);
    }

    function _delegateStateModuleInitialization(bytes memory data) private {
        _delegateStateModuleCall(data);
    }

    function _delegateStateModuleCall(bytes memory data) private {
        address target = address(_STATE_MODULE);
        assembly ("memory-safe") {
            let success := delegatecall(gas(), target, add(data, 32), mload(data), 0, 0)
            if iszero(success) {
                let size := returndatasize()
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    function _delegateStateModuleResult(bytes memory data) private returns (bytes memory result) {
        address target = address(_STATE_MODULE);
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

    function _delegateLiveProjection(address delegatee) private returns (ForageTokenActiveProjection memory) {
        return abi.decode(
            _delegateStateModuleResult(abi.encodeCall(ForageTokenStateModule.liveIndexedProjection, (delegatee))),
            (ForageTokenActiveProjection)
        );
    }

    function _readLiveProjection(address delegatee) private view returns (ForageTokenActiveProjection memory) {
        function(address) internal view returns (ForageTokenActiveProjection memory) reader;
        function(address) internal returns (ForageTokenActiveProjection memory) delegateReader = _delegateLiveProjection;
        assembly ("memory-safe") {
            reader := delegateReader
        }
        return reader(delegatee);
    }

    function _delegatePastProjection(address delegatee, uint256 timepoint)
        private
        returns (ForageTokenPastProjection memory)
    {
        return abi.decode(
            _delegateStateModuleResult(
                abi.encodeCall(ForageTokenStateModule.pastIndexedProjection, (delegatee, timepoint))
            ),
            (ForageTokenPastProjection)
        );
    }

    function _readPastProjection(address delegatee, uint256 timepoint)
        private
        view
        returns (ForageTokenPastProjection memory)
    {
        function(address, uint256) internal view returns (ForageTokenPastProjection memory) reader;
        function(address, uint256) internal returns (ForageTokenPastProjection memory) delegateReader =
            _delegatePastProjection;
        assembly ("memory-safe") {
            reader := delegateReader
        }
        return reader(delegatee, timepoint);
    }

    function _delegateSourceEligibilityForBlocklist(
        address source,
        address registeredBeneficiary,
        bool registrationKnown,
        address blocklist_,
        address allowlist_
    ) private returns (ForageTokenSourceEligibility memory) {
        ForageTokenSourceEligibilityQuery memory query = ForageTokenSourceEligibilityQuery({
            source: source,
            registeredBeneficiary: registeredBeneficiary,
            registrationKnown: registrationKnown,
            blocklist: blocklist_,
            allowlist: allowlist_,
            rememberedBeneficiary: _vestingBeneficiaryBySource[source]
        });
        return abi.decode(
            _delegateStateModuleResult(
                abi.encodeCall(ForageTokenStateModule.sourceEligibilityForBlocklistModule, (query))
            ),
            (ForageTokenSourceEligibility)
        );
    }

    function _readSourceEligibilityForBlocklist(
        address source,
        address registeredBeneficiary,
        bool registrationKnown,
        address blocklist_,
        address allowlist_
    ) private view returns (ForageTokenSourceEligibility memory) {
        function(address, address, bool, address, address) internal view returns (ForageTokenSourceEligibility memory)
            reader;
        function(address, address, bool, address, address) internal returns (ForageTokenSourceEligibility memory)
            delegateReader = _delegateSourceEligibilityForBlocklist;
        assembly ("memory-safe") {
            reader := delegateReader
        }
        return reader(source, registeredBeneficiary, registrationKnown, blocklist_, allowlist_);
    }

    function _delegateRotationStatus() private returns (ForageTokenRotationStatus memory) {
        return abi.decode(
            _delegateStateModuleResult(abi.encodeCall(ForageTokenStateModule.blocklistRotationStatus, ())),
            (ForageTokenRotationStatus)
        );
    }

    function _readRotationStatus() private view returns (ForageTokenRotationStatus memory status) {
        function() internal view returns (ForageTokenRotationStatus memory) reader;
        function() internal returns (ForageTokenRotationStatus memory) delegateReader = _delegateRotationStatus;
        assembly ("memory-safe") {
            reader := delegateReader
        }
        return reader();
    }

    function _requireFreshInventory() private view returns (ForageTokenRotationStatus memory status) {
        status = _readRotationStatus();
        if (!status.inventorySupported || status.epochCount == 0) {
            revert LegacySourceInventoryUnavailable(_blocklist, address(0));
        }
    }

    function _delegateStateModuleCalldata() private {
        address target = address(_STATE_MODULE);
        assembly ("memory-safe") {
            let size := calldatasize()
            let data := mload(0x40)
            calldatacopy(data, 0, size)
            let success := delegatecall(gas(), target, data, size, 0, 0)
            if iszero(success) {
                let resultSize := returndatasize()
                let result := mload(0x40)
                returndatacopy(result, 0, resultSize)
                revert(result, resultSize)
            }
        }
    }

    function initialize(address teamVestingAddress_, address forageTreasuryAddress_, address initialOwner_)
        external
        onlyDuringConstructionBeforeInitialization
        initializer
    {
        if (teamVestingAddress_ == address(0)) revert ZeroAddress();
        if (forageTreasuryAddress_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __ERC20_init("Forage Token", "FORAGE");
        __ERC20Permit_init("Forage Token");
        __ERC20Votes_init();
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        _initialTeamVestingSource = teamVestingAddress_;
        _initialTreasurySource = forageTreasuryAddress_;
        _delegateStateModuleInitialization(abi.encodeCall(ForageTokenStateModule.initializeSourceInventory, ()));
        _mint(teamVestingAddress_, TEAM_VESTING_ALLOCATION);
        _mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);
    }

    /// @notice OF-16-033: Dead code — no tokens at address(this) after initialization.
    /// All tokens are minted to specific addresses during initialize(). This function is
    /// effectively unreachable in production. Retained for backward compatibility.
    /// @dev DEPRECATED: Will be removed in a future upgrade.
    function releaseTokens(address to, uint256 amount) external onlyAllowedCaller onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _transfer(address(this), to, amount);
        emit TokensReleased(to, amount);
    }

    function delegate(address delegatee) public override freshInventoryReady onlyAllowedCaller {
        _requireVoteEligibilitySyncTimepoint();
        address account = _msgSender();
        _requireNotBlocked(account);
        if (delegatee != address(0)) {
            _requireNotBlocked(delegatee);
        }
        super.delegate(delegatee);
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncDelegation, (account, delegatee)));
    }

    function getVotes(address account) public view override returns (uint256) {
        _requireFreshInventory();
        _requireNoPendingVoteEligibilitySync();
        uint256 checkpointVotes = super.getVotes(account);
        address blocklist_ = _blocklist;
        if (!_isDelegateeEligibleNow(account, blocklist_)) return 0;
        ForageTokenActiveProjection memory projection = _readLiveProjection(account);
        uint256 trackedVotes = projection.indexedVotes;
        return trackedVotes < checkpointVotes ? trackedVotes : checkpointVotes;
    }

    function getPastVotes(address account, uint256 timepoint) public view override returns (uint256) {
        _requireNoPendingVoteEligibilitySync();
        uint256 checkpointVotes = super.getPastVotes(account, timepoint);
        ForageTokenPastProjection memory projection = _readPastProjection(account, timepoint);
        if (_wasBlockedAt(account, timepoint, projection.blocklist, projection.allowlist)) return 0;
        uint256 trackedVotes = projection.indexedVotes;
        return trackedVotes < checkpointVotes ? trackedVotes : checkpointVotes;
    }

    function _isDelegateeEligibleNow(address delegatee, address blocklist_) private view returns (bool) {
        if (blocklist_ == address(0)) return true;
        try IBlocklist(blocklist_).isBlocked(delegatee) returns (bool blocked) {
            return !blocked;
        } catch {
            revert InvalidBlocklist(blocklist_);
        }
    }

    function delegateBySig(
        address, // delegatee
        uint256, // nonce
        uint256, // expiry
        uint8, // v
        bytes32, // r
        bytes32 // s
    ) public pure override {
        revert DelegationBySignatureDisabled();
    }

    function syncVoteEligibility(address account) external {
        ForageTokenRotationStatus memory status = _requireFreshInventory();
        bool observer = msg.sender == allowlist() || msg.sender == _blocklist || msg.sender == status.pendingBlocklist
            || msg.sender == status.pendingAllowlist;
        if (observer) {
            _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncVoteEligibility, (account)));
            return;
        }
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.processPendingVoteEligibilitySync, (account)));
    }

    /// @notice OF-16-003: CRITICAL INTEGRATION REQUIREMENT — When burn causes balance < locked,
    /// per-locker balances are pro-rata reduced WITHOUT notification to the locking contracts.
    /// Lockers' on-chain state becomes stale (they believe they hold more locked tokens than exist).
    /// ForageUnlocked events are emitted for off-chain monitoring but lockers get no callback.
    /// Any contract that locks FORAGE via setAuthorizedLocker MUST either:
    ///   (a) query ForageToken.lockerBalances(account, address(this)) before acting on assumed lock amounts, or
    ///   (b) monitor ForageUnlocked events indexed by their address to detect pro-rata reductions.
    /// Failure to do so may allow users to perform actions requiring more locked tokens than actually exist.
    function burn(address from, uint256 amount) external freshInventoryReady onlyAllowedCaller {
        if (!_authorizedBurners[msg.sender]) revert UnauthorizedBurner(msg.sender);
        _requireNotBlocked(msg.sender);
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(from);

        _delegateStateModuleCalldata();

        _burn(from, amount);
        emit ForageBurned(from, amount, msg.sender);
    }

    function setAuthorizedBurner(address burner_, bool authorized_)
        external
        freshInventoryReady
        onlyAllowedCaller
        onlyOwner
    {
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.setAuthorizedBurner, (burner_, authorized_)));
    }

    function approve(address spender, uint256 value) public override freshInventoryReady returns (bool) {
        address owner_ = _msgSender();
        _requireNotBlocked(owner_);
        if (value != 0) {
            _requireNotBlocked(spender);
            _requireExplicitAllowanceReset(owner_, spender, value);
        }
        bool approved = super.approve(spender, value);
        if (approved) _explicitZeroResetRequired[owner_][spender] = value != 0;
        return approved;
    }

    function transferFrom(address from, address to, uint256 value) public override freshInventoryReady returns (bool) {
        _requireNotBlocked(msg.sender);
        return super.transferFrom(from, to, value);
    }

    function lock(address account, uint256 amount) external freshInventoryReady onlyAllowedCaller {
        if (!_authorizedLockers[msg.sender]) revert UnauthorizedLocker(msg.sender);
        _requireNotBlocked(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(account);
        if (_lockExempt[account]) revert LockExemptAccount();

        uint256 unlocked = balanceOf(account) - _lockedBalances[account];
        if (unlocked < amount) revert InsufficientUnlockedBalance(account, unlocked, amount);

        _delegateStateModuleCalldata();
    }

    function unlock(address account, uint256 amount) external freshInventoryReady onlyAllowedCaller {
        if (!_authorizedLockers[msg.sender]) revert UnauthorizedLocker(msg.sender);
        _requireNotBlocked(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(account);

        _delegateStateModuleCalldata();
    }

    /// @notice Set whether an address is authorized to lock/unlock FORAGE on behalf of users.
    /// @dev OF-L05 WARNING: Deauthorizing a locker that has active FORAGE locks will strand those
    /// locks permanently — the deauthorized contract can no longer call unlock(). Before deauthorizing,
    /// ensure all active locks by this locker are cleared via unlockBatch() or direct unlock() calls.
    /// Recovery procedure if locks are stranded: re-authorize the locker temporarily, call
    /// unlockBatch() for all affected accounts, then deauthorize again.
    function setAuthorizedLocker(address locker_, bool authorized_)
        external
        freshInventoryReady
        onlyAllowedCaller
        onlyOwner
    {
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.setAuthorizedLocker, (locker_, authorized_)));
    }

    function setLockExempt(address account, bool exempt) external freshInventoryReady onlyAllowedCaller onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (exempt && _lockedBalances[account] > 0) {
            revert AccountHasActiveLocks(account, _lockedBalances[account]);
        }
        _delegateStateModuleCalldata();
    }

    /// @notice OF-13-019: Emergency unlock for FORAGE balances stranded behind deauthorized lockers.
    /// @dev Only works when the locker has been deauthorized (_authorizedLockers[locker] == false).
    /// Reads _lockerBalances[account][locker], decrements _lockedBalances[account], clears the
    /// per-locker balance, removes locker from _accountLockers[account], and emits ForageUnlocked.
    function emergencyUnlock(address account, address locker)
        external
        freshInventoryReady
        onlyAllowedCaller
        onlyOwner
    {
        if (account == address(0)) revert ZeroAddress();
        if (locker == address(0)) revert ZeroAddress();
        _requireNotBlocked(account);
        if (_authorizedLockers[locker]) revert LockerStillAuthorized();
        _delegateStateModuleCalldata();
    }

    function unlockBatch(address[] calldata accounts, uint256[] calldata amounts)
        external
        freshInventoryReady
        onlyAllowedCaller
    {
        if (!_authorizedLockers[msg.sender]) revert UnauthorizedLocker(msg.sender);
        _requireNotBlocked(msg.sender);
        // OF-L23: Use semantically correct error for array length mismatch
        if (accounts.length != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert ZeroAmount();
            _requireNotBlocked(accounts[i]);
            _delegateStateModule(abi.encodeCall(ForageTokenStateModule.unlock, (accounts[i], amounts[i])));
        }
    }

    function lockedBalance(address account) external view returns (uint256) {
        return _lockedBalances[account];
    }

    /// @notice Per-locker balance for a specific locker on an account.
    function lockerBalance(address account, address locker) external view returns (uint256) {
        return _lockerBalances[account][locker];
    }

    /// @notice List of all lockers with active locks on an account.
    function accountLockers(address account) external view returns (address[] memory) {
        return _accountLockers[account].values();
    }

    /// @notice Check if an address is an authorized locker.
    /// @dev Enables on-chain verification of deployment wiring (OF-002).
    function isAuthorizedLocker(address locker) external view returns (bool) {
        return _authorizedLockers[locker];
    }

    function setBlocklist(address blocklist_) external freshInventoryReady onlyAllowedCaller onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        ForageTokenRotationStatus memory status = _readRotationStatus();
        if (blocklist_ == address(0)) revert ZeroAddress();
        _requireValidBlocklist(blocklist_);
        address oldBlocklist = _blocklist;
        if (oldBlocklist == blocklist_) {
            _registerBlocklistObserver(blocklist_);
            emit BlocklistSet(oldBlocklist, blocklist_);
            return;
        }
        bool freshEmptyInventory = status.inventorySupported && !status.rotationActive && oldBlocklist == address(0)
            && status.activeGeneration == 0 && status.inventoryLength == 0;
        if (freshEmptyInventory) {
            _registerBlocklistObserver(blocklist_);
            _delegateStateModule(abi.encodeCall(ForageTokenStateModule.bindInitialBlocklist, (blocklist_, clock())));
            emit BlocklistSet(oldBlocklist, blocklist_);
            return;
        }
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.beginBlocklistRotation, (blocklist_)));
        _registerBlocklistObserver(blocklist_);
    }

    function processBlocklistRotation() external freshInventoryReady onlyAllowedCaller onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.processBlocklistRotation, ()));
    }

    function activateBlocklistRotation() external freshInventoryReady onlyAllowedCaller onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        ForageTokenRotationStatus memory status = _readRotationStatus();
        if (!status.rotationActive) revert BlocklistRotationUnavailable();
        _unregisterBlocklistObserverStrict(status.activeBlocklist);
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.activateBlocklistRotation, ()));
        emit BlocklistSet(status.activeBlocklist, status.pendingBlocklist);
    }

    function blocklistRotationStatus() external view returns (ForageTokenRotationStatus memory) {
        return _requireFreshInventory();
    }

    /// @dev Configuration-time code+interface probe (mirror of DelegatingVestingWallet's
    /// `_requireValidBlocklist`): a blocklist that cannot answer `isBlocked`/`wasBlockedAt` would
    /// silently brick every governance and FORAGE transfer path that consults it.
    function _requireValidBlocklist(address blocklist_) private view {
        if (blocklist_.code.length == 0) revert TargetHasNoCode(blocklist_);
        try IBlocklist(blocklist_).isBlocked(address(this)) {}
        catch {
            revert InvalidBlocklist(blocklist_);
        }
        _readHistoricalBlocklistBoolean(blocklist_, address(this), block.timestamp, IBlocklist.wasBlockedAt.selector);
        _wasCheckpointBlockedAt(blocklist_, address(this), block.timestamp);
        try IBlocklistVoteEligibility(blocklist_).supportsVoteEligibilityObserver() returns (bool supported) {
            if (!supported) revert InvalidBlocklist(blocklist_);
        } catch {
            revert InvalidBlocklist(blocklist_);
        }
        try IBlocklistVoteEligibility(blocklist_).blockedUntil(address(this)) {}
        catch {
            revert InvalidBlocklist(blocklist_);
        }
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        if (!_isInitializing()) _requireFreshInventory();
        if (!_isInitializing()) _requireVoteEligibilitySyncTimepoint();
        // Lock enforcement: check unlocked balance before transfer
        // Skip on mints (from == 0), burns (to == 0), contract self-transfer, and lock-exempt senders
        if (from != address(0) && to != address(0) && from != address(this) && !_lockExempt[from]) {
            uint256 fromBalance = balanceOf(from);
            uint256 locked = _lockedBalances[from];
            uint256 unlocked = fromBalance - locked;
            if (unlocked < value) {
                revert InsufficientUnlockedBalance(from, unlocked, value);
            }
        }
        if (from != address(0)) {
            _requireNotBlocked(from);
        }
        if (to != address(0)) {
            _requireNotBlocked(to);
        }

        super._update(from, to, value);

        if (!_isInitializing()) {
            if (from != address(0)) {
                _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncSourceFromToken, (from)));
            }
            if (to != address(0)) {
                _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncSourceFromToken, (to)));
            }
        }
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        freshInventoryReady
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    function transferOwnership(address newOwner) public override freshInventoryReady onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override freshInventoryReady onlyAllowedCaller {
        super.acceptOwnership();
    }

    function permit(address owner_, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        override
        freshInventoryReady
    {
        _requireNotBlocked(owner_);
        if (value != 0) {
            _requireNotBlocked(spender);
            _requireExplicitAllowanceReset(owner_, spender, value);
        }
        super.permit(owner_, spender, value, deadline, v, r, s);
        _explicitZeroResetRequired[owner_][spender] = value != 0;
    }

    function _requireExplicitAllowanceReset(address owner_, address spender, uint256 value) private view {
        uint256 currentAllowance = allowance(owner_, spender);
        if (currentAllowance != 0 || _explicitZeroResetRequired[owner_][spender]) {
            revert AllowanceChangeRequiresZero(spender, currentAllowance, value);
        }
    }

    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }

    function setAllowlist(address allowlist_) external freshInventoryReady onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        address oldAllowlist = allowlist();
        if (oldAllowlist == allowlist_) {
            _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncInitialVestingSources, ()));
            return;
        }
        ForageTokenRotationStatus memory rotation = _requireFreshInventory();
        if (rotation.rotationActive || rotation.allowlistReindexActive) {
            address pending = rotation.allowlistReindexActive ? rotation.pendingAllowlist : rotation.pendingBlocklist;
            revert AllowlistReindexInProgress(pending);
        }
        _validateAllowlistTransition(allowlist_);
        if (_blocklist == address(0)) {
            _unregisterAllowlistObserver(oldAllowlist);
            _transitionAllowlist(allowlist_);
            _registerAllowlistObserver(allowlist_);
            _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncInitialVestingSources, ()));
            return;
        }
        if (!_supportsAllowlistVoteEligibility(allowlist_)) revert IAllowlist.AllowlistUnavailable();
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.beginAllowlistReindex, (allowlist_)));
        _registerAllowlistObserver(allowlist_);
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncInitialVestingSources, ()));
    }

    function processAllowlistReindex() external freshInventoryReady onlyAllowedCaller onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.processAllowlistReindex, ()));
    }

    function activateAllowlistReindex() external freshInventoryReady onlyAllowedCaller onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        ForageTokenRotationStatus memory status = _readRotationStatus();
        address nextAllowlist = status.pendingAllowlist;
        if (!status.allowlistReindexActive || nextAllowlist == address(0)) revert AllowlistReindexUnavailable();
        address oldAllowlist = allowlist();
        _unregisterAllowlistObserver(oldAllowlist);
        _transitionAllowlist(nextAllowlist);
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.activateAllowlistReindex, ()));
    }

    function cancelAllowlistReindex() external freshInventoryReady onlyAllowedCaller onlyOwner {
        _requireNoPendingVoteEligibilitySync();
        ForageTokenRotationStatus memory status = _readRotationStatus();
        address candidateAllowlist = status.pendingAllowlist;
        if (!status.allowlistReindexActive || candidateAllowlist == address(0)) revert AllowlistReindexUnavailable();
        _unregisterAllowlistObserver(candidateAllowlist);
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.cancelAllowlistReindex, ()));
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        _requireFreshInventory();
        _requireNoPendingVoteEligibilitySync();
    }

    function _requireNoPendingVoteEligibilitySync() private view {
        if (_voteEligibilitySyncCount != 0) revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
    }

    function _requireVoteEligibilitySyncTimepoint() private view {
        if (_voteEligibilitySyncCount != 0 && clock() != _voteEligibilitySyncTimepoint) {
            revert VoteEligibilitySyncPending(_voteEligibilitySyncTimepoint);
        }
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0) && !_isInitializing()) revert InvalidBlocklist(address(0));
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function sourceEligibilityForBlocklist(
        address source,
        address registeredBeneficiary,
        bool registrationKnown,
        address blocklist_,
        address allowlist_
    ) external view returns (ForageTokenSourceEligibility memory eligibility) {
        if (msg.sender != address(this)) revert UnauthorizedTokenQuery(msg.sender);
        return
            _readSourceEligibilityForBlocklist(source, registeredBeneficiary, registrationKnown, blocklist_, allowlist_);
    }

    function _wasCheckpointBlockedAt(address blocklist_, address account, uint256 timepoint)
        private
        view
        returns (bool)
    {
        return _readHistoricalBlocklistBoolean(blocklist_, account, timepoint, IBlocklist.wasBlockedAt.selector);
    }

    function _readHistoricalBlocklistBoolean(address blocklist_, address account, uint256 timepoint, bytes4 selector)
        private
        view
        returns (bool)
    {
        (bool ok, bytes memory data) = blocklist_.staticcall(abi.encodeWithSelector(selector, account, timepoint));
        if (!ok || data.length != 32) revert InvalidBlocklist(blocklist_);
        uint256 result;
        assembly ("memory-safe") {
            result := mload(add(data, 32))
        }
        if (result > 1) revert InvalidBlocklist(blocklist_);
        return result == 1;
    }

    function _supportsAllowlistVoteEligibility(address allowlist_) private view returns (bool) {
        (bool ok, bytes memory data) = allowlist_.staticcall(
            abi.encodeWithSelector(IAllowlistVoteEligibility.supportsVoteEligibilityObserver.selector)
        );
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function _isSystemAccountAt(address account, uint256 timepoint, address allowlist_) private view returns (bool) {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVoteEligibility(allowlist_).isSystemAccountAt(account, timepoint) returns (bool systemAccount_) {
            return systemAccount_;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _wasBlockedAt(address account, uint256 timepoint, address provider, address allowlist_)
        private
        view
        returns (bool)
    {
        if (provider == address(0)) return false;
        if (_wasCheckpointBlockedAt(provider, account, timepoint)) return true;
        if (!_isSystemAccountAt(account, timepoint, allowlist_)) return false;
        address beneficiary = _vestingBeneficiaryBySource[account];
        return beneficiary != address(0) && _wasCheckpointBlockedAt(provider, beneficiary, timepoint);
    }

    function _registerAllowlistObserver(address allowlist_) private {
        if (allowlist_ == address(0)) return;
        _isSystemAccountAt(address(this), clock(), allowlist_);
        if (!_supportsAllowlistVoteEligibility(allowlist_)) return;
        bool isSystemAccount_;
        try IAllowlist(allowlist_).isSystemAccount(address(this)) returns (bool value) {
            isSystemAccount_ = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (!isSystemAccount_) revert IAllowlist.AllowlistUnavailable();
        IAllowlistVoteEligibility(allowlist_).registerVoteEligibilityObserver();
    }

    function _unregisterAllowlistObserver(address allowlist_) private {
        if (allowlist_ == address(0) || !_supportsAllowlistVoteEligibility(allowlist_)) return;
        IAllowlistVoteEligibility(allowlist_).unregisterVoteEligibilityObserver();
    }

    function _registerBlocklistObserver(address blocklist_) private {
        IBlocklistVoteEligibility(blocklist_).registerVoteEligibilityObserver();
    }

    function _unregisterBlocklistObserverStrict(address blocklist_) private {
        if (blocklist_ == address(0)) return;
        try IBlocklistVoteEligibility(blocklist_).supportsVoteEligibilityObserver() returns (bool supported) {
            if (!supported) revert InvalidBlocklist(blocklist_);
        } catch {
            revert InvalidBlocklist(blocklist_);
        }
        try IBlocklistVoteEligibility(blocklist_).unregisterVoteEligibilityObserver() {}
        catch {
            revert InvalidBlocklist(blocklist_);
        }
    }
}
