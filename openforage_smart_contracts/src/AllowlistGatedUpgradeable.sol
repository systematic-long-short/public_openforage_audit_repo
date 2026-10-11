// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IAllowlist.sol";

/// @title AllowlistGatedUpgradeable
/// @notice Caller gate mixin: every adopter requires an allowlisted caller before its own checks.
/// @dev The allowlist lives in ERC-7201 namespaced storage so no adopter's existing proxy slot moves.
abstract contract AllowlistGatedUpgradeable is Initializable {
    /// @custom:storage-location erc7201:openforage.storage.AllowlistGated
    struct AllowlistGatedStorage {
        IAllowlist allowlist;
    }

    bytes32 private constant ALLOWLIST_GATED_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("openforage.storage.AllowlistGated")) - 1)) & ~bytes32(uint256(0xff));

    event AllowlistSet(address indexed previous, address indexed next);

    function _getAllowlistGatedStorage() private pure returns (AllowlistGatedStorage storage $) {
        bytes32 slot = ALLOWLIST_GATED_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    function allowlist() public view returns (address) {
        return address(_getAllowlistGatedStorage().allowlist);
    }

    function __AllowlistGated_init(address allowlist_) internal onlyInitializing {
        _setAllowlist(allowlist_);
    }

    modifier onlyAllowedCaller() {
        _checkAllowedCaller();
        _;
    }

    function _setAllowlist(address allowlist_) internal {
        if (allowlist_ == address(0) || allowlist_.code.length == 0) revert IAllowlist.AllowlistUnavailable();
        (bool ok, bytes memory ret) = allowlist_.staticcall(abi.encodeCall(IAllowlist.isSystemAccount, (address(this))));
        if (!ok || ret.length != 32) revert IAllowlist.AllowlistUnavailable();

        _writeAllowlist(allowlist_);
    }

    function _transitionAllowlist(address allowlist_) internal {
        _validateAllowlistTransition(allowlist_);
        _writeAllowlist(allowlist_);
    }

    function _validateAllowlistTransition(address allowlist_) internal view {
        if (address(_getAllowlistGatedStorage().allowlist) != address(0)) _checkAllowedCaller();
        _requireTransitionCandidate(allowlist_, msg.sender);
    }

    function _requireTransitionCandidate(address candidate, address caller) private view {
        if (candidate == address(0) || candidate.code.length == 0) revert IAllowlist.AllowlistUnavailable();
        if (!_readCanonicalBoolean(candidate, abi.encodeCall(IAllowlist.isAllowed, (caller)))) {
            revert IAllowlist.CallerNotAllowed(caller);
        }
        if (!_readCanonicalBoolean(candidate, abi.encodeCall(IAllowlist.isSystemAccount, (address(this))))) {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _readCanonicalBoolean(address target, bytes memory callData) private view returns (bool) {
        (bool ok, bytes memory returnedData) = target.staticcall(callData);
        if (!ok || returnedData.length != 32) revert IAllowlist.AllowlistUnavailable();
        uint256 value;
        assembly ("memory-safe") {
            value := mload(add(returnedData, 0x20))
        }
        if (value > 1) revert IAllowlist.AllowlistUnavailable();
        return value == 1;
    }

    function _writeAllowlist(address allowlist_) private {
        AllowlistGatedStorage storage $ = _getAllowlistGatedStorage();
        address previous = address($.allowlist);
        $.allowlist = IAllowlist(allowlist_);
        emit AllowlistSet(previous, allowlist_);
    }

    function _checkAllowedCaller() internal view {
        address allowlistAddress = address(_getAllowlistGatedStorage().allowlist);
        if (allowlistAddress == address(0)) revert IAllowlist.AllowlistUnavailable();

        try IAllowlist(allowlistAddress).isAllowed(msg.sender) returns (bool allowed) {
            if (!allowed) revert IAllowlist.CallerNotAllowed(msg.sender);
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }
}
