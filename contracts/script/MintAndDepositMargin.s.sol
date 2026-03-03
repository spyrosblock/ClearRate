// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MarginVault} from "../src/margin/MarginVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MintAndDepositMargin
/// @notice Script to deposit 4 million tokens each for 2 users on the MarginVault.
/// @dev Run with: forge script script/MintAndDepositMargin.s.sol:MintAndDepositMargin --rpc-url sepolia --broadcast --verify
///
/// This script reads from environment variables:
/// - USER1_ADDRESS / USER2_ADDRESS: User wallet addresses
/// - USER1_ACCOUNT_ID / USER2_ACCOUNT_ID: Account IDs for margin accounts
/// - USER1_PRIVATE_KEY / USER2_PRIVATE_KEY: Private keys for signing transactions
/// - MARGIN_VAULT_ADDRESS: Address of the MarginVault contract
/// - MOCK_COLLATERAL_TOKEN: Address of the collateral token (USDC)
contract MintAndDepositMargin is Script {
    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Amount to deposit for each user (4 million tokens)
    uint256 internal constant DEPOSIT_AMOUNT = 4_000_000e18; // 4,000,000 with 18 decimals

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

    /// @notice Main function to execute the deposit script.
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
        console.log("Depositing Margin on ClearRate Protocol");
        console.log("========================================");
        console.log("MarginVault Address:");
        console.logAddress(marginVaultAddress);
        console.log("Collateral Token:");
        console.logAddress(collateralToken);
        console.log("Deposit Amount (per user):");
        console.logUint(DEPOSIT_AMOUNT);

        // Initialize MarginVault interface
        MarginVault marginVault = MarginVault(marginVaultAddress);
        IERC20 token = IERC20(collateralToken);

        // ═══════════════════════════════════════════════════════════════════════
        //  MINT TOKENS TO USERS (using the deployer key for mock token)
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n--- Minting Tokens to Users ---");
        
        // Get the deployer private key from environment
        string memory deployerKeyStr = vm.envString("DEPLOYER_PRIVATE_KEY");
        uint256 deployerPrivateKey = _parseHexPrivateKey(deployerKeyStr);

        // Cast to contract with mint function
        // Using inline assembly to call mint(address, uint256)
        address tokenAddr = collateralToken;
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Mint to user 1
        (bool success1, ) = tokenAddr.call(abi.encodeWithSignature("mint(address,uint256)", user1Address, DEPOSIT_AMOUNT));
        require(success1, "Failed to mint tokens to user 1");
        console.log("Minted to User 1:");
        console.logUint(DEPOSIT_AMOUNT);
        
        // Mint to user 2
        (bool success2, ) = tokenAddr.call(abi.encodeWithSignature("mint(address,uint256)", user2Address, DEPOSIT_AMOUNT));
        require(success2, "Failed to mint tokens to user 2");
        console.log("Minted to User 2:");
        console.logUint(DEPOSIT_AMOUNT);
        
        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════════════════
        //  CHECK TOKEN BALANCES
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n--- Checking Token Balances ---");
        
        uint256 user1Balance = token.balanceOf(user1Address);
        console.log("User 1 Token Balance:");
        console.logUint(user1Balance);

        uint256 user2Balance = token.balanceOf(user2Address);
        console.log("User 2 Token Balance:");
        console.logUint(user2Balance);

        if (user1Balance < DEPOSIT_AMOUNT) {
            console.log("WARNING: User 1 has insufficient balance!");
        }
        if (user2Balance < DEPOSIT_AMOUNT) {
            console.log("WARNING: User 2 has insufficient balance!");
        }

        // Check and show current margin balances
        console.log("\n--- Current Margin Account Status ---");
        
        uint256 user1CurrentCollateral = marginVault.getTotalCollateral(accountId1, collateralToken);
        console.log("User 1 Current Total Collateral:");
        console.logUint(user1CurrentCollateral);

        uint256 user2CurrentCollateral = marginVault.getTotalCollateral(accountId2, collateralToken);
        console.log("User 2 Current Total Collateral:");
        console.logUint(user2CurrentCollateral);

        // ═══════════════════════════════════════════════════════════════════════
        //  DEPOSIT FOR USER 1
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n[1/2] Depositing margin for User 1...");
        console.log("  Address:");
        console.logAddress(user1Address);
        console.log("  AccountId:");
        console.logBytes32(accountId1);
        console.log("  Amount:");
        console.logUint(DEPOSIT_AMOUNT);

        vm.startBroadcast(user1PrivateKey);

        // Approve tokens for MarginVault
        token.approve(marginVaultAddress, DEPOSIT_AMOUNT);

        // Deposit margin
        marginVault.depositMargin(accountId1, collateralToken, DEPOSIT_AMOUNT);
        
        vm.stopBroadcast();

        console.log("  [OK] User 1 margin deposited successfully");

        // ═══════════════════════════════════════════════════════════════════════
        //  DEPOSIT FOR USER 2
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n[2/2] Depositing margin for User 2...");
        console.log("  Address:");
        console.logAddress(user2Address);
        console.log("  AccountId:");
        console.logBytes32(accountId2);
        console.log("  Amount:");
        console.logUint(DEPOSIT_AMOUNT);

        vm.startBroadcast(user2PrivateKey);

        // Approve tokens for MarginVault
        token.approve(marginVaultAddress, DEPOSIT_AMOUNT);

        // Deposit margin
        marginVault.depositMargin(accountId2, collateralToken, DEPOSIT_AMOUNT);
        
        vm.stopBroadcast();

        console.log("  [OK] User 2 margin deposited successfully");

        // ═══════════════════════════════════════════════════════════════════════
        //  VERIFY DEPOSITS
        // ═══════════════════════════════════════════════════════════════════════

        console.log("\n========================================");
        console.log("Deposit Summary");
        console.log("========================================");

        uint256 user1NewCollateral = marginVault.getTotalCollateral(accountId1, collateralToken);
        console.log("User 1 New Total Collateral:");
        console.logUint(user1NewCollateral);

        uint256 user2NewCollateral = marginVault.getTotalCollateral(accountId2, collateralToken);
        console.log("User 2 New Total Collateral:");
        console.logUint(user2NewCollateral);

        console.log("\n========================================");
        console.log("Margin deposit complete!");
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
