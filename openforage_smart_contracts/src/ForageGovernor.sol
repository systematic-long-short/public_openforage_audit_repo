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
import "./GuardianModule.sol";
import "./interfaces/IBlocklist.sol";

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
    error InsufficientVotingPower();
    error MaxActiveProposalsReached();
    error EmptyProposal();
    error Unauthorized();
    error TimelockDelayBelowMinimum(uint256 requested, uint256 minimum); // OF-13-001 (13th audit)
    error NotAContract(); // OF-18-006
    error IncompatibleGuardianModule(); // OF-18-006
    error VotingPeriodBelowMinimum(uint256 requested, uint256 minimum);
    error BlockedAddress(address account);
    error TooManyProposalActions(uint256 count, uint256 maximum);
    error GuardianActiveProposalQuotaReached(address guardian, uint256 active, uint256 maximum);
    error TimelockSelfProposerGrant();

    // ── Custom events ────────────────────────────────────────────────────
    event QuorumBpsUpdated(uint256 oldQuorumBps, uint256 newQuorumBps);
    event MaxActiveProposalsUpdated(uint256 oldMax, uint256 newMax);
    event ProposalThresholdBpsUpdated(uint256 oldBps, uint256 newBps);
    event GuardianModuleUpdated(address oldModule, address newModule);

    // ── State variables ──────────────────────────────────────────────────
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

    /// @dev Reserved storage gap for future upgrades (7 vars + 43 gap = 50)
    uint256[43] private __gap;

    // ── Constants ──────────────────────────────────────────────────────
    /// @notice OF-13-001: Minimum timelock delay floor to prevent governance self-reduction.
    uint256 public constant MIN_TIMELOCK_DELAY = 1 days;
    /// @notice Minimum voting-period floor (1 hour); permits the testnet-only fast profile.
    /// @dev Mainnet / production deployment belongs to a separate production-governance deployer.
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    /// @notice CHAIN-V06: Hard cap proposal batch size to keep execution gas bounded.
    uint256 public constant MAX_PROPOSAL_ACTIONS = 100;
    /// @notice CHAIN-V06: Queued proposals older than this no longer consume active proposal slots.
    uint256 public constant STALE_QUEUED_PROPOSAL_AGE = 30 days;
    /// @notice V7: Guardians that bypass token threshold cannot monopolize active proposal slots.
    uint256 public constant MAX_ACTIVE_GUARDIAN_PROPOSALS_PER_GUARDIAN = 1;

    // ── Public getters ───────────────────────────────────────────────
    function maxActiveProposals() external view returns (uint256) {
        return _maxActiveProposals;
    }

    /// @dev OF-13-055: Optimized with early termination — stops once count reaches
    /// _maxActiveProposals (no proposal can be added beyond that, so remaining entries
    /// must all be terminal). Cache length and max to minimize SLOADs.
    function activeProposalCount() public view returns (uint256) {
        uint256 count = 0;
        uint256 len = _activeProposalIds.length;
        uint256 maxActive = _maxActiveProposals;
        for (uint256 i = 0; i < len;) {
            ProposalState s = state(_activeProposalIds[i]);
            if (_usesActiveProposalSlot(_activeProposalIds[i], s)) {
                unchecked {
                    ++count;
                }
                if (count >= maxActive) return count; // OF-13-055: early exit
            }
            unchecked {
                ++i;
            }
        }
        return count;
    }

    function activeGuardianProposalCount(address guardian) external view returns (uint256) {
        return _activeProposalCountFor(guardian);
    }

    /// @notice Returns stored proposal params for a given proposalId.
    /// @dev Used by GuardianModule.guardianCancel() to retrieve cancel params.
    function getProposalParams(uint256 proposalId)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        ProposalParams storage pp = _proposalParams[proposalId];
        return (pp.targets, pp.values, pp.calldatas, pp.descriptionHash);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
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
    ) external initializer {
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
            _validateGuardianModule(guardianModule_);
            guardianModule = GuardianModule(guardianModule_);
        }
    }

    // ── Proposal lifecycle (overrides) ───────────────────────────────────

    /// @dev OF-033: Guardians with PERMISSION_CAN_PROPOSE bypass the token threshold but share
    /// the global _maxActiveProposals cap and a stricter per-guardian cap.
    /// Mitigation: cancel-capable guardians can clear spam; proposals expire after votingPeriod.
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(GovernorUpgradeable) returns (uint256) {
        // Lazy cleanup of terminal proposals
        _cleanupTerminalProposals();

        if (targets.length > MAX_PROPOSAL_ACTIONS) {
            revert TooManyProposalActions(targets.length, MAX_PROPOSAL_ACTIONS);
        }
        if (activeProposalCount() >= _maxActiveProposals) revert MaxActiveProposalsReached();

        // Guardian bypass: skip threshold check if caller has PERMISSION_CAN_PROPOSE in the module
        address proposerAddr = _msgSender();
        _requireNotBlocked(proposerAddr);
        if (!_isValidDescriptionForProposer(proposerAddr, description)) {
            revert GovernorRestrictedProposer(proposerAddr);
        }
        bool isGuardianProposer = address(guardianModule) != address(0)
            && guardianModule.hasPermission(proposerAddr, guardianModule.PERMISSION_CAN_PROPOSE());

        if (isGuardianProposer) {
            uint256 activeByGuardian = _activeProposalCountFor(proposerAddr);
            if (activeByGuardian >= MAX_ACTIVE_GUARDIAN_PROPOSALS_PER_GUARDIAN) {
                revert GuardianActiveProposalQuotaReached(
                    proposerAddr, activeByGuardian, MAX_ACTIVE_GUARDIAN_PROPOSALS_PER_GUARDIAN
                );
            }
        } else {
            uint256 proposerVotes = getVotes(proposerAddr, clock() - 1);
            uint256 threshold = proposalThreshold();
            if (threshold > 0 && proposerVotes < threshold) {
                revert InsufficientVotingPower();
            }
        }

        // Call internal _propose (bypasses super's threshold check)
        uint256 proposalId = _propose(targets, values, calldatas, description, proposerAddr);

        // Store proposal params for guardian cancel
        ProposalParams storage pp = _proposalParams[proposalId];
        pp.targets = targets;
        pp.values = values;
        pp.calldatas = calldatas;
        pp.descriptionHash = keccak256(bytes(description));

        // Track active proposal
        _activeProposalIds.push(proposalId);

        // OF-13-016: Snapshot quorum BPS at proposal creation
        _proposalQuorumBps[proposalId] = _quorumBps;

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
    ) public override(GovernorUpgradeable) returns (uint256) {
        uint256 proposalId = getProposalId(targets, values, calldatas, descriptionHash);
        if (!_validateCancel(proposalId, _msgSender())) {
            revert GovernorUnableToCancel(proposalId, _msgSender());
        }
        // _cancel override handles the broader Pending|Active|Succeeded|Queued bitmap
        return _cancel(targets, values, calldatas, descriptionHash);
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

    function _activeProposalCountFor(address proposerAddr) internal view returns (uint256 count) {
        uint256 len = _activeProposalIds.length;
        for (uint256 i; i < len;) {
            uint256 proposalId = _activeProposalIds[i];
            if (_usesActiveProposalSlot(proposalId, state(proposalId)) && proposalProposer(proposalId) == proposerAddr)
            {
                unchecked {
                    ++count;
                }
                if (count >= MAX_ACTIVE_GUARDIAN_PROPOSALS_PER_GUARDIAN) return count;
            }
            unchecked {
                ++i;
            }
        }
    }

    // ── Parameter setters ────────────────────────────────────────────────

    /// @dev OF-13-016: _quorumBps is now snapshotted per-proposal at creation time.
    /// Changing quorum via governance only affects future proposals.
    function setQuorumBps(uint256 quorumBps_) external {
        if (msg.sender != _executor()) revert Unauthorized();
        if (quorumBps_ == 0 || quorumBps_ > 5000) revert InvalidParameter();

        uint256 oldBps = _quorumBps;
        _quorumBps = quorumBps_;

        emit QuorumBpsUpdated(oldBps, quorumBps_);
    }

    function setVotingDelay(uint48 newVotingDelay) public override(GovernorSettingsUpgradeable) {
        if (msg.sender != _executor()) revert Unauthorized();
        // OF-001: No hardcoded minimum on votingDelay. Testnet fast profile: 0s. Mainnet / production: 86400s (1 day), set from genesis by the production deployer.
        // Transition via governance proposal; timelock delay protects against malicious changes.
        _setVotingDelay(newVotingDelay);
    }

    function setVotingPeriod(uint32 newVotingPeriod) public override(GovernorSettingsUpgradeable) {
        if (msg.sender != _executor()) revert Unauthorized();
        if (newVotingPeriod < MIN_VOTING_PERIOD) {
            revert VotingPeriodBelowMinimum(newVotingPeriod, MIN_VOTING_PERIOD);
        }
        // Testnet fast profile: 3600s (1 hour). Mainnet / production: 432000s (5 days), set from genesis by the production deployer.
        _setVotingPeriod(newVotingPeriod);
    }

    function setProposalThresholdBps(uint256 proposalThresholdBps_) external {
        if (msg.sender != _executor()) revert Unauthorized();
        if (proposalThresholdBps_ == 0 || proposalThresholdBps_ > 5000) revert InvalidParameter();

        uint256 oldBps = _proposalThresholdBps;
        _proposalThresholdBps = proposalThresholdBps_;

        emit ProposalThresholdBpsUpdated(oldBps, proposalThresholdBps_);
    }

    function setMaxActiveProposals(uint256 maxActiveProposals_) external {
        if (msg.sender != _executor()) revert Unauthorized();
        if (maxActiveProposals_ == 0 || maxActiveProposals_ > 100) revert InvalidParameter();

        uint256 oldMax = _maxActiveProposals;
        _maxActiveProposals = maxActiveProposals_;

        emit MaxActiveProposalsUpdated(oldMax, maxActiveProposals_);
    }

    function setGuardianModule(address guardianModule_) external {
        if (msg.sender != _executor()) revert Unauthorized();
        _validateGuardianModule(guardianModule_);

        address oldModule = address(guardianModule);
        guardianModule = GuardianModule(guardianModule_);

        emit GuardianModuleUpdated(oldModule, guardianModule_);
    }

    /// @dev OF-18-006/CHAIN-W05/CHAIN-W18: Validate that a guardian module address is a contract,
    /// exposes the expected interface, and is initialized for this governor and current timelock.
    function _validateGuardianModule(address module) internal view {
        if (module == address(0)) revert ZeroAddress();
        if (module.code.length == 0) revert NotAContract();
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
        if (!ok4 || timelockData.length < 32 || abi.decode(timelockData, (address)) != _executor()) {
            revert IncompatibleGuardianModule();
        }
    }

    // ── Required overrides (OZ Governor diamond) ─────────────────────────

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
        uint256 snapshotBps = _proposalQuorumBps[proposalId];
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

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return GovernorTimelockControlUpgradeable.state(proposalId);
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
        onlyGovernance
    {
        if (address(newTimelock) == address(0)) revert ZeroAddress();
        if (address(newTimelock).code.length == 0) revert NotAContract();
        uint256 newDelay = newTimelock.getMinDelay();
        if (newDelay < MIN_TIMELOCK_DELAY) {
            revert TimelockDelayBelowMinimum(newDelay, MIN_TIMELOCK_DELAY);
        }
        super.updateTimelock(newTimelock);
    }

    function relay(address target, uint256 value, bytes calldata data) public payable override(GovernorUpgradeable) {
        _enforceTimelockOperationGuards(_executor(), target, data);
        super.relay(target, value, data);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
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
        // V28: prioritize unsafe delay-floor schedules before other timelock role guards.
        for (uint256 i = 0; i < targets.length;) {
            _enforceTimelockOperation(executor, targets[i], calldatas[i], true, false);
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < targets.length;) {
            _enforceTimelockOperation(executor, targets[i], calldatas[i], false, true);
            unchecked {
                ++i;
            }
        }
        GovernorTimelockControlUpgradeable._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
        _removeActiveProposal(proposalId);
        delete _proposalParams[proposalId];
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

    function _enforceTimelockOperationGuards(address executor, address target, bytes memory data) internal pure {
        _enforceTimelockOperation(executor, target, data, true, false);
        _enforceTimelockOperation(executor, target, data, false, true);
    }

    function _enforceTimelockOperation(
        address executor,
        address target,
        bytes memory data,
        bool checkDelayFloor,
        bool checkSelfProposerGrant
    ) internal pure {
        if (target != executor || data.length < 4) return;
        bytes4 selector = _operationSelector(data);
        bytes memory payload = _operationPayload(data);
        if (checkDelayFloor && selector == _updateDelaySelector()) {
            uint256 newDelay = abi.decode(payload, (uint256));
            _revertIfDelayBelowFloor(newDelay);
            return;
        }
        if (checkSelfProposerGrant && selector == _timelockGrantRoleSelector()) {
            (bytes32 role, address account) = abi.decode(payload, (bytes32, address));
            if (role == _timelockProposerRole() && account == executor) revert TimelockSelfProposerGrant();
            return;
        }
        if (selector == _timelockScheduleSelector()) {
            (address scheduledTarget,, bytes memory scheduledData,,,) =
                abi.decode(payload, (address, uint256, bytes, bytes32, bytes32, uint256));
            _enforceTimelockOperation(executor, scheduledTarget, scheduledData, checkDelayFloor, checkSelfProposerGrant);
            return;
        }
        if (selector == _timelockScheduleBatchSelector()) {
            (address[] memory scheduledTargets,, bytes[] memory scheduledPayloads,,,) =
                abi.decode(payload, (address[], uint256[], bytes[], bytes32, bytes32, uint256));
            for (uint256 i; i < scheduledTargets.length;) {
                _enforceTimelockOperation(
                    executor, scheduledTargets[i], scheduledPayloads[i], checkDelayFloor, checkSelfProposerGrant
                );
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _operationSelector(bytes memory data) internal pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _operationPayload(bytes memory data) internal pure returns (bytes memory payload) {
        uint256 payloadLength = data.length - 4;
        payload = new bytes(payloadLength);
        for (uint256 i; i < payloadLength;) {
            payload[i] = data[i + 4];
            unchecked {
                ++i;
            }
        }
    }

    function _revertIfDelayBelowFloor(uint256 newDelay) internal pure {
        if (newDelay < MIN_TIMELOCK_DELAY) {
            revert TimelockDelayBelowMinimum(newDelay, MIN_TIMELOCK_DELAY);
        }
    }

    function _updateDelaySelector() internal pure returns (bytes4) {
        return bytes4(keccak256("updateDelay(uint256)"));
    }

    function _timelockScheduleSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("schedule(address,uint256,bytes,bytes32,bytes32,uint256)"));
    }

    function _timelockScheduleBatchSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)"));
    }

    function _timelockGrantRoleSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("grantRole(bytes32,address)"));
    }

    function _timelockProposerRole() internal pure returns (bytes32) {
        return keccak256("PROPOSER_ROLE");
    }

    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
        internal
        override(GovernorUpgradeable)
        returns (uint256)
    {
        _requireNotBlocked(account);
        // Let super handle state validation first, then check voting power
        uint256 weight = super._castVote(proposalId, account, support, reason, params);
        // OF-L18: Allow zero-weight abstentions (support == 2) but reject zero-weight For/Against
        if (weight == 0 && support != 2) revert InsufficientVotingPower();
        return weight;
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != _executor()) revert Unauthorized();
    }

    function _requireNotBlocked(address account) internal view {
        address tokenAddress = address(token());
        (bool ok, bytes memory data) = tokenAddress.staticcall(abi.encodeWithSignature("blocklist()"));
        if (!ok || data.length < 32) return;

        address blocklist_ = abi.decode(data, (address));
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    /// @notice OF-G01: Standalone cleanup for gas-conscious callers. Removes terminal
    /// proposals (Defeated, Expired, Executed, Canceled) from the active tracking array.
    /// Also called lazily in propose(), but this external version allows anyone to trigger
    /// cleanup without submitting a new proposal.
    function cleanupDefeated() external {
        _cleanupTerminalProposals();
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    /// @dev OF-006: _activeProposalIds growth is bounded. Every propose() call runs
    /// _cleanupTerminalProposals(), which removes all terminal proposals (Defeated, Expired,
    /// Executed, Canceled). After cleanup, remaining entries ≤ _maxActiveProposals (max 100).
    /// Additionally, cleanupDefeated() allows permissionless cleanup without submitting a proposal.
    /// Therefore the array can never grow beyond _maxActiveProposals + number of proposals
    /// created in a single block (practically bounded by block gas limit).
    function _cleanupTerminalProposals() internal {
        uint256 writeIdx = 0;
        // OF-035: Cache storage length to avoid redundant SLOAD per iteration
        uint256 len = _activeProposalIds.length;
        for (uint256 i = 0; i < len;) {
            uint256 proposalId = _activeProposalIds[i];
            ProposalState s = state(proposalId);
            if (_usesActiveProposalSlot(proposalId, s)) {
                if (writeIdx != i) {
                    _activeProposalIds[writeIdx] = proposalId;
                }
                writeIdx++;
            } else if (s != ProposalState.Queued) {
                // OF-L19: Clear stored proposal params for terminal proposals (Defeated, Expired, Executed, Canceled)
                delete _proposalParams[proposalId];
            }
            unchecked {
                ++i;
            }
        }
        while (_activeProposalIds.length > writeIdx) {
            _activeProposalIds.pop();
        }
    }

    function _usesActiveProposalSlot(uint256 proposalId, ProposalState proposalState) internal view returns (bool) {
        if (
            proposalState == ProposalState.Pending || proposalState == ProposalState.Active
                || proposalState == ProposalState.Succeeded
        ) {
            return true;
        }
        if (proposalState != ProposalState.Queued) return false;
        uint256 eta = proposalEta(proposalId);
        return eta == 0 || block.timestamp <= eta + STALE_QUEUED_PROPOSAL_AGE;
    }

    function _removeActiveProposal(uint256 proposalId) internal {
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
