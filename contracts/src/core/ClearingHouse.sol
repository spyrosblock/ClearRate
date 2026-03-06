// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IClearingHouse} from "../interfaces/IClearingHouse.sol";
import {IRSInstrument} from "./IRSInstrument.sol";
import {MarginVault} from "../margin/MarginVault.sol";
import {RiskEngine} from "../margin/RiskEngine.sol";
import {Whitelist} from "../access/Whitelist.sol";
import {ReceiverTemplate} from "../interfaces/ReceiverTemplate.sol";

/// @title ClearingHouse
/// @notice Central coordinator for IRS trade novation, VM settlement, and position compression.
/// @dev Implements EIP-712 for gas-free matched trade submission and signature verification.
///      Inherits from ReceiverTemplate to receive reports from Chainlink CRE workflow.
///      Each IRS position is represented by a unique tokenId (ERC-1155). Actions operate on
///      individual tokenIds and depend on the amount (notional) of the token the user holds.
contract ClearingHouse is AccessControl, ReentrancyGuard, EIP712, ReceiverTemplate, IClearingHouse {
    using ECDSA for bytes32;

    // ─── Constants ──────────────────────────────────────────────────────
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant LIQUIDATION_ENGINE_ROLE = keccak256("LIQUIDATION_ENGINE_ROLE");

    /// @dev EIP-712 typehash for MatchedTrade struct.
    bytes32 public constant MATCHED_TRADE_TYPEHASH = keccak256(
        "MatchedTrade(bytes32 tradeId,bytes32 partyA,bytes32 partyB,uint256 notional,uint256 fixedRateBps,uint256 startDate,uint256 maturityDate,uint256 paymentInterval,uint8 dayCountConvention,bytes32 floatingRateIndex,uint256 nonce,uint256 deadline,address collateralToken)"
    );

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice Tracks the token pair created from a trade.
    struct TradeTokens {
        uint256 tokenIdA;        // PAY_FIXED token
        uint256 tokenIdB;        // RECEIVE_FIXED token
        bool active;
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Core protocol dependencies.
    IRSInstrument public immutable instrument;
    MarginVault public immutable marginVault;
    RiskEngine public immutable riskEngine;
    Whitelist public immutable whitelist;

    /// @notice Active position tokenIds for an account (accountId => collateralToken => tokenIds).
    mapping(bytes32 => mapping(address => uint256[])) public accountTokenIds;

    /// @notice Mapping from tradeId to the token pair created.
    mapping(bytes32 => TradeTokens) public tradeTokens;

    /// @notice Used nonces per account for replay protection.
    mapping(bytes32 => mapping(uint256 => bool)) public usedNonces;

    /// @notice Trade IDs that have been submitted (prevents double-submission).
    mapping(bytes32 => bool) public tradeSubmitted;

    /// @notice Total number of active positions.
    uint256 public activePositionCount;

    /// @notice Protocol fee in BPS charged on notional per trade.
    uint256 public protocolFeeBps;

    /// @notice Protocol fee recipient address.
    address public feeRecipient;

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the ClearingHouse.
    /// @param admin The admin address.
    /// @param forwarder The Chainlink Forwarder address for CRE reports.
    /// @param instrument_ The IRSInstrument (ERC-1155) contract.
    /// @param marginVault_ The MarginVault contract.
    /// @param riskEngine_ The RiskEngine contract.
    /// @param whitelist_ The Whitelist contract.
    constructor(
        address admin,
        address forwarder,
        address instrument_,
        address marginVault_,
        address riskEngine_,
        address whitelist_
    ) EIP712("ClearRate CCP", "1") ReceiverTemplate(forwarder) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(SETTLEMENT_ROLE, admin);

        instrument = IRSInstrument(instrument_);
        marginVault = MarginVault(marginVault_);
        riskEngine = RiskEngine(riskEngine_);
        whitelist = Whitelist(whitelist_);
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Set the protocol fee.
    /// @param newFeeBps New fee in basis points.
    function setProtocolFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit ProtocolFeeUpdated(protocolFeeBps, newFeeBps);
        protocolFeeBps = newFeeBps;
    }

    /// @notice Set the fee recipient address.
    /// @param recipient The new fee recipient.
    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeRecipient = recipient;
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get the EIP-712 digest for a matched trade.
    /// @param trade The trade to hash.
    /// @return The EIP-712 typed data hash.
    function getTradeDigest(MatchedTrade calldata trade) external view returns (bytes32) {
        return _hashTypedDataV4(_tradeStructHash(trade));
    }

    /// @notice Get all active position tokenIds for an account.
    /// @param accountId The account to query.
    /// @param collateralToken The collateral token to filter by.
    /// @return Array of tokenIds.
    function getAccountTokenIds(bytes32 accountId, address collateralToken) external view returns (uint256[] memory) {
        return accountTokenIds[accountId][collateralToken];
    }

    /// @notice Get the token pair for a trade.
    /// @param tradeId The trade ID to query.
    /// @return tokenIdA The PAY_FIXED token ID.
    /// @return tokenIdB The RECEIVE_FIXED token ID.
    /// @return active Whether the trade is still active.
    function getTradeTokens(bytes32 tradeId) external view returns (uint256 tokenIdA, uint256 tokenIdB, bool active) {
        TradeTokens storage tt = tradeTokens[tradeId];
        return (tt.tokenIdA, tt.tokenIdB, tt.active);
    }

    // ─── ReceiverTemplate Implementation ─────────────────────────────────

    /// @inheritdoc AccessControl
    /// @dev Overrides supportsInterface to include both AccessControl and ReceiverTemplate interfaces.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, ReceiverTemplate) returns (bool) {
        return AccessControl.supportsInterface(interfaceId) || ReceiverTemplate.supportsInterface(interfaceId);
    }

    /// @notice Process the report data from Chainlink CRE.
    /// @dev Called by ReceiverTemplate.onReport() after validation.
    ///      Supports three report types:
    ///      1. Trade submission: abi.encode(uint8(0), matchedTrade, sigA, sigB)
    ///      2. VM settlement: abi.encode(uint8(1), NPVChange[], VMSettlement[])
    ///      3. Matured position settlement: abi.encode(uint8(2), NPVChange[], VMSettlement[])
    /// @param report ABI-encoded report data with type prefix
    function _processReport(
        bytes calldata report
    ) internal override {
        // Decode the first byte to determine report type
        (uint8 reportType) = abi.decode(report[:32], (uint8));

        if (reportType == 0) {
            // Trade submission report
            // Decode: (uint8, MatchedTrade trade, bytes sigA, bytes sigB)
            (, MatchedTrade memory trade, bytes memory sigA, bytes memory sigB) = abi.decode(
                report,
                (uint8, MatchedTrade, bytes, bytes)
            );
            _executeMatchedTrade(trade, sigA, sigB);
        } else if (reportType == 1) {
            // VM settlement report
            // Decode: (uint8, NPVChange[] npvChanges, VMSettlement[] vmSettlements)
            (, NPVChange[] memory npvChanges, VMSettlement[] memory vmSettlements) = abi.decode(
                report,
                (uint8, NPVChange[], VMSettlement[])
            );
            _executeVMSettlement(npvChanges, vmSettlements);
        } else if (reportType == 2) {
            // Matured position settlement batch report
            // Decode: (uint8, NPVChange[] npvChanges, VMSettlement[] vmSettlements)
            // All tokenIds in npvChanges will be deactivated after settlement
            (, NPVChange[] memory npvChanges, VMSettlement[] memory vmSettlements) = abi.decode(
                report,
                (uint8, NPVChange[], VMSettlement[])
            );
            _executeMaturedPositionSettlement(npvChanges, vmSettlements);
        } else {
            revert InvalidReportType(reportType);
        }
    }

    // ─── Internal: Trade Execution ─────────────────────────────────────

    /// @dev Execute a matched trade: validate, verify signatures, check margins, and novate.
    function _executeMatchedTrade(
        MatchedTrade memory trade,
        bytes memory sigA,
        bytes memory sigB
    ) internal {
        // ── Validation ──
        _validateTrade(trade);

        // ── Signature Verification ──
        _verifySignature(trade, trade.partyA, sigA);
        _verifySignature(trade, trade.partyB, sigB);

        // ── Whitelist & Tier Check ──
        address ownerA = whitelist.getAccountOwner(trade.partyA);
        address ownerB = whitelist.getAccountOwner(trade.partyB);
        
        // Check whitelisted status (includes KYC expiry check)
        if (!whitelist.isWhitelisted(ownerA)) revert PartyNotWhitelisted(trade.partyA);
        if (!whitelist.isWhitelisted(ownerB)) revert PartyNotWhitelisted(trade.partyB);

        // Check KYC expiry explicitly for better error messaging
        if (whitelist.isExpired(ownerA)) {
            revert KycExpired(trade.partyA, whitelist.getValidUntil(ownerA));
        }
        if (whitelist.isExpired(ownerB)) {
            revert KycExpired(trade.partyB, whitelist.getValidUntil(ownerB));
        }

        // Check maxNotional limits (cumulative across all positions)
        if (!whitelist.checkNotionalLimit(ownerA, trade.notional)) {
            uint256 currentTotal = whitelist.getTotalOpenNotional(ownerA);
            uint256 maxAllowed = whitelist.getMaxNotional(ownerA);
            revert ExceedsMaxNotional(trade.partyA, trade.notional, currentTotal, maxAllowed);
        }
        if (!whitelist.checkNotionalLimit(ownerB, trade.notional)) {
            uint256 currentTotal = whitelist.getTotalOpenNotional(ownerB);
            uint256 maxAllowed = whitelist.getMaxNotional(ownerB);
            revert ExceedsMaxNotional(trade.partyB, trade.notional, currentTotal, maxAllowed);
        }

        // ── Margin Check ──
        uint256 tenor = trade.maturityDate - trade.startDate;
        uint256 imRequired = riskEngine.calculateIM(trade.notional, tenor);

        if (!riskEngine.checkIM(trade.partyA, imRequired, trade.collateralToken)) {
            revert InsufficientMarginForTrade(trade.partyA);
        }
        if (!riskEngine.checkIM(trade.partyB, imRequired, trade.collateralToken)) {
            revert InsufficientMarginForTrade(trade.partyB);
        }

        // Mark trade as submitted
        tradeSubmitted[trade.tradeId] = true;

        emit TradeSubmitted(trade.tradeId);

        // ── Novation ──
        _novate(trade, ownerA, ownerB, imRequired);
    }

    /// @dev Validate trade parameters.
    function _validateTrade(MatchedTrade memory trade) internal view {
        if (tradeSubmitted[trade.tradeId]) revert TradeAlreadySubmitted(trade.tradeId);
        if (block.timestamp > trade.deadline) revert SignatureExpired(trade.deadline);
        if (trade.notional == 0) revert InvalidNotional();
        if (trade.maturityDate <= trade.startDate) revert InvalidTradeTerms();
        if (trade.fixedRateBps == 0) revert InvalidTradeTerms();
        if (trade.paymentInterval == 0) revert InvalidTradeTerms();
        if (trade.partyA == trade.partyB) revert InvalidTradeTerms();
        if (trade.collateralToken == address(0)) revert InvalidCollateralToken(trade.collateralToken);

        // Nonce checks
        if (usedNonces[trade.partyA][trade.nonce]) {
            revert NonceAlreadyUsed(trade.partyA, trade.nonce);
        }
        if (usedNonces[trade.partyB][trade.nonce]) {
            revert NonceAlreadyUsed(trade.partyB, trade.nonce);
        }
    }

    /// @dev Verify an EIP-712 signature against an accountId.
    function _verifySignature(
        MatchedTrade memory trade,
        bytes32 accountId,
        bytes memory signature
    ) internal view {
        bytes32 digest = _hashTypedDataV4(_tradeStructHash(trade));
        address signer = digest.recover(signature);
        address expectedSigner = whitelist.getAccountOwner(accountId);
        if (signer != expectedSigner) revert InvalidSignature(accountId);
    }

    /// @dev Compute the EIP-712 struct hash for a MatchedTrade.
    function _tradeStructHash(MatchedTrade memory trade) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MATCHED_TRADE_TYPEHASH,
                trade.tradeId,
                trade.partyA,
                trade.partyB,
                trade.notional,
                trade.fixedRateBps,
                trade.startDate,
                trade.maturityDate,
                trade.paymentInterval,
                trade.dayCountConvention,
                trade.floatingRateIndex,
                trade.nonce,
                trade.deadline,
                trade.collateralToken
            )
        );
    }

    /// @dev Execute novation: mint ERC-1155 position tokens and lock IM.
    function _novate(
        MatchedTrade memory trade,
        address ownerA,
        address ownerB,
        uint256 imRequired
    ) internal {
        // Mark nonces as used
        usedNonces[trade.partyA][trade.nonce] = true;
        usedNonces[trade.partyB][trade.nonce] = true;

        // Add notional to participants' total open notional
        whitelist.addNotional(ownerA, trade.notional);
        whitelist.addNotional(ownerB, trade.notional);

        // Mint Party A's position (PAY_FIXED)
        IRSInstrument.SwapTerms memory termsA = IRSInstrument.SwapTerms({
            notional: trade.notional,
            fixedRateBps: trade.fixedRateBps,
            startDate: trade.startDate,
            maturityDate: trade.maturityDate,
            paymentInterval: trade.paymentInterval,
            direction: IRSInstrument.Direction.PAY_FIXED,
            floatingRateIndex: trade.floatingRateIndex,
            dayCountConvention: trade.dayCountConvention,
            collateralToken: trade.collateralToken,
            active: true,
            lastNpv: 0
        });
        uint256 tokenIdA = instrument.mintPosition(ownerA, trade.partyA, termsA);

        // Mint Party B's position (RECEIVE_FIXED)
        IRSInstrument.SwapTerms memory termsB = IRSInstrument.SwapTerms({
            notional: trade.notional,
            fixedRateBps: trade.fixedRateBps,
            startDate: trade.startDate,
            maturityDate: trade.maturityDate,
            paymentInterval: trade.paymentInterval,
            direction: IRSInstrument.Direction.RECEIVE_FIXED,
            floatingRateIndex: trade.floatingRateIndex,
            dayCountConvention: trade.dayCountConvention,
            collateralToken: trade.collateralToken,
            active: true,
            lastNpv: 0
        });
        uint256 tokenIdB = instrument.mintPosition(ownerB, trade.partyB, termsB);

        // Track trade to token mapping
        tradeTokens[trade.tradeId] = TradeTokens({
            tokenIdA: tokenIdA,
            tokenIdB: tokenIdB,
            active: true
        });

        // Lock Initial Margin for both parties (in the specified collateral token)
        marginVault.lockInitialMargin(trade.partyA, trade.collateralToken, imRequired);
        marginVault.lockInitialMargin(trade.partyB, trade.collateralToken, imRequired);

        // Update Maintenance Margin for both parties
        _updateAccountMaintenanceMargin(trade.partyA, trade.collateralToken);
        _updateAccountMaintenanceMargin(trade.partyB, trade.collateralToken);

        // Track positions per account
        accountTokenIds[trade.partyA][trade.collateralToken].push(tokenIdA);
        accountTokenIds[trade.partyB][trade.collateralToken].push(tokenIdB);

        ++activePositionCount;

        emit TradeNovated(
            trade.tradeId,
            tokenIdA,
            tokenIdB,
            trade.partyA,
            trade.partyB,
            trade.notional,
            trade.fixedRateBps,
            trade.startDate,
            trade.maturityDate,
            trade.paymentInterval,
            trade.dayCountConvention,
            trade.floatingRateIndex,
            trade.collateralToken
        );
    }

    // ─── Internal: Variation Margin ─────────────────────────────────────

    /// @dev Execute VM settlement for a batch of positions.
    /// @param npvChanges Array of NPV changes per token.
    /// @param vmSettlements Array of VM settlement entries per account.
    function _executeVMSettlement(
        NPVChange[] memory npvChanges,
        VMSettlement[] memory vmSettlements
    ) internal {
        // Step 1: Update NPV for each token
        for (uint256 i; i < npvChanges.length; ++i) {
            NPVChange memory change = npvChanges[i];
            _updateTokenNpv(change.tokenId, change.npvChange);
        }

        // Step 2: Settle aggregated VM for each account
        for (uint256 i; i < vmSettlements.length; ++i) {
            VMSettlement memory settlement = vmSettlements[i];
            _settleAccountVariationMargin(settlement.accountId, settlement.collateralToken, settlement.vmChange);
        }
    }

    /// @dev Update NPV for a single token.
    /// @param tokenId The token ID to update NPV for.
    /// @param npvChange The NPV change to apply.
    function _updateTokenNpv(
        uint256 tokenId,
        int256 npvChange
    ) internal {
        // Get position data from IRSInstrument
        IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenId);
        
        if (!terms.active) revert PositionNotActive(tokenId);

        // Update NPV in the instrument
        if (npvChange != 0) {
            instrument.updateNpv(tokenId, npvChange);
        }

        emit NpvUpdated(tokenId, npvChange, block.timestamp);
    }

    /// @dev Settle aggregated variation margin for an account.
    /// @param accountId The account ID to settle VM for.
    /// @param collateralToken The collateral token to settle in.
    /// @param vmChange The aggregated VM change for the account.
    function _settleAccountVariationMargin(
        bytes32 accountId,
        address collateralToken,
        int256 vmChange
    ) internal {
        // VM settlement applies to all positions of the account
        if (vmChange == 0) return;

        // Settle VM: positive vmChange = credit, negative = debit
        marginVault.settleVariationMargin(accountId, collateralToken, vmChange);

        emit AccountVariationMarginSettled(accountId, vmChange, block.timestamp);
    }

    // ─── Internal: Position Settlement ─────────────────────────────────

    /// @dev Execute matured position settlement for a batch of positions.
    /// @param npvChanges Array of NPV changes per token. All tokens in this array will be deactivated.
    /// @param vmSettlements Array of VM settlement entries per account.
    function _executeMaturedPositionSettlement(
        NPVChange[] memory npvChanges,
        VMSettlement[] memory vmSettlements
    ) internal {
        // Step 1: Update NPV for each token
        for (uint256 i; i < npvChanges.length; ++i) {
            NPVChange memory change = npvChanges[i];
            _updateTokenNpv(change.tokenId, change.npvChange);
        }

        // Step 2: Settle aggregated VM for each account
        for (uint256 i; i < vmSettlements.length; ++i) {
            VMSettlement memory settlement = vmSettlements[i];
            _settleAccountVariationMargin(settlement.accountId, settlement.collateralToken, settlement.vmChange);
        }

        // Step 3: Close all matured positions (all tokenIds in npvChanges)
        for (uint256 i; i < npvChanges.length; ++i) {
            uint256 tokenId = npvChanges[i].tokenId;
            _closeMaturedPosition(tokenId);
        }
    }

    /// @dev Close a matured position and release locked margin.
    /// @param tokenId The token that has matured.
    function _closeMaturedPosition(
        uint256 tokenId
    ) internal {
        // Get position data from IRSInstrument
        IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenId);
        
        if (!terms.active) revert PositionNotActive(tokenId); // Already closed

        // TODO: enable this in production
        // if (block.timestamp < terms.maturityDate) revert PositionNotMatured(tokenId);

        // Get the token balance - we need to find who holds this token
        // Since this is an ERC-1155, we need to track holders separately or iterate
        // For now, we'll close the position for the original account stored in the terms
        // Note: This is a simplified approach - in production you may need to handle multiple holders
        
        // Mark position as inactive
        instrument.setActiveStatus(tokenId, false);

        // Note: In a full implementation, you would:
        // 1. Iterate through all accounts that hold this token
        // 2. Release IM for each account
        // 3. Update MM for each account
        // 4. Remove notional for each account
        // 5. Burn tokens for each account
        // 6. Emit PositionMatured for each (tokenId, accountId) pair

        // For now, we emit a simplified event
        emit PositionMatured(tokenId, bytes32(0), block.timestamp);
    }

    // ─── Internal: Margin Calculations ─────────────────────────────────

    /// @dev Update the maintenance margin for an account for a specific collateral token.
    /// @dev Reads locked IM directly from MarginVault to get the current IM requirement.
    /// @param accountId The account identifier.
    /// @param collateralToken The collateral token to update MM for.
    function _updateAccountMaintenanceMargin(bytes32 accountId, address collateralToken) internal {
        // Get locked IM directly from MarginVault (simpler than iterating positions)
        uint256 lockedIM = marginVault.getLockedIMByToken(accountId, collateralToken);
        uint256 newMM = riskEngine.calculateMM(lockedIM);
        riskEngine.updateMaintenanceMargin(accountId, collateralToken, newMM);
    }

    // ─── Liquidation ────────────────────────────────────────────────────

    /// @notice Transfer positions from a liquidated account to a liquidator.
    /// @dev Called by the LiquidationEngine during absorbPosition.
    ///      Handles the transfer of positions, margin requirements, and notional tracking.
    ///      Also transfers ERC-1155 position tokens to maintain the invariant: token holder = position owner.
    /// @param liquidatedAccount The account being liquidated.
    /// @param liquidatorAccountId The liquidator's account taking over positions.
    /// @param collateralToken The collateral token for the liquidation.
    /// @param imAmount The initial margin amount to lock for the liquidator.
    /// @return tokenIds Array of tokenIds transferred.
    function transferPositions(
        bytes32 liquidatedAccount,
        bytes32 liquidatorAccountId,
        address collateralToken,
        uint256 imAmount
    ) external onlyRole(LIQUIDATION_ENGINE_ROLE) returns (uint256[] memory tokenIds) {
        // Get all positions for the liquidated account
        uint256[] storage positions_ = accountTokenIds[liquidatedAccount][collateralToken];
        
        // Get owner addresses for token transfers
        address liquidatedOwner = whitelist.getAccountOwner(liquidatedAccount);
        address liquidatorOwner = whitelist.getAccountOwner(liquidatorAccountId);
        
        // Count active positions for this collateral token
        uint256 activeCount;
        for (uint256 i = 0; i < positions_.length; i++) {
            IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(positions_[i]);
            if (terms.active && terms.collateralToken == collateralToken) {
                activeCount++;
            }
        }
        
        tokenIds = new uint256[](activeCount);
        uint256 index;
        
        // Transfer each active position for this collateral token
        for (uint256 i = 0; i < positions_.length; i++) {
            uint256 tokenId = positions_[i];
            IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenId);
            
            if (terms.active && terms.collateralToken == collateralToken) {
                tokenIds[index] = tokenId;
                index++;
                
                // Get the balance (amount/notional) of this token held by the liquidated owner
                uint256 balance = instrument.balanceOf(liquidatedOwner, tokenId);
                
                if (balance > 0) {
                    // Transfer the token from liquidated owner to liquidator owner
                    instrument.transferPosition(liquidatedOwner, liquidatorOwner, tokenId, balance);
                }
                
                // Add position to liquidator's account
                accountTokenIds[liquidatorAccountId][collateralToken].push(tokenId);
            }
        }
        
        // Clear positions array for liquidated account (they've been transferred)
        delete accountTokenIds[liquidatedAccount][collateralToken];
        
        // Update notional tracking
        // Add notional to liquidator's owner for each transferred position
        for (uint256 i = 0; i < tokenIds.length; i++) {
            IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenIds[i]);
            whitelist.addNotional(liquidatorOwner, terms.notional);
        }
        
        // Lock initial margin for the liquidator
        if (imAmount > 0) {
            marginVault.lockInitialMargin(liquidatorAccountId, collateralToken, imAmount);
        }
        
        // Update maintenance margin for liquidator
        _updateAccountMaintenanceMargin(liquidatorAccountId, collateralToken);
        
        // Release IM from liquidated account (all IM for this token)
        uint256 lockedIM = marginVault.getLockedIMByToken(liquidatedAccount, collateralToken);
        if (lockedIM > 0) {
            marginVault.releaseInitialMargin(liquidatedAccount, collateralToken, lockedIM);
        }
        
        // Update maintenance margin for liquidated account
        _updateAccountMaintenanceMargin(liquidatedAccount, collateralToken);
        
        // Remove notional from liquidated account's owner
        for (uint256 i = 0; i < tokenIds.length; i++) {
            IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenIds[i]);
            whitelist.removeNotional(liquidatedOwner, terms.notional);
        }
        
        emit PositionsTransferred(liquidatedAccount, liquidatorAccountId, tokenIds, collateralToken);
    }

    /// @notice Get the total IM requirement for an account's positions in a specific collateral token.
    /// @param accountId The account to query.
    /// @param collateralToken The collateral token to filter by.
    /// @return totalIM The total IM required for all positions.
    function getTotalIMForToken(
        bytes32 accountId,
        address collateralToken
    ) external view returns (uint256 totalIM) {
        uint256[] storage positions_ = accountTokenIds[accountId][collateralToken];
        for (uint256 i = 0; i < positions_.length; i++) {
            uint256 tokenId = positions_[i];
            IRSInstrument.SwapTerms memory terms = instrument.getSwapTerms(tokenId);
            if (terms.active && terms.collateralToken == collateralToken) {
                uint256 tenor = terms.maturityDate - terms.startDate;
                totalIM += riskEngine.calculateIM(terms.notional, tenor);
            }
        }
    }
}
