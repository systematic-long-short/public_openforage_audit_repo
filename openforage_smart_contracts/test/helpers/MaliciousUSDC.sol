// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MaliciousUSDC - ERC20 mock that re-enters a target during transferFrom
/// @dev Used by TC-18 reentrancy tests. On transferFrom, after the normal transfer,
///      calls the configured re-entry target with the configured calldata.
///      If reentryEnabled is false, behaves as a normal ERC20 (for initial setup).
contract MaliciousUSDC is ERC20 {
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public reentryEnabled;

    constructor() ERC20("Malicious USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Configure the re-entry attack parameters.
    /// @param target_ The contract to re-enter
    /// @param calldata_ The calldata to use for the re-entry call
    function setReentry(address target_, bytes calldata calldata_) external {
        reentryTarget = target_;
        reentryCalldata = calldata_;
    }

    /// @dev Enable or disable the re-entry callback.
    function setReentryEnabled(bool enabled_) external {
        reentryEnabled = enabled_;
    }

    /// @dev Override transferFrom to trigger re-entry after the normal transfer.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);

        // Trigger re-entry if enabled
        if (reentryEnabled && reentryTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = reentryTarget.call(reentryCalldata);
            // We do not revert if the re-entry call fails -- the test's
            // vm.expectRevert will catch the ReentrancyGuardReentrantCall
            // from the target contract. If the call succeeded, that means
            // reentrancy was NOT properly guarded (test should fail).
            success; // silence unused variable warning
        }

        return result;
    }
}
