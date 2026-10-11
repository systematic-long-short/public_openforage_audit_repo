// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAllowlistSystemRegistrar {
    function setSystemAccount(address account, bool isSystem) external;

    function isSystemRegistrar(address account) external view returns (bool);
}
