// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "./AllowlistGatedUpgradeable.sol";
import "./GuardianModule.sol";
import "./ForageGovernorTimelockGuard.sol";
import "./interfaces/IAllowlist.sol";

/// @title ForageGovernor — OZ Governor with BPS-based quorum/threshold and external GuardianModule
/// @notice Extends OZ Governor with max active proposals, lazy Defeated cleanup,
///         and UUPS upgradeability. Guardian logic is in a separate GuardianModule contract
///         to stay under the EIP-170 contract size limit (24,576 bytes).
/// @dev OF-I09: The governor intentionally cannot pause itself. Self-pause would create an
/// irrecoverable deadlock — the governor would be unable to unpause itself since proposals
/// require an active (unpaused) governor. Guardian pause targets are restricted to protocol
/// contracts via the GuardianModule's _pausableTargets whitelist (OF-M01).
/// @dev OF-I13: EIP-712 domain is persisted across upgrades by OZ GovernorUpgradeable's
/// EIP712Upgradeable base, which stores the domain name in initializable storage. UUPS
/// upgrades preserve storage, so the domain separator remains valid across implementation
/// changes. Cached domain separator is auto-rebuilt on chain ID change per EIP-712 spec.
contract ForageGovernor is
    Initializable,
    AllowlistGatedUpgradeable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    // ── Custom errors ────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidParameter();
    error MalformedTimelockCalldata();
    error InsufficientVotingPower();
    error MaxActiveProposalsReached();
    error EmptyProposal();
    error Unauthorized();
    error TimelockDelayBelowMinimum(uint256 requested, uint256 minimum); // OF-13-001 (13th audit)
    error NotAContract(); // OF-18-006
    error IncompatibleGuardianModule(); // OF-18-006
    error GuardianModuleRegistryMismatch(address module, address expectedRegistry, address actualRegistry);
    error VotingPeriodBelowMinimum(uint256 requested, uint256 minimum);
    error BlockedAddress(address account);
    error TooManyProposalActions(uint256 count, uint256 maximum);
    error GuardianActiveProposalQuotaReached(address guardian, uint256 active, uint256 maximum);
    error TimelockSelfProposerGrant();
    error TimelockExternalProposerGrant(address account);
    error SignatureVotingDisabled();
    error TimelockRoleMissing(bytes32 role, address account);
    error GuardianTimelockMigrationNotPrepared(address requestedTimelock, address pendingTimelock);
    error TimelockMigrationContextMismatch(address expected, address actual);
    error TimelockCandidateAddressMismatch(address candidate, address expected);
    error TimelockCandidateAlreadyExists(address candidate);
    error TimelockCandidateMissingCode(address candidate);
    error TimelockCandidateNotSystemAccount(address candidate);
    error TimelockAllowlistUnavailable(address allowlistAddress);
    error GuardianTimelockStateUnavailable(address guardianModule);
    error QueuedProposalBlocksTimelockUpdate(uint256 queuedCount, uint256 proposalId);
    error GovernorFreshLayoutRequired(uint256 version);

    // ── Custom events ────────────────────────────────────────────────────
    event QuorumBpsUpdated(uint256 oldQuorumBps, uint256 newQuorumBps);
    event MaxActiveProposalsUpdated(uint256 oldMax, uint256 newMax);
    event ProposalThresholdBpsUpdated(uint256 oldBps, uint256 newBps);
    event GuardianModuleUpdated(address oldModule, address newModule);
    event TimelockMigrationCandidatePrepared(
        address indexed governor,
        address indexed currentTimelock,
        address indexed candidate,
        uint256 minDelay,
        bytes32 salt
    );

    // ── State variables ──────────────────────────────────────────────────
    ForageGovernorTimelockGuard private immutable _timelockGuard;
    uint256 internal _maxActiveProposals;
    uint256 internal _quorumBps;
    uint256 internal _proposalThresholdBps;
    uint256[] internal _activeProposalIds;

    struct ProposalParams {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        bytes32 descriptionHash;
    }

    mapping(uint256 => ProposalParams) internal _proposalParams;

    /// @notice External guardian module managing guardian permissions and actions.
    GuardianModule public guardianModule;

    /// @dev OF-13-016: Snapshot quorum BPS at proposal creation to prevent retroactive changes.
    mapping(uint256 => uint256) internal _proposalQuorumBps;

    uint256 private _reservedGuardianProposalIdPlusOne;
    uint256 private _freshLayoutVersion;
    uint256[41] private __gap;

    // ── Constants ──────────────────────────────────────────────────────
    /// @notice OF-13-001: Minimum timelock delay floor to prevent governance self-reduction.
    uint256 public constant MIN_TIMELOCK_DELAY = 1 days;
    /// @notice Minimum voting-period floor (1 hour); permits the testnet-only fast profile.
    /// @dev Mainnet / production deployment belongs to a separate production-governance deployer.
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    /// @notice CHAIN-V06: Hard cap proposal batch size to keep execution gas bounded.
    uint256 public constant MAX_PROPOSAL_ACTIONS = GovernancePayloadBudget.MAX_TOP_LEVEL_ACTIONS;
    /// @notice CHAIN-V06: Queued proposals older than this no longer consume active proposal slots.
    uint256 public constant STALE_QUEUED_PROPOSAL_AGE = 30 days;
    uint256 private constant STALE_SUCCEEDED_PROPOSAL_AGE = 14 days;
    /// @notice V7: Guardians that bypass token threshold cannot monopolize active proposal slots.
    uint256 public constant MAX_ACTIVE_GUARDIAN_PROPOSALS_PER_GUARDIAN = 1;
    uint256 private constant MAX_ACTIVE_ORDINARY_PROPOSALS_PER_PROPOSER = 3;
    uint256 private constant MAX_TIMELOCK_NESTING = GovernancePayloadBudget.MAX_TIMELOCK_DEPTH;
    uint256 private constant GUARDIAN_PROPOSAL_FLAG = 1 << 255;
    bytes32 private constant _EXECUTING_PROPOSAL_ID_SLOT =
        keccak256("openforage.forager.governor.executing-proposal-id");
    bytes32 private constant _EXECUTING_PROPOSAL_ACTIVE_SLOT =
        keccak256("openforage.forager.governor.executing-proposal-active");

    // ── Public getters ───────────────────────────────────────────────
    function maxActiveProposals() external view returns (uint256) {
        return _maxActiveProposals;
    }

    function activeProposalCount() public view returns (uint256) {
        return ForageGovernorTimelockMigrationGuard.activeProposalCount(
            _activeProposalIds, _proposalQuorumBps, _maxActiveProposals, address(this)
        );
    }

    function activeGuardianProposalCount(address guardian) external view returns (uint256) {
        return ForageGovernorTimelockMigrationGuard.activeProposalCountFor(
            _activeProposalIds, _proposalQuorumBps, guardian, MAX_ACTIVE_GUARDIAN_PROPOSALS_PER_GUARDIAN, address(this)
        );
    }

    /// @notice Returns stored proposal params for a given proposalId.
    /// @dev Used by GuardianModule.guardianCancel() to retrieve cancel params.
    function getProposalParams(uint256 proposalId)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        ProposalParams storage pp = _proposalParams[proposalId];
        uint256 actionCount = pp.targets.length;
        if (actionCount > MAX_PROPOSAL_ACTIONS) {
            revert TooManyProposalActions(actionCount, MAX_PROPOSAL_ACTIONS);
        }
        if (actionCount != pp.values.length || actionCount != pp.calldatas.length) {
            revert MalformedTimelockCalldata();
        }
        uint256 actionBytes = 0;
        for (uint256 i; i < actionCount; ++i) {
            uint256 length = pp.calldatas[i].length;
            if (length > GovernancePayloadBudget.MAX_TOP_LEVEL_ACTION_BYTES - actionBytes) {
                revert MalformedTimelockCalldata();
            }
            actionBytes += length;
        }
        return (pp.targets, pp.values, pp.calldatas, pp.descriptionHash);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address canonicalCustodianRegistry) {
        _disableInitializers();
        _timelockGuard = new ForageGovernorTimelockGuard(canonicalCustodianRegistry);
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0 || _getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    modifier validateGuardianModuleBeforeInitialization(address module, address expectedTimelock) {
        if (module != address(0)) _validateGuardianModule(module, expectedTimelock);
        _;
    }

    function _requireFreshLayout() private view {
        uint256 version = _freshLayoutVersion;
        if (version != 1) revert GovernorFreshLayoutRequired(version);
    }

    modifier freshLayout() {
        _requireFreshLayout();
        _;
    }

    // ── Initializer ──────────────────────────────────────────────────────

    function initialize(
        address forageToken_,
        address timelockController_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThresholdBps_,
        uint256 quorumBps_,
        address guardianModule_
    )
        external
        onlyDuringConstructionBeforeInitialization
        validateGuardianModuleBeforeInitialization(guardianModule_, timelockController_)
        initializer
    {
        if (forageToken_ == address(0)) revert ZeroAddress();
        if (timelockController_ == address(0)) revert ZeroAddress();
        // OF-001: votingPeriod has a one-hour floor (MIN_VOTING_PERIOD); votingDelay may be zero.
        // Network selection lives in deploy scripts, NOT in this contract:
        //   Mainnet / production (every non-test chain): votingDelay=86400 (1d), votingPeriod=432000 (5d),
        //     timelockDelay=691200 (8d) — selected from genesis by a separate production deployer.
        //   Testnet ONLY (Sepolia / Arbitrum-Sepolia / anvil / hardhat): votingDelay=0, votingPeriod=3600 (1h),
        //     timelockDelay=0 — the fast profile so testers avoid multi-day waits; never used on mainnet.
        //   Quorum: 4% (NOT 0 — rejected below). This contract enforces only the floors; it does not pick the profile.
        if (votingPeriod_ < MIN_VOTING_PERIOD) {
            revert VotingPeriodBelowMinimum(votingPeriod_, MIN_VOTING_PERIOD);
        }
        if (proposalThresholdBps_ == 0 || proposalThresholdBps_ > 5000) revert InvalidParameter();
        if (quorumBps_ == 0 || quorumBps_ > 5000) revert InvalidParameter();

        __Governor_init("ForageGovernor");
        __GovernorSettings_init(votingDelay_, votingPeriod_, 0);
        __GovernorVotes_init(IVotes(forageToken_));
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(timelockController_)));
        // UUPSUpgradeable has no init in OZ 5.x (stateless)

        _quorumBps = quorumBps_;
        _proposalThresholdBps = proposalThresholdBps_;
        _maxActiveProposals = 10;

        if (guardianModule_ != address(0)) {
            guardianModule = GuardianModule(guardianModule_);
        }
        _freshLayoutVersion = 1;
    }

    receive() external payable override freshLayout {
        if (_executor() != address(this)) revert GovernorDisabledDeposit();
    }

    // ── Proposal lifecycle (overrides) ───────────────────────────────────

    /// @dev Guardians bypass the token threshold under a per-guardian cap; ordinary proposers
    /// are limited separately while every proposal still shares the global active cap.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(GovernorUpgradeable) freshLayout onlyAllowedCaller returns (uint256) {
        _cleanupTerminalProposals();
        ForageGovernorTimelockMigrationGuard.ProposalAdmissionRequest memory admission;
        admission.reservedProposalIdPlusOne = _reservedGuardianProposalIdPlusOne;
        admission.maxActiveProposals = _maxActiveProposals;
        admission.guardianModule = address(guardianModule);
        admission.proposer = _msgSender();
        admission.tokenAddress = address(token());
        admission.targets = targets;
        admission.values = values;
        admission.calldatas = calldatas;
        admission.description = description;
        admission.governor = address(this);
        (address proposerAddr, bool isGuardianProposer, bool usesReservedSlot) =
            ForageGovernorTimelockMigrationGuard.admitProposal(_activeProposalIds, _proposalQuorumBps, admission);
        _enforceTimelockOperations(_executor(), address(this), targets, values, calldatas);

        uint256 proposalId = _propose(targets, values, calldatas, description, proposerAddr);
        ForageGovernorTimelockMigrationGuard.ProposalRecordRequest memory record;
        record.reservedProposalIdPlusOne = _reservedGuardianProposalIdPlusOne;
        record.proposalId = proposalId;
        record.usesReservedSlot = usesReservedSlot;
        record.isGuardianProposer = isGuardianProposer;
        record.quorumBps = _quorumBps;
        record.targets = targets;
        record.values = values;
        record.calldatas = calldatas;
        record.descriptionHash = keccak256(bytes(description));
        record.governor = address(this);
        _reservedGuardianProposalIdPlusOne = ForageGovernorTimelockMigrationGuard.recordProposal(
            _activeProposalIds, _proposalParamsStorageSlot(), _proposalQuorumBps, record
        );

        return proposalId;
    }

    /// @notice Override public cancel to use broader state bitmap for guardian module.
    /// @dev OZ base cancel() restricts to Pending-only. Guardians need to cancel
    /// Pending|Active|Succeeded|Queued proposals. Our _cancel() override applies
    /// the broader bitmap, so we skip the base's restrictive check.
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override(GovernorUpgradeable) freshLayout onlyAllowedCaller returns (uint256) {
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);
        if (!_validateCancel(proposalId, _msgSender())) {
            revert GovernorUnableToCancel(proposalId, _msgSender());
        }
        // _cancel override handles the broader Pending|Active|Succeeded|Queued bitmap
        return _cancel(targets, values, calldatas, descriptionHash);
    }

    function cancelBelowThreshold(uint256 proposalId) external freshLayout onlyAllowedCaller returns (uint256) {
        ProposalState proposalState = state(proposalId);
        if (!_isBelowThresholdOrdinaryProposal(proposalId, proposalState)) {
            revert GovernorUnableToCancel(proposalId, _msgSender());
        }
        return _cancelStoredProposal(proposalId);
    }

    function _validateCancel(uint256 proposalId, address caller)
        internal
        view
        override(GovernorUpgradeable)
        returns (bool)
    {
        // Proposers match OZ behavior: they can only cancel while the proposal is still Pending.
        if (caller == proposalProposer(proposalId)) return state(proposalId) == ProposalState.Pending;
        // GuardianModule can cancel (delegates guardian cancel permission checks)
        if (address(guardianModule) != address(0) && caller == address(guardianModule)) return true;
        return false;
    }

    function _cancelStoredProposal(uint256 proposalId) private returns (uint256) {
        ProposalParams storage pp = _proposalParams[proposalId];
        return _cancel(pp.targets, pp.values, pp.calldatas, pp.descriptionHash);
    }

    function _isBelowThresholdOrdinaryProposal(uint256 proposalId, ProposalState proposalState)
        private
        view
        returns (bool)
    {
        return ForageGovernorTimelockMigrationGuard.isBelowThresholdOrdinaryProposal(
            _proposalQuorumBps, proposalId, uint8(proposalState), address(this)
        );
    }

    function _clearReservedGuardianProposal(uint256 proposalId) private {
        _reservedGuardianProposalIdPlusOne = ForageGovernorTimelockMigrationGuard.clearReservedGuardianProposal(
            proposalId, _reservedGuardianProposalIdPlusOne, address(this)
        );
    }

    function _proposalParamsStorageSlot() private view returns (uint256 slot) {
        assembly ("memory-safe") {
            slot := _proposalParams.slot
        }
    }

    // ── Parameter setters ────────────────────────────────────────────────

    /// @dev OF-13-016: _quorumBps is now snapshotted per-proposal at creation time.
    /// Changing quorum via governance only affects future proposals.
    function setQuorumBps(uint256 quorumBps_) external freshLayout onlyAllowedCaller {
        if (msg.sender != _executor()) revert Unauthorized();
        if (quorumBps_ == 0 || quorumBps_ > 5000) revert InvalidParameter();

        uint256 oldBps = _quorumBps;
        _quorumBps = quorumBps_;

        emit QuorumBpsUpdated(oldBps, quorumBps_);
    }

    function setVotingDelay(uint48 newVotingDelay)
        public
        override(GovernorSettingsUpgradeable)
        freshLayout
        onlyAllowedCaller
    {
        if (msg.sender != _executor()) revert Unauthorized();
        // OF-001: No hardcoded minimum on votingDelay. Testnet fast profile: 0s. Mainnet / production: 86400s (1 day), set from genesis by the production deployer.
        // Transition via governance proposal; timelock delay protects against malicious changes.
        _setVotingDelay(newVotingDelay);
    }

    function setVotingPeriod(uint32 newVotingPeriod)
        public
        override(GovernorSettingsUpgradeable)
        freshLayout
        onlyAllowedCaller
    {
        if (msg.sender != _executor()) revert Unauthorized();
        if (newVotingPeriod < MIN_VOTING_PERIOD) {
            revert VotingPeriodBelowMinimum(newVotingPeriod, MIN_VOTING_PERIOD);
        }
        // Testnet fast profile: 3600s (1 hour). Mainnet / production: 432000s (5 days), set from genesis by the production deployer.
        _setVotingPeriod(newVotingPeriod);
    }

    function setProposalThresholdBps(uint256 proposalThresholdBps_) external freshLayout onlyAllowedCaller {
        if (msg.sender != _executor()) revert Unauthorized();
        if (proposalThresholdBps_ == 0 || proposalThresholdBps_ > 5000) revert InvalidParameter();

        uint256 oldBps = _proposalThresholdBps;
        _proposalThresholdBps = proposalThresholdBps_;

        emit ProposalThresholdBpsUpdated(oldBps, proposalThresholdBps_);
    }

    function setMaxActiveProposals(uint256 maxActiveProposals_) external freshLayout onlyAllowedCaller {
        if (msg.sender != _executor()) revert Unauthorized();
        if (maxActiveProposals_ == 0 || maxActiveProposals_ > 100) revert InvalidParameter();
        if (
            maxActiveProposals_
                < ForageGovernorTimelockMigrationGuard.activeOrdinaryProposalCount(
                    _activeProposalIds, _proposalQuorumBps, _reservedGuardianProposalIdPlusOne, address(this)
                )
        ) revert InvalidParameter();

        uint256 oldMax = _maxActiveProposals;
        _maxActiveProposals = maxActiveProposals_;

        emit MaxActiveProposalsUpdated(oldMax, maxActiveProposals_);
    }

    function setGuardianModule(address guardianModule_) external freshLayout onlyAllowedCaller {
        if (msg.sender != _executor()) revert Unauthorized();
        _validateGuardianModule(guardianModule_, _executor());

        address oldModule = address(guardianModule);
        guardianModule = GuardianModule(guardianModule_);

        emit GuardianModuleUpdated(oldModule, guardianModule_);
    }

    /// @dev OF-18-006/CHAIN-W05/CHAIN-W18: Validate that a guardian module address is a contract,
    /// exposes the expected interface, and is initialized for this governor and current timelock.
    function _validateGuardianModule(address module, address expectedTimelock) internal view {
        if (module == address(0)) revert ZeroAddress();
        if (module.code.length == 0) revert NotAContract();
        bytes4 registrySelector = GuardianModule.canonicalCustodianRegistry.selector;
        bool registryOk;
        uint256 registrySize;
        uint256 registryWord;
        assembly ("memory-safe") {
            mstore(0, registrySelector)
            registryOk := staticcall(30000, module, 0, 4, 0, 32)
            registrySize := returndatasize()
            registryWord := mload(0)
        }
        if (!registryOk || registrySize != 32 || registryWord > type(uint160).max) {
            revert IncompatibleGuardianModule();
        }
        address actualRegistry = address(uint160(registryWord));
        address expectedRegistry = _timelockGuard.canonicalRegistryAddress();
        if (actualRegistry != expectedRegistry) {
            revert GuardianModuleRegistryMismatch(module, expectedRegistry, actualRegistry);
        }
        // Smoke-test: verify the contract responds to hasPermission and PERMISSION_CAN_PROPOSE
        (bool ok,) =
            module.staticcall(abi.encodeWithSignature("hasPermission(address,uint256)", address(0), uint256(0)));
        if (!ok) revert IncompatibleGuardianModule();
        (bool ok2,) = module.staticcall(abi.encodeWithSignature("PERMISSION_CAN_PROPOSE()"));
        if (!ok2) revert IncompatibleGuardianModule();
        (bool ok3, bytes memory governorData) = module.staticcall(abi.encodeWithSignature("governor()"));
        if (!ok3 || governorData.length < 32 || abi.decode(governorData, (address)) != address(this)) {
            revert IncompatibleGuardianModule();
        }
        (bool ok4, bytes memory timelockData) = module.staticcall(abi.encodeWithSignature("timelock()"));
        if (!ok4 || timelockData.length < 32 || abi.decode(timelockData, (address)) != expectedTimelock) {
            revert IncompatibleGuardianModule();
        }
    }

    // ── Required overrides (OZ Governor diamond) ─────────────────────────

    function COUNTING_MODE()
        public
        pure
        override(GovernorCountingSimpleUpgradeable, IGovernor)
        returns (string memory)
    {
        return "support=bravo&quorum=for";
    }

    /// @dev OF-13-016: quorum() uses current _quorumBps as fallback for external queries.
    /// For proposal-specific quorum (used in voting), see _quorumReached which uses
    /// the snapshotted _proposalQuorumBps[proposalId].
    function quorum(uint256 timepoint) public view override(GovernorUpgradeable) returns (uint256) {
        return token().getPastTotalSupply(timepoint) * _quorumBps / 10_000;
    }

    /// @dev OF-13-016: Returns the quorum for a specific proposal using the snapshotted BPS.
    /// Falls back to current _quorumBps for proposals created before the snapshot feature
    /// (pre-upgrade: _proposalQuorumBps[proposalId] == 0).
    function quorumForProposal(uint256 proposalId) public view returns (uint256) {
        uint256 snapshotBps = _proposalQuorumBps[proposalId] & ~GUARDIAN_PROPOSAL_FLAG;
        uint256 bps = snapshotBps > 0 ? snapshotBps : _quorumBps;
        return token().getPastTotalSupply(proposalSnapshot(proposalId)) * bps / 10_000;
    }

    /// @notice NEM-T2-M01: Override to require forVotes >= quorum (abstain votes do not count).
    /// @dev OZ default counts forVotes + abstainVotes toward quorum. This override ensures
    /// that only explicit "For" votes can reach quorum, preventing abstain-only proposals
    /// from passing the quorum gate.
    /// @dev OF-13-016: Uses snapshotted _proposalQuorumBps instead of live _quorumBps.
    function _quorumReached(uint256 proposalId)
        internal
        view
        override(GovernorUpgradeable, GovernorCountingSimpleUpgradeable)
        returns (bool)
    {
        (, uint256 forVotes,) = proposalVotes(proposalId);
        return forVotes >= quorumForProposal(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return token().getPastTotalSupply(clock() - 1) * _proposalThresholdBps / 10_000;
    }

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.votingDelay();
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.votingPeriod();
    }

    function _isValidDescriptionForProposer(address proposerAddr, string memory description)
        internal
        pure
        override(GovernorUpgradeable)
        returns (bool)
    {
        return ForageGovernorTimelockMigrationGuard.isValidDescriptionForProposer(proposerAddr, description);
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        ProposalState proposalState = GovernorTimelockControlUpgradeable.state(proposalId);
        if (
            proposalState == ProposalState.Succeeded
                && block.timestamp > proposalDeadline(proposalId) + STALE_SUCCEEDED_PROPOSAL_AGE
        ) return ProposalState.Expired;
        return proposalState;
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return GovernorTimelockControlUpgradeable.proposalNeedsQueuing(proposalId);
    }

    function updateTimelock(TimelockControllerUpgradeable newTimelock)
        public
        override(GovernorTimelockControlUpgradeable)
        freshLayout
        onlyAllowedCaller
    {
        if (address(newTimelock) == address(0)) revert ZeroAddress();
        ForageGovernorTimelockMigrationGuard.validate(
            _activeProposalIds, address(guardianModule), address(newTimelock), address(this), address(_timelockGuard)
        );
        super.updateTimelock(newTimelock);
    }

    function prepareTimelockMigrationCandidate(uint256 minDelay)
        external
        freshLayout
        onlyAllowedCaller
        returns (address)
    {
        if (msg.sender != address(this)) revert Unauthorized();
        return ForageGovernorTimelockMigrationGuard.prepareTimelock(address(this), _executor(), minDelay);
    }

    function relay(address target, uint256 value, bytes calldata data)
        public
        payable
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
    {
        if (data.length > GovernancePayloadBudget.MAX_TOP_LEVEL_ACTION_BYTES) revert MalformedTimelockCalldata();
        _enforceTimelockOperationGuards(_executor(), target, value, data);
        super.relay(target, value, data);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        _enforceTimelockOperations(_executor(), address(this), targets, values, calldatas);
        return
            GovernorTimelockControlUpgradeable._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        address executor = _executor();
        _enforceTimelockOperations(executor, address(this), targets, values, calldatas);
        uint256 previousExecutingProposalId;
        uint256 previousExecutionActive;
        bytes32 executionSlot = _EXECUTING_PROPOSAL_ID_SLOT;
        bytes32 executionActiveSlot = _EXECUTING_PROPOSAL_ACTIVE_SLOT;
        assembly ("memory-safe") {
            previousExecutingProposalId := tload(executionSlot)
            previousExecutionActive := tload(executionActiveSlot)
            tstore(executionSlot, proposalId)
            tstore(executionActiveSlot, 1)
        }
        GovernorTimelockControlUpgradeable._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
        assembly ("memory-safe") {
            tstore(executionSlot, previousExecutingProposalId)
            tstore(executionActiveSlot, previousExecutionActive)
        }
        _removeActiveProposal(proposalId);
        delete _proposalParams[proposalId];
    }

    function _enforceTimelockOperations(
        address executor,
        address allowedProposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) internal view {
        _timelockGuard.enforceOperations(
            executor,
            allowedProposer,
            address(guardianModule),
            MIN_TIMELOCK_DELAY,
            MAX_TIMELOCK_NESTING,
            targets,
            values,
            calldatas
        );
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);

        // Custom bitmap: Pending|Active|Succeeded|Queued (excludes Defeated)
        _validateStateBitmap(
            proposalId,
            _encodeStateBitmap(ProposalState.Pending) | _encodeStateBitmap(ProposalState.Active)
                | _encodeStateBitmap(ProposalState.Succeeded) | _encodeStateBitmap(ProposalState.Queued)
        );

        // Delegate to GovernorTimelockControlUpgradeable (handles Governor state + timelock cancellation)
        uint256 result = GovernorTimelockControlUpgradeable._cancel(targets, values, calldatas, descriptionHash);

        // Track active proposals
        _removeActiveProposal(proposalId);
        delete _proposalParams[proposalId];

        return result;
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return GovernorTimelockControlUpgradeable._executor();
    }

    function _enforceTimelockOperationGuards(address executor, address target, uint256 value, bytes memory data)
        internal
        view
    {
        _timelockGuard.enforceOperation(
            executor,
            address(this),
            address(guardianModule),
            MIN_TIMELOCK_DELAY,
            MAX_TIMELOCK_NESTING,
            target,
            value,
            data
        );
    }

    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
        internal
        override(GovernorUpgradeable)
        returns (uint256)
    {
        ForageGovernorTimelockMigrationGuard.requireNotBlocked(address(token()), account, address(this));
        // Let super handle state validation first, then check voting power
        uint256 weight = super._castVote(proposalId, account, support, reason, params);
        // OF-L18: Allow zero-weight abstentions (support == 2) but reject zero-weight For/Against
        if (weight == 0 && support != 2) revert InsufficientVotingPower();
        return weight;
    }

    // ── Caller-gate overrides (DEC-1074) ──────────────────────────────────

    function castVote(uint256 proposalId, uint8 support)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (uint256)
    {
        return super.castVote(proposalId, support);
    }

    function castVoteWithReason(uint256 proposalId, uint8 support, string calldata reason)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (uint256)
    {
        return super.castVoteWithReason(proposalId, support, reason);
    }

    function castVoteWithReasonAndParams(uint256 proposalId, uint8 support, string calldata reason, bytes memory params)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (uint256)
    {
        return super.castVoteWithReasonAndParams(proposalId, support, reason, params);
    }

    function castVoteBySig(uint256, uint8, address, bytes memory)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (uint256)
    {
        revert SignatureVotingDisabled();
    }

    function castVoteWithReasonAndParamsBySig(uint256, uint8, address, string calldata, bytes memory, bytes memory)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (uint256)
    {
        revert SignatureVotingDisabled();
    }

    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (uint256)
    {
        return super.queue(targets, values, calldatas, descriptionHash);
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override(GovernorUpgradeable) freshLayout onlyAllowedCaller returns (uint256) {
        return super.execute(targets, values, calldatas, descriptionHash);
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override(UUPSUpgradeable)
        freshLayout
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    function setProposalThreshold(uint256 newProposalThreshold)
        public
        override(GovernorSettingsUpgradeable)
        freshLayout
        onlyAllowedCaller
    {
        super.setProposalThreshold(newProposalThreshold);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes memory data)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (bytes4)
    {
        return super.onERC721Received(operator, from, tokenId, data);
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes memory data)
        public
        override(GovernorUpgradeable)
        freshLayout
        onlyAllowedCaller
        returns (bytes4)
    {
        return super.onERC1155Received(operator, from, id, value, data);
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override(GovernorUpgradeable) freshLayout onlyAllowedCaller returns (bytes4) {
        return super.onERC1155BatchReceived(operator, from, ids, values, data);
    }

    function setAllowlist(address allowlist_) external freshLayout {
        if (msg.sender != _executor()) revert Unauthorized();
        if (allowlist_ == address(0) || allowlist_.code.length == 0) revert IAllowlist.AllowlistUnavailable();

        address currentAllowlist = allowlist();
        if (currentAllowlist != address(0)) _checkAllowedCaller();

        IAllowlist proposedAllowlist = IAllowlist(allowlist_);
        if (!proposedAllowlist.isAllowed(msg.sender) || !proposedAllowlist.isSystemAccount(msg.sender)) {
            revert IAllowlist.CallerNotAllowed(msg.sender);
        }
        if (!proposedAllowlist.isAllowed(address(this)) || !proposedAllowlist.isSystemAccount(address(this))) {
            revert IAllowlist.CallerNotAllowed(address(this));
        }
        _setAllowlist(allowlist_);
    }

    function _authorizeUpgrade(address) internal override {
        _requireFreshLayout();
        if (msg.sender != _executor()) revert Unauthorized();
        _checkAllowedCaller();
    }

    /// @notice OF-G01: Standalone cleanup for gas-conscious callers. Removes terminal
    /// proposals (Defeated, Expired, Executed, Canceled) from the active tracking array.
    /// Also called lazily in propose(), but this external version allows anyone to trigger
    /// cleanup without submitting a new proposal.
    function cleanupDefeated() external freshLayout onlyAllowedCaller {
        _cleanupTerminalProposals();
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    function _cleanupTerminalProposals() internal {
        _requireFreshLayout();
        _cleanupBelowThresholdProposals();
        _reservedGuardianProposalIdPlusOne = ForageGovernorTimelockMigrationGuard.cleanupTerminalProposals(
            _activeProposalIds,
            _proposalParamsStorageSlot(),
            _proposalQuorumBps,
            _reservedGuardianProposalIdPlusOne,
            address(this)
        );
    }

    function _cleanupBelowThresholdProposals() private {
        uint256 i;
        while (i < _activeProposalIds.length) {
            uint256 proposalId = _activeProposalIds[i];
            ProposalState proposalState = state(proposalId);
            if (
                _isBelowThresholdOrdinaryProposal(proposalId, proposalState)
                    || (proposalState == ProposalState.Queued && !_usesActiveProposalSlot(proposalId, proposalState))
            ) {
                _cancelStoredProposal(proposalId);
            } else {
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _usesActiveProposalSlot(uint256 proposalId, ProposalState proposalState) internal view returns (bool) {
        if (proposalState <= ProposalState.Active) {
            return !_isBelowThresholdOrdinaryProposal(proposalId, proposalState);
        }
        if (proposalState == ProposalState.Succeeded) return true;
        if (proposalState != ProposalState.Queued) return false;
        uint256 eta = proposalEta(proposalId);
        return eta == 0 || block.timestamp <= eta + STALE_QUEUED_PROPOSAL_AGE;
    }

    function _removeActiveProposal(uint256 proposalId) internal {
        _clearReservedGuardianProposal(proposalId);
        // OF-035: Cache storage length to avoid redundant SLOAD per iteration
        uint256 len = _activeProposalIds.length;
        for (uint256 i = 0; i < len;) {
            if (_activeProposalIds[i] == proposalId) {
                _activeProposalIds[i] = _activeProposalIds[len - 1];
                _activeProposalIds.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }
}
