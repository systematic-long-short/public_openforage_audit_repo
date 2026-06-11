// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/ForageGovernor.sol";

/// @dev V3 with two additional storage variables appended at end. For upgrade-after-upgrade tests (TC-09).
///      Same inheritance as ForageGovernor. Adds a version() function returning 3.
contract ForageGovernorV3 is ForageGovernor {
    // Appended storage variables (after all ForageGovernor storage)
    uint256 public newVariableV2;
    uint256 public anotherVariableV3;

    function versionV3() external pure returns (uint256) {
        return 3;
    }
}
