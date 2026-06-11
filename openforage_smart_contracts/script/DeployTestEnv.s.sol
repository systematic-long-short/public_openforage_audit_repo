// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../test/mocks/MockUSDC.sol";
import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Deploy a test environment with MockUSDC for E2E testing on Sepolia
contract DeployTestEnv is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Use existing MockUSDC if set, otherwise deploy new
        address mockUsdc = vm.envOr("MOCK_USDC", address(0));

        vm.startBroadcast(deployerKey);

        if (mockUsdc == address(0)) {
            MockUSDC usdc = new MockUSDC();
            mockUsdc = address(usdc);
            MockUSDC(mockUsdc).mint(deployer, 100_000e6);
        }

        // Deploy RISKUSD
        RISKUSD riskusdImpl = new RISKUSD();
        bytes memory riskusdInit = abi.encodeCall(RISKUSD.initialize, (deployer));
        ERC1967Proxy riskusdProxy = new ERC1967Proxy(address(riskusdImpl), riskusdInit);
        address riskusd = address(riskusdProxy);

        // Deploy RISKUSDVault
        RISKUSDVault vaultImpl = new RISKUSDVault();
        bytes memory vaultInit = abi.encodeCall(RISKUSDVault.initialize, (mockUsdc, riskusd, deployer));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInit);
        address vault = address(vaultProxy);

        // Set vault as RISKUSD minter (finalize in separate tx via cast)
        RISKUSD(riskusd).setMinter(vault);

        vm.stopBroadcast();

        console.log("MockUSDC:", mockUsdc);
        console.log("RISKUSD:", riskusd);
        console.log("RISKUSDVault:", vault);
        console.log("Deployer USDC balance:", MockUSDC(mockUsdc).balanceOf(deployer));
        console.log("NOTE: Run 'cast send RISKUSD finalizeMinter()' in a separate tx after this completes");
    }
}
