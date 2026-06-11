// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title HyperLiquid legacy transport static regression guard
/// @notice Runs the active-surface source scan from Foundry so transport drift
///         fails alongside the HyperLiquid contract test suite.
contract HLLegacyTransportStaticTest is Test {
    function test_noLegacyTransportIdentifiersInActiveSurface() public {
        string[] memory cmd = new string[](2);
        cmd[0] = "node";
        cmd[1] = "script/check_no_legacy_transport.js";

        string memory output = string(vm.ffi(cmd));
        assertTrue(_contains(output, "NO_LEGACY_TRANSPORT_PASS"), output);
        assertEq(_jsonUint(output, "matches"), 0, output);
        assertGe(_jsonUint(output, "filesScanned"), 40, "static scan scope regressed");
        assertGe(_jsonUint(output, "targetsScanned"), 10, "target list regressed");
        assertGe(_jsonUint(output, "forbiddenPatterns"), 12, "forbidden pattern list regressed");
    }

    function test_staticGuardCoversExpectedSurface() public view {
        string memory checker = vm.readFile("script/check_no_legacy_transport.js");

        assertTrue(_contains(checker, "src"), "production contracts must be scanned");
        assertTrue(_contains(checker, "test/hyperliquid"), "HyperLiquid tests must be scanned");
        assertTrue(_contains(checker, "remappings.txt"), "dependency remappings must be scanned");
        assertTrue(_contains(checker, "documentation/ccip"), "CCIP operations docs must be scanned");
        assertTrue(_contains(checker, "plans/smart_contracts"), "active smart-contract specs must be scanned");
        assertTrue(_contains(checker, "web/src/contracts"), "web contract config must be scanned");
        assertTrue(_contains(checker, "src/contract_keeper_service"), "keeper config must be scanned");
        assertTrue(_contains(checker, "scripts/keeper"), "keeper scripts must be scanned");
        assertTrue(_contains(checker, "LayerZero"), "exact legacy transport names must be forbidden");
        assertTrue(_contains(checker, "LayerZero-v2"), "legacy dependency directory must be forbidden");
        assertTrue(_contains(checker, "lzReceive"), "legacy receive entrypoint must be forbidden");
        assertTrue(_contains(checker, "MessagingParams"), "legacy message structs must be forbidden");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory source = bytes(haystack);
        bytes memory target = bytes(needle);
        if (target.length == 0) return true;
        if (target.length > source.length) return false;
        for (uint256 i = 0; i + target.length <= source.length; ++i) {
            bool matched = true;
            for (uint256 j = 0; j < target.length; ++j) {
                if (source[i + j] != target[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function _jsonUint(string memory json, string memory key) internal pure returns (uint256 value) {
        bytes memory haystack = bytes(json);
        bytes memory needle = bytes(string.concat("\"", key, "\":"));

        for (uint256 i = 0; i + needle.length <= haystack.length; ++i) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (!matched) continue;

            uint256 cursor = i + needle.length;
            while (cursor < haystack.length && haystack[cursor] >= 0x30 && haystack[cursor] <= 0x39) {
                value = value * 10 + uint8(haystack[cursor]) - 48;
                ++cursor;
            }
            return value;
        }

        revert(string.concat("missing JSON key: ", key));
    }
}
