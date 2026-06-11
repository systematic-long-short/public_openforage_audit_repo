// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/ForageGovernor.sol";

/// @dev V2 with one additional storage variable appended at end. For upgrade tests (TC-09).
///      Same inheritance as ForageGovernor. All custom overrides delegate to parent (which reverts
///      "STUB: not implemented" in the stub phase). Adds a version() function returning 2.
contract ForageGovernorV2 is ForageGovernor {
    // Appended storage variable (after all ForageGovernor storage)
    uint256 public newVariableV2;

    function versionV2() external pure returns (uint256) {
        return 2;
    }
}
