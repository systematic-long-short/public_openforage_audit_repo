// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal mock that satisfies _requireNoLossPending() in atRISKUSD.
/// Returns itself as the riskusdVault() and lossPending() returns false.
/// Used by AtRISKUSDTestBase to provide a yieldSource with code that
/// responds to the two staticcalls in the fail-closed lossPending check.
contract MockYieldSourceForLossPending {
    bool private _lossPending;

    /// @dev Called by atRISKUSD._requireNoLossPending() first staticcall.
    function riskusdVault() external view returns (address) {
        return address(this);
    }

    /// @dev Called by atRISKUSD._requireNoLossPending() second staticcall.
    function lossPending() external view returns (bool) {
        return _lossPending;
    }

    /// @dev Allow tests to toggle lossPending state.
    function setLossPending(bool pending) external {
        _lossPending = pending;
    }
}
