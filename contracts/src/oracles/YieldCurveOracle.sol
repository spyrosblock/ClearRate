// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title YieldCurveOracle
/// @notice Ingests discount factors from Chainlink CRE DON for yield curve pricing.
/// @dev Discount factors are stored per tenor bucket and updated by authorized oracle reporters.
///      All discount factors are in WAD (1e18) precision.
contract YieldCurveOracle is AccessControl {
    // ─── Constants ──────────────────────────────────────────────────────
    uint256 internal constant WAD = 1e18;

    bytes32 public constant ORACLE_REPORTER_ROLE = keccak256("ORACLE_REPORTER_ROLE");

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

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the YieldCurveOracle.
    /// @param admin The address granted admin roles.
    /// @param initialMaxStaleness Maximum allowed staleness in seconds.
    /// @param initialTenors Array of initial supported tenor buckets (in seconds).
    constructor(
        address admin,
        uint256 initialMaxStaleness,
        uint256[] memory initialTenors
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_REPORTER_ROLE, admin);

        if (initialMaxStaleness == 0) revert InvalidStaleness();
        maxStaleness = initialMaxStaleness;

        for (uint256 i; i < initialTenors.length; ++i) {
            supportedTenors.push(initialTenors[i]);
            isSupportedTenor[initialTenors[i]] = true;
        }
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Batch update discount factors for supported tenors.
    /// @dev Called by Chainlink CRE DON or authorized reporter.
    /// @param tenors Array of tenor buckets (must all be supported).
    /// @param factors Array of discount factors in WAD.
    function updateDiscountFactors(
        uint256[] calldata tenors,
        uint256[] calldata factors
    ) external onlyRole(ORACLE_REPORTER_ROLE) {
        if (tenors.length != factors.length) revert ArrayLengthMismatch();

        for (uint256 i; i < tenors.length; ++i) {
            if (!isSupportedTenor[tenors[i]]) revert UnsupportedTenor(tenors[i]);
            // Discount factors must be > 0 and <= 1.0 (WAD)
            if (factors[i] == 0 || factors[i] > WAD) {
                revert InvalidDiscountFactor(tenors[i], factors[i]);
            }
            discountFactors[tenors[i]] = factors[i];
        }

        lastUpdateTimestamp = block.timestamp;
        emit DiscountFactorsUpdated(block.timestamp, tenors.length);
    }

    /// @notice Add a new supported tenor bucket.
    /// @param tenor The tenor in seconds to add.
    function addTenor(uint256 tenor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isSupportedTenor[tenor]) revert TenorAlreadySupported(tenor);
        supportedTenors.push(tenor);
        isSupportedTenor[tenor] = true;
        emit TenorAdded(tenor);
    }

    /// @notice Remove a supported tenor bucket.
    /// @param tenor The tenor in seconds to remove.
    function removeTenor(uint256 tenor) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function setMaxStaleness(uint256 newMaxStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxStaleness == 0) revert InvalidStaleness();
        emit MaxStalenessUpdated(maxStaleness, newMaxStaleness);
        maxStaleness = newMaxStaleness;
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
