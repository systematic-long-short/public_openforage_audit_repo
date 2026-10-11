// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../AllowlistGatedUpgradeable.sol";
import "../FinalizeDelayProfile.sol";
import "../interfaces/IEmergencyPrincipalLane.sol";

interface ICustodianRegistryBridgeVault {
    function riskusdVault() external view returns (address);
}

interface ICustodianRegistryActiveVaultRoute {
    function vaultRegistry() external view returns (address);
    function riskusdVault() external view returns (address);
}

interface ICustodianRegistryDayStartSupply {
    function dayStartDepositSupply() external view returns (uint256);
}

interface ICustodianRegistryBridgeRole {
    function keeper() external view returns (address);
    function pendingKeeper() external view returns (address);
    function usdcTreasury() external view returns (address);
    function custodianRegistry() external view returns (address);
}

interface ICustodianRegistryTreasuryRole {
    function pnlAttestor() external view returns (address);
    function hlTradingBridge() external view returns (address);
}

interface ICustodianRegistryExecutorQuery {
    function hasActiveExecutor(address account) external view returns (bool);
}

library CustodianRegistryCapitalStorage {
    bytes32 private constant STORAGE_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.CustodianRegistry.Capital")) - 1)
    ) & ~bytes32(uint256(0xff));

    struct Layout {
        address emergencyPrincipalLane;
        uint256 deployUsedThisDay;
        uint256 deployUsedDayStart;
        address canonicalVault;
        uint256 deployDayStartSupply;
        address vaultRegistry;
        mapping(address => uint256) activeExecutorGrants;
    }

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}

