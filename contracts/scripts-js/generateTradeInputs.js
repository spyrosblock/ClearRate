/**
 * Generate inputs for ClearingHouse.submitMatchedTrade()
 * 
 * This script creates:
 * 1. A MatchedTrade struct with all required fields
 * 2. EIP-712 signatures from both parties (partyA and partyB)
 * 
 * Usage: node generateTradeInputs.js
 */

const { ethers } = require("ethers");

// ─── Configuration ─────────────────────────────────────────────────────

// Domain separator for EIP-712
const DOMAIN = {
  name: "ClearRate CCP",
  version: "1",
  chainId: 11155111, // Sepolia
  verifyingContract: "0x0000000000000000000000000000000000000001" // Placeholder - replace with actual ClearingHouse address
};

// MatchedTrade type definition for EIP-712
const TYPE_HASH = ethers.keccak256(
  ethers.toUtf8Bytes(
    "MatchedTrade(bytes32 tradeId,bytes32 partyA,bytes32 partyB,uint256 notional,uint256 fixedRateBps,uint256 startDate,uint256 maturityDate,uint256 paymentInterval,uint8 dayCountConvention,bytes32 floatingRateIndex,uint256 nonce,uint256 deadline)"
  )
);

// ─── Trade Parameters ────────────────────────────────────────────────

// Generate unique trade ID
const tradeId = ethers.keccak256(ethers.randomBytes(32));

// Account IDs (bytes32 format)
const partyA = ethers.keccak256(ethers.toUtf8Bytes("ACCOUNT_A"));
const partyB = ethers.keccak256(ethers.toUtf8Bytes("ACCOUNT_B"));

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

// ─── EIP-712 Signing Helpers ─────────────────────────────────────────

/**
 * Compute the struct hash for a MatchedTrade
 */
function getStructHash(trade) {
  return ethers.keccak256(
    ethers.concat([
      TYPE_HASH,
      trade.tradeId,
      trade.partyA,
      trade.partyB,
      ethers.zeroPadValue(ethers.toBeHex(trade.notional), 32),
      ethers.zeroPadValue(ethers.toBeHex(trade.fixedRateBps), 32),
      ethers.zeroPadValue(ethers.toBeHex(trade.startDate), 32),
      ethers.zeroPadValue(ethers.toBeHex(trade.maturityDate), 32),
      ethers.zeroPadValue(ethers.toBeHex(trade.paymentInterval), 32),
      ethers.zeroPadValue(ethers.toBeHex(trade.dayCountConvention), 32),
      trade.floatingRateIndex,
      ethers.zeroPadValue(ethers.toBeHex(trade.nonce), 32),
      ethers.zeroPadValue(ethers.toBeHex(trade.deadline), 32)
    ])
  );
}

/**
 * Compute the domain separator
 */
function getDomainSeparator(domain) {
  return ethers.keccak256(
    ethers.concat([
      ethers.toUtf8Bytes(
        "\x19\x01" +
        domain.name +
        "\x00" +
        domain.version +
        "\x00"
      ),
      ethers.zeroPadValue(ethers.toBeHex(domain.chainId), 32),
      domain.verifyingContract
    ])
  );
}

/**
 * Compute EIP-712 digest
 */
function getTypedDataHash(trade, domain) {
  const domainSeparator = getDomainSeparator(domain);
  const structHash = getStructHash(trade);
  return ethers.keccak256(
    ethers.concat([
      ethers.toUtf8Bytes("\x19\x01"),
      domainSeparator,
      structHash
    ])
  );
}

/**
 * Sign a trade using a private key
 */
function signTrade(trade, privateKey, domain) {
  const messageHash = getTypedDataHash(trade, domain);
  const wallet = new ethers.Wallet(privateKey);
  const signature = wallet.signingKey.sign(messageHash);
  return ethers.Signature.from(signature).serialized;
}

// ─── Generate Signatures ─────────────────────────────────────────────

