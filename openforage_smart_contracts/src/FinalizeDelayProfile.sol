// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FinalizeDelayProfile
/// @notice Shared effective delay for two-step trust-boundary finalizers.
/// @dev Constants add no proxy storage. Test chains are intentionally fast for wet proof;
///      every other chain keeps the production delay.
abstract contract FinalizeDelayProfile {
    uint256 internal constant _PRODUCTION_FINALIZE_DELAY = 2 days;
    uint256 internal constant _TESTNET_FINALIZE_DELAY = 10 minutes;
    uint256 internal constant _LOCAL_CHAIN_ID = 31337;
    uint256 internal constant _ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    function FINALIZE_DELAY() public view returns (uint256) {
        return _finalizeDelay();
    }

    function _finalizeDelay() internal view returns (uint256) {
        if (block.chainid == _LOCAL_CHAIN_ID || block.chainid == _ARBITRUM_SEPOLIA_CHAIN_ID) {
            return _TESTNET_FINALIZE_DELAY;
        }
        return _PRODUCTION_FINALIZE_DELAY;
    }
}
