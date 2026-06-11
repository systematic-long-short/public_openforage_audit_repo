// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/atRISKUSD.sol";

/// @dev V2 with one additional storage variable appended at end. For upgrade tests.
contract AtRISKUSDV2 is atRISKUSD {
    uint256 public newVariableV2;

    function setNewVariableV2(uint256 val) external {
        newVariableV2 = val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
