// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AtRISKUSDV3.sol";

/// @dev V4 upgrade mock for multi-generation upgrade tests (TC-08).
contract AtRISKUSDV4 is AtRISKUSDV3 {
    function version() external pure override returns (uint256) {
        return 4;
    }
}