contract CustodianRegistryCapitalModule is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    FinalizeDelayProfile,
    AllowlistGatedUpgradeable
{
    enum CustodianKind {
        None,
        HyperLiquid,
        Lighter,
        Generic
    }

    enum CustodianNAVBaselineStatus {
        Unclassified,
        FreshNoBaseline,
        ReservedBaselineStatus,
        Ready
    }

    enum LossIdentityKind {
        Attested,
        Manual
    }

    struct CustodianConfig {
        bytes32 id;
        CustodianKind kind;
        address bridge;
        address executor;
        uint32 remoteEid;
        bytes32 peer;
        uint256 maxDeployed;
        uint256 perBlockDeployCap;
        uint256 perDayDeployCap;
        uint16 navDeltaCapBps;
        uint16 returnPerCallBps;
        uint16 returnPerDayBps;
    }

    struct CustodianView {
        bool exists;
        bool paused;
        CustodianKind kind;
        address bridge;
        address executor;
        uint32 remoteEid;
        bytes32 peer;
        uint256 maxDeployed;
        uint256 perBlockDeployCap;
        uint256 perDayDeployCap;
        uint16 navDeltaCapBps;
        uint16 returnPerCallBps;
        uint16 returnPerDayBps;
        uint256 deployed;
        uint256 lastNAV;
        uint256 lastNAVTimestamp;
    }

    struct NAVLossRelation {
        bytes32 attestedVaultId;
        uint256 attestedLossNonceThrough;
        uint256 includedAttestedPrincipal;
        uint256 manualLossTicketThrough;
        uint256 includedManualPrincipal;
    }

    struct LossIdentity {
        uint256 identity;
        uint256 reportedIdentity;
        uint256 reportedCumulative;
        uint256 cumulativeBase;
        uint256 reservedPrincipal;
        uint256 appliedPrincipal;
        uint256 includedPrincipal;
        bool cancelled;
    }

    struct CustodianLossRelation {
        uint64 reportEpoch;
        bytes32 attestedVaultId;
        LossIdentity attestedLoss;
        LossIdentity manualLoss;
        bool protocolActive;
        bool unboundLoss;
    }

    struct CustodianState {
        bool exists;
        bool paused;
        CustodianKind kind;
        address bridge;
        address executor;
        uint32 remoteEid;
        bytes32 peer;
        uint256 maxDeployed;
        uint256 perBlockDeployCap;
        uint256 perDayDeployCap;
        uint16 navDeltaCapBps;
        uint16 returnPerCallBps;
        uint16 returnPerDayBps;
        uint256 deployed;
        uint256 lastNAV;
        uint256 lastNAVTimestamp;
        uint256 deployUsedThisBlock;
        uint256 deployUsedBlockNumber;
        uint256 deployUsedThisDay;
        uint256 deployUsedDayStart;
        uint256 returnUsedThisDay;
        uint256 returnUsedDayStart;
        uint256 navCapReference;
        bool navCapReferenceInitialized;
        CustodianNAVBaselineStatus navBaselineStatus;
        uint256 returnDayBasis;
    }

    struct PendingCustodianConfig {
        CustodianConfig config;
        uint256 proposedAt;
        bool exists;
        uint256 navCapReference;
    }

    struct PendingAllowedPeer {
        uint256 proposedAt;
        bool exists;
    }

    struct PendingCustodianRole {
        uint256 proposedAt;
        bool exists;
    }

    error DirectCallForbidden();
    error ZeroAddress();
    error ZeroBytes32();
    error ZeroAmount();
    error CustodianNotFound(bytes32 id);
    error CustodianPaused(bytes32 id);
    error CustodianDeployCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error CustodianPerBlockDeployCapRetired(uint256 provided);
    error CustodianPerDayCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error CustodianReturnPerDayCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error ExcessiveCustodianReturn(bytes32 id, uint256 provided, uint256 deployed);
    error NoPendingCustodianConfig(bytes32 id);
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error CustodianNAVBaselineStateInvalid(
        bytes32 id, CustodianNAVBaselineStatus status, uint256 navCapReference, bool initialized
    );
    error CustodianRegistryFreshDeploymentRequired(uint8 layoutVersion);
    error CustodianRegistryVaultUnavailable(address target);
    error CustodianRegistryDayStartSupplyUnavailable(address vault);
    error CustodianRegistryVaultMismatch(address canonicalVault, address providedVault);
    error EmergencyPrincipalLaneUnavailable(address lane);
    error CustodianRoleCollision(address account, address conflictingAccount);
    error RoleSourceUnavailable(address source);
    error NoPendingCustodianRole(bytes32 id, bytes32 role, address account);
    error StaleCustodianConfigEpoch(bytes32 id, uint64 expected, uint64 actual);

    bytes32 private constant ROLE_ACCOUNTANT = keccak256("ACCOUNTANT");
    bytes32 private constant ROLE_NAV_ATTESTER = keccak256("NAV_ATTESTER");
    bytes32 private constant ROLE_EXECUTOR = keccak256("EXECUTOR");
    uint256 private constant DAY_SECONDS = 86400;
    uint256 private constant PROPOSAL_EXPIRY = 30 days;
    uint256 private constant DEPLOY_DAILY_CAP_BPS = 1000;
    uint256 private constant RETURN_DAILY_CAP_BPS = 1000;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint8 private constant FRESH_LAYOUT_VERSION = 6;
    bytes32 private constant HYPERLIQUID_CUSTODIAN_ID = keccak256("HYPERLIQUID");

    event CustodianConfigFinalized(bytes32 indexed id, CustodianKind kind, address bridge, address executor);
    event CustodianPeerAllowed(bytes32 indexed id, bytes32 indexed peer, bool allowed);
    event CustodianRoleProposed(bytes32 indexed id, bytes32 indexed role, address indexed account);
    event CustodianRoleAllowed(bytes32 indexed id, bytes32 indexed role, address indexed account, bool allowed);
    event CustodianDeploymentRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianReturnRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianEmergencyReturnRecorded(
        bytes32 indexed id, address indexed caller, uint256 amount, uint256 deployed
    );
    event CustodianRegistryVaultBound(address indexed vault);
    event CustodianDeployDayStartSupplySnapshotted(uint256 indexed utcDay, uint256 supply);
    event CustodianNAVBaselineUpdated(
        bytes32 indexed id, CustodianNAVBaselineStatus status, uint256 navReference, bool initialized
    );

    mapping(bytes32 => CustodianState) private _custodians;
    mapping(bytes32 => PendingCustodianConfig) private _pendingCustodianConfigs;
    mapping(bytes32 => mapping(bytes32 => bool)) private _allowedPeers;
    mapping(bytes32 => mapping(bytes32 => PendingAllowedPeer)) private _pendingAllowedPeers;
    mapping(bytes32 => mapping(bytes32 => mapping(address => bool))) private _allowedRoles;
    mapping(bytes32 => mapping(bytes32 => mapping(address => PendingCustodianRole))) private _pendingAllowedRoles;
    mapping(bytes32 => uint64) private _custodianConfigEpoch;
    mapping(bytes32 => mapping(bytes32 => uint64)) private _pendingAllowedPeerConfigEpoch;
    mapping(bytes32 => mapping(bytes32 => mapping(address => uint64))) private _pendingAllowedRoleConfigEpoch;
    bytes32[] private _custodianIds;
    uint256 private _totalDeployed;
    address private _forageGovernor;
    address private _guardianModule;
    address private _pendingForageGovernor;
    address private _pendingGuardianModule;
    uint256 private _pendingForageGovernorProposedAt;
    uint256 private _pendingGuardianModuleProposedAt;
    uint8 private _freshLayoutVersion;
    mapping(bytes32 => CustodianLossRelation) private _custodianLossRelations;
    uint256[34] private __gap;

    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    function finalizeCustodianConfig(bytes32 id) external onlyDelegateCall {
        _requireFreshLayout();
        PendingCustodianConfig storage pending = _pendingCustodianConfigs[id];
        if (!pending.exists) revert NoPendingCustodianConfig(id);
        if (block.timestamp < pending.proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > pending.proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();

        CustodianConfig memory config = pending.config;
        _requireDistinctExecutor(config.bridge, config.executor, id == HYPERLIQUID_CUSTODIAN_ID);
        (address vaultRegistry, address activeVault) = _activeRISKUSDVault(config.bridge);
        _bindCanonicalVault(vaultRegistry, activeVault);

        CustodianState storage state = _custodians[id];
        if (state.exists) {
            _requireNAVBaselineConsistency(id, state, state.navBaselineStatus);
            _setCoreRoles(id, state.bridge, state.executor, false);
        } else {
            state.exists = true;
            _custodianIds.push(id);
        }
        if (!state.navCapReferenceInitialized) {
            state.navCapReference = pending.navCapReference;
            state.navCapReferenceInitialized = true;
            state.navBaselineStatus = CustodianNAVBaselineStatus.Ready;
        }
        _custodianConfigEpoch[id] += 1;

        state.kind = config.kind;
        state.bridge = config.bridge;
        state.executor = config.executor;
        state.remoteEid = config.remoteEid;
        state.peer = config.peer;
        state.maxDeployed = config.maxDeployed;
        state.perBlockDeployCap = config.perBlockDeployCap;
        state.perDayDeployCap = config.perDayDeployCap;
        state.navDeltaCapBps = config.navDeltaCapBps;
        state.returnPerCallBps = config.returnPerCallBps;
        state.returnPerDayBps = config.returnPerDayBps;
        if (state.deployUsedDayStart == 0) state.deployUsedDayStart = block.timestamp;
        if (state.returnUsedDayStart == 0) state.returnUsedDayStart = block.timestamp;

        _allowedPeers[id][config.peer] = true;
        _setCoreRoles(id, config.bridge, config.executor, true);
        delete _pendingCustodianConfigs[id];
        emit CustodianPeerAllowed(id, config.peer, true);
        emit CustodianConfigFinalized(id, config.kind, config.bridge, config.executor);
        _emitNAVBaselineUpdated(id, state);
    }

    function setCustodianRole(bytes32 id, bytes32 role, address account, bool allowed) external onlyDelegateCall {
        _requireFreshLayout();
        CustodianState storage state = _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        if (!allowed) {
            delete _pendingAllowedRoles[id][role][account];
            _setRole(id, role, account, false);
            return;
        }
        if (role == ROLE_EXECUTOR) _requireDistinctExecutor(state.bridge, account, false);
        _proposeCustodianRole(id, role, account);
    }

    function proposeCustodianRole(bytes32 id, bytes32 role, address account) external onlyDelegateCall {
        _requireFreshLayout();
        CustodianState storage state = _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        if (role == ROLE_EXECUTOR) _requireDistinctExecutor(state.bridge, account, false);
        _proposeCustodianRole(id, role, account);
    }

    function finalizeCustodianRole(bytes32 id, bytes32 role, address account) external onlyDelegateCall {
        _requireFreshLayout();
        CustodianState storage state = _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        uint64 expectedEpoch = _custodianConfigEpoch[id];
        uint64 proposedEpoch = _pendingAllowedRoleConfigEpoch[id][role][account];
        if (proposedEpoch != expectedEpoch) revert StaleCustodianConfigEpoch(id, expectedEpoch, proposedEpoch);
        if (role == ROLE_EXECUTOR) _requireDistinctExecutor(state.bridge, account, false);
        delete _pendingAllowedRoles[id][role][account];
        delete _pendingAllowedRoleConfigEpoch[id][role][account];
        _setRole(id, role, account, true);
    }

    function recordDeployment(bytes32 id, uint256 amount) external onlyDelegateCall {
        _requireFreshLayout();
        CustodianState storage state = _requireCustodian(id);
        _requireNAVBaselineConsistency(id, state, state.navBaselineStatus);
        if (state.paused) revert CustodianPaused(id);
        if (amount == 0) revert ZeroAmount();
        (address vaultRegistry, address activeVault) = _activeRISKUSDVault(state.bridge);
        _bindCanonicalVault(vaultRegistry, activeVault);
        _syncReturnDayBasis(state);
        _enforceDeploymentCaps(id, state, amount);
        if (state.returnDayBasis == 0 && state.returnUsedThisDay == 0 && state.deployed == 0) {
            state.returnDayBasis = amount;
        }
        state.deployed += amount;
        _totalDeployed += amount;
        if (state.navCapReferenceInitialized) state.navCapReference += amount;
        emit CustodianDeploymentRecorded(id, amount, state.deployed);
        _emitNAVBaselineUpdated(id, state);
    }

    function recordReturnWithNAVBasis(bytes32 id, uint256 amount, bool navAlreadyReduced) external onlyDelegateCall {
        _requireFreshLayout();
        CustodianState storage state = _requireCustodian(id);
        if (amount == 0) revert ZeroAmount();
        if (amount > state.deployed) revert ExcessiveCustodianReturn(id, amount, state.deployed);
        _syncReturnDayBasis(state);
        if (!_principalLaneOpen()) _enforceReturnDayCap(id, state, amount);
        uint256 deployed = state.deployed - amount;
        state.deployed = deployed;
        _totalDeployed -= amount;
        _reduceNAVCapReference(id, state, navAlreadyReduced ? 0 : amount);
        if (paused()) emit CustodianEmergencyReturnRecorded(id, msg.sender, amount, deployed);
        emit CustodianReturnRecorded(id, amount, deployed);
    }

    function _requireFreshLayout() private view {
        if (_freshLayoutVersion != FRESH_LAYOUT_VERSION) {
            revert CustodianRegistryFreshDeploymentRequired(_freshLayoutVersion);
        }
    }

    function _requireDistinctExecutor(address bridge, address executor, bool requireSelected) private view {
        (address treasury, address selectedBridge) = _resolveRoleBridge(bridge, requireSelected);
        _checkExecutorRoles(treasury, selectedBridge, executor);
    }

    function _resolveRoleBridge(address bridge, bool requireSelected)
        private
        view
        returns (address treasury, address selectedBridge)
    {
        if (bridge.code.length == 0) revert RoleSourceUnavailable(bridge);
        ICustodianRegistryBridgeRole candidate = ICustodianRegistryBridgeRole(bridge);
        if (candidate.custodianRegistry() != address(this)) revert RoleSourceUnavailable(bridge);
        treasury = _boundTreasury(bridge, candidate);
        if (treasury.code.length == 0) revert RoleSourceUnavailable(treasury);
        selectedBridge = ICustodianRegistryTreasuryRole(treasury).hlTradingBridge();
        if (selectedBridge.code.length == 0) revert RoleSourceUnavailable(selectedBridge);
        if (requireSelected && selectedBridge != bridge) revert RoleSourceUnavailable(bridge);
        _requireBridgePair(selectedBridge, treasury);
    }

    function _boundTreasury(address bridge, ICustodianRegistryBridgeRole candidate)
        private
        view
        returns (address treasury)
    {
        address anchor = _custodians[HYPERLIQUID_CUSTODIAN_ID].bridge;
        if (anchor == address(0)) return candidate.usdcTreasury();
        if (anchor.code.length == 0) revert RoleSourceUnavailable(anchor);
        ICustodianRegistryBridgeRole anchorRole = ICustodianRegistryBridgeRole(anchor);
        if (anchorRole.custodianRegistry() != address(this)) revert RoleSourceUnavailable(anchor);
        treasury = anchorRole.usdcTreasury();
        if (candidate.usdcTreasury() != treasury) revert RoleSourceUnavailable(bridge);
    }

    function _requireBridgePair(address bridge, address treasury) private view {
        ICustodianRegistryBridgeRole selected = ICustodianRegistryBridgeRole(bridge);
        if (selected.custodianRegistry() != address(this) || selected.usdcTreasury() != treasury) {
            revert RoleSourceUnavailable(bridge);
        }
    }

    function _checkExecutorRoles(address treasury, address bridge, address executor) private view {
        address attestor = ICustodianRegistryTreasuryRole(treasury).pnlAttestor();
        ICustodianRegistryBridgeRole bridgeRole = ICustodianRegistryBridgeRole(bridge);
        address keeper = bridgeRole.keeper();
        address pendingKeeper = bridgeRole.pendingKeeper();
        _requireDifferent(executor, attestor);
        _requireDifferent(executor, keeper);
        _requireDifferent(executor, pendingKeeper);
        _requireDifferent(attestor, keeper);
        _requireDifferent(attestor, pendingKeeper);
        _requireNoActiveExecutor(attestor, bridge);
        _requireNoActiveExecutor(keeper, bridge);
        _requireNoActiveExecutor(pendingKeeper, bridge);
    }

    function _requireNoActiveExecutor(address account, address bridge) private view {
        if (account == address(0)) return;
        if (ICustodianRegistryExecutorQuery(address(this)).hasActiveExecutor(account)) {
            revert CustodianRoleCollision(account, bridge);
        }
    }

    function _proposeCustodianRole(bytes32 id, bytes32 role, address account) private {
        _pendingAllowedRoles[id][role][account] = PendingCustodianRole({proposedAt: block.timestamp, exists: true});
        _pendingAllowedRoleConfigEpoch[id][role][account] = _custodianConfigEpoch[id];
        emit CustodianRoleProposed(id, role, account);
    }

    function _requireDifferent(address first, address second) private pure {
        if (first != address(0) && first == second) revert CustodianRoleCollision(first, second);
    }

    function _requireCustodian(bytes32 id) private view returns (CustodianState storage state) {
        state = _custodians[id];
        if (!state.exists) revert CustodianNotFound(id);
    }

    function _enforceDeploymentCaps(bytes32 id, CustodianState storage state, uint256 amount) private {
        uint256 maxRemaining = state.maxDeployed > state.deployed ? state.maxDeployed - state.deployed : 0;
        if (amount > maxRemaining) revert CustodianDeployCapExceeded(id, amount, maxRemaining);
        if (state.perBlockDeployCap != 0) revert CustodianPerBlockDeployCapRetired(state.perBlockDeployCap);
        CustodianRegistryCapitalStorage.Layout storage capital = CustodianRegistryCapitalStorage.layout();
        uint256 utcDay = block.timestamp / DAY_SECONDS;
        if (capital.deployUsedDayStart != utcDay) {
            uint256 supply = _dayStartDepositSupply(capital.canonicalVault);
            capital.deployUsedDayStart = utcDay;
            capital.deployUsedThisDay = 0;
            capital.deployDayStartSupply = supply;
            emit CustodianDeployDayStartSupplySnapshotted(utcDay, supply);
        }
        uint256 dailyCap = Math.mulDiv(capital.deployDayStartSupply, DEPLOY_DAILY_CAP_BPS, BPS_DENOMINATOR);
        uint256 used = capital.deployUsedThisDay;
        uint256 remaining = dailyCap > used ? dailyCap - used : 0;
        if (amount > remaining) revert CustodianPerDayCapExceeded(id, amount, remaining);
        capital.deployUsedThisDay = used + amount;
    }

    function _activeRISKUSDVault(address bridge) private view returns (address vaultRegistry, address vault) {
        address bridgeVault = _routeAddress(bridge, ICustodianRegistryBridgeVault.riskusdVault.selector);
        vaultRegistry = _routeAddress(bridgeVault, ICustodianRegistryActiveVaultRoute.vaultRegistry.selector);
        address pinnedRegistry = CustodianRegistryCapitalStorage.layout().vaultRegistry;
        if (pinnedRegistry != address(0) && vaultRegistry != pinnedRegistry) {
            revert CustodianRegistryVaultMismatch(pinnedRegistry, vaultRegistry);
        }
        vault = _routeAddress(vaultRegistry, ICustodianRegistryActiveVaultRoute.riskusdVault.selector);
        if (bridgeVault != vault) revert CustodianRegistryVaultMismatch(vault, bridgeVault);
    }

    function _routeAddress(address source, bytes4 selector) private view returns (address target) {
        if (source.code.length == 0) revert CustodianRegistryVaultUnavailable(source);
        (bool ok, bytes memory data) = source.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length != 32) revert CustodianRegistryVaultUnavailable(source);
        uint256 value;
        assembly ("memory-safe") {
            value := mload(add(data, 32))
        }
        if (value == 0 || value > type(uint160).max) revert CustodianRegistryVaultUnavailable(source);
        target = address(uint160(value));
        if (target.code.length == 0) revert CustodianRegistryVaultUnavailable(target);
    }

    function _bindCanonicalVault(address vaultRegistry, address activeVault) private {
        CustodianRegistryCapitalStorage.Layout storage capital = CustodianRegistryCapitalStorage.layout();
        if (capital.vaultRegistry == address(0)) capital.vaultRegistry = vaultRegistry;
        if (capital.vaultRegistry != vaultRegistry) {
            revert CustodianRegistryVaultMismatch(capital.vaultRegistry, vaultRegistry);
        }
        if (capital.canonicalVault == activeVault) return;
        capital.canonicalVault = activeVault;
        emit CustodianRegistryVaultBound(activeVault);
    }

    function _dayStartDepositSupply(address vault) private view returns (uint256 supply) {
        if (vault == address(0) || vault.code.length == 0) revert CustodianRegistryVaultUnavailable(vault);
        (bool supplyOk, bytes memory supplyData) =
            vault.staticcall(abi.encodeCall(ICustodianRegistryDayStartSupply.dayStartDepositSupply, ()));
        if (!supplyOk || supplyData.length != 32) revert CustodianRegistryDayStartSupplyUnavailable(vault);
        assembly ("memory-safe") {
            supply := mload(add(supplyData, 32))
        }
    }

    function _syncReturnDayBasis(CustodianState storage state) private {
        uint256 dayStart = state.returnUsedDayStart;
        if (dayStart == 0 || block.timestamp >= dayStart + DAY_SECONDS) {
            state.returnUsedDayStart = block.timestamp;
            state.returnUsedThisDay = 0;
            state.returnDayBasis = state.deployed;
        } else if (state.returnDayBasis == 0 && state.returnUsedThisDay == 0 && state.deployed != 0) {
            state.returnDayBasis = state.deployed;
        }
    }

    function _enforceReturnDayCap(bytes32 id, CustodianState storage state, uint256 amount) private {
        uint256 dayCap = (state.returnDayBasis * RETURN_DAILY_CAP_BPS + 9999) / BPS_DENOMINATOR;
        uint256 used = state.returnUsedThisDay;
        uint256 remaining = dayCap > used ? dayCap - used : 0;
        if (amount > remaining) revert CustodianReturnPerDayCapExceeded(id, amount, remaining);
        state.returnUsedThisDay = used + amount;
    }

    function _principalLaneOpen() private view returns (bool) {
        address lane = CustodianRegistryCapitalStorage.layout().emergencyPrincipalLane;
        if (lane == address(0)) return false;
        if (lane.code.length == 0) revert EmergencyPrincipalLaneUnavailable(lane);
        (bool ok, bytes memory data) = lane.staticcall(abi.encodeCall(IEmergencyPrincipalLane.principalLaneOpen, ()));
        if (!ok || data.length != 32) revert EmergencyPrincipalLaneUnavailable(lane);
        uint256 openWord;
        assembly ("memory-safe") {
            openWord := mload(add(data, 32))
        }
        if (openWord > 1) revert EmergencyPrincipalLaneUnavailable(lane);
        return openWord == 1;
    }

    function _reduceNAVCapReference(bytes32 id, CustodianState storage state, uint256 amount) private {
        _requireNAVBaselineConsistency(id, state, state.navBaselineStatus);
        uint256 navReference = state.navCapReference;
        state.navCapReference = amount >= navReference ? 0 : navReference - amount;
        _emitNAVBaselineUpdated(id, state);
    }

    function _requireNAVBaselineConsistency(bytes32 id, CustodianState storage state, CustodianNAVBaselineStatus status)
        private
        view
    {
        bool freshWithoutReference = status == CustodianNAVBaselineStatus.FreshNoBaseline && state.navCapReference == 0
            && !state.navCapReferenceInitialized;
        bool readyWithReference = status == CustodianNAVBaselineStatus.Ready && state.navCapReferenceInitialized;
        if (freshWithoutReference || readyWithReference) return;
        revert CustodianNAVBaselineStateInvalid(id, status, state.navCapReference, state.navCapReferenceInitialized);
    }

    function _emitNAVBaselineUpdated(bytes32 id, CustodianState storage state) private {
        emit CustodianNAVBaselineUpdated(
            id, state.navBaselineStatus, state.navCapReference, state.navCapReferenceInitialized
        );
    }

    function _setCoreRoles(bytes32 id, address bridge, address executor, bool allowed) private {
        _setRole(id, ROLE_ACCOUNTANT, bridge, allowed);
        _setRole(id, ROLE_NAV_ATTESTER, bridge, allowed);
        _setRole(id, ROLE_EXECUTOR, executor, allowed);
    }

    function _setRole(bytes32 id, bytes32 role, address account, bool allowed) private {
        if (account == address(0)) return;
        bool previous = _allowedRoles[id][role][account];
        if (role == ROLE_EXECUTOR && previous != allowed) {
            mapping(address => uint256) storage grants = CustodianRegistryCapitalStorage.layout().activeExecutorGrants;
            if (allowed) grants[account] += 1;
            else grants[account] -= 1;
        }
        _allowedRoles[id][role][account] = allowed;
        emit CustodianRoleAllowed(id, role, account, allowed);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert DirectCallForbidden();
    }
}
