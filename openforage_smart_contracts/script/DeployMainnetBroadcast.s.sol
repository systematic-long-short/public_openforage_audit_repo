// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployMainnet.s.sol";

/// @title DeployBroadcastBase
/// @notice Shared by the two broadcast phases. Each broadcast is signed by the deployer's own wallet: the key in
///         DEPLOYER_PRIVATE_KEY or, when it is unset, the wallet forge was given, such as `--ledger --sender`. The
///         Timelock starts at zero delay, so set-up through it needs no eight-day waits; CompleteDeploy raises the
///         delay to PRODUCTION_MIN_DELAY as its last Timelock operation and then revokes every deployer role.
abstract contract DeployBroadcastBase is DeployMainnet {
    function _minDelay() internal pure override returns (uint256) {
        return 0;
    }

    function _timelockOperationDelay() internal pure override returns (uint256) {
        return 0;
    }

    function _startDeployerBroadcast() internal returns (address deployer) {
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        deployer = deployerKey == 0 ? msg.sender : vm.addr(deployerKey);
        if (deployerKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerKey);
        }
    }
}

/// @title DeployMainnetBroadcast
/// @notice Phase 1 of the Arbitrum One deployment: deploys and wires the stack and proposes every setting that waits
///         for the two-day finalize delay. The deployer keeps its ownership and its Timelock roles. After the delay
///         the operator runs RegisterAllowlist, the distributor accepts both treasuries, and CompleteDeploy finishes.
contract DeployMainnetBroadcast is DeployBroadcastBase {
    function run() public override {
        _requireMainnetDryRunChain();
        _requireExpectedDeployChain();
        cfgRequireExplicitGuardians = true;
        cfgBroadcast = true;
        _requireExplicitGuardianConfig();
        address sequencerUptimeFeed = vm.envAddress("SEQUENCER_UPTIME_FEED");
        if (sequencerUptimeFeed != ARBITRUM_ONE_SEQUENCER_UPTIME_FEED) {
            revert UnexpectedSequencerUptimeFeed(ARBITRUM_ONE_SEQUENCER_UPTIME_FEED, sequencerUptimeFeed);
        }
        address deployer = _startDeployerBroadcast();
        DeployConfig memory cfg = DeployConfig({
            usdc: vm.envAddress("USDC_ADDRESS"),
            deployer: deployer,
            beneficiary: vm.envAddress("BENEFICIARY"),
            foundationPrimary: vm.envAddress("FOUNDATION_PRIMARY"),
            foundationBackup: vm.envAddress("FOUNDATION_BACKUP"),
            protocolPrimary: vm.envAddress("PROTOCOL_PRIMARY"),
            protocolBackup: vm.envAddress("PROTOCOL_BACKUP"),
            launchVotingDelegate: vm.envAddress("LAUNCH_VOTING_DELEGATE"),
            keeper: vm.envAddress("KEEPER_ADDRESS"),
            allowlistRegistrarSigner: vm.envAddress("ALLOWLIST_REGISTRAR_SIGNER"),
            pnlAttestor: vm.envAddress("PNL_ATTESTOR"),
            custodianExecutor: vm.envAddress("CUSTODIAN_EXECUTOR"),
            coldAccount: vm.envAddress("COLD_ACCOUNT_ADDRESS"),
            sequencerUptimeFeed: sequencerUptimeFeed,
            hyperliquidSourceAccount: vm.envBytes32("HYPERLIQUID_SOURCE_ACCOUNT"),
            withdrawalChainSelector: uint64(vm.envUint("WITHDRAWAL_CHAIN_SELECTOR")),
            manifestPath: vm.envString("DEPLOYMENT_MANIFEST_PATH")
        });
        _deployWithConfig(cfg, deployer);
        vm.stopBroadcast();
    }
}

