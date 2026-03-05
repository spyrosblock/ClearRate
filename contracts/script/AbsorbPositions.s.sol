// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {ClearRateScript} from "./ClearRateScript.sol";
import {LiquidationEngine} from "../src/liquidation/LiquidationEngine.sol";
import {Whitelist} from "../src/access/Whitelist.sol";

/// @title AbsorbPositions
/// @notice Script for user 3 to call absorbPositions on the LiquidationEngine to liquidate user 2.
/// @dev Run with: forge script script/AbsorbPositions.s.sol --rpc-url sepolia --broadcast
///
/// Prerequisites:
/// - User 2 must have an active liquidation auction
/// - User 3 must be whitelisted
/// - User 3 must have sufficient margin to take over positions
contract AbsorbPositions is ClearRateScript {
    // ─── State ──────────────────────────────────────────────────────────

    LiquidationEngine internal liquidationEngine;
    Whitelist internal whitelist;

    // ─── Configuration ─────────────────────────────────────────────────

    /// @notice Get the LiquidationEngine address from environment.
    function getLiquidationEngine() internal view returns (address) {
        string memory addrStr = vm.envString("LIQUIDATION_ENGINE_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get User 2's address (the account to liquidate).
    function getUser2Address() internal view returns (address) {
        string memory addrStr = vm.envString("USER2_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get User 3's private key (the liquidator).
    function getUser3PrivateKey() internal view returns (uint256) {
        string memory privateKeyStr = vm.envString("USER3_PRIVATE_KEY");
        
        // Remove "0x" prefix if present
        if (bytes(privateKeyStr).length >= 2) {
            bytes memory prefix = bytes(privateKeyStr);
            if (prefix[0] == 0x30 && prefix[1] == 0x78) {
                privateKeyStr = _substring(privateKeyStr, 2, bytes(privateKeyStr).length);
            }
        }
        
        return _parseHex(privateKeyStr);
    }

    /// @notice Get the collateral token address from environment.
    function getCollateralToken() internal view returns (address) {
        string memory addrStr = vm.envString("MOCK_COLLATERAL_TOKEN");
        return _parseAddress(addrStr);
    }

    /// @notice Get the Whitelist address from environment.
    function getWhitelistAddress() internal view returns (address) {
        string memory addrStr = vm.envString("WHITELIST_ADDRESS");
        return _parseAddress(addrStr);
    }

    // ─── Main Entry Point ───────────────────────────────────────────────

    /// @notice Execute the absorbPositions call.
    /// @dev User 3 absorbs all positions from User 2's liquidation auction.
    function run() external {
        // Get configuration from environment
        address liquidationEngineAddr = getLiquidationEngine();
        address user2Addr = getUser2Address();
        uint256 user3PrivateKey = getUser3PrivateKey();
        address collateralToken = getCollateralToken();
        address whitelistAddr = getWhitelistAddress();

        // Derive User 3's address from private key
        address user3Addr = vm.addr(user3PrivateKey);

        console.log("========================================");
        console.log("Absorb Positions Script");
        console.log("========================================");
        console.log("LiquidationEngine:", liquidationEngineAddr);
        console.log("Liquidator (User 3):", user3Addr);
        console.log("Account to Liquidate (User 2):", user2Addr);
        console.log("Collateral Token:", collateralToken);
        console.log("Whitelist:", whitelistAddr);
        console.log("========================================\n");

        // Initialize contract interfaces
        liquidationEngine = LiquidationEngine(liquidationEngineAddr);
        whitelist = Whitelist(whitelistAddr);

        // Get User 2's account ID from whitelist
        bytes32 user2AccountId = whitelist.getAccountId(user2Addr);
        
        console.log("User 2 Account ID:");
        console.logBytes32(user2AccountId);

        // Check if auction is active
        bool isAuctionActive = liquidationEngine.isAuctionActive(user2AccountId, collateralToken);
        console.log("Auction Active:", isAuctionActive);

        if (!isAuctionActive) {
            console.log("\n[ERROR] No active auction for User 2 with the specified collateral token.");
            console.log("A liquidation auction must be started before positions can be absorbed.");
            revert("No active auction");
        }

        // Get current premium
        uint256 currentPremium = liquidationEngine.getCurrentPremium(user2AccountId, collateralToken);
        console.log("Current Premium (BPS):", currentPremium);
        console.log("Premium Percentage:", currentPremium / 100, "basis points");

        console.log("\n========================================");
        console.log("Executing absorbPositions...");
        console.log("========================================");

        // Start broadcasting from User 3's address
        vm.startBroadcast(user3PrivateKey);

        // Call absorbPositions
        liquidationEngine.absorbPositions(user2AccountId, collateralToken);

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("SUCCESS: Positions absorbed successfully!");
        console.log("========================================");
        console.log("User 3 has taken over User 2's positions.");
        console.log("User 3 received a liquidation premium.");
    }
}