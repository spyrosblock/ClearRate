// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MarginVault} from "./MarginVault.sol";

/// @title RiskEngine
/// @notice Validates initial margin, maintenance margin, and liquidation eligibility.
/// @dev Risk weights are tenor-dependent. Confidence multiplier is configurable.
contract RiskEngine is AccessControl {
    // ─── Constants ──────────────────────────────────────────────────────
    uint256 internal constant BPS = 10_000;

    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Reference to the MarginVault.
    MarginVault public immutable marginVault;

    /// @notice Risk weight in BPS per tenor bucket (seconds → bps).
    /// @dev E.g., 1 year = 31536000 seconds → 200 bps (2%) risk weight.
    mapping(uint256 => uint256) public riskWeightBps;

    /// @notice Confidence multiplier in BPS (e.g. 9900 = 99% confidence).
    uint256 public confidenceBps;

    /// @notice Maintenance margin as a fraction of IM in BPS (e.g. 7500 = 75% of IM).
    uint256 public maintenanceMarginRatioBps;

    /// @notice Per-account maintenance margin requirement per collateral token.
    mapping(bytes32 => mapping(address => uint256)) public accountMaintenanceMargin;

    // ─── Events ─────────────────────────────────────────────────────────
    event RiskWeightUpdated(uint256 indexed tenor, uint256 oldWeight, uint256 newWeight);
    event ConfidenceUpdated(uint256 oldConfidence, uint256 newConfidence);
    event MaintenanceMarginRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event AccountMMUpdated(bytes32 indexed accountId, address collateralToken, uint256 oldMM, uint256 newMM);

    // ─── Errors ─────────────────────────────────────────────────────────
    error InsufficientInitialMargin(bytes32 accountId, uint256 required, uint256 available);
    error InsufficientMaintenanceMargin(bytes32 accountId, uint256 required, uint256 available);
    error InvalidRiskWeight();
    error InvalidConfidence();
    error InvalidMMRatio();
    error NoRiskWeightForTenor(uint256 tenor);

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the RiskEngine.
    /// @param admin The admin address.
    /// @param vault The MarginVault address.
    /// @param initialConfidenceBps Initial confidence multiplier in BPS.
    /// @param initialMMRatioBps Initial maintenance margin ratio in BPS.
    constructor(
        address admin,
        address vault,
        uint256 initialConfidenceBps,
        uint256 initialMMRatioBps
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN_ROLE, admin);

        marginVault = MarginVault(vault);

        if (initialConfidenceBps == 0 || initialConfidenceBps > BPS) revert InvalidConfidence();
        if (initialMMRatioBps == 0 || initialMMRatioBps > BPS) revert InvalidMMRatio();

        confidenceBps = initialConfidenceBps;
        maintenanceMarginRatioBps = initialMMRatioBps;
    }

    // ─── Risk Weight Management ─────────────────────────────────────────

    /// @notice Set the risk weight for a tenor bucket.
    /// @param tenor The tenor in seconds.
    /// @param weightBps The risk weight in basis points.
    function setRiskWeight(
        uint256 tenor,
        uint256 weightBps
    ) external onlyRole(RISK_ADMIN_ROLE) {
        if (weightBps == 0 || weightBps > BPS) revert InvalidRiskWeight();
        uint256 oldWeight = riskWeightBps[tenor];
        riskWeightBps[tenor] = weightBps;
        emit RiskWeightUpdated(tenor, oldWeight, weightBps);
    }

    /// @notice Update the confidence multiplier.
    /// @param newConfidenceBps New confidence in BPS.
    function setConfidence(uint256 newConfidenceBps) external onlyRole(RISK_ADMIN_ROLE) {
        if (newConfidenceBps == 0 || newConfidenceBps > BPS) revert InvalidConfidence();
        emit ConfidenceUpdated(confidenceBps, newConfidenceBps);
        confidenceBps = newConfidenceBps;
    }

    /// @notice Update the maintenance margin ratio.
    /// @param newRatioBps New MM ratio in BPS.
    function setMaintenanceMarginRatio(uint256 newRatioBps) external onlyRole(RISK_ADMIN_ROLE) {
        if (newRatioBps == 0 || newRatioBps > BPS) revert InvalidMMRatio();
        emit MaintenanceMarginRatioUpdated(maintenanceMarginRatioBps, newRatioBps);
        maintenanceMarginRatioBps = newRatioBps;
    }

    // ─── IM/MM Computation ──────────────────────────────────────────────

    /// @notice Calculate the initial margin requirement for a single position.
    /// @param notional The notional amount.
    /// @param tenor The tenor of the swap in seconds.
    /// @return im The initial margin requirement.
    function calculateIM(
        uint256 notional,
        uint256 tenor
    ) public view returns (uint256 im) {
        uint256 weight = riskWeightBps[tenor];
        if (weight == 0) revert NoRiskWeightForTenor(tenor);
        im = (notional * weight * confidenceBps) / (BPS * BPS);
    }

    /// @notice Calculate the maintenance margin for a given IM amount.
    /// @param im The initial margin amount.
    /// @return mm The maintenance margin requirement.
    function calculateMM(uint256 im) public view returns (uint256 mm) {
        mm = (im * maintenanceMarginRatioBps) / BPS;
    }

    // ─── Validation ─────────────────────────────────────────────────────

    /// @notice Check if an account has sufficient collateral to meet IM for a new trade.
    /// @param accountId The  account identifier.
    /// @param additionalIM The IM required for the new trade.
    /// @param collateralToken The collateral token to check against.
    /// @return True if the account passes the IM check.
    function checkIM(
        bytes32 accountId,
        uint256 additionalIM,
        address collateralToken
    ) external view returns (bool) {
        uint256 freeMargin = marginVault.getFreeMarginByToken(accountId, collateralToken);
        return freeMargin >= additionalIM;
    }

    /// @notice Check if an account meets its maintenance margin requirement for a specific collateral token.
    /// @param accountId The account identifier.
    /// @param collateralToken The collateral token to check against.
    /// @return True if the account passes the MM check.
    function checkMM(bytes32 accountId, address collateralToken) external view returns (bool) {
        uint256 totalCollateral = marginVault.getTotalCollateral(accountId, collateralToken);
        uint256 mm = accountMaintenanceMargin[accountId][collateralToken];
        return totalCollateral >= mm;
    }

    /// @notice Check if an account is eligible for liquidation for a specific collateral token.
    /// @param accountId The account identifier.
    /// @param collateralToken The collateral token to check against.
    /// @return True if the account's collateral is below maintenance margin.
    function isLiquidatable(bytes32 accountId, address collateralToken) external view returns (bool) {
        uint256 totalCollateral = marginVault.getTotalCollateral(accountId, collateralToken);
        uint256 mm = accountMaintenanceMargin[accountId][collateralToken];
        return totalCollateral < mm;
    }

    // ─── Account Margin Updates ─────────────────────────────────────────

    /// @notice Update the maintenance margin for an account for a specific collateral token.
    /// @param accountId The account identifier.
    /// @param collateralToken The collateral token.
    /// @param newMM The new maintenance margin requirement.
    function updateMaintenanceMargin(
        bytes32 accountId,
        address collateralToken,
        uint256 newMM
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        uint256 oldMM = accountMaintenanceMargin[accountId][collateralToken];
        accountMaintenanceMargin[accountId][collateralToken] = newMM;
        emit AccountMMUpdated(accountId, collateralToken, oldMM, newMM);
    }
}
