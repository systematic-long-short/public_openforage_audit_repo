// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IAllowlist.sol";

contract MockAllowlist is IAllowlist {
    mapping(address => bool) private _allowed;
    mapping(address => bool) private _denied;
    mapping(address => bool) private _systemAccount;
    mapping(address => uint64) private _allowedUntil;
    mapping(address => uint8) private _basis;
    bool private _allAllowed;

    function setAllowed(address account, bool allowed_) external {
        _allowed[account] = allowed_;
        _denied[account] = !allowed_;
    }

    function setSystemAccount(address account, bool systemAccount_) external {
        _systemAccount[account] = systemAccount_;
    }

    function setAllowedUntil(address account, uint64 until) external {
        _allowedUntil[account] = until;
    }

    function setBasis(address account, uint8 basis) external {
        _basis[account] = basis;
    }

    function setAllAllowed(bool allAllowed_) external {
        _allAllowed = allAllowed_;
    }

    function isAllowed(address account) external view returns (bool) {
        if (_denied[account]) return false;
        if (_allAllowed) return true;
        return _allowed[account];
    }

    function allowedUntil(address account) external view returns (uint64) {
        return _allowedUntil[account];
    }

    function basisOf(address account) external view returns (uint8) {
        return _basis[account];
    }

    function isSystemAccount(address account) external view returns (bool) {
        return _systemAccount[account];
    }
}
