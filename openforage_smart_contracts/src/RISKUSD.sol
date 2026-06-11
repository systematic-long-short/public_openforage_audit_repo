// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
/// @dev OF-16-006: OZ 5.x ReentrancyGuard uses ERC-7201 namespaced storage — inherently upgrade-safe.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./IForageGovernorPause.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IBlocklist.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev OF-I23: Pause semantics — when paused, standard transfers between non-exempt addresses
/// are blocked. Mint remains available (gated by its own whenNotPaused). Burn bypasses pause
/// (OF-M06) to allow emergency loss recording via the minter (RISKUSDVault). Protocol
/// contracts (StakingQueue, RISKUSDVault) are marked transfer-exempt via setTransferExempt()
/// and can send/receive RISKUSD even during pause (PHASE4A-017).
contract RISKUSD is
    Initializable,
    ERC20Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile
{
    // Custom errors
    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedMinter();
    error UnauthorizedPauseControl(address caller);
    error RenounceOwnershipDisabled();
    error NotPendingMinter();
    error FinalizeDelayNotElapsed(); // OF-NEW-04 (12th audit)
    error ProposalExpired(); // OF-NEW-04 (12th audit)
    error NoPendingForageGovernor(); // OF-15-005
    error BlockedAddress(address account);

    // Events
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event MinterProposed(address indexed currentMinter, address indexed pendingMinter);
    event MinterSetByOwner(address indexed currentMinter, address indexed pendingMinter); // OF-13-025/052
    event ForageGovernorSet(address indexed oldGovernor, address indexed newGovernor);
    event ForageGovernorProposed(address indexed current, address indexed pending); // OF-15-005
    event TransferExemptSet(address indexed account, bool exempt);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);

    // Constants
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-NEW-04 (12th audit)

    // State
    address internal _minter;
    address internal _forageGovernor;
    /// @dev PHASE4A-017: Protocol contracts exempt from transfer pause (StakingQueue, RISKUSDVault)
    mapping(address => bool) internal _transferExempt;
    /// @dev OF-003: Pending minter for two-step handoff
    address internal _pendingMinter;
    /// @dev OF-NEW-04 (12th audit): Proposal timestamp for finalize delay enforcement
    uint256 internal _minterProposedAt;

    /// @dev OF-15-005: Pending ForageGovernor for two-step setter
    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;

    /// @dev OF-16-015: EnumerableSet for on-chain enumeration of exempt addresses.
    /// Uses 2 storage slots (length + mapping) from the gap.
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _exemptAddressSet;
    address internal _blocklist;

    /// @dev Reserved storage gap for future upgrades (47 - 2 pending ForageGovernor - 2 exempt set - 1 blocklist = 42)
    uint256[42] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner_) external initializer {
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __ERC20_init("RISKUSD", "RISKUSD");
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();
        // OF-I02: UUPSUpgradeable has no init in OZ 5.x (stateless)
    }

    function mint(address to, uint256 amount) external whenNotPaused nonReentrant {
        if (msg.sender != _minter) revert UnauthorizedMinter();
        _requireNotBlocked(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @notice OF-M06: burn bypasses pause for minter to allow emergency loss recording.
    /// OF-16-032: Intentional asymmetry — burn() is NOT gated by whenNotPaused, but mint() IS.
    /// Rationale: the loss pipeline (burnForLoss → absorbLoss → burn) must complete even when
    /// the protocol is paused to maintain solvency invariants. Mint is paused because new deposits
    /// should be blocked during emergencies.
    /// @notice OF-L16: Minter burn authority is intentional design — the minter (RISKUSDVault)
    /// must be able to burn RISKUSD for loss accounting without holder consent.
    function burn(address from, uint256 amount) external nonReentrant {
        if (msg.sender != _minter) revert UnauthorizedMinter();
        _requireNotBlocked(msg.sender);
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _requireNotBlocked(msg.sender);
        if (value != 0) {
            _requireNotBlocked(spender);
        }
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _requireNotBlocked(msg.sender);
        return super.transferFrom(from, to, value);
    }

    /// @notice OF-15-047: setMinter now delegates to proposeMinter for single-path consistency.
    function setMinter(address minter_) external onlyOwner {
        proposeMinter(minter_);
    }

    /// @notice OF-003: Propose a new minter (two-step handoff). Only owner can propose.
    function proposeMinter(address newMinter_) public onlyOwner {
        if (newMinter_ == address(0)) revert ZeroAddress();
        _pendingMinter = newMinter_;
        _minterProposedAt = block.timestamp; // OF-NEW-04 (12th audit)
        emit MinterProposed(_minter, newMinter_);
    }

    /// @notice OF-003: Accept the pending minter role. Only the pending minter can call.
    /// @dev OF-NEW-04 (12th audit): Enforces FINALIZE_DELAY and PROPOSAL_EXPIRY.
    function acceptMinter() external {
        if (msg.sender != _pendingMinter) revert NotPendingMinter();
        if (block.timestamp < _minterProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _minterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldMinter = _minter;
        _minter = _pendingMinter;
        _pendingMinter = address(0);
        _minterProposedAt = 0;
        emit MinterUpdated(oldMinter, _minter);
    }

    /// @notice OF-NEW-04 (12th audit): Owner-side finalization for minter change (for contract recipients).
    function finalizeMinter() external onlyOwner {
        if (_pendingMinter == address(0)) revert ZeroAddress();
        if (block.timestamp < _minterProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _minterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldMinter = _minter;
        _minter = _pendingMinter;
        _pendingMinter = address(0);
        _minterProposedAt = 0;
        emit MinterUpdated(oldMinter, _minter);
    }

    /// @notice OF-003: View the pending minter address.
    function pendingMinter() external view returns (address) {
        return _pendingMinter;
    }

    /// @notice OF-L06: Clear the pending minter to prevent stale proposals surviving UUPS upgrades.
    function clearPendingMinter() external onlyOwner {
        _pendingMinter = address(0);
        _minterProposedAt = 0; // OF-NEW-04 (12th audit)
    }

    // OF-19-002: owner, governor, or guardian module can pause/unpause
    function pause() external {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _pause();
    }

    function unpause() external {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _unpause();
    }

    /// @dev OF-19-002: Check if caller is the GuardianModule via ForageGovernor query.
    function _isGuardianModule(address caller) internal view returns (bool) {
        if (_forageGovernor == address(0) || _forageGovernor.code.length == 0) return false;
        try IForageGovernorPause(_forageGovernor).guardianModule() returns (address gm) {
            return caller == gm && gm != address(0);
        } catch {
            return false;
        }
    }

    /// @notice OF-15-005: setForageGovernor now only proposes — no instant effect.
    /// Use finalizeForageGovernor() to complete the change after FINALIZE_DELAY.
    function setForageGovernor(address forageGovernor_) external onlyOwner {
        if (forageGovernor_ == address(0)) revert ZeroAddress();
        _pendingForageGovernor = forageGovernor_;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, forageGovernor_);
    }

    /// @notice OF-15-005: Finalize the pending ForageGovernor after FINALIZE_DELAY.
    function finalizeForageGovernor() external onlyOwner {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldGovernor = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorSet(oldGovernor, _forageGovernor);
    }

    /// @notice OF-15-005: Clear pending ForageGovernor to prevent stale proposals.
    function clearPendingForageGovernor() external onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    /// @dev PHASE4A-017: Set transfer exemption for protocol contracts.
    /// Exempt addresses can send/receive RISKUSD even when paused.
    /// Only owner can set; intended for StakingQueue and RISKUSDVault.
    function setTransferExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _transferExempt[account] = exempt;
        // OF-16-015: Maintain EnumerableSet for on-chain enumeration
        if (exempt) {
            _exemptAddressSet.add(account);
        } else {
            _exemptAddressSet.remove(account);
        }
        emit TransferExemptSet(account, exempt);
    }

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    /// @dev Returns whether an address is exempt from transfer pause.
    function isTransferExempt(address account) external view returns (bool) {
        return _transferExempt[account];
    }

    /// @notice OF-16-015: On-chain enumeration of all exempt addresses.
    function exemptAddresses() external view returns (address[] memory) {
        return _exemptAddressSet.values();
    }

    function _update(address from, address to, uint256 value) internal override {
        // Block transfers when paused — mint/burn have separate whenNotPaused guards (OF-029)
        // PHASE4A-017: only protocol-originated transfers bypass pause
        if (from != address(0) && to != address(0)) {
            if (paused() && !_transferExempt[from]) {
                revert EnforcedPause();
            }
        }
        if (from != address(0)) {
            _requireNotBlocked(from);
        }
        if (to != address(0)) {
            _requireNotBlocked(to);
        }
        super._update(from, to, value);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function minter() external view returns (address) {
        return _minter;
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    /// @dev OF-L06: Auto-clear pending minter on every upgrade to prevent stale proposals
    /// from surviving UUPS upgrades and allowing outdated addresses to call acceptMinter().
    /// @dev OF-15-005: Also clear pending ForageGovernor.
    function _authorizeUpgrade(address) internal override onlyOwner {
        _pendingMinter = address(0);
        _minterProposedAt = 0; // OF-NEW-04 (12th audit)
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }
}