// Private keys for testing (DO NOT USE IN PRODUCTION)
// In production, these would be managed by the actual account owners
const privateKeyA = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // First Sepolia account
const privateKeyB = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // Second Sepolia account

// Generate signatures
const sigA = signTrade(matchedTrade, privateKeyA, DOMAIN);
const sigB = signTrade(matchedTrade, privateKeyB, DOMAIN);

// ─── Output ───────────────────────────────────────────────────────────

const output = {
  // The MatchedTrade struct (as Solidity calldata format)
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
  
  // Metadata for debugging
  metadata: {
    description: "Generated trade inputs for ClearingHouse.submitMatchedTrade()",
    tradeId: matchedTrade.tradeId,
    partyA: matchedTrade.partyA,
    partyB: matchedTrade.partyB,
    notionalFormatted: ethers.formatEther(matchedTrade.notional) + " USDC",
    fixedRateFormatted: (matchedTrade.fixedRateBps / 100).toFixed(2) + "%",
    tenorDays: Math.floor((matchedTrade.maturityDate - matchedTrade.startDate) / (24 * 60 * 60)),
    paymentIntervalDays: Math.floor(matchedTrade.paymentInterval / (24 * 60 * 60)),
    domain: DOMAIN
  },
  
  // Solidity function call format (for direct use in cast/forge)
  solidityCall: {
    function: "submitMatchedTrade((bytes32,bytes32,bytes32,uint256,uint256,uint256,uint256,uint256,uint8,bytes32,uint256,uint256),bytes,bytes)",
    params: [
      `(${matchedTrade.tradeId},${matchedTrade.partyA},${matchedTrade.partyB},${matchedTrade.notional},${matchedTrade.fixedRateBps},${matchedTrade.startDate},${matchedTrade.maturityDate},${matchedTrade.paymentInterval},${matchedTrade.dayCountConvention},${matchedTrade.floatingRateIndex},${matchedTrade.nonce},${matchedTrade.deadline})`,
      sigA,
      sigB
    ]
  }
};

console.log("\n" + "=".repeat(70));
console.log("CLEARINGHOUSE.SUBMITMATCHEDTRADE() INPUTS");
console.log("=".repeat(70) + "\n");

console.log("--- MATCHED TRADE STRUCT ---\n");
console.log(`tradeId:           ${matchedTrade.tradeId}`);
console.log(`partyA:            ${matchedTrade.partyA}`);
console.log(`partyB:            ${matchedTrade.partyB}`);
console.log(`notional:          ${matchedTrade.notional}`);
console.log(`fixedRateBps:      ${matchedTrade.fixedRateBps}`);
console.log(`startDate:         ${matchedTrade.startDate}`);
console.log(`maturityDate:      ${matchedTrade.maturityDate}`);
console.log(`paymentInterval:  ${matchedTrade.paymentInterval}`);
console.log(`dayCountConvention:${matchedTrade.dayCountConvention}`);
console.log(`floatingRateIndex:${matchedTrade.floatingRateIndex}`);
console.log(`nonce:             ${matchedTrade.nonce}`);
console.log(`deadline:          ${matchedTrade.deadline}`);

console.log("\n--- SIGNATURES ---\n");
console.log(`sigA: ${sigA}`);
console.log(`sigB: ${sigB}`);

console.log("\n--- METADATA ---\n");
console.log(`Notional:    ${output.metadata.notionalFormatted}`);
console.log(`Fixed Rate:  ${output.metadata.fixedRateFormatted}`);
console.log(`Tenor:       ${output.metadata.tenorDays} days`);
console.log(`Payments:   Every ${output.metadata.paymentIntervalDays} days`);

console.log("\n" + "=".repeat(70));
console.log("FULL JSON OUTPUT (for programmatic use):");
console.log("=".repeat(70) + "\n");

console.log(JSON.stringify(output, null, 2));

// Also write to file for convenience
const fs = require("fs");
fs.writeFileSync(
  "./tradeInputs.json",
  JSON.stringify(output, null, 2)
);
console.log("\n✓ Saved to tradeInputs.json");
