// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/GuardianModule.sol";

/// @dev V2 mock for GuardianModule upgrade tests (OF-031).
/// Minimal contract that inherits GuardianModule to enable UUPS upgradeToAndCall.
contract GuardianModuleV2 is GuardianModule {
    uint256 public newVariableV2;

    function version() external pure returns (uint256) {
        return 2;
    }
}
