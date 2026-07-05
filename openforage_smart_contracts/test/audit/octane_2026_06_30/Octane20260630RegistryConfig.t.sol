// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/CustodianRegistry.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/RISKUSDVault.sol";
import "../../../src/VaultRegistry.sol";

contract Octane20260630RegistryConfigPublicAudit001Test is Test {
    address private owner = makeAddr("reg-exp-owner");
    address private governor = makeAddr("reg-exp-governor");
    address private guardian = makeAddr("reg-exp-guardian");
    address private usdc = makeAddr("reg-exp-usdc");
    address private riskusd = makeAddr("reg-exp-riskusd");

    function test_REGEXP_freshVaultAndRegistryReplacementHasNoDelayedFinalizerFirstMover() public {
        RISKUSDVault oldVault = _deployVault();
        VaultRegistry oldRegistry = _deployVaultRegistry();
        _wireVaultRegistryPair(oldVault, oldRegistry);

        RISKUSDVault freshVault = _deployVault();
        VaultRegistry freshRegistry = _deployVaultRegistry();
        _wireVaultRegistryPair(freshVault, freshRegistry);

        vm.startPrank(owner);
        oldRegistry.proposeRISKUSDVault(address(freshVault));
        oldVault.proposeVaultRegistry(address(freshRegistry));
        freshVault.proposeVaultRegistry(address(oldRegistry));
        vm.stopPrank();

        vm.warp(block.timestamp + oldRegistry.FINALIZE_DELAY() + 1);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.VaultRegistryMismatch.selector);
        oldRegistry.finalizeRISKUSDVault();

        vm.prank(owner);
        vm.expectRevert(RISKUSDVault.RISKUSDVaultMismatch.selector);
        oldVault.finalizeVaultRegistry();

        vm.prank(owner);
        vm.expectRevert(RISKUSDVault.RISKUSDVaultMismatch.selector);
        freshVault.finalizeVaultRegistry();

        assertEq(oldRegistry.riskusdVault(), address(oldVault), "old registry remains on old vault");
        assertEq(oldVault.vaultRegistry(), address(oldRegistry), "old vault remains on old registry");
        assertEq(freshRegistry.riskusdVault(), address(freshVault), "fresh registry remains on fresh vault");
        assertEq(freshVault.vaultRegistry(), address(freshRegistry), "fresh vault remains on fresh registry");
    }

    function test_REGEXP_staleCustodianRoleAndPeerFinalizeAfterConfigReplacementAndReachAccounting() public {
        CustodianRegistry registry = _deployCustodianRegistry();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        bytes32 accountantRole = registry.ROLE_ACCOUNTANT();
        bytes32 executorRole = registry.ROLE_EXECUTOR();
        address bridgeA = makeAddr("reg-exp-bridge-a");
        address executorA = makeAddr("reg-exp-executor-a");
        bytes32 peerA = bytes32(uint256(0xA11CE));
        address bridgeB = makeAddr("reg-exp-bridge-b");
        address executorB = makeAddr("reg-exp-executor-b");
        bytes32 peerB = bytes32(uint256(0xB0B));
        address staleAccountant = makeAddr("reg-exp-stale-accountant");
        address staleExecutor = makeAddr("reg-exp-stale-executor");
        bytes32 stalePeer = bytes32(uint256(0x57A1E));

        _finalizeCustodianConfig(registry, _custodianConfig(registry, bridgeA, executorA, peerA));

        vm.startPrank(owner);
        registry.proposeCustodianRole(id, accountantRole, staleAccountant);
        registry.proposeCustodianRole(id, executorRole, staleExecutor);
        registry.proposeAllowedPeer(id, stalePeer);
        registry.proposeCustodianConfig(_custodianConfig(registry, bridgeB, executorB, peerB));
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianConfig(id);

        assertFalse(registry.hasCustodianRole(id, accountantRole, bridgeA), "old bridge accountant is revoked");
        assertFalse(registry.hasCustodianRole(id, executorRole, executorA), "old executor is revoked");
        assertTrue(registry.hasCustodianRole(id, accountantRole, bridgeB), "new bridge accountant is live");
        assertTrue(registry.hasCustodianRole(id, executorRole, executorB), "new executor is live");
        assertTrue(registry.isAllowedPeer(id, peerB), "new config peer is live");
        assertFalse(registry.hasCustodianRole(id, accountantRole, staleAccountant), "stale accountant not live yet");
        assertFalse(registry.hasCustodianRole(id, executorRole, staleExecutor), "stale executor not live yet");
        assertFalse(registry.isAllowedPeer(id, stalePeer), "stale peer not live yet");

        registry.finalizeCustodianRole(id, accountantRole, staleAccountant);
        registry.finalizeCustodianRole(id, executorRole, staleExecutor);
        registry.finalizeAllowedPeer(id, stalePeer);
        vm.stopPrank();

        assertTrue(registry.hasCustodianRole(id, accountantRole, staleAccountant), "stale accountant becomes live");
        assertTrue(registry.hasCustodianRole(id, executorRole, staleExecutor), "stale executor becomes live");
        assertTrue(registry.isAllowedPeer(id, stalePeer), "stale peer becomes live");

        vm.prank(staleAccountant);
        registry.recordDeployment(id, 100e6);

        assertEq(registry.deployedByCustodian(id), 100e6, "stale accountant reaches accounting sink");
        assertEq(registry.totalDeployed(), 100e6, "stale accountant changes aggregate accounting");
    }

    function test_REGEXP_unsetRiskusdBlocklistPermitsMintAndMissingPauseExemptionBlocksExit() public {
        RISKUSD token = _deployRiskUSD();
        address protocolSender = makeAddr("reg-exp-protocol-sender");
        address recipient = makeAddr("reg-exp-recipient");

        vm.startPrank(owner);
        token.setMinter(address(this));
        vm.warp(block.timestamp + token.FINALIZE_DELAY() + 1);
        token.finalizeMinter();
        vm.stopPrank();

        assertEq(token.blocklist(), address(0), "blocklist starts unset");
        token.mint(protocolSender, 10e6);
        assertEq(token.balanceOf(protocolSender), 10e6, "unset blocklist permits mint");

        vm.prank(owner);
        token.pause();

        vm.prank(protocolSender);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        token.transfer(recipient, 1e6);

        vm.prank(owner);
        token.setTransferExempt(protocolSender, true);

        vm.prank(protocolSender);
        token.transfer(recipient, 1e6);

        assertTrue(token.isTransferExempt(protocolSender), "protocol sender exemption is seeded");
        assertEq(token.balanceOf(recipient), 1e6, "exempt protocol sender can exit while paused");
    }

    function _deployVault() private returns (RISKUSDVault vault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (usdc, riskusd, owner));
        vault = RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRiskUSD() private returns (RISKUSD token) {
        RISKUSD implementation = new RISKUSD();
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (owner));
        token = RISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployVaultRegistry() private returns (VaultRegistry registry) {
        VaultRegistry implementation = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (owner));
        registry = VaultRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _wireVaultRegistryPair(RISKUSDVault vault, VaultRegistry registry) private {
        vm.prank(owner);
        registry.initializeV2(address(vault));
        vm.prank(owner);
        vault.initializeV2(address(registry));

        assertTrue(registry.verifyWiring(), "pair must start reciprocally wired");
        assertEq(vault.vaultRegistry(), address(registry), "vault points at registry");
        assertEq(registry.riskusdVault(), address(vault), "registry points at vault");
    }

    function _deployCustodianRegistry() private returns (CustodianRegistry registry) {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, governor, guardian));
        registry = CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _custodianConfig(CustodianRegistry registry, address bridge, address executor, bytes32 peer)
        private
        pure
        returns (CustodianRegistry.CustodianConfig memory)
    {
        return registry.hyperLiquidLaunchConfig(bridge, executor, 10_001, peer, 10_000_000e6);
    }

    function _finalizeCustodianConfig(
        CustodianRegistry registry,
        CustodianRegistry.CustodianConfig memory config
    ) private {
        vm.startPrank(owner);
        registry.proposeCustodianConfig(config);
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianConfig(config.id);
        vm.stopPrank();
    }
}
