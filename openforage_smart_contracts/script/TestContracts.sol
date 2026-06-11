// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";

/// @dev RISKUSD with zero finalize delay for testnet E2E testing
contract TestRISKUSD is RISKUSD {
    // Override the internal finalize check by providing instant-finalize functions
    function finalizeMinterForTestnet() external onlyOwner {
        address pending = this.pendingMinter();
        require(pending != address(0), "No pending minter");
        // Bypass delay — directly set minter via low-level storage write
        // Storage slot for _minter is determined by the contract layout
        assembly {
            // Clear proposal timestamp so the real finalizeMinter works
            // _minterProposedAt is at a known storage slot
        }
        // Actually just call the parent with a time warp isn't possible on-chain
        // Instead, expose a direct setter for testing only
        _setMinterDirect(pending);
    }

    function _setMinterDirect(address newMinter) internal {
        // Access the namespaced storage directly
        // This is a test-only contract — NOT for production
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("RISKUSD.storage")) - 1)) & ~bytes32(uint256(0xff));
        // minter is at offset 0 in the struct
        assembly {
            sstore(slot, newMinter)
        }
    }
}
