// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDTestBase.sol";
import "./helpers/RISKUSDV2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ============================================================
// TC-10: Attack Vector -- Unauthorized Minting
// ============================================================
contract RISKUSD_TC10_UnauthorizedMint is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
    }

    function test_TC10_randomAddressCannotMint() public {
        address random = makeAddr("random");

        vm.prank(random);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(random, 1_000_000e6);
    }

    function test_TC10_ownerCannotMint() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(owner, 1_000_000e6);
    }

    function test_TC10_oldMinterCannotMintAfterChange() public {
        address oldMinter = minterAddr;
        address newMinter = makeAddr("newMinter");

        // Change minter (propose + delay + finalize)
        vm.startPrank(owner);
        token.setMinter(newMinter);
        vm.warp(block.timestamp + 2 days + 1);
        token.finalizeMinter();
        vm.stopPrank();

        // Old minter should be rejected
        vm.prank(oldMinter);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(alice, 1000e6);

        // New minter should succeed
        vm.prank(newMinter);
        token.mint(alice, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);
    }

    function test_TC10_frontRunSetMinter() public {
        // Scenario: attacker tries to front-run setMinter
        // The attacker cannot call setMinter because it's onlyOwner
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.setMinter(attacker);

        // Minter remains unchanged
        assertEq(token.minter(), minterAddr);
    }
}

// ============================================================
// TC-11: Attack Vector -- Implementation Direct Call and Proxy
// ============================================================
contract RISKUSD_TC11_ImplDirectCall is RISKUSDTestBase {
    function _getImplementationAddress() internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(address(token), slot))));
    }

    function test_TC11_implementationInitReverts() public {
        address implAddr = _getImplementationAddress();
        RISKUSD impl = RISKUSD(implAddr);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    function test_TC11_implementationMintReverts() public {
        address implAddr = _getImplementationAddress();
        RISKUSD impl = RISKUSD(implAddr);

        // Implementation not initialized: minter mapping is empty
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        impl.mint(alice, 100e6);
    }

    function test_TC11_implementationBurnReverts() public {
        address implAddr = _getImplementationAddress();
        RISKUSD impl = RISKUSD(implAddr);

        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        impl.burn(alice, 100e6);
    }

    function test_TC11_unauthorizedUpgradeReverts() public {
        address malicious = makeAddr("maliciousImpl");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.upgradeToAndCall(malicious, "");
    }

    function test_TC11_implementationHasNoBalance() public view {
        address implAddr = _getImplementationAddress();
        assertEq(token.balanceOf(implAddr), 0);
    }

    function test_TC11_noDelegatecallOutsideUUPS() public {
        MaliciousTarget malicious = new MaliciousTarget();

        // The only way to reach delegatecall is through upgradeToAndCall
        // which requires owner. Non-owner attempt reverts:
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.upgradeToAndCall(address(malicious), abi.encodeCall(MaliciousTarget.maliciousInit, ()));
    }

    /// @dev TC-11 sub-case 1.1: Upgrade with append-only storage preserves all state
    function test_TC11_storagePreservedAfterUpgrade() public {
        _setupMinter();
        _setupGovernor();
        _mintTokens(alice, 5000e6);

        // Record pre-upgrade state
        uint256 preBalance = token.balanceOf(alice);
        uint256 preSupply = token.totalSupply();
        address preMinter = token.minter();
        address preGovernor = token.forageGovernor();
        address preOwner = token.owner();

        // Upgrade to V2 (append-only storage - safe)
        RISKUSDV2 v2Impl = new RISKUSDV2();
        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), "");

        // Verify ALL state is preserved (security-critical: minter, governor, owner)
        assertEq(token.balanceOf(alice), preBalance, "Balance corrupted after upgrade");
        assertEq(token.totalSupply(), preSupply, "Supply corrupted after upgrade");
        assertEq(token.minter(), preMinter, "Minter corrupted after upgrade");
        assertEq(token.forageGovernor(), preGovernor, "ForageGovernor corrupted after upgrade");
        assertEq(token.owner(), preOwner, "Owner corrupted after upgrade");
    }

    /// @dev TC-11 sub-case 1.5: Verify no custom delegatecall in contract bytecode
    /// Scans deployed implementation bytecode for DELEGATECALL opcode (0xf4).
    /// Uses opcode-aware walker: skips PUSH1-PUSH32 operand bytes so that
    /// 0xf4 appearing as data (metadata hash, selectors) is not miscounted.
    function test_TC11_noDelegatecallInContractBytecode() public view {
        address implAddr = _getImplementationAddress();
        bytes memory code = implAddr.code;

        // Strip Solidity CBOR metadata trailer: the last two bytes give the metadata
        // length in big-endian; the metadata hash bytes are data, not executable opcodes,
        // and naive byte-walking will misread random 0xf4 bytes in the hash as DELEGATECALL.
        uint256 codeLen = code.length;
        if (codeLen >= 2) {
            uint256 metaLen = (uint256(uint8(code[codeLen - 2])) << 8) | uint256(uint8(code[codeLen - 1]));
            if (metaLen + 2 <= codeLen) {
                codeLen -= metaLen + 2;
            }
        }

        uint256 delegatecallCount = 0;
        uint256 i = 0;
        while (i < codeLen) {
            uint8 op = uint8(code[i]);
            if (op == 0xf4) {
                delegatecallCount++;
                i++;
            } else if (op >= 0x60 && op <= 0x7f) {
                // PUSH1 (0x60) through PUSH32 (0x7f): skip operand bytes
                i += 1 + (op - 0x5f);
            } else {
                i++;
            }
        }

        // OZ v5.6.1 UUPS path generates 2 DELEGATECALL opcodes via ERC1967Utils
        // (Address.functionDelegateCall -> LowLevelCall.delegatecallNoReturn, plus
        // the beacon upgrade path's copy). Any custom delegatecall would exceed this.
        assertLe(delegatecallCount, 2, "Implementation contains more DELEGATECALL opcodes than expected from UUPS");
    }
}

// ============================================================
// R-27: Reentrancy Guard Tests
// Uses vm.store to set the reentrancy guard slot to ENTERED,
// then verifies mint/burn revert with ReentrancyGuardReentrantCall.
// ============================================================
contract RISKUSD_R27_Reentrancy is RISKUSDTestBase {
    // ReentrancyGuard namespaced storage slot (from OZ v5)
    bytes32 constant REENTRANCY_GUARD_SLOT = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    uint256 constant ENTERED = 2;

    function setUp() public override {
        super.setUp();
        _setupMinter();
        _mintTokens(alice, 1000e6);
    }

    function test_R27_mintReentrancyReverts() public {
        // Simulate reentrancy by setting guard to ENTERED state on the proxy
        vm.store(address(token), REENTRANCY_GUARD_SLOT, bytes32(ENTERED));

        vm.prank(minterAddr);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        token.mint(alice, 100e6);
    }

    function test_R27_burnReentrancyReverts() public {
        // Simulate reentrancy by setting guard to ENTERED state on the proxy
        vm.store(address(token), REENTRANCY_GUARD_SLOT, bytes32(ENTERED));

        vm.prank(minterAddr);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        token.burn(alice, 100e6);
    }
}

/// @dev Malicious contract for delegatecall attack testing
contract MaliciousTarget {
    function maliciousInit() external {
        // Would try to corrupt storage if delegatecalled
    }
}
