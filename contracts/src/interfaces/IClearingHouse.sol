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

    /// @notice Variation margin settlement batch entry.
    /// @dev Each settlement is for a specific account. The vmChange is aggregated across all positions for the account.
    struct VMSettlement {
        bytes32 accountId;
        address collateralToken;
        int256 vmChange;
    }
    
    struct NPVChange {
        uint256 tokenId;
        int256 npvChange;
    }

    /// @notice Matured position entry for settlement.
    /// @dev Used to close matured positions and release margin.
    struct MaturedPosition {
        bytes32 accountId;  // Account that holds the position
        uint256 tokenId;    // The token that has matured
    }

    // ─── Events ─────────────────────────────────────────────────────────

    event TradeSubmitted(bytes32 indexed tradeId);
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
        address collateralToken,
        uint256 newMMA,
        uint256 newMMB
    );
    event NpvUpdated(
        uint256 indexed tokenId,
        int256 npvChange,
        uint256 timestamp
    );
    event AccountVariationMarginSettled(
        bytes32 indexed accountId,
        int256 vmChange,
        uint256 timestamp
    );
    event PositionMatured(uint256 indexed tokenId, bytes32 indexed accountId, uint256 newMM);
    event PositionClosed(uint256 indexed tokenId, bytes32 accountId);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event PositionsAbsorbed(
        bytes32 indexed fromAccount,
        bytes32 indexed toAccount,
        uint256[] tokenIds,
        address collateralToken,
        int256 liquidatedTransfer,
        uint256 newMMLiquidated,
        uint256 newMMLiquidator
    );
    event PositionTransferred(
        uint256 indexed tokenId,
        bytes32 indexed fromAccount,
        bytes32 indexed toAccount,
        uint256 amount,
        address collateralToken,
        uint256 newMMFrom,
        uint256 newMMTo
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
    error PositionNotActive(uint256 tokenId);
    error PositionNotMatured(uint256 tokenId);
    error TokenDoesNotExist(uint256 tokenId);
    error InvalidNotional();
    error InvalidTradeTerms();
    error NotPartyToTrade(bytes32 accountId, uint256 tokenId);
    error PositionsNotCompressible();
    error InvalidReportType(uint8 reportType);
    error InvalidCollateralToken(address token);
    error InsufficientTokenBalance(uint256 tokenId, uint256 requested, uint256 available);
    error AccountNotFound(bytes32 accountId);
    error RecipientNotWhitelisted(bytes32 accountId);
}
