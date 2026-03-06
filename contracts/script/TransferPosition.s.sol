// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {ClearRateScript} from "./ClearRateScript.sol";
import {ClearingHouse} from "../src/core/ClearingHouse.sol";
import {IRSInstrument} from "../src/core/IRSInstrument.sol";
import {Whitelist} from "../src/access/Whitelist.sol";
import {MarginVault} from "../src/margin/MarginVault.sol";
import {RiskEngine} from "../src/margin/RiskEngine.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title TransferPosition
/// @notice Script for User 1 to transfer 20% of the notional amount of position with tokenId 0 to User 2.
/// @dev Run with: forge script script/TransferPosition.s.sol --rpc-url sepolia --broadcast
///
/// Prerequisites:
/// - User 1 must have a position with tokenId 0
/// - User 1 and User 2 must be whitelisted
/// - User 2 must have sufficient margin to accept the position
/// - User 2 must sign an EIP-712 message approving the transfer
contract TransferPosition is ClearRateScript {
    using ECDSA for bytes32;

    // ─── State ──────────────────────────────────────────────────────────

    ClearingHouse internal clearingHouse;
    IRSInstrument internal instrument;
    Whitelist internal whitelist;
    MarginVault internal marginVault;
    RiskEngine internal riskEngine;

    // ─── Configuration ─────────────────────────────────────────────────

    /// @notice Get the ClearingHouse address from environment.
    function getClearingHouseAddress() internal view returns (address) {
        string memory addrStr = vm.envString("CLEARING_HOUSE_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get the IRSInstrument address from environment.
    function getIRSInstrumentAddress() internal view returns (address) {
        string memory addrStr = vm.envString("IRS_INSTRUMENT_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get the Whitelist address from environment.
    function getWhitelistAddress() internal view returns (address) {
        string memory addrStr = vm.envString("WHITELIST_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get User 1's private key (the sender).
    function getUser1PrivateKey() internal view returns (uint256) {
        string memory privateKeyStr = vm.envString("USER1_PRIVATE_KEY");
        
        // Remove "0x" prefix if present
        if (bytes(privateKeyStr).length >= 2) {
            bytes memory prefix = bytes(privateKeyStr);
            if (prefix[0] == 0x30 && prefix[1] == 0x78) {
                privateKeyStr = _substring(privateKeyStr, 2, bytes(privateKeyStr).length);
            }
        }
        
        return _parseHex(privateKeyStr);
    }

    /// @notice Get User 1's address.
    function getUser1Address() internal view returns (address) {
        string memory addrStr = vm.envString("USER1_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get User 2's private key (the recipient - for signing).
    function getUser2PrivateKey() internal view returns (uint256) {
        string memory privateKeyStr = vm.envString("USER2_PRIVATE_KEY");
        
        // Remove "0x" prefix if present
        if (bytes(privateKeyStr).length >= 2) {
            bytes memory prefix = bytes(privateKeyStr);
            if (prefix[0] == 0x30 && prefix[1] == 0x78) {
                privateKeyStr = _substring(privateKeyStr, 2, bytes(privateKeyStr).length);
            }
        }
        
        return _parseHex(privateKeyStr);
    }

    /// @notice Get User 2's address.
    function getUser2Address() internal view returns (address) {
        string memory addrStr = vm.envString("USER2_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get the MarginVault address from environment.
    function getMarginVaultAddress() internal view returns (address) {
        string memory addrStr = vm.envString("MARGIN_VAULT_ADDRESS");
        return _parseAddress(addrStr);
    }

    /// @notice Get the RiskEngine address from environment.
    function getRiskEngineAddress() internal view returns (address) {
        string memory addrStr = vm.envString("RISK_ENGINE_ADDRESS");
        return _parseAddress(addrStr);
    }

    // ─── Main Entry Point ───────────────────────────────────────────────

    /// @notice Execute the transferPosition call.
    /// @dev User 1 transfers 20% of position tokenId 0 to User 2.
    function run() external {
        // Get configuration from environment
        address clearingHouseAddr = getClearingHouseAddress();
        address instrumentAddr = getIRSInstrumentAddress();
        address whitelistAddr = getWhitelistAddress();
        uint256 user1PrivateKey = getUser1PrivateKey();
        address user1Addr = getUser1Address();
        uint256 user2PrivateKey = getUser2PrivateKey();
        address user2Addr = getUser2Address();

        // Derive addresses from private keys for verification
        address derivedUser1 = vm.addr(user1PrivateKey);
        address derivedUser2 = vm.addr(user2PrivateKey);

        console.log("========================================");
        console.log("Transfer Position Script");
        console.log("========================================");
        console.log("ClearingHouse:", clearingHouseAddr);
        console.log("IRSInstrument:", instrumentAddr);
        console.log("Whitelist:", whitelistAddr);
        console.log("Sender (User 1):", user1Addr);
        console.log("Recipient (User 2):", user2Addr);
        console.log("Derived User 1:", derivedUser1);
        console.log("Derived User 2:", derivedUser2);
        console.log("========================================\n");

        // Initialize contract interfaces
        clearingHouse = ClearingHouse(clearingHouseAddr);
        instrument = IRSInstrument(instrumentAddr);
        whitelist = Whitelist(whitelistAddr);
        marginVault = MarginVault(getMarginVaultAddress());
        riskEngine = RiskEngine(getRiskEngineAddress());

        // Get position details for tokenId 0
        uint256 tokenId = 0;
        IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenId);
        
        console.log("Position Details (tokenId 0):");
        console.log("  Notional:", terms.notional);
        console.log("  Fixed Rate (BPS):", terms.fixedRateBps);
        console.log("  Active:", terms.active);
        console.log("  Collateral Token:", terms.collateralToken);
        
        // Check if position is active
        if (!terms.active) {
            revert("Position with tokenId 0 is not active");
        }

        // Get User 1's balance for this token
        uint256 user1Balance = instrument.balanceOf(user1Addr, tokenId);
        console.log("  User 1 Balance:", user1Balance);

        if (user1Balance == 0) {
            revert("User 1 does not hold any balance for tokenId 0");
        }

        // Calculate 20% of the notional (using User 1's balance)
        uint256 transferAmount = (user1Balance * 20) / 100;
        console.log("  Transfer Amount (20%):", transferAmount);

        if (transferAmount == 0) {
            revert("Transfer amount is 0 (balance too small)");
        }

        // Get account IDs
        bytes32 user1AccountId = whitelist.getAccountId(user1Addr);
        bytes32 user2AccountId = whitelist.getAccountId(user2Addr);

        console.log("\nAccount IDs:");
        console.log("  User 1 Account ID:");
        console.logBytes32(user1AccountId);
        console.log("  User 2 Account ID:");
        console.logBytes32(user2AccountId);

        // Check whitelist status
        bool user1Whitelisted = whitelist.isWhitelisted(user1Addr);
        bool user2Whitelisted = whitelist.isWhitelisted(user2Addr);
        console.log("\nWhitelist Status:");
        console.log("  User 1 Whitelisted:", user1Whitelisted);
        console.log("  User 2 Whitelisted:", user2Whitelisted);

        if (!user1Whitelisted || !user2Whitelisted) {
            revert("Both users must be whitelisted");
        }

        // ─── Margin Checks for User 2 (recipient) ───
        // Calculate the IM required for the transfer amount
        uint256 tenor = terms.maturityDate - terms.startDate;
        uint256 imRequired = riskEngine.calculateIM(transferAmount, tenor);
        
        // Get User 2's free margin for the collateral token
        uint256 user2FreeMargin = marginVault.getFreeMarginByToken(user2AccountId, terms.collateralToken);
        
        console.log("\nMargin Requirements for Transfer:");
        console.log("  Tenor (seconds):", tenor);
        console.log("  IM Required for Transfer:", imRequired);
        console.log("  User 2 Free Margin:", user2FreeMargin);
        
        // Check if User 2's margin account exists
        bool user2AccountExists = marginVault.accountExists(user2AccountId);
        console.log("  User 2 Margin Account Exists:", user2AccountExists);
        
        if (!user2AccountExists) {
            console.log("\n[ERROR] User 2 does not have a margin account.");
            console.log("User 2 must deposit margin before receiving a position transfer.");
            revert("User 2 margin account does not exist - deposit margin first");
        }
        
        if (user2FreeMargin < imRequired) {
            console.log("\n[ERROR] User 2 has insufficient free margin.");
            console.log("Required:", imRequired);
            console.log("Available:", user2FreeMargin);
            console.log("Shortfall:", imRequired - user2FreeMargin);
            revert("User 2 has insufficient margin for transfer");
        }
        
        console.log("  User 2 has sufficient margin for transfer.");
        
        // ─── Check User 2's Notional Limit ───
        uint256 user2CurrentNotional = whitelist.getTotalOpenNotional(user2Addr);
        uint256 user2MaxNotional = whitelist.getMaxNotional(user2Addr);
        uint256 user2AvailableNotional = user2MaxNotional > user2CurrentNotional ? user2MaxNotional - user2CurrentNotional : 0;
        
        console.log("\nNotional Limit Check:");
        console.log("  User 2 Current Notional:", user2CurrentNotional);
        console.log("  User 2 Max Notional:", user2MaxNotional);
        console.log("  User 2 Available Notional:", user2AvailableNotional);
        console.log("  Transfer Amount:", transferAmount);
        
        if (transferAmount > user2AvailableNotional) {
            console.log("\n[ERROR] User 2 would exceed notional limit.");
            console.log("Required:", transferAmount);
            console.log("Available:", user2AvailableNotional);
            console.log("Shortfall:", transferAmount - user2AvailableNotional);
            revert("User 2 would exceed notional limit");
        }
        
        console.log("  User 2 has sufficient notional capacity.");

        // Generate EIP-712 signature from User 2 (recipient)
        uint256 nonce = uint256(keccak256(abi.encodePacked(block.timestamp, user1AccountId, user2AccountId, tokenId, transferAmount)));
        uint256 deadline = block.timestamp + 1 hours;

        // Get the digest for the position transfer
        bytes32 digest = clearingHouse.getPositionTransferDigest(
            user2AccountId,
            tokenId,
            transferAmount,
            nonce,
            deadline
        );

        // Sign the digest with User 2's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2PrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("\nSignature Details:");
        console.log("  Nonce:", nonce);
        console.log("  Deadline:", deadline);
        console.log("  Signature length:", signature.length);

        console.log("\n========================================");
        console.log("Executing transferPosition...");
        console.log("========================================");

        // Start broadcasting from User 1's address
        vm.startBroadcast(user1PrivateKey);

        // Call transferPosition
        clearingHouse.transferPosition(
            user2AccountId,  // toAccountId
            tokenId,         // tokenId (0)
            transferAmount,  // amount (20% of notional)
            nonce,           // nonce
            deadline,        // deadline
            signature        // toSignature (User 2's signature)
        );

        vm.stopBroadcast();

        // Verify the transfer
        uint256 user1NewBalance = instrument.balanceOf(user1Addr, tokenId);
        uint256 user2NewBalance = instrument.balanceOf(user2Addr, tokenId);

        console.log("\n========================================");
        console.log("SUCCESS: Position transferred successfully!");
        console.log("========================================");
        console.log("Position Transfer Summary:");
        console.log("  Token ID:", tokenId);
        console.log("  Amount Transferred:", transferAmount);
        console.log("  User 1 Old Balance:", user1Balance);
        console.log("  User 1 New Balance:", user1NewBalance);
        console.log("  User 2 Old Balance: 0");
        console.log("  User 2 New Balance:", user2NewBalance);
        console.log("========================================");
    }
}