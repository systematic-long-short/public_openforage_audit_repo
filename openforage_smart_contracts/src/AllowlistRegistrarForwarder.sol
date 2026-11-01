// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAllowlistRegistrarCalls {
    function approve(address account, uint64 until, uint8 basis_, bytes32 caseRef_) external;
    function revoke(address account) external;
}

/// @title AllowlistRegistrarForwarder
/// @notice The Allowlist registrar as a contract with one signer that can never change. The deploy makes it a system
///         account, and `Allowlist.revoke` keeps a contract's system bit, so the Allowlist guardian cannot cut it off.
contract AllowlistRegistrarForwarder is IAllowlistRegistrarCalls {
    error InvalidAllowlist(address allowlist);
    error InvalidSigner(address signer);
    error NotSigner(address caller);

    address private immutable _allowlist;
    address private immutable _signer;

    constructor(address allowlist_, address signer_) {
        if (allowlist_ == address(0) || allowlist_.code.length == 0) revert InvalidAllowlist(allowlist_);
        if (signer_ == address(0) || signer_.code.length != 0) revert InvalidSigner(signer_);
        _allowlist = allowlist_;
        _signer = signer_;
    }

    function approve(address account, uint64 until, uint8 basis_, bytes32 caseRef_) external {
        _requireSigner();
        IAllowlistRegistrarCalls(_allowlist).approve(account, until, basis_, caseRef_);
    }

    function revoke(address account) external {
        _requireSigner();
        IAllowlistRegistrarCalls(_allowlist).revoke(account);
    }

    function allowlist() external view returns (address) {
        return _allowlist;
    }

    function signer() external view returns (address) {
        return _signer;
    }

    /// @dev The signer must also send the transaction, so an EIP-7702 delegation set on the signer's address while
    ///      its key was stolen cannot keep calling here after the key is switched off.
    function _requireSigner() private view {
        if (msg.sender != _signer || msg.sender != tx.origin) revert NotSigner(msg.sender);
    }
}
