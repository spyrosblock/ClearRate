// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {ClearRateScript} from "./ClearRateScript.sol";
import {Whitelist} from "../src/access/Whitelist.sol";
import {MarginVault} from "../src/margin/MarginVault.sol";
import {RiskEngine} from "../src/margin/RiskEngine.sol";
import {IRSInstrument} from "../src/core/IRSInstrument.sol";
import {ClearingHouse} from "../src/core/ClearingHouse.sol";
import {InsuranceFund} from "../src/insurance/InsuranceFund.sol";
import {LiquidationEngine} from "../src/liquidation/LiquidationEngine.sol";

/// @title Deploy
/// @notice Deployment script for the ClearRate protocol on Ethereum Sepolia.
/// @dev Run with: forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
///
/// Deployment order:
/// 1. Whitelist - KYC/governance-controlled address registry
/// 2. MarginVault - Margin ledger
/// 3. RiskEngine - IM/MM validation
/// 4. YieldCurveOracle - Discount factor oracle
/// 5. IRSInstrument - ERC-1155 position tokens
/// 6. ClearingHouse - Trade novation and coordination
/// 7. InsuranceFund - Backstop capital
/// 8. LiquidationEngine - Dutch auction liquidations
contract Deploy is ClearRateScript {
    // ─── Role Constants ─────────────────────────────────────────────────
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 internal constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");
    bytes32 internal constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");
    bytes32 internal constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");
    bytes32 internal constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 internal constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    // ─── Risk Parameters ───────────────────────────────────────────────
    uint256 internal constant CONFIDENCE_BPS = 9900;
    uint256 internal constant MM_RATIO_BPS = 7500;

    // ─── Oracle Parameters ─────────────────────────────────────────────
    uint256 internal constant MAX_STALENESS = 1 days;

    // ─── Liquidation Parameters ────────────────────────────────────────
    uint256 internal constant AUCTION_DURATION = 1 hours;
    uint256 internal constant START_PREMIUM_BPS = 500;

    /// @notice Main entry point for deployment.
    function run() external {
        address deployer = getDeployer();

        console.log("========================================");
        console.log("ClearRate Protocol Deployment (Ethereum Sepolia)");
        console.log("========================================");
        console.log("Deployer:");
        console.logAddress(deployer);

        address[] memory tokens = getAcceptedTokens();
        uint256[] memory tenors = new uint256[](defaultTenors.length);
        for (uint256 i; i < defaultTenors.length; ++i) {
            tenors[i] = defaultTenors[i];
        }

        // Start broadcasting all transactions from deployer
        vm.startBroadcast(deployer);

        // 1. Deploy Whitelist
        console.log("\n[1/7] Deploying Whitelist...");
        Whitelist whitelist = new Whitelist(deployer, getChainlinkForwarder());
        logDeployment("Whitelist", address(whitelist));

        // 2. Deploy MarginVault
        console.log("\n[2/7] Deploying MarginVault...");
        MarginVault marginVault = new MarginVault(deployer, address(whitelist), tokens);
        logDeployment("MarginVault", address(marginVault));

        // 3. Deploy RiskEngine
        console.log("\n[3/7] Deploying RiskEngine...");
        RiskEngine riskEngine = new RiskEngine(
            deployer,
            address(marginVault),
            CONFIDENCE_BPS,
            MM_RATIO_BPS
        );
        logDeployment("RiskEngine", address(riskEngine));

        // 4. Deploy IRSInstrument
        console.log("\n[4/7] Deploying IRSInstrument...");
        IRSInstrument instrument = new IRSInstrument(
            deployer,
            "https://metadata.clearrate.io/{id}.json"
        );
        logDeployment("IRSInstrument", address(instrument));

        // 5. Deploy ClearingHouse
        console.log("\n[5/7] Deploying ClearingHouse...");
        ClearingHouse clearingHouse = new ClearingHouse(
            deployer,
            getChainlinkForwarder(),
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist)
        );
        logDeployment("ClearingHouse", address(clearingHouse));

        // 6. Deploy InsuranceFund
        console.log("\n[6/7] Deploying InsuranceFund...");
        InsuranceFund insuranceFund = new InsuranceFund(deployer, tokens);
        logDeployment("InsuranceFund", address(insuranceFund));

        // 7. Deploy LiquidationEngine
        console.log("\n[7/7] Deploying LiquidationEngine...");
        LiquidationEngine liquidationEngine = new LiquidationEngine(
            deployer,
            address(riskEngine),
            address(marginVault),
            address(insuranceFund),
            AUCTION_DURATION,
            START_PREMIUM_BPS
        );
        logDeployment("LiquidationEngine", address(liquidationEngine));

        // ═══════════════════════════════════════════════════════════════
        //  WIRE UP ROLES AND PERMISSIONS
        // ═══════════════════════════════════════════════════════════════

        console.log("\n========================================");
        console.log("Configuring Roles & Permissions...");
        console.log("========================================\n");

        // Grant ClearingHouse roles to MarginVault
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        console.log("- Granted CLEARING_HOUSE_ROLE to ClearingHouse on MarginVault");

        // Grant roles to IRSInstrument
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        console.log("- Granted CLEARING_HOUSE_ROLE to ClearingHouse on IRSInstrument");

        // Grant roles to RiskEngine
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        riskEngine.grantRole(RISK_ADMIN_ROLE, deployer);
        console.log("- Granted CLEARING_HOUSE_ROLE to ClearingHouse on RiskEngine");

        // Grant roles to InsuranceFund
        insuranceFund.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        insuranceFund.grantRole(FUND_MANAGER_ROLE, deployer);
        console.log("- Granted CLEARING_HOUSE_ROLE to ClearingHouse on InsuranceFund");

        // Grant roles to LiquidationEngine
        liquidationEngine.grantRole(LIQUIDATOR_ROLE, deployer);
        console.log("- Granted LIQUIDATOR_ROLE to deployer on LiquidationEngine");

        // Grant roles to Whitelist
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, deployer);
        console.log("- Granted WHITELIST_ADMIN_ROLE to deployer on Whitelist");
        whitelist.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        console.log("- Granted CLEARING_HOUSE_ROLE to ClearingHouse on Whitelist");

        // Set default risk weights
        _setDefaultRiskWeights(riskEngine);

        vm.stopBroadcast();

        console.log("Roles configured successfully!");

        // ═══════════════════════════════════════════════════════════════
        //  DEPLOYMENT SUMMARY
        // ═══════════════════════════════════════════════════════════════

        string[] memory names = new string[](7);
        address[] memory addrs = new address[](7);

        names[0] = "Whitelist";
        addrs[0] = address(whitelist);
        names[1] = "MarginVault";
        addrs[1] = address(marginVault);
        names[2] = "RiskEngine";
        addrs[2] = address(riskEngine);
        names[3] = "IRSInstrument";
        addrs[3] = address(instrument);
        names[4] = "ClearingHouse";
        addrs[4] = address(clearingHouse);
        names[5] = "InsuranceFund";
        addrs[5] = address(insuranceFund);
        names[6] = "LiquidationEngine";
        addrs[6] = address(liquidationEngine);

        logAllDeployments(names, addrs);

        console.log("Protocol deployment complete!");
    }

    function _setDefaultRiskWeights(RiskEngine riskEngine) internal {
        riskEngine.setRiskWeight(30 days, 50);
        console.log("- Set risk weight for 30 days: 50 BPS");
        riskEngine.setRiskWeight(90 days, 100);
        console.log("- Set risk weight for 90 days: 100 BPS");
        riskEngine.setRiskWeight(180 days, 150);
        console.log("- Set risk weight for 180 days: 150 BPS");
        riskEngine.setRiskWeight(365 days, 200);
        console.log("- Set risk weight for 365 days: 200 BPS");
        riskEngine.setRiskWeight(730 days, 250);
        console.log("- Set risk weight for 730 days: 250 BPS");
        riskEngine.setRiskWeight(1825 days, 400);
        console.log("- Set risk weight for 1825 days: 400 BPS");
        riskEngine.setRiskWeight(3650 days, 600);
        console.log("- Set risk weight for 3650 days: 600 BPS");
        console.log("Default risk weights configured");
    }

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
