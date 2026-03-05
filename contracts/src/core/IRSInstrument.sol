// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title IRSInstrument
/// @notice ERC-1155 token representing novated IRS position legs.
/// @dev Each token ID encodes a unique swap leg. The ClearingHouse is the sole minter/burner.
///      Token amounts represent notional in the collateral token's decimals.
contract IRSInstrument is ERC1155, AccessControl {
    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── Constants ──────────────────────────────────────────────────────

    /// @notice Allowed floating rate indices.
    bytes32 public constant SOFR_INDEX = keccak256("SOFR");
    bytes32 public constant EUROSTR_INDEX = keccak256("EuroSTR");

    // ─── Enums ──────────────────────────────────────────────────────────

    /// @notice Direction of the swap leg from the holder's perspective.
    enum Direction {
        PAY_FIXED,     // Holder pays fixed, receives floating
        RECEIVE_FIXED  // Holder receives fixed, pays floating
    }

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice Full specification of an IRS swap leg.
    struct SwapTerms {
        uint256 notional;          // Notional amount in collateral token decimals
        uint256 fixedRateBps;      // Fixed rate in basis points (e.g. 500 = 5.00%)
        uint256 startDate;         // Swap effective date (Unix timestamp)
        uint256 maturityDate;      // Swap maturity date (Unix timestamp)
        uint256 paymentInterval;   // Payment frequency in seconds (e.g. 90 days)
        Direction direction;       // PAY_FIXED or RECEIVE_FIXED
        bytes32 floatingRateIndex; // Identifier for floating rate (e.g. keccak256("SOFR"))
        uint8 dayCountConvention;  // 0=ACT/360, 1=ACT/365, 2=30/360
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Mapping from token ID to swap terms.
    mapping(uint256 => SwapTerms) public swapTerms;

    /// @notice Counter for generating unique token IDs.
    uint256 public nextTokenId;

    /// @notice Mapping from token ID to whether it has been minted.
    mapping(uint256 => bool) public tokenExists;

    // ─── Events ─────────────────────────────────────────────────────────
    event SwapPositionMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint256 notional,
        uint256 fixedRateBps,
        Direction direction
    );
    event SwapPositionBurned(uint256 indexed tokenId, address indexed from, uint256 amount);

    // ─── Errors ─────────────────────────────────────────────────────────
    error TokenDoesNotExist(uint256 tokenId);
    error InvalidSwapTerms();
    error MaturityBeforeStart();
    error ZeroNotional();
    error InvalidFloatingRateIndex();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the IRSInstrument contract.
    /// @param admin The admin address.
    /// @param uri_ The metadata URI for ERC-1155 tokens.
    constructor(
        address admin,
        string memory uri_
    ) ERC1155(uri_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Mint a new IRS position token (called during novation).
    /// @param to The address to receive the position token.
    /// @param terms The full swap terms for this position.
    /// @return tokenId The newly minted token ID.
    function mintPosition(
        address to,
        SwapTerms calldata terms
    ) external onlyRole(CLEARING_HOUSE_ROLE) returns (uint256 tokenId) {
        _validateTerms(terms);

        tokenId = nextTokenId++;
        swapTerms[tokenId] = terms;
        tokenExists[tokenId] = true;

        _mint(to, tokenId, terms.notional, "");

        emit SwapPositionMinted(
            tokenId,
            to,
            terms.notional,
            terms.fixedRateBps,
            terms.direction
        );
    }

    /// @notice Burn a position token (called during compression or settlement).
    /// @param from The address holding the position token.
    /// @param tokenId The token ID to burn.
    /// @param amount The amount (notional) to burn.
    function burnPosition(
        address from,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (!tokenExists[tokenId]) revert TokenDoesNotExist(tokenId);
        _burn(from, tokenId, amount);
        emit SwapPositionBurned(tokenId, from, amount);
    }

    /// @notice Transfer a position token from one address to another (called during liquidation).
    /// @dev Called by ClearingHouse during transferPositions to maintain token holder = position owner invariant.
    /// @param from The address currently holding the position token.
    /// @param to The address to receive the position token.
    /// @param tokenId The token ID to transfer.
    /// @param amount The amount (notional) to transfer.
    function transferPosition(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (!tokenExists[tokenId]) revert TokenDoesNotExist(tokenId);
        _safeTransferFrom(from, to, tokenId, amount, "");
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get the full swap terms for a token ID.
    /// @param tokenId The token ID to query.
    /// @return terms The swap terms struct.
    function getSwapTerms(uint256 tokenId) external view returns (SwapTerms memory terms) {
        if (!tokenExists[tokenId]) revert TokenDoesNotExist(tokenId);
        terms = swapTerms[tokenId];
    }

    /// @notice Check if a position has matured.
    /// @param tokenId The token ID to check.
    /// @return True if the current timestamp is past the maturity date.
    function isMatured(uint256 tokenId) external view returns (bool) {
        if (!tokenExists[tokenId]) revert TokenDoesNotExist(tokenId);
        return block.timestamp >= swapTerms[tokenId].maturityDate;
    }

    /// @notice Get the remaining time to maturity in seconds.
    /// @param tokenId The token ID to check.
    /// @return remaining Seconds until maturity (0 if already matured).
    function timeToMaturity(uint256 tokenId) external view returns (uint256 remaining) {
        if (!tokenExists[tokenId]) revert TokenDoesNotExist(tokenId);
        if (block.timestamp >= swapTerms[tokenId].maturityDate) return 0;
        remaining = swapTerms[tokenId].maturityDate - block.timestamp;
    }

    // ─── ERC-165 Support ────────────────────────────────────────────────

    /// @notice Override supportsInterface for both ERC1155 and AccessControl.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Validate swap terms before minting.
    function _validateTerms(SwapTerms calldata terms) internal pure {
        if (terms.notional == 0) revert ZeroNotional();
        if (terms.maturityDate <= terms.startDate) revert MaturityBeforeStart();
        if (terms.fixedRateBps == 0) revert InvalidSwapTerms();
        if (terms.paymentInterval == 0) revert InvalidSwapTerms();
        if (terms.floatingRateIndex != SOFR_INDEX && terms.floatingRateIndex != EUROSTR_INDEX) {
            revert InvalidFloatingRateIndex();
        }
    }
}
