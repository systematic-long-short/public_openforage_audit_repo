// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/Allowlist.sol";

interface IAllowlistSettable {
    function setAllowlist(address allowlist_) external;
}

/// @dev Deploy and populate the real Allowlist registry for suites and local scripts.
library AllowlistHarness {
    function deploy(address owner_, address guardian_) internal returns (address allowlist) {
        Allowlist implementation = new Allowlist();
        bytes memory initData =
            abi.encodeCall(Allowlist.initialize, (owner_, guardian_, uint64(implementation.FINALIZE_DELAY())));
        allowlist = address(new ERC1967Proxy(address(implementation), initData));
    }

    function setSystemAccounts(address allowlist_, address[] memory accounts) internal {
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert Allowlist.ZeroAddress();
            Allowlist(allowlist_).setSystemAccount(accounts[i], true);
        }
    }

    function approveActors(address allowlist_, address[] memory actors) internal {
        for (uint256 i; i < actors.length; ++i) {
            Allowlist(allowlist_).approveOperator(actors[i]);
        }
    }
}
