// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/RISKUSDVault.sol";

/// @dev Malicious ERC-20 that re-enters RISKUSDVault.deposit() during transferFrom.
/// Used for TC-16 Attack 2.1 (deposit reentrancy) tests.
contract ReentrantMockUSDC is ERC20 {
    RISKUSDVault public target;
    bool public shouldReenter;
    uint256 public reenterAmount;

    constructor() ERC20("ReentrantUSDC", "REUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentrancy(address target_, uint256 amount_) external {
        target = RISKUSDVault(target_);
        shouldReenter = true;
        reenterAmount = amount_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (shouldReenter) {
            shouldReenter = false; // prevent infinite loop
            target.deposit(reenterAmount);
        }
        return result;
    }
}
