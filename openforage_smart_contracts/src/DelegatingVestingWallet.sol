// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "./interfaces/IBlocklist.sol";

/// @title DelegatingVestingWallet
/// @notice Non-upgradeable per-beneficiary FORAGE vesting with cliff and voting delegation
contract DelegatingVestingWallet {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroDuration();
    error CliffExceedsDuration();
    error UnauthorizedTokenSetter(address caller);
    error ForageTokenAlreadySet();
    error ForageTokenNotSet();
    error NoTokenBalance(); // OF-NEW-08 (12th audit)
    error NothingToRelease();
    error UnauthorizedBeneficiary(address caller);
    error InvalidStartTimestamp();
    error DelegateCallFailed();
    error VotingDelegationFailed(address token, address expectedDelegatee, address actualDelegatee);
    error CannotRescueForageToken(); // OF-16-016
    error BlockedAddress(address account);
    error BlocklistAlreadySet();
    error BlocklistNotSet();
    error ForageTokenNotPrecommitted();
    error ForageTokenAlreadyPrecommitted();
    error UnexpectedForageToken(address expected, address provided);
    error InvalidBlocklist(address blocklist);

    event ForageTokenPrecommitted(address indexed forageToken);
    event ForageTokenSet(address indexed forageToken);
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event VotingDelegateChanged(address indexed oldDelegatee, address indexed newDelegatee);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);

    address private immutable _beneficiary;
    uint64 private immutable _start;
    uint64 private immutable _duration;
    uint64 private immutable _cliff;

    address private _tokenSetter;
    address private _forageToken;
    address private _delegatee;
    uint256 private _released;
    /// @dev OF-023: Snapshot of initial token balance to prevent vesting manipulation via donations.
    /// OF-16-028: FORAGE donated after setForageToken() is permanently trapped — vestedAmount()
    /// uses _originalAllocation as ceiling. This is intentional: prevents vesting schedule manipulation.
    /// There is no rescue function for FORAGE specifically to maintain this invariant.
    uint256 private _originalAllocation;
    address private _blocklist;
    address private immutable _blocklistSetter;
    address private _precommittedForageToken;

    constructor(
        address beneficiary_,
        uint64 startTimestamp_,
        uint64 durationSeconds_,
        uint64 cliffSeconds_,
        address tokenSetter_
    ) {
        if (beneficiary_ == address(0)) revert ZeroAddress();
        if (tokenSetter_ == address(0)) revert ZeroAddress();
        if (durationSeconds_ == 0) revert ZeroDuration();
        if (cliffSeconds_ > durationSeconds_) revert CliffExceedsDuration();
        // OF-L15: Prevent creating vesting wallets with past start timestamps
        if (startTimestamp_ < uint64(block.timestamp)) revert InvalidStartTimestamp();

        _beneficiary = beneficiary_;
        _start = startTimestamp_;
        _duration = durationSeconds_;
        _cliff = cliffSeconds_;
        _tokenSetter = tokenSetter_;
        _blocklistSetter = tokenSetter_;
        _delegatee = beneficiary_;
    }

    function setBlocklist(address blocklist_) external {
        if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
            revert UnauthorizedTokenSetter(msg.sender);
        }
        if (_blocklist != address(0)) revert BlocklistAlreadySet();
        if (blocklist_ == address(0)) revert ZeroAddress();
        _requireValidBlocklist(blocklist_);
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function replaceBrokenBlocklist(address blocklist_) external {
        if (msg.sender != _tokenSetter && msg.sender != _blocklistSetter) {
            revert UnauthorizedTokenSetter(msg.sender);
        }
        address oldBlocklist = _blocklist;
        if (oldBlocklist == address(0)) revert BlocklistNotSet();
        if (_isHealthyBlocklist(oldBlocklist)) revert BlocklistAlreadySet();
        if (blocklist_ == address(0)) revert ZeroAddress();
        _requireValidBlocklist(blocklist_);
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function precommitForageToken(address forageToken_) external {
        if (_forageToken != address(0)) revert ForageTokenAlreadySet();
        if (msg.sender != _tokenSetter) revert UnauthorizedTokenSetter(msg.sender);
        if (_precommittedForageToken != address(0)) revert ForageTokenAlreadyPrecommitted();
        if (forageToken_ == address(0)) revert ZeroAddress();
        if (forageToken_.code.length == 0) revert TargetHasNoCode(forageToken_);

        _precommittedForageToken = forageToken_;
        emit ForageTokenPrecommitted(forageToken_);
    }

    function setInitialDelegatee(address delegatee_) external {
        if (_forageToken != address(0)) revert ForageTokenAlreadySet();
        if (msg.sender != _tokenSetter) revert UnauthorizedTokenSetter(msg.sender);
        if (delegatee_ == address(0)) revert ZeroAddress();
        _delegatee = delegatee_;
    }

    function setForageToken(address forageToken_) external {
        if (_forageToken != address(0)) revert ForageTokenAlreadySet();
        if (msg.sender != _tokenSetter) revert UnauthorizedTokenSetter(msg.sender);
        if (forageToken_ == address(0)) revert ZeroAddress();
        if (forageToken_.code.length == 0) revert ZeroAddress();
        address precommittedForageToken_ = _precommittedForageToken;
        if (precommittedForageToken_ == address(0)) revert ForageTokenNotPrecommitted();
        if (forageToken_ != precommittedForageToken_) {
            revert UnexpectedForageToken(precommittedForageToken_, forageToken_);
        }
        // OF-NEW-08 (12th audit): Require non-zero token balance to prevent zero _originalAllocation
        if (IERC20(forageToken_).balanceOf(address(this)) == 0) revert NoTokenBalance();
        _requireNotBlocked(address(this));

        _forageToken = forageToken_;
        _tokenSetter = address(0);

        // OF-023: Snapshot initial allocation to prevent vesting manipulation via donations
        _originalAllocation = IERC20(forageToken_).balanceOf(address(this));

        // Trigger initial delegation
        _callDelegate(_delegatee);

        emit ForageTokenSet(forageToken_);
    }

    function release() external {
        if (_forageToken == address(0)) revert ForageTokenNotSet();
        // OF-L04: Only beneficiary can release vested tokens
        if (msg.sender != _beneficiary) revert UnauthorizedBeneficiary(msg.sender);

        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();
        _requireNotBlocked(_beneficiary);
        _requireNotBlocked(address(this));

        _released += amount;
        IERC20(_forageToken).safeTransfer(_beneficiary, amount);

        emit TokensReleased(_beneficiary, amount);
    }

    function delegateVotingPower(address newDelegatee) external {
        if (msg.sender != _beneficiary) revert UnauthorizedBeneficiary(msg.sender);
        if (_forageToken == address(0)) revert ForageTokenNotSet();
        if (newDelegatee == address(0)) revert ZeroAddress();
        _requireNotBlocked(_beneficiary);
        _requireNotBlocked(address(this));
        _requireNotBlocked(newDelegatee);

        address oldDelegatee = _delegatee;
        // OF-I22: State update before interaction is safe — _callDelegate reverts on failure
        // (all-or-nothing), and the target is our own ForageToken (trusted, code-checked).
        _delegatee = newDelegatee;

        _callDelegate(newDelegatee);

        emit VotingDelegateChanged(oldDelegatee, newDelegatee);
    }

    function beneficiary() external view returns (address) {
        return _beneficiary;
    }

    function forageToken() external view returns (address) {
        return _forageToken;
    }

    function precommittedForageToken() external view returns (address) {
        return _precommittedForageToken;
    }

    function tokenSetter() external view returns (address) {
        return _tokenSetter;
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function start() external view returns (uint64) {
        return _start;
    }

    function duration() external view returns (uint64) {
        return _duration;
    }

    function cliff() external view returns (uint64) {
        return _cliff;
    }

    function end() external view returns (uint64) {
        return _start + _duration;
    }

    function released() external view returns (uint256) {
        return _released;
    }

    function releasable() public view returns (uint256) {
        if (_forageToken == address(0)) return 0;
        return vestedAmount(uint64(block.timestamp)) - _released;
    }

    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        if (_forageToken == address(0)) return 0;

        // OF-023: Use snapshotted allocation if available, fall back to dynamic for pre-upgrade wallets
        uint256 totalAllocation =
            _originalAllocation > 0 ? _originalAllocation : _released + IERC20(_forageToken).balanceOf(address(this));

        // Use uint256 arithmetic to prevent overflow with large timestamps
        if (uint256(timestamp) < uint256(_start) + uint256(_cliff)) {
            return 0;
        }

        if (uint256(timestamp) >= uint256(_start) + uint256(_duration)) {
            return totalAllocation;
        }

        return (totalAllocation * (uint256(timestamp) - uint256(_start))) / uint256(_duration);
    }

    function delegatee() external view returns (address) {
        return _delegatee;
    }

    /// @notice OF-16-016: Rescue non-FORAGE ERC-20 tokens accidentally sent to this contract.
    /// Only the beneficiary can call. Excludes _forageToken to preserve vesting invariants.
    function rescueToken(address token, uint256 amount) external {
        if (msg.sender != _beneficiary) revert UnauthorizedBeneficiary(msg.sender);
        if (_forageToken == address(0)) revert ForageTokenNotSet();
        if (token == address(0)) revert ZeroAddress();
        if (token == _forageToken) revert CannotRescueForageToken();
        if (token == _precommittedForageToken) revert CannotRescueForageToken();
        _requireNotBlocked(_beneficiary);
        _requireNotBlocked(address(this));
        IERC20(token).safeTransfer(_beneficiary, amount);
    }

    error TargetHasNoCode(address target); // OF-M09

    function _callDelegate(address delegatee_) private {
        // OF-M09: validate target has code before calling
        if (_forageToken.code.length == 0) revert TargetHasNoCode(_forageToken);
        // OF-13-018: Use typed IVotes interface instead of raw .call
        IVotes token = IVotes(_forageToken);
        token.delegate(delegatee_);
        address actualDelegatee = token.delegates(address(this));
        if (actualDelegatee != delegatee_) revert VotingDelegationFailed(_forageToken, delegatee_, actualDelegatee);
    }

    function _requireNotBlocked(address account) private view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _requireValidBlocklist(address blocklist_) private view {
        if (blocklist_.code.length == 0) revert TargetHasNoCode(blocklist_);
        if (!_isHealthyBlocklist(blocklist_)) revert InvalidBlocklist(blocklist_);
    }

    function _isHealthyBlocklist(address blocklist_) private view returns (bool) {
        if (blocklist_.code.length == 0) return false;
        return _blocklistResponds(blocklist_, address(0)) && _blocklistResponds(blocklist_, _beneficiary)
            && _blocklistResponds(blocklist_, address(this));
    }

    function _blocklistResponds(address blocklist_, address account) private view returns (bool) {
        (bool ok, bytes memory data) =
            blocklist_.staticcall(abi.encodeWithSelector(IBlocklist.isBlocked.selector, account));
        if (!ok || data.length != 32) return false;

        uint256 value;
        assembly {
            value := mload(add(data, 32))
        }
        return value <= 1;
    }
}
