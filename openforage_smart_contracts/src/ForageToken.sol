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

        // Lock ceiling adjustment: if burning would make balance < locked, reduce locked
        uint256 currentBalance = balanceOf(from);
        if (currentBalance >= amount) {
            uint256 newBalance = currentBalance - amount;
            uint256 locked = _lockedBalances[from];
            if (newBalance < locked) {
                uint256 excess = locked - newBalance;
                uint256 length = _accountLockers[from].length();
                if (length > 0) {
                    // Pro-rata reduction across per-locker balances
                    uint256 reduced;
                    for (uint256 i = 0; i < length; i++) {
                        address locker = _accountLockers[from].at(i);
                        uint256 lockerBal = _lockerBalances[from][locker];
                        uint256 reduction;
                        if (i == length - 1) {
                            // Last locker absorbs rounding dust
                            reduction = excess - reduced;
                        } else {
                            reduction = (lockerBal * excess) / locked;
                        }
                        if (reduction > lockerBal) reduction = lockerBal;
                        _lockerBalances[from][locker] -= reduction;
                        reduced += reduction;
                        if (reduction > 0) {
                            emit ForageUnlocked(from, reduction, locker);
                        }
                    }
                    // OF-006 (11th audit): If pro-rata loop under-reduced due to
                    // capping, run a second pass to consume remaining excess so that
                    // _lockedBalances == sum(_lockerBalances) always holds.
                    uint256 shortfall = excess - reduced;
                    if (shortfall > 0) {
                        for (uint256 j = 0; j < length && shortfall > 0; j++) {
                            address locker = _accountLockers[from].at(j);
                            uint256 remaining = _lockerBalances[from][locker];
                            if (remaining > 0) {
                                uint256 take = shortfall > remaining ? remaining : shortfall;
                                _lockerBalances[from][locker] -= take;
                                reduced += take;
                                shortfall -= take;
                                if (take > 0) {
                                    emit ForageUnlocked(from, take, locker);
                                }
                            }
                        }
                    }
                    // Clean up lockers with zero balance (iterate backwards for safe removal)
                    for (uint256 i = length; i > 0; i--) {
                        address locker = _accountLockers[from].at(i - 1);
                        if (_lockerBalances[from][locker] == 0) {
                            _accountLockers[from].remove(locker);
                        }
                    }
                    // OF-012: Decrement by actual reduced amount (not target) to prevent
                    // aggregate desync when per-locker capping causes under-reduction with 3+ lockers
                    _lockedBalances[from] -= reduced;
                } else {
                    // Stale aggregate-only state (e.g. from vm.store) — emit single event
                    emit ForageUnlocked(from, excess, msg.sender);
                    _lockedBalances[from] = newBalance;
                }
            }
        }
        // If amount > currentBalance, _burn reverts — no lock adjustment needed

        _burn(from, amount);
        emit ForageBurned(from, amount, msg.sender);
    }

    function setAuthorizedBurner(address burner_, bool authorized_) external onlyAllowedCaller onlyOwner {
        if (burner_ == address(0)) revert ZeroAddress();
        _authorizedBurners[burner_] = authorized_;
        emit AuthorizedBurnerUpdated(burner_, authorized_);
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

        if (_lockerBalances[account][msg.sender] == 0 && !_accountLockers[account].contains(msg.sender)) {
            if (_accountLockers[account].length() >= MAX_LOCKERS_PER_ACCOUNT) {
                revert TooManyAccountLockers(account, MAX_LOCKERS_PER_ACCOUNT);
            }
            _accountLockers[account].add(msg.sender);
        }
        _lockedBalances[account] += amount;
        _lockerBalances[account][msg.sender] += amount;
        emit ForageLocked(account, amount, msg.sender);
    }

    function unlock(address account, uint256 amount) external onlyAllowedCaller {
        if (!_authorizedLockers[msg.sender]) revert UnauthorizedLocker(msg.sender);
        _requireNotBlocked(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(account);

        uint256 lockerBal = _lockerBalances[account][msg.sender];
        if (lockerBal < amount) revert InsufficientLockedBalance(account, lockerBal, amount);

        _lockerBalances[account][msg.sender] -= amount;
        _lockedBalances[account] -= amount;
        if (_lockerBalances[account][msg.sender] == 0) {
            _accountLockers[account].remove(msg.sender);
        }
        emit ForageUnlocked(account, amount, msg.sender);
    }

    /// @notice Set whether an address is authorized to lock/unlock FORAGE on behalf of users.
    /// @dev OF-L05 WARNING: Deauthorizing a locker that has active FORAGE locks will strand those
    /// locks permanently — the deauthorized contract can no longer call unlock(). Before deauthorizing,
    /// ensure all active locks by this locker are cleared via unlockBatch() or direct unlock() calls.
    /// Recovery procedure if locks are stranded: re-authorize the locker temporarily, call
    /// unlockBatch() for all affected accounts, then deauthorize again.
    function setAuthorizedLocker(address locker_, bool authorized_) external onlyAllowedCaller onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        _authorizedLockers[locker_] = authorized_;
        emit AuthorizedLockerUpdated(locker_, authorized_);
    }

    function setLockExempt(address account, bool exempt) external onlyAllowedCaller onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        // OF-15-020: Revert if granting exemption while account has active locks.
        // Lockers must explicitly unlock first via unlock/unlockBatch/emergencyUnlock.
        if (exempt && _lockedBalances[account] > 0) {
            revert AccountHasActiveLocks(account, _lockedBalances[account]);
        }
        // OF-13-023: Reconcile _lockedBalances from per-locker sum when revoking exemption.
        // This ensures _lockedBalances accurately reflects the sum of all _lockerBalances.
        if (!exempt) {
            uint256 length = _accountLockers[account].length();
            uint256 reconciledSum;
            for (uint256 i = 0; i < length; i++) {
                address lkr = _accountLockers[account].at(i);
                reconciledSum += _lockerBalances[account][lkr];
            }
            uint256 accountBalance = balanceOf(account);
            if (reconciledSum > accountBalance) {
                revert LockBalanceExceedsBalance(account, reconciledSum, accountBalance);
            }
            _lockedBalances[account] = reconciledSum;
        }
        _lockExempt[account] = exempt;
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
        uint256 lockerBal = _lockerBalances[account][locker];
        if (lockerBal == 0) revert NoLockerBalance();
        _lockedBalances[account] -= lockerBal;
        _lockerBalances[account][locker] = 0;
        _accountLockers[account].remove(locker);
        emit ForageUnlocked(account, lockerBal, locker);
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
            uint256 lockerBal = _lockerBalances[accounts[i]][msg.sender];
            if (lockerBal < amounts[i]) revert InsufficientLockedBalance(accounts[i], lockerBal, amounts[i]);
            _lockerBalances[accounts[i]][msg.sender] -= amounts[i];
            _lockedBalances[accounts[i]] -= amounts[i];
            if (_lockerBalances[accounts[i]][msg.sender] == 0) {
                _accountLockers[accounts[i]].remove(msg.sender);
            }
            emit ForageUnlocked(accounts[i], amounts[i], msg.sender);
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
        _blocklist = blocklist_;
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
        try IBlocklist(blocklist_).wasBlockedAt(address(this), block.timestamp) {}
        catch {
            revert InvalidBlocklist(blocklist_);
        }
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
        if (oldAllowlist != allowlist_) _unregisterAllowlistObserver(oldAllowlist);
        _setAllowlist(allowlist_);
        _registerAllowlistObserver(allowlist_);
        _syncInitialVestingSources();
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _recordActiveDelegateSource(address delegatee, address source) internal {
        bool added = _delegateSources[delegatee].add(source);
        if (!added && !_delegateSources[delegatee].contains(source)) {
            revert DelegateSourceTrackingFailed(delegatee, source);
        }
    }

    function _setDelegateSource(address source, address oldDelegate, address newDelegate) internal {
        _rememberVestingBeneficiary(source);
        if (oldDelegate != address(0)) {
            if (_historicalDelegateSources[oldDelegate].contains(source)) {
                _delegateSources[oldDelegate].remove(source);
                _writeDelegateSourceCheckpoint(oldDelegate, source, 0);
            } else {
                _clearNewVoteContribution(source);
            }
        }

        uint256 votes = balanceOf(source);
        if (newDelegate == address(0) || votes == 0) {
            _clearNewVoteContribution(source);
            _updateVestingSourceMembership(source, newDelegate, votes);
            return;
        }
        if (_historicalDelegateSources[newDelegate].contains(source)) {
            _clearNewVoteContribution(source);
            _recordActiveDelegateSource(newDelegate, source);
            _writeDelegateSourceCheckpoint(newDelegate, source, votes);
            _updateVestingSourceMembership(source, newDelegate, votes);
            return;
        }

        if (_isUnindexedLegacyVestingSource(source)) {
            _syncLegacyVestingContribution(source, newDelegate, votes);
            return;
        }

        _syncNewVoteContribution(source, newDelegate, votes);
    }

    function _syncDelegateSourceContribution(address source) internal {
        if (source == address(0)) return;
        _rememberVestingBeneficiary(source);
        address delegatee = delegates(source);
        if (delegatee == address(0)) {
            _clearNewVoteContribution(source);
            _updateVestingSourceMembership(source, address(0), 0);
            return;
        }

        uint256 votes = balanceOf(source);
        if (_historicalDelegateSources[delegatee].contains(source)) {
            if (votes == 0) {
                _delegateSources[delegatee].remove(source);
                _writeDelegateSourceCheckpoint(delegatee, source, 0);
                _updateVestingSourceMembership(source, delegatee, 0);
                return;
            }
            _recordActiveDelegateSource(delegatee, source);
            _writeDelegateSourceCheckpoint(delegatee, source, votes);
            _updateVestingSourceMembership(source, delegatee, votes);
            return;
        }

        if (_isUnindexedLegacyVestingSource(source)) {
            _syncLegacyVestingContribution(source, delegatee, votes);
            return;
        }

        _syncNewVoteContribution(source, delegatee, votes);
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

    function _syncNewVoteContribution(address source, address delegatee, uint256 votes) private {
        SourceEligibility memory eligibility = _sourceEligibility(source);
        uint256 newBaseVotes = eligibility.allowlisted && !eligibility.blocked ? votes : 0;
        VoteTransitions memory transitions = _planVoteTransitions(eligibility, votes);
        VoteSourceState storage state = _voteSourceStates[source];
        address oldDelegatee = state.delegatee;

        if (oldDelegatee != address(0)) {
            _cancelVoteSourceTransitions(oldDelegatee, state);
            if (oldDelegatee == delegatee) {
                _changeIndexedVotes(delegatee, state.baseVotes, newBaseVotes);
            } else {
                _changeIndexedVotes(oldDelegatee, state.baseVotes, 0);
                _changeIndexedVotes(delegatee, 0, newBaseVotes);
            }
        } else {
            _changeIndexedVotes(delegatee, 0, newBaseVotes);
        }

        state.delegatee = delegatee;
        state.baseVotes = uint208(newBaseVotes);
        state.firstTransitionTime = transitions.firstTime;
        state.firstTransitionDelta = transitions.firstDelta;
        state.secondTransitionTime = transitions.secondTime;
        state.secondTransitionDelta = transitions.secondDelta;
        _addVoteSourceTransitions(delegatee, transitions);
        _updateVestingSourceMembership(source, delegatee, votes);
    }

    function _clearNewVoteContribution(address source) private {
        VoteSourceState storage state = _voteSourceStates[source];
        address delegatee = state.delegatee;
        if (delegatee == address(0)) return;

        _cancelVoteSourceTransitions(delegatee, state);
        _changeIndexedVotes(delegatee, state.baseVotes, 0);
        delete _voteSourceStates[source];
        _updateVestingSourceMembership(source, address(0), 0);
    }

    function _sourceEligibility(address source) private view returns (SourceEligibility memory eligibility) {
        (eligibility.allowlisted, eligibility.systemAccount, eligibility.allowedUntil) =
            _allowlistAccountEligibility(source);
        address beneficiary_ = _vestingBeneficiaryBySource[source];
        if (beneficiary_ == address(0) && eligibility.systemAccount) {
            beneficiary_ = _legacyVestingBeneficiary(source);
        }
        if (beneficiary_ != address(0)) {
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

    function _cancelVoteSourceTransitions(address delegatee, VoteSourceState storage state) private {
        uint48 currentTime = clock();
        if (state.firstTransitionTime != 0) {
            uint48 firstTime = state.firstTransitionTime > currentTime ? state.firstTransitionTime : currentTime;
            _addEligibilityTransition(delegatee, firstTime, -state.firstTransitionDelta);
        }
        if (state.secondTransitionTime != 0) {
            uint48 secondTime = state.secondTransitionTime > currentTime ? state.secondTransitionTime : currentTime;
            _addEligibilityTransition(delegatee, secondTime, -state.secondTransitionDelta);
        }
    }

    function _addVoteSourceTransitions(address delegatee, VoteTransitions memory transitions) private {
        if (transitions.firstTime != 0) {
            _addEligibilityTransition(delegatee, transitions.firstTime, transitions.firstDelta);
        }
        if (transitions.secondTime != 0) {
            _addEligibilityTransition(delegatee, transitions.secondTime, transitions.secondDelta);
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
        _eligibleDelegateVotes[delegatee].push(clock(), uint208(nextVotes));
    }

    function _addEligibilityTransition(address delegatee, uint48 timepoint, int256 delta) private {
        if (delta == 0) return;
        uint256 index = uint256(timepoint) + 1;
        uint256 limit = uint256(type(uint48).max) + 1;
        while (index <= limit) {
            _eligibilityTransitionTree[delegatee][index] += delta;
            index += index & (~index + 1);
        }
    }

    function _eligibilityTransitionPrefix(address delegatee, uint256 timepoint) private view returns (int256 delta) {
        if (timepoint > type(uint48).max) return 0;
        uint256 index = timepoint + 1;
        while (index != 0) {
            delta += _eligibilityTransitionTree[delegatee][index];
            index -= index & (~index + 1);
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

    function _writeDelegateSourceCheckpoint(address delegatee, address source, uint256 votes) internal {
        _delegateSourceCheckpoints[delegatee][source].push(clock(), uint208(votes));
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
        SourceEligibility memory eligibility = _sourceEligibility(source);
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

    function _rememberVestingBeneficiary(address source) private {
        if (source.code.length == 0) return;
        address allowlist_ = allowlist();
        bool systemAccount_;
        try IAllowlist(allowlist_).isSystemAccount(source) returns (bool value) {
            systemAccount_ = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (!systemAccount_) return;
        address beneficiary_;
        try IAllowlistVestingSourceRegistry(allowlist_).vestingSourceBeneficiary(source) returns (
            address registeredBeneficiary
        ) {
            beneficiary_ = registeredBeneficiary;
        } catch {
            return;
        }
        if (beneficiary_ == address(0)) return;
        if (_readVestingBeneficiary(source) != beneficiary_) revert IAllowlist.AllowlistUnavailable();
        address previous = _vestingBeneficiaryBySource[source];
        if (previous == address(0)) {
            _vestingBeneficiaryBySource[source] = beneficiary_;
        } else if (previous != beneficiary_) {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _isUnindexedLegacyVestingSource(address source) private view returns (bool) {
        if (_vestingBeneficiaryBySource[source] != address(0) || source.code.length == 0) return false;
        address allowlist_ = allowlist();
        bool systemAccount_;
        try IAllowlist(allowlist_).isSystemAccount(source) returns (bool value) {
            systemAccount_ = value;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (!systemAccount_) return false;
        try IAllowlistVestingSourceRegistry(allowlist_).vestingSourceBeneficiary(source) returns (address beneficiary_)
        {
            if (beneficiary_ != address(0)) return false;
        } catch {}
        return _readVestingBeneficiary(source) != address(0);
    }

    function _legacyVestingBeneficiary(address source) private view returns (address beneficiary_) {
        beneficiary_ = _vestingBeneficiaryBySource[source];
        if (beneficiary_ != address(0) || source.code.length == 0) return beneficiary_;
        address allowlist_ = allowlist();
        try IAllowlistVestingSourceRegistry(allowlist_).vestingSourceBeneficiary(source) returns (
            address registeredBeneficiary
        ) {
            if (registeredBeneficiary != address(0)) return registeredBeneficiary;
        } catch {}
        return _readVestingBeneficiary(source);
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

    function _updateVestingSourceMembership(address source, address delegatee, uint256 votes) private {
        address beneficiary_ = _vestingBeneficiaryBySource[source];
        if (beneficiary_ == address(0)) return;
        EnumerableSet.AddressSet storage sources = _vestingSourcesByBeneficiary[beneficiary_];
        if (delegatee != address(0) && votes != 0) {
            if (!sources.contains(source)) {
                uint256 sourceCount = sources.length();
                uint256 maximum = _maxVestingSourcesPerBeneficiary();
                if (sourceCount >= maximum) revert TooManyVestingSources(beneficiary_, sourceCount, maximum);
                sources.add(source);
            }
        } else {
            sources.remove(source);
        }
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
        address beneficiary_ = _vestingBeneficiaryBySource[account];
        if (beneficiary_ == address(0) && _isSystemAccountAt(account, timepoint)) {
            beneficiary_ = _legacyVestingBeneficiary(account);
        }
        return beneficiary_ == address(0) || _isAllowlistedAt(beneficiary_, timepoint);
    }

    function _isSystemAccountAt(address account, uint256 timepoint) private view returns (bool) {
        address allowlist_ = allowlist();
        try IAllowlistVoteEligibility(allowlist_).isSystemAccountAt(account, timepoint) returns (bool systemAccount_) {
            return systemAccount_;
        } catch {
            try IAllowlist(allowlist_).isSystemAccount(account) returns (bool systemAccount_) {
                return systemAccount_;
            } catch {
                revert IAllowlist.AllowlistUnavailable();
            }
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
        address beneficiary_ = _vestingBeneficiaryBySource[account];
        if (beneficiary_ == address(0) && _isSystemAccountAt(account, timepoint)) {
            beneficiary_ = _legacyVestingBeneficiary(account);
        }
        return beneficiary_ != address(0) && _wasEffectivelyBlockedAt(blocklist_, beneficiary_, timepoint);
    }

    function _wasEffectivelyBlockedAt(address blocklist_, address account, uint256 timepoint)
        private
        view
        returns (bool)
    {
        (bool ok, bytes memory data) = blocklist_.staticcall(
            abi.encodeWithSelector(IBlocklist.wasEffectivelyBlockedAt.selector, account, timepoint)
        );
        if (ok && data.length >= 32) {
            return abi.decode(data, (bool));
        }
        return IBlocklist(blocklist_).wasBlockedAt(account, timepoint);
    }

    function _supportsAllowlistVoteEligibility(address allowlist_) private view returns (bool) {
        (bool ok, bytes memory data) = allowlist_.staticcall(
            abi.encodeWithSelector(IAllowlistVoteEligibility.supportsVoteEligibilityObserver.selector)
        );
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function _registerAllowlistObserver(address allowlist_) private {
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
