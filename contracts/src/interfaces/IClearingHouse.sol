// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title IClearingHouse
/// @notice Interface for the ClearingHouse contract.
/// @dev Contains structs, events, and errors used by the ClearingHouse.
interface IClearingHouse {
    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice A matched trade agreement signed by both parties.
    struct MatchedTrade {
        bytes32 tradeId;           // Unique trade identifier
        bytes32 partyA;            // AccountId of party A (pays fixed)
        bytes32 partyB;            // AccountId of party B (receives fixed)
        uint256 notional;          // Notional amount
        uint256 fixedRateBps;      // Fixed rate in basis points
        uint256 startDate;         // Swap effective date
        uint256 maturityDate;      // Swap maturity date
        uint256 paymentInterval;   // Payment frequency in seconds
        uint8 dayCountConvention;  // Day-count convention
        bytes32 floatingRateIndex; // Floating rate index identifier
        uint256 nonce;             // Replay protection nonce
        uint256 deadline;          // Signature validity deadline
        address collateralToken;   // Single collateral token for IM and VM
    }

    /// @notice A novated position record.
    struct NovatedPosition {
        bytes32 tradeId;
        uint256 tokenIdA;           // ERC-1155 token ID for party A's leg
        uint256 tokenIdB;           // ERC-1155 token ID for party B's leg
        bytes32 partyA;
        bytes32 partyB;
        uint256 notional;           // Current notional (may be reduced after compression)
        uint256 fixedRateBps;
        uint256 startDate;
        uint256 maturityDate;
        bool active;
        int256 lastNpv;             // Last mark-to-market NPV
        address collateralToken;    // Single collateral token for IM and VM
    }

    /// @notice Variation margin settlement batch entry.
    struct VMSettlement {
        bytes32 tradeId;            // Unique trade identifier
        int256 npvChange;           // NPV change from the fixed payer's perspective
    }

    /// @notice Matured position settlement entry.
    struct MaturedPositionSettlement {
        bytes32 tradeId;            // Unique trade identifier
        int256 finalNpvChange;     // Final NPV change to settle (from fixed payer's perspective)
    }

    /// @notice New compressed position to be created during compression.
    struct NewCompressedPosition {
        bytes32 tradeId;           // New trade ID for the compressed position
        bytes32 partyA;            // AccountId of party A (pays fixed)
        bytes32 partyB;            // AccountId of party B (receives fixed)
        uint256 notional;          // New notional amount (reduced)
        uint256 fixedRateBps;      // Fixed rate in basis points
        uint256 startDate;         // Swap effective date
        uint256 maturityDate;      // Swap maturity date
        uint256 paymentInterval;   // Payment frequency in seconds
        uint8 dayCountConvention;  // Day-count convention
        bytes32 floatingRateIndex; // Floating rate index identifier
        address collateralToken;   // Collateral token for the position
    }

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
        uint256 tokenIdB,
        bytes32 indexed partyA,
        bytes32 indexed partyB,
        uint256 notional,
        uint256 fixedRateBps,
        uint256 startDate,
        uint256 maturityDate,
        uint256 paymentInterval,
        uint8 dayCountConvention,
        bytes32 floatingRateIndex,
        address collateralToken
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
    event PositionsTransferred(
        bytes32 indexed fromAccount,
        bytes32 indexed toAccount,
        bytes32[] positionIds,
        address collateralToken
    );

    // ─── Errors ─────────────────────────────────────────────────────────

    error TradeAlreadySubmitted(bytes32 tradeId);
    error InvalidSignature(bytes32 accountId);
    error SignatureExpired(uint256 deadline);
    error NonceAlreadyUsed(bytes32 accountId, uint256 nonce);
    error PartyNotWhitelisted(bytes32 accountId);
    error KycExpired(bytes32 accountId, uint64 expiry);
    error ExceedsMaxNotional(bytes32 accountId, uint256 requested, uint256 currentTotal, uint256 maxAllowed);
    error InsufficientMarginForTrade(bytes32 accountId);
    error PositionNotActive(bytes32 tradeId);
    error PositionNotMatured(bytes32 tradeId);
    error InvalidNotional();
    error InvalidTradeTerms();
    error NotPartyToTrade(bytes32 accountId, bytes32 tradeId);
    error PositionsNotCompressible();
    error InvalidReportType(uint8 reportType);
    error InvalidCollateralToken(address token);
}
