// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "./AllowlistGatedUpgradeable.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IAllowlist.sol";

/// @title Blocklist
/// @notice Address-only emergency blocklist with single-stage guardian adds and delayed owner removals.
contract Blocklist is
    Initializable,
    AllowlistGatedUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    FinalizeDelayProfile
{
    using Checkpoints for Checkpoints.Trace208;

    error UnauthorizedGuardian();
    error ZeroAddress();
    error NotBlocked();
    error NoPendingUnblock();
    error NoPendingGuardian();
    error InvalidGuardian();
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error RenounceOwnershipDisabled();
    error BlocklistLegacyStateUnsupported(uint256 storedVersion);
    error NotVoteEligibilityObserver();
    error VoteEligibilityObserverAlreadyRegistered(address observer);
    error InvalidVoteEligibilityObserver(address observer);

    event AddressBlocked(address indexed account, uint256 blockedUntil);
    event UnblockProposed(address indexed account, uint256 proposedAt);
    event AddressUnblocked(address indexed account);
    event UnblockCancelled(address indexed account);
    event GuardianProposed(address indexed currentGuardian, address indexed pendingGuardian, uint256 proposedAt);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event GuardianProposalCancelled(address indexed pendingGuardian);
    event VoteEligibilityObserverSet(address indexed previous, address indexed next);

    uint256 public constant BLOCK_DURATION = 365 days;
    uint256 public constant PROPOSAL_EXPIRY = 30 days;

    address private _guardian;
    address private _pendingGuardian;
    uint256 private _pendingGuardianProposedAt;

    mapping(address => uint256) public blockedUntil;
    mapping(address => uint256) public pendingUnblock;
    mapping(address => Checkpoints.Trace208) private _blockedUntilCheckpoints;
    mapping(address => uint256) private _preCheckpointBlockedUntil;
    address private _voteEligibilityObserver;

    uint256 private _freshLayoutVersion;
    uint256[47] private __gap;

    modifier freshOnly() {
        uint256 version = _freshLayoutVersion;
        if (version != 1) revert BlocklistLegacyStateUnsupported(version);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address guardian_, address initialOwner_) external initializer {
        if (address(this).code.length != 0 || _freshLayoutVersion != 0 || owner() != address(0)) {
            revert BlocklistLegacyStateUnsupported(_freshLayoutVersion);
        }
        if (guardian_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();

        _guardian = guardian_;
        _freshLayoutVersion = 1;
    }

    function blockAddress(address account) external freshOnly onlyAllowedCaller {
        if (msg.sender != _guardian) revert UnauthorizedGuardian();
        if (account == address(0)) revert ZeroAddress();

        uint256 newExpiry = block.timestamp + BLOCK_DURATION;
        uint256 currentExpiry = blockedUntil[account];
        if (currentExpiry > newExpiry) {
            newExpiry = currentExpiry;
        }
        blockedUntil[account] = newExpiry;
        (uint208 previousExpiry, uint208 writtenExpiry) =
            _blockedUntilCheckpoints[account].push(uint48(block.timestamp), uint208(newExpiry));
        previousExpiry;
        writtenExpiry;
        if (pendingUnblock[account] != 0) {
            pendingUnblock[account] = 0;
            emit UnblockCancelled(account);
        }

        emit AddressBlocked(account, newExpiry);
        _notifyVoteEligibilityObserver(account);
    }

    function proposeUnblock(address account) external freshOnly onlyAllowedCaller onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (!isBlocked(account)) revert NotBlocked();

        pendingUnblock[account] = block.timestamp;
        emit UnblockProposed(account, block.timestamp);
    }

    function finalizeUnblock(address account) external freshOnly onlyAllowedCaller onlyOwner {
        uint256 proposedAt = pendingUnblock[account];
        if (proposedAt == 0) revert NoPendingUnblock();
        _requireProposalReady(proposedAt);

        blockedUntil[account] = 0;
        (uint208 previousExpiry, uint208 writtenExpiry) =
            _blockedUntilCheckpoints[account].push(uint48(block.timestamp), 0);
        previousExpiry;
        writtenExpiry;
        pendingUnblock[account] = 0;

        emit AddressUnblocked(account);
        _notifyVoteEligibilityObserver(account);
    }

    function cancelUnblock(address account) external freshOnly onlyAllowedCaller onlyOwner {
        if (pendingUnblock[account] == 0) revert NoPendingUnblock();

        pendingUnblock[account] = 0;
        emit UnblockCancelled(account);
    }

    function proposeGuardian(address guardian_) external freshOnly onlyAllowedCaller onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        if (guardian_ == _guardian) revert InvalidGuardian();
        if (!IAllowlist(allowlist()).isAllowed(guardian_)) revert IAllowlist.CallerNotAllowed(guardian_);

        _pendingGuardian = guardian_;
        _pendingGuardianProposedAt = block.timestamp;

        emit GuardianProposed(_guardian, guardian_, block.timestamp);
    }

    function finalizeGuardian() external freshOnly onlyAllowedCaller onlyOwner {
        address newGuardian = _pendingGuardian;
        if (newGuardian == address(0)) revert NoPendingGuardian();
        if (!IAllowlist(allowlist()).isAllowed(newGuardian)) revert IAllowlist.CallerNotAllowed(newGuardian);
        _requireProposalReady(_pendingGuardianProposedAt);

        address oldGuardian = _guardian;
        _guardian = newGuardian;
        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    function cancelGuardianProposal() external freshOnly onlyAllowedCaller onlyOwner {
        address cancelledGuardian = _pendingGuardian;
        if (cancelledGuardian == address(0)) revert NoPendingGuardian();

        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianProposalCancelled(cancelledGuardian);
    }

    function guardian() external view returns (address) {
        return _guardian;
    }

    function pendingGuardian() external view returns (address pendingGuardian_, uint256 proposedAt) {
        return (_pendingGuardian, _pendingGuardianProposedAt);
    }

    function supportsVoteEligibilityObserver() external pure returns (bool) {
        return true;
    }

    function registerVoteEligibilityObserver() external freshOnly onlyAllowedCaller {
        address allowlist_ = allowlist();
        bool systemAccount_;
        try IAllowlist(allowlist_).isSystemAccount(msg.sender) returns (bool value) {
            systemAccount_ = value;
        } catch {
            revert InvalidVoteEligibilityObserver(msg.sender);
        }
        if (msg.sender.code.length == 0 || !systemAccount_) revert InvalidVoteEligibilityObserver(msg.sender);

        address previous = _voteEligibilityObserver;
        if (previous != address(0) && previous != msg.sender) {
            revert VoteEligibilityObserverAlreadyRegistered(previous);
        }
        _voteEligibilityObserver = msg.sender;
        emit VoteEligibilityObserverSet(previous, msg.sender);
    }

    function unregisterVoteEligibilityObserver() external freshOnly {
        if (_voteEligibilityObserver == address(0)) return;
        if (msg.sender != _voteEligibilityObserver) revert NotVoteEligibilityObserver();

        address previous = _voteEligibilityObserver;
        _voteEligibilityObserver = address(0);
        emit VoteEligibilityObserverSet(previous, address(0));
    }

    function isBlocked(address account) public view returns (bool) {
        uint256 expiry = blockedUntil[account];
        return expiry != 0 && expiry >= block.timestamp;
    }

    function wasBlockedAt(address account, uint256 timepoint) public view returns (bool) {
        if (timepoint > type(uint48).max) return false;

        uint256 expiry = _blockedUntilCheckpoints[account].upperLookupRecent(uint48(timepoint));
        return expiry != 0 && expiry >= timepoint;
    }

    function _notifyVoteEligibilityObserver(address account) private {
        address observer = _voteEligibilityObserver;
        if (observer != address(0)) IVoteEligibilityObserver(observer).syncVoteEligibility(account);
    }

    function _requireProposalReady(uint256 proposedAt) private view {
        if (block.timestamp < proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override freshOnly onlyOwner {}

    function setAllowlist(address allowlist_) external freshOnly onlyOwner {
        _transitionAllowlist(allowlist_);
    }

    function transferOwnership(address newOwner) public override freshOnly onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override freshOnly onlyAllowedCaller {
        super.acceptOwnership();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        freshOnly
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
    }
}
