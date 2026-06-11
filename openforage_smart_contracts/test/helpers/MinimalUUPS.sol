// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @dev Minimal UUPS contract with no custom logic — used as a DELEGATECALL baseline.
contract MinimalUUPS is OwnableUpgradeable, UUPSUpgradeable {
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
