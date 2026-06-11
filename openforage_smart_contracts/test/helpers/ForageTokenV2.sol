// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/ForageToken.sol";

/// @dev V2 upgrade mock — adds a version() view and a new storage variable
contract ForageTokenV2 is ForageToken {
    uint256 private _v2NewVar;

    function version() external pure virtual returns (uint256) {
        return 2;
    }

    function setV2NewVar(uint256 val) external {
        _v2NewVar = val;
    }

    function getV2NewVar() external view returns (uint256) {
        return _v2NewVar;
    }
}
