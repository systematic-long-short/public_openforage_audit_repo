// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IAllowlist.sol";

/// @title Allowlist
/// @notice UUPS investor and operator registry: a registrar approves investors under a per-UTC-day
///         cap, the owner approves operators without expiry, and registrar, guardian and system
///         registrars rotate behind the profile finalize delay.
contract Allowlist is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, FinalizeDelayProfile {
    using Checkpoints for Checkpoints.Trace208;

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
    error NotVoteEligibilityObserver();
    error VotingTokenAlreadyRegistered(address token);
    error TooManyVestingSources(address beneficiary, uint256 count, uint256 maximum);
    error VestingSourceRegistrationUnderflow(address beneficiary);
    error TimestampOutOfRange(uint256 timestamp);
    error AllowlistFreshDeploymentRequired(uint256 layoutVersion);
    error FreshInitializationOnExistingState(
        uint256 layoutVersion, address currentOwner, address registrar, address guardian, bool historyInitialized
    );
    error CurrentOwnerMustRemainEligible(address account);

    uint256 public constant PROPOSAL_EXPIRY = 30 days;

    event Approved(address indexed account, uint64 until, uint8 basis, bytes32 caseRef);
    event OperatorApproved(address indexed account);
    event Revoked(address indexed account, address indexed by);
    event SystemAccountSet(address indexed account, bool isSystem);
    event VestingSourceRegistrationPendingSet(address indexed source, bool pending);
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
    event VoteEligibilityObserverSet(address indexed previous, address indexed next);

    uint256 private constant APPROVAL_TERM_LIMIT = 400 days;
    uint32 private constant DEFAULT_APPROVALS_PER_DAY_CAP = 50;
    uint32 private constant MAX_VESTING_SOURCES_PER_BENEFICIARY = 32;

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
    address private _voteEligibilityObserver;
    uint48 private _eligibilityHistoryStart;
    bool private _eligibilityHistoryInitialized;
    mapping(address => Checkpoints.Trace208) private _eligibilityCheckpoints;
    mapping(address => uint64) private _preCheckpointAllowedUntil;
    mapping(address => bool) private _preCheckpointSystemAccount;
    mapping(address => bool) private _eligibilityBaselineSet;
    mapping(address => address) private _vestingSourceBeneficiary;
    mapping(address => uint32) public vestingSourceCount;
    mapping(address => bool) private _pendingVestingSourceRegistration;

    uint256[28] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyEligibleOwner() {
        _requireEligibleOwner();
        _;
    }

    modifier freshOnly() {
        _requireFreshLayout();
        _;
    }

    function initialize(address owner_, address guardian_, uint64 finalizeDelay_) external initializer {
        _requireFreshInitializationState();
        if (owner_ == address(0)) revert ZeroAddress();
        if (guardian_ == address(0)) revert ZeroAddress();
        require(finalizeDelay_ == _finalizeDelay());

        __Ownable_init(owner_);
        __Ownable2Step_init();

        _guardian = guardian_;
        _approvalsPerDayCap = DEFAULT_APPROVALS_PER_DAY_CAP;
        _ensureEligibilityHistory();
        _approveOperator(owner_);
        if (guardian_ != owner_) _approveOperator(guardian_);
        _setFreshLayoutVersion();
    }

    function _requireFreshInitializationState() private view {
        uint256 layoutVersion = _freshLayoutVersion();
        address currentOwner = super.owner();
        if (
            address(this).code.length != 0 || layoutVersion != 0 || currentOwner != address(0)
                || _registrar != address(0) || _guardian != address(0) || _approvalsPerDayCap != 0
                || _eligibilityHistoryInitialized || _pendingRegistrar != address(0) || _pendingRegistrarProposedAt != 0
                || _pendingGuardian != address(0) || _pendingGuardianProposedAt != 0
                || _pendingSystemRegistrar != address(0) || _pendingSystemRegistrarIsSystem
                || _pendingSystemRegistrarProposedAt != 0 || _approvalsDay != 0 || _approvalsTodayCount != 0
                || _eligibilityHistoryStart != 0 || _voteEligibilityObserver != address(0)
        ) {
            revert FreshInitializationOnExistingState(
                layoutVersion, currentOwner, _registrar, _guardian, _eligibilityHistoryInitialized
            );
        }
    }

    function _requireFreshLayout() private view {
        uint256 layoutVersion = _freshLayoutVersion();
        if (layoutVersion != 1) {
            revert AllowlistFreshDeploymentRequired(layoutVersion);
        }
    }

    function _freshLayoutVersion() private view returns (uint256) {
        return StorageSlot.getUint256Slot(_freshLayoutSlot()).value;
    }

    function _setFreshLayoutVersion() private {
        StorageSlot.getUint256Slot(_freshLayoutSlot()).value = 1;
    }

    function _freshLayoutSlot() private pure returns (bytes32) {
        return bytes32(
            uint256(keccak256(abi.encode(uint256(keccak256("openforage.storage.AllowlistFreshLayout")) - 1)))
                & ~uint256(0xff)
        );
    }

    function owner() public view override returns (address) {
        _requireFreshLayout();
        return super.owner();
    }

    function approve(address account, uint64 until, uint8 basis_, bytes32 caseRef_) external freshOnly {
        if (msg.sender != _registrar) revert NotRegistrar();
        if (!_isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (account == owner()) revert CurrentOwnerMustRemainEligible(account);
        if (until > uint64(block.timestamp + APPROVAL_TERM_LIMIT)) revert ExpiryTooFar();
        _countApproval();
        _captureEligibilityBaseline(account);

        _allowedUntil[account] = until;
        _basis[account] = basis_;
        _caseRef[account] = caseRef_;

        emit Approved(account, until, basis_, caseRef_);
        _recordEligibilityChange(account);
    }

    function approveOperator(address account) external onlyEligibleOwner {
        _approveOperator(account);
    }

    function approveVestingBeneficiary(address account) external onlyEligibleOwner {
        if (account == address(0)) revert ZeroAddress();
        if (account == owner()) revert CurrentOwnerMustRemainEligible(account);
        if (block.timestamp > uint256(type(uint64).max) - APPROVAL_TERM_LIMIT) {
            revert TimestampOutOfRange(block.timestamp);
        }
        uint64 until = uint64(block.timestamp + APPROVAL_TERM_LIMIT);
        _countApproval();
        _captureEligibilityBaseline(account);
        _allowedUntil[account] = until;
        _basis[account] = 0;
        _caseRef[account] = bytes32(0);
        emit Approved(account, until, 0, bytes32(0));
        _recordEligibilityChange(account);
    }

    function revoke(address account) external freshOnly {
        if (msg.sender != _registrar && msg.sender != _guardian) revert NotGuardianOrRegistrar();
        if (!_isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);
        bool currentOwner = account == owner();
        if (
            currentOwner
                && (_vestingSourceBeneficiary[account] != address(0) || _pendingVestingSourceRegistration[account])
        ) {
            revert CurrentOwnerMustRemainEligible(account);
        }

        _captureEligibilityBaseline(account);
        _allowedUntil[account] = currentOwner ? type(uint64).max : 0;
        _basis[account] = 0;
        _caseRef[account] = bytes32(0);

        if (currentOwner && _systemAccounts[account]) {
            _updateVestingSourceRegistration(account, false);
            _systemAccounts[account] = false;
            emit SystemAccountSet(account, false);
        }

        if (currentOwner) emit OperatorApproved(account);
        emit Revoked(account, msg.sender);
        _recordEligibilityChange(account);
    }

    function shrinkApprovalsPerDayCap(uint32 newCap) external freshOnly {
        if (msg.sender != owner() && msg.sender != _guardian) revert NotOwnerOrGuardian();
        if (!_isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);
        if (newCap >= _approvalsPerDayCap) revert CapNotShrunk();

        uint32 previous = _approvalsPerDayCap;
        _approvalsPerDayCap = newCap;

        emit ApprovalsPerDayCapShrunk(previous, newCap);
    }

    function setSystemAccount(address account, bool isSystem) external freshOnly {
        if (msg.sender != owner() && !_systemRegistrars[msg.sender]) revert NotSystemRegistrar();
        if (!_isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        if (account == owner() && !isSystem && _allowedUntil[account] != type(uint64).max) {
            revert CurrentOwnerMustRemainEligible(account);
        }

        _captureEligibilityBaseline(account);
        _updateVestingSourceRegistration(account, isSystem);
        _systemAccounts[account] = isSystem;

        emit SystemAccountSet(account, isSystem);
        _recordEligibilityChange(account);
    }

    function proposeRegistrar(address account) external onlyEligibleOwner {
        _pendingRegistrar = account;
        _pendingRegistrarProposedAt = block.timestamp;

        emit RegistrarProposed(account, block.timestamp);
    }

    function finalizeRegistrar() external onlyEligibleOwner {
        address account = _pendingRegistrar;
        if (account == address(0)) revert NoPendingProposal();
        _requireProposalReady(_pendingRegistrarProposedAt);
        if (!_isAllowed(account)) revert IAllowlist.CallerNotAllowed(account);

        address previous = _registrar;
        _registrar = account;
        _pendingRegistrar = address(0);
        _pendingRegistrarProposedAt = 0;

        emit RegistrarUpdated(previous, account);
    }

    function cancelRegistrar() external onlyEligibleOwner {
        address account = _pendingRegistrar;
        if (account == address(0)) revert NoPendingProposal();

        _pendingRegistrar = address(0);
        _pendingRegistrarProposedAt = 0;

        emit RegistrarProposalCancelled(account);
    }

    function proposeGuardian(address account) external onlyEligibleOwner {
        _pendingGuardian = account;
        _pendingGuardianProposedAt = block.timestamp;

        emit GuardianProposed(account, block.timestamp);
    }

    function finalizeGuardian() external onlyEligibleOwner {
        address account = _pendingGuardian;
        if (account == address(0)) revert NoPendingProposal();
        _requireProposalReady(_pendingGuardianProposedAt);
        if (!_isAllowed(account)) revert IAllowlist.CallerNotAllowed(account);

        address previous = _guardian;
        _guardian = account;
        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianUpdated(previous, account);
    }

    function cancelGuardian() external onlyEligibleOwner {
        address account = _pendingGuardian;
        if (account == address(0)) revert NoPendingProposal();

        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianProposalCancelled(account);
    }

    function proposeSystemRegistrar(address account, bool isSystem) external onlyEligibleOwner {
        _pendingSystemRegistrar = account;
        _pendingSystemRegistrarIsSystem = isSystem;
        _pendingSystemRegistrarProposedAt = block.timestamp;

        emit SystemRegistrarProposed(account, isSystem, block.timestamp);
    }

    function finalizeSystemRegistrar() external onlyEligibleOwner {
        address account = _pendingSystemRegistrar;
        if (account == address(0)) revert NoPendingProposal();
        _requireProposalReady(_pendingSystemRegistrarProposedAt);

        bool isSystem = _pendingSystemRegistrarIsSystem;
        if (isSystem && !_isAllowed(account)) revert IAllowlist.CallerNotAllowed(account);
        _systemRegistrars[account] = isSystem;
        _pendingSystemRegistrar = address(0);
        _pendingSystemRegistrarIsSystem = false;
        _pendingSystemRegistrarProposedAt = 0;

        emit SystemRegistrarUpdated(account, isSystem);
    }

    function cancelSystemRegistrar() external onlyEligibleOwner {
        address account = _pendingSystemRegistrar;
        if (account == address(0)) revert NoPendingProposal();

        _pendingSystemRegistrar = address(0);
        _pendingSystemRegistrarIsSystem = false;
        _pendingSystemRegistrarProposedAt = 0;

        emit SystemRegistrarProposalCancelled(account);
    }

    function registrar() external view freshOnly returns (address) {
        return _registrar;
    }

    function guardian() external view freshOnly returns (address) {
        return _guardian;
    }

    function isSystemRegistrar(address account) external view freshOnly returns (bool) {
        return _systemRegistrars[account];
    }

    function approvalsPerDayCap() external view freshOnly returns (uint32) {
        return _approvalsPerDayCap;
    }

    function approvalsToday() external view freshOnly returns (uint32) {
        if (_approvalsDay != uint64(block.timestamp / 1 days)) return 0;
        return _approvalsTodayCount;
    }

    function caseRefOf(address account) external view freshOnly returns (bytes32) {
        return _caseRef[account];
    }

    function isAllowed(address account) external view freshOnly returns (bool) {
        return _isAllowed(account);
    }

    function isAllowedAt(address account, uint256 timepoint) external view freshOnly returns (bool) {
        if (timepoint > type(uint48).max) return false;
        if (!_eligibilityHistoryInitialized || timepoint < _eligibilityHistoryStart) return true;

        (uint64 allowedUntil_, bool systemAccount_) = _eligibilityStateAt(account, uint48(timepoint));
        return _isAllowedStateAt(allowedUntil_, systemAccount_, timepoint);
    }

    function isSystemAccountAt(address account, uint256 timepoint) external view freshOnly returns (bool) {
        if (timepoint > type(uint48).max) return false;
        if (!_eligibilityHistoryInitialized || timepoint < _eligibilityHistoryStart) return _systemAccounts[account];

        (, bool systemAccount_) = _eligibilityStateAt(account, uint48(timepoint));
        return systemAccount_;
    }

    function supportsVoteEligibilityObserver() external pure returns (bool) {
        return true;
    }

    function registerVoteEligibilityObserver() external freshOnly {
        if (msg.sender.code.length == 0 || !_systemAccounts[msg.sender]) revert NotSystemRegistrar();
        address previous = _voteEligibilityObserver;
        if (previous != address(0) && previous != msg.sender) revert VotingTokenAlreadyRegistered(previous);

        _voteEligibilityObserver = msg.sender;
        _ensureEligibilityHistory();
        emit VoteEligibilityObserverSet(previous, msg.sender);
    }

    function unregisterVoteEligibilityObserver() external freshOnly {
        if (_voteEligibilityObserver == address(0)) return;
        if (msg.sender != _voteEligibilityObserver) revert NotVoteEligibilityObserver();

        address previous = _voteEligibilityObserver;
        _voteEligibilityObserver = address(0);
        emit VoteEligibilityObserverSet(previous, address(0));
    }

    function allowedUntil(address account) external view freshOnly returns (uint64) {
        return _allowedUntil[account];
    }

    function maxVestingSourcesPerBeneficiary() external pure returns (uint256) {
        return MAX_VESTING_SOURCES_PER_BENEFICIARY;
    }

    function basisOf(address account) external view freshOnly returns (uint8) {
        return _basis[account];
    }

    function isSystemAccount(address account) external view freshOnly returns (bool) {
        return _systemAccounts[account];
    }

    function vestingSourceBeneficiary(address source) external view freshOnly returns (address) {
        return _vestingSourceBeneficiary[source];
    }

    function isVestingSourceRegistrationPending(address source) external view freshOnly returns (bool) {
        return _pendingVestingSourceRegistration[source];
    }

    function _countApproval() private {
        if (_approvalsPerDayCap == 0) revert DailyCapReached();
        uint64 today = uint64(block.timestamp / 1 days);
        if (_approvalsDay != today) {
            _approvalsDay = today;
            _approvalsTodayCount = 1;
            return;
        }
        if (_approvalsTodayCount >= _approvalsPerDayCap) revert DailyCapReached();
        _approvalsTodayCount += 1;
    }

    function _approveOperator(address account) private {
        _captureEligibilityBaseline(account);
        _allowedUntil[account] = type(uint64).max;
        _basis[account] = 0;
        _caseRef[account] = bytes32(0);

        emit OperatorApproved(account);
        _recordEligibilityChange(account);
    }

    function _requireEligibleOwner() private view {
        if (msg.sender != owner() || !_isAllowed(msg.sender)) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    function _requireProposalReady(uint256 proposedAt) private view {
        if (block.timestamp < proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
    }

    function _ensureEligibilityHistory() private {
        if (_eligibilityHistoryInitialized) return;
        if (block.timestamp > type(uint48).max) revert TimestampOutOfRange(block.timestamp);
        _eligibilityHistoryStart = uint48(block.timestamp);
        _eligibilityHistoryInitialized = true;
    }

    function _captureEligibilityBaseline(address account) private {
        _ensureEligibilityHistory();
        if (_eligibilityBaselineSet[account]) return;

        _preCheckpointAllowedUntil[account] = _allowedUntil[account];
        _preCheckpointSystemAccount[account] = _systemAccounts[account];
        _eligibilityBaselineSet[account] = true;
    }

    function _eligibilityStateAt(address account, uint48 timepoint)
        private
        view
        returns (uint64 allowedUntil_, bool systemAccount_)
    {
        Checkpoints.Trace208 storage checkpoints = _eligibilityCheckpoints[account];
        uint256 checkpointCount = checkpoints.length();
        if (checkpointCount != 0) {
            Checkpoints.Checkpoint208 memory firstCheckpoint = checkpoints.at(0);
            if (timepoint >= firstCheckpoint._key) {
                uint208 state = checkpoints.upperLookupRecent(timepoint);
                return (uint64(state >> 1), (state & 1) != 0);
            }
        }

        if (_eligibilityBaselineSet[account]) {
            return (_preCheckpointAllowedUntil[account], _preCheckpointSystemAccount[account]);
        }
        return (_allowedUntil[account], _systemAccounts[account]);
    }

    function _recordEligibilityChange(address account) private {
        if (block.timestamp > type(uint48).max) revert TimestampOutOfRange(block.timestamp);
        uint208 state = (uint208(_allowedUntil[account]) << 1) | (_systemAccounts[account] ? 1 : 0);
        _eligibilityCheckpoints[account].push(uint48(block.timestamp), state);

        address observer = _voteEligibilityObserver;
        if (observer != address(0)) IVoteEligibilityObserver(observer).syncVoteEligibility(account);
    }

    function _updateVestingSourceRegistration(address source, bool isSystem) private {
        address beneficiary_ = _vestingSourceBeneficiary[source];
        if (!isSystem) {
            _setVestingSourceRegistrationPending(source, false);
            if (beneficiary_ == address(0)) return;
            uint32 previousCount = vestingSourceCount[beneficiary_];
            if (previousCount == 0) revert VestingSourceRegistrationUnderflow(beneficiary_);
            vestingSourceCount[beneficiary_] = previousCount - 1;
            delete _vestingSourceBeneficiary[source];
            return;
        }
        if (source.code.length == 0) {
            if (beneficiary_ == address(0)) _setVestingSourceRegistrationPending(source, true);
            return;
        }
        if (beneficiary_ != address(0)) return;

        (bool ok, bytes memory data) =
            source.staticcall(abi.encodeWithSelector(IVestingBeneficiarySource.beneficiary.selector));
        if (!ok || data.length != 32) return;
        beneficiary_ = abi.decode(data, (address));
        if (beneficiary_ == address(0)) return;

        uint32 sourceCount = vestingSourceCount[beneficiary_];
        uint256 maximum = MAX_VESTING_SOURCES_PER_BENEFICIARY;
        if (sourceCount >= maximum) revert TooManyVestingSources(beneficiary_, sourceCount, maximum);
        _vestingSourceBeneficiary[source] = beneficiary_;
        vestingSourceCount[beneficiary_] = sourceCount + 1;
        _setVestingSourceRegistrationPending(source, false);
    }

    function _setVestingSourceRegistrationPending(address source, bool pending) private {
        if (_pendingVestingSourceRegistration[source] == pending) return;
        _pendingVestingSourceRegistration[source] = pending;
        emit VestingSourceRegistrationPendingSet(source, pending);
    }

    function _isAllowed(address account) private view returns (bool) {
        return _systemAccounts[account] || _allowedUntil[account] >= uint64(block.timestamp);
    }

    function _isAllowedStateAt(uint64 allowedUntil_, bool systemAccount_, uint256 timepoint)
        private
        pure
        returns (bool)
    {
        return systemAccount_ || allowedUntil_ >= timepoint;
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function transferOwnership(address newOwner) public override onlyEligibleOwner {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override freshOnly {
        if (!_isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);
        if (!_systemAccounts[msg.sender] && _allowedUntil[msg.sender] != type(uint64).max) {
            revert CurrentOwnerMustRemainEligible(msg.sender);
        }
        super.acceptOwnership();
    }

    function _authorizeUpgrade(address) internal override onlyEligibleOwner {}
}
