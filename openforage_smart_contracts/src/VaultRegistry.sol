// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IVaultRegistry.sol";

/// @dev OF-14-001: Minimal interface for RISKUSDVault lossPending query in startWindDown.
interface IRISKUSDVaultLossQuery {
    function vaultRegistry() external view returns (address);
    function lossPending() external view returns (bool);
    function lossPendingVaultId() external view returns (uint256);
}

interface ITierVaultAccountingQuery {
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

/// @title VaultRegistry — Central on-chain registry of all strategy vaults
/// @notice Stores per-vault configuration. Governance-only mutation via Ownable2Step.
/// @dev OF-I16: _allVaultIds is an append-only array — vault IDs are never removed.
/// Deactivated vaults transition through Paused → WindingDown states but remain in the
/// array. This ensures getAllVaults() always returns a complete historical record and
/// vault IDs are stable references across the protocol.
///
/// OF-006: VaultConfig struct and VaultStatus enum are defined in
/// interfaces/IVaultRegistry.sol as the single source of truth.
contract VaultRegistry is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, FinalizeDelayProfile {
    // ── Custom errors ──
    error ZeroAddress();
    error NotRISKUSDVault(); // OF-21-002: dedicated auth error for notifyLossResolved
    error VaultRegistryMismatch(); // OF-21-061: reciprocal wiring check
    error EmptyName();
    error EmptyAbbreviation();
    error DuplicateAbbreviation(string abbreviation);
    error ZeroCapacity();
    error InvalidSplitTotal(uint8 tier);
    error ZeroYieldSplit(uint8 tier);
    error InvalidVaultId();
    error VaultNotActive();
    error VaultNotPaused();
    error VaultAlreadyWindingDown();
    error VaultNotWindingDown();
    error VaultNotFound();
    error AbbreviationAlreadyReleased();
    error NonZeroTier0Lockup();
    error DuplicateTierVault();
    error RenounceOwnershipDisabled();
    error TierVaultsNotUsed();
    error LossPendingForVault(); // OF-14-001: cannot wind down vault with pending loss
    error LossCooldownActive(); // OF-16-002: cooldown after loss resolution
    error FinalizeDelayNotElapsed(); // OF-13-010
    error ProposalExpired(); // OF-13-010
    error NoPendingYieldSplits(); // OF-13-010
    error NoPendingCapacityCap(); // OF-13-028
    error NoPendingRISKUSDVault(); // OF-15-004
    error Deprecated(); // OF-15-004: dead code marker
    error InvalidRISKUSDVaultInterface(address target);
    error ResidualTierVaultAssets(address tierVault, uint256 assets);

    // ── Events ──
    event VaultAdded(uint256 indexed vaultId, string name, string abbreviation);
    event VaultPaused(uint256 indexed vaultId);
    event VaultResumed(uint256 indexed vaultId);
    event VaultWindingDown(uint256 indexed vaultId);
    event CapacityCapUpdated(uint256 indexed vaultId, uint256 oldCap, uint256 newCap);
    event YieldSplitsUpdated(uint256 indexed vaultId);
    event AbbreviationReleased(uint256 indexed vaultId, string abbreviation);
    event TierVaultsReleased(uint256 indexed vaultId);
    event YieldSplitsProposed(uint256 indexed vaultId); // OF-13-010
    event CapacityCapProposed(uint256 indexed vaultId, uint256 newCap); // OF-13-028
    event RISKUSDVaultProposed(address indexed current, address indexed pending); // OF-15-004
    event RISKUSDVaultUpdated(address indexed oldVault, address indexed newVault); // OF-15-004
    event LossResolutionBlockMigrated(uint256 oldValue, uint256 newValue);

    // ── Storage ──
    uint256 private _nextVaultId;
    uint256 private _deprecated_vaultCount; // OF-051: replaced by _allVaultIds.length
    mapping(uint256 => VaultConfig) private _vaults;
    uint256[] private _allVaultIds;
    mapping(bytes32 => uint256) private _abbreviationToVaultId;
    /// @dev OF-003: Global tracker for tier vault address uniqueness across all vaults.
    mapping(address => bool) private _tierVaultUsed;

    /// @dev OF-14-001: RISKUSDVault reference for lossPending query in startWindDown.
    /// Set via reinitializer(2) at upgrade time.
    /// INVARIANT: Must point to the canonical RISKUSDVault used by target treasury and custodian accounting.
    address private _riskusdVault;

    /// @dev OF-13-010: Pending yield splits for propose/finalize flow
    struct PendingYieldSplits {
        uint16[4] yieldSplitsBps;
        uint16[4] fundingBps;
        uint256 proposedAt;
    }
    mapping(uint256 => PendingYieldSplits) private _pendingYieldSplits;

    /// @dev OF-13-028: Pending capacity cap for propose/finalize flow
    struct PendingCapacityCap {
        uint256 capacityCap;
        uint256 proposedAt;
    }
    mapping(uint256 => PendingCapacityCap) private _pendingCapacityCap;

    /// @dev OF-15-004: Pending RISKUSDVault address for two-step setter.
    /// Packed: address (20 bytes) + uint48 timestamp (6 bytes) = 26 bytes → 1 slot.
    address private _pendingRISKUSDVault;
    uint48 private _pendingRISKUSDVaultTimestamp;

    // OF-13-010/028: FINALIZE_DELAY and PROPOSAL_EXPIRY for propose/finalize flows
    uint256 public constant PROPOSAL_EXPIRY = 30 days;

    /// @dev OF-16-002: Block of last loss resolution for same-block TOCTOU enforcement.
    uint256 private _lastLossResolutionBlock;
    /// @dev OF-16-002: Require at least one new block after loss resolution before wind-down.
    uint256 public constant LOSS_COOLDOWN_BLOCKS = 1;

    uint256[44] private __gap; // 48 - 2 mappings - 1 packed - 1 loss timestamp

    // ── Constructor (disable initializers on implementation) ──
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer ──
    function initialize(address initialOwner_) external initializer {
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        // OF-I02: UUPSUpgradeable has no init in OZ 5.x (stateless)

        _nextVaultId = 1;
    }

    // ── Vault Registration ──
    function addVault(
        string calldata name_,
        string calldata abbreviation_,
        address[4] calldata tierVaults_,
        address stakingQueue_,
        uint256 capacityCap_,
        uint256[4] calldata lockupDurations_,
        uint16[4] calldata yieldSplitsBps_,
        uint16[4] calldata fundingBps_
    ) external onlyOwner returns (uint256) {
        if (bytes(name_).length == 0) revert EmptyName();
        if (bytes(abbreviation_).length == 0) revert EmptyAbbreviation();

        // OF-003: Validate tier vault addresses are non-zero, intra-vault unique,
        // AND globally unique across all registered vaults.
        for (uint256 i; i < 4;) {
            if (tierVaults_[i] == address(0)) revert ZeroAddress();
            if (_tierVaultUsed[tierVaults_[i]]) revert DuplicateTierVault();
            unchecked {
                ++i;
            }
        }
        // PHASE2-021: Ensure all tier vault addresses are unique within this vault
        for (uint256 i; i < 4;) {
            for (uint256 j = i + 1; j < 4;) {
                if (tierVaults_[i] == tierVaults_[j]) revert DuplicateTierVault();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (stakingQueue_ == address(0)) revert ZeroAddress();
        if (capacityCap_ == 0) revert ZeroCapacity();
        if (lockupDurations_[0] != 0) revert NonZeroTier0Lockup();

        for (uint256 i; i < 4;) {
            if (yieldSplitsBps_[i] == 0) revert ZeroYieldSplit(uint8(i));
            if (uint256(yieldSplitsBps_[i]) + uint256(fundingBps_[i]) > 10000) revert InvalidSplitTotal(uint8(i));
            unchecked {
                ++i;
            }
        }

        bytes32 abbrHash = keccak256(bytes(abbreviation_));
        if (_abbreviationToVaultId[abbrHash] != 0) revert DuplicateAbbreviation(abbreviation_);

        uint256 vaultId = _nextVaultId;

        VaultConfig storage v = _vaults[vaultId];
        v.vaultId = vaultId;
        v.name = name_;
        v.abbreviation = abbreviation_;
        v.tierVaults = tierVaults_;
        v.stakingQueue = stakingQueue_;
        v.capacityCap = capacityCap_;
        v.lockupDurations = lockupDurations_;
        v.yieldSplitsBps = yieldSplitsBps_;
        v.fundingBps = fundingBps_;
        v.status = VaultStatus.Active;

        _abbreviationToVaultId[abbrHash] = vaultId;
        _allVaultIds.push(vaultId);
        _nextVaultId = vaultId + 1;

        // OF-003: Mark all tier vault addresses as used globally
        for (uint256 i; i < 4;) {
            _tierVaultUsed[tierVaults_[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit VaultAdded(vaultId, name_, abbreviation_);

        return vaultId;
    }

    // ── Vault Lifecycle ──
    function pauseVault(uint256 vaultId) external onlyOwner {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status != VaultStatus.Active) revert VaultNotActive();

        vault.status = VaultStatus.Paused;

        emit VaultPaused(vaultId);
    }

    // OF-L01: Resume a paused vault
    function resumeVault(uint256 vaultId) external onlyOwner {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status != VaultStatus.Paused) revert VaultNotPaused();
        vault.status = VaultStatus.Active;
        emit VaultResumed(vaultId);
    }

    /// @notice OF-L09: Paused→WindingDown intentionally allowed for vault lifecycle progression.
    /// @dev OF-NEW-09 (12th audit): Active→WindingDown is intentional by design. Both Active
    /// and Paused vaults can transition to WindingDown. Active→WindingDown skips the Pause step
    /// for operational flexibility. Governance should coordinate timing with keeper/NAV settlement
    /// so new accounting does not target a vault already moving to WindingDown.
    /// @dev OF-16-036: Full wind-down state machine:
    ///   Active → Paused (pauseVault) → Active (resumeVault)
    ///   Active → WindingDown (startWindDown) — direct, skips Pause
    ///   Paused → WindingDown (startWindDown) — progression without resume
    ///   WindingDown is terminal — no transitions out. releaseAbbreviation() and
    ///   releaseTierVaults() are cleanup operations within WindingDown state.
    /// @dev OF-16-002: Added loss resolution cooldown. startWindDown reverts if a loss was
    /// resolved within LOSS_COOLDOWN_BLOCKS to prevent same-block TOCTOU race between
    /// lossPending check and status transition.
    function startWindDown(uint256 vaultId) external onlyOwner {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status == VaultStatus.WindingDown) revert VaultAlreadyWindingDown();
        // OF-14-001: Block wind-down if a loss is pending for this vault (or legacy unbound loss)
        if (_riskusdVault != address(0)) {
            IRISKUSDVaultLossQuery riskVault = IRISKUSDVaultLossQuery(_riskusdVault);
            if (riskVault.lossPending()) {
                uint256 pendingVaultId = riskVault.lossPendingVaultId();
                // Fail-closed: block if loss is for this vault OR legacy unbound (vaultId == 0)
                if (pendingVaultId == vaultId || pendingVaultId == 0) revert LossPendingForVault();
            }
        }
        // OF-16-002: Block-based cooldown after loss resolution to close same-block TOCTOU window.
        if (_lastLossResolutionBlock > 0 && block.number <= _lastLossResolutionBlock + LOSS_COOLDOWN_BLOCKS - 1) {
            revert LossCooldownActive();
        }

        vault.status = VaultStatus.WindingDown;

        emit VaultWindingDown(vaultId);
    }

    function releaseAbbreviation(uint256 vaultId) external onlyOwner {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status != VaultStatus.WindingDown) revert VaultNotWindingDown();

        string memory abbr = vault.abbreviation;
        bytes32 abbrHash = keccak256(bytes(abbr));
        if (_abbreviationToVaultId[abbrHash] != vaultId) revert AbbreviationAlreadyReleased();

        delete _abbreviationToVaultId[abbrHash];

        emit AbbreviationReleased(vaultId, abbr);
    }

    /// @notice Release only empty tier vault addresses for a winding-down vault.
    /// @dev Tier vaults with live share supply remain globally reserved to prevent
    /// legacy holder state from being reused under a new vault identity.
    function releaseTierVaults(uint256 vaultId) external onlyOwner {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status != VaultStatus.WindingDown) revert VaultNotWindingDown();

        address[4] memory tierVaults = vault.tierVaults;
        bool anyUsed = false;
        for (uint256 i; i < 4;) {
            if (_tierVaultUsed[tierVaults[i]] && _tierVaultIsReleasable(tierVaults[i])) {
                _tierVaultUsed[tierVaults[i]] = false;
                vault.tierVaults[i] = address(0);
                anyUsed = true;
            }
            unchecked {
                ++i;
            }
        }
        if (!anyUsed) revert TierVaultsNotUsed();

        emit TierVaultsReleased(vaultId);
    }

    // ── Vault Configuration Updates ──
    /// @notice OF-15-006: setCapacityCap now delegates to proposeCapacityCap (no instant effect).
    function setCapacityCap(uint256 vaultId, uint256 capacityCap_) external onlyOwner {
        proposeCapacityCap(vaultId, capacityCap_);
    }

    /// @notice OF-15-006: setYieldSplits now delegates to proposeYieldSplits (no instant effect).
    function setYieldSplits(uint256 vaultId, uint16[4] calldata yieldSplitsBps_, uint16[4] calldata fundingBps_)
        external
        onlyOwner
    {
        proposeYieldSplits(vaultId, yieldSplitsBps_, fundingBps_);
    }

    /// @notice OF-13-010: Propose new yield splits with FINALIZE_DELAY.
    /// @dev OF-16-009: Require Active vault for defense-in-depth (WindingDown config has no effect).
    function proposeYieldSplits(uint256 vaultId, uint16[4] calldata yieldSplitsBps_, uint16[4] calldata fundingBps_)
        public
        onlyOwner
    {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status != VaultStatus.Active) revert VaultNotActive();

        for (uint256 i; i < 4;) {
            if (yieldSplitsBps_[i] == 0) revert ZeroYieldSplit(uint8(i));
            if (uint256(yieldSplitsBps_[i]) + uint256(fundingBps_[i]) > 10000) revert InvalidSplitTotal(uint8(i));
            unchecked {
                ++i;
            }
        }

        _pendingYieldSplits[vaultId] =
            PendingYieldSplits({yieldSplitsBps: yieldSplitsBps_, fundingBps: fundingBps_, proposedAt: block.timestamp});

        emit YieldSplitsProposed(vaultId);
    }

