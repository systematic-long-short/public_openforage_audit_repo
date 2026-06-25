// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBlocklist {
    function isBlocked(address account) external view returns (bool);

    function wasBlockedAt(address account, uint256 timepoint) external view returns (bool);
}
