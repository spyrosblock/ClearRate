// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ClearRateScript} from "./Script.sol";
import {LocalMarginVault} from "../src/margin/LocalMarginVault.sol";
import {CCIPSpokeGateway} from "../src/crosschain/CCIPSpokeGateway.sol";

/// @title DeploySpokes
/// @notice Deployment script for Spoke chain contracts (Base Sepolia, Arbitrum Sepolia).
/// @dev Run with: 
///      Base Sepolia: forge script script/DeploySpokes.s.sol --rpc-url base_sepolia --broadcast --verify --sig "run(uint64,address,address)" 580965213822371589 <HUB_GATEWAY> <CCIP_ROUTER>
///      Arbitrum Sepolia: forge script script/DeploySpokes.s.sol --rpc-url arbitrum_sepolia --broadcast --verify --sig "run(uint64,address,address)" 3478487238524512106 <HUB_GATWAY> <CCIP_ROUTER>
///
/// This script deploys:
///      - LocalMarginVault: For users to deposit/withdraw collateral on L2
///      - CCIPSpokeGateway: For cross-chain margin sync and trade relay
contract DeploySpokes is ClearRateScript {
    // ═══════════════════════════════════════════════════════════════════════
    //  CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Chain configuration for a spoke.
    struct ChainConfig {
        uint64 chainSelector;      // CCIP chain selector
        string name;              // Human-readable name
        address ccipRouter;       // CCIP router address on this chain
        address usdc;             // USDC address on this chain
    }

    /// @notice Default CCIP chain selectors and router addresses for testnet.
    /// @dev From CONTINUE.md:
    ///      - Ethereum Sepolia: 16015286601757825753
    ///      - Base Sepolia: 580965213822371589  
    ///      - Arbitrum Sepolia: 3478487238524512106
    ///      
    ///      CCIP Onramp/Offramp addresses from CONTINUE.md:
    ///      - Base Sepolia: onramp 0x28A025d34c830BF212f5D2357C8DcAB32dD92A20, offramp 0xF4EbCC2c077d3939434C7Ab0572660c5A45e4df5
    ///      - Arbitrum Sepolia: onramp 0x64d78F20aD987c7D52FdCB8FB0777bD00de53210, offramp 0xBed6e9131916d724418C8a6FE810F727302a5c00
    ChainConfig[] internal defaultChainConfigs;

    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor() {
        // Initialize default chain configs for testnet
        
        // Base Sepolia
        defaultChainConfigs.push(ChainConfig({
            chainSelector: BASE_SEPOLIA_CHAIN_SELECTOR,
            name: "Base Sepolia",
            ccipRouter: address(0), // Will be set from CONTINUE.md onramp addresses
            usdc: BASE_SEPOLIA_USDC
        }));

        // Arbitrum Sepolia
        defaultChainConfigs.push(ChainConfig({
            chainSelector: ARB_SEPOLIA_CHAIN_SELECTOR,
            name: "Arbitrum Sepolia",
            ccipRouter: address(0),
            usdc: ARB_SEPOLIA_USDC
        }));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy a spoke with default testnet configuration for Base Sepolia.
    /// @dev Use this for quick testing with default CCIP testnet values.
    /// @param hubGatewayAddress_ The address of the Hub gateway contract on Ethereum Sepolia.
    function runBaseSepolia(address hubGatewayAddress_) external {
        // Base Sepolia configuration
        uint64 chainSelector = BASE_SEPOLIA_CHAIN_SELECTOR;
        
        // CCIP Router for Base Sepolia (from CONTINUE.md - onramp address)
        address ccipRouter = 0x28A025d34c830BF212f5D2357C8DcAB32dD92A20;
        
        _deploySpoke(chainSelector, hubGatewayAddress_, ccipRouter, "Base Sepolia");
    }

    /// @notice Deploy a spoke with default testnet configuration for Arbitrum Sepolia.
    /// @dev Use this for quick testing with default CCIP testnet values.
    /// @param hubGatewayAddress_ The address of the Hub gateway contract on Ethereum Sepolia.
    function runArbitrumSepolia(address hubGatewayAddress_) external {
        // Arbitrum Sepolia configuration
        uint64 chainSelector = ARB_SEPOLIA_CHAIN_SELECTOR;
        
        // CCIP Router for Arbitrum Sepolia (from CONTINUE.md - onramp address)
        address ccipRouter = 0x64d78F20aD987c7D52FdCB8FB0777bD00de53210;
        
        _deploySpoke(chainSelector, hubGatewayAddress_, ccipRouter, "Arbitrum Sepolia");
    }

    /// @notice Main deployment function - specify chain selector explicitly.
    /// @param hubChainSelector_ The CCIP chain selector for the Hub (Ethereum Sepolia: 16015286601757825753).
    /// @param hubGatewayAddress_ The address of the Hub gateway contract.
    /// @param ccipRouterAddress_ The CCIP router/onramp address on this spoke chain.
    function run(
        uint64 hubChainSelector_,
        address hubGatewayAddress_,
        address ccipRouterAddress_
    ) external {
        string memory chainName = _getChainName(hubChainSelector_);
        _deploySpoke(hubChainSelector_, hubGatewayAddress_, ccipRouterAddress_, chainName);
    }

    /// @notice Internal deployment logic.
    /// @param hubChainSelector_ The CCIP chain selector for the Hub.
    /// @param hubGatewayAddress_ The address of the Hub gateway contract.
    /// @param ccipRouterAddress_ The CCIP router address on this spoke chain.
    /// @param chainName_ Human-readable name of this spoke chain.
    function _deploySpoke(
        uint64 hubChainSelector_,
        address hubGatewayAddress_,
        address ccipRouterAddress_,
        string memory chainName_
    ) internal {
        // Get the deployer address
        address deployer = getDeployer();

        console.log("========================================");
        console.log("ClearRate Spoke Deployment");
        console.log("========================================");
        console.log("Deployer:");
        console.logAddress(deployer);
        console.log("\nSpoke Chain:");
        console.log(chainName_);
        console.log("Chain Selector:");
        console.logUint(hubChainSelector_);

        // Get accepted tokens for this spoke chain
        address[] memory tokens = getSpokeTokens(hubChainSelector_);

        console.log("\nAccepted Collateral Token:");
        console.logAddress(tokens[0]);

        console.log("\nHub Configuration:");
        console.log("Hub Chain Selector (Ethereum Sepolia):");
        console.logUint(ETH_SEPOLIA_CHAIN_SELECTOR);
        console.log("Hub Gateway Address:");
        console.logAddress(hubGatewayAddress_);
        console.log("CCIP Router/Onramp Address:");
        console.logAddress(ccipRouterAddress_);

        // ═══════════════════════════════════════════════════════════════════
        //  DEPLOY SPOKE CONTRACTS
        // ═══════════════════════════════════════════════════════════════

        // 1. Deploy LocalMarginVault
        console.log("\n[1/2] Deploying LocalMarginVault...");
        LocalMarginVault localVault = new LocalMarginVault(deployer, tokens);
        logDeployment("LocalMarginVault", address(localVault));

        // 2. Deploy CCIPSpokeGateway
        console.log("\n[2/2] Deploying CCIPSpokeGateway...");
        CCIPSpokeGateway gateway = new CCIPSpokeGateway(
            deployer,
            address(localVault),
            ccipRouterAddress_,
            hubChainSelector_,
            hubGatewayAddress_
        );
        logDeployment("CCIPSpokeGateway", address(gateway));

        // ═══════════════════════════════════════════════════════════════
        //  WIRE UP CONTRACTS
        // ═══════════════════════════════════════════════════════════════

        console.log("\n========================================");
        console.log("Configuring Spoke Contracts...");
        console.log("========================================\n");

        // Set the gateway on LocalMarginVault
        localVault.setGateway(address(gateway));
        console.log("- Set CCIPSpokeGateway on LocalMarginVault");

        console.log("Spoke contracts configured successfully!");

        // ═══════════════════════════════════════════════════════════════
        //  DEPLOYMENT SUMMARY
        // ═══════════════════════════════════════════════════════════════

        string[] memory names = new string[](2);
        address[] memory addrs = new address[](2);

        names[0] = "LocalMarginVault";
        addrs[0] = address(localVault);

        names[1] = "CCIPSpokeGateway";
        addrs[1] = address(gateway);

        logAllDeployments(names, addrs);

        console.log("Spoke deployment complete!");
        console.log("\n========================================");
        console.log("NEXT STEPS:");
        console.log("========================================");
        console.log("1. Verify contracts on block explorer");
        console.log("2. Register this spoke gateway on ClearingHouse");
        console.log("3. Configure CCIP lane (onramp/offramp)");
        console.log("4. Add stablecoin liquidity to LocalMarginVault");
        console.log("5. Test cross-chain margin sync");
    }

    /// @notice Get the list of supported spoke chain configurations.
    /// @return Array of chain configs.
    function getSupportedChains() external view returns (ChainConfig[] memory) {
        return defaultChainConfigs;
    }

    /// @dev Helper to get chain name from selector.
    /// @param chainSelector_ The CCIP chain selector.
    /// @return The chain name.
    function _getChainName(uint64 chainSelector_) internal pure returns (string memory) {
        if (chainSelector_ == BASE_SEPOLIA_CHAIN_SELECTOR) {
            return "Base Sepolia";
        } else if (chainSelector_ == ARB_SEPOLIA_CHAIN_SELECTOR) {
            return "Arbitrum Sepolia";
        }
        return "Unknown Chain";
    }
}
