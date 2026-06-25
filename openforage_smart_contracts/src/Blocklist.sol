// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "./FinalizeDelayProfile.sol";

/// @title Blocklist
/// @notice Address-only emergency blocklist with single-stage guardian adds and delayed owner removals.
contract Blocklist is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, FinalizeDelayProfile {
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

    event AddressBlocked(address indexed account, uint256 blockedUntil);
    event UnblockProposed(address indexed account, uint256 proposedAt);
    event AddressUnblocked(address indexed account);
    event UnblockCancelled(address indexed account);
    event GuardianProposed(address indexed currentGuardian, address indexed pendingGuardian, uint256 proposedAt);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event GuardianProposalCancelled(address indexed pendingGuardian);

    uint256 public constant BLOCK_DURATION = 365 days;
    uint256 public constant PROPOSAL_EXPIRY = 30 days;

    address private _guardian;
    address private _pendingGuardian;
    uint256 private _pendingGuardianProposedAt;

    mapping(address => uint256) public blockedUntil;
    mapping(address => uint256) public pendingUnblock;
    mapping(address => Checkpoints.Trace208) private _blockedUntilCheckpoints;
    mapping(address => uint256) private _preCheckpointBlockedUntil;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address guardian_, address initialOwner_) external initializer {
        if (guardian_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();

        _guardian = guardian_;
    }

    function blockAddress(address account) external {
        if (msg.sender != _guardian) revert UnauthorizedGuardian();
        if (account == address(0)) revert ZeroAddress();

        uint256 newExpiry = block.timestamp + BLOCK_DURATION;
        uint256 currentExpiry = blockedUntil[account];
        _recordPreCheckpointLegacyExpiry(account, currentExpiry);
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
    }

    function proposeUnblock(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (!isBlocked(account)) revert NotBlocked();

        pendingUnblock[account] = block.timestamp;
        emit UnblockProposed(account, block.timestamp);
    }

    function finalizeUnblock(address account) external onlyOwner {
        uint256 proposedAt = pendingUnblock[account];
        if (proposedAt == 0) revert NoPendingUnblock();
        _requireProposalReady(proposedAt);

        _recordPreCheckpointLegacyExpiry(account, blockedUntil[account]);
        blockedUntil[account] = 0;
        (uint208 previousExpiry, uint208 writtenExpiry) =
            _blockedUntilCheckpoints[account].push(uint48(block.timestamp), 0);
        previousExpiry;
        writtenExpiry;
        pendingUnblock[account] = 0;

        emit AddressUnblocked(account);
    }

    function cancelUnblock(address account) external onlyOwner {
        if (pendingUnblock[account] == 0) revert NoPendingUnblock();

        pendingUnblock[account] = 0;
        emit UnblockCancelled(account);
    }

    function proposeGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        if (guardian_ == _guardian) revert InvalidGuardian();

        _pendingGuardian = guardian_;
        _pendingGuardianProposedAt = block.timestamp;

        emit GuardianProposed(_guardian, guardian_, block.timestamp);
    }

    function finalizeGuardian() external onlyOwner {
        address newGuardian = _pendingGuardian;
        if (newGuardian == address(0)) revert NoPendingGuardian();
        _requireProposalReady(_pendingGuardianProposedAt);

        address oldGuardian = _guardian;
        _guardian = newGuardian;
        _pendingGuardian = address(0);
        _pendingGuardianProposedAt = 0;

        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    function cancelGuardianProposal() external onlyOwner {
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

    function isBlocked(address account) public view returns (bool) {
        uint256 expiry = blockedUntil[account];
        return expiry != 0 && expiry >= block.timestamp;
    }

    function wasBlockedAt(address account, uint256 timepoint) public view returns (bool) {
        if (timepoint > type(uint48).max) return false;

        uint256 expiry = _blockedUntilCheckpoints[account].upperLookupRecent(uint48(timepoint));
        return expiry != 0 && expiry >= timepoint;
    }

    /// @notice Migration-aware historical block state for governance vote exclusion.
    /// @dev `wasBlockedAt` remains checkpoint-only; this function applies the explicit
    /// legacy `blockedUntil` fallback until an account's first checkpoint becomes authoritative.
    function wasEffectivelyBlockedAt(address account, uint256 timepoint) public view returns (bool) {
        if (wasBlockedAt(account, timepoint)) return true;
        if (timepoint > type(uint48).max) return false;

        Checkpoints.Trace208 storage checkpoints = _blockedUntilCheckpoints[account];
        uint256 checkpointCount = checkpoints.length();
        if (checkpointCount != 0) {
            Checkpoints.Checkpoint208 memory firstCheckpoint = checkpoints.at(0);
            if (uint48(timepoint) >= firstCheckpoint._key) return false;

            uint256 preCheckpointExpiry = _preCheckpointBlockedUntil[account];
            return preCheckpointExpiry != 0 && preCheckpointExpiry >= timepoint;
        }

        uint256 legacyExpiry = blockedUntil[account];
        return legacyExpiry != 0 && legacyExpiry >= timepoint;
    }

    function _recordPreCheckpointLegacyExpiry(address account, uint256 legacyExpiry) private {
        if (legacyExpiry != 0 && _blockedUntilCheckpoints[account].length() == 0) {
            _preCheckpointBlockedUntil[account] = legacyExpiry;
        }
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
