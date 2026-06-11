// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RISKUSD.sol";

contract RISKUSDV3 is RISKUSD {
    uint256 public newVariable;
    uint256 public anotherVariable;

    function setAnotherVariable(uint256 val) external {
        anotherVariable = val;
    }

    function version() external pure virtual returns (uint256) {
        return 3;
    }
}
