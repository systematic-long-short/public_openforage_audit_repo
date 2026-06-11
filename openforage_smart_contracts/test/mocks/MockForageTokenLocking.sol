// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockForageTokenLocking
/// @dev Full-featured mock ForageToken that implements the lock/unlock interface
///      for testing StakingQueue's active FORAGE locking behavior.
///      Mirrors the real ForageToken's per-locker namespace model: authorized lockers,
///      lock-exempt accounts, aggregate locked balances, per-locker tracking, and transfer restrictions.
contract MockForageTokenLocking is ERC20 {
    // --- Errors (matching real ForageToken) ---
    error UnauthorizedLocker(address caller);
    error InsufficientUnlockedBalance(address account, uint256 available, uint256 required);
    error InsufficientLockedBalance(address account, uint256 available, uint256 required);
    error LockExemptAccount();
    error ZeroAddress();
    error ZeroAmount();

    // --- Events (matching real ForageToken) ---
    event ForageLocked(address indexed account, uint256 amount, address indexed locker);
    event ForageUnlocked(address indexed account, uint256 amount, address indexed locker);
    event AuthorizedLockerUpdated(address indexed locker, bool authorized);

    // --- State ---
    mapping(address => bool) public authorizedLockers;
    mapping(address => uint256) private _lockedBalances;
    mapping(address => bool) public lockExempt;
    // Per-locker tracking (mirrors real ForageToken OF-001 fix)
    mapping(address => mapping(address => uint256)) private _lockerBalances;
    mapping(address => address[]) private _accountLockersList;

    // --- Call tracking ---
    struct LockCall {
        address account;
        uint256 amount;
        address locker;
    }

    struct UnlockCall {
        address account;
        uint256 amount;
        address locker;
    }
    LockCall[] public lockCalls;
    UnlockCall[] public unlockCalls;

    constructor() ERC20("Forage Token", "FORAGE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // --- Lock/Unlock interface (matches real ForageToken per-locker model) ---

    function lock(address account, uint256 amount) external {
        if (!authorizedLockers[msg.sender]) revert UnauthorizedLocker(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (lockExempt[account]) revert LockExemptAccount();

        uint256 unlocked = balanceOf(account) - _lockedBalances[account];
        if (unlocked < amount) revert InsufficientUnlockedBalance(account, unlocked, amount);

        _lockedBalances[account] += amount;
        if (_lockerBalances[account][msg.sender] == 0) {
            _accountLockersList[account].push(msg.sender);
        }
        _lockerBalances[account][msg.sender] += amount;
        lockCalls.push(LockCall(account, amount, msg.sender));
        emit ForageLocked(account, amount, msg.sender);
    }

    function unlock(address account, uint256 amount) external {
        if (!authorizedLockers[msg.sender]) revert UnauthorizedLocker(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 lockerBal = _lockerBalances[account][msg.sender];
        if (lockerBal < amount) revert InsufficientLockedBalance(account, lockerBal, amount);

        _lockerBalances[account][msg.sender] -= amount;
        _lockedBalances[account] -= amount;
        if (_lockerBalances[account][msg.sender] == 0) {
            _removeLocker(account, msg.sender);
        }
        unlockCalls.push(UnlockCall(account, amount, msg.sender));
        emit ForageUnlocked(account, amount, msg.sender);
    }

    function lockedBalance(address account) external view returns (uint256) {
        return _lockedBalances[account];
    }

    function lockerBalance(address account, address locker) external view returns (uint256) {
        return _lockerBalances[account][locker];
    }

    // --- Admin controls (for test setup) ---

    function setAuthorizedLocker(address locker, bool authorized) external {
        authorizedLockers[locker] = authorized;
        emit AuthorizedLockerUpdated(locker, authorized);
    }

    function setLockExempt(address account, bool exempt) external {
        // Replicate PHASE3-200: zero locked balance when granting exemption
        if (exempt && _lockedBalances[account] > 0) {
            // Per-locker cleanup
            address[] memory lockers = _accountLockersList[account];
            for (uint256 i = 0; i < lockers.length; i++) {
                uint256 lockerBal = _lockerBalances[account][lockers[i]];
                if (lockerBal > 0) {
                    emit ForageUnlocked(account, lockerBal, lockers[i]);
                    _lockerBalances[account][lockers[i]] = 0;
                }
            }
            delete _accountLockersList[account];
            _lockedBalances[account] = 0;
        }
        lockExempt[account] = exempt;
    }

    /// @dev Directly set locked balance for test setup (bypasses locker auth).
    function setLockedBalance(address account, uint256 amount) external {
        _lockedBalances[account] = amount;
    }

    /// @dev Directly set per-locker balance for test setup.
    function setLockerBalance(address account, address locker, uint256 amount) external {
        if (_lockerBalances[account][locker] == 0 && amount > 0) {
            _accountLockersList[account].push(locker);
        }
        _lockerBalances[account][locker] = amount;
    }

    // --- Call tracking helpers ---

    function lockCallCount() external view returns (uint256) {
        return lockCalls.length;
    }

    function unlockCallCount() external view returns (uint256) {
        return unlockCalls.length;
    }

    function getLastLockCall() external view returns (LockCall memory) {
        require(lockCalls.length > 0, "no lock calls");
        return lockCalls[lockCalls.length - 1];
    }

    function getLastUnlockCall() external view returns (UnlockCall memory) {
        require(unlockCalls.length > 0, "no unlock calls");
        return unlockCalls[unlockCalls.length - 1];
    }

    // --- Transfer restriction (matching real ForageToken) ---

    function _update(address from, address to, uint256 value) internal override {
        // Lock enforcement: check unlocked balance before transfer
        if (from != address(0) && to != address(0) && from != address(this) && !lockExempt[from]) {
            uint256 fromBalance = balanceOf(from);
            uint256 locked = _lockedBalances[from];
            uint256 unlocked = fromBalance - locked;
            if (unlocked < value) {
                revert InsufficientUnlockedBalance(from, unlocked, value);
            }
        }
        super._update(from, to, value);
    }

    // --- Internal helpers ---

    function _removeLocker(address account, address locker) private {
        address[] storage lockers = _accountLockersList[account];
        for (uint256 i = 0; i < lockers.length; i++) {
            if (lockers[i] == locker) {
                lockers[i] = lockers[lockers.length - 1];
                lockers.pop();
                return;
            }
        }
    }
}
