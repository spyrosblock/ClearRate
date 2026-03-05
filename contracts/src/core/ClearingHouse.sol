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

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Core protocol dependencies.
    IRSInstrument public immutable instrument;
    MarginVault public immutable marginVault;
    RiskEngine public immutable riskEngine;
    Whitelist public immutable whitelist;

    /// @notice Novated positions indexed by tradeId.
    mapping(bytes32 => NovatedPosition) public positions;

    /// @notice Active position tradeIds for an account.
    mapping(bytes32 => mapping(address => bytes32[])) public accountPositions;

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

    /// @notice Compress positions by deleting old positions and creating new compressed ones.
    /// @notice Works for many positions and users.
    /// @notice All positions that are compressed must be for the same token. (Enforced externally)
    /// @param oldPositions Array of old position trade IDs to be deleted
    /// @param newPositions Array of new compressed positions to be created
    /// @param newIMs Array of initial margin values for each new position.
    /// Tenors might not be standard so we need to calculate the newIMs offchain
    function compressPositions(
        bytes32[] calldata oldPositions,
        NewCompressedPosition[] calldata newPositions,
        uint256[] calldata newIMs
    ) external onlyRole(OPERATOR_ROLE) {
        // Delete all old positions first
        for (uint256 i = 0; i < oldPositions.length; i++) {
            _deletePosition(oldPositions[i]);
        }

        // Create all new compressed positions
        for (uint256 i = 0; i < newPositions.length; i++) {
            _createCompressedPosition(newPositions[i], newIMs[i]);
        }
    }

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

    /// @notice Get all active position trade IDs for an account.
    /// @param accountId The account to query.
    /// @return Array of trade IDs.
    function getAccountPositions(bytes32 accountId, address collateralToken) external view returns (bytes32[] memory) {
        return accountPositions[accountId][collateralToken];
    }

    /// @notice Get position details.
    /// @param tradeId The trade ID to query.
    /// @return The novated position struct.
    function getPosition(bytes32 tradeId) external view returns (NovatedPosition memory) {
        return positions[tradeId];
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
    ///      2. VM settlement: abi.encode(uint8(1), VMSettlement[])
    ///      3. Matured position settlement: abi.encode(uint8(2), MaturedPositionSettlement[])
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
            // Decode: (uint8, VMSettlement[] settlements)
            (, VMSettlement[] memory settlements) = abi.decode(
                report,
                (uint8, VMSettlement[])
            );
            _executeVMSettlement(settlements);
        } else if (reportType == 2) {
            // Matured position settlement batch report
            // Decode: (uint8, MaturedPositionSettlement[] settlements)
            (, MaturedPositionSettlement[] memory settlements) = abi.decode(
                report,
                (uint8, MaturedPositionSettlement[])
            );
            _executeMaturedPositionSettlement(settlements);
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

        emit TradeSubmitted(
            trade.tradeId,
            trade.partyA,
            trade.partyB,
            trade.notional,
            trade.fixedRateBps
        );

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
            dayCountConvention: trade.dayCountConvention
        });
        uint256 tokenIdA = instrument.mintPosition(ownerA, termsA);

        // Mint Party B's position (RECEIVE_FIXED)
        IRSInstrument.SwapTerms memory termsB = IRSInstrument.SwapTerms({
            notional: trade.notional,
            fixedRateBps: trade.fixedRateBps,
            startDate: trade.startDate,
            maturityDate: trade.maturityDate,
            paymentInterval: trade.paymentInterval,
            direction: IRSInstrument.Direction.RECEIVE_FIXED,
            floatingRateIndex: trade.floatingRateIndex,
            dayCountConvention: trade.dayCountConvention
        });
        uint256 tokenIdB = instrument.mintPosition(ownerB, termsB);

        // Lock Initial Margin for both parties (in the specified collateral token)
        marginVault.lockInitialMargin(trade.partyA, trade.collateralToken, imRequired);
        marginVault.lockInitialMargin(trade.partyB, trade.collateralToken, imRequired);

        // Update Maintenance Margin for both parties
        _updateAccountMaintenanceMargin(trade.partyA, trade.collateralToken);
        _updateAccountMaintenanceMargin(trade.partyB, trade.collateralToken);

        // Store novated position
        positions[trade.tradeId] = NovatedPosition({
            tradeId: trade.tradeId,
            tokenIdA: tokenIdA,
            tokenIdB: tokenIdB,
            partyA: trade.partyA,
            partyB: trade.partyB,
            notional: trade.notional,
            fixedRateBps: trade.fixedRateBps,
            startDate: trade.startDate,
            maturityDate: trade.maturityDate,
            active: true,
            lastNpv: 0,
            collateralToken: trade.collateralToken
        });

        // Track positions per account
        accountPositions[trade.partyA][trade.collateralToken].push(trade.tradeId);
        accountPositions[trade.partyB][trade.collateralToken].push(trade.tradeId);

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

    // ─── Internal: Position Compression ────────────────────────────────

    /// @dev Delete a single position (used during compression).
    /// @param tradeId The trade ID of the position to delete.
    function _deletePosition(bytes32 tradeId) internal {
        NovatedPosition storage pos = positions[tradeId];
        if (!pos.active) revert PositionNotActive(tradeId);

        // Release IM for both parties
        uint256 tenor = pos.maturityDate - pos.startDate;
        uint256 imRelease = riskEngine.calculateIM(pos.notional, tenor);

        marginVault.releaseInitialMargin(pos.partyA, pos.collateralToken, imRelease);
        marginVault.releaseInitialMargin(pos.partyB, pos.collateralToken, imRelease);

        // Update Maintenance Margin for both parties
        _updateAccountMaintenanceMargin(pos.partyA, pos.collateralToken);
        _updateAccountMaintenanceMargin(pos.partyB, pos.collateralToken);

        // Remove notional from participants' total open notional
        address ownerA = whitelist.getAccountOwner(pos.partyA);
        address ownerB = whitelist.getAccountOwner(pos.partyB);
        whitelist.removeNotional(ownerA, pos.notional);
        whitelist.removeNotional(ownerB, pos.notional);

        // Burn position tokens
        if (instrument.balanceOf(ownerA, pos.tokenIdA) > 0) {
            instrument.burnPosition(ownerA, pos.tokenIdA, pos.notional);
        }
        if (instrument.balanceOf(ownerB, pos.tokenIdB) > 0) {
            instrument.burnPosition(ownerB, pos.tokenIdB, pos.notional);
        }

        // Mark position as inactive
        pos.active = false;
        --activePositionCount;

        emit PositionCompressed(
            pos.partyA,
            tradeId,
            bytes32(0),
            pos.notional
        );
    }

    /// @dev Create a single compressed position (used during compression).
    /// @param newPos The new compressed position data.
    /// @param imRequired The initial margin required for this position.
    function _createCompressedPosition(
        NewCompressedPosition memory newPos,
        uint256 imRequired
    ) internal {
        // Get owners for both parties
        address ownerA = whitelist.getAccountOwner(newPos.partyA);
        address ownerB = whitelist.getAccountOwner(newPos.partyB);

        // Add notional to participants' total open notional (for new compressed position)
        // Note: The old notional was already removed in _deletePosition
        whitelist.addNotional(ownerA, newPos.notional);
        whitelist.addNotional(ownerB, newPos.notional);

        // Mint Party A's position (PAY_FIXED)
        IRSInstrument.SwapTerms memory termsA = IRSInstrument.SwapTerms({
            notional: newPos.notional,
            fixedRateBps: newPos.fixedRateBps,
            startDate: newPos.startDate,
            maturityDate: newPos.maturityDate,
            paymentInterval: newPos.paymentInterval,
            direction: IRSInstrument.Direction.PAY_FIXED,
            floatingRateIndex: newPos.floatingRateIndex,
            dayCountConvention: newPos.dayCountConvention
        });
        uint256 tokenIdA = instrument.mintPosition(ownerA, termsA);

        // Mint Party B's position (RECEIVE_FIXED)
        IRSInstrument.SwapTerms memory termsB = IRSInstrument.SwapTerms({
            notional: newPos.notional,
            fixedRateBps: newPos.fixedRateBps,
            startDate: newPos.startDate,
            maturityDate: newPos.maturityDate,
            paymentInterval: newPos.paymentInterval,
            direction: IRSInstrument.Direction.RECEIVE_FIXED,
            floatingRateIndex: newPos.floatingRateIndex,
            dayCountConvention: newPos.dayCountConvention
        });
        uint256 tokenIdB = instrument.mintPosition(ownerB, termsB);

        // Lock Initial Margin for both parties
        marginVault.lockInitialMargin(newPos.partyA, newPos.collateralToken, imRequired);
        marginVault.lockInitialMargin(newPos.partyB, newPos.collateralToken, imRequired);

        // Update MM for both parties
        _updateAccountMaintenanceMargin(newPos.partyA, newPos.collateralToken);
        _updateAccountMaintenanceMargin(newPos.partyB, newPos.collateralToken);

        // Store the new compressed position
        positions[newPos.tradeId] = NovatedPosition({
            tradeId: newPos.tradeId,
            tokenIdA: tokenIdA,
            tokenIdB: tokenIdB,
            partyA: newPos.partyA,
            partyB: newPos.partyB,
            notional: newPos.notional,
            fixedRateBps: newPos.fixedRateBps,
            startDate: newPos.startDate,
            maturityDate: newPos.maturityDate,
            active: true,
            lastNpv: 0,
            collateralToken: newPos.collateralToken
        });

        // Track positions per account
        accountPositions[newPos.partyA][newPos.collateralToken].push(newPos.tradeId);
        accountPositions[newPos.partyB][newPos.collateralToken].push(newPos.tradeId);

        ++activePositionCount;

        emit TradeNovated(
            newPos.tradeId,
            tokenIdA,
            tokenIdB,
            newPos.partyA,
            newPos.partyB,
            newPos.notional,
            newPos.fixedRateBps,
            newPos.startDate,
            newPos.maturityDate,
            newPos.paymentInterval,
            newPos.dayCountConvention,
            newPos.floatingRateIndex,
            newPos.collateralToken
        );
    }

    // ─── Internal: Variation Margin ─────────────────────────────────────

    /// @dev Execute VM settlement for a batch of positions by trade.
    /// @param settlements Array of VM settlement entries (tradeId + npvChange).
    function _executeVMSettlement(
        VMSettlement[] memory settlements
    ) internal {
        for (uint256 i; i < settlements.length; ++i) {
            VMSettlement memory settlement = settlements[i];
            _settleVariationMargin(settlement.tradeId, settlement.npvChange);
        }
    }

    /// @dev Settle variation margin for a single position by tradeId.
    /// @param tradeId The unique identifier of the position to settle.
    /// @param npvChange The NPV change from the fixed payer's perspective.
    function _settleVariationMargin(
        bytes32 tradeId,
        int256 npvChange
    ) internal {
        NovatedPosition storage pos = positions[tradeId];
        if (!pos.active) revert PositionNotActive(tradeId);

        pos.lastNpv += npvChange;

        // Party A is the fixed payer: positive npvChange benefits A, debits B
        // Settle VM in the position's collateral token
        if (npvChange != 0) {
            marginVault.settleVariationMargin(pos.partyA, pos.collateralToken, npvChange);
            marginVault.settleVariationMargin(pos.partyB, pos.collateralToken, -npvChange);
        }

        emit VariationMarginSettled(tradeId, npvChange, block.timestamp);
    }

    // ─── Internal: Position Settlement ─────────────────────────────────

    /// @dev Execute matured position settlement for a batch of positions.
    /// @param settlements Array of matured position settlement entries.
    function _executeMaturedPositionSettlement(
        MaturedPositionSettlement[] memory settlements
    ) internal {
        for (uint256 i; i < settlements.length; ++i) {
            MaturedPositionSettlement memory settlement = settlements[i];
            _settleSingleMaturedPosition(settlement.tradeId, settlement.finalNpvChange);
        }
    }

    /// @dev Settle a single matured position and release locked margin.
    /// @param tradeId The trade that has matured.
    /// @param finalNpvChange The final NPV change to settle (from fixed payer's perspective).
    function _settleSingleMaturedPosition(
        bytes32 tradeId,
        int256 finalNpvChange
    ) internal {
        NovatedPosition storage pos = positions[tradeId];
        if (!pos.active) revert PositionNotActive(tradeId);
        // TODO: enable this in production
        // if (block.timestamp < pos.maturityDate) revert PositionNotMatured(tradeId);

        // Settle final variation margin before closing position
        if (finalNpvChange != 0) {
            _settleVariationMargin(tradeId, finalNpvChange);
        }

        pos.active = false;
        --activePositionCount;

        // Release IM for both parties
        uint256 tenor = pos.maturityDate - pos.startDate;
        uint256 imRelease = riskEngine.calculateIM(pos.notional, tenor);

        marginVault.releaseInitialMargin(pos.partyA, pos.collateralToken, imRelease);
        marginVault.releaseInitialMargin(pos.partyB, pos.collateralToken, imRelease);

        // Update Maintenance Margin after position settlement
        _updateAccountMaintenanceMargin(pos.partyA, pos.collateralToken);
        _updateAccountMaintenanceMargin(pos.partyB, pos.collateralToken);

        // Remove notional from participants' total open notional
        address ownerA = whitelist.getAccountOwner(pos.partyA);
        address ownerB = whitelist.getAccountOwner(pos.partyB);
        whitelist.removeNotional(ownerA, pos.notional);
        whitelist.removeNotional(ownerB, pos.notional);

        // Burn position tokens using notional (tokens were minted with current amount)
        if (instrument.balanceOf(ownerA, pos.tokenIdA) > 0) {
            instrument.burnPosition(ownerA, pos.tokenIdA, pos.notional);
        }
        if (instrument.balanceOf(ownerB, pos.tokenIdB) > 0) {
            instrument.burnPosition(ownerB, pos.tokenIdB, pos.notional);
        }

        emit PositionMatured(tradeId, block.timestamp);
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

    /// @notice Transfer all positions from a liquidated account to a liquidator.
    /// @dev Called by the LiquidationEngine during absorbPosition.
    ///      Handles the transfer of positions, margin requirements, and notional tracking.
    ///      Also transfers ERC-1155 position tokens to maintain the invariant: token holder = position owner.
    /// @param liquidatedAccount The account being liquidated.
    /// @param liquidatorAccountId The liquidator's account taking over positions.
    /// @param collateralToken The collateral token for the liquidation.
    /// @param imAmount The initial margin amount to lock for the liquidator.
    /// @return positionIds Array of tradeIds transferred.
    function transferPositions(
        bytes32 liquidatedAccount,
        bytes32 liquidatorAccountId,
        address collateralToken,
        uint256 imAmount
    ) external onlyRole(LIQUIDATION_ENGINE_ROLE) returns (bytes32[] memory positionIds) {
        // Get all positions for the liquidated account
        bytes32[] storage positions_ = accountPositions[liquidatedAccount][collateralToken];
        
        // Get owner addresses for token transfers
        address liquidatedOwner = whitelist.getAccountOwner(liquidatedAccount);
        address liquidatorOwner = whitelist.getAccountOwner(liquidatorAccountId);
        
        // Count active positions for this collateral token
        uint256 activeCount;
        for (uint256 i = 0; i < positions_.length; i++) {
            if (positions[positions_[i]].active) {
                activeCount++;
            }
        }
        
        positionIds = new bytes32[](activeCount);
        uint256 index;
        
        // Transfer each active position for this collateral token
        for (uint256 i = 0; i < positions_.length; i++) {
            NovatedPosition storage pos = positions[positions_[i]];
            if (pos.active) {
                positionIds[index] = positions_[i];
                index++;
                
                // Determine which party is being liquidated and update
                // Also transfer the corresponding ERC-1155 position token
                if (pos.partyA == liquidatedAccount) {
                    pos.partyA = liquidatorAccountId;
                    // Transfer tokenIdA from liquidatedOwner to liquidatorOwner
                    if (instrument.balanceOf(liquidatedOwner, pos.tokenIdA) >= pos.notional) {
                        instrument.transferPosition(liquidatedOwner, liquidatorOwner, pos.tokenIdA, pos.notional);
                    }
                } else if (pos.partyB == liquidatedAccount) {
                    pos.partyB = liquidatorAccountId;
                    // Transfer tokenIdB from liquidatedOwner to liquidatorOwner
                    if (instrument.balanceOf(liquidatedOwner, pos.tokenIdB) >= pos.notional) {
                        instrument.transferPosition(liquidatedOwner, liquidatorOwner, pos.tokenIdB, pos.notional);
                    }
                }
                
                // Add position to liquidator's account
                accountPositions[liquidatorAccountId][collateralToken].push(positions_[i]);
            }
        }
        
        // Clear positions array for liquidated account (they've been transferred)
        delete accountPositions[liquidatedAccount][collateralToken];
        
        // Update notional tracking
        // Add notional to liquidator's owner
        for (uint256 i = 0; i < positionIds.length; i++) {
            NovatedPosition storage pos_ = positions[positionIds[i]];
            whitelist.addNotional(liquidatorOwner, pos_.notional);
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
        for (uint256 i = 0; i < positionIds.length; i++) {
            NovatedPosition storage pos_ = positions[positionIds[i]];
            whitelist.removeNotional(liquidatedOwner, pos_.notional);
        }
        
        emit PositionsTransferred(liquidatedAccount, liquidatorAccountId, positionIds, collateralToken);
    }

    /// @notice Get the total IM requirement for an account's positions in a specific collateral token.
    /// @param accountId The account to query.
    /// @param collateralToken The collateral token to filter by.
    /// @return totalIM The total IM required for all positions.
    function getTotalIMForToken(
        bytes32 accountId,
        address collateralToken
    ) external view returns (uint256 totalIM) {
        bytes32[] storage positions_ = accountPositions[accountId][collateralToken];
        for (uint256 i = 0; i < positions_.length; i++) {
            NovatedPosition storage pos = positions[positions_[i]];
            if (pos.active && pos.collateralToken == collateralToken) {
                uint256 tenor = pos.maturityDate - pos.startDate;
                totalIM += riskEngine.calculateIM(pos.notional, tenor);
            }
        }
    }
}
