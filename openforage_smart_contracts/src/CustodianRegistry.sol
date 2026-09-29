// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./FinalizeDelayProfile.sol";
import "./AllowlistGatedUpgradeable.sol";

interface IForageGovernorGuardianSource {
    function guardianModule() external view returns (address);
}

/// @title CustodianRegistry
/// @notice R-27/F11 registry shape for N trading custodians.
/// @dev Hot-path checks are mapping lookups by custodian id; enumeration is only for off-chain/admin views.
contract CustodianRegistry is
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

    error ZeroAddress();
    error ZeroBytes32();
    error ZeroAmount();
    error InvalidCustodianId();
    error CustodianNotFound(bytes32 id);
    error CustodianPaused(bytes32 id);
    error InvalidCustodianKind();
    error InvalidBps();
    error InvalidCap();
    error UnauthorizedPauseControl(address caller);
    error UnauthorizedCustodianRole(bytes32 id, bytes32 role, address caller);
    error CustodianDeployCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error CustodianPerBlockCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error CustodianPerDayCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error CustodianReturnPerCallCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error CustodianReturnPerDayCapExceeded(bytes32 id, uint256 provided, uint256 available);
    error ExcessiveCustodianReturn(bytes32 id, uint256 provided, uint256 deployed);
    error ExcessiveCustodianLoss(bytes32 id, uint256 amount, uint256 custodianDeployed, uint256 totalDeployed);
    error NoPendingCustodianConfig(bytes32 id);
    error NoPendingAllowedPeer(bytes32 id, bytes32 peer);
    error NoPendingCustodianRole(bytes32 id, bytes32 role, address account);
    error NoPendingForageGovernor();
    error NoPendingGuardianModule();
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error RenounceOwnershipDisabled();
    error CustodianNAVDeltaCapExceeded(bytes32 id, uint256 navCapReference, uint256 newNAV);
    error CustodianNAVBaselineStateInvalid(
        bytes32 id, CustodianNAVBaselineStatus status, uint256 navCapReference, bool initialized
    );
    error CustodianLossRelationInvalid(bytes32 id, uint256 expected, uint256 provided);
    error CustodianRegistryFreshDeploymentRequired(uint8 layoutVersion);
    error FreshInitializationOnExistingState(
        uint8 layoutVersion, uint256 custodianCount, uint256 totalDeployed, address currentOwner
    );
    error StaleCustodianConfigEpoch(bytes32 id, uint64 expected, uint64 actual);
    error GuardianRotationRetired();
    error GuardianGovernorUnavailable(address governor);
    error GuardianModuleLookupFailed(address governor);
    error InvalidGuardianModule(address module);

    bytes32 public constant HYPERLIQUID_CUSTODIAN_ID = keccak256("HYPERLIQUID");
    bytes32 public constant LIGHTER_CUSTODIAN_ID = keccak256("LIGHTER");
    bytes32 public constant ROLE_ACCOUNTANT = keccak256("ACCOUNTANT");
    bytes32 public constant ROLE_NAV_ATTESTER = keccak256("NAV_ATTESTER");
    bytes32 public constant ROLE_EXECUTOR = keccak256("EXECUTOR");
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    uint256 public constant DAY_SECONDS = 86400;
    bytes32 private constant MANUAL_LOSS_SOURCE = keccak256("MANUAL_CUSTODIAN_LOSS");

    event CustodianConfigProposed(bytes32 indexed id, CustodianKind kind, address bridge, address executor);
    event CustodianConfigFinalized(bytes32 indexed id, CustodianKind kind, address bridge, address executor);
    event CustodianPausedSet(bytes32 indexed id, bool paused);
    event CustodianPeerProposed(bytes32 indexed id, bytes32 indexed peer);
    event CustodianPeerAllowed(bytes32 indexed id, bytes32 indexed peer, bool allowed);
    event CustodianRoleProposed(bytes32 indexed id, bytes32 indexed role, address indexed account);
    event CustodianRoleAllowed(bytes32 indexed id, bytes32 indexed role, address indexed account, bool allowed);
    event CustodianDeploymentRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianReturnRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianLossRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianEmergencyReturnRecorded(
        bytes32 indexed id, address indexed caller, uint256 amount, uint256 deployed
    );
    event CustodianNAVRecorded(bytes32 indexed id, uint256 nav, uint256 timestamp);
    event CustodianNAVBaselineUpdated(
        bytes32 indexed id, CustodianNAVBaselineStatus status, uint256 navReference, bool initialized
    );
    event CustodianLossIdentityReserved(
        bytes32 indexed id, bytes32 indexed vaultId, uint256 indexed lossNonce, uint256 principalAmount
    );
    event CustodianLossIdentityApplied(
        bytes32 indexed id, bytes32 indexed vaultId, uint256 indexed lossNonce, uint256 cumulativePrincipal
    );
    event CustodianNAVLossRelationRecorded(
        bytes32 indexed id,
        uint64 reportEpoch,
        bytes32 indexed attestedVaultId,
        uint256 attestedLossNonceThrough,
        uint256 manualLossTicketThrough
    );
    event ForageGovernorProposed(address indexed current, address indexed pending);
    event ForageGovernorUpdated(address indexed oldGovernor, address indexed newGovernor);
    event GuardianModuleProposed(address indexed current, address indexed pending);
    event GuardianModuleUpdated(address indexed oldGuardian, address indexed newGuardian);

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
    uint8 private constant _FRESH_LAYOUT_VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    modifier freshOnly() {
        _requireFreshLayout();
        _;
    }

    function initialize(address initialOwner_, address forageGovernor_, address guardianModule_) external initializer {
        _requireFreshInitializationState();
        if (initialOwner_ == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();
        _forageGovernor = forageGovernor_;
        _guardianModule = guardianModule_;
        _freshLayoutVersion = _FRESH_LAYOUT_VERSION;
    }

    function setAllowlist(address allowlist_) external freshOnly onlyOwner {
        _transitionAllowlist(allowlist_);
    }

    function _requireFreshInitializationState() private view {
        address currentOwner = owner();
        if (
            address(this).code.length != 0 || _freshLayoutVersion != 0 || _custodianIds.length != 0
                || _totalDeployed != 0 || _forageGovernor != address(0) || _guardianModule != address(0)
                || _pendingForageGovernor != address(0) || _pendingGuardianModule != address(0)
                || _pendingForageGovernorProposedAt != 0 || _pendingGuardianModuleProposedAt != 0
                || allowlist() != address(0) || paused() || currentOwner != address(0)
        ) {
            revert FreshInitializationOnExistingState(
                _freshLayoutVersion, _custodianIds.length, _totalDeployed, currentOwner
            );
        }
    }

    function _requireFreshLayout() private view {
        if (_freshLayoutVersion != _FRESH_LAYOUT_VERSION) {
            revert CustodianRegistryFreshDeploymentRequired(_freshLayoutVersion);
        }
    }

    modifier onlyCustodianRole(bytes32 id, bytes32 role) {
        if (!_allowedRoles[id][role][msg.sender]) {
            revert UnauthorizedCustodianRole(id, role, msg.sender);
        }
        _;
    }

    function proposeCustodianConfig(CustodianConfig calldata config, uint256 navCapReference)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        _validateConfig(config);
        _pendingCustodianConfigs[config.id] = PendingCustodianConfig({
            config: config,
            proposedAt: block.timestamp,
            exists: true,
            navCapReference: navCapReference
        });
        emit CustodianConfigProposed(config.id, config.kind, config.bridge, config.executor);
    }

    function finalizeCustodianConfig(bytes32 id) external freshOnly onlyAllowedCaller onlyOwner {
        PendingCustodianConfig storage pending = _pendingCustodianConfigs[id];
        if (!pending.exists) revert NoPendingCustodianConfig(id);
        if (block.timestamp < pending.proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > pending.proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();

        CustodianConfig memory config = pending.config;
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
        if (state.deployUsedDayStart == 0) {
            state.deployUsedDayStart = block.timestamp;
        }
        if (state.returnUsedDayStart == 0) {
            state.returnUsedDayStart = block.timestamp;
        }

        _allowedPeers[id][config.peer] = true;
        _setCoreRoles(id, config.bridge, config.executor, true);

        delete _pendingCustodianConfigs[id];
        emit CustodianPeerAllowed(id, config.peer, true);
        emit CustodianConfigFinalized(id, config.kind, config.bridge, config.executor);
        _emitNAVBaselineUpdated(id, state);
    }

    function cancelPendingCustodianConfig(bytes32 id) external freshOnly onlyAllowedCaller onlyOwner {
        if (!_pendingCustodianConfigs[id].exists) revert NoPendingCustodianConfig(id);
        delete _pendingCustodianConfigs[id];
    }

    function setCustodianPaused(bytes32 id, bool paused_) external freshOnly onlyAllowedCaller {
        address guardian = _authorizePauseControl();
        if (guardian != address(0) && !paused_) revert UnauthorizedPauseControl(msg.sender);
        CustodianState storage state = _requireCustodian(id);
        state.paused = paused_;
        emit CustodianPausedSet(id, paused_);
    }

    function setAllowedPeer(bytes32 id, bytes32 peer, bool allowed) external freshOnly onlyAllowedCaller onlyOwner {
        _requireCustodian(id);
        if (peer == bytes32(0)) revert ZeroBytes32();
        if (!allowed) {
            delete _pendingAllowedPeers[id][peer];
            _allowedPeers[id][peer] = false;
            emit CustodianPeerAllowed(id, peer, false);
            return;
        }
        _proposeAllowedPeer(id, peer);
    }

    function proposeAllowedPeer(bytes32 id, bytes32 peer) external freshOnly onlyAllowedCaller onlyOwner {
        _requireCustodian(id);
        if (peer == bytes32(0)) revert ZeroBytes32();
        _proposeAllowedPeer(id, peer);
    }

    function finalizeAllowedPeer(bytes32 id, bytes32 peer) external freshOnly onlyAllowedCaller onlyOwner {
        _requireCustodian(id);
        if (peer == bytes32(0)) revert ZeroBytes32();
        PendingAllowedPeer storage pending = _pendingAllowedPeers[id][peer];
        if (!pending.exists) revert NoPendingAllowedPeer(id, peer);
        _validatePendingDelay(pending.proposedAt);
        _validateConfigEpoch(id, _pendingAllowedPeerConfigEpoch[id][peer]);
        delete _pendingAllowedPeers[id][peer];
        delete _pendingAllowedPeerConfigEpoch[id][peer];
        _allowedPeers[id][peer] = true;
        emit CustodianPeerAllowed(id, peer, true);
    }

    function cancelPendingAllowedPeer(bytes32 id, bytes32 peer) external freshOnly onlyAllowedCaller onlyOwner {
        if (!_pendingAllowedPeers[id][peer].exists) revert NoPendingAllowedPeer(id, peer);
        delete _pendingAllowedPeers[id][peer];
        delete _pendingAllowedPeerConfigEpoch[id][peer];
    }

    function setCustodianRole(bytes32 id, bytes32 role, address account, bool allowed)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        if (!allowed) {
            delete _pendingAllowedRoles[id][role][account];
            _setRole(id, role, account, false);
            return;
        }
        _proposeCustodianRole(id, role, account);
    }

    function proposeCustodianRole(bytes32 id, bytes32 role, address account)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        _proposeCustodianRole(id, role, account);
    }

    function finalizeCustodianRole(bytes32 id, bytes32 role, address account)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        PendingCustodianRole storage pending = _pendingAllowedRoles[id][role][account];
        if (!pending.exists) revert NoPendingCustodianRole(id, role, account);
        _validatePendingDelay(pending.proposedAt);
        _validateConfigEpoch(id, _pendingAllowedRoleConfigEpoch[id][role][account]);
        delete _pendingAllowedRoles[id][role][account];
        delete _pendingAllowedRoleConfigEpoch[id][role][account];
        _setRole(id, role, account, true);
    }

    function cancelPendingCustodianRole(bytes32 id, bytes32 role, address account)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        if (!_pendingAllowedRoles[id][role][account].exists) {
            revert NoPendingCustodianRole(id, role, account);
        }
        delete _pendingAllowedRoles[id][role][account];
        delete _pendingAllowedRoleConfigEpoch[id][role][account];
    }

    function recordDeployment(bytes32 id, uint256 amount)
        external
        freshOnly
        onlyAllowedCaller
        whenNotPaused
        onlyCustodianRole(id, ROLE_ACCOUNTANT)
    {
        CustodianState storage state = _requireCustodian(id);
        _requireNAVBaselineConsistency(id, state, state.navBaselineStatus);
        if (state.paused) revert CustodianPaused(id);
        if (amount == 0) revert ZeroAmount();
        _enforceDeploymentCaps(id, state, amount);
        state.deployed += amount;
        _totalDeployed += amount;
        if (state.navCapReferenceInitialized) state.navCapReference += amount;
        emit CustodianDeploymentRecorded(id, amount, state.deployed);
        _emitNAVBaselineUpdated(id, state);
    }

    /// @notice Return accounting is intentionally live while the custodian is paused.
    function recordReturn(bytes32 id, uint256 amount)
        external
        freshOnly
        onlyAllowedCaller
        whenNotPaused
        onlyCustodianRole(id, ROLE_ACCOUNTANT)
    {
        uint256 deployed = _applyReturnAccounting(id, amount);
        emit CustodianReturnRecorded(id, amount, deployed);
    }

    /// @notice Named escape hatch for return accounting while the registry-wide pause is active.
    function recordEmergencyReturn(bytes32 id, uint256 amount)
        external
        freshOnly
        onlyAllowedCaller
        whenPaused
        onlyCustodianRole(id, ROLE_ACCOUNTANT)
    {
        uint256 deployed = _applyReturnAccounting(id, amount);
        emit CustodianEmergencyReturnRecorded(id, msg.sender, amount, deployed);
        emit CustodianReturnRecorded(id, amount, deployed);
    }

    function recordLoss(bytes32 id, uint256 amount)
        external
        freshOnly
        onlyAllowedCaller
        onlyCustodianRole(id, ROLE_ACCOUNTANT)
        returns (uint256 recordedAmount)
    {
        CustodianState storage state = _requireCustodian(id);
        if (amount == 0) revert ZeroAmount();
        _requireNAVBaselineConsistency(id, state, state.navBaselineStatus);
        _debitPrincipalLoss(id, state, amount);
        CustodianLossRelation storage relation = _custodianLossRelations[id];
        relation.unboundLoss = true;
        emit CustodianLossRecorded(id, amount, state.deployed);
        return amount;
    }

    function reserveLossIdentity(
        bytes32 id,
        LossIdentityKind kind,
        bytes32 vaultId,
        uint256 identity,
        uint256 principalAmount
    ) external freshOnly onlyAllowedCaller returns (uint256 reservedIdentity) {
        _requireCustodian(id);
        CustodianLossRelation storage relation = _requireBoundLossRelation(id);
        if (principalAmount == 0) revert ZeroAmount();
        if (kind == LossIdentityKind.Attested) {
            if (!_allowedRoles[id][ROLE_ACCOUNTANT][msg.sender]) {
                revert UnauthorizedCustodianRole(id, ROLE_ACCOUNTANT, msg.sender);
            }
            _validateNextAttestedIdentity(id, relation, vaultId, identity);
            _requireLossIdentityReconciled(id, relation.attestedLoss);
            relation.attestedVaultId = vaultId;
            relation.attestedLoss = _reservedLoss(identity, principalAmount, relation.attestedLoss.reportedCumulative);
            reservedIdentity = identity;
        } else {
            if (msg.sender != owner()) {
                revert CustodianLossRelationInvalid(id, uint256(uint160(owner())), uint256(uint160(msg.sender)));
            }
            if (vaultId != bytes32(0) || identity != 0) {
                revert CustodianLossRelationInvalid(id, 0, identity);
            }
            _requireLossIdentityReconciled(id, relation.manualLoss);
            uint256 previousTicket = relation.manualLoss.identity;
            if (previousTicket == type(uint256).max) {
                revert CustodianLossRelationInvalid(id, type(uint256).max - 1, previousTicket);
            }
            reservedIdentity = previousTicket + 1;
            relation.manualLoss =
                _reservedLoss(reservedIdentity, principalAmount, relation.manualLoss.reportedCumulative);
        }
        relation.protocolActive = true;
        emit CustodianLossIdentityReserved(
            id, kind == LossIdentityKind.Attested ? vaultId : MANUAL_LOSS_SOURCE, reservedIdentity, principalAmount
        );
    }

    function cancelLossReservation(bytes32 id, LossIdentityKind kind, bytes32 vaultId, uint256 identity)
        external
        freshOnly
        onlyAllowedCaller
    {
        CustodianLossRelation storage relation = _requireBoundLossRelation(id);
        LossIdentity storage loss = _lossIdentityFor(id, relation, kind, vaultId, identity);
        if (loss.cancelled || loss.reservedPrincipal == 0 || loss.appliedPrincipal != 0) {
            revert CustodianLossRelationInvalid(id, loss.reservedPrincipal, loss.appliedPrincipal);
        }
        if (loss.includedPrincipal != 0) {
            revert CustodianLossRelationInvalid(id, 0, loss.includedPrincipal);
        }
        if (kind == LossIdentityKind.Attested) {
            if (!_allowedRoles[id][ROLE_ACCOUNTANT][msg.sender]) {
                revert UnauthorizedCustodianRole(id, ROLE_ACCOUNTANT, msg.sender);
            }
        } else if (kind == LossIdentityKind.Manual) {
            if (msg.sender != owner()) {
                revert CustodianLossRelationInvalid(id, uint256(uint160(owner())), uint256(uint160(msg.sender)));
            }
        }
        if (loss.reportedIdentity >= identity) {
            _invalidLoss(id, identity - 1, loss.reportedIdentity);
        }
        loss.cancelled = true;
        emit CustodianLossIdentityReserved(id, _lossSource(kind, vaultId), identity, 0);
    }

    function recordLossWithIdentity(
        bytes32 id,
        LossIdentityKind kind,
        bytes32 vaultId,
        uint256 identity,
        uint256 cumulativePrincipal
    ) external freshOnly onlyAllowedCaller returns (uint256 recordedAmount) {
        CustodianState storage state = _requireCustodian(id);
        CustodianLossRelation storage relation = _requireBoundLossRelation(id);
        if (!_allowedRoles[id][ROLE_ACCOUNTANT][msg.sender]) {
            revert UnauthorizedCustodianRole(id, ROLE_ACCOUNTANT, msg.sender);
        }
        LossIdentity storage loss = _lossIdentityFor(id, relation, kind, vaultId, identity);
        if (loss.cancelled || loss.reservedPrincipal <= loss.appliedPrincipal) {
            revert CustodianLossRelationInvalid(id, loss.reservedPrincipal, loss.appliedPrincipal);
        }
        recordedAmount = _applyLossCumulative(id, state, loss, cumulativePrincipal);
        emit CustodianLossRecorded(id, recordedAmount, state.deployed);
        emit CustodianLossIdentityApplied(id, _lossSource(kind, vaultId), identity, cumulativePrincipal);
    }

    function recordNAVWithRelation(bytes32 id, uint256 nav, uint64 reportEpoch, bytes calldata relationData)
        external
        freshOnly
        onlyAllowedCaller
        whenNotPaused
        onlyCustodianRole(id, ROLE_NAV_ATTESTER)
    {
        NAVLossRelation memory relationInput = abi.decode(relationData, (NAVLossRelation));
        CustodianState storage state = _requireCustodian(id);
        CustodianLossRelation storage relation = _requireBoundLossRelation(id);
        _validateReportEpoch(id, relation, reportEpoch);
        _validateReportWatermark(id, relation, relationInput, LossIdentityKind.Attested);
        _validateReportWatermark(id, relation, relationInput, LossIdentityKind.Manual);
        if (state.paused) revert CustodianPaused(id);
        _enforceNAVDeltaCap(id, state, nav);
        _recordReportWatermark(relation, relationInput, LossIdentityKind.Attested);
        _recordReportWatermark(relation, relationInput, LossIdentityKind.Manual);
        relation.reportEpoch = reportEpoch;
        relation.protocolActive = true;
        _recordNAVValue(id, state, nav);
        emit CustodianNAVLossRelationRecorded(
            id,
            reportEpoch,
            relationInput.attestedVaultId,
            relationInput.attestedLossNonceThrough,
            relationInput.manualLossTicketThrough
        );
    }

    function recordNAV(bytes32 id, uint256 nav)
        external
        freshOnly
        onlyAllowedCaller
        whenNotPaused
        onlyCustodianRole(id, ROLE_NAV_ATTESTER)
    {
        CustodianState storage state = _requireCustodian(id);
        CustodianLossRelation storage relation = _custodianLossRelations[id];
        if (relation.unboundLoss || relation.protocolActive) {
            _invalidLoss(id, 0, 1);
        }
        if (state.paused) revert CustodianPaused(id);
        _enforceNAVDeltaCap(id, state, nav);
        _recordNAVValue(id, state, nav);
    }

    function proposeForageGovernor(address newGovernor) external freshOnly onlyAllowedCaller onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();
        _pendingForageGovernor = newGovernor;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, newGovernor);
    }

    function finalizeForageGovernor() external freshOnly onlyAllowedCaller onlyOwner {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldGovernor = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorUpdated(oldGovernor, _forageGovernor);
    }

    function proposeGuardianModule(address newGuardianModule) external freshOnly onlyAllowedCaller onlyOwner {
        if (newGuardianModule == address(0)) revert GuardianRotationRetired();
        revert GuardianRotationRetired();
    }

    function finalizeGuardianModule() external freshOnly onlyAllowedCaller onlyOwner {
        revert GuardianRotationRetired();
    }

    function pause() external freshOnly onlyAllowedCaller {
        _authorizePauseControl();
        _pause();
    }

    function unpause() external freshOnly onlyAllowedCaller {
        address guardian = _authorizePauseControl();
        if (guardian != address(0)) revert UnauthorizedPauseControl(msg.sender);
        _unpause();
    }

    function hyperLiquidLaunchConfig(
        address bridge,
        address executor,
        uint32 remoteEid,
        bytes32 peer,
        uint256 maxDeployed
    ) external pure returns (CustodianConfig memory) {
        return CustodianConfig({
            id: HYPERLIQUID_CUSTODIAN_ID,
            kind: CustodianKind.HyperLiquid,
            bridge: bridge,
            executor: executor,
            remoteEid: remoteEid,
            peer: peer,
            maxDeployed: maxDeployed,
            perBlockDeployCap: 1_000_000e6,
            perDayDeployCap: 5_000_000e6,
            navDeltaCapBps: 1000,
            returnPerCallBps: 1000,
            returnPerDayBps: 1000
        });
    }

    function lighterReadyFixture(address bridge, address executor, uint32 remoteEid, bytes32 peer, uint256 maxDeployed)
        external
        pure
        returns (CustodianConfig memory)
    {
        return CustodianConfig({
            id: LIGHTER_CUSTODIAN_ID,
            kind: CustodianKind.Lighter,
            bridge: bridge,
            executor: executor,
            remoteEid: remoteEid,
            peer: peer,
            maxDeployed: maxDeployed,
            perBlockDeployCap: 500_000e6,
            perDayDeployCap: 2_500_000e6,
            navDeltaCapBps: 1000,
            returnPerCallBps: 2500,
            returnPerDayBps: 5000
        });
    }

    function getCustodian(bytes32 id) external view freshOnly returns (CustodianView memory view_) {
        CustodianState storage state = _requireCustodian(id);
        view_ = CustodianView({
            exists: state.exists,
            paused: state.paused,
            kind: state.kind,
            bridge: state.bridge,
            executor: state.executor,
            remoteEid: state.remoteEid,
            peer: state.peer,
            maxDeployed: state.maxDeployed,
            perBlockDeployCap: state.perBlockDeployCap,
            perDayDeployCap: state.perDayDeployCap,
            navDeltaCapBps: state.navDeltaCapBps,
            returnPerCallBps: state.returnPerCallBps,
            returnPerDayBps: state.returnPerDayBps,
            deployed: state.deployed,
            lastNAV: state.lastNAV,
            lastNAVTimestamp: state.lastNAVTimestamp
        });
    }

    function custodianCount() external view freshOnly returns (uint256) {
        return _custodianIds.length;
    }

    function custodianIdAt(uint256 index) external view freshOnly returns (bytes32) {
        return _custodianIds[index];
    }

    function totalDeployed() external view freshOnly returns (uint256) {
        return _totalDeployed;
    }

    function deployedByCustodian(bytes32 id) external view freshOnly returns (uint256) {
        return _requireCustodian(id).deployed;
    }

    function lastNAV(bytes32 id) external view freshOnly returns (uint256 nav, uint256 timestamp) {
        CustodianState storage state = _requireCustodian(id);
        return (state.lastNAV, state.lastNAVTimestamp);
    }

    function navCapBaseline(bytes32 id)
        external
        view
        freshOnly
        returns (CustodianNAVBaselineStatus baselineStatus, uint256 navReference, bool baselineReady)
    {
        CustodianState storage state = _requireCustodian(id);
        _requireNAVBaselineConsistency(id, state, state.navBaselineStatus);
        bool ready = state.navBaselineStatus == CustodianNAVBaselineStatus.Ready;
        return (state.navBaselineStatus, state.navCapReference, ready);
    }

    function isAllowedPeer(bytes32 id, bytes32 peer) external view freshOnly returns (bool) {
        return _allowedPeers[id][peer];
    }

    function hasCustodianRole(bytes32 id, bytes32 role, address account) external view freshOnly returns (bool) {
        return _allowedRoles[id][role][account];
    }

    function pendingAllowedPeer(bytes32 id, bytes32 peer)
        external
        view
        freshOnly
        returns (bool exists, uint256 proposedAt)
    {
        PendingAllowedPeer storage pending = _pendingAllowedPeers[id][peer];
        return (pending.exists, pending.proposedAt);
    }

    function pendingCustodianRole(bytes32 id, bytes32 role, address account)
        external
        view
        freshOnly
        returns (bool exists, uint256 proposedAt)
    {
        PendingCustodianRole storage pending = _pendingAllowedRoles[id][role][account];
        return (pending.exists, pending.proposedAt);
    }

    function forageGovernor() external view freshOnly returns (address) {
        return _forageGovernor;
    }

    function guardianModule() external view freshOnly returns (address) {
        return _resolveGuardianModule();
    }

    function pendingCustodianConfig(bytes32 id)
        external
        view
        freshOnly
        returns (CustodianConfig memory config, uint256 proposedAt)
    {
        PendingCustodianConfig storage pending = _pendingCustodianConfigs[id];
        if (!pending.exists) revert NoPendingCustodianConfig(id);
        return (pending.config, pending.proposedAt);
    }

    function _validateConfig(CustodianConfig memory config) internal pure {
        if (config.id == bytes32(0)) revert InvalidCustodianId();
        if (config.kind == CustodianKind.None) revert InvalidCustodianKind();
        if (config.bridge == address(0) || config.executor == address(0)) revert ZeroAddress();
        if (config.peer == bytes32(0)) revert ZeroBytes32();
        if (config.remoteEid == 0) revert InvalidCustodianId();
        if (config.maxDeployed == 0 || config.perBlockDeployCap == 0 || config.perDayDeployCap == 0) {
            revert InvalidCap();
        }
        if (config.perBlockDeployCap > config.perDayDeployCap || config.perDayDeployCap > config.maxDeployed) {
            revert InvalidCap();
        }
        if (
            config.navDeltaCapBps == 0 || config.navDeltaCapBps > 10000 || config.returnPerCallBps == 0
                || config.returnPerCallBps > 10000 || config.returnPerDayBps == 0 || config.returnPerDayBps > 10000
        ) revert InvalidBps();
    }

    function _applyReturnAccounting(bytes32 id, uint256 amount) internal returns (uint256 deployed) {
        CustodianState storage state = _requireCustodian(id);
        if (amount == 0) revert ZeroAmount();
        if (amount > state.deployed) revert ExcessiveCustodianReturn(id, amount, state.deployed);
        _enforceReturnCaps(id, state, amount);
        deployed = state.deployed - amount;
        state.deployed = deployed;
        _totalDeployed -= amount;
        _reduceNAVCapReference(id, state, amount);
    }

    function _requireCustodian(bytes32 id) private view returns (CustodianState storage state) {
        state = _custodians[id];
        if (!state.exists) revert CustodianNotFound(id);
    }

    function _setRole(bytes32 id, bytes32 role, address account, bool allowed) internal {
        if (account == address(0)) return;
        _allowedRoles[id][role][account] = allowed;
        emit CustodianRoleAllowed(id, role, account, allowed);
    }

    function _setCoreRoles(bytes32 id, address bridge, address executor, bool allowed) internal {
        _setRole(id, ROLE_ACCOUNTANT, bridge, allowed);
        _setRole(id, ROLE_NAV_ATTESTER, bridge, allowed);
        _setRole(id, ROLE_EXECUTOR, executor, allowed);
    }

    function _proposeAllowedPeer(bytes32 id, bytes32 peer) internal {
        _pendingAllowedPeers[id][peer] = PendingAllowedPeer({proposedAt: block.timestamp, exists: true});
        _pendingAllowedPeerConfigEpoch[id][peer] = _custodianConfigEpoch[id];
        emit CustodianPeerProposed(id, peer);
    }

    function _proposeCustodianRole(bytes32 id, bytes32 role, address account) internal {
        _pendingAllowedRoles[id][role][account] = PendingCustodianRole({proposedAt: block.timestamp, exists: true});
        _pendingAllowedRoleConfigEpoch[id][role][account] = _custodianConfigEpoch[id];
        emit CustodianRoleProposed(id, role, account);
    }

    function _validateConfigEpoch(bytes32 id, uint64 proposedEpoch) internal view {
        uint64 currentEpoch = _custodianConfigEpoch[id];
        if (proposedEpoch != currentEpoch) revert StaleCustodianConfigEpoch(id, proposedEpoch, currentEpoch);
    }

    function _validatePendingDelay(uint256 proposedAt) internal view {
        if (block.timestamp < proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
    }

    function _requireBoundLossRelation(bytes32 id) private view returns (CustodianLossRelation storage relation) {
        relation = _custodianLossRelations[id];
        if (relation.unboundLoss) _invalidLoss(id, 0, 1);
    }

    function _invalidLoss(bytes32 id, uint256 expected, uint256 provided) private pure {
        revert CustodianLossRelationInvalid(id, expected, provided);
    }

    function _reservedLoss(uint256 identity, uint256 principalAmount, uint256 includedBase)
        private
        pure
        returns (LossIdentity memory)
    {
        return LossIdentity({
            identity: identity,
            reportedIdentity: identity - 1,
            reportedCumulative: includedBase,
            cumulativeBase: includedBase,
            reservedPrincipal: principalAmount,
            appliedPrincipal: 0,
            includedPrincipal: 0,
            cancelled: false
        });
    }

    function _lossIdentityFor(
        bytes32 id,
        CustodianLossRelation storage relation,
        LossIdentityKind kind,
        bytes32 vaultId,
        uint256 identity
    ) private view returns (LossIdentity storage loss) {
        if (kind == LossIdentityKind.Attested) {
            _validateCurrentAttestedIdentity(id, relation, vaultId, identity);
            return relation.attestedLoss;
        }
        if (vaultId != bytes32(0) || relation.manualLoss.identity != identity) {
            _invalidLoss(id, relation.manualLoss.identity, identity);
        }
        return relation.manualLoss;
    }

    function _lossSource(LossIdentityKind kind, bytes32 vaultId) private pure returns (bytes32) {
        return kind == LossIdentityKind.Attested ? vaultId : MANUAL_LOSS_SOURCE;
    }

    function _requireLossIdentityReconciled(bytes32 id, LossIdentity storage loss) private view {
        uint256 identity = loss.identity;
        if (identity == 0) return;
        bool reconciled = loss.cancelled
            ? loss.appliedPrincipal == 0 && loss.includedPrincipal == 0
            : loss.appliedPrincipal == loss.reservedPrincipal && loss.includedPrincipal == loss.appliedPrincipal;
        if (loss.reportedIdentity != identity || !reconciled) {
            _invalidLoss(id, identity, loss.reportedIdentity);
        }
    }

    function _validateNextAttestedIdentity(
        bytes32 id,
        CustodianLossRelation storage relation,
        bytes32 vaultId,
        uint256 lossNonce
    ) private view {
        bytes32 expectedVaultId = relation.attestedVaultId;
        uint256 previousNonce = relation.attestedLoss.identity;
        uint256 expectedNonce = previousNonce == type(uint256).max ? previousNonce : previousNonce + 1;
        if (
            previousNonce == type(uint256).max || vaultId == bytes32(0)
                || (expectedVaultId != bytes32(0) && expectedVaultId != vaultId) || lossNonce != expectedNonce
        ) {
            _invalidLoss(id, expectedNonce, lossNonce);
        }
    }

    function _validateCurrentAttestedIdentity(
        bytes32 id,
        CustodianLossRelation storage relation,
        bytes32 vaultId,
        uint256 lossNonce
    ) private view {
        bytes32 expectedVaultId = relation.attestedVaultId;
        uint256 expectedNonce = relation.attestedLoss.identity;
        if (expectedVaultId != vaultId || expectedNonce != lossNonce) {
            _invalidLoss(id, expectedNonce, lossNonce);
        }
    }

    function _applyLossCumulative(
        bytes32 id,
        CustodianState storage state,
        LossIdentity storage loss,
        uint256 cumulativePrincipal
    ) private returns (uint256 delta) {
        uint256 previousApplied = loss.appliedPrincipal;
        uint256 reservedPrincipal = loss.reservedPrincipal;
        if (cumulativePrincipal <= previousApplied || cumulativePrincipal > reservedPrincipal) {
            _invalidLoss(id, reservedPrincipal, cumulativePrincipal);
        }
        delta = cumulativePrincipal - previousApplied;
        uint256 priorUnreported = _unreportedPrincipal(previousApplied, loss.includedPrincipal);
        _debitPrincipalLoss(id, state, delta);
        loss.appliedPrincipal = cumulativePrincipal;
        uint256 nextUnreported = _unreportedPrincipal(cumulativePrincipal, loss.includedPrincipal);
        if (nextUnreported > priorUnreported) {
            _reduceNAVCapReference(id, state, nextUnreported - priorUnreported);
        }
    }

    function _debitPrincipalLoss(bytes32 id, CustodianState storage state, uint256 amount) private {
        uint256 deployed = state.deployed;
        uint256 totalDeployed_ = _totalDeployed;
        if (amount > deployed || amount > totalDeployed_) {
            revert ExcessiveCustodianLoss(id, amount, deployed, totalDeployed_);
        }
        unchecked {
            state.deployed = deployed - amount;
            _totalDeployed = totalDeployed_ - amount;
        }
    }

    function _unreportedPrincipal(uint256 applied, uint256 included) private pure returns (uint256) {
        return applied > included ? applied - included : 0;
    }

    function _validateReportEpoch(bytes32 id, CustodianLossRelation storage relation, uint64 reportEpoch)
        private
        view
    {
        uint64 currentEpoch = relation.reportEpoch;
        if (currentEpoch == type(uint64).max || reportEpoch != currentEpoch + 1) {
            uint64 expectedEpoch = currentEpoch == type(uint64).max ? currentEpoch : currentEpoch + 1;
            _invalidLoss(id, expectedEpoch, reportEpoch);
        }
    }

    function _validateReportWatermark(
        bytes32 id,
        CustodianLossRelation storage relation,
        NAVLossRelation memory relationInput,
        LossIdentityKind kind
    ) private view {
        bool attested = kind == LossIdentityKind.Attested;
        bytes32 expectedSource = attested ? relation.attestedVaultId : MANUAL_LOSS_SOURCE;
        bytes32 providedSource = attested ? relationInput.attestedVaultId : MANUAL_LOSS_SOURCE;
        uint256 through = attested ? relationInput.attestedLossNonceThrough : relationInput.manualLossTicketThrough;
        uint256 included = attested ? relationInput.includedAttestedPrincipal : relationInput.includedManualPrincipal;
        LossIdentity storage loss = attested ? relation.attestedLoss : relation.manualLoss;
        uint256 reportedThrough = loss.reportedIdentity;
        uint256 reportedCumulative = loss.reportedCumulative;
        if (providedSource != expectedSource) {
            _invalidLoss(id, loss.identity, through);
        }
        _validateLossWatermark(id, through, included, reportedThrough, reportedCumulative, loss);
    }

    function _validateLossWatermark(
        bytes32 id,
        uint256 through,
        uint256 included,
        uint256 reportedThrough,
        uint256 reportedCumulative,
        LossIdentity storage loss
    ) private view {
        uint256 latestIdentity = loss.identity;
        bool valid = through >= reportedThrough && through <= latestIdentity && included >= reportedCumulative;
        if (valid && through < latestIdentity) {
            valid = through == reportedThrough && included == reportedCumulative && loss.appliedPrincipal == 0;
        } else if (valid && latestIdentity == 0) {
            valid = through == 0 && included == 0;
        } else if (valid) {
            valid = through == latestIdentity && included >= loss.cumulativeBase;
            if (valid) {
                uint256 includedPrincipal = included - loss.cumulativeBase;
                valid = includedPrincipal >= loss.includedPrincipal;
                valid = valid && (loss.cancelled ? includedPrincipal == 0 : includedPrincipal <= loss.reservedPrincipal);
                valid = valid && (loss.appliedPrincipal == 0 || includedPrincipal == loss.appliedPrincipal);
            }
        }
        if (!valid) _invalidLoss(id, reportedThrough, through);
    }

    function _recordReportWatermark(
        CustodianLossRelation storage relation,
        NAVLossRelation memory relationInput,
        LossIdentityKind kind
    ) private {
        if (kind == LossIdentityKind.Attested) {
            relation.attestedLoss.reportedIdentity = relationInput.attestedLossNonceThrough;
            relation.attestedLoss.reportedCumulative = relationInput.includedAttestedPrincipal;
            if (relationInput.attestedLossNonceThrough == relation.attestedLoss.identity) {
                relation.attestedLoss.includedPrincipal =
                    relationInput.includedAttestedPrincipal - relation.attestedLoss.cumulativeBase;
            }
            return;
        }
        relation.manualLoss.reportedIdentity = relationInput.manualLossTicketThrough;
        relation.manualLoss.reportedCumulative = relationInput.includedManualPrincipal;
        if (relationInput.manualLossTicketThrough == relation.manualLoss.identity) {
            relation.manualLoss.includedPrincipal =
                relationInput.includedManualPrincipal - relation.manualLoss.cumulativeBase;
        }
    }

    function _recordNAVValue(bytes32 id, CustodianState storage state, uint256 nav) private {
        state.lastNAV = nav;
        state.lastNAVTimestamp = block.timestamp;
        state.navCapReference = nav;
        state.navCapReferenceInitialized = true;
        state.navBaselineStatus = CustodianNAVBaselineStatus.Ready;
        emit CustodianNAVRecorded(id, nav, block.timestamp);
        _emitNAVBaselineUpdated(id, state);
    }

    function _enforceDeploymentCaps(bytes32 id, CustodianState storage state, uint256 amount) internal {
        uint256 maxRemaining = state.maxDeployed > state.deployed ? state.maxDeployed - state.deployed : 0;
        if (amount > maxRemaining) revert CustodianDeployCapExceeded(id, amount, maxRemaining);

        if (block.number != state.deployUsedBlockNumber) {
            state.deployUsedBlockNumber = block.number;
            state.deployUsedThisBlock = 0;
        }
        uint256 blockRemaining = state.perBlockDeployCap > state.deployUsedThisBlock
            ? state.perBlockDeployCap - state.deployUsedThisBlock
            : 0;
        if (amount > blockRemaining) revert CustodianPerBlockCapExceeded(id, amount, blockRemaining);
        state.deployUsedThisBlock += amount;

        if (block.timestamp >= state.deployUsedDayStart + DAY_SECONDS) {
            state.deployUsedDayStart = block.timestamp;
            state.deployUsedThisDay = 0;
        }
        uint256 dayRemaining =
            state.perDayDeployCap > state.deployUsedThisDay ? state.perDayDeployCap - state.deployUsedThisDay : 0;
        if (amount > dayRemaining) revert CustodianPerDayCapExceeded(id, amount, dayRemaining);
        state.deployUsedThisDay += amount;
    }

    function _enforceReturnCaps(bytes32 id, CustodianState storage state, uint256 amount) internal {
        uint256 callCap = _bpsCap(state.deployed, state.returnPerCallBps);
        if (amount > callCap) revert CustodianReturnPerCallCapExceeded(id, amount, callCap);

        if (state.returnUsedDayStart == 0 || block.timestamp >= state.returnUsedDayStart + DAY_SECONDS) {
            state.returnUsedDayStart = block.timestamp;
            state.returnUsedThisDay = 0;
        }

        uint256 used = state.returnUsedThisDay;
        uint256 dayBasis = state.deployed + used;
        uint256 dayCap = _bpsCap(dayBasis, state.returnPerDayBps);
        uint256 dayRemaining = dayCap > used ? dayCap - used : 0;
        if (amount > dayRemaining) revert CustodianReturnPerDayCapExceeded(id, amount, dayRemaining);
        state.returnUsedThisDay = used + amount;
    }

    function _bpsCap(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * uint256(bps) + 9999) / 10000;
    }

    function _enforceNAVDeltaCap(bytes32 id, CustodianState storage state, uint256 nav) internal view {
        CustodianNAVBaselineStatus status = state.navBaselineStatus;
        if (status != CustodianNAVBaselineStatus.Ready || !state.navCapReferenceInitialized) {
            revert CustodianNAVBaselineStateInvalid(id, status, state.navCapReference, state.navCapReferenceInitialized);
        }
        uint256 navReference = state.navCapReference;
        uint256 delta;
        unchecked {
            delta = nav > navReference ? nav - navReference : navReference - nav;
        }
        uint256 maxDelta =
            Math.mulDiv(navReference == 0 ? state.maxDeployed : navReference, uint256(state.navDeltaCapBps), 10_000);
        if (delta > maxDelta) revert CustodianNAVDeltaCapExceeded(id, navReference, nav);
    }

    function _reduceNAVCapReference(bytes32 id, CustodianState storage state, uint256 amount) internal {
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
        CustodianNAVBaselineStatus status = state.navBaselineStatus;
        emit CustodianNAVBaselineUpdated(id, status, state.navCapReference, state.navCapReferenceInitialized);
    }

    function _authorizePauseControl() internal view returns (address guardian) {
        if (msg.sender == owner() || msg.sender == _forageGovernor) return address(0);
        guardian = _resolveGuardianModule();
        if (msg.sender != guardian) revert UnauthorizedPauseControl(msg.sender);
    }

    function _resolveGuardianModule() internal view returns (address module) {
        address governor = _forageGovernor;
        if (governor == address(0) || governor.code.length == 0) revert GuardianGovernorUnavailable(governor);
        (bool ok, bytes memory data) =
            governor.staticcall(abi.encodeCall(IForageGovernorGuardianSource.guardianModule, ()));
        if (!ok || data.length != 32) revert GuardianModuleLookupFailed(governor);
        uint256 moduleWord;
        assembly ("memory-safe") {
            moduleWord := mload(add(data, 32))
        }
        if (moduleWord > type(uint160).max) revert GuardianModuleLookupFailed(governor);
        module = address(uint160(moduleWord));
        if (module == address(0) || module.code.length == 0) revert InvalidGuardianModule(module);
    }

    function transferOwnership(address newOwner) public override freshOnly onlyAllowedCaller onlyOwner {
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

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override freshOnly onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingGuardianModule = address(0);
        _pendingForageGovernorProposedAt = 0;
        _pendingGuardianModuleProposedAt = 0;
    }
}
