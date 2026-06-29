// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IBlocklist.sol";

contract ForageToken is
    Initializable,
    ERC20Upgradeable,
    Ownable2StepUpgradeable,
    ERC20VotesUpgradeable,
    UUPSUpgradeable
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

    /// @dev Reserved storage gap for future upgrades
    uint256[44] private __gap;

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
        _mint(teamVestingAddress_, TEAM_VESTING_ALLOCATION);
        _mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);
    }

    /// @notice OF-16-033: Dead code — no tokens at address(this) after initialization.
    /// All tokens are minted to specific addresses during initialize(). This function is
    /// effectively unreachable in production. Retained for backward compatibility.
    /// @dev DEPRECATED: Will be removed in a future upgrade.
    function releaseTokens(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _transfer(address(this), to, amount);
        emit TokensReleased(to, amount);
    }

    function delegate(address delegatee) public override {
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
        return _liveUnblockedVotes(account, super.getVotes(account));
    }

    function getPastVotes(address account, uint256 timepoint) public view override returns (uint256) {
        uint256 checkpointVotes = super.getPastVotes(account, timepoint);
        return _pastUnblockedVotes(account, timepoint, checkpointVotes);
    }

    function delegateBySig(
        address, // delegatee
        uint256, // nonce
        uint256, // expiry
        uint8, // v
        bytes32, // r
        bytes32 // s
    )
        public
        pure
        override
    {
        revert DelegationBySignatureDisabled();
    }

    /// @notice Seeds delegate-source trackers for delegations that existed before this implementation.
    /// @dev Pre-upgrade delegated votes fail closed while source tracking is missing or incomplete.
    /// Sources are intentionally allowed to already be blocked.
    function syncDelegateSources(address[] calldata sources) external onlyOwner {
        for (uint256 i; i < sources.length;) {
            if (sources[i] == address(0)) revert ZeroAddress();
            _syncDelegateSourceContribution(sources[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice OF-16-003: CRITICAL INTEGRATION REQUIREMENT — When burn causes balance < locked,
    /// per-locker balances are pro-rata reduced WITHOUT notification to the locking contracts.
    /// Lockers' on-chain state becomes stale (they believe they hold more locked tokens than exist).
    /// ForageUnlocked events are emitted for off-chain monitoring but lockers get no callback.
    /// Any contract that locks FORAGE via setAuthorizedLocker MUST either:
    ///   (a) query ForageToken.lockerBalances(account, address(this)) before acting on assumed lock amounts, or
    ///   (b) monitor ForageUnlocked events indexed by their address to detect pro-rata reductions.
    /// Failure to do so may allow users to perform actions requiring more locked tokens than actually exist.
    function burn(address from, uint256 amount) external {
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

    function setAuthorizedBurner(address burner_, bool authorized_) external onlyOwner {
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

    function lock(address account, uint256 amount) external {
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

    function unlock(address account, uint256 amount) external {
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
    function setAuthorizedLocker(address locker_, bool authorized_) external onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        _authorizedLockers[locker_] = authorized_;
        emit AuthorizedLockerUpdated(locker_, authorized_);
    }

    function setLockExempt(address account, bool exempt) external onlyOwner {
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
    function emergencyUnlock(address account, address locker) external onlyOwner {
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

    function unlockBatch(address[] calldata accounts, uint256[] calldata amounts) external {
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

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
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

        _syncDelegateSourceContribution(from);
        _syncDelegateSourceContribution(to);
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

    function _setDelegateSource(address source, address oldDelegate, address newDelegate) internal {
        if (oldDelegate != address(0)) {
            bool wasTracked = _delegateSources[oldDelegate].remove(source);
            if (wasTracked || _historicalDelegateSources[oldDelegate].contains(source)) {
                _historicalDelegateSources[oldDelegate].add(source);
                _writeDelegateSourceCheckpoint(oldDelegate, source, 0);
            }
        }
        if (newDelegate != address(0)) {
            uint256 votes = balanceOf(source);
            if (votes == 0) return;
            _delegateSources[newDelegate].add(source);
            _historicalDelegateSources[newDelegate].add(source);
            _writeDelegateSourceCheckpoint(newDelegate, source, votes);
        }
    }

    function _syncDelegateSourceContribution(address source) internal {
        if (source == address(0)) return;
        address delegatee = delegates(source);
        if (delegatee == address(0)) return;

        uint256 votes = balanceOf(source);
        if (votes == 0) {
            bool wasTracked = _delegateSources[delegatee].remove(source);
            if (wasTracked || _historicalDelegateSources[delegatee].contains(source)) {
                _historicalDelegateSources[delegatee].add(source);
                _writeDelegateSourceCheckpoint(delegatee, source, 0);
            }
            return;
        }

        _delegateSources[delegatee].add(source);
        _historicalDelegateSources[delegatee].add(source);
        _writeDelegateSourceCheckpoint(delegatee, source, votes);
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

    function _liveUnblockedVotes(address delegatee, uint256 checkpointVotes) internal view returns (uint256) {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) return checkpointVotes;
        if (IBlocklist(blocklist_).isBlocked(delegatee)) return 0;

        EnumerableSet.AddressSet storage sources = _delegateSources[delegatee];
        uint256 sourceCount = sources.length();
        if (sourceCount == 0) return 0;

        uint256 adjustedVotes = checkpointVotes;
        uint256 trackedActiveVotes;
        for (uint256 i; i < sourceCount;) {
            address source = sources.at(i);
            if (delegates(source) == delegatee) {
                uint256 sourceVotes = balanceOf(source);
                trackedActiveVotes += sourceVotes;
                if (IBlocklist(blocklist_).isBlocked(source)) {
                    if (sourceVotes >= adjustedVotes) {
                        return 0;
                    }
                    adjustedVotes -= sourceVotes;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (trackedActiveVotes < adjustedVotes) return trackedActiveVotes;
        return adjustedVotes;
    }

    function _pastUnblockedVotes(address delegatee, uint256 timepoint, uint256 checkpointVotes)
        internal
        view
        returns (uint256)
    {
        address blocklist_ = _blocklist;
        bool hasBlocklist = blocklist_ != address(0);
        if (hasBlocklist && _wasEffectivelyBlockedAt(blocklist_, delegatee, timepoint)) return 0;

        EnumerableSet.AddressSet storage sources = _historicalDelegateSources[delegatee];
        uint256 sourceCount = sources.length();
        if (sourceCount == 0) return 0;

        uint256 adjustedVotes = checkpointVotes;
        uint256 trackedHistoricalVotes;
        for (uint256 i; i < sourceCount;) {
            address source = sources.at(i);
            uint256 sourceVotes = _delegateSourcePastVotes(delegatee, source, timepoint);
            trackedHistoricalVotes += sourceVotes;
            if (hasBlocklist && _wasEffectivelyBlockedAt(blocklist_, source, timepoint)) {
                if (sourceVotes >= adjustedVotes) {
                    return 0;
                }
                adjustedVotes -= sourceVotes;
            }
            unchecked {
                ++i;
            }
        }
        if (trackedHistoricalVotes < adjustedVotes) return trackedHistoricalVotes;
        return adjustedVotes;
    }

    function _wasEffectivelyBlockedAt(address blocklist_, address account, uint256 timepoint)
        internal
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
}
