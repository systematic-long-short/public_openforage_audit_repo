// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deploy.s.sol";

interface IOwnable2StepTarget {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title DeployMainnet
/// @notice No-broadcast Arbitrum One dry-run path with production governance timings.
contract DeployMainnet is Deploy {
    error WrongMainnetDryRunChain(uint256 chainId);

    uint256 public constant MAINNET_CHAIN_ID = 42161;
    uint256 public constant PRODUCTION_MIN_DELAY = 8 days;
    uint256 public constant PRODUCTION_VOTING_DELAY = 1 days;
    uint256 public constant PRODUCTION_VOTING_PERIOD = 5 days;
    uint256 public initialHyperLiquidConfigPreFinalizeTimestamp;
    uint256 public initialHyperLiquidConfigProposedAt;
    uint256 public initialHyperLiquidConfigFinalizedAt;

    function run() public override {
        runDryRunWithPlaceholders();
    }

    function runWithConfig(
        address usdc,
        address beneficiary,
        address foundationPrimary,
        address foundationBackup,
        address protocolPrimary,
        address protocolBackup,
        address launchVotingDelegate
    ) public override {
        _requireMainnetDryRunChain();
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
                custodianExecutor: vm.envAddress("CUSTODIAN_EXECUTOR"),
                coldAccount: vm.envAddress("COLD_ACCOUNT_ADDRESS"),
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
                custodianExecutor: _placeholder(8),
                coldAccount: _placeholder(9),
                hyperliquidSourceAccount: bytes32(uint256(uint160(_placeholder(9)))),
                withdrawalChainSelector: uint64(MAINNET_CHAIN_ID),
                manifestPath: ""
            }),
            address(this)
        );
        _handoffToProductionGovernance();
    }

    function _minDelay() internal pure override returns (uint256) {
        return PRODUCTION_MIN_DELAY;
    }

    function _votingDelay() internal pure override returns (uint48) {
        return uint48(PRODUCTION_VOTING_DELAY);
    }

    function _votingPeriod() internal pure override returns (uint32) {
        return uint32(PRODUCTION_VOTING_PERIOD);
    }

    function _timelockOperationDelay() internal pure override returns (uint256) {
        return PRODUCTION_MIN_DELAY;
    }

    function _afterInitialCustodianConfigProposed() internal override {
        _finalizeInitialHyperLiquidCustodianConfig();
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
        if (block.timestamp < readyAt) {
            vm.warp(readyAt);
        }
        require(block.timestamp <= expiresAt, "initial custodian config expired");
        initialHyperLiquidConfigProposedAt = proposedAt;
        initialHyperLiquidConfigFinalizedAt = block.timestamp;
        registry.finalizeCustodianConfig(id);
    }

    function _handoffToProductionGovernance() internal {
        _transferOwnershipThroughTimelock(deployedBlocklist);
        _transferOwnershipThroughTimelock(deployedCustodianRegistry);
        _transferOwnershipThroughTimelock(deployedFORAGETreasury);
        _transferOwnershipThroughTimelock(deployedForageToken);
        _transferOwnershipThroughTimelock(deployedRiskusd);
        _transferOwnershipThroughTimelock(deployedRiskusdVault);
        _transferOwnershipThroughTimelock(deployedVaultRegistry);
        _transferOwnershipThroughTimelock(deployedAtRiskTier0);
        _transferOwnershipThroughTimelock(deployedAtRiskTier1);
        _transferOwnershipThroughTimelock(deployedAtRiskTier2);
        _transferOwnershipThroughTimelock(deployedAtRiskTier3);
        _transferOwnershipThroughTimelock(deployedStakingQueue);
        _transferOwnershipThroughTimelock(deployedUSDCTreasury);
        _transferOwnershipThroughTimelock(deployedHLTradingBridge);
        _revokeDeployerTimelockRoles();
    }

    function _transferOwnershipThroughTimelock(address target) internal {
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
