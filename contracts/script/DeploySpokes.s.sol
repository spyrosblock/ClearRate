// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ClearRateScript} from "./Script.sol";
import {LocalMarginVault} from "../src/margin/LocalMarginVault.sol";
import {CCIPSpokeGateway} from "../src/crosschain/CCIPSpokeGateway.sol";

/// @title DeploySpokes
/// @notice Deployment script for Spoke chain contracts (Base Sepolia, Arbitrum Sepolia).
contract DeploySpokes is ClearRateScript {
    /// @notice Chain configurations for supported spoke chains
    struct ChainConfig {
        uint64 chainSelector;
        uint256 chainId;
        string name;
        address ccipRouter;
        address usdc;
    }

    /// @notice Get the chain configuration based on the current network's chain ID
    function _getChainConfig() internal view returns (ChainConfig memory) {
        uint256 currentChainId = block.chainid;

        if (currentChainId == 84532 || currentChainId == 8453) {
            // Base Sepolia (84532) or Base Mainnet (8453)
            return ChainConfig({
                chainSelector: 10344971235874465080,
                chainId: currentChainId,
                name: "Base Sepolia",
                ccipRouter: 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93,
                usdc: BASE_SEPOLIA_USDC
            });
        } else if (currentChainId == 421614 || currentChainId == 42161) {
            // Arbitrum Sepolia (421614) or Arbitrum Mainnet (42161)
            return ChainConfig({
                chainSelector: 3478487238524512106,
                chainId: currentChainId,
                name: "Arbitrum Sepolia",
                ccipRouter: 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165,
                usdc: ARB_SEPOLIA_USDC
            });
        }
        revert("Unsupported chain for spoke deployment");
    }

    function run(
        address hubGatewayAddress_
    ) external {
        ChainConfig memory chainConfig = _getChainConfig();
        
        console.log("========================================");
        console.log("ClearRate Spoke Deployment");
        console.log("========================================");
        console.log("Detected Chain:");
        console.log(chainConfig.name);
        console.log("Chain ID:");
        console.logUint(chainConfig.chainId);
        
        _deploySpoke(chainConfig, hubGatewayAddress_);
    }

    function _deploySpoke(
        ChainConfig memory chainConfig,
        address hubGatewayAddress_
    ) internal {
        address deployer = getDeployer();

        console.log("========================================");
        console.log("ClearRate Spoke Deployment");
        console.log("========================================");
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("\nSpoke Chain:");
        console.log(chainConfig.name);

        // Get tokens for this chain
        address[] memory tokens = new address[](1);
        tokens[0] = chainConfig.usdc;

        console.log("\nAccepted Collateral Token:");
        console.logAddress(tokens[0]);

        console.log("\nHub Configuration:");
        console.log("Hub Chain Selector:");
        console.logUint(ETH_SEPOLIA_CHAIN_SELECTOR);
        console.log("Hub Gateway Address:");
        console.logAddress(hubGatewayAddress_);

        // Start broadcasting all transactions
        vm.startBroadcast(deployer);

        // 1. Deploy LocalMarginVault
        console.log("\n[1/2] Deploying LocalMarginVault...");
        LocalMarginVault localVault = new LocalMarginVault(deployer, tokens);
        logDeployment("LocalMarginVault", address(localVault));

        // 2. Deploy CCIPSpokeGateway
        console.log("\n[2/2] Deploying CCIPSpokeGateway...");
        CCIPSpokeGateway gateway = new CCIPSpokeGateway(
            deployer,
            address(localVault),
            chainConfig.ccipRouter,
            ETH_SEPOLIA_CHAIN_SELECTOR,
            hubGatewayAddress_
        );
        logDeployment("CCIPSpokeGateway", address(gateway));

        // Wire up contracts
        console.log("\nConfiguring Spoke Contracts...");
        localVault.setGateway(address(gateway));
        console.log("- Set CCIPSpokeGateway on LocalMarginVault");

        vm.stopBroadcast();

        console.log("Spoke contracts configured successfully!");

        // Deployment Summary
        string[] memory names = new string[](2);
        address[] memory addrs = new address[](2);

        names[0] = "LocalMarginVault";
        addrs[0] = address(localVault);
        names[1] = "CCIPSpokeGateway";
        addrs[1] = address(gateway);

        logAllDeployments(names, addrs);
        console.log("Spoke deployment complete!");
    }
}
