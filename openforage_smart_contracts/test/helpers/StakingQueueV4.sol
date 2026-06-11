// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakingQueueV3.sol";

/// @dev V4 upgrade mock for multi-generation upgrade tests (TC-08).
contract StakingQueueV4 is StakingQueueV3 {
    function version() external pure override returns (uint256) {
        return 4;
    }
}
