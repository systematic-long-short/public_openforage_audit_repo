// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 that calls back into a target on transfer (for reentrancy testing).
/// When `armed`, the `transfer` function calls `attackTarget.distribute(attackRecipient, attackAmount)`
/// before completing the transfer. If the callback reverts, the revert is propagated,
/// causing the outer transfer (and thus the outer distribute) to also revert.
contract ReentrantToken is ERC20 {
    address public attackTarget;
    address public attackRecipient;
    uint256 public attackAmount;
    bool public armed;

    constructor() ERC20("Reentrant Token", "REENTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, address recipient, uint256 amount) external {
        attackTarget = target;
        attackRecipient = recipient;
        attackAmount = amount;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false; // prevent infinite loop
            // Attempt to reenter distribute() via the attack target
            (bool success, bytes memory returndata) =
                attackTarget.call(abi.encodeWithSignature("distribute(address,uint256)", attackRecipient, attackAmount));
            // Propagate the revert so the outer call also fails
            if (!success) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
        }
        return super.transfer(to, value);
    }
}