    /// @notice OF-13-010: Finalize proposed yield splits after FINALIZE_DELAY.
    /// @dev OF-21-048: Re-validate vault status at finalize time.
    function finalizeYieldSplits(uint256 vaultId) external onlyOwner {
        PendingYieldSplits storage pending = _pendingYieldSplits[vaultId];
        if (pending.proposedAt == 0) revert NoPendingYieldSplits();
        if (block.timestamp < pending.proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > pending.proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        // OF-21-048: Re-check vault is still Active at finalize time
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.status != VaultStatus.Active) revert VaultNotActive();

        vault.yieldSplitsBps = pending.yieldSplitsBps;
        vault.fundingBps = pending.fundingBps;

        delete _pendingYieldSplits[vaultId];

        emit YieldSplitsUpdated(vaultId);
    }

    /// @notice OF-13-028: Propose a new capacity cap with FINALIZE_DELAY.
    /// @dev OF-16-009: Require Active vault for defense-in-depth.
    function proposeCapacityCap(uint256 vaultId, uint256 capacityCap_) public onlyOwner {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        if (vault.status != VaultStatus.Active) revert VaultNotActive();
        if (capacityCap_ == 0) revert ZeroCapacity();

        _pendingCapacityCap[vaultId] = PendingCapacityCap({capacityCap: capacityCap_, proposedAt: block.timestamp});

        emit CapacityCapProposed(vaultId, capacityCap_);
    }

