// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAllowlist {
    error CallerNotAllowed(address caller);
    error AllowlistUnavailable();

    function isAllowed(address account) external view returns (bool);

    function allowedUntil(address account) external view returns (uint64);

    function basisOf(address account) external view returns (uint8);

    function isSystemAccount(address account) external view returns (bool);
}
