// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IForageVotes {
    function delegate(address delegatee) external;
    function delegates(address account) external view returns (address);
}
