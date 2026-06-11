// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/ForageGovernor.sol";

/// @title ProposeAndVoteAttacker - Attempts to propose and vote in a single transaction
/// @dev Used by TC-15 to verify that votingDelay prevents atomic propose-and-vote attacks.
///      The attacker contract calls propose() then castVote() in the same transaction.
contract ProposeAndVoteAttacker {
    ForageGovernor public governor;

    constructor(address governor_) {
        governor = ForageGovernor(payable(governor_));
    }

    /// @dev Attempt to propose and immediately vote in one transaction.
    ///      castVote should revert because the proposal is in Pending state
    ///      (votingDelay has not elapsed).
    function proposeAndVote(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description,
        uint8 support
    ) external returns (uint256) {
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        governor.castVote(proposalId, support);
        return proposalId;
    }
}
