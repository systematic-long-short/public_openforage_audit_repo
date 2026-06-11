// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MaliciousRISKUSD - ERC20 mock that re-enters a target during transfer/transferFrom
/// @dev Used by TC-18 reentrancy tests for the withdrawal chain. During transfer
///      (called by executeWithdrawal sending RISKUSD back to the depositor),
///      re-enters the configured target with the configured calldata.
///      If reentryEnabled is false, behaves as a normal ERC20 (for initial setup).
contract MaliciousRISKUSD is ERC20 {
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public reentryEnabled;

    constructor() ERC20("Malicious RISKUSD", "mRISKUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
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

    /// @dev Override transfer to trigger re-entry after the normal transfer.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);

        if (reentryEnabled && reentryTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = reentryTarget.call(reentryCalldata);
            success; // silence unused variable warning
        }

        return result;
    }

    /// @dev Override transferFrom to trigger re-entry after the normal transfer.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);

        if (reentryEnabled && reentryTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = reentryTarget.call(reentryCalldata);
            success; // silence unused variable warning
        }

        return result;
    }
}
