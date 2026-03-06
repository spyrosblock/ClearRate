// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ClearingHouse} from "../core/ClearingHouse.sol";
import {RiskEngine} from "../margin/RiskEngine.sol";
import {MarginVault} from "../margin/MarginVault.sol";
import {Whitelist} from "../access/Whitelist.sol";
import {ReceiverTemplate} from "../interfaces/ReceiverTemplate.sol";

/// @title LiquidationEngine
/// @notice Dutch auction liquidation mechanism for undercollateralized accounts.
/// @dev When an account breaches maintenance margin, a Dutch auction begins where the
///      liquidation incentive decays over time until a liquidator absorbs the positions.
///      Inherits from ReceiverTemplate to receive liquidation reports from Chainlink CRE workflow.
contract LiquidationEngine is AccessControl, ReentrancyGuard, ReceiverTemplate {
    using SafeERC20 for IERC20;

    // ─── Constants ──────────────────────────────────────────────────────
    uint256 internal constant BPS = 10_000;

    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice 
    struct LiquidationTarget {
        bytes32 accountId;            // Unique identifier for the account
        address collateralToken;      // Collateral token
    }

    /// @notice State of an active liquidation auction.
    struct Auction {
        bytes32 accountId;            // Account being liquidated
        uint256 startTime;            // Auction start timestamp
        uint256 startPremiumBps;      // Initial premium in BPS (e.g. 500 = 5%)
        uint256 duration;             // Auction duration in seconds
        uint256 availableCollateral;  // Available collateral to be auctioned off
        bool active;                  // Whether the auction is still active
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Reference to the ClearingHouse.
    ClearingHouse public immutable clearingHouse;

    /// @notice Reference to the RiskEngine.
    RiskEngine public immutable riskEngine;

    /// @notice Reference to the MarginVault.
    MarginVault public immutable marginVault;

    /// @notice Reference to the Whitelist.
    Whitelist public immutable whitelist;

    /// @notice Mapping from accountId to active auction.
    mapping(bytes32 => mapping(address => Auction)) public auctions;

    /// @notice Default auction duration in seconds.
    uint256 public defaultAuctionDuration;

    /// @notice Default starting premium in BPS.
    uint256 public defaultStartPremiumBps;

    /// @notice Minimum premium at end of auction (0 = full decay).
    uint256 public minPremiumBps;

    // ─── Events ─────────────────────────────────────────────────────────
    event LiquidationStarted(
        bytes32 indexed accountId,
        address collateralToken,
        uint256 startTime,
        uint256 startPremium,
        uint256 duration,
        uint256 availableCollateral  // Total collateral to be auctioned off
    );
    event PositionsAbsorbed(
        bytes32 indexed accountId,
        address indexed collateralToken,
        bytes32 indexed liquidatorId,
        uint256 premium
    );
    event AuctionParametersUpdated(uint256 duration, uint256 startPremiumBps, uint256 minPremiumBps);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AccountNotLiquidatable(bytes32 accountId);
    error AuctionAlreadyActive(bytes32 accountId);
    error NoActiveAuction(bytes32 accountId);
    error AuctionExpired(bytes32 accountId);
    error InvalidDuration();
    error InvalidPremium();
    error LiquidatorNotWhitelisted(address liquidator);
    error InvalidReportType(uint8 reportType);
    error LiquidatorSameAsLiquidatedAccount(address liquidator);

    // ─── Constructor ────────────────────────────────────────────────────

    /// @param admin The admin address.
    /// @param forwarder The Chainlink Forwarder address for CRE reports.
    /// @param clearingHouse_ The ClearingHouse contract address.
    /// @param riskEngine_ The RiskEngine contract address.
    /// @param marginVault_ The MarginVault contract address.
    /// @param whitelist_ The Whitelist contract address.
    /// @param auctionDuration_ Default auction duration in seconds.
    /// @param startPremium_ Default starting premium in BPS.
    constructor(
        address admin,
        address forwarder,
        address clearingHouse_,
        address riskEngine_,
        address marginVault_,
        address whitelist_,
        uint256 auctionDuration_,
        uint256 startPremium_
    ) ReceiverTemplate(forwarder) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        clearingHouse = ClearingHouse(clearingHouse_);
        riskEngine = RiskEngine(riskEngine_);
        marginVault = MarginVault(marginVault_);
        whitelist = Whitelist(whitelist_);

        if (auctionDuration_ == 0) revert InvalidDuration();
        if (startPremium_ == 0 || startPremium_ > BPS) revert InvalidPremium();

        defaultAuctionDuration = auctionDuration_;
        defaultStartPremiumBps = startPremium_;
    }

    // ─── Liquidation Functions ──────────────────────────────────────────

    /// @notice Start a liquidation auction for an undercollateralized account for a specific collateral token.
    /// @param targets An array of LiquidationTarget structs.
    function liquidateAccounts(LiquidationTarget[] memory targets) external {
        for (uint i = 0; i < targets.length; i++) {
            _liquidateAccount(targets[i].accountId, targets[i].collateralToken);
        }
    }

    /// @notice Absorb positions from a liquidated account (Dutch auction bid).
    /// @dev The premium decays linearly from startPremiumBps to minPremiumBps over the auction duration.
    ///      Liquidator takes over the positions and receives a premium from the account's remaining collateral.
    /// @param accountId The account whose positions to absorb.
    /// @param collateralToken The collateral token for the liquidation.
    function absorbPositions(bytes32 accountId, address collateralToken) external nonReentrant {
        Auction storage auction = auctions[accountId][collateralToken];
        if (!auction.active) revert NoActiveAuction(accountId);

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed > auction.duration) revert AuctionExpired(accountId);

        // Get the liquidator's account ID from the whitelist
        bytes32 liquidatorAccountId = whitelist.getAccountId(msg.sender);
        if (liquidatorAccountId == accountId) {
            revert LiquidatorSameAsLiquidatedAccount(msg.sender);
        }
        
        // Verify the liquidator is whitelisted
        if (!whitelist.isWhitelisted(msg.sender)) {
            revert LiquidatorNotWhitelisted(msg.sender);
        }

        // Get total IM requirement for the liquidated account's positions in this collateral token
        uint256 imRequired = clearingHouse.getTotalIMForToken(accountId, collateralToken);

        // Transfer positions from liquidated account to liquidator
        // This will:
        // 1. Update the position's partyA/partyB to the liquidator
        // 2. Add positions to liquidator's accountPositions
        // 3. Lock IM for the liquidator
        // 4. Release IM from the liquidated account
        // 5. Update MM for both accounts
        // 6. Update notional tracking
        clearingHouse.transferPositions(
            accountId,
            liquidatorAccountId,
            collateralToken,
            imRequired
        );

        // Calculate current premium (linear decay)
        uint256 currentPremiumBps = _currentPremium(auction, elapsed);

        // Calculate and transfer the premium to the liquidator
        // Premium is based on the total collateral of the liquidated account
        uint256 totalCollateral = marginVault.getTotalCollateral(accountId, collateralToken);
        uint256 premium = (totalCollateral * currentPremiumBps) / BPS;

        if (premium > 0) {
            // Deduct premium from liquidated account's collateral via VM settlement
            // Credit the premium to liquidator's collateral
            marginVault.settleVariationMargin(accountId, collateralToken, -int256(premium));
            marginVault.settleVariationMargin(liquidatorAccountId, collateralToken, int256(premium));
        }

        // Mark auction as resolved
        auction.active = false;

        emit PositionsAbsorbed(accountId, collateralToken, liquidatorAccountId, premium);
    }

    // ─── Admin Functions ────────────────────────────────────────────────

    /// @notice Update default auction parameters.
    /// @param duration_ New default auction duration.
    /// @param startPremium_ New default starting premium in BPS.
    /// @param minPremium_ New minimum premium at auction end in BPS.
    function setAuctionParameters(
        uint256 duration_,
        uint256 startPremium_,
        uint256 minPremium_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration_ == 0) revert InvalidDuration();
        if (startPremium_ == 0 || startPremium_ > BPS) revert InvalidPremium();
        if (minPremium_ > startPremium_) revert InvalidPremium();

        defaultAuctionDuration = duration_;
        defaultStartPremiumBps = startPremium_;
        minPremiumBps = minPremium_;

        emit AuctionParametersUpdated(duration_, startPremium_, minPremium_);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get the current premium for an active auction.
    /// @param accountId The account in liquidation.
    /// @return premiumBps The current premium in BPS.
    function getCurrentPremium(bytes32 accountId, address collateralToken) external view returns (uint256 premiumBps) {
        Auction storage auction = auctions[accountId][collateralToken];
        if (!auction.active) revert NoActiveAuction(accountId);

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed > auction.duration) return minPremiumBps;

        premiumBps = _currentPremium(auction, elapsed);
    }

    /// @notice Check if an auction is active for an account.
    /// @param accountId The account to check.
    /// @return True if an auction is currently active.
    function isAuctionActive(bytes32 accountId, address collateralToken) external view returns (bool) {
        return auctions[accountId][collateralToken].active;
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _liquidateAccount(bytes32 accountId, address collateralToken) internal {
        if (!riskEngine.isLiquidatable(accountId, collateralToken)) {
            revert AccountNotLiquidatable(accountId);
        }
        if (auctions[accountId][collateralToken].active) {
            revert AuctionAlreadyActive(accountId);
        }

        uint256 totalCollateral = marginVault.getTotalCollateral(accountId, collateralToken);
        uint256 lockedIM = riskEngine.accountInitialMargin(accountId, collateralToken);
        uint256 availableCollateral = totalCollateral > lockedIM ? totalCollateral - lockedIM : 0;

        auctions[accountId][collateralToken] = Auction({
            accountId: accountId,
            startTime: block.timestamp,
            startPremiumBps: defaultStartPremiumBps,
            duration: defaultAuctionDuration,
            availableCollateral: availableCollateral,
            active: true
        });

        emit LiquidationStarted(
            accountId,
            collateralToken,
            block.timestamp,
            defaultStartPremiumBps,
            defaultAuctionDuration,
            availableCollateral
        );
    }

    /// @dev Calculate the current premium based on linear decay.
    function _currentPremium(
        Auction storage auction,
        uint256 elapsed
    ) internal view returns (uint256) {
        uint256 range = auction.startPremiumBps - minPremiumBps;
        uint256 decay = (range * elapsed) / auction.duration;
        return auction.startPremiumBps - decay;
    }

    // ─── ReceiverTemplate Implementation ────────────────────────────────

    /// @inheritdoc AccessControl
    /// @dev Overrides supportsInterface to include both AccessControl and ReceiverTemplate interfaces.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, ReceiverTemplate) returns (bool) {
        return AccessControl.supportsInterface(interfaceId) || ReceiverTemplate.supportsInterface(interfaceId);
    }

    /// @notice Process the report data from Chainlink CRE.
    /// @dev Called by ReceiverTemplate.onReport() after validation.
    ///      Supports one report type:
    ///      1. Liquidate accounts: abi.encode(uint8(0), LiquidationTarget[] targets)
    /// @param report ABI-encoded report data with type prefix
    function _processReport(
        bytes calldata report
    ) internal override {
        // Decode the first byte to determine report type
        (uint8 reportType) = abi.decode(report[:32], (uint8));

        if (reportType == 0) {
            // Liquidate accounts report
            // Decode: (uint8, LiquidationTarget[] targets)
            (, LiquidationTarget[] memory targets) = abi.decode(
                report,
                (uint8, LiquidationTarget[])
            );
            for (uint i = 0; i < targets.length; i++) {
                _liquidateAccount(targets[i].accountId, targets[i].collateralToken);
            }
        } else {
            revert InvalidReportType(reportType);
        }
    }
}
