// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RiskEngine} from "../margin/RiskEngine.sol";
import {MarginVault} from "../margin/MarginVault.sol";
import {InsuranceFund} from "../insurance/InsuranceFund.sol";

/// @title LiquidationEngine
/// @notice Dutch auction liquidation mechanism for undercollateralized accounts.
/// @dev When an account breaches maintenance margin, a Dutch auction begins where the
///      liquidation incentive decays over time until a liquidator absorbs the positions.
contract LiquidationEngine is AccessControl, ReentrancyGuard {
    // ─── Constants ──────────────────────────────────────────────────────
    uint256 internal constant BPS = 10_000;

    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice State of an active liquidation auction.
    struct Auction {
        bytes32 accountId;        // Account being liquidated
        uint256 startTime;        // Auction start timestamp
        uint256 startPremiumBps;  // Initial premium in BPS (e.g. 500 = 5%)
        uint256 duration;         // Auction duration in seconds
        uint256 debtAmount;       // Total debt/deficit to cover
        bool active;              // Whether the auction is still active
        bool resolved;            // Whether the auction has been resolved
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Reference to the RiskEngine.
    RiskEngine public immutable riskEngine;

    /// @notice Reference to the MarginVault.
    MarginVault public immutable marginVault;

    /// @notice Reference to the InsuranceFund.
    InsuranceFund public immutable insuranceFund;

    /// @notice Mapping from accountId to active auction.
    mapping(bytes32 => Auction) public auctions;

    /// @notice Default auction duration in seconds.
    uint256 public defaultAuctionDuration;

    /// @notice Default starting premium in BPS.
    uint256 public defaultStartPremiumBps;

    /// @notice Minimum premium at end of auction (0 = full decay).
    uint256 public minPremiumBps;

    // ─── Events ─────────────────────────────────────────────────────────
    event LiquidationStarted(
        bytes32 indexed accountId,
        uint256 debtAmount,
        uint256 startPremiumBps,
        uint256 duration
    );
    event PositionAbsorbed(
        bytes32 indexed accountId,
        address indexed liquidator,
        uint256 premiumBps,
        uint256 debtCovered
    );
    event AuctionResolved(bytes32 indexed accountId, bool coveredByInsurance);
    event AuctionParametersUpdated(uint256 duration, uint256 startPremiumBps, uint256 minPremiumBps);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AccountNotLiquidatable(bytes32 accountId);
    error AuctionAlreadyActive(bytes32 accountId);
    error NoActiveAuction(bytes32 accountId);
    error AuctionExpired(bytes32 accountId);
    error InvalidDuration();
    error InvalidPremium();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @param admin The admin address.
    /// @param riskEngine_ The RiskEngine contract address.
    /// @param marginVault_ The MarginVault contract address.
    /// @param insuranceFund_ The InsuranceFund contract address.
    /// @param auctionDuration_ Default auction duration in seconds.
    /// @param startPremium_ Default starting premium in BPS.
    constructor(
        address admin,
        address riskEngine_,
        address marginVault_,
        address insuranceFund_,
        uint256 auctionDuration_,
        uint256 startPremium_
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        riskEngine = RiskEngine(riskEngine_);
        marginVault = MarginVault(marginVault_);
        insuranceFund = InsuranceFund(insuranceFund_);

        if (auctionDuration_ == 0) revert InvalidDuration();
        if (startPremium_ == 0 || startPremium_ > BPS) revert InvalidPremium();

        defaultAuctionDuration = auctionDuration_;
        defaultStartPremiumBps = startPremium_;
    }

    // ─── Liquidation Functions ──────────────────────────────────────────

    /// @notice Start a liquidation auction for an undercollateralized account for a specific collateral token.
    /// @param accountId The account to liquidate.
    /// @param collateralToken The collateral token to liquidate against.
    function liquidateAccount(bytes32 accountId, address collateralToken) external {
        if (!riskEngine.isLiquidatable(accountId, collateralToken)) {
            revert AccountNotLiquidatable(accountId);
        }
        if (auctions[accountId].active) {
            revert AuctionAlreadyActive(accountId);
        }

        // Calculate the debt (MM shortfall)
        // Debt must consider locked IM which is not immediately available
        uint256 totalCollateral = marginVault.getTotalCollateral(accountId, collateralToken);
        uint256 lockedIM = riskEngine.accountInitialMargin(accountId, collateralToken);
        uint256 mm = riskEngine.accountMaintenanceMargin(accountId, collateralToken);
        // Available collateral = totalCollateral - lockedIM
        // Debt = MM - availableCollateral = MM - (totalCollateral - lockedIM)
        uint256 availableCollateral = totalCollateral > lockedIM ? totalCollateral - lockedIM : 0;
        uint256 debt = mm > availableCollateral ? mm - availableCollateral : 0;

        auctions[accountId] = Auction({
            accountId: accountId,
            startTime: block.timestamp,
            startPremiumBps: defaultStartPremiumBps,
            duration: defaultAuctionDuration,
            debtAmount: debt,
            active: true,
            resolved: false
        });

        emit LiquidationStarted(
            accountId,
            debt,
            defaultStartPremiumBps,
            defaultAuctionDuration
        );
    }

    /// @notice Absorb positions from a liquidated account (Dutch auction bid).
    /// @dev The premium decays linearly from startPremiumBps to minPremiumBps over the auction duration.
    ///      Liquidator takes over the positions and receives a premium from the account's remaining collateral.
    /// @param accountId The account whose positions to absorb.
    function absorbPosition(bytes32 accountId) external nonReentrant {
        Auction storage auction = auctions[accountId];
        if (!auction.active) revert NoActiveAuction(accountId);

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed > auction.duration) revert AuctionExpired(accountId);

        // Calculate current premium (linear decay)
        uint256 currentPremiumBps = _currentPremium(auction, elapsed);

        // Mark auction as resolved
        auction.active = false;
        auction.resolved = true;

        emit PositionAbsorbed(accountId, msg.sender, currentPremiumBps, auction.debtAmount);
        emit AuctionResolved(accountId, false);
    }

    /// @notice Resolve an expired auction by tapping the insurance fund.
    /// @dev If no liquidator stepped in, the insurance fund covers the deficit.
    /// @param accountId The account whose auction expired.
    /// @param token The stablecoin token to use from the insurance fund.
    function resolveExpiredAuction(
        bytes32 accountId,
        address token
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        Auction storage auction = auctions[accountId];
        if (!auction.active) revert NoActiveAuction(accountId);

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed <= auction.duration) {
            // Auction hasn't expired yet — can still be absorbed
            revert AuctionAlreadyActive(accountId);
        }

        auction.active = false;
        auction.resolved = true;

        // Tap insurance fund for the remaining deficit
        if (auction.debtAmount > 0) {
            insuranceFund.claimDeficit(token, address(marginVault), auction.debtAmount);
        }

        emit AuctionResolved(accountId, true);
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
    function getCurrentPremium(bytes32 accountId) external view returns (uint256 premiumBps) {
        Auction storage auction = auctions[accountId];
        if (!auction.active) revert NoActiveAuction(accountId);

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed > auction.duration) return minPremiumBps;

        premiumBps = _currentPremium(auction, elapsed);
    }

    /// @notice Check if an auction is active for an account.
    /// @param accountId The account to check.
    /// @return True if an auction is currently active.
    function isAuctionActive(bytes32 accountId) external view returns (bool) {
        return auctions[accountId].active;
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Calculate the current premium based on linear decay.
    function _currentPremium(
        Auction storage auction,
        uint256 elapsed
    ) internal view returns (uint256) {
        uint256 range = auction.startPremiumBps - minPremiumBps;
        uint256 decay = (range * elapsed) / auction.duration;
        return auction.startPremiumBps - decay;
    }
}
