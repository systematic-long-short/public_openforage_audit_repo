// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IForageGovernorPause — Minimal interface for guardian module resolution
/// @dev OF-19-002: Pausable contracts query ForageGovernor for the guardian module address
/// to authorize emergency pause/unpause calls without storing an additional address.
interface IForageGovernorPause {
    function guardianModule() external view returns (address);
}
