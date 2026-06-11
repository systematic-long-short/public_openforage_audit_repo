// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ForageGovernorV3.sol";

/// @dev V4 upgrade mock for multi-generation upgrade tests (TC-08).
contract ForageGovernorV4 is ForageGovernorV3 {
    function versionV4() external pure returns (uint256) {
        return 4;
    }
}
