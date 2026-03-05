import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Path to .env file (contracts/.env)
const envPath = path.join(__dirname, "..", ".env");

// Path to project root (where workflow directories are)
const projectRoot = path.join(__dirname, "..", "..");

// Mapping of workflow config files to their address requirements
// Format: [env variable name, config json key]
const workflowConfigs = {
    "create-trade-workflow": [
        ["CLEARING_HOUSE_ADDRESS", "clearingHouseAddress"],
    ],
    "liquidation-workflow": [
        ["LIQUIDATION_ENGINE_ADDRESS", "liquidationEngineAddress"],
    ],
    "settle-vm-workflow": [
        ["CLEARING_HOUSE_ADDRESS", "clearingHouseAddress"],
    ],
    "store-logs-workflow": [
        ["CLEARING_HOUSE_ADDRESS", "clearingHouseAddress"],
        ["MARGIN_VAULT_ADDRESS", "marginVaultAddress"],
        ["RISK_ENGINE_ADDRESS", "riskEngineAddress"],
        ["LIQUIDATION_ENGINE_ADDRESS", "liquidationEngineAddress"]
    ],
    "whitelist-user-workflow": [
        ["WHITELIST_ADDRESS", "whitelistAddress"],
    ],
};

// Mapping of final-config files to their address requirements
// These are processed in addition to the regular config files
// Format: [workflow directory, [env variable name, config json key]]
const finalConfigMappings = [
    ["settle-vm-workflow", [
        ["CLEARING_HOUSE_ADDRESS", "clearingHouseAddress"],
    ]],
];

/**
 * Parse .env file and extract key-value pairs
 */
function parseEnvFile(filePath) {
    if (!fs.existsSync(filePath)) {
        console.error(`Error: .env file not found at ${filePath}`);
        process.exit(1);
    }

    const envContent = fs.readFileSync(filePath, "utf8");
    const envVars = {};

    envContent.split("\n").forEach((line) => {
        const trimmedLine = line.trim();
        // Skip empty lines and comments
        if (!trimmedLine || trimmedLine.startsWith("#")) {
            return;
        }

        const equalIndex = trimmedLine.indexOf("=");
        if (equalIndex > 0) {
            const key = trimmedLine.substring(0, equalIndex).trim();
            let value = trimmedLine.substring(equalIndex + 1).trim();
            
            // Remove quotes if present
            if ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'"))) {
                value = value.slice(1, -1);
            }
            
            envVars[key] = value;
        }
    });

    return envVars;
}

/**
 * Update a config.json file with new addresses
 */
function updateConfigFile(configPath, addressMappings, envVars) {
    if (!fs.existsSync(configPath)) {
        console.warn(`Warning: Config file not found at ${configPath}`);
        return false;
    }

    const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
    let updated = false;

    // Update addresses in the evms array
    if (config.evms && Array.isArray(config.evms)) {
        config.evms.forEach((evmConfig) => {
            addressMappings.forEach(([envKey, configKey]) => {
                if (envVars[envKey]) {
                    if (evmConfig[configKey] !== envVars[envKey]) {
                        console.log(`  Updating ${configKey}: ${evmConfig[configKey] || "(not set)"} -> ${envVars[envKey]}`);
                        evmConfig[configKey] = envVars[envKey];
                        updated = true;
                    } else {
                        console.log(`  ${configKey} already up to date: ${envVars[envKey]}`);
                    }
                } else {
                    console.warn(`  Warning: ${envKey} not found in .env file`);
                }
            });
        });
    }

    if (updated) {
        fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
        console.log(`  Saved: ${configPath}`);
    }

    return updated;
}

/**
 * Main function
 */
function main() {
    console.log("=== Update Config Addresses Script ===\n");
    
    // Parse .env file
    console.log(`Reading .env from: ${envPath}`);
    const envVars = parseEnvFile(envPath);
    console.log(`Found ${Object.keys(envVars).length} environment variables\n`);

    // Process each workflow
    let totalUpdated = 0;
    
    for (const [workflow, addressMappings] of Object.entries(workflowConfigs)) {
        console.log(`\nProcessing: ${workflow}`);
        const configPath = path.join(projectRoot, workflow, "config.staging.json");
        
        if (updateConfigFile(configPath, addressMappings, envVars)) {
            totalUpdated++;
        }
    }

    // Process final-config files
    for (const [workflow, addressMappings] of finalConfigMappings) {
        console.log(`\nProcessing final-config: ${workflow}`);
        const configPath = path.join(projectRoot, workflow, "final-config.staging.json");
        
        if (updateConfigFile(configPath, addressMappings, envVars)) {
            totalUpdated++;
        }
    }

    console.log(`\n=== Complete: ${totalUpdated} config file(s) updated ===`);
}

main();