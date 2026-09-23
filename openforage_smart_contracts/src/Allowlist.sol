// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./FinalizeDelayProfile.sol";

/// @title Allowlist
/// @notice UUPS investor and operator registry: a registrar approves investors under a per-UTC-day
///         cap, the owner approves operators without expiry, and registrar, guardian and system
///         registrars rotate behind the profile finalize delay.
contract Allowlist is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, FinalizeDelayProfile {
    error NotRegistrar();
    error NotGuardianOrRegistrar();
    error NotOwnerOrGuardian();
    error NotSystemRegistrar();
    error ZeroAddress();
    error ExpiryTooFar();
    error DailyCapReached();
    error CapNotShrunk();
    error RenounceOwnershipDisabled();
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error NoPendingProposal();

    uint256 public constant PROPOSAL_EXPIRY = 30 days;

    event Approved(address indexed account, uint64 until, uint8 basis, bytes32 caseRef);
    event OperatorApproved(address indexed account);
    event Revoked(address indexed account, address indexed by);
    event SystemAccountSet(address indexed account, bool isSystem);
    event ApprovalsPerDayCapShrunk(uint32 previous, uint32 next);
    event RegistrarProposed(address indexed account, uint256 proposedAt);
    event RegistrarUpdated(address indexed previous, address indexed next);
    event RegistrarProposalCancelled(address indexed account);
    event GuardianProposed(address indexed account, uint256 proposedAt);
    event GuardianUpdated(address indexed previous, address indexed next);
    event GuardianProposalCancelled(address indexed account);
    event SystemRegistrarProposed(address indexed account, bool isSystem, uint256 proposedAt);
    event SystemRegistrarUpdated(address indexed account, bool isSystem);
    event SystemRegistrarProposalCancelled(address indexed account);

    uint256 private constant APPROVAL_TERM_LIMIT = 400 days;
    uint32 private constant DEFAULT_APPROVALS_PER_DAY_CAP = 50;

    address private _registrar;
    address private _pendingRegistrar;
    uint256 private _pendingRegistrarProposedAt;
    address private _guardian;
    address private _pendingGuardian;
    uint256 private _pendingGuardianProposedAt;
    address private _pendingSystemRegistrar;
    bool private _pendingSystemRegistrarIsSystem;
    uint256 private _pendingSystemRegistrarProposedAt;
    uint32 private _approvalsPerDayCap;
    uint64 private _approvalsDay;
    uint32 private _approvalsTodayCount;
    mapping(address => uint64) private _allowedUntil;
    mapping(address => uint8) private _basis;
    mapping(address => bytes32) private _caseRef;
    mapping(address => bool) private _systemAccounts;
    mapping(address => bool) private _systemRegistrars;

    uint256[36] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address guardian_, uint64 finalizeDelay_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (guardian_ == address(0)) revert ZeroAddress();
        require(finalizeDelay_ == _finalizeDelay());

        __Ownable_init(owner_);
        __Ownable2Step_init();

        _guardian = guardian_;
        _approvalsPerDayCap = DEFAULT_APPROVALS_PER_DAY_CAP;
    }

    function approve(address account, uint64 until, uint8 basis_, bytes32 caseRef_) external {
        if (msg.sender != _registrar) revert NotRegistrar();
        if (account == address(0)) revert ZeroAddress();
        if (until > uint64(block.timestamp + APPROVAL_TERM_LIMIT)) revert ExpiryTooFar();
        _countApproval();

        _allowedUntil[account] = until;
        _basis[account] = basis_;
        _caseRef[account] = caseRef_;

        emit Approved(account, until, basis_, caseRef_);
    }

    function approveOperator(address account) external onlyOwner {
        _allowedUntil[account] = type(uint64).max;
        _basis[account] = 0;
        _caseRef[account] = bytes32(0);

        emit OperatorApproved(account);
    }

    function revoke(address account) external {
        if (msg.sender != _registrar && msg.sender != _guardian) revert NotGuardianOrRegistrar();

        _allowedUntil[account] = 0;
        _basis[account] = 0;
        _caseRef[account] = bytes32(0);

        emit Revoked(account, msg.sender);
    }

    function shrinkApprovalsPerDayCap(uint32 newCap) external {
        if (msg.sender != owner() && msg.sender != _guardian) revert NotOwnerOrGuardian();
        if (newCap >= _approvalsPerDayCap) revert CapNotShrunk();

        uint32 previous = _approvalsPerDayCap;
        _approvalsPerDayCap = newCap;

        emit ApprovalsPerDayCapShrunk(previous, newCap);
    }

    function setSystemAccount(address account, bool isSystem) external {
        if (msg.sender != owner() && !_systemRegistrars[msg.sender]) revert NotSystemRegistrar();
        if (account == address(0)) revert ZeroAddress();

        _systemAccounts[account] = isSystem;

        emit SystemAccountSet(account, isSystem);
    }

    function proposeRegistrar(address account) external onlyOwner {
        _pendingRegistrar = account;
        _pendingRegistrarProposedAt = block.timestamp;

        emit RegistrarProposed(account, block.timestamp);
    }

    function finalizeRegistrar() external onlyOwner {
        address account = _pendingRegistrar;
        if (account == address(0)) revert NoPendingProposal();
        _requireProposalReady(_pendingRegistrarProposedAt);

        address previous = _registrar;
        _registrar = account;
        _pendingRegistrar = address(0);
        _pendingRegistrarProposedAt = 0;

        emit RegistrarUpdated(previous, account);
    }

    function cancelRegistrar() external onlyOwner {
        address account = _pendingRegistrar;
        if (account == address(0)) revert NoPendingProposal();

        _pendingRegistrar = address(0);
        _pendingRegistrarProposedAt = 0;

        emit RegistrarProposalCancelled(account);
    }

    function proposeGuardian(address account) external onlyOwner {
        _pendingGuardian = account;
        _pendingGuardianProposedAt = block.timestamp;

        emit GuardianProposed(account, block.timestamp);
    }

    function finalizeGuardian() external onlyOwner {
        address account = _pendingGuardian;
        if (account == address(0)) revert NoPendingProposal();
        _requireProposalReady(_pendingGuardianProposedAt);

        address previous = _guardian;
        _guardian = account;
        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianUpdated(previous, account);
    }

    function cancelGuardian() external onlyOwner {
        address account = _pendingGuardian;
        if (account == address(0)) revert NoPendingProposal();

        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianProposalCancelled(account);
    }

    function proposeSystemRegistrar(address account, bool isSystem) external onlyOwner {
        _pendingSystemRegistrar = account;
        _pendingSystemRegistrarIsSystem = isSystem;
        _pendingSystemRegistrarProposedAt = block.timestamp;

        emit SystemRegistrarProposed(account, isSystem, block.timestamp);
    }

    function finalizeSystemRegistrar() external onlyOwner {
        address account = _pendingSystemRegistrar;
        if (account == address(0)) revert NoPendingProposal();
        _requireProposalReady(_pendingSystemRegistrarProposedAt);

        bool isSystem = _pendingSystemRegistrarIsSystem;
        _systemRegistrars[account] = isSystem;
        _pendingSystemRegistrar = address(0);
        _pendingSystemRegistrarIsSystem = false;
        _pendingSystemRegistrarProposedAt = 0;

        emit SystemRegistrarUpdated(account, isSystem);
    }

    function cancelSystemRegistrar() external onlyOwner {
        address account = _pendingSystemRegistrar;
        if (account == address(0)) revert NoPendingProposal();

        _pendingSystemRegistrar = address(0);
        _pendingSystemRegistrarIsSystem = false;
        _pendingSystemRegistrarProposedAt = 0;

        emit SystemRegistrarProposalCancelled(account);
    }

    function registrar() external view returns (address) {
        return _registrar;
    }

    function guardian() external view returns (address) {
        return _guardian;
    }

    function isSystemRegistrar(address account) external view returns (bool) {
        return _systemRegistrars[account];
    }

    function approvalsPerDayCap() external view returns (uint32) {
        return _approvalsPerDayCap;
    }

    function approvalsToday() external view returns (uint32) {
        if (_approvalsDay != uint64(block.timestamp / 1 days)) return 0;
        return _approvalsTodayCount;
    }

    function caseRefOf(address account) external view returns (bytes32) {
        return _caseRef[account];
    }

    function isAllowed(address account) external view returns (bool) {
        return _systemAccounts[account] || _allowedUntil[account] >= uint64(block.timestamp);
    }

    function allowedUntil(address account) external view returns (uint64) {
        return _allowedUntil[account];
    }

    function basisOf(address account) external view returns (uint8) {
        return _basis[account];
    }

    function isSystemAccount(address account) external view returns (bool) {
        return _systemAccounts[account];
    }

    function _countApproval() private {
        uint64 today = uint64(block.timestamp / 1 days);
        if (_approvalsDay != today) {
            _approvalsDay = today;
            _approvalsTodayCount = 1;
            return;
        }
        if (_approvalsTodayCount >= _approvalsPerDayCap) revert DailyCapReached();
        _approvalsTodayCount += 1;
    }

    function _requireProposalReady(uint256 proposedAt) private view {
        if (block.timestamp < proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
