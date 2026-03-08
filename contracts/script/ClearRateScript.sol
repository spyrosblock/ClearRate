// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @title ClearRateScript
/// @notice Base contract for ClearRate deployment scripts with common utilities.
/// @dev Configuration is read from environment variables or uses defaults for testnet.
abstract contract ClearRateScript is Script {
    // ─── Configuration ──────────────────────────────────────────────────

    /// @notice Default accepted tokens array for margin vaults.
    address[] internal acceptedTokens;

    /// @notice Default tenors for yield curve oracle (in seconds).
    uint256[] internal defaultTenors;

    // ─── Chainlink Forwarder ─────────────────────────────────────────────
    /// @notice Chainlink Forwarder address for CRE reports on Ethereum Sepolia
    address internal constant CHAINLINK_ETHEREUM_SEPOLIA_FORWARDER = address(0x15fC6ae953E024d975e77382eEeC56A9101f9F88);


    // ─── Initialization ─────────────────────────────────────────────────

    constructor() {
        // Add mock collateral token for testing from .env
        string memory mockTokenStr = vm.envString("MOCK_COLLATERAL_TOKEN");
        address mockToken = _parseAddress(mockTokenStr);
        if (mockToken != address(0)) {
            acceptedTokens.push(mockToken);
        }
        // Note: USDT and DAI would need to be added here for mainnet

        // Initialize default tenors (1M, 3M, 6M, 1Y, 2Y, 3Y, 5Y, 7Y, 10Y, 30Y)
        defaultTenors.push(30 days);    // 1M
        defaultTenors.push(90 days);     // 3M
        defaultTenors.push(180 days);    // 6M
        defaultTenors.push(365 days);    // 1Y
        defaultTenors.push(730 days);    // 2Y
        defaultTenors.push(1095 days);   // 3Y
        defaultTenors.push(1825 days);   // 5Y
        defaultTenors.push(3650 days);   // 10Y
        defaultTenors.push(10950 days);  // 30Y
    }

    // ─── Helper Functions ───────────────────────────────────────────────

    /// @notice Get the deployer address from the PRIVATE_KEY or DEPLOYER_PRIVATE_KEY environment variable.
    /// @return deployer The deployer address derived from the private key.
    function getDeployer() internal view returns (address deployer) {
        // Try to read DEPLOYER_PRIVATE_KEY from environment (from .env file)
        string memory privateKeyStr = vm.envString("DEPLOYER_PRIVATE_KEY");
        
        // Remove "0x" prefix if present
        if (bytes(privateKeyStr).length >= 2) {
            bytes memory prefix = bytes(privateKeyStr);
            if (prefix[0] == 0x30 && prefix[1] == 0x78) {
                privateKeyStr = _substring(privateKeyStr, 2, bytes(privateKeyStr).length);
            }
        }
        
        // Convert hex string to uint256
        uint256 privateKey = _parseHex(privateKeyStr);
        deployer = vm.addr(privateKey);
        
        if (deployer == address(0)) {
            // Fallback to msg.sender if we can't derive from env
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
                continue; // Skip non-hex characters
            }
            result = result * 16 + digit;
        }
        return result;
    }

    /// @dev Helper to parse address from hex string
    function _parseAddress(string memory addrStr) internal pure returns (address) {
        // Remove "0x" prefix if present
        string memory hexStr = addrStr;
        if (bytes(hexStr).length >= 2) {
            bytes memory prefix = bytes(hexStr);
            if (prefix[0] == 0x30 && prefix[1] == 0x78) {
                hexStr = _substring(hexStr, 2, bytes(hexStr).length);
            }
        }
        
        uint256 addrUint = _parseHex(hexStr);
        return address(uint160(addrUint));
    }

    /// @notice Get accepted tokens for the protocol.
    /// @return tokens Array of accepted token addresses.
    function getAcceptedTokens() internal view returns (address[] memory tokens) {
        return acceptedTokens;
    }

    /// @notice Get the Chainlink Forwarder address for CRE reports.
    /// @return The forwarder address.
    function getChainlinkForwarder() internal pure returns (address) {
        return CHAINLINK_ETHEREUM_SEPOLIA_FORWARDER;
    }

    /// @notice Log a deployed contract address.
    /// @param name_ The contract name.
    /// @param addr_ The deployed address.
    function logDeployment(string memory name_, address addr_) internal pure {
        console.log(string(abi.encodePacked("Deployed ", name_, " at: ")));
        console.logAddress(addr_);
    }

    /// @notice Log all deployed contract addresses at the end.
    /// @param names_ Array of contract names.
    /// @param addrs_ Array of deployed addresses.
    function logAllDeployments(
        string[] memory names_,
        address[] memory addrs_,
        string[] memory envVars_
    ) internal pure {
        console.log("\n=== ClearRate Deployment Summary ===");
        for (uint256 i; i < names_.length; ++i) {
            console.log(names_[i]);
            console.log(string(abi.encodePacked(envVars_[i], "=0x", toAsciiString(addrs_[i]))));
        }
        console.log("=====================================\n");
    }

    function toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint(uint160(x)) / (2**(8*(19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2*i] = char(hi);
            s[2*i+1] = char(lo);            
        }
        return string(s);
    }

    function char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }
}
