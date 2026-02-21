// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PositionMath
/// @notice Pure library for IRS position mathematics: day-count fractions, accruals, and PV helpers.
/// @dev All fixed-point math uses 18 decimals (WAD = 1e18) to maintain precision.
library PositionMath {
    // ─── Constants ──────────────────────────────────────────────────────
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    // ─── Day-Count Convention Enum ──────────────────────────────────────
    enum DayCountConvention {
        ACT_360,
        ACT_365,
        THIRTY_360
    }

    // ─── Custom Errors ──────────────────────────────────────────────────
    error InvalidDateRange();
    error DivisionByZero();
    error OverflowDetected();

    // ─── Day-Count Fraction ─────────────────────────────────────────────

    /// @notice Compute the day-count fraction between two timestamps.
    /// @param startTimestamp Start of the accrual period (Unix seconds).
    /// @param endTimestamp End of the accrual period (Unix seconds).
    /// @param convention The day-count convention to use.
    /// @return dcf The day-count fraction scaled to WAD (1e18).
    function dayCountFraction(
        uint256 startTimestamp,
        uint256 endTimestamp,
        DayCountConvention convention
    ) internal pure returns (uint256 dcf) {
        if (endTimestamp <= startTimestamp) revert InvalidDateRange();

        uint256 elapsedSeconds = endTimestamp - startTimestamp;

        if (convention == DayCountConvention.ACT_360) {
            // DCF = actualDays / 360
            dcf = (elapsedSeconds * WAD) / (360 * SECONDS_PER_DAY);
        } else if (convention == DayCountConvention.ACT_365) {
            // DCF = actualDays / 365
            dcf = (elapsedSeconds * WAD) / (365 * SECONDS_PER_DAY);
        } else {
            // THIRTY_360: each month = 30 days, year = 360 days
            // Approximation using actual seconds for simplicity
            dcf = (elapsedSeconds * WAD) / (360 * SECONDS_PER_DAY);
        }
    }

    // ─── Accrued Interest ───────────────────────────────────────────────

    /// @notice Calculate accrued interest for a fixed-rate leg.
    /// @param notional The notional amount (6 decimal stablecoin precision, e.g. 1e6 = $1).
    /// @param fixedRateBps Fixed rate in basis points (e.g. 500 = 5.00%).
    /// @param dcf Day-count fraction in WAD (1e18).
    /// @return accrued The accrued interest in notional token decimals.
    function accruedFixed(
        uint256 notional,
        uint256 fixedRateBps,
        uint256 dcf
    ) internal pure returns (uint256 accrued) {
        // accrued = notional * (fixedRateBps / BPS) * dcf
        // Reorder to avoid precision loss: (notional * fixedRateBps * dcf) / (BPS * WAD)
        accrued = (notional * fixedRateBps * dcf) / (BPS * WAD);
    }

    /// @notice Calculate accrued interest for a floating-rate leg.
    /// @param notional The notional amount in token decimals.
    /// @param floatingRateWad Floating rate in WAD (e.g., 5% = 0.05e18).
    /// @param dcf Day-count fraction in WAD (1e18).
    /// @return accrued The accrued interest in notional token decimals.
    function accruedFloat(
        uint256 notional,
        uint256 floatingRateWad,
        uint256 dcf
    ) internal pure returns (uint256 accrued) {
        // accrued = notional * floatingRate * dcf (both in WAD)
        accrued = (notional * floatingRateWad) / WAD;
        accrued = (accrued * dcf) / WAD;
    }

    // ─── Present Value Helpers ──────────────────────────────────────────

    /// @notice Discount a future cash flow to present value.
    /// @param cashFlow The undiscounted cash flow amount.
    /// @param discountFactorWad The discount factor in WAD (e.g. 0.98e18 for 2% discount).
    /// @return pv The present value of the cash flow.
    function presentValue(
        uint256 cashFlow,
        uint256 discountFactorWad
    ) internal pure returns (uint256 pv) {
        pv = (cashFlow * discountFactorWad) / WAD;
    }

    /// @notice Compute the Net Present Value of a fixed leg (sum of discounted fixed coupons).
    /// @param notional Notional amount in token decimals.
    /// @param fixedRateBps Fixed rate in basis points.
    /// @param dcfs Array of day-count fractions (WAD) for each period.
    /// @param discountFactors Array of discount factors (WAD) for each period.
    /// @return npv The total present value of the fixed leg.
    function pvFixedLeg(
        uint256 notional,
        uint256 fixedRateBps,
        uint256[] memory dcfs,
        uint256[] memory discountFactors
    ) internal pure returns (uint256 npv) {
        uint256 len = dcfs.length;
        for (uint256 i; i < len; ++i) {
            uint256 coupon = accruedFixed(notional, fixedRateBps, dcfs[i]);
            npv += presentValue(coupon, discountFactors[i]);
        }
    }

    /// @notice Compute the Net Present Value of a floating leg.
    /// @param notional Notional amount in token decimals.
    /// @param forwardRatesWad Array of forward rates in WAD for each period.
    /// @param dcfs Array of day-count fractions (WAD) for each period.
    /// @param discountFactors Array of discount factors (WAD) for each period.
    /// @return npv The total present value of the floating leg.
    function pvFloatLeg(
        uint256 notional,
        uint256[] memory forwardRatesWad,
        uint256[] memory dcfs,
        uint256[] memory discountFactors
    ) internal pure returns (uint256 npv) {
        uint256 len = dcfs.length;
        for (uint256 i; i < len; ++i) {
            uint256 coupon = accruedFloat(notional, forwardRatesWad[i], dcfs[i]);
            npv += presentValue(coupon, discountFactors[i]);
        }
    }

    /// @notice Compute the signed NPV of a swap from the fixed-payer perspective.
    /// @dev NPV = PV(float) - PV(fixed). Positive means the fixed payer profits.
    /// @param pvFloat Present value of the floating leg.
    /// @param pvFixed Present value of the fixed leg.
    /// @return npv Signed swap NPV (positive = value to fixed payer).
    function swapNpv(
        uint256 pvFloat,
        uint256 pvFixed
    ) internal pure returns (int256 npv) {
        npv = int256(pvFloat) - int256(pvFixed);
    }

    // ─── Initial Margin Helper ──────────────────────────────────────────

    /// @notice Calculate initial margin requirement for a position.
    /// @param notional The notional amount.
    /// @param riskWeightBps Risk weight in basis points (tenor-dependent).
    /// @param confidenceBps Confidence multiplier in basis points (e.g. 9900 = 99%).
    /// @return im The initial margin requirement.
    function initialMargin(
        uint256 notional,
        uint256 riskWeightBps,
        uint256 confidenceBps
    ) internal pure returns (uint256 im) {
        // IM = |notional| * riskWeight * confidence
        im = (notional * riskWeightBps * confidenceBps) / (BPS * BPS);
    }

    // ─── Utility ────────────────────────────────────────────────────────

    /// @notice Absolute value of a signed integer.
    /// @param x The signed integer.
    /// @return The absolute value.
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /// @notice Safely cast uint256 to int256, reverting on overflow.
    /// @param x The unsigned integer.
    /// @return The signed integer.
    function toInt256(uint256 x) internal pure returns (int256) {
        if (x > uint256(type(int256).max)) revert OverflowDetected();
        return int256(x);
    }
}
