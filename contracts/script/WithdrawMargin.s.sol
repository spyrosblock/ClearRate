// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MarginVault} from "../src/margin/MarginVault.sol";

/// @title WithdrawMargin
/// @notice Script to withdraw all free margin for 2 users from the MarginVault on Sepolia.
/// @dev Run with: forge script script/WithdrawMargin.s.sol:WithdrawMargin --rpc-url sepolia --broadcast --verify
///
/// This script reads from environment variables:
/// - USER1_ADDRESS / USER2_ADDRESS: User wallet addresses
/// - USER1_ACCOUNT_ID / USER2_ACCOUNT_ID: Account IDs for margin accounts
/// - USER1_PRIVATE_KEY / USER2_PRIVATE_KEY: Private keys for signing transactions
/// - MARGIN_VAULT_ADDRESS: Address of the MarginVault contract
/// - MOCK_COLLATERAL_TOKEN: Address of the collateral token (USDC)
/// - WITHDRAW_AMOUNT: Custom amount to withdraw (optional, defaults to full free margin)
/// By default, withdraws the full free margin (totalCollateral - lockedIM), capped by token collateral.
contract WithdrawMargin is Script {
    // ═══════════════════════════════════════════════════════════════════════
    //  USER DATA (from .env)
    // ═══════════════════════════════════════════════════════════════════════

    address internal user1Address;
    address internal user2Address;
    bytes32 internal accountId1;
    bytes32 internal accountId2;
    uint256 internal user1PrivateKey;
    uint256 internal user2PrivateKey;
    address internal marginVaultAddress;
    address internal collateralToken;

    // ═══════════════════════════════════════════════════════════════════════
    //  MAIN ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Main function to execute the withdraw script.
    function run() external {
        // ═══════════════════════════════════════════════════════════════════════
        //  LOAD ENVIRONMENT VARIABLES
        // ═══════════════════════════════════════════════════════════════════════

        // Load MarginVault address
        string memory marginVaultStr = vm.envString("MARGIN_VAULT_ADDRESS");
        marginVaultAddress = _parseAddress(marginVaultStr);

        // Load collateral token address
        string memory collateralStr = vm.envString("MOCK_COLLATERAL_TOKEN");
        collateralToken = _parseAddress(collateralStr);

        // Load user addresses
        string memory user1AddrStr = vm.envString("USER1_ADDRESS");
        string memory user2AddrStr = vm.envString("USER2_ADDRESS");
        user1Address = _parseAddress(user1AddrStr);
        user2Address = _parseAddress(user2AddrStr);

        // Load account IDs
        accountId1 = _addressToAccountId(user1Address);
        accountId2 = _addressToAccountId(user2Address);

        // Load private keys
        string memory user1KeyStr = vm.envString("USER1_PRIVATE_KEY");
        string memory user2KeyStr = vm.envString("USER2_PRIVATE_KEY");
        user1PrivateKey = _parseHexPrivateKey(user1KeyStr);
        user2PrivateKey = _parseHexPrivateKey(user2KeyStr);

        console.log("========================================");
        console.log("Withdrawing Margin on ClearRate Protocol");
        console.log("========================================");
        console.log("MarginVault Address:");
        console.logAddress(marginVaultAddress);
        console.log("Collateral Token:");
        console.logAddress(collateralToken);

        // Initialize MarginVault interface
        MarginVault marginVault = MarginVault(marginVaultAddress);

        // ═══════════════════════════════════════════════════════════════════════
        //  CHECK CURRENT MARGIN BALANCES
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n--- Current Margin Account Status ---");
        
        uint256 user1CurrentCollateral = marginVault.getTotalCollateral(accountId1, collateralToken);
        uint256 user1TokenCollateral = marginVault.tokenCollateral(accountId1, collateralToken);
        uint256 user1FreeMargin = marginVault.getFreeMarginByToken(accountId1, collateralToken);
        console.log("User 1 Current Total Collateral:");
        console.logUint(user1CurrentCollateral);
        console.log("User 1 Token Collateral (USDC):");
        console.logUint(user1TokenCollateral);
        console.log("User 1 Free Margin:");
        console.logUint(user1FreeMargin);

        uint256 user2CurrentCollateral = marginVault.getTotalCollateral(accountId2, collateralToken);
        uint256 user2TokenCollateral = marginVault.tokenCollateral(accountId2, collateralToken);
        uint256 user2FreeMargin = marginVault.getFreeMarginByToken(accountId2, collateralToken);
        console.log("User 2 Current Total Collateral:");
        console.logUint(user2CurrentCollateral);
        console.log("User 2 Token Collateral (USDC):");
        console.logUint(user2TokenCollateral);
        console.log("User 2 Free Margin:");
        console.logUint(user2FreeMargin);

        // ═══════════════════════════════════════════════════════════════════════
        //  WITHDRAW FOR USER 1 (full free margin by default)
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n[1/2] Withdrawing margin for User 1...");

        // Default to full free margin (the maximum withdrawable amount)
        // Must cap at token collateral since we can only withdraw what's available in that token
        uint256 withdrawAmountUser1 = user1FreeMargin > user1TokenCollateral 
            ? user1TokenCollateral 
            : user1FreeMargin;
        bool useCustomAmount = false;

        // Check if WITHDRAW_AMOUNT is set and use it instead (capped at free margin and token collateral)
        if (vm.envExists("WITHDRAW_AMOUNT")) {
            uint256 customAmount = vm.envUint("WITHDRAW_AMOUNT");
            uint256 maxWithdrawable = user1FreeMargin > user1TokenCollateral 
                ? user1TokenCollateral 
                : user1FreeMargin;
            if (customAmount <= maxWithdrawable) {
                withdrawAmountUser1 = customAmount;
                useCustomAmount = true;
            } else {
                console.log("  WARNING: Custom amount exceeds available margin, using max withdrawable");
                withdrawAmountUser1 = maxWithdrawable;
            }
        }

        console.log("  Address:");
        console.logAddress(user1Address);
        console.log("  AccountId:");
        console.logBytes32(accountId1);
        console.log("  Free Margin:");
        console.logUint(user1FreeMargin);
        console.log("  Token Collateral (USDC):");
        console.logUint(user1TokenCollateral);
        console.log("  Withdraw Amount:");
        console.logUint(withdrawAmountUser1);
        if (useCustomAmount) {
            console.log("  (Custom amount specified)");
        } else {
            console.log("  (Full free margin, capped by token collateral)");
        }

        if (withdrawAmountUser1 == 0) {
            console.log("  [SKIPPED] No margin to withdraw");
        } else {
            vm.startBroadcast(user1PrivateKey);

            // Withdraw margin - funds go to the user's own address
            marginVault.withdrawMargin(accountId1, collateralToken, withdrawAmountUser1, user1Address);
            
            vm.stopBroadcast();

            console.log("  [OK] User 1 margin withdrawn successfully");
        }

        // ═══════════════════════════════════════════════════════════════════════
        //  WITHDRAW FOR USER 2 (full free margin by default)
        // ═══════════════════════════════════════════════════════════════════════

        // Refresh user2's free margin and token collateral (in case user1 withdrawal affected it, though they're separate accounts)
        uint256 user2FreeMarginAfter = marginVault.getFreeMarginByToken(accountId2, collateralToken);
        uint256 user2TokenCollateralAfter = marginVault.tokenCollateral(accountId2, collateralToken);

        console.log("\n[2/2] Withdrawing margin for User 2...");

        // Default to full free margin (the maximum withdrawable amount)
        // Must cap at token collateral since we can only withdraw what's available in that token
        uint256 withdrawAmountUser2 = user2FreeMarginAfter > user2TokenCollateralAfter 
            ? user2TokenCollateralAfter 
            : user2FreeMarginAfter;
        useCustomAmount = false;

        // Check if WITHDRAW_AMOUNT is set and use it instead (capped at free margin and token collateral)
        if (vm.envExists("WITHDRAW_AMOUNT")) {
            uint256 customAmount = vm.envUint("WITHDRAW_AMOUNT");
            uint256 maxWithdrawable = user2FreeMarginAfter > user2TokenCollateralAfter 
                ? user2TokenCollateralAfter 
                : user2FreeMarginAfter;
            if (customAmount <= maxWithdrawable) {
                withdrawAmountUser2 = customAmount;
                useCustomAmount = true;
            } else {
                console.log("  WARNING: Custom amount exceeds available margin, using max withdrawable");
                withdrawAmountUser2 = maxWithdrawable;
            }
        }

        console.log("  Address:");
        console.logAddress(user2Address);
        console.log("  AccountId:");
        console.logBytes32(accountId2);
        console.log("  Free Margin:");
        console.logUint(user2FreeMarginAfter);
        console.log("  Token Collateral (USDC):");
        console.logUint(user2TokenCollateralAfter);
        console.log("  Withdraw Amount:");
        console.logUint(withdrawAmountUser2);
        if (useCustomAmount) {
            console.log("  (Custom amount specified)");
        } else {
            console.log("  (Full free margin, capped by token collateral)");
        }

        if (withdrawAmountUser2 == 0) {
            console.log("  [SKIPPED] No margin to withdraw");
        } else {
            vm.startBroadcast(user2PrivateKey);

            // Withdraw margin - funds go to the user's own address
            marginVault.withdrawMargin(accountId2, collateralToken, withdrawAmountUser2, user2Address);
            
            vm.stopBroadcast();

            console.log("  [OK] User 2 margin withdrawn successfully");
        }

        // ═══════════════════════════════════════════════════════════════════════
        //  VERIFY WITHDRAWALS
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n========================================");
        console.log("Withdrawal Summary");
        console.log("========================================");

        uint256 user1NewCollateral = marginVault.getTotalCollateral(accountId1, collateralToken);
        console.log("User 1 New Total Collateral:");
        console.logUint(user1NewCollateral);

        uint256 user2NewCollateral = marginVault.getTotalCollateral(accountId2, collateralToken);
        console.log("User 2 New Total Collateral:");
        console.logUint(user2NewCollateral);

        console.log("\n========================================");
        console.log("Margin withdrawal complete!");
        console.log("========================================");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Parse a private key from hex string (with or without 0x prefix)
    function _parseHexPrivateKey(string memory hexStr) internal pure returns (uint256) {
        bytes memory b = bytes(hexStr);
        uint256 result = 0;
        
        // Skip "0x" prefix if present
        uint256 startIndex = 0;
        if (b.length >= 2 && b[0] == 0x30 && b[1] == 0x78) { // "0x"
            startIndex = 2;
        }
        
        for (uint256 i = startIndex; i < b.length; i++) {
            bytes1 currentByte = b[i];
            uint256 digit;
            if (currentByte >= bytes1("0") && currentByte <= bytes1("9")) {
                digit = uint256(uint8(currentByte)) - uint256(uint8(bytes1("0")));
            } else if (currentByte >= bytes1("a") && currentByte <= bytes1("f")) {
                digit = 10 + uint256(uint8(currentByte)) - uint256(uint8(bytes1("a")));
            } else if (currentByte >= bytes1("A") && currentByte <= bytes1("F")) {
                digit = 10 + uint256(uint8(currentByte)) - uint256(uint8(bytes1("A")));
            } else {
                continue;
            }
            result = result * 16 + digit;
        }
        return result;
    }

    /// @dev Parse an address from string
    function _parseAddress(string memory addrStr) internal pure returns (address) {
        bytes memory strBytes = bytes(addrStr);
        if (strBytes.length == 42 && strBytes[0] == 0x30 && strBytes[1] == 0x78) {
            bytes memory addrBytes = new bytes(40);
            for (uint256 i = 2; i < 42; i++) {
                addrBytes[i - 2] = strBytes[i];
            }
            return address(uint160(_parseHexBytes(addrBytes)));
        }
        return address(0);
    }

    /// @dev Parse hex bytes to uint256
    function _parseHexBytes(bytes memory b) internal pure returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 currentByte = b[i];
            uint256 digit;
            if (currentByte >= bytes1("0") && currentByte <= bytes1("9")) {
                digit = uint256(uint8(currentByte)) - uint256(uint8(bytes1("0")));
            } else if (currentByte >= bytes1("a") && currentByte <= bytes1("f")) {
                digit = 10 + uint256(uint8(currentByte)) - uint256(uint8(bytes1("a")));
            } else if (currentByte >= bytes1("A") && currentByte <= bytes1("F")) {
                digit = 10 + uint256(uint8(currentByte)) - uint256(uint8(bytes1("A")));
            } else {
                continue;
            }
            result = result * 16 + digit;
        }
        return result;
    }

    /// @dev Convert an address to a bytes32 account ID with left padding of 0s
    function _addressToAccountId(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
