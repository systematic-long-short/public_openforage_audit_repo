// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Allowlist} from "../../src/Allowlist.sol";
import {AllowlistHarness} from "./AllowlistHarness.sol";

/// @dev One-call base that deploys, registers and approves the real Allowlist for a suite.
abstract contract AllowlistTestBase {
    Allowlist internal allowlist;

    function deployAllowlistHarness(address[] memory systemAccounts, address[] memory actors)
        internal
        returns (Allowlist deployed)
    {
        address registry = AllowlistHarness.deploy(address(this), address(this));
        AllowlistHarness.setSystemAccounts(registry, systemAccounts);
        AllowlistHarness.approveActors(registry, actors);
        deployed = Allowlist(registry);
        allowlist = deployed;
    }
}
