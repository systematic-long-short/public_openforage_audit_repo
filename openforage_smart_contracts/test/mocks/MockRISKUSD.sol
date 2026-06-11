// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock RISKUSD with mint/burn, call tracking, and configurable pause state.
contract MockRISKUSD is ERC20 {
    bool public mockPaused;

    // Call tracking
    struct MintCall {
        address to;
        uint256 amount;
    }

    struct BurnCall {
        address from;
        uint256 amount;
    }
    MintCall[] public mintCalls;
    BurnCall[] public burnCalls;

    error EnforcedPause();

    constructor() ERC20("RISKUSD", "RISKUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (mockPaused) revert EnforcedPause();
        mintCalls.push(MintCall(to, amount));
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (mockPaused) revert EnforcedPause();
        burnCalls.push(BurnCall(from, amount));
        _burn(from, amount);
    }

    function setMockPaused(bool paused_) external {
        mockPaused = paused_;
    }

    function mintCallCount() external view returns (uint256) {
        return mintCalls.length;
    }

    function burnCallCount() external view returns (uint256) {
        return burnCalls.length;
    }
}
