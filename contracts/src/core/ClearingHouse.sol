// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IRSInstrument} from "./IRSInstrument.sol";
import {MarginVault} from "../margin/MarginVault.sol";
import {RiskEngine} from "../margin/RiskEngine.sol";
import {Whitelist} from "../access/Whitelist.sol";
import {YieldCurveOracle} from "../oracles/YieldCurveOracle.sol";
import {ReceiverTemplate} from "../interfaces/ReceiverTemplate.sol";

/// @title ClearingHouse
/// @notice Central coordinator for IRS trade novation, VM settlement, and position compression.
/// @dev Implements EIP-712 for gas-free matched trade submission and signature verification.
///      Inherits from ReceiverTemplate to receive reports from Chainlink CRE workflow.
contract ClearingHouse is AccessControl, ReentrancyGuard, EIP712, ReceiverTemplate {
    using ECDSA for bytes32;

    // ─── Constants ──────────────────────────────────────────────────────
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    /// @dev EIP-712 typehash for MatchedTrade struct.
    bytes32 public constant MATCHED_TRADE_TYPEHASH = keccak256(
        "MatchedTrade(bytes32 tradeId,bytes32 partyA,bytes32 partyB,uint256 notional,uint256 fixedRateBps,uint256 startDate,uint256 maturityDate,uint256 paymentInterval,uint8 dayCountConvention,bytes32 floatingRateIndex,uint256 nonce,uint256 deadline)"
    );

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice A matched trade agreement signed by both parties.
    struct MatchedTrade {
        bytes32 tradeId;            // Unique trade identifier
        bytes32 partyA;             // AccountId of party A (pays fixed)
        bytes32 partyB;             // AccountId of party B (receives fixed)
        uint256 notional;           // Notional amount
        uint256 fixedRateBps;       // Fixed rate in basis points
        uint256 startDate;          // Swap effective date
        uint256 maturityDate;       // Swap maturity date
        uint256 paymentInterval;    // Payment frequency in seconds
        uint8 dayCountConvention;   // Day-count convention
        bytes32 floatingRateIndex;  // Floating rate index identifier
        uint256 nonce;              // Replay protection nonce
        uint256 deadline;           // Signature validity deadline
    }

    /// @notice A novated position record.
    struct NovatedPosition {
        bytes32 tradeId;
        uint256 tokenIdA;           // ERC-1155 token ID for party A's leg
        uint256 tokenIdB;           // ERC-1155 token ID for party B's leg
        bytes32 partyA;
        bytes32 partyB;
        uint256 notional;           // Current notional (may be reduced after compression)
        uint256 originalNotional;   // Original notional at novation (for correct token burn)
        uint256 fixedRateBps;
        uint256 startDate;
        uint256 maturityDate;
        bool active;
        int256 lastNpv;             // Last mark-to-market NPV
    }

    /// @notice Variation margin settlement batch entry.
    struct VMSettlement {
        bytes32 accountId;
        int256 vmAmount;            // Signed VM amount (positive = credit)
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Core protocol dependencies.
    IRSInstrument public immutable instrument;
    MarginVault public immutable marginVault;
    RiskEngine public immutable riskEngine;
    Whitelist public immutable whitelist;
    YieldCurveOracle public immutable oracle;

    /// @notice Novated positions indexed by tradeId.
    mapping(bytes32 => NovatedPosition) public positions;

    /// @notice Active position tradeIds for an account.
    mapping(bytes32 => bytes32[]) public accountPositions;

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

    // ─── Events ─────────────────────────────────────────────────────────
    event TradeSubmitted(
        bytes32 indexed tradeId,
        bytes32 indexed partyA,
        bytes32 indexed partyB,
        uint256 notional,
        uint256 fixedRateBps
    );
    event TradeNovated(
        bytes32 indexed tradeId,
        uint256 tokenIdA,
        uint256 tokenIdB
    );
    event VariationMarginSettled(
        bytes32 indexed tradeId,
        int256 npvChange,
        uint256 timestamp
    );
    event PositionCompressed(
        bytes32 indexed accountId,
        bytes32 indexed tradeIdA,
        bytes32 indexed tradeIdB,
        uint256 notionalReduced
    );
    event PositionMatured(bytes32 indexed tradeId, uint256 timestamp);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // ─── Errors ─────────────────────────────────────────────────────────
    error TradeAlreadySubmitted(bytes32 tradeId);
    error InvalidSignature(bytes32 accountId);
    error SignatureExpired(uint256 deadline);
    error NonceAlreadyUsed(bytes32 accountId, uint256 nonce);
    error PartyNotWhitelisted(bytes32 accountId);
    error InsufficientMarginForTrade(bytes32 accountId);
    error PositionNotActive(bytes32 tradeId);
    error PositionNotMatured(bytes32 tradeId);
    error InvalidNotional();
    error InvalidTradeTerms();
    error NotPartyToTrade(bytes32 accountId, bytes32 tradeId);
    error PositionsNotCompressible();
    error InvalidReportType(uint8 reportType);

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the ClearingHouse.
    /// @param admin The admin address.
    /// @param forwarder The Chainlink Forwarder address for CRE reports.
    /// @param instrument_ The IRSInstrument (ERC-1155) contract.
    /// @param marginVault_ The MarginVault contract.
    /// @param riskEngine_ The RiskEngine contract.
    /// @param whitelist_ The Whitelist contract.
    /// @param oracle_ The YieldCurveOracle contract.
    constructor(
        address admin,
        address forwarder,
        address instrument_,
        address marginVault_,
        address riskEngine_,
        address whitelist_,
        address oracle_
    ) EIP712("ClearRate CCP", "1") ReceiverTemplate(forwarder) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(SETTLEMENT_ROLE, admin);

        instrument = IRSInstrument(instrument_);
        marginVault = MarginVault(marginVault_);
        riskEngine = RiskEngine(riskEngine_);
        whitelist = Whitelist(whitelist_);
        oracle = YieldCurveOracle(oracle_);
    }

    // ─── Trade Submission ───────────────────────────────────────────────

    /// @notice Submit a matched trade with EIP-712 signatures from both parties.
    /// @param trade The matched trade details.
    /// @param sigA Signature from party A.
    /// @param sigB Signature from party B.
    function submitMatchedTrade(
        MatchedTrade calldata trade,
        bytes calldata sigA,
        bytes calldata sigB
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        _executeMatchedTrade(trade, sigA, sigB);
    }

    // ─── Variation Margin Settlement ────────────────────────────────────

    /// @notice Settle variation margin for a batch of positions.
    /// @dev Called by a keeper or CRE workflow with fresh NPV calculations.
    /// @param settlements Array of VM settlement entries.
    function settleVM(
        VMSettlement[] calldata settlements
    ) external nonReentrant onlyRole(SETTLEMENT_ROLE) {
        _executeVMSettlement(settlements);
    }
    
    /// @param tradeId The unique identifier of the position to settle.
    /// @param newNpv The new NPV from the fixed payer's perspective.
    function settlePositionVM(
        bytes32 tradeId,
        int256 newNpv
    ) external nonReentrant onlyRole(SETTLEMENT_ROLE) {
        NovatedPosition storage pos = positions[tradeId];
        if (!pos.active) revert PositionNotActive(tradeId);

        int256 npvChange = newNpv - pos.lastNpv;
        pos.lastNpv = newNpv;

        // Party A is the fixed payer: positive NPV change benefits A, debits B
        if (npvChange != 0) {
            marginVault.settleVariationMargin(pos.partyA, npvChange);
            marginVault.settleVariationMargin(pos.partyB, -npvChange);
        }

        emit VariationMarginSettled(tradeId, npvChange, block.timestamp);
    }

    // ─── Position Compression ───────────────────────────────────────────

    /// @notice Compress two offsetting positions for the same account.
    /// @dev Both positions must involve the same account and have opposite directions.
    ///      The notional of both is reduced by the minimum of the two.
    /// @param tradeIdA First trade ID.
    /// @param tradeIdB Second trade ID.
    function compressPositions(
        bytes32 tradeIdA,
        bytes32 tradeIdB
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        NovatedPosition storage posA = positions[tradeIdA];
        NovatedPosition storage posB = positions[tradeIdB];

        if (!posA.active || !posB.active) revert PositionNotActive(tradeIdA);

        // Find the common account
        bytes32 commonAccount;
        if (posA.partyA == posB.partyB) {
            commonAccount = posA.partyA;
        } else if (posA.partyB == posB.partyA) {
            commonAccount = posA.partyB;
        } else {
            revert PositionsNotCompressible();
        }

        // Determine compression amount (minimum notional)
        uint256 compressionAmount = posA.notional < posB.notional
            ? posA.notional
            : posB.notional;

        // Reduce notionals
        posA.notional -= compressionAmount;
        posB.notional -= compressionAmount;

        // Deactivate fully compressed positions and update counter
        if (posA.notional == 0) {
            posA.active = false;
            --activePositionCount;
        }
        if (posB.notional == 0) {
            posB.active = false;
            --activePositionCount;
        }

        // Release IM proportionally
        uint256 tenor = posA.maturityDate - posA.startDate;
        uint256 imRelease = riskEngine.calculateIM(compressionAmount, tenor);
        marginVault.releaseInitialMargin(commonAccount, imRelease);
        
        // Update Maintenance Margin after position compression
        _updateAccountMaintenanceMargin(commonAccount);

        emit PositionCompressed(commonAccount, tradeIdA, tradeIdB, compressionAmount);
    }

    // ─── Position Maturity ──────────────────────────────────────────────

    /// @notice Settle a matured position and release locked margin.
    /// @param tradeId The trade that has matured.
    function settleMaturedPosition(
        bytes32 tradeId
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        NovatedPosition storage pos = positions[tradeId];
        if (!pos.active) revert PositionNotActive(tradeId);
        if (block.timestamp < pos.maturityDate) revert PositionNotMatured(tradeId);

        pos.active = false;
        --activePositionCount;

        // Release IM for both parties
        uint256 tenor = pos.maturityDate - pos.startDate;
        uint256 imRelease = riskEngine.calculateIM(pos.notional, tenor);

        marginVault.releaseInitialMargin(pos.partyA, imRelease);
        marginVault.releaseInitialMargin(pos.partyB, imRelease);

        // Update Maintenance Margin after position settlement
        _updateAccountMaintenanceMargin(pos.partyA);
        _updateAccountMaintenanceMargin(pos.partyB);

        // Burn position tokens using originalNotional (tokens were minted with original amount)
        address ownerA = whitelist.getAccountOwner(pos.partyA);
        address ownerB = whitelist.getAccountOwner(pos.partyB);

        if (instrument.balanceOf(ownerA, pos.tokenIdA) > 0) {
            instrument.burnPosition(ownerA, pos.tokenIdA, pos.originalNotional);
        }
        if (instrument.balanceOf(ownerB, pos.tokenIdB) > 0) {
            instrument.burnPosition(ownerB, pos.tokenIdB, pos.originalNotional);
        }

        emit PositionMatured(tradeId, block.timestamp);
    }

    // ─── Admin Functions ────────────────────────────────────────────────

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

    // ─── ReceiverTemplate Implementation ─────────────────────────────────

    /// @notice Process the report data from Chainlink CRE.
    /// @dev Called by ReceiverTemplate.onReport() after validation.
    ///      Supports two report types:
    ///      1. Trade submission: abi.encode(uint8(0), matchedTrade, sigA, sigB)
    ///      2. VM settlement: abi.encode(uint8(1), VMSettlement[])
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
        } else {
            revert InvalidReportType(reportType);
        }
    }

    /// @inheritdoc AccessControl
    /// @dev Overrides supportsInterface to include both AccessControl and ReceiverTemplate interfaces.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, ReceiverTemplate) returns (bool) {
        return AccessControl.supportsInterface(interfaceId) || ReceiverTemplate.supportsInterface(interfaceId);
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
    function getAccountPositions(bytes32 accountId) external view returns (bytes32[] memory) {
        return accountPositions[accountId];
    }

    /// @notice Get position details.
    /// @param tradeId The trade ID to query.
    /// @return The novated position struct.
    function getPosition(bytes32 tradeId) external view returns (NovatedPosition memory) {
        return positions[tradeId];
    }

    // ─── Internal Functions ─────────────────────────────────────────────

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

        // ── Whitelist Check ──
        address ownerA = whitelist.getAccountOwner(trade.partyA);
        address ownerB = whitelist.getAccountOwner(trade.partyB);
        if (!whitelist.isWhitelisted(ownerA)) revert PartyNotWhitelisted(trade.partyA);
        if (!whitelist.isWhitelisted(ownerB)) revert PartyNotWhitelisted(trade.partyB);

        // ── Margin Check ──
        uint256 tenor = trade.maturityDate - trade.startDate;

        uint256 imRequired = riskEngine.calculateIM(trade.notional, tenor);

        if (!riskEngine.checkIM(trade.partyA, imRequired)) {
            revert InsufficientMarginForTrade(trade.partyA);
        }
        if (!riskEngine.checkIM(trade.partyB, imRequired)) {
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


    /// @dev Execute VM settlement for a batch of positions.
    /// @param settlements Array of VM settlement entries.
    function _executeVMSettlement(
        VMSettlement[] memory settlements
    ) internal {
        for (uint256 i; i < settlements.length; ++i) {
            marginVault.settleVariationMargin(
                settlements[i].accountId,
                settlements[i].vmAmount
            );
        }
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
                trade.deadline
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

        // Lock Initial Margin for both parties
        marginVault.lockInitialMargin(trade.partyA, imRequired);
        marginVault.lockInitialMargin(trade.partyB, imRequired);

        // Update Maintenance Margin for both parties
        _updateAccountMaintenanceMargin(trade.partyA);
        _updateAccountMaintenanceMargin(trade.partyB);

        // Store novated position
        positions[trade.tradeId] = NovatedPosition({
            tradeId: trade.tradeId,
            tokenIdA: tokenIdA,
            tokenIdB: tokenIdB,
            partyA: trade.partyA,
            partyB: trade.partyB,
            notional: trade.notional,
            originalNotional: trade.notional,
            fixedRateBps: trade.fixedRateBps,
            startDate: trade.startDate,
            maturityDate: trade.maturityDate,
            active: true,
            lastNpv: 0
        });

        // Track positions per account
        accountPositions[trade.partyA].push(trade.tradeId);
        accountPositions[trade.partyB].push(trade.tradeId);

        ++activePositionCount;

        emit TradeNovated(trade.tradeId, tokenIdA, tokenIdB);
    }

    /// @dev Calculate aggregate initial margin for all active positions of an account.
    /// @param accountId The account identifier.
    /// @return totalIM The total IM requirement.
    function _calculateAggregateIM(bytes32 accountId) internal view returns (uint256 totalIM) {
        bytes32[] memory tradeIds = accountPositions[accountId];
        for (uint256 i = 0; i < tradeIds.length; ++i) {
            NovatedPosition storage pos = positions[tradeIds[i]];
            if (pos.active) {
                uint256 tenor = pos.maturityDate - pos.startDate;
                totalIM += riskEngine.calculateIM(pos.notional, tenor);
            }
        }
    }

    /// @dev Calculate aggregate maintenance margin for all active positions of an account.
    /// @param accountId The account identifier.
    /// @return totalMM The total MM requirement.
    function _calculateAggregateMM(bytes32 accountId) internal view returns (uint256 totalMM) {
        uint256 totalIM = _calculateAggregateIM(accountId);
        totalMM = riskEngine.calculateMM(totalIM);
    }

    /// @dev Update the maintenance margin for an account based on all active positions.
    /// @param accountId The account identifier.
    function _updateAccountMaintenanceMargin(bytes32 accountId) internal {
        uint256 newMM = _calculateAggregateMM(accountId);
        riskEngine.updateMaintenanceMargin(accountId, newMM);
    }
}
