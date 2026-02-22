// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReceiverTemplate} from "../interfaces/ReceiverTemplate.sol";

/// @title YieldCurveOracle
/// @notice Ingests discount factors from Chainlink CRE DON for yield curve pricing.
/// @dev Discount factors are stored per tenor bucket and updated via the Chainlink CRE flow.
///      All discount factors are in WAD (1e18) precision.
///      Inherits from ReceiverTemplate to receive reports directly from Chainlink CRE.
contract YieldCurveOracle is ReceiverTemplate {
    // ─── Constants ──────────────────────────────────────────────────────
    uint256 internal constant WAD = 1e18;

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Mapping from tenor (in seconds) to discount factor (WAD).
    mapping(uint256 => uint256) public discountFactors;

    /// @notice Supported tenor buckets (in seconds).
    uint256[] public supportedTenors;

    /// @notice Mapping to check if a tenor is supported.
    mapping(uint256 => bool) public isSupportedTenor;

    /// @notice Timestamp of the last discount factor update.
    uint256 public lastUpdateTimestamp;

    /// @notice Maximum staleness allowed for oracle data (in seconds).
    uint256 public maxStaleness;

    // ─── Events ─────────────────────────────────────────────────────────
    event DiscountFactorsUpdated(uint256 indexed timestamp, uint256 tenorCount);
    event TenorAdded(uint256 indexed tenor);
    event TenorRemoved(uint256 indexed tenor);
    event MaxStalenessUpdated(uint256 oldStaleness, uint256 newStaleness);

    // ─── Errors ─────────────────────────────────────────────────────────
    error UnsupportedTenor(uint256 tenor);
    error ArrayLengthMismatch();
    error StaleOracleData();
    error InvalidDiscountFactor(uint256 tenor, uint256 value);
    error TenorAlreadySupported(uint256 tenor);
    error TenorNotSupported(uint256 tenor);
    error InvalidStaleness();
    error InvalidDataLength(uint256 expected, uint256 actual);

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the YieldCurveOracle.
    /// @param forwarder The Chainlink Forwarder address for CRE reports.
    /// @param initialMaxStaleness Maximum allowed staleness in seconds.
    /// @param initialTenors Array of initial supported tenor buckets (in seconds).
    constructor(
        address forwarder,
        uint256 initialMaxStaleness,
        uint256[] memory initialTenors
    ) ReceiverTemplate(forwarder) {
        if (initialMaxStaleness == 0) revert InvalidStaleness();
        maxStaleness = initialMaxStaleness;

        for (uint256 i; i < initialTenors.length; ++i) {
            supportedTenors.push(initialTenors[i]);
            isSupportedTenor[initialTenors[i]] = true;
        }
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Batch update discount factors for supported tenors.
    /// @dev Called by the contract owner.
    /// @param tenors Array of tenor buckets (must all be supported).
    /// @param factors Array of discount factors in WAD.
    function updateDiscountFactors(
        uint256[] calldata tenors,
        uint256[] calldata factors
    ) external onlyOwner {
        if (tenors.length != factors.length) revert ArrayLengthMismatch();

        _updateDiscountFactors(tenors, factors);

        lastUpdateTimestamp = block.timestamp;
        emit DiscountFactorsUpdated(block.timestamp, tenors.length);
    }

    /// @notice Add a new supported tenor bucket.
    /// @param tenor The tenor in seconds to add.
    function addTenor(uint256 tenor) external onlyOwner {
        if (isSupportedTenor[tenor]) revert TenorAlreadySupported(tenor);
        supportedTenors.push(tenor);
        isSupportedTenor[tenor] = true;
        emit TenorAdded(tenor);
    }

    /// @notice Remove a supported tenor bucket.
    /// @param tenor The tenor in seconds to remove.
    function removeTenor(uint256 tenor) external onlyOwner {
        if (!isSupportedTenor[tenor]) revert TenorNotSupported(tenor);
        isSupportedTenor[tenor] = false;
        delete discountFactors[tenor];

        // Remove from array (swap-and-pop)
        uint256 len = supportedTenors.length;
        for (uint256 i; i < len; ++i) {
            if (supportedTenors[i] == tenor) {
                supportedTenors[i] = supportedTenors[len - 1];
                supportedTenors.pop();
                break;
            }
        }
        emit TenorRemoved(tenor);
    }

    /// @notice Update the maximum staleness threshold.
    /// @param newMaxStaleness New maximum staleness in seconds.
    function setMaxStaleness(uint256 newMaxStaleness) external onlyOwner {
        if (newMaxStaleness == 0) revert InvalidStaleness();
        emit MaxStalenessUpdated(maxStaleness, newMaxStaleness);
        maxStaleness = newMaxStaleness;
    }

    // ─── Internal Functions ─────────────────────────────────────────────

    /// @dev Internal function to update discount factors.
    /// @param tenors Array of tenor buckets.
    /// @param factors Array of discount factors in WAD.
    function _updateDiscountFactors(uint256[] memory tenors, uint256[] memory factors) internal {
        for (uint256 i; i < tenors.length; ++i) {
            if (!isSupportedTenor[tenors[i]]) revert UnsupportedTenor(tenors[i]);
            // Discount factors must be > 0 and <= 1.0 (WAD)
            if (factors[i] == 0 || factors[i] > WAD) {
                revert InvalidDiscountFactor(tenors[i], factors[i]);
            }
            discountFactors[tenors[i]] = factors[i];
        }
    }

    // ─── ReceiverTemplate Implementation ────────────────────────────────

    /// @notice Process the report data from Chainlink CRE.
    /// @dev Called by ReceiverTemplate.onReport() after validation.
    /// @param report ABI-encoded discount factor data (uint256[] tenors, uint256[] factors)
    function _processReport(
        bytes calldata report
    ) internal override {
        // Decode the report data: (uint256[] tenors, uint256[] factors)
        (uint256[] memory tenors, uint256[] memory factors) = abi.decode(
            report,
            (uint256[], uint256[])
        );

        if (tenors.length != factors.length) revert InvalidDataLength(tenors.length, factors.length);

        _updateDiscountFactors(tenors, factors);
        lastUpdateTimestamp = block.timestamp;
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get the discount factor for a specific tenor, reverting if stale.
    /// @param tenor The tenor in seconds.
    /// @return factor The discount factor in WAD.
    function getDiscountFactor(uint256 tenor) external view returns (uint256 factor) {
        if (!isSupportedTenor[tenor]) revert UnsupportedTenor(tenor);
        if (block.timestamp - lastUpdateTimestamp > maxStaleness) revert StaleOracleData();
        factor = discountFactors[tenor];
    }

    /// @notice Get all supported tenors.
    /// @return Array of supported tenor values (in seconds).
    function getSupportedTenors() external view returns (uint256[] memory) {
        return supportedTenors;
    }

    /// @notice Check if oracle data is fresh.
    /// @return True if data is within staleness bounds.
    function isFresh() external view returns (bool) {
        return (block.timestamp - lastUpdateTimestamp) <= maxStaleness;
    }
}
