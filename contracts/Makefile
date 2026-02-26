.PHONY: build clean test install help \
	extract-abis format

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
	forge test --fork-url sepolia --via-ir -vv

# ============================================
# FORMATTING
# ============================================

format:
	forge fmt

# ============================================
# DEPLOYMENT (Ethereum Sepolia)
# ============================================

# Deploy contracts to Sepolia
deploy-contracts-sepolia:
	@echo "Deploying contracts to Ethereum Sepolia..."
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--verifier-url https://api.etherscan.io/v2/api?chainid=11155111 \
		--optimizer-runs 200 \
		--via-ir \
		-vv
	@echo "Update contracts/.env, create-trade-workflow/config.staging.json and settle-vm-workflow/config.staging.json with new addresses"


# ============================================
# WHITELIST USERS
# ============================================

# Whitelist 2 users on Sepolia
whitelist-users-sepolia:
	@echo "Whitelisting 2 users on Ethereum Sepolia..."
	@forge script script/WhitelistUsers.s.sol:WhitelistUsers \
		--rpc-url sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vv

# ============================================
# MARGIN DEPOSITS
# ============================================

# Deposit margin for 2 users on Sepolia
deposit-margin-sepolia:
	@echo "Depositing margin for 2 users on Ethereum Sepolia..."
	@forge script script/DepositMargin.s.sol:DepositMargin \
		--rpc-url sepolia \
		--broadcast \
		-vv
	@echo "Margin deposit complete!"

# ============================================
# READ MARGIN DATA
# ============================================

# Helper function to format wei to readable format (18 decimals)
define FORMAT_WEI
$(shell echo "$(1)" | awk '{len=length($$1); if(len<=18){printf "0.%018d", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')
endef

# Get all margin data for all accounts from .env on Sepolia
get-margin-data-sepolia:
	@echo "Reading margin data for accounts on Ethereum Sepolia..."
	@echo "========================================================"
	@echo "Account ID $(USER1_ACCOUNT_ID) (USER1):"
	@echo "  Total Collateral: $(shell cast call $(MARGIN_VAULT_ADDRESS) "getTotalCollateral(bytes32)" $(shell echo "$(USER1_ACCOUNT_ID)" | awk '{printf "0x%064x", $$1}') --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Locked IM:         $(shell cast call $(MARGIN_VAULT_ADDRESS) "getLockedIM(bytes32)" $(shell echo "$(USER1_ACCOUNT_ID)" | awk '{printf "0x%064x", $$1}') --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Free Margin:       $(shell cast call $(MARGIN_VAULT_ADDRESS) "getFreeMargin(bytes32)" $(shell echo "$(USER1_ACCOUNT_ID)" | awk '{printf "0x%064x", $$1}') --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo ""
	@echo "Account ID $(USER2_ACCOUNT_ID) (USER2):"
	@echo "  Total Collateral: $(shell cast call $(MARGIN_VAULT_ADDRESS) "getTotalCollateral(bytes32)" $(shell echo "$(USER2_ACCOUNT_ID)" | awk '{printf "0x%064x", $$1}') --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Locked IM:         $(shell cast call $(MARGIN_VAULT_ADDRESS) "getLockedIM(bytes32)" $(shell echo "$(USER2_ACCOUNT_ID)" | awk '{printf "0x%064x", $$1}') --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Free Margin:       $(shell cast call $(MARGIN_VAULT_ADDRESS) "getFreeMargin(bytes32)" $(shell echo "$(USER2_ACCOUNT_ID)" | awk '{printf "0x%064x", $$1}') --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "========================================================"

# ============================================
# TRADE CREATION
# ============================================

# Generate trade inputs and create a trade on Sepolia
create-trade-sepolia:
	@echo "Generating trade inputs and creating trade on Ethereum Sepolia..."
	node scripts-js/generateTradeInputs.js

# ============================================
# ABI EXTRACTION
# ============================================

extract-abis:
	node scripts-js/extractAbis.js

# ============================================
# ENVIRONMENT
# ============================================

-include .env

help:
	@echo "ClearRate Makefile Commands"
	@echo "==========================="
	@echo ""
	@echo "Build & Test:"
	@echo "  make build           - Compile all contracts"
	@echo "  make test           - Run all tests"
	@echo "  make format         - Format Solidity code"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy-sepolia    - Deploy to Ethereum Sepolia"
	@echo ""
	@echo "Whitelist:"
	@echo "  make whitelist-users-sepolia - Whitelist 2 users on Ethereum Sepolia"
	@echo ""
	@echo "Margin:"
	@echo "  make deposit-margin-sepolia   - Deposit margin for 2 users on Ethereum Sepolia"
	@echo "  make get-margin-data-sepolia   - Read all margin data for all accounts on Ethereum Sepolia"
	@echo ""
	@echo "Utilities:"
	@echo "  make extract-abis  - Extract contract ABIs"
	@echo "  make clean         - Clean build artifacts"
	@echo ""
	@echo "Environment variables (see .env.example):"
	@echo "  DEPLOYER_PRIVATE_KEY  - Private key for deployment"
	@echo "  ETHERSCAN_API_KEY     - Etherscan API key for verification"
	@echo "  ETH_RPC_URL           - RPC URL for fork testing"
	@echo ""
