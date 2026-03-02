/**
 * Generate whitelist user input JSON files from .env configuration
 * 
 * This script reads user configuration from .env file and generates
 * JSON files in the format required by whitelist-user-workflow
 * 
 * Usage: node generateWhitelistInputs.js
 */

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

// ─── Generate Company Information ─────────────────────────────────────

function generateCompanyInfo(userNumber) {
  if (userNumber === 1) {
    return {
      companyName: "TechCorp Solutions",
      registrationNumber: "TC123456789",
      registeredCountry: "DE",
      contactEmail: "contact@techcorp.com",
      lei: "549300KHAXQ1P3T4GJ31"
    };
  } else {
    return {
      companyName: "Jane Johnson",
      registrationNumber: "JJ123456789",
      registeredCountry: "CA",
      contactEmail: "jane.johnson@example.com",
      lei: "549300123456789012"
    };
  }
}

// ─── Main ─────────────────────────────────────────────────────────────

async function main() {
  // Import ethers only if needed (for accountId formatting)
  let ethers;
  try {
    ethers = await import("ethers");
  } catch (e) {
    console.warn("ethers library not found, using simple padding for account ID formatting");
  }
  
  const env = loadEnv();
  
  // Define users to process
  const users = [
    {
      number: 1,
      address: env.USER1_ADDRESS,
      accountId: env.USER1_ACCOUNT_ID,
      privateKey: env.USER1_PRIVATE_KEY
    },
    {
      number: 2,
      address: env.USER2_ADDRESS,
      accountId: env.USER2_ACCOUNT_ID,
      privateKey: env.USER2_PRIVATE_KEY
    }
  ];
  
  // Filter out users that don't have all required fields
  const validUsers = users.filter(user => 
    user.address && user.accountId && user.privateKey
  );
  
  if (validUsers.length === 0) {
    console.error("No valid users found in .env file. Please ensure USER1 and/or USER2 configuration is complete.");
    process.exit(1);
  }
  
  console.log(`Generating whitelist input files for ${validUsers.length} user(s)...`);
  
  // Create output directory if it doesn't exist
  const outputDir = path.join(__dirname, "payloads");
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
    console.log(`Created directory: ${outputDir}`);
  }
  
  // Generate JSON files for each user
  validUsers.forEach((user, index) => {
    const companyInfo = generateCompanyInfo(user.number);
    
    // Convert account ID to bytes32 format (same as generateTradeInputs.js)
    const accountId = ethers ? 
      ethers.zeroPadValue(ethers.toBeHex(parseInt(user.accountId)), 32) :
      "0x" + user.accountId.padStart(64, "0");
    
    const userData = {
      address: user.address,
      company: companyInfo
    };
    
    // Generate filename (user_1.json, user_2.json, etc.)
    const filename = `user_${index + 1}.json`;
    const outputPath = path.join(outputDir, filename);
    
    fs.writeFileSync(outputPath, JSON.stringify(userData, null, 2));
    console.log(`✓ Generated ${filename} for user ${user.number}`);
    console.log(`  Address: ${user.address}`);
    console.log(`  Account ID: ${accountId}`);
    console.log(`  Company: ${companyInfo.companyName}`);
    console.log(`  Contact Email: ${companyInfo.contactEmail}`);
    console.log(`  Country: ${companyInfo.registeredCountry}`);
    console.log("");
  });
  
  console.log(`Successfully generated ${validUsers.length} whitelist input file(s) in ${outputDir}`);
}

main().catch(console.error);