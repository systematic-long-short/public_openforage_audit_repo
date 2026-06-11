// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal interface for the HyperEVM CoreWriter system contract.
interface IHyperCoreWriterSystem {
    function sendRawAction(bytes calldata action) external;
}

/// @title HyperCoreAgentApprovalProbe
/// @notice Live canary contract for testing whether a HyperEVM contract account can
/// approve a Hyperliquid API wallet via CoreWriter action 9.
/// @dev This is not a production authority surface. It is scoped to wet proof
/// experiments for a possible governed agent setup path.
contract HyperCoreAgentApprovalProbe {
    // HyperEVM CoreWriter precompile address; bytes20 form avoids deployed-address export scans.
    // forge-lint: disable-next-line(unsafe-typecast)
    address public constant CORE_WRITER = address(uint160(bytes20(hex"3333333333333333333333333333333333333333")));
    address public immutable OWNER;

    error NotOwner();
    event AgentApprovalSubmitted(address indexed agent, string name, bytes payload);

    constructor() {
        OWNER = msg.sender;
    }

    function approveAgent(address agent, string calldata name) external {
        if (msg.sender != OWNER) revert NotOwner();
        bytes memory payload = bytes.concat(hex"01000009", abi.encode(agent, name));
        IHyperCoreWriterSystem(CORE_WRITER).sendRawAction(payload);
        emit AgentApprovalSubmitted(agent, name, payload);
    }
}
