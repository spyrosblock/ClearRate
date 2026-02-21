// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LocalMarginVault} from "../margin/LocalMarginVault.sol";

/// @title CCIPSpokeGateway
/// @notice CCIP sender/receiver for Hub ↔ Spoke cross-chain margin sync and trade relay.
/// @dev This contract encodes/decodes typed messages for cross-chain communication.
///      In production, this extends Chainlink's CCIPReceiver. This version provides
///      the message encoding/routing layer with a pluggable transport interface.
contract CCIPSpokeGateway is AccessControl, ReentrancyGuard {
    // ─── Constants ──────────────────────────────────────────────────────
    bytes32 public constant HUB_OPERATOR_ROLE = keccak256("HUB_OPERATOR_ROLE");

    // ─── Message Types ──────────────────────────────────────────────────
    uint8 public constant MSG_MARGIN_SYNC = 1;
    uint8 public constant MSG_TRADE_INTENT = 2;
    uint8 public constant MSG_LIQUIDATION_NOTICE = 3;

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice Cross-chain message envelope.
    struct CCIPMessage {
        uint8 messageType;       // Message type identifier
        bytes32 accountId;       // Global account identifier
        bytes payload;           // Encoded message payload
        uint64 sourceChainSelector; // Source chain identifier
        uint256 timestamp;       // Message creation timestamp
    }

    /// @notice Margin sync payload.
    struct MarginSyncPayload {
        address token;           // Stablecoin token address
        uint256 amount;          // Amount being synced
        bool isDeposit;          // True = deposit to Hub, False = withdrawal from Hub
    }

    /// @notice Trade intent payload.
    struct TradeIntentPayload {
        bytes32 tradeId;         // Unique trade identifier
        bytes32 counterpartyId;  // Counterparty account ID
        uint256 notional;        // Notional amount
        uint256 fixedRateBps;    // Fixed rate in BPS
        uint256 tenor;           // Swap tenor in seconds
        bool payFixed;           // True if this account pays fixed
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Reference to the local margin vault on this spoke.
    LocalMarginVault public immutable localVault;

    /// @notice Hub chain selector for CCIP routing.
    uint64 public hubChainSelector;

    /// @notice Hub gateway address for message verification.
    address public hubGatewayAddress;

    /// @notice CCIP router address on this chain.
    address public ccipRouter;

    /// @notice Nonce for outgoing messages.
    uint256 public outgoingNonce;

    /// @notice Processed incoming message IDs (replay protection).
    mapping(bytes32 => bool) public processedMessages;

    // ─── Events ─────────────────────────────────────────────────────────
    event MessageSent(
        uint8 indexed messageType,
        bytes32 indexed accountId,
        bytes32 messageId,
        uint64 destinationChainSelector
    );
    event MessageReceived(
        uint8 indexed messageType,
        bytes32 indexed accountId,
        bytes32 messageId,
        uint64 sourceChainSelector
    );
    event MarginSynced(bytes32 indexed accountId, address token, uint256 amount, bool isDeposit);
    event HubConfigUpdated(uint64 chainSelector, address gatewayAddress);

    // ─── Errors ─────────────────────────────────────────────────────────
    error InvalidMessageType(uint8 messageType);
    error MessageAlreadyProcessed(bytes32 messageId);
    error UnauthorizedSource(uint64 chainSelector, address sender);
    error InvalidAddress();
    error InvalidChainSelector();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the CCIPSpokeGateway.
    /// @param admin The admin address.
    /// @param localVault_ The LocalMarginVault on this spoke.
    /// @param ccipRouter_ The CCIP router address on this chain.
    /// @param hubChainSelector_ The hub chain's CCIP selector.
    /// @param hubGateway_ The hub gateway contract address.
    constructor(
        address admin,
        address localVault_,
        address ccipRouter_,
        uint64 hubChainSelector_,
        address hubGateway_
    ) {
        if (admin == address(0)) revert InvalidAddress();
        if (localVault_ == address(0)) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(HUB_OPERATOR_ROLE, admin);

        localVault = LocalMarginVault(localVault_);
        ccipRouter = ccipRouter_;
        hubChainSelector = hubChainSelector_;
        hubGatewayAddress = hubGateway_;
    }

    // ─── Outgoing Messages ──────────────────────────────────────────────

    /// @notice Send a margin sync message to the Hub chain.
    /// @param accountId The account performing the sync.
    /// @param token The stablecoin token address.
    /// @param amount The amount to sync.
    /// @param isDeposit True if depositing to Hub, false if withdrawing.
    /// @return messageId The unique message identifier.
    function sendMarginSync(
        bytes32 accountId,
        address token,
        uint256 amount,
        bool isDeposit
    ) external nonReentrant returns (bytes32 messageId) {
        MarginSyncPayload memory payload = MarginSyncPayload({
            token: token,
            amount: amount,
            isDeposit: isDeposit
        });

        messageId = _sendMessage(
            MSG_MARGIN_SYNC,
            accountId,
            abi.encode(payload)
        );

        emit MarginSynced(accountId, token, amount, isDeposit);
    }

    /// @notice Send a trade intent to the Hub chain.
    /// @param accountId The submitting account.
    /// @param intent The trade intent payload.
    /// @return messageId The unique message identifier.
    function sendTradeIntent(
        bytes32 accountId,
        TradeIntentPayload calldata intent
    ) external nonReentrant returns (bytes32 messageId) {
        messageId = _sendMessage(
            MSG_TRADE_INTENT,
            accountId,
            abi.encode(intent)
        );
    }

    // ─── Incoming Messages ──────────────────────────────────────────────

    /// @notice Process an incoming CCIP message from the Hub.
    /// @dev In production, this would be called by _ccipReceive. Here it's gated by HUB_OPERATOR_ROLE.
    /// @param messageId The unique message identifier.
    /// @param message The decoded CCIP message.
    function processIncomingMessage(
        bytes32 messageId,
        CCIPMessage calldata message
    ) external onlyRole(HUB_OPERATOR_ROLE) {
        if (processedMessages[messageId]) {
            revert MessageAlreadyProcessed(messageId);
        }

        processedMessages[messageId] = true;

        if (message.messageType == MSG_MARGIN_SYNC) {
            _handleMarginSync(message);
        } else if (message.messageType == MSG_LIQUIDATION_NOTICE) {
            _handleLiquidationNotice(message);
        } else {
            revert InvalidMessageType(message.messageType);
        }

        emit MessageReceived(
            message.messageType,
            message.accountId,
            messageId,
            message.sourceChainSelector
        );
    }

    // ─── Admin Functions ────────────────────────────────────────────────

    /// @notice Update Hub chain configuration.
    /// @param chainSelector_ New hub chain selector.
    /// @param gatewayAddress_ New hub gateway address.
    function setHubConfig(
        uint64 chainSelector_,
        address gatewayAddress_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (chainSelector_ == 0) revert InvalidChainSelector();
        if (gatewayAddress_ == address(0)) revert InvalidAddress();

        hubChainSelector = chainSelector_;
        hubGatewayAddress = gatewayAddress_;

        emit HubConfigUpdated(chainSelector_, gatewayAddress_);
    }

    /// @notice Update the CCIP router address.
    /// @param newRouter The new router address.
    function setCCIPRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRouter == address(0)) revert InvalidAddress();
        ccipRouter = newRouter;
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Construct and "send" a CCIP message (encodes and emits).
    function _sendMessage(
        uint8 messageType,
        bytes32 accountId,
        bytes memory payload
    ) internal returns (bytes32 messageId) {
        messageId = keccak256(
            abi.encodePacked(
                address(this),
                block.chainid,
                outgoingNonce++,
                block.timestamp
            )
        );

        // In production: encode into Client.EVM2AnyMessage and call ccipRouter.ccipSend()
        // For now, we emit the intent for offchain relay
        emit MessageSent(messageType, accountId, messageId, hubChainSelector);
    }

    /// @dev Handle an incoming margin sync from the Hub.
    function _handleMarginSync(CCIPMessage calldata message) internal {
        MarginSyncPayload memory payload = abi.decode(message.payload, (MarginSyncPayload));

        if (!payload.isDeposit) {
            // Hub is returning margin to the spoke — credit the user's local balance
            address owner = address(uint160(uint256(message.accountId)));
            localVault.creditFromSync(owner, payload.token, payload.amount);
        }
    }

    /// @dev Handle an incoming liquidation notice from the Hub.
    function _handleLiquidationNotice(CCIPMessage calldata message) internal {
        // Freeze the account's local vault and emit notification
        // Implementation depends on ClearingHouse liquidation flow
        // For now, this is a placeholder for the event-driven architecture
    }
}
