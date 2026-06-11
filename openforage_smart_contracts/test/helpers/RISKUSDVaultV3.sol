// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RISKUSDVault.sol";

/// @dev V3 with two additional storage variables. For multi-generation upgrade tests (TC-11).
contract RISKUSDVaultV3 is RISKUSDVault {
    uint256 public newVariableV2;
    uint256 public anotherVariableV3;

    function setAnotherVariableV3(uint256 val) external {
        anotherVariableV3 = val;
    }

    function version() external pure virtual returns (uint256) {
        return 3;
    }
}
