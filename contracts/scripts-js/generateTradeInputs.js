/**
 * Generate inputs for ClearingHouse.submitMatchedTrade()
 * 
 * This script creates:
 * 1. A MatchedTrade struct with all required fields
 * 2. EIP-712 signatures from both parties (partyA and partyB)
 * 
 * Configuration is loaded from .env file
 * Usage: node generateTradeInputs.js
 */

import { ethers } from "ethers";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ─── Load Configuration from .env ─────────────────────────────────────

function loadEnv() {
  const envPath = path.join(__dirname, "..", ".env");
  const envContent = fs.readFileSync(envPath, "utf8");
  
  const config = {};
  envContent.split("\n").forEach(line => {
    const trimmed = line.trim();
    if (trimmed && !trimmed.startsWith("#")) {
      const [key, ...valueParts] = trimmed.split("=");
      if (key && valueParts.length > 0) {
        config[key] = valueParts.join("=").trim();
      }
    }
  });
  
  return config;
}

const env = loadEnv();

// ─── Get Network Chain ID ─────────────────────────────────────────────

async function getChainId() {
  const provider = new ethers.JsonRpcProvider(
    "https://eth-sepolia.g.alchemy.com/v2/" + env.ALCHEMY_API_KEY
  );
  const network = await provider.getNetwork();
  // network.chainId is a BigInt, convert to number
  return Number(network.chainId);
}

// ─── Main ─────────────────────────────────────────────────────────────

async function main() {
  // Get the actual chainId from the network
  const chainId = await getChainId();
  console.log("Using chainId:", chainId);

  // Domain separator for EIP-712 (using ethers' built-in TypedDataEncoder for correct hashing)
  const domain = {
    name: "ClearRate CCP",
    version: "1",
    chainId: chainId,
    verifyingContract: env.CLEARING_HOUSE_ADDRESS
  };

  // MatchedTrade type definition for EIP-712
  const types = {
    MatchedTrade: [
      { name: "tradeId", type: "bytes32" },
      { name: "partyA", type: "bytes32" },
      { name: "partyB", type: "bytes32" },
      { name: "notional", type: "uint256" },
      { name: "fixedRateBps", type: "uint256" },
      { name: "startDate", type: "uint256" },
      { name: "maturityDate", type: "uint256" },
      { name: "paymentInterval", type: "uint256" },
      { name: "dayCountConvention", type: "uint8" },
      { name: "floatingRateIndex", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" }
    ]
  };

  // ─── Trade Parameters ────────────────────────────────────────────────

  // Generate unique trade ID
  const tradeId = ethers.keccak256(ethers.randomBytes(32));

  // Account IDs (bytes32 format) - Must match exactly how Solidity stores them
  // WhitelistUsers.s.sol uses: bytes32(vm.envUint("USER1_ACCOUNT_ID"))
  // So we convert the numeric string to bytes32 directly, NOT keccak256
  const partyA = ethers.zeroPadValue(ethers.toBeHex(parseInt(env.USER1_ACCOUNT_ID || "1")), 32);
  const partyB = ethers.zeroPadValue(ethers.toBeHex(parseInt(env.USER2_ACCOUNT_ID || "2")), 32);

  // Trade terms
  const notional = ethers.parseEther("1000000"); // 1,000,000 USDC
  const fixedRateBps = 350; // 3.50% annual fixed rate

  // Timestamps (using realistic dates)
  const startDate = Math.floor(Date.now() / 1000) + 86400; // Tomorrow
  const maturityDate = startDate + 365 * 24 * 60 * 60; // 1 year

  // Payment every 3 months (90 days in seconds)
  const paymentInterval = 90 * 24 * 60 * 60;

  // Day count convention: 0 = ACT/360, 1 = 30/360, etc.
  const dayCountConvention = 0; // ACT/360

  // Floating rate index (SOFR)
  const floatingRateIndex = ethers.keccak256(ethers.toUtf8Bytes("SOFR"));

  // Nonce for replay protection
  const nonce = 1;

  // Deadline for signature validity (24 hours from startDate)
  const deadline = startDate + 24 * 60 * 60;

  // ─── Build the Trade Struct ───────────────────────────────────────────

  const matchedTrade = {
    tradeId,
    partyA,
    partyB,
    notional: notional.toString(),
    fixedRateBps,
    startDate,
    maturityDate,
    paymentInterval,
    dayCountConvention,
    floatingRateIndex,
    nonce,
    deadline
  };

  // ─── Generate Signatures ─────────────────────────────────────────────

  // Private keys from .env file
  const privateKeyA = env.USER1_PRIVATE_KEY;
  const privateKeyB = env.USER2_PRIVATE_KEY;

  // Create wallets
  const walletA = new ethers.Wallet(privateKeyA);
  const walletB = new ethers.Wallet(privateKeyB);

  // Generate EIP-712 signatures using ethers' built-in TypedDataEncoder
  // This ensures exact compatibility with Solidity's EIP712 implementation
  const sigA = await walletA.signTypedData(domain, types, matchedTrade);
  const sigB = await walletB.signTypedData(domain, types, matchedTrade);

  // ─── Output ───────────────────────────────────────────────────────────

  const output = {
    // The MatchedTrade struct
    trade: {
      tradeId: matchedTrade.tradeId,
      partyA: matchedTrade.partyA,
      partyB: matchedTrade.partyB,
      notional: matchedTrade.notional,
      fixedRateBps: matchedTrade.fixedRateBps,
      startDate: matchedTrade.startDate,
      maturityDate: matchedTrade.maturityDate,
      paymentInterval: matchedTrade.paymentInterval,
      dayCountConvention: matchedTrade.dayCountConvention,
      floatingRateIndex: matchedTrade.floatingRateIndex,
      nonce: matchedTrade.nonce,
      deadline: matchedTrade.deadline
    },
    
    // EIP-712 signatures
    sigA,
    sigB,
    
    // Metadata
    metadata: {
      notionalFormatted: ethers.formatEther(matchedTrade.notional) + " USDC",
      fixedRateFormatted: (matchedTrade.fixedRateBps / 100).toFixed(2) + "%",
      tenorDays: Math.floor((matchedTrade.maturityDate - matchedTrade.startDate) / (24 * 60 * 60)),
      paymentIntervalDays: Math.floor(matchedTrade.paymentInterval / (24 * 60 * 60)),
      partyAFormatted: matchedTrade.partyA,
      partyBFormatted: matchedTrade.partyB
    }
  };

  // Store the result in a trade.json file
  const outputPath = path.join(__dirname, "trade.json");
  fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));
  console.log(`Trade inputs saved to ${outputPath}`);
  console.log(JSON.stringify(output, null, 2));
}

main().catch(console.error);
