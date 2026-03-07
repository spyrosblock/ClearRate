.PHONY: help \
	deploy-contracts \
	whitelist-users \
	deposit-margin \
	store-logs \
	create-trade-json \
	create-trade \
	settle-vm \
	withdraw-margin \
	get-margin-data \
	workflow-install

# ===============================================
# HELP
# ===============================================

help:
	@echo "ClearRate CCP Workflow Makefile"
	@echo "================================"
	@echo ""
	@echo "Lifecycle Steps (in order):"
	@echo "  1. make deploy-contracts    - Deploy contracts to Sepolia"
	@echo "  2. make whitelist-users     - Whitelist user 1 and user 2"
	@echo "  3. make deposit-margin      - Mint mock tokens and deposit collateral"
	@echo "  4. make store-logs          - Store MarginDeposited event logs"
	@echo "  5. make create-trade-json   - Generate trade JSON file"
	@echo "  6. make create-trade        - Create the swap via CRE API"
	@echo "  7. make store-logs          - Store TradeNovated event logs"
	@echo "  8. make settle-vm           - Settle variation margin daily"
	@echo "  9. make store-logs          - Store PositionMatured event logs"
	@echo "  10. make withdraw-margin    - Withdraw collateral after settlement"
	@echo ""
	@echo "Read Commands:"
	@echo "  make get-margin-data        - Get free margin data for all users"
	@echo ""
	@echo "Utilities:"
	@echo "  make workflow-install       - Install dependencies for all workflows"
	@echo ""

# ===============================================
# WORKFLOW INSTALLATION
# ===============================================

# Install dependencies for all workflows
workflow-install:
	@echo "Installing dependencies for all workflows..."
	cd whitelist-user-workflow && bun install
	cd store-logs-workflow && bun install
	cd create-trade-workflow && bun install
	cd settle-vm-workflow && bun install
	@echo "All workflow dependencies installed!"

# ===============================================
# STORE LOGS
# ===============================================

# Store MarginDeposited event logs (triggered by deposit-margin)
store-logs:
	@echo "Storing event logs via CRE workflow..."
	cd store-logs-workflow && bun install
	cre workflow simulate store-logs-workflow --target staging-settings --broadcast
	@echo "Event logs stored successfully!"

# ===============================================
# STEP 1: DEPLOY CONTRACTS
# ===============================================

# Deploy contracts to Sepolia
deploy-contracts:
	curl https://clear-rate.vercel.app/api/restart-db-for-testing
	cd contracts && make deploy-contracts-sepolia

# IMPORTANT - After deploying, update the contracts/.env file

# After undating the .env update the configs of the workflows
update-config-addresses:
	cd contracts && make update-config-addresses

# ===============================================
# STEP 2: WHITELIST USERS
# ===============================================

# Whitelist users 1, 2 and 3 via whitelist-user-workflow
whitelist-users:
	cd contracts && make generate-whitelist-inputs
	@echo "Whitelisting users via CRE workflow..."
	cd whitelist-user-workflow && bun install && cd ..
	cre workflow simulate whitelist-user-workflow --target staging-settings --broadcast --http-payload "$$(cat ./contracts/scripts-js/payloads/user_1.json)" --non-interactive --trigger-index 0
	cre workflow simulate whitelist-user-workflow --target staging-settings --broadcast --http-payload "$$(cat ./contracts/scripts-js/payloads/user_2.json)" --non-interactive --trigger-index 0
	cre workflow simulate whitelist-user-workflow --target staging-settings --broadcast --http-payload "$$(cat ./contracts/scripts-js/payloads/user_3.json)" --non-interactive --trigger-index 0
	@echo "Users whitelisted successfully!"

# ===============================================
# STEP 3: DEPOSIT MARGIN
# ===============================================

# Mint mock tokens and deposit collateral for users
# Store MarginDeposited Event (1) - MarginVault.sol
# Store MarginDeposited Event (1) - MarginVault.sol
# Store MarginDeposited Event (1) - MarginVault.sol
deposit-margin:
	cd contracts && make deposit-margin-sepolia
	$(MAKE) store-logs
	$(MAKE) store-logs
	$(MAKE) store-logs

# ===============================================
# STEP 4: CREATE TRADE
# ===============================================

# Create the swap via CRE API
# Store TradeNovated Event (11) - ClearingHouse.sol
create-trade:
	@echo "Generating trade JSON file..."
	cd contracts && make create-trade-sepolia
	@echo "Trade JSON file generated!"
	@echo "Creating trade via CRE workflow..."
	cd create-trade-workflow && bun install
	cre workflow simulate create-trade-workflow --target staging-settings --broadcast --http-payload "$$(cat ./contracts/scripts-js/payloads/trade.json)" --non-interactive --trigger-index 0
	@echo "Trade created successfully!"
	$(MAKE) store-logs

# ===============================================
# STEP 5: SETTLE VARIATION MARGIN
# ===============================================

# Settle variation margin for all positions daily
settle-vm:
	@echo "Settling variation margin..."
	cd settle-vm-workflow && bun install
	cre workflow simulate settle-vm-workflow --target staging-settings --broadcast
	@echo "Variation margin settled successfully!"

# ===============================================
# STEP 6: SETTLE VARIATION MARGIN - FINAL
# ===============================================

# Final variation margin settlement for all positions
# Store PositionMatured Event (11) - ClearingHouse.sol
# Store PositionMatured Event (17) - ClearingHouse.sol
settle-vm-final:
	@echo "Settling variation margin..."
	cd settle-vm-workflow && bun install
	cre workflow simulate settle-vm-workflow --target final-staging-settings --broadcast
	@echo "Variation margin settled successfully!"
	$(MAKE) store-logs
	$(MAKE) store-logs

# ===============================================
# STEP 7: WITHDRAW MARGIN
# ===============================================

# Withdraw collateral after trade is settled
# Store MarginWithdrawn Event (1) - MarginVault.sol
withdraw-margin:
	@echo "Withdrawing margin..."
	cd contracts && make withdraw-margin-sepolia
	@echo "Margin withdrawn successfully!"
	$(MAKE) store-logs
	$(MAKE) store-logs

# ===============================================
# LIQUIDATION
# ===============================================

# before withdrawing
# make create-trade
# make withdraw-margin
# make settle-vm

# Liquidate the liquidatable users
liquidate:
	@echo "Liquidating..."
	cd liquidation-workflow && bun install
	cre workflow simulate liquidation-workflow --target staging-settings --broadcast

# Store PositionsAbsorbed Event (9) - ClearingHouse.sol
absorb-positions:
	@echo "Absorbing positions..."
	cd contracts && make absorb-positions-sepolia
	$(MAKE) store-logs

# ===============================================
# PARTIAL POSITION TRANSFER
# ===============================================

# Store PositionTransferred Event (7) - ClearingHouse.sol
transfer-position:
	@echo "Transferring positions..."
	cd contracts && make transfer-position-sepolia
	$(MAKE) store-logs

# ===============================================
# READ COMMANDS
# ===============================================

# Get margin data for all users
get-margin-data:
	cd contracts && make get-margin-data-sepolia

# Get db data
get-db-data:
	@echo "Getting DB Data..."
	clear && curl https://clear-rate.vercel.app/api/data

# ===============================================
# TROUBLESHOOT
# ===============================================
#- May need to run `bun x cre-setup on each workflow` inside the workflows
