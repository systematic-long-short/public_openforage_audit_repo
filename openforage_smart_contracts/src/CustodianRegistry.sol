// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./FinalizeDelayProfile.sol";

/// @title CustodianRegistry
/// @notice R-27/F11 registry shape for N trading custodians.
/// @dev Hot-path checks are mapping lookups by custodian id; enumeration is only for off-chain/admin views.
contract CustodianRegistry is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    FinalizeDelayProfile
{
    enum CustodianKind {
        None,
        HyperLiquid,
        Lighter,
        Generic
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
    }

    struct PendingCustodianConfig {
        CustodianConfig config;
        uint256 proposedAt;
        bool exists;
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
    error NoPendingCustodianConfig(bytes32 id);
    error NoPendingAllowedPeer(bytes32 id, bytes32 peer);
    error NoPendingCustodianRole(bytes32 id, bytes32 role, address account);
    error NoPendingForageGovernor();
    error NoPendingGuardianModule();
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error RenounceOwnershipDisabled();
    error CustodianNAVDeltaCapExceeded(bytes32 id, uint256 previousNAV, uint256 newNAV);

    bytes32 public constant HYPERLIQUID_CUSTODIAN_ID = keccak256("HYPERLIQUID");
    bytes32 public constant LIGHTER_CUSTODIAN_ID = keccak256("LIGHTER");
    bytes32 public constant ROLE_ACCOUNTANT = keccak256("ACCOUNTANT");
    bytes32 public constant ROLE_NAV_ATTESTER = keccak256("NAV_ATTESTER");
    bytes32 public constant ROLE_EXECUTOR = keccak256("EXECUTOR");
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    uint256 public constant DAY_SECONDS = 86400;

    event CustodianConfigProposed(bytes32 indexed id, CustodianKind kind, address bridge, address executor);
    event CustodianConfigFinalized(bytes32 indexed id, CustodianKind kind, address bridge, address executor);
    event CustodianPausedSet(bytes32 indexed id, bool paused);
    event CustodianPeerProposed(bytes32 indexed id, bytes32 indexed peer);
    event CustodianPeerAllowed(bytes32 indexed id, bytes32 indexed peer, bool allowed);
    event CustodianRoleProposed(bytes32 indexed id, bytes32 indexed role, address indexed account);
    event CustodianRoleAllowed(bytes32 indexed id, bytes32 indexed role, address indexed account, bool allowed);
    event CustodianDeploymentRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianReturnRecorded(bytes32 indexed id, uint256 amount, uint256 deployed);
    event CustodianEmergencyReturnRecorded(
        bytes32 indexed id, address indexed caller, uint256 amount, uint256 deployed
    );
    event CustodianNAVRecorded(bytes32 indexed id, uint256 nav, uint256 timestamp);
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
    bytes32[] private _custodianIds;
    uint256 private _totalDeployed;
    address private _forageGovernor;
    address private _guardianModule;
    address private _pendingForageGovernor;
    address private _pendingGuardianModule;
    uint256 private _pendingForageGovernorProposedAt;
    uint256 private _pendingGuardianModuleProposedAt;

    uint256[39] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner_, address forageGovernor_, address guardianModule_) external initializer {
        if (initialOwner_ == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();
        _forageGovernor = forageGovernor_;
        _guardianModule = guardianModule_;
    }

    modifier onlyPauseControl() {
        if (msg.sender != owner() && msg.sender != _forageGovernor && msg.sender != _guardianModule) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _;
    }

    modifier onlyCustodianRole(bytes32 id, bytes32 role) {
        if (!_allowedRoles[id][role][msg.sender]) {
            revert UnauthorizedCustodianRole(id, role, msg.sender);
        }
        _;
    }

    function proposeCustodianConfig(CustodianConfig calldata config) external onlyOwner {
        _validateConfig(config);
        _pendingCustodianConfigs[config.id] =
            PendingCustodianConfig({config: config, proposedAt: block.timestamp, exists: true});
        emit CustodianConfigProposed(config.id, config.kind, config.bridge, config.executor);
    }

    function finalizeCustodianConfig(bytes32 id) external onlyOwner {
        PendingCustodianConfig storage pending = _pendingCustodianConfigs[id];
        if (!pending.exists) revert NoPendingCustodianConfig(id);
        if (block.timestamp < pending.proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > pending.proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();

        CustodianConfig memory config = pending.config;
        _validateConfig(config);
        CustodianState storage state = _custodians[id];
        if (!state.exists) {
            state.exists = true;
            _custodianIds.push(id);
        } else {
            _setCoreRoles(id, state.bridge, state.executor, false);
        }

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
    }

    function cancelPendingCustodianConfig(bytes32 id) external onlyOwner {
        if (!_pendingCustodianConfigs[id].exists) revert NoPendingCustodianConfig(id);
        delete _pendingCustodianConfigs[id];
    }

    function setCustodianPaused(bytes32 id, bool paused_) external onlyPauseControl {
        CustodianState storage state = _requireCustodian(id);
        state.paused = paused_;
        emit CustodianPausedSet(id, paused_);
    }

    function setAllowedPeer(bytes32 id, bytes32 peer, bool allowed) external onlyOwner {
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

    function proposeAllowedPeer(bytes32 id, bytes32 peer) external onlyOwner {
        _requireCustodian(id);
        if (peer == bytes32(0)) revert ZeroBytes32();
        _proposeAllowedPeer(id, peer);
    }

    function finalizeAllowedPeer(bytes32 id, bytes32 peer) external onlyOwner {
        _requireCustodian(id);
        if (peer == bytes32(0)) revert ZeroBytes32();
        PendingAllowedPeer storage pending = _pendingAllowedPeers[id][peer];
        if (!pending.exists) revert NoPendingAllowedPeer(id, peer);
        _validatePendingDelay(pending.proposedAt);
        delete _pendingAllowedPeers[id][peer];
        _allowedPeers[id][peer] = true;
        emit CustodianPeerAllowed(id, peer, true);
    }

    function cancelPendingAllowedPeer(bytes32 id, bytes32 peer) external onlyOwner {
        if (!_pendingAllowedPeers[id][peer].exists) revert NoPendingAllowedPeer(id, peer);
        delete _pendingAllowedPeers[id][peer];
    }

    function setCustodianRole(bytes32 id, bytes32 role, address account, bool allowed) external onlyOwner {
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

    function proposeCustodianRole(bytes32 id, bytes32 role, address account) external onlyOwner {
        _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        _proposeCustodianRole(id, role, account);
    }

    function finalizeCustodianRole(bytes32 id, bytes32 role, address account) external onlyOwner {
        _requireCustodian(id);
        if (role == bytes32(0)) revert ZeroBytes32();
        if (account == address(0)) revert ZeroAddress();
        PendingCustodianRole storage pending = _pendingAllowedRoles[id][role][account];
        if (!pending.exists) revert NoPendingCustodianRole(id, role, account);
        _validatePendingDelay(pending.proposedAt);
        delete _pendingAllowedRoles[id][role][account];
        _setRole(id, role, account, true);
    }

    function cancelPendingCustodianRole(bytes32 id, bytes32 role, address account) external onlyOwner {
        if (!_pendingAllowedRoles[id][role][account].exists) {
            revert NoPendingCustodianRole(id, role, account);
        }
        delete _pendingAllowedRoles[id][role][account];
    }

    function recordDeployment(bytes32 id, uint256 amount)
        external
        whenNotPaused
        onlyCustodianRole(id, ROLE_ACCOUNTANT)
    {
        CustodianState storage state = _requireCustodian(id);
        if (state.paused) revert CustodianPaused(id);
        if (amount == 0) revert ZeroAmount();
        _enforceDeploymentCaps(id, state, amount);
        state.deployed += amount;
        _totalDeployed += amount;
        emit CustodianDeploymentRecorded(id, amount, state.deployed);
    }

    /// @notice Return accounting is intentionally live while the custodian is paused.
    function recordReturn(bytes32 id, uint256 amount) external whenNotPaused onlyCustodianRole(id, ROLE_ACCOUNTANT) {
        uint256 deployed = _applyReturnAccounting(id, amount);
        emit CustodianReturnRecorded(id, amount, deployed);
    }

    /// @notice Named escape hatch for return accounting while the registry-wide pause is active.
    function recordEmergencyReturn(bytes32 id, uint256 amount)
        external
        whenPaused
        onlyCustodianRole(id, ROLE_ACCOUNTANT)
    {
        uint256 deployed = _applyReturnAccounting(id, amount);
        emit CustodianEmergencyReturnRecorded(id, msg.sender, amount, deployed);
        emit CustodianReturnRecorded(id, amount, deployed);
    }

    function recordNAV(bytes32 id, uint256 nav) external whenNotPaused onlyCustodianRole(id, ROLE_NAV_ATTESTER) {
        CustodianState storage state = _requireCustodian(id);
        if (state.paused) revert CustodianPaused(id);
        if (nav == 0) revert ZeroAmount();
        _enforceNAVDeltaCap(id, state, nav);
        state.lastNAV = nav;
        state.lastNAVTimestamp = block.timestamp;
        emit CustodianNAVRecorded(id, nav, block.timestamp);
    }

    function proposeForageGovernor(address newGovernor) external onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();
        _pendingForageGovernor = newGovernor;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, newGovernor);
    }

    function finalizeForageGovernor() external onlyOwner {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldGovernor = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorUpdated(oldGovernor, _forageGovernor);
    }

    function proposeGuardianModule(address newGuardianModule) external onlyOwner {
        if (newGuardianModule == address(0)) revert ZeroAddress();
        _pendingGuardianModule = newGuardianModule;
        _pendingGuardianModuleProposedAt = block.timestamp;
        emit GuardianModuleProposed(_guardianModule, newGuardianModule);
    }

    function finalizeGuardianModule() external onlyOwner {
        if (_pendingGuardianModule == address(0)) revert NoPendingGuardianModule();
        if (block.timestamp < _pendingGuardianModuleProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingGuardianModuleProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldGuardian = _guardianModule;
        _guardianModule = _pendingGuardianModule;
        _pendingGuardianModule = address(0);
        _pendingGuardianModuleProposedAt = 0;
        emit GuardianModuleUpdated(oldGuardian, _guardianModule);
    }

    function pause() external onlyPauseControl {
        _pause();
    }

    function unpause() external onlyPauseControl {
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

    function getCustodian(bytes32 id) external view returns (CustodianView memory view_) {
        CustodianState storage state = _requireCustodianView(id);
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

    function custodianCount() external view returns (uint256) {
        return _custodianIds.length;
    }

    function custodianIdAt(uint256 index) external view returns (bytes32) {
        return _custodianIds[index];
    }

    function totalDeployed() external view returns (uint256) {
        return _totalDeployed;
    }

    function deployedByCustodian(bytes32 id) external view returns (uint256) {
        return _requireCustodianView(id).deployed;
    }

    function lastNAV(bytes32 id) external view returns (uint256 nav, uint256 timestamp) {
        CustodianState storage state = _requireCustodianView(id);
        return (state.lastNAV, state.lastNAVTimestamp);
    }

    function isAllowedPeer(bytes32 id, bytes32 peer) external view returns (bool) {
        return _allowedPeers[id][peer];
    }

    function hasCustodianRole(bytes32 id, bytes32 role, address account) external view returns (bool) {
        return _allowedRoles[id][role][account];
    }

    function pendingAllowedPeer(bytes32 id, bytes32 peer) external view returns (bool exists, uint256 proposedAt) {
        PendingAllowedPeer storage pending = _pendingAllowedPeers[id][peer];
        return (pending.exists, pending.proposedAt);
    }

    function pendingCustodianRole(bytes32 id, bytes32 role, address account)
        external
        view
        returns (bool exists, uint256 proposedAt)
    {
        PendingCustodianRole storage pending = _pendingAllowedRoles[id][role][account];
        return (pending.exists, pending.proposedAt);
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function guardianModule() external view returns (address) {
        return _guardianModule;
    }

    function pendingCustodianConfig(bytes32 id)
        external
        view
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
    }

    function _requireCustodian(bytes32 id) internal view returns (CustodianState storage state) {
        state = _custodians[id];
        if (!state.exists) revert CustodianNotFound(id);
    }

    function _requireCustodianView(bytes32 id) internal view returns (CustodianState storage state) {
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
        emit CustodianPeerProposed(id, peer);
    }

    function _proposeCustodianRole(bytes32 id, bytes32 role, address account) internal {
        _pendingAllowedRoles[id][role][account] = PendingCustodianRole({proposedAt: block.timestamp, exists: true});
        emit CustodianRoleProposed(id, role, account);
    }

    function _validatePendingDelay(uint256 proposedAt) internal view {
        if (block.timestamp < proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
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
        uint256 previousNAV = state.lastNAV;
        if (state.lastNAVTimestamp == 0 || state.navDeltaCapBps == 0) return;
        uint256 delta = nav > previousNAV ? nav - previousNAV : previousNAV - nav;
        uint256 maxDelta = previousNAV * uint256(state.navDeltaCapBps) / 10000;
        if (delta > maxDelta) revert CustodianNAVDeltaCapExceeded(id, previousNAV, nav);
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingGuardianModule = address(0);
        _pendingForageGovernorProposedAt = 0;
        _pendingGuardianModuleProposedAt = 0;
    }
}
