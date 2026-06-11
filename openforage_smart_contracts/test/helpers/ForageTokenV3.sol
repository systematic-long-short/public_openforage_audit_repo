// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ForageTokenV2.sol";

/// @dev V3 upgrade mock — adds another storage variable and version bump
contract ForageTokenV3 is ForageTokenV2 {
    uint256 private _v3NewVar;

    function version() external pure virtual override returns (uint256) {
        return 3;
    }

    function setV3NewVar(uint256 val) external {
        _v3NewVar = val;
    }

    function getV3NewVar() external view returns (uint256) {
        return _v3NewVar;
    }
}
