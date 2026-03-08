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
		@echo ""
	@echo "IMPORTANT: Update the following files with new contract addresses:"
	@echo "  - contracts/.env"
	@echo "  - create-trade-workflow/config.staging.json"
	@echo "  - settle-vm-workflow/config.staging.json"
	@echo "  - store-logs-workflow/config.staging.json"
	@echo "  - whitelist-user-workflow/config.staging.json"
	@echo "  - liquidate-workflow/config.staging.json"
	@echo "IMPORTANT: Also reset the db"
	@echo "  - curl https://clear-rate.vercel.app/api/restart-db-for-testing"

# ============================================
# UPDATE CONFIG ADDRESSES
# ============================================

update-config-addresses:
	@node scripts-js/updateConfigAddresses.js

# ============================================
# UPDATE CONFIG ADDRESSES
# ============================================

generate-whitelist-inputs:
	@node scripts-js/generateWhitelistInputs.js

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
# MARGIN DEPOSITS & WITHDRAWALS
# ============================================

# Mint mock tokens and deposit margin for 3 users on Sepolia
deposit-margin-sepolia:
	@echo "Depositing margin for 3 users on Ethereum Sepolia..."
	@forge script script/MintAndDepositMargin.s.sol:MintAndDepositMargin \
		--rpc-url sepolia \
		--broadcast \
		-vv
	@echo "Margin deposit complete!"

# Withdraw margin for 2 users on Sepolia (default: full free margin balance, or set WITHDRAW_AMOUNT)
withdraw-margin-sepolia:
	@echo "Withdrawing margin for 2 users on Ethereum Sepolia..."
	@forge script script/WithdrawMargin.s.sol:WithdrawMargin \
		--rpc-url sepolia \
		--broadcast \
		-vv
	@echo "Margin withdrawal complete!"

# ============================================
# USER 3 ABSORBS POSITIONS FROM USER 2
# ============================================

absorb-positions-sepolia:
	@echo "User 3 absorbs positions from User 2..."
	@forge script script/AbsorbPositions.s.sol:AbsorbPositions \
		--rpc-url sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vv

# ============================================
# USER 1 TRANSFERS 20% OF TOKENID 0 TO USER 2
# ============================================

transfer-position-sepolia:
	@echo "User 1 transfers 20% of TokenID 0 to User 2..."
	@forge script script/TransferPosition.s.sol:TransferPosition \
		--rpc-url sepolia \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--broadcast \
		-vv

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
	@echo "Account ID $(USER1_ADDRESS) (USER1):"
	@echo "  Total Collateral:  $(shell cast call $(MARGIN_VAULT_ADDRESS) "getTotalCollateral(bytes32,address)" $(shell echo "$(USER1_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Locked IM:         $(shell cast call $(MARGIN_VAULT_ADDRESS) "getLockedIMByToken(bytes32,address)" $(shell echo "$(USER1_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  MM:                $(shell cast call $(RISK_ENGINE_ADDRESS) "accountMaintenanceMargin(bytes32,address)" $(shell echo "$(USER1_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Free Margin:       $(shell cast call $(MARGIN_VAULT_ADDRESS) "getFreeMarginByToken(bytes32,address)" $(shell echo "$(USER1_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "Account ID $(USER2_ADDRESS) (USER2):"
	@echo "  Total Collateral:  $(shell cast call $(MARGIN_VAULT_ADDRESS) "getTotalCollateral(bytes32,address)" $(shell echo "$(USER2_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Locked IM:         $(shell cast call $(MARGIN_VAULT_ADDRESS) "getLockedIMByToken(bytes32,address)" $(shell echo "$(USER2_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  MM:                $(shell cast call $(RISK_ENGINE_ADDRESS) "accountMaintenanceMargin(bytes32,address)" $(shell echo "$(USER2_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Free Margin:       $(shell cast call $(MARGIN_VAULT_ADDRESS) "getFreeMarginByToken(bytes32,address)" $(shell echo "$(USER2_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "Account ID $(USER3_ADDRESS) (USER3):"
	@echo "  Total Collateral:  $(shell cast call $(MARGIN_VAULT_ADDRESS) "getTotalCollateral(bytes32,address)" $(shell echo "$(USER3_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Locked IM:         $(shell cast call $(MARGIN_VAULT_ADDRESS) "getLockedIMByToken(bytes32,address)" $(shell echo "$(USER3_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  MM:                $(shell cast call $(RISK_ENGINE_ADDRESS) "accountMaintenanceMargin(bytes32,address)" $(shell echo "$(USER3_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"
	@echo "  Free Margin:       $(shell cast call $(MARGIN_VAULT_ADDRESS) "getFreeMarginByToken(bytes32,address)" $(shell echo "$(USER3_ADDRESS)" | sed 's/^0x//' | awk '{printf "0x%064s", $$1}' | tr ' ' '0') $(MOCK_COLLATERAL_TOKEN) --rpc-url sepolia | cast --to-dec | awk '{len=length($$1); if(len<=18){printf "0.%018s", $$1}else{printf "%s.%s", substr($$1,1,len-18), substr($$1,len-17)}}')"

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


-include .env
