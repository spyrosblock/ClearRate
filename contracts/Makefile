.PHONY: build clean test install fork-anvil help \
	deploy-hub-sepolia deploy-hub-sepolia-sim deploy-hub-anvil \
	deploy-spoke-base-sepolia deploy-spoke-arb-sepolia \
	verify-hub verify-spoke \
	extract-abis snapshot

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
		--rpc-url sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api.etherscan.io/v2/api?chainid=11155111 \
		--optimizer-runs 200 \
		--via-ir \
		-vv

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
# Script automatically detects chain from RPC URL
deploy-spoke-base-sepolia:
	@echo "Deploying Spoke contracts to Base Sepolia..."
	@echo "Hub Gateway Address: $(HUB_GATEWAY_ADDRESS)"
	forge script script/DeploySpokes.s.sol:DeploySpokes --sig "run(address)" $(HUB_GATEWAY_ADDRESS) \
		--rpc-url base_sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api.etherscan.io/v2/api?chainid=84532 \
		--optimizer-runs 200 \
		--via-ir \
		-vv

# Deploy spoke contracts to Arbitrum Sepolia
deploy-spoke-arb-sepolia:
	@echo "Deploying Spoke contracts to Arbitrum Sepolia..."
	@echo "Hub Gateway Address: $(HUB_GATEWAY_ADDRESS)"
	forge script script/DeploySpokes.s.sol:DeploySpokes --sig "run(address)" $(HUB_GATEWAY_ADDRESS) \
		--rpc-url arbitrum_sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api.etherscan.io/v2/api?chainid=421614 \
		--optimizer-runs 200 \
		--via-ir \
		-vv

# Deploy all spokes (after hub deployment)
deploy-spokes: deploy-spoke-base-sepolia deploy-spoke-arb-sepolia
	@echo "Spoke deployments complete!"

# ============================================
# VERIFICATION
# ============================================

# Verify hub contracts on Etherscan
verify-hub-sepolia:
	@echo "Verifying Hub contracts on Etherscan..."
	forge verify-contract 0x618Cb68e0770eCAD5c8151e82be7bacaa64a27eb src/access/Whitelist.sol:Whitelist --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0x90c6ca51091fd0e090902aa20bc842392261363b src/margin/GlobalMarginVault.sol:GlobalMarginVault --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0xa9155f695f72ecbce362d65f70ec0fbb2e59ba5b src/margin/RiskEngine.sol:RiskEngine --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0x1d9418e725ef47f113030a0e5e915d40fc4a6992 src/oracles/YieldCurveOracle.sol:YieldCurveOracle --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0xd7bee027a96f23caedbe0fa3a72f0068ad8be6f7 src/core/IRSInstrument.sol:IRSInstrument --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0x535257bbda42c20417a140041a924af53b2d78fc src/core/ClearingHouse.sol:ClearingHouse --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0x3137bbf18bae9766e8bc8737f66a876c877c4abd src/insurance/InsuranceFund.sol:InsuranceFund --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111
	forge verify-contract 0xaa910ba9edca900bfa3af3bcc4ff815e1127fd31 src/liquidation/LiquidationEngine.sol:LiquidationEngine --etherscan-api-key $(ETHERSCAN_API_KEY) --verifier-url https://api.etherscan.io/v2/api?chainid=11155111

# ============================================
# ABI EXTRACTION
# ============================================

extract-abis:
	node scripts-js/extractAbis.js

# ============================================
# ENVIRONMENT
# ============================================

-include .env
