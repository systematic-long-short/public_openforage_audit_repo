// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ForageTokenV3.sol";

/// @dev V4 upgrade mock — another version bump to test multi-generation upgrades
contract ForageTokenV4 is ForageTokenV3 {
    uint256 private _v4NewVar;

    function version() external pure override returns (uint256) {
        return 4;
    }

    function setV4NewVar(uint256 val) external {
        _v4NewVar = val;
    }

    function getV4NewVar() external view returns (uint256) {
        return _v4NewVar;
    }
}
