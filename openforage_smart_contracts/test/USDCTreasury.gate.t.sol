// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/USDCTreasury.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";
import "./mocks/MockUSDC.sol";

contract GateVaultRegistry {
    function getVault(uint256) external pure returns (VaultConfig memory config) {
        config.yieldSplitsBps = [uint16(5_000), uint16(2_500), uint16(1_500), uint16(1_000)];
    }
}

contract GateBlocklist {
    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}

contract USDCTreasury_Gate is Test {
    USDCTreasury internal treasury;
    MockUSDC internal usdc;
    MockAllowlist internal mockAllowlist;

    address internal owner = makeAddr("gate-owner");
    address internal attestor = makeAddr("gate-attestor");
    address internal bridge = makeAddr("gate-bridge");
    address internal foundationPrimary = makeAddr("gate-foundation-primary");
    address internal foundationBackup = makeAddr("gate-foundation-backup");
    address internal protocolPrimary = makeAddr("gate-protocol-primary");
    address internal protocolBackup = makeAddr("gate-protocol-backup");
    uint256 internal vaultId = 1;

    function setUp() public {
        usdc = new MockUSDC();
        USDCTreasury implementation = new USDCTreasury();
        bytes memory initData = abi.encodeCall(
            USDCTreasury.initialize,
            (
                address(usdc),
                makeAddr("gate-riskusd-vault"),
                address(new GateVaultRegistry()),
                owner,
                foundationPrimary,
                foundationBackup,
                protocolPrimary,
                protocolBackup
            )
        );
        treasury = USDCTreasury(address(new ERC1967Proxy(address(implementation), initData)));

        mockAllowlist = new MockAllowlist();
        mockAllowlist.setAllAllowed(true);
        vm.startPrank(owner);
        treasury.setAllowlist(address(mockAllowlist));
        treasury.setPnLAttestor(attestor);
        treasury.setHLTradingBridge(bridge);
        treasury.setBlocklist(address(new GateBlocklist()));
        vm.stopPrank();
    }

    function _fundAgentPay() internal {
        uint256 pnl = 1_000e6;
        vm.prank(attestor);
        treasury.recognizePnL(vaultId, int256(pnl));
        usdc.mint(bridge, 2 * pnl);
        vm.startPrank(bridge);
        usdc.approve(address(treasury), 2 * pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();
    }

    function test_gate_unverifiedDisburseRevertsCallerNotAllowed() public {
        address caller = makeAddr("gate-unverified");
        mockAllowlist.setAllAllowed(false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        treasury.disburse(bytes32(0), address(0), 0);
    }

    function test_gate_disburseSucceedsOnceAllowed() public {
        _fundAgentPay();
        address recipient = makeAddr("gate-agent");
        uint256 amount = 1e6;
        bytes32 agentPay = treasury.EARMARK_AGENT_PAY();
        mockAllowlist.setAllAllowed(true);

        vm.prank(owner);
        treasury.disburse(agentPay, recipient, amount);

        assertEq(usdc.balanceOf(recipient), amount, "an allowed owner disburses once the gate passes");
    }
}
