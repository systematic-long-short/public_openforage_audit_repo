// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deploy.s.sol";
import "../src/Allowlist.sol";

interface IOwnable2StepTarget {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title DeployMainnet
/// @notice No-broadcast Arbitrum One dry-run path with production governance timings. The broadcast path,
///         which shares this code, is in DeployMainnetBroadcast.s.sol.
contract DeployMainnet is Deploy {
    error WrongMainnetDryRunChain(uint256 chainId);
    error UnexpectedSequencerUptimeFeed(address expected, address actual);

    uint256 public constant MAINNET_CHAIN_ID = 42161;
    address public constant ARBITRUM_ONE_SEQUENCER_UPTIME_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint256 public constant PRODUCTION_MIN_DELAY = 8 days;
    uint256 public constant PRODUCTION_VOTING_DELAY = 1 days;
    uint256 public constant PRODUCTION_VOTING_PERIOD = 5 days;
    uint256 public initialHyperLiquidConfigPreFinalizeTimestamp;
    uint256 public initialHyperLiquidConfigProposedAt;
    uint256 public initialHyperLiquidConfigFinalizedAt;

    function run() public virtual override {
        runDryRunWithPlaceholders();
    }

    function runWithConfig(
        address usdc,
        address beneficiary,
        address foundationPrimary,
        address foundationBackup,
        address protocolPrimary,
        address protocolBackup,
        address launchVotingDelegate,
        address sequencerUptimeFeed
    ) public override {
        _requireMainnetDryRunChain();
        if (sequencerUptimeFeed != ARBITRUM_ONE_SEQUENCER_UPTIME_FEED) {
            revert UnexpectedSequencerUptimeFeed(ARBITRUM_ONE_SEQUENCER_UPTIME_FEED, sequencerUptimeFeed);
        }
        cfgRequireExplicitGuardians = true;
        _requireExplicitGuardianConfig();
        _deployWithConfig(
            DeployConfig({
                usdc: usdc,
                deployer: address(this),
                beneficiary: beneficiary,
                foundationPrimary: foundationPrimary,
                foundationBackup: foundationBackup,
                protocolPrimary: protocolPrimary,
                protocolBackup: protocolBackup,
                launchVotingDelegate: launchVotingDelegate,
                keeper: vm.envAddress("KEEPER_ADDRESS"),
                allowlistRegistrarSigner: vm.envAddress("ALLOWLIST_REGISTRAR_SIGNER"),
                pnlAttestor: vm.envAddress("PNL_ATTESTOR"),
                custodianExecutor: vm.envAddress("CUSTODIAN_EXECUTOR"),
                coldAccount: vm.envAddress("COLD_ACCOUNT_ADDRESS"),
                sequencerUptimeFeed: sequencerUptimeFeed,
                hyperliquidSourceAccount: vm.envBytes32("HYPERLIQUID_SOURCE_ACCOUNT"),
                withdrawalChainSelector: uint64(vm.envUint("WITHDRAWAL_CHAIN_SELECTOR")),
                manifestPath: ""
            }),
            address(this)
        );
        _handoffToProductionGovernance();
    }

    function runDryRunWithPlaceholders() public {
        _requireMainnetDryRunChain();
        cfgRequireExplicitGuardians = false;
        _deployWithConfig(
            DeployConfig({
                usdc: _placeholder(0),
                deployer: address(this),
                beneficiary: _placeholder(1),
                foundationPrimary: _placeholder(2),
                foundationBackup: _placeholder(3),
                protocolPrimary: _placeholder(4),
                protocolBackup: _placeholder(5),
                launchVotingDelegate: _placeholder(6),
                keeper: _placeholder(7),
                allowlistRegistrarSigner: _placeholder(11),
                pnlAttestor: _placeholder(10),
                custodianExecutor: _placeholder(8),
                coldAccount: _placeholder(9),
                sequencerUptimeFeed: ARBITRUM_ONE_SEQUENCER_UPTIME_FEED,
                hyperliquidSourceAccount: bytes32(uint256(uint160(_placeholder(9)))),
                withdrawalChainSelector: uint64(MAINNET_CHAIN_ID),
                manifestPath: ""
            }),
            address(this)
        );
        _handoffToProductionGovernance();
    }

    function _minDelay() internal pure virtual override returns (uint256) {
        return PRODUCTION_MIN_DELAY;
    }

    function _votingDelay() internal pure override returns (uint48) {
        return uint48(PRODUCTION_VOTING_DELAY);
    }

    function _votingPeriod() internal pure override returns (uint32) {
        return uint32(PRODUCTION_VOTING_PERIOD);
    }

    function _timelockOperationDelay() internal pure virtual override returns (uint256) {
        return PRODUCTION_MIN_DELAY;
    }

    function _afterInitialCustodianConfigProposed() internal override {
        if (!cfgBroadcast) _finalizeInitialHyperLiquidCustodianConfig();
    }

    function _requireMainnetDryRunChain() internal view {
        if (block.chainid != MAINNET_CHAIN_ID) {
            revert WrongMainnetDryRunChain(block.chainid);
        }
    }

    function _placeholder(uint256 index) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("OpenForage mainnet dry-run placeholder", index)))));
    }

    function _finalizeInitialHyperLiquidCustodianConfig() internal {
        CustodianRegistry registry = CustodianRegistry(deployedCustodianRegistry);
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        (, uint256 proposedAt) = registry.pendingCustodianConfig(id);
        uint256 readyAt = proposedAt + registry.FINALIZE_DELAY() + 1;
        uint256 expiresAt = proposedAt + registry.PROPOSAL_EXPIRY();
        initialHyperLiquidConfigPreFinalizeTimestamp = block.timestamp;
        if (block.timestamp < readyAt && !cfgBroadcast) {
            vm.warp(readyAt);
        }
        require(block.timestamp <= expiresAt, "initial custodian config expired");
        initialHyperLiquidConfigProposedAt = proposedAt;
        initialHyperLiquidConfigFinalizedAt = block.timestamp;
        _timelockCall(deployedCustodianRegistry, abi.encodeCall(CustodianRegistry.finalizeCustodianConfig, (id)));
    }

    function _afterRiskusdMinterProposed() internal override {
        if (!cfgBroadcast) _finalizeRiskusdMinter();
    }

    function _finalizeRiskusdMinter() internal {
        RISKUSD riskusd = RISKUSD(deployedRiskusd);
        if (riskusd.minter() == deployedRiskusdVault) {
            require(riskusd.pendingMinter() == address(0), "riskusd pending minter remains");
            return;
        }

        require(riskusd.pendingMinter() == deployedRiskusdVault, "riskusd vault minter not pending");
        if (!cfgBroadcast) vm.warp(block.timestamp + riskusd.FINALIZE_DELAY() + 1);
        riskusd.finalizeMinter();
        require(riskusd.minter() == deployedRiskusdVault, "riskusd vault minter not finalized");
        require(riskusd.pendingMinter() == address(0), "riskusd pending minter remains");
    }

    function _handoffToProductionGovernance() internal {
        _finalizeAllowlistRegistrars();
        _transferProductionOwnerships();
        Allowlist(deployedAllowlist).setSystemAccount(address(this), false);
        _transferOwnershipThroughTimelock(deployedAllowlist);
        _revokeDeployerTimelockRoles();
    }

    /// @notice Every contract the deployer owns until the handoff except the Allowlist, which moves last.
    function _productionOwnedContracts() internal view returns (address[13] memory) {
        return [
            deployedBlocklist,
            deployedFORAGETreasury,
            deployedForageToken,
            deployedRiskusd,
            deployedRiskusdVault,
            deployedVaultRegistry,
            deployedAtRiskTier0,
            deployedAtRiskTier1,
            deployedAtRiskTier2,
            deployedAtRiskTier3,
            deployedStakingQueue,
            deployedUSDCTreasury,
            deployedHLTradingBridge
        ];
    }

    function _transferProductionOwnerships() internal {
        address[13] memory targets = _productionOwnedContracts();
        for (uint256 i; i < targets.length;) {
            _transferOwnershipThroughTimelock(targets[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice OPEN-337: the deployer finalises the Allowlist's registrar and system registrar while it still owns
    ///         and is allowed by the Allowlist. Proposals that are not yet ready or have expired are made again
    ///         and finalised after the Allowlist's finalize delay; on mainnet the handoff waits for that delay.
    function _finalizeAllowlistRegistrars() internal {
        Allowlist registry = Allowlist(deployedAllowlist);
        try registry.finalizeRegistrar() {
            registry.finalizeSystemRegistrar();
        } catch {
            registry.proposeRegistrar(deployedAllowlistRegistrar);
            registry.proposeSystemRegistrar(deployedFORAGETreasury, true);
            vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
            registry.finalizeRegistrar();
            registry.finalizeSystemRegistrar();
        }
        require(registry.registrar() == deployedAllowlistRegistrar, "allowlist registrar not finalized");
        require(registry.isSystemRegistrar(deployedFORAGETreasury), "allowlist system registrar not finalized");
    }

    function _transferOwnershipThroughTimelock(address target) internal {
        if (IOwnable2StepTarget(target).owner() == deployedTimelock) return;
        IOwnable2StepTarget(target).transferOwnership(deployedTimelock);
        _timelockCall(target, abi.encodeCall(IOwnable2StepTarget.acceptOwnership, ()));
    }

    function _revokeDeployerTimelockRoles() internal {
        TimelockController timelock = TimelockController(payable(deployedTimelock));
        timelock.revokeRole(PROPOSER_ROLE, address(this));
        timelock.revokeRole(CANCELLER_ROLE, address(this));
        timelock.revokeRole(EXECUTOR_ROLE, address(this));
        timelock.revokeRole(bytes32(0), address(this));
    }
}
