// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RISKUSD.sol";

contract RISKUSDV2 is RISKUSD {
    uint256 public newVariable;

    function setNewVariable(uint256 val) external {
        newVariable = val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
