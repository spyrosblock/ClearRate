.PHONY: build clean test install fork-anvil help \
	deploy-hub-sepolia deploy-hub-sepolia-sim deploy-hub-anvil \
	deploy-spoke-base-sepolia deploy-spoke-arb-sepolia \
	verify-hub verify-spoke \
	extract-abis snapshot

# ============================================
# DEFAULT TARGET
# ============================================
help:
	@echo "ClearRate - Onchain CCP for Interest Rate Swaps"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "=== Development ==="
	@echo "  install            Install dependencies"
	@echo "  build              Compile contracts"
	@echo "  test               Run all tests"
	@echo "  test-sepolia       Run tests with Sepolia fork"
	@echo "  fork-anvil         Start anvil forked from Sepolia"
	@echo "  snapshot           Generate gas snapshot"
	@echo "  extract-abis       Extract ABIs for TypeScript"
	@echo ""
	@echo "=== Hub Deployment (Ethereum Sepolia) ==="
	@echo "  deploy-hub-sepolia          Deploy hub contracts to Sepolia (broadcast)"
	@echo "  deploy-hub-sepolia-sim      Simulate hub deployment (no broadcast)"
	@echo "  deploy-hub-anvil            Deploy hub contracts to local anvil"
	@echo ""
	@echo "=== Spoke Deployment (L2 Testnets) ==="
	@echo "  deploy-spoke-base-sepolia   Deploy spoke contracts to Base Sepolia"
	@echo "  deploy-spoke-arb-sepolia    Deploy spoke contracts to Arbitrum Sepolia"
	@echo ""
	@echo "=== Verification ==="
	@echo "  verify-hub          Verify hub contracts on Etherscan"
	@echo "  verify-spoke        Verify spoke contracts on block explorers"
	@echo ""
	@echo "=== Environment ==="
	@echo "  Requires: ETH_RPC_URL, ETH_KEYSTORE_ACCOUNT, ETHERSCAN_API_KEY"
	@echo "  Or set them in .env file"
	@echo ""

# ============================================
# INSTALLATION & BUILD
# ============================================

install:
	forge install

build:
	forge build

clean:
	forge clean

# ============================================
# TESTING
# ============================================

test:
	forge test -vv

test-sepolia:
	forge test --fork-url $(ETH_RPC_URL) --via-ir -vv

fork-anvil:
	anvil --fork-url $(ETH_RPC_URL) --chain-id 31337

snapshot:
	forge snapshot

# ============================================
# HUB DEPLOYMENT (Ethereum Sepolia)
# ============================================

# Deploy hub contracts to Sepolia (requires broadcast)
deploy-hub-sepolia:
	@echo "Deploying Hub contracts to Ethereum Sepolia..."
	forge script script/DeployHub.s.sol:DeployHub \
		--rpc-url $(ETH_RPC_URL) \
		--account $(ETH_KEYSTORE_ACCOUNT) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api \
		--optimizer-runs 200 \
		--via-ir \
		-vv

# Simulate hub deployment (no broadcast)
deploy-hub-sepolia-sim:
	@echo "Simulating Hub deployment to Ethereum Sepolia..."
	forge script script/DeployHub.s.sol:DeployHub \
		--rpc-url $(ETH_RPC_URL) \
		--account $(ETH_KEYSTORE_ACCOUNT) \
		--simulate \
		-vvvv

# Deploy to local anvil for testing
deploy-hub-anvil:
	@echo "Deploying Hub contracts to local anvil..."
	forge script script/DeployHub.s.sol:DeployHub \
		--rpc-url http://localhost:8545 \
		--account deployer \
		--broadcast \
		-vvv

# ============================================
# SPOKE DEPLOYMENT (L2 Testnets)
# ============================================

# Deploy spoke contracts to Base Sepolia
# Requires HUB_GATEWAY_ADDRESS to be set (from hub deployment)
deploy-spoke-base-sepolia:
	@echo "Deploying Spoke contracts to Base Sepolia..."
	forge script script/DeploySpokes.s.sol:DeploySpokes --sig "runBaseSepolia(address)" $(HUB_GATEWAY_ADDRESS) \
		--rpc-url base_sepolia \
		--account $(ETH_KEYSTORE_ACCOUNT) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.basescan.org/api \
		--optimizer-runs 200 \
		--via-ir \
		-vv

# Deploy spoke contracts to Arbitrum Sepolia
deploy-spoke-arb-sepolia:
	@echo "Deploying Spoke contracts to Arbitrum Sepolia..."
	forge script script/DeploySpokes.s.sol:DeploySpokes --sig "runArbitrumSepolia(address)" $(HUB_GATEWAY_ADDRESS) \
		--rpc-url arbitrum_sepolia \
		--account $(ETH_KEYSTORE_ACCOUNT) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ARBISCAN_API_KEY) \
		--verifier-url https://api-sepolia.arbiscan.io/api \
		--optimizer-runs 200 \
		--via-ir \
		-vv

# ============================================
# VERIFICATION
# ============================================

verify-hub:
	@echo "Verifying Hub contracts on Etherscan..."
	forge verify-contract <WHITELIST_ADDRESS> src/access/Whitelist.sol:Whitelist \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <GLOBAL_MARGIN_VAULT_ADDRESS> src/margin/GlobalMarginVault.sol:GlobalMarginVault \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <RISK_ENGINE_ADDRESS> src/margin/RiskEngine.sol:RiskEngine \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <YIELD_CURVE_ORACLE_ADDRESS> src/oracles/YieldCurveOracle.sol:YieldCurveOracle \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <IRS_INSTRUMENT_ADDRESS> src/core/IRSInstrument.sol:IRSInstrument \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <CLEARING_HOUSE_ADDRESS> src/core/ClearingHouse.sol:ClearingHouse \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <INSURANCE_FUND_ADDRESS> src/insurance/InsuranceFund.sol:InsuranceFund \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api
	forge verify-contract <LIQUIDATION_ENGINE_ADDRESS> src/liquidation/LiquidationEngine.sol:LiquidationEngine \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.etherscan.io/api

verify-spoke:
	@echo "Verifying Spoke contracts..."
	@echo "Note: Replace addresses with actual deployed contract addresses"
	forge verify-contract <LOCAL_MARGIN_VAULT_ADDRESS> src/margin/LocalMarginVault.sol:LocalMarginVault \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.basescan.org/api
	forge verify-contract <CCIP_SPOKE_GATEWAY_ADDRESS> src/crosschain/CCIPSpokeGateway.sol:CCIPSpokeGateway \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api-sepolia.basescan.org/api

# ============================================
# ABI EXTRACTION
# ============================================

extract-abis:
	node scripts-js/extractAbis.js

# ============================================
# ENVIRONMENT
# ============================================

-include .env
