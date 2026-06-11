// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

abstract contract AuditSemgrepRuleAssertions is Test {
    function _semgrepRule(string memory semgrep, string memory id) internal pure returns (string memory) {
        string memory marker = string.concat("  - id: ", id);
        bytes memory source = bytes(semgrep);
        bytes memory target = bytes(marker);

        (bool found, uint256 start) = _indexOf(source, target, 0);
        require(found, "semgrep rule missing");

        (bool hasNextRule, uint256 end) = _indexOf(source, bytes("\n  - id: "), start + target.length);
        if (!hasNextRule) {
            end = source.length;
        }

        return _slice(semgrep, start, end);
    }

    function _assertContains(string memory haystack, string memory needle, string memory message) internal pure {
        assertTrue(_contains(haystack, needle), message);
    }

    function _assertNotContains(string memory haystack, string memory needle, string memory message) internal pure {
        assertFalse(_contains(haystack, needle), message);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory source = bytes(haystack);
        bytes memory target = bytes(needle);
        (bool found,) = _indexOf(source, target, 0);
        return found;
    }

    function _indexOf(bytes memory source, bytes memory target, uint256 start)
        private
        pure
        returns (bool found, uint256 index)
    {
        if (target.length == 0) return (true, start);
        if (start >= source.length || target.length > source.length) return (false, 0);

        for (uint256 i = start; i + target.length <= source.length; ++i) {
            bool matched = true;
            for (uint256 j; j < target.length; ++j) {
                if (source[i + j] != target[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return (true, i);
        }

        return (false, 0);
    }

    function _slice(string memory value, uint256 start, uint256 end) private pure returns (string memory) {
        bytes memory source = bytes(value);
        require(end >= start && end <= source.length, "invalid slice");

        bytes memory result = new bytes(end - start);
        for (uint256 i; i < result.length; ++i) {
            result[i] = source[start + i];
        }

        return string(result);
    }
}