    /// @notice OF-13-028: Finalize proposed capacity cap after FINALIZE_DELAY.
    /// @dev OF-21-048: Re-validate vault status at finalize time.
    function finalizeCapacityCap(uint256 vaultId) external onlyOwner {
        PendingCapacityCap storage pending = _pendingCapacityCap[vaultId];
        if (pending.proposedAt == 0) revert NoPendingCapacityCap();
        if (block.timestamp < pending.proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > pending.proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        // OF-21-048: Re-check vault is still Active at finalize time
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.status != VaultStatus.Active) revert VaultNotActive();

        uint256 oldCap = vault.capacityCap;
        vault.capacityCap = pending.capacityCap;

        delete _pendingCapacityCap[vaultId];

        emit CapacityCapUpdated(vaultId, oldCap, vault.capacityCap);
    }

    // ── View functions ──
    function getVault(uint256 vaultId) external view returns (VaultConfig memory) {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) revert InvalidVaultId();
        return vault;
    }

    function getActiveVaults() external view returns (uint256[] memory) {
        uint256 len = _allVaultIds.length;
        uint256 count;
        for (uint256 i; i < len;) {
            if (_vaults[_allVaultIds[i]].status == VaultStatus.Active) {
                count++;
            }
            unchecked {
                ++i;
            }
        }

        uint256[] memory result = new uint256[](count);
        uint256 idx;
        for (uint256 i; i < len;) {
            if (_vaults[_allVaultIds[i]].status == VaultStatus.Active) {
                result[idx] = _allVaultIds[i];
                idx++;
            }
            unchecked {
                ++i;
            }
        }
        return result;
    }

    function getAllVaults() external view returns (uint256[] memory) {
        return _allVaultIds;
    }

    function getVaultsPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextOffset, uint256 total)
    {
        total = _allVaultIds.length;
        if (offset >= total || limit == 0) {
            return (new uint256[](0), total, total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        ids = new uint256[](end - offset);
        for (uint256 i; i < ids.length;) {
            ids[i] = _allVaultIds[offset + i];
            unchecked {
                ++i;
            }
        }
        nextOffset = end;
    }

    function vaultCount() external view returns (uint256) {
        return _allVaultIds.length;
    }

    function getVaultByAbbreviation(string calldata abbreviation_) external view returns (uint256) {
        uint256 vaultId = _abbreviationToVaultId[keccak256(bytes(abbreviation_))];
        if (vaultId == 0) revert VaultNotFound();
        return vaultId;
    }

    // ── Deposit Status ──
    function isDepositOpen(uint256 vaultId) external view returns (bool) {
        VaultConfig storage vault = _vaults[vaultId];
        if (vault.vaultId == 0) return false;
        return vault.status == VaultStatus.Active;
    }

    // ── RISKUSDVault Wiring (OF-15-004 + CODEX-001) ──

    /// @notice OF-15-004: Wire _riskusdVault on deployed proxies. Called once after UUPS upgrade.
    /// @dev CODEX-R1: onlyOwner prevents front-running if upgrade and init are not atomic.
    function initializeV2(address riskusdVault_) external onlyOwner reinitializer(2) {
        if (riskusdVault_ == address(0)) revert ZeroAddress();
        _riskusdVault = riskusdVault_;
        emit RISKUSDVaultUpdated(address(0), riskusdVault_);
    }

    /// @notice Migrates the retired loss-resolution timestamp slot to block-number semantics.
    /// @dev Existing upgraded proxies may hold a Unix timestamp in this slot from older code.
    /// Such values are greater than block.number and would keep wind-down cooldown active
    /// indefinitely. Fresh deployments and already-migrated block values are left unchanged.
    function initializeV3() external onlyOwner reinitializer(3) {
        uint256 oldValue = _lastLossResolutionBlock;
        if (oldValue > block.number) {
            _lastLossResolutionBlock = 0;
            emit LossResolutionBlockMigrated(oldValue, 0);
        }
    }

    /// @notice OF-15-004: Propose a new RISKUSDVault address. Takes effect after FINALIZE_DELAY.
    function proposeRISKUSDVault(address newVault_) external onlyOwner {
        if (newVault_ == address(0)) revert ZeroAddress();
        _pendingRISKUSDVault = newVault_;
        _pendingRISKUSDVaultTimestamp = uint48(block.timestamp);
        emit RISKUSDVaultProposed(_riskusdVault, newVault_);
    }

    /// @notice OF-15-004: Finalize the proposed RISKUSDVault after FINALIZE_DELAY.
    /// @dev OF-21-061: Verify reciprocal wiring — new vault must reference this registry.
    function finalizeRISKUSDVault() external onlyOwner {
        if (_pendingRISKUSDVault == address(0)) revert NoPendingRISKUSDVault();
        if (block.timestamp < uint256(_pendingRISKUSDVaultTimestamp) + _finalizeDelay()) {
            revert FinalizeDelayNotElapsed();
        }
        if (block.timestamp > uint256(_pendingRISKUSDVaultTimestamp) + PROPOSAL_EXPIRY) revert ProposalExpired();
        // OF-21-061: Verify new vault's vaultRegistry() points back to this registry
        (bool ok, bytes memory data) = _pendingRISKUSDVault.staticcall(abi.encodeWithSignature("vaultRegistry()"));
        if (!ok || data.length < 32) revert VaultRegistryMismatch();
        if (abi.decode(data, (address)) != address(this)) revert VaultRegistryMismatch();
        _requireRISKUSDVaultInterface(_pendingRISKUSDVault);

        address oldVault = _riskusdVault;
        _riskusdVault = _pendingRISKUSDVault;
        _pendingRISKUSDVault = address(0);
        _pendingRISKUSDVaultTimestamp = 0;

        emit RISKUSDVaultUpdated(oldVault, _riskusdVault);
    }

    /// @notice OF-15-004: Clear a pending RISKUSDVault proposal without finalizing.
    function clearPendingRISKUSDVault() external onlyOwner {
        _pendingRISKUSDVault = address(0);
        _pendingRISKUSDVaultTimestamp = 0;
    }

    /// @notice OF-16-002: Called by RISKUSDVault after loss is resolved.
    /// Records timestamp to enforce cooldown before wind-down.
    function notifyLossResolved() external {
        if (msg.sender != _riskusdVault) revert NotRISKUSDVault(); // OF-21-002: dedicated auth error
        _lastLossResolutionBlock = block.number;
    }

    /// @notice View the current RISKUSDVault address.
    function riskusdVault() external view returns (address) {
        return _riskusdVault;
    }

    /// @notice OF-16-018: Cross-contract reference consistency check.
    /// Returns true only if VaultRegistry→RISKUSDVault and RISKUSDVault→VaultRegistry
    /// point to each other. Fails silently (returns false) on any call failure.
    function verifyWiring() external view returns (bool) {
        if (_riskusdVault == address(0)) return false;
        (bool ok, bytes memory data) = _riskusdVault.staticcall(abi.encodeWithSignature("vaultRegistry()"));
        if (!ok || data.length < 32) return false;
        address vaultRegistryOnVault = abi.decode(data, (address));
        return vaultRegistryOnVault == address(this);
    }

    function _requireRISKUSDVaultInterface(address vault_) private view {
        if (vault_.code.length == 0) revert InvalidRISKUSDVaultInterface(vault_);
        (bool ok, bytes memory data) =
            vault_.staticcall(abi.encodeWithSelector(IRISKUSDVaultLossQuery.lossPending.selector));
        if (!ok || data.length < 32) revert InvalidRISKUSDVaultInterface(vault_);
        (ok, data) = vault_.staticcall(abi.encodeWithSelector(IRISKUSDVaultLossQuery.lossPendingVaultId.selector));
        if (!ok || data.length < 32) revert InvalidRISKUSDVaultInterface(vault_);
    }

    function _tierVaultIsReleasable(address tierVault) private view returns (bool) {
        if (tierVault == address(0)) return false;
        try ITierVaultAccountingQuery(tierVault).totalSupply() returns (uint256 supply) {
            if (supply != 0) return false;
        } catch {
            return false;
        }
        try ITierVaultAccountingQuery(tierVault).totalAssets() returns (uint256 assets) {
            if (assets != 0) revert ResidualTierVaultAssets(tierVault, assets);
        } catch (bytes memory reason) {
            if (reason.length != 0) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            return false;
        }
        return true;
    }

    // ── Ownership ──
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // ── UUPS ──
    function _authorizeUpgrade(address) internal override onlyOwner {
        // OF-15-004: Clear pending RISKUSDVault proposal on upgrade to prevent stale proposals
        _pendingRISKUSDVault = address(0);
        _pendingRISKUSDVaultTimestamp = 0;
    }
}