/// @title CompleteDeploy
/// @notice Phase 2 on every chain, after the finalize delay (ten minutes on the test chains, two days on Arbitrum
///         One). It finalizes the ForageGovernor pause controls the broadcast proposed. On Arbitrum One it then
///         finalizes the RISKUSD minter and the HyperLiquid custodian config, refuses to go on until RegisterAllowlist
///         has run and the distributor has accepted both treasuries (OPEN-455, OPEN-572), hands every contract to the
///         Timelock, raises the Timelock delay to PRODUCTION_MIN_DELAY and revokes the deployer's roles. Every step
///         reads current state first, so a second run sends only what is left.
contract CompleteDeploy is DeployBroadcastBase {
    error ManifestChainMismatch(uint256 manifestChainId, uint256 chainId);
    error PreHandoffStepMissing(string step, address account);
    error HandoffIncomplete(string check, address account);

    bytes4 private constant NO_PENDING_CUSTODIAN_CONFIG = bytes4(keccak256("NoPendingCustodianConfig(bytes32)"));

    function run() public override {
        _requireExpectedDeployChain();
        cfgRequireExplicitGuardians = true;
        cfgBroadcast = true;
        _loadDeployment(vm.envString("DEPLOYMENT_MANIFEST_PATH"));
        address deployer = _startDeployerBroadcast();
        _finalizeForageGovernorPauseControls();
        if (block.chainid == MAINNET_CHAIN_ID) {
            _finalizeRiskusdMinter();
            if (_initialCustodianConfigPending()) _finalizeInitialHyperLiquidCustodianConfig();
            _requireRegisterAllowlistComplete();
            _handoffFromDeployer(deployer);
        }
        vm.stopBroadcast();
        if (block.chainid == MAINNET_CHAIN_ID) _requireProductionHandoff(deployer);
    }

    function _loadDeployment(string memory manifestPath) internal {
        string memory manifest = vm.readFile(manifestPath);
        uint256 manifestChainId = vm.parseJsonUint(manifest, ".chainId");
        if (manifestChainId != block.chainid) revert ManifestChainMismatch(manifestChainId, block.chainid);
        deployedAllowlist = vm.parseJsonAddress(manifest, ".allowlist");
        deployedAllowlistRegistrar = vm.parseJsonAddress(manifest, ".allowlistRegistrar");
        deployedBlocklist = vm.parseJsonAddress(manifest, ".blocklist");
        deployedCustodianRegistry = vm.parseJsonAddress(manifest, ".custodianRegistry");
        deployedRiskusd = vm.parseJsonAddress(manifest, ".riskusd");
        deployedRiskusdVault = vm.parseJsonAddress(manifest, ".riskusdVault");
        deployedVaultRegistry = vm.parseJsonAddress(manifest, ".vaultRegistry");
        deployedUSDCTreasury = vm.parseJsonAddress(manifest, ".usdcTreasury");
        deployedForageToken = vm.parseJsonAddress(manifest, ".forageToken");
        deployedFORAGETreasury = vm.parseJsonAddress(manifest, ".forageTreasury");
        deployedForageGovernor = vm.parseJsonAddress(manifest, ".forageGovernor");
        deployedTimelock = vm.parseJsonAddress(manifest, ".timelockController");
        deployedHLTradingBridge = vm.parseJsonAddress(manifest, ".hlTradingBridge");
        deployedStakingQueue = vm.parseJsonAddress(manifest, ".stakingQueue");
        deployedAtRiskTier0 = vm.parseJsonAddress(manifest, ".atRiskusdTier0");
        deployedAtRiskTier1 = vm.parseJsonAddress(manifest, ".atRiskusdTier1");
        deployedAtRiskTier2 = vm.parseJsonAddress(manifest, ".atRiskusdTier2");
        deployedAtRiskTier3 = vm.parseJsonAddress(manifest, ".atRiskusdTier3");
    }

    // Any reason other than "nothing pending" counts as pending, so the finalize that follows reverts with it. With
    // nothing pending, getCustodian reverts unless the config was finalized.
    function _initialCustodianConfigPending() internal view returns (bool) {
        CustodianRegistry registry = CustodianRegistry(deployedCustodianRegistry);
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        try registry.pendingCustodianConfig(id) returns (
            CustodianRegistry.CustodianConfig memory config, uint256 proposedAt
        ) {
            return proposedAt != 0 && config.id == id;
        } catch (bytes memory reason) {
            if (reason.length < 4 || bytes4(reason) != NO_PENDING_CUSTODIAN_CONFIG) return true;
        }
        return !registry.getCustodian(id).exists;
    }

    /// @dev OPEN-455, OPEN-572: RegisterAllowlist needs the deployer as owner, so its whole result must be in place
    ///      before the Allowlist and both treasuries pass to governance.
    function _requireRegisterAllowlistComplete() internal view {
        Allowlist registry = Allowlist(deployedAllowlist);
        address distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");
        address launchVotingDelegate = vm.envAddress("LAUNCH_VOTING_DELEGATE");
        if (registry.registrar() != deployedAllowlistRegistrar) {
            revert PreHandoffStepMissing("finalizeRegistrar", deployedAllowlistRegistrar);
        }
        if (!registry.isSystemRegistrar(deployedFORAGETreasury)) {
            revert PreHandoffStepMissing("finalizeSystemRegistrar", deployedFORAGETreasury);
        }
        if (!registry.isSystemAccount(distributor)) revert PreHandoffStepMissing("setSystemAccount", distributor);
        if (!registry.isSystemAccount(launchVotingDelegate)) {
            revert PreHandoffStepMissing("setSystemAccount", launchVotingDelegate);
        }
        address[] memory guardians = _guardianAddresses(address(0));
        for (uint256 i; i < guardians.length;) {
            _requireOperatorApproved(registry, guardians[i]);
            unchecked {
                ++i;
            }
        }
        _requireOperatorApproved(registry, vm.envAddress("CUSTODIAN_EXECUTOR"));
        _requireOperatorApproved(registry, launchVotingDelegate);
        if (FORAGETreasury(deployedFORAGETreasury).distributor() != distributor) {
            revert PreHandoffStepMissing("acceptDistributor", deployedFORAGETreasury);
        }
        if (USDCTreasury(deployedUSDCTreasury).distributor() != distributor) {
            revert PreHandoffStepMissing("acceptDistributor", deployedUSDCTreasury);
        }
    }

    function _requireOperatorApproved(Allowlist registry, address account) internal view {
        if (registry.allowedUntil(account) != type(uint64).max) {
            revert PreHandoffStepMissing("approveOperator", account);
        }
    }

    function _handoffFromDeployer(address deployer) internal {
        _transferProductionOwnerships();
        Allowlist registry = Allowlist(deployedAllowlist);
        if (registry.isSystemAccount(deployer)) registry.setSystemAccount(deployer, false);
        _transferOwnershipThroughTimelock(deployedAllowlist);
        TimelockController timelock = TimelockController(payable(deployedTimelock));
        if (timelock.getMinDelay() != PRODUCTION_MIN_DELAY) {
            _timelockCall(deployedTimelock, abi.encodeCall(TimelockController.updateDelay, (PRODUCTION_MIN_DELAY)));
        }
        // The default admin role is revoked last, so a deployer still holding it may hold others.
        if (timelock.hasRole(bytes32(0), deployer)) _revokeDeployerOperationalRoles(deployer);
    }

    function _requireProductionHandoff(address deployer) internal view {
        TimelockController timelock = TimelockController(payable(deployedTimelock));
        if (timelock.getMinDelay() != PRODUCTION_MIN_DELAY) revert HandoffIncomplete("timelockDelay", deployedTimelock);
        if (
            timelock.hasRole(PROPOSER_ROLE, deployer) || timelock.hasRole(CANCELLER_ROLE, deployer)
                || timelock.hasRole(EXECUTOR_ROLE, deployer) || timelock.hasRole(bytes32(0), deployer)
        ) {
            revert HandoffIncomplete("deployerRole", deployer);
        }
        if (
            !timelock.hasRole(PROPOSER_ROLE, deployedForageGovernor)
                || !timelock.hasRole(CANCELLER_ROLE, deployedForageGovernor)
                || !timelock.hasRole(EXECUTOR_ROLE, deployedForageGovernor)
        ) {
            revert HandoffIncomplete("governorRole", deployedForageGovernor);
        }
        address[13] memory owned = _productionOwnedContracts();
        for (uint256 i; i < owned.length;) {
            if (IOwnable2StepTarget(owned[i]).owner() != deployedTimelock) revert HandoffIncomplete("owner", owned[i]);
            unchecked {
                ++i;
            }
        }
        if (IOwnable2StepTarget(deployedAllowlist).owner() != deployedTimelock) {
            revert HandoffIncomplete("owner", deployedAllowlist);
        }
        if (Allowlist(deployedAllowlist).isSystemAccount(deployer)) {
            revert HandoffIncomplete("deployerSystemAccount", deployer);
        }
    }
}
