// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../../src/GuardianModule.sol";

/// @dev BAD layout: inserts `insertedVar` BEFORE `_maxActiveProposals`, shifting
///      all ForageGovernor-specific storage slots. Used by TC-09 negative layout test.
///      After upgrading to this, reading _maxActiveProposals/quorumBps/etc.
///      returns corrupted data because they now read from wrong slots.
///
///      ForageGovernor real layout (post-refactor):
///        _maxActiveProposals
///        _quorumBps
///        _proposalThresholdBps
///        _activeProposalIds (EnumerableSet)
///        _proposalParams (mapping)
///        guardianModule (GuardianModule)
///        __gap[43]
///
///      Bad layout (inserts variable BEFORE _maxActiveProposals):
///        insertedVar              <-- INSERTED HERE, shifts everything down
///        _maxActiveProposals
///        _quorumBps
///        _proposalThresholdBps
///        _activeProposalIds (EnumerableSet)
///        _proposalParams (mapping)
///        guardianModule (GuardianModule)
///        __gap[43]
contract ForageGovernorV2BadLayout is
    Initializable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    // ---- Storage layout: DELIBERATELY WRONG (inserted variable) ----
    uint256 public insertedVar; // <-- INSERTED HERE, shifts everything down
    uint256 internal _maxActiveProposals;
    uint256 internal _quorumBps;
    uint256 internal _proposalThresholdBps;
    // _activeProposalIds (EnumerableSet) and _proposalParams (mapping) are complex types
    // that don't need to be replicated exactly for the corruption test
    // guardianModule is now a reference to external contract
    GuardianModule public guardianModule;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function versionV2BadLayout() external pure returns (uint256) {
        return 99;
    }

    /// @dev Expose _maxActiveProposals for corruption testing
    function readMaxActiveProposals() external view returns (uint256) {
        return _maxActiveProposals;
    }

    // ── Required overrides (must exist for compilation) ─────────────

    function quorum(uint256) public view override(GovernorUpgradeable) returns (uint256) {
        revert("BAD_LAYOUT");
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        revert("BAD_LAYOUT");
    }

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        revert("BAD_LAYOUT");
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        revert("BAD_LAYOUT");
    }

    function state(uint256)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        revert("BAD_LAYOUT");
    }

    function proposalNeedsQueuing(uint256)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        revert("BAD_LAYOUT");
    }

    function _queueOperations(uint256, address[] memory, uint256[] memory, bytes[] memory, bytes32)
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint48)
    {
        revert("BAD_LAYOUT");
    }

    function _executeOperations(uint256, address[] memory, uint256[] memory, bytes[] memory, bytes32)
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
    {
        revert("BAD_LAYOUT");
    }

    function _cancel(address[] memory, uint256[] memory, bytes[] memory, bytes32)
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint256)
    {
        revert("BAD_LAYOUT");
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        revert("BAD_LAYOUT");
    }

    function _authorizeUpgrade(address) internal override {
        // No access control -- bad layout contract used only for storage collision test
    }
}
