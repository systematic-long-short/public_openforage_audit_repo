// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {
    IAllowlist,
    IAllowlistVoteEligibility,
    IVestingBeneficiarySource,
    IVoteEligibilityObserver
} from "./interfaces/IAllowlist.sol";
import {IBlocklist, IBlocklistVoteEligibility} from "./interfaces/IBlocklist.sol";
import "./AllowlistGatedUpgradeable.sol";
import {ForageTokenStateModule, ForageTokenStateUpdate} from "./modules/ForageTokenStateModule.sol";

interface IAllowlistVestingSourceLimit {
    function maxVestingSourcesPerBeneficiary() external view returns (uint256);
}

interface IAllowlistVestingSourceRegistry {
    function vestingSourceBeneficiary(address source) external view returns (address);
}

contract ForageToken is
    Initializable,
    ERC20Upgradeable,
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

    // Events
    event TokensReleased(address indexed to, uint256 amount);
    event ForageBurned(address indexed from, uint256 amount, address indexed burner);
    event AuthorizedBurnerUpdated(address indexed burner, bool authorized);
    event ForageLocked(address indexed account, uint256 amount, address indexed locker);
    event ForageUnlocked(address indexed account, uint256 amount, address indexed locker);
    event AuthorizedLockerUpdated(address indexed locker, bool authorized);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);

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

    struct VoteTransitions {
        uint48 firstTime;
        int256 firstDelta;
        uint48 secondTime;
        int256 secondDelta;
    }

    struct SourceEligibility {
        bool allowlisted;
        bool systemAccount;
        bool blocked;
        uint64 allowedUntil;
        uint256 blockedUntil;
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

    /// @dev Reserved storage gap for future upgrades
    uint256[37] private __gap;

    ForageTokenStateModule private immutable _STATE_MODULE;

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

    function _delegateEligibilityTransitionPrefix(address delegatee, uint256 timepoint)
        private
        returns (uint256 value)
    {
        bytes32 selectorWord = bytes32(bytes4(keccak256("eligibilityTransitionPrefix(address,uint256)")));
        address target = address(_STATE_MODULE);
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, selectorWord)
            mstore(add(input, 4), delegatee)
            mstore(add(input, 36), timepoint)
            let success := delegatecall(gas(), target, input, 68, 0, 0)
            let size := returndatasize()
            if iszero(success) {
                let result := mload(0x40)
                returndatacopy(result, 0, size)
                revert(result, size)
            }
            if iszero(eq(size, 32)) { revert(0, 0) }
            returndatacopy(input, 0, 32)
            value := mload(input)
        }
    }

    function _readEligibilityTransitionPrefixWord(address delegatee, uint256 timepoint)
        private
        view
        returns (uint256 value)
    {
        function(address, uint256) internal view returns (uint256) readOnly;
        function(address, uint256) internal returns (uint256) delegateReader = _delegateEligibilityTransitionPrefix;
        assembly ("memory-safe") {
            readOnly := delegateReader
        }
        value = readOnly(delegatee, timepoint);
    }

    function initialize(address teamVestingAddress_, address forageTreasuryAddress_, address initialOwner_)
        external
        initializer
    {
        if (teamVestingAddress_ == address(0)) revert ZeroAddress();
        if (forageTreasuryAddress_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __ERC20_init("Forage Token", "FORAGE");
        __EIP712_init("Forage Token", "1");
        __ERC20Votes_init();
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        _initialTeamVestingSource = teamVestingAddress_;
        _initialTreasurySource = forageTreasuryAddress_;
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

    function delegate(address delegatee) public override onlyAllowedCaller {
        address account = _msgSender();
        _requireNotBlocked(account);
        if (delegatee != address(0)) {
            _requireNotBlocked(delegatee);
        }
        address oldDelegate = delegates(account);
        super.delegate(delegatee);
        _setDelegateSource(account, oldDelegate, delegatee);
    }

    function getVotes(address account) public view override returns (uint256) {
        uint256 checkpointVotes = super.getVotes(account);
        if (!_isDelegateeEligibleNow(account)) return 0;

        uint256 trackedVotes = _liveLegacyEligibleVotes(account) + _liveIndexedEligibleVotes(account);
        return trackedVotes < checkpointVotes ? trackedVotes : checkpointVotes;
    }

    function getPastVotes(address account, uint256 timepoint) public view override returns (uint256) {
        if (msg.sender == address(this)) return _readEligibilityTransitionPrefixWord(account, timepoint);

        uint256 checkpointVotes = super.getPastVotes(account, timepoint);
        if (!_isDelegateeEligibleAt(account, timepoint)) return 0;

        uint256 trackedVotes =
            _pastLegacyEligibleVotes(account, timepoint) + _pastIndexedEligibleVotes(account, timepoint);
        return trackedVotes < checkpointVotes ? trackedVotes : checkpointVotes;
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

    /// @notice Seeds delegate-source trackers for delegations that existed before this implementation.
    /// @dev Pre-upgrade delegated votes fail closed while source tracking is missing or incomplete.
    /// Sources are intentionally allowed to already be blocked.
    function syncDelegateSources(address[] calldata sources) external onlyAllowedCaller onlyOwner {
        for (uint256 i; i < sources.length;) {
            if (sources[i] == address(0)) revert ZeroAddress();
            _syncDelegateSourceContribution(sources[i]);
            unchecked {
                ++i;
            }
        }
    }

    function syncVoteEligibility(address account) external {
        if (msg.sender != allowlist() && msg.sender != _blocklist) {
            revert UnauthorizedEligibilityObserver(msg.sender);
        }
        _syncDelegateSourceContribution(account);
        _syncVestingSources(account);
    }

    /// @notice OF-16-003: CRITICAL INTEGRATION REQUIREMENT — When burn causes balance < locked,
    /// per-locker balances are pro-rata reduced WITHOUT notification to the locking contracts.
    /// Lockers' on-chain state becomes stale (they believe they hold more locked tokens than exist).
    /// ForageUnlocked events are emitted for off-chain monitoring but lockers get no callback.
    /// Any contract that locks FORAGE via setAuthorizedLocker MUST either:
    ///   (a) query ForageToken.lockerBalances(account, address(this)) before acting on assumed lock amounts, or
    ///   (b) monitor ForageUnlocked events indexed by their address to detect pro-rata reductions.
    /// Failure to do so may allow users to perform actions requiring more locked tokens than actually exist.
    function burn(address from, uint256 amount) external onlyAllowedCaller {
        if (!_authorizedBurners[msg.sender]) revert UnauthorizedBurner(msg.sender);
        _requireNotBlocked(msg.sender);
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(from);

        _delegateStateModuleCalldata();

        _burn(from, amount);
        emit ForageBurned(from, amount, msg.sender);
    }

    function setAuthorizedBurner(address burner_, bool authorized_) external onlyAllowedCaller onlyOwner {
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.setAuthorizedBurner, (burner_, authorized_)));
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        address owner_ = _msgSender();
        _requireNotBlocked(owner_);
        if (value != 0) {
            _requireNotBlocked(spender);
        }
        uint256 currentAllowance = allowance(owner_, spender);
        if (currentAllowance != 0 && value != 0) {
            revert AllowanceChangeRequiresZero(spender, currentAllowance, value);
        }
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _requireNotBlocked(msg.sender);
        return super.transferFrom(from, to, value);
    }

    function lock(address account, uint256 amount) external onlyAllowedCaller {
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

    function unlock(address account, uint256 amount) external onlyAllowedCaller {
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
    function setAuthorizedLocker(address locker_, bool authorized_) external onlyAllowedCaller onlyOwner {
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.setAuthorizedLocker, (locker_, authorized_)));
    }

    function setLockExempt(address account, bool exempt) external onlyAllowedCaller onlyOwner {
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
    function emergencyUnlock(address account, address locker) external onlyAllowedCaller onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (locker == address(0)) revert ZeroAddress();
        _requireNotBlocked(account);
        if (_authorizedLockers[locker]) revert LockerStillAuthorized();
        _delegateStateModuleCalldata();
    }

    function unlockBatch(address[] calldata accounts, uint256[] calldata amounts) external onlyAllowedCaller {
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

    function setBlocklist(address blocklist_) external onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        _requireValidBlocklist(blocklist_);
        address oldBlocklist = _blocklist;
        if (oldBlocklist != blocklist_) _unregisterBlocklistObserver(oldBlocklist);
        _delegateStateModuleCalldata();
        _registerBlocklistObserver(blocklist_);
        emit BlocklistSet(oldBlocklist, blocklist_);
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
        _wasEffectivelyBlockedAt(blocklist_, address(this), block.timestamp);
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
            _syncDelegateSourceContribution(from);
            _syncDelegateSourceContribution(to);
        }
    }

    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override onlyAllowedCaller {
        super.upgradeToAndCall(newImplementation, data);
    }

    function transferOwnership(address newOwner) public override onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override onlyAllowedCaller {
        super.acceptOwnership();
    }

    function setAllowlist(address allowlist_) external onlyOwner {
        address oldAllowlist = allowlist();
        if (oldAllowlist != allowlist_) {
            _validateAllowlistTransition(allowlist_);
            _unregisterAllowlistObserver(oldAllowlist);
        }
        _transitionAllowlist(allowlist_);
        _registerAllowlistObserver(allowlist_);
        _syncInitialVestingSources();
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0) && !_isInitializing()) revert InvalidBlocklist(address(0));
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _setDelegateSource(address source, address oldDelegate, address newDelegate) internal {
        uint256 votes = balanceOf(source);
        address registeredBeneficiary = _prepareDelegateSourceUpdate(source, newDelegate, votes);
        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.prepareDelegateSourceChange, (source, oldDelegate)));
        _applyDelegateSourceUpdate(source, newDelegate, votes, true, registeredBeneficiary);
    }

    function _syncDelegateSourceContribution(address source) internal {
        if (source == address(0)) return;
        address delegatee = delegates(source);
        uint256 votes;
        if (delegatee != address(0)) votes = balanceOf(source);
        address registeredBeneficiary = _prepareDelegateSourceUpdate(source, delegatee, votes);
        _applyDelegateSourceUpdate(source, delegatee, votes, false, registeredBeneficiary);
    }

    function _prepareDelegateSourceUpdate(address source, address newDelegate, uint256 votes)
        private
        returns (address registeredBeneficiary)
    {
        if (newDelegate != address(0) && votes != 0) _requireNoPendingVestingSourceRegistration(source);
        return _rememberVestingBeneficiary(source);
    }

    function _requireNoPendingVestingSourceRegistration(address source) private view {
        address allowlist_ = allowlist();
        (bool ok, bytes memory data) =
            allowlist_.staticcall(abi.encodeCall(IAllowlist.isVestingSourceRegistrationPending, (source)));
        if (!ok || data.length != 32) revert IAllowlist.AllowlistUnavailable();
        if (abi.decode(data, (bool))) {
            revert VestingSourceRegistrationRequired(source, _readVestingBeneficiary(source));
        }
    }

    function _applyDelegateSourceUpdate(
        address source,
        address newDelegate,
        uint256 votes,
        bool isDelegation,
        address registeredBeneficiary
    ) private {
        ForageTokenStateUpdate memory update;
        update.source = source;
        update.newDelegate = newDelegate;
        update.votes = votes;
        if (newDelegate != address(0) && votes != 0) {
            update.unindexedLegacyVestingSource = _isUnindexedLegacyVestingSource(source);
            if (!update.unindexedLegacyVestingSource && !_historicalDelegateSources[newDelegate].contains(source)) {
                SourceEligibility memory eligibility = _sourceEligibility(source, registeredBeneficiary, true);
                update.newBaseVotes = eligibility.allowlisted && !eligibility.blocked ? votes : 0;
                VoteTransitions memory transitions = _planVoteTransitions(eligibility, votes);
                update.firstTransitionTime = transitions.firstTime;
                update.firstTransitionDelta = transitions.firstDelta;
                update.secondTransitionTime = transitions.secondTime;
                update.secondTransitionDelta = transitions.secondDelta;
            }
        }

        _delegateStateModule(abi.encodeCall(ForageTokenStateModule.applyDelegateSourceUpdate, (update, isDelegation)));
        address beneficiary = _vestingBeneficiaryBySource[source];
        if (beneficiary == address(0) || update.unindexedLegacyVestingSource) return;
        uint256 maximum;
        if (
            registeredBeneficiary != address(0) && newDelegate != address(0) && votes != 0
                && !_vestingSourcesByBeneficiary[beneficiary].contains(source)
        ) {
            maximum = _maxVestingSourcesPerBeneficiary();
        }
        _delegateStateModule(
            abi.encodeCall(
                ForageTokenStateModule.updateRegisteredVestingSourceMembership,
                (source, newDelegate, votes, maximum, registeredBeneficiary != address(0))
            )
        );
    }

    function _sourceEligibility(address source, address registeredBeneficiary, bool registrationKnown)
        private
        view
        returns (SourceEligibility memory eligibility)
    {
        (eligibility.allowlisted, eligibility.systemAccount, eligibility.allowedUntil) =
            _allowlistAccountEligibility(source);
        address beneficiary_ = registeredBeneficiary;
        if (!registrationKnown && eligibility.systemAccount && source.code.length != 0) {
            beneficiary_ = _registeredVestingSourceBeneficiary(allowlist(), source);
        }
        if (beneficiary_ != address(0)) {
            address rememberedBeneficiary = _vestingBeneficiaryBySource[source];
            if (rememberedBeneficiary != address(0) && rememberedBeneficiary != beneficiary_) {
                revert IAllowlist.AllowlistUnavailable();
            }
            (bool beneficiaryAllowed, bool beneficiarySystem, uint64 beneficiaryUntil) =
                _allowlistAccountEligibility(beneficiary_);
            bool sourceSystem = eligibility.systemAccount;
            eligibility.allowlisted = eligibility.allowlisted && beneficiaryAllowed;
            eligibility.systemAccount = sourceSystem && beneficiarySystem;
            if (sourceSystem) {
                eligibility.allowedUntil = beneficiaryUntil;
            } else if (!beneficiarySystem && beneficiaryUntil < eligibility.allowedUntil) {
                eligibility.allowedUntil = beneficiaryUntil;
            }
        }

        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) return eligibility;
        try IBlocklist(blocklist_).isBlocked(source) returns (bool blocked) {
            eligibility.blocked = blocked;
        } catch {
            revert InvalidBlocklist(blocklist_);
        }
        try IBlocklistVoteEligibility(blocklist_).blockedUntil(source) returns (uint256 blockedUntil_) {
            eligibility.blockedUntil = blockedUntil_;
        } catch {
            revert InvalidBlocklist(blocklist_);
        }
        if (beneficiary_ != address(0)) {
            bool beneficiaryBlocked;
            uint256 beneficiaryBlockedUntil;
            try IBlocklist(blocklist_).isBlocked(beneficiary_) returns (bool blocked) {
                beneficiaryBlocked = blocked;
            } catch {
                revert InvalidBlocklist(blocklist_);
            }
            try IBlocklistVoteEligibility(blocklist_).blockedUntil(beneficiary_) returns (uint256 blockedUntil_) {
                beneficiaryBlockedUntil = blockedUntil_;
            } catch {
                revert InvalidBlocklist(blocklist_);
            }
            eligibility.blocked = eligibility.blocked || beneficiaryBlocked;
            if (beneficiaryBlockedUntil > eligibility.blockedUntil) {
                eligibility.blockedUntil = beneficiaryBlockedUntil;
            }
        }
    }

    function _allowlistAccountEligibility(address account)
        private
        view
        returns (bool allowed, bool systemAccount_, uint64 allowedUntil_)
    {
        address allowlist_ = allowlist();
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlist(allowlist_).isAllowed(account) returns (bool currentAllowed) {
            allowed = currentAllowed;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        try IAllowlist(allowlist_).isSystemAccount(account) returns (bool currentSystem) {
            systemAccount_ = currentSystem;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        try IAllowlist(allowlist_).allowedUntil(account) returns (uint64 currentUntil) {
            allowedUntil_ = currentUntil;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _planVoteTransitions(SourceEligibility memory eligibility, uint256 votes)
        private
        view
        returns (VoteTransitions memory transitions)
    {
        if (votes == 0 || !eligibility.allowlisted) return transitions;
        uint48 currentTime = clock();
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

    function _eligibilityTransitionPrefix(address delegatee, uint256 timepoint) private view returns (int256 delta) {
        if (timepoint > type(uint48).max) return 0;
        bytes32 selectorWord = bytes32(this.getPastVotes.selector);
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, selectorWord)
            mstore(add(input, 4), delegatee)
            mstore(add(input, 36), timepoint)
            let success := staticcall(gas(), address(), input, 68, input, 32)
            let size := returndatasize()
            if iszero(success) {
                returndatacopy(input, 0, size)
                revert(input, size)
            }
            if iszero(eq(size, 32)) { revert(0, 0) }
            delta := mload(input)
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

    function _liveIndexedEligibleVotes(address delegatee) private view returns (uint256) {
        return _applyEligibilityTransition(
            _eligibleDelegateVotes[delegatee].latest(), _eligibilityTransitionPrefix(delegatee, clock())
        );
    }

    function _pastIndexedEligibleVotes(address delegatee, uint256 timepoint) private view returns (uint256) {
        if (timepoint > type(uint48).max) return 0;
        return _applyEligibilityTransition(
            _eligibleDelegateVotes[delegatee].upperLookupRecent(uint48(timepoint)),
            _eligibilityTransitionPrefix(delegatee, timepoint)
        );
    }

    function _delegateSourcePastVotes(address delegatee, address source, uint256 timepoint)
        internal
        view
        returns (uint256)
    {
        return _delegateSourceCheckpoints[delegatee][source].upperLookupRecent(uint48(timepoint));
    }

    function _liveLegacyEligibleVotes(address delegatee) private view returns (uint256 votes) {
        EnumerableSet.AddressSet storage sources = _delegateSources[delegatee];
        uint256 sourceCount = sources.length();
        if (sourceCount > MAX_DELEGATE_SOURCES) {
            revert LegacyDelegateSourceIndexCorrupted(delegatee, sourceCount, MAX_DELEGATE_SOURCES);
        }
        for (uint256 i; i < sourceCount;) {
            address source = sources.at(i);
            if (delegates(source) == delegatee && _isSourceEligibleNow(source)) {
                votes += balanceOf(source);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _pastLegacyEligibleVotes(address delegatee, uint256 timepoint) private view returns (uint256 votes) {
        EnumerableSet.AddressSet storage sources = _historicalDelegateSources[delegatee];
        uint256 sourceCount = sources.length();
        if (sourceCount > MAX_DELEGATE_SOURCES) {
            revert LegacyDelegateSourceIndexCorrupted(delegatee, sourceCount, MAX_DELEGATE_SOURCES);
        }
        for (uint256 i; i < sourceCount;) {
            address source = sources.at(i);
            uint256 sourceVotes = _delegateSourcePastVotes(delegatee, source, timepoint);
            if (sourceVotes != 0 && _isAllowedAt(source, timepoint) && !_wasBlockedAt(source, timepoint)) {
                votes += sourceVotes;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isSourceEligibleNow(address source) private view returns (bool) {
        SourceEligibility memory eligibility = _sourceEligibility(source, address(0), false);
        return eligibility.allowlisted && !eligibility.blocked;
    }

    function _isDelegateeEligibleNow(address delegatee) private view returns (bool) {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0)) {
            try IBlocklist(blocklist_).isBlocked(delegatee) returns (bool blocked) {
                if (blocked) return false;
            } catch {
                revert InvalidBlocklist(blocklist_);
            }
        }
        return true;
    }

    function _isDelegateeEligibleAt(address delegatee, uint256 timepoint) private view returns (bool) {
        return !_wasBlockedAt(delegatee, timepoint);
    }

    function _rememberVestingBeneficiary(address source) private returns (address beneficiary_) {
        (bool systemAccount_, address registeredBeneficiary) = _currentVestingSourceRegistration(source, allowlist());
        if (!systemAccount_ || registeredBeneficiary == address(0)) return address(0);
        if (_readVestingBeneficiary(source) != registeredBeneficiary) revert IAllowlist.AllowlistUnavailable();
        address previous = _vestingBeneficiaryBySource[source];
        if (previous == address(0)) {
            _delegateStateModule(
                abi.encodeCall(ForageTokenStateModule.rememberVestingBeneficiary, (source, registeredBeneficiary))
            );
        } else if (previous != registeredBeneficiary) {
            revert IAllowlist.AllowlistUnavailable();
        }
        return registeredBeneficiary;
    }

    function _isUnindexedLegacyVestingSource(address source) private view returns (bool) {
        if (_vestingBeneficiaryBySource[source] != address(0)) return false;
        address allowlist_ = allowlist();
        (bool systemAccount_, address registeredBeneficiary) = _currentVestingSourceRegistration(source, allowlist_);
        if (!systemAccount_ || registeredBeneficiary != address(0)) return false;
        address beneficiary_ = _readVestingBeneficiary(source);
        if (beneficiary_ == address(0)) return false;
        return true;
    }

    function _legacyVestingBeneficiary(address source) private view returns (address beneficiary_) {
        beneficiary_ = _vestingBeneficiaryBySource[source];
        if (beneficiary_ != address(0) || source.code.length == 0) return beneficiary_;
        address allowlist_ = allowlist();
        beneficiary_ = _registeredVestingSourceBeneficiary(allowlist_, source);
        if (beneficiary_ != address(0)) return beneficiary_;
        return _readVestingBeneficiary(source);
    }

    function _currentVestingSourceRegistration(address source, address allowlist_)
        private
        view
        returns (bool systemAccount_, address beneficiary_)
    {
        if (source.code.length == 0) return (false, address(0));
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlist(allowlist_).isSystemAccount(source) returns (bool currentSystemAccount) {
            systemAccount_ = currentSystemAccount;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (!systemAccount_) return (false, address(0));
        beneficiary_ = _registeredVestingSourceBeneficiary(allowlist_, source);
    }

    function _registeredVestingSourceBeneficiary(address allowlist_, address source)
        private
        view
        returns (address beneficiary_)
    {
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVestingSourceRegistry(allowlist_).vestingSourceBeneficiary(source) returns (
            address registeredBeneficiary
        ) {
            return registeredBeneficiary;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _readVestingBeneficiary(address source) private view returns (address beneficiary_) {
        (bool ok, bytes memory data) =
            source.staticcall(abi.encodeWithSelector(IVestingBeneficiarySource.beneficiary.selector));
        if (!ok || data.length != 32) return address(0);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := mload(add(data, 32))
        }
        if (encoded > type(uint160).max) return address(0);
        return address(uint160(encoded));
    }

    function _syncVestingSources(address beneficiary_) private {
        EnumerableSet.AddressSet storage sources = _vestingSourcesByBeneficiary[beneficiary_];
        uint256 sourceCount = sources.length();
        if (sourceCount == 0) return;
        uint256 maximum = _maxVestingSourcesPerBeneficiary();
        if (sourceCount > maximum) revert TooManyVestingSources(beneficiary_, sourceCount, maximum);
        for (uint256 i = sourceCount; i > 0; --i) {
            _syncDelegateSourceContribution(sources.at(i - 1));
        }
    }

    function _syncInitialVestingSources() private {
        address teamSource = _initialTeamVestingSource;
        if (teamSource != address(0)) _syncDelegateSourceContribution(teamSource);

        address treasurySource = _initialTreasurySource;
        if (treasurySource != address(0) && treasurySource != teamSource) {
            _syncDelegateSourceContribution(treasurySource);
        }
    }

    function _maxVestingSourcesPerBeneficiary() private view returns (uint256 maximum) {
        address allowlist_ = allowlist();
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVestingSourceLimit(allowlist_).maxVestingSourcesPerBeneficiary() returns (uint256 value) {
            maximum = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _isAllowedAt(address account, uint256 timepoint) private view returns (bool) {
        if (!_isAllowlistedAt(account, timepoint)) return false;
        if (!_isSystemAccountAt(account, timepoint)) return true;
        address beneficiary_ = _vestingBeneficiaryBySource[account];
        if (beneficiary_ == address(0)) beneficiary_ = _legacyVestingBeneficiary(account);
        return beneficiary_ == address(0) || _isAllowlistedAt(beneficiary_, timepoint);
    }

    function _isSystemAccountAt(address account, uint256 timepoint) private view returns (bool) {
        address allowlist_ = allowlist();
        try IAllowlistVoteEligibility(allowlist_).isSystemAccountAt(account, timepoint) returns (bool systemAccount_) {
            return systemAccount_;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _isAllowlistedAt(address account, uint256 timepoint) private view returns (bool) {
        address allowlist_ = allowlist();
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlistVoteEligibility(allowlist_).isAllowedAt(account, timepoint) returns (bool allowed) {
            return allowed;
        } catch {
            if (_supportsAllowlistVoteEligibility(allowlist_)) revert IAllowlist.AllowlistUnavailable();
            return _isAllowedNow(account);
        }
    }

    function _isAllowedNow(address account) private view returns (bool) {
        address allowlist_ = allowlist();
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlist(allowlist_).isAllowed(account) returns (bool allowed) {
            return allowed;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _wasBlockedAt(address account, uint256 timepoint) private view returns (bool) {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) return false;
        if (_wasEffectivelyBlockedAt(blocklist_, account, timepoint)) return true;
        if (!_isSystemAccountAt(account, timepoint)) return false;
        address beneficiary_ = _vestingBeneficiaryBySource[account];
        if (beneficiary_ == address(0)) beneficiary_ = _legacyVestingBeneficiary(account);
        return beneficiary_ != address(0) && _wasEffectivelyBlockedAt(blocklist_, beneficiary_, timepoint);
    }

    function _wasEffectivelyBlockedAt(address blocklist_, address account, uint256 timepoint)
        private
        view
        returns (bool)
    {
        return
            _readHistoricalBlocklistBoolean(blocklist_, account, timepoint, IBlocklist.wasEffectivelyBlockedAt.selector);
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

    function _registerAllowlistObserver(address allowlist_) private {
        if (allowlist_ == address(0)) return;
        _isSystemAccountAt(address(this), clock());
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

    function _unregisterBlocklistObserver(address blocklist_) private {
        if (blocklist_ == address(0)) return;
        (bool ok, bytes memory data) = blocklist_.staticcall(
            abi.encodeWithSelector(IBlocklistVoteEligibility.supportsVoteEligibilityObserver.selector)
        );
        if (ok && data.length >= 32 && abi.decode(data, (bool))) {
            IBlocklistVoteEligibility(blocklist_).unregisterVoteEligibilityObserver();
        }
    }
}
