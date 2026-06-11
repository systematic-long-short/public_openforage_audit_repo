// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockPausable - Simulates a pausable OpenForage contract
/// @notice Accepts owner (timelock), forageGovernor, or guardianModule for pause/unpause
contract MockPausable {
    address public owner;
    address public forageGovernor;
    address public guardianModule;
    bool public paused;
    address public lastPauseCaller;

    error Unauthorized();

    event Paused(address account);
    event Unpaused(address account);

    constructor(address _owner, address _forageGovernor) {
        owner = _owner;
        forageGovernor = _forageGovernor;
    }

    function setGuardianModule(address _guardianModule) external {
        guardianModule = _guardianModule;
    }

    function pause() external {
        if (msg.sender != owner && msg.sender != forageGovernor && msg.sender != guardianModule) {
            revert Unauthorized();
        }
        paused = true;
        lastPauseCaller = msg.sender;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if (msg.sender != owner && msg.sender != forageGovernor && msg.sender != guardianModule) {
            revert Unauthorized();
        }
        paused = false;
        emit Unpaused(msg.sender);
    }
}
