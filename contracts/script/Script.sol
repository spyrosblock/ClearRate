// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @title ClearRateScript
/// @notice Base contract for ClearRate deployment scripts with common utilities.
/// @dev Configuration is read from environment variables or uses defaults for testnet.
abstract contract ClearRateScript is Script {
    // ─── Configuration ──────────────────────────────────────────────────

    /// @notice Ethereum Sepolia USDC token address.
    /// @dev From CONTINUE.md: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
    address internal constant SEPOLIA_USDC = address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);

    /// @notice Base Sepolia USDC token address.
    /// @dev From CONTINUE.md: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    address internal constant BASE_SEPOLIA_USDC = address(0x036CbD53842c5426634e7929541eC2318f3dCF7e);

    /// @notice Arbitrum Sepolia USDC token address.
    /// @dev From CONTINUE.md: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
    address internal constant ARB_SEPOLIA_USDC = address(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d);

    /// @notice Default accepted tokens array for hub margin vaults.
    address[] internal acceptedTokens;

    /// @notice Default tenors for yield curve oracle (in seconds).
    uint256[] internal defaultTenors;

    /// @notice CCIP chain selectors for testnet.
    uint64 internal constant ETH_SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    uint64 internal constant BASE_SEPOLIA_CHAIN_SELECTOR = 580965213822371589;
    uint64 internal constant ARB_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;

    // ─── Initialization ─────────────────────────────────────────────────

    constructor() {
        // Initialize default accepted tokens (USDC on Ethereum Sepolia)
        acceptedTokens.push(SEPOLIA_USDC);
        // Note: USDT and DAI would need to be added here for mainnet

        // Initialize default tenors (30D, 90D, 180D, 1Y, 2Y, 5Y, 10Y)
        defaultTenors.push(30 days);
        defaultTenors.push(90 days);
        defaultTenors.push(180 days);
        defaultTenors.push(365 days);
        defaultTenors.push(730 days);
        defaultTenors.push(1825 days);
        defaultTenors.push(3650 days);
    }

    // ─── Helper Functions ───────────────────────────────────────────────

    /// @notice Get the deployer address from vm.
    /// @return deployer The deployer address.
    function getDeployer() internal view returns (address deployer) {
        return msg.sender;
    }

    /// @notice Get accepted tokens for the hub.
    /// @return tokens Array of accepted token addresses.
    function getHubTokens() internal view returns (address[] memory tokens) {
        return acceptedTokens;
    }

    /// @notice Get accepted tokens for a specific spoke chain.
    /// @param chainSelector The CCIP chain selector.
    /// @return tokens Array of accepted token addresses for that chain.
    function getSpokeTokens(uint64 chainSelector) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        if (chainSelector == BASE_SEPOLIA_CHAIN_SELECTOR) {
            tokens[0] = BASE_SEPOLIA_USDC;
        } else if (chainSelector == ARB_SEPOLIA_CHAIN_SELECTOR) {
            tokens[0] = ARB_SEPOLIA_USDC;
        } else {
            // Default to Sepolia tokens
            tokens[0] = SEPOLIA_USDC;
        }
    }

    /// @notice Get the CCIP router address for a given chain.
    /// @param chainSelector The CCIP chain selector.
    /// @return router The CCIP router address.
    function getCCIPRouter(uint64 chainSelector) internal pure returns (address router) {
        // These are placeholder router addresses - replace with actual CCIP router addresses
        if (chainSelector == BASE_SEPOLIA_CHAIN_SELECTOR) {
            // Base Sepolia CCIP Router (placeholder - verify with Chainlink docs)
            return address(0x2334936096ae3d5E5B4E0C4A3E3F3d2C1b0A0908);
        } else if (chainSelector == ARB_SEPOLIA_CHAIN_SELECTOR) {
            // Arbitrum Sepolia CCIP Router (placeholder)
            return address(0x2334936096ae3d5E5B4E0C4A3E3F3d2C1b0A0908);
        }
        // Default/ETH Sepolia
        return address(0x2334936096ae3d5E5B4E0C4A3E3F3d2C1b0A0908);
    }

    /// @notice Log a deployed contract address.
    /// @param name_ The contract name.
    /// @param addr_ The deployed address.
    function logDeployment(string memory name_, address addr_) internal view {
        console.log(string(abi.encodePacked("Deployed ", name_, " at: ")));
        console.logAddress(addr_);
    }

    /// @notice Log all deployed contract addresses at the end.
    /// @param names_ Array of contract names.
    /// @param addrs_ Array of deployed addresses.
    function logAllDeployments(
        string[] memory names_,
        address[] memory addrs_
    ) internal view {
        console.log("\n=== ClearRate Deployment Summary ===");
        for (uint256 i; i < names_.length; ++i) {
            console.log(string(abi.encodePacked(names_[i], ": ")));
            console.logAddress(addrs_[i]);
        }
        console.log("=====================================\n");
    }
}
