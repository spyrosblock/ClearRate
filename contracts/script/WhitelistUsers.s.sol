// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Whitelist} from "../src/access/Whitelist.sol";

/// @title WhitelistUsers
/// @notice Script to whitelist 2 users on the ClearRate protocol.
/// @dev Run with: forge script script/WhitelistUsers.s.sol:WhitelistUsers --rpc-url sepolia --broadcast --verify
///
/// This script reads user addresses from environment variables:
/// - USER1_ADDRESS
/// - USER2_ADDRESS
/// - USER1_ACCOUNT_ID (optional, defaults to bytes32(uint256(1)))
/// - USER2_ACCOUNT_ID (optional, defaults to bytes32(uint256(2)))
contract WhitelistUsers is Script {
    // ═══════════════════════════════════════════════════════════════════════
    //  USER ADDRESSES (from .env)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice First user address to whitelist (from USER1_ADDRESS env var).
    address internal user1Address;

    /// @notice Second user address to whitelist (from USER2_ADDRESS env var).
    address internal user2Address;

    // ═══════════════════════════════════════════════════════════════════════
    //  ACCOUNT IDS (from .env, optional)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Account ID for user 1 (from USER1_ACCOUNT_ID env var, optional).
    bytes32 internal accountId1;

    /// @notice Account ID for user 2 (from USER2_ACCOUNT_ID env var, optional).
    bytes32 internal accountId2;

    /// @notice Main entry point for the whitelist script.
    function run() external {
        // ═══════════════════════════════════════════════════════════════════
        //  LOAD ENVIRONMENT VARIABLES
        // ═══════════════════════════════════════════════════════════════════

        // Load whitelist address from environment
        string memory whitelistAddressStr = vm.envString("WHITELIST_ADDRESS");
        
        address whitelistAddress;
        if (bytes(whitelistAddressStr).length > 0) {
            whitelistAddress = _parseAddress(whitelistAddressStr);
        } else {
            revert("WHITELIST_ADDRESS not set in .env");
        }

        // Load user addresses from environment
        string memory user1AddressStr = vm.envString("USER1_ADDRESS");
        string memory user2AddressStr = vm.envString("USER2_ADDRESS");

        user1Address = _parseAddress(user1AddressStr);
        user2Address = _parseAddress(user2AddressStr);

        // Load account IDs from environment (optional, defaults provided)
        string memory user1AccountIdStr = vm.envString("USER1_ACCOUNT_ID");
        string memory user2AccountIdStr = vm.envString("USER2_ACCOUNT_ID");

        if (bytes(user1AccountIdStr).length > 0) {
            accountId1 = bytes32(vm.envUint("USER1_ACCOUNT_ID"));
        } else {
            accountId1 = bytes32(uint256(1));
        }

        if (bytes(user2AccountIdStr).length > 0) {
            accountId2 = bytes32(vm.envUint("USER2_ACCOUNT_ID"));
        } else {
            accountId2 = bytes32(uint256(2));
        }

        console.log("========================================");
        console.log("Whitelisting Users on ClearRate Protocol");
        console.log("========================================");
        console.log("Whitelist Address:");
        console.logAddress(whitelistAddress);

        Whitelist whitelist = Whitelist(whitelistAddress);

        // Get deployer (must have WHITELIST_ADMIN_ROLE)
        address deployer = getDeployer();
        console.log("Operator:");
        console.logAddress(deployer);

        // Start broadcasting
        vm.startBroadcast(deployer);

        // Whitelist User 1
        console.log("\n[1/2] Whitelisting User 1...");
        console.log("  Address:");
        console.logAddress(user1Address);
        console.log("  AccountId:");
        console.logBytes32(accountId1);
        
        whitelist.addParticipant(user1Address, accountId1);
        console.log("  [OK] User 1 whitelisted successfully");

        // Whitelist User 2
        console.log("\n[2/2] Whitelisting User 2...");
        console.log("  Address:");
        console.logAddress(user2Address);
        console.log("  AccountId:");
        console.logBytes32(accountId2);
        
        whitelist.addParticipant(user2Address, accountId2);
        console.log("  [OK] User 2 whitelisted successfully");

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("Whitelist Summary");
        console.log("========================================");
        console.log("Total participants after whitelist:");
        console.logUint(whitelist.participantCount());
        
        console.log("\nUser 1 is whitelisted:");
        console.logBool(whitelist.isWhitelisted(user1Address));
        
        console.log("User 2 is whitelisted:");
        console.logBool(whitelist.isWhitelisted(user2Address));

        console.log("\n========================================");
        console.log("Whitelist operation complete!");
        console.log("========================================");
    }

    /// @notice Get the deployer address from the PRIVATE_KEY or DEPLOYER_PRIVATE_KEY environment variable.
    /// @return deployer The deployer address derived from the private key.
    function getDeployer() internal view returns (address deployer) {
        string memory privateKeyStr = vm.envString("DEPLOYER_PRIVATE_KEY");
        
        if (bytes(privateKeyStr).length >= 2) {
            bytes memory prefix = bytes(privateKeyStr);
            if (prefix[0] == 0x30 && prefix[1] == 0x78) { // "0x"
                privateKeyStr = _substring(privateKeyStr, 2, bytes(privateKeyStr).length);
            }
        }
        
        uint256 privateKey = _parseHex(privateKeyStr);
        deployer = vm.addr(privateKey);
        
        if (deployer == address(0)) {
            deployer = msg.sender;
        }
    }

    /// @dev Helper to extract substring
    function _substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    /// @dev Helper to parse hex string to uint256
    function _parseHex(string memory hexStr) internal pure returns (uint256) {
        bytes memory b = bytes(hexStr);
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

    /// @dev Helper to parse address from string
    function _parseAddress(string memory addrStr) internal pure returns (address) {
        bytes memory strBytes = bytes(addrStr);
        if (strBytes.length == 42 && strBytes[0] == 0x30 && strBytes[1] == 0x78) {
            // Remove "0x" prefix
            bytes memory addrBytes = new bytes(40);
            for (uint256 i = 2; i < 42; i++) {
                addrBytes[i - 2] = strBytes[i];
            }
            return address(uint160(_parseHexBytes(addrBytes)));
        }
        return address(0);
    }

    /// @dev Helper to parse hex bytes to uint256
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
}
