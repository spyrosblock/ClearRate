// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReceiverTemplate} from "../interfaces/ReceiverTemplate.sol";

/// @title Whitelist
/// @notice KYC/governance-controlled address registry for CCP participants.
/// @dev Only whitelisted addresses may deposit collateral and submit trades.
///      Supports tiered access with maxNotional limits (cumulative across positions) and KYC expiry.
///      Inherits from ReceiverTemplate to receive reports from Chainlink CRE workflow.
contract Whitelist is AccessControl, ReceiverTemplate {
    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── Structs ──────────────────────────────────────────────────────

    /// @notice Participant data with limits.
    struct Participant {
        bool isWhitelisted;
        uint256 maxNotional;     // Maximum cumulative position size allowed
        uint256 totalOpenNotional; // Current cumulative notional from all open positions
        uint64 validUntil;       // Whitelist validity expiration timestamp
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Mapping from address to participant data.
    mapping(address => Participant) private _participants;

    /// @notice Mapping from address to their global accountId (bytes32).
    mapping(address => bytes32) private _accountIds;

    /// @notice Mapping from accountId to the primary address.
    mapping(bytes32 => address) private _accountOwners;

    /// @notice Total number of whitelisted participants.
    uint256 public participantCount;

    // ─── Events ─────────────────────────────────────────────────────────
    event ParticipantAdded(
        address indexed participant,
        bytes32 indexed accountId,
        uint8 tier,
        uint256 maxNotional,
        uint64 validUntil
    );
    event ParticipantRemoved(address indexed participant, bytes32 indexed accountId);
    event ParticipantUpdated(
        address indexed participant,
        uint8 newTier,
        uint256 newMaxNotional,
        uint64 newValidUntil
    );
    event NotionalAdded(address indexed participant, uint256 notional, uint256 newTotal);
    event NotionalRemoved(address indexed participant, uint256 notional, uint256 newTotal);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AlreadyWhitelisted(address participant);
    error NotWhitelisted(address participant);
    error InvalidAddress();
    error InvalidAccountId();
    error AccountIdTaken(bytes32 accountId);
    error InvalidTier(uint8 tier);
    error WhitelistExpired(address participant, uint64 expiry);
    error ExceedsMaxNotional(address participant, uint256 requested, uint256 currentTotal, uint256 maxAllowed);
    error ZeroAmount();
    error NotAuthorized();
    error InvalidReportType(uint8 reportType);
    error InvalidExpiry();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the Whitelist and assign initial admin.
    /// @param admin The address granted DEFAULT_ADMIN_ROLE and WHITELIST_ADMIN_ROLE.
    /// @param forwarder The Chainlink Forwarder address for CRE reports.
    constructor(address admin, address forwarder) ReceiverTemplate(forwarder) {
        if (admin == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WHITELIST_ADMIN_ROLE, admin);
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Add a participant to the whitelist with all required fields.
    /// @param participant The address to whitelist.
    /// @param accountId The global account identifier for this participant.
    /// @param maxNotional The maximum notional limit for this participant.
    /// @param validUntil Whitelist validity expiration timestamp.
    function addParticipant(
        address participant,
        bytes32 accountId,
        uint256 maxNotional,
        uint64 validUntil
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        _addParticipant(participant, accountId, maxNotional, validUntil);
    }

    /// @dev Private helper function to add a participant with full logic.
    /// @param participant The address to whitelist.
    /// @param accountId The global account identifier for this participant.
    /// @param maxNotional The maximum notional limit for this participant.
    /// @param validUntil Whitelist validity expiration timestamp.
    function _addParticipant(
        address participant,
        bytes32 accountId,
        uint256 maxNotional,
        uint64 validUntil
    ) private {
        if (participant == address(0)) revert InvalidAddress();
        if (accountId == bytes32(0)) revert InvalidAccountId();
        if (maxNotional == 0) revert ZeroAmount();
        if (validUntil == 0) revert ZeroAmount();
        if (validUntil <= block.timestamp) revert InvalidExpiry();
        if (_participants[participant].isWhitelisted) revert AlreadyWhitelisted(participant);
        if (_accountOwners[accountId] != address(0)) revert AccountIdTaken(accountId);

        _participants[participant] = Participant({
            isWhitelisted: true,
            maxNotional: maxNotional,
            totalOpenNotional: 0,
            validUntil: validUntil
        });
        
        _accountIds[participant] = accountId;
        _accountOwners[accountId] = participant;
        ++participantCount;

        emit ParticipantAdded(participant, accountId, 0, maxNotional, validUntil);
    }

    /// @notice Remove a participant from the whitelist.
    /// @param participant The address to remove.
    function removeParticipant(
        address participant
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        _removeParticipant(participant);
    }

    /// @dev Private helper function to remove a participant with full logic.
    /// @param participant The address to remove.
    function _removeParticipant(address participant) private {
        if (!_participants[participant].isWhitelisted) revert NotWhitelisted(participant);

        bytes32 accountId = _accountIds[participant];
        delete _participants[participant];
        delete _accountIds[participant];
        delete _accountOwners[accountId];
        --participantCount;

        emit ParticipantRemoved(participant, accountId);
    }

    /// @notice Update participant fields at once.
    /// @param participant The address to update.
    /// @param newMaxNotional The new maximum notional.
    /// @param newValidUntil The new whitelist validity expiration timestamp.
    function updateParticipant(
        address participant,
        uint256 newMaxNotional,
        uint64 newValidUntil
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        _updateParticipant(participant, newMaxNotional, newValidUntil);
    }

    /// @dev Private helper function to update a participant with full logic.
    /// @param participant The address to update.
    /// @param newMaxNotional The new maximum notional.
    /// @param newValidUntil The new whitelist validity expiration timestamp.
    function _updateParticipant(
        address participant,
        uint256 newMaxNotional,
        uint64 newValidUntil
    ) private {
        if (!_participants[participant].isWhitelisted) revert NotWhitelisted(participant);
        if (newMaxNotional == 0) revert ZeroAmount();
        if (newValidUntil <= block.timestamp) revert InvalidExpiry();

        Participant storage p = _participants[participant];
        p.maxNotional = newMaxNotional;
        p.validUntil = newValidUntil;
        
        emit ParticipantUpdated(participant, 0, newMaxNotional, newValidUntil);
    }

    // ─── Notional Management (for ClearingHouse) ────────────────────────

    /// @notice Add notional to a participant's open positions.
    /// @dev Called when a new position is opened. Reverts if exceeds maxNotional or whitelist is expired.
    /// @param participant The address of the participant.
    /// @param notional The notional amount to add.
    function addNotional(address participant, uint256 notional) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (!_participants[participant].isWhitelisted) revert NotWhitelisted(participant);
        if (_participants[participant].validUntil < block.timestamp) revert WhitelistExpired(participant, _participants[participant].validUntil);
        if (notional == 0) revert ZeroAmount();

        Participant storage p = _participants[participant];
        uint256 newTotal = p.totalOpenNotional + notional;
        
        if (newTotal > p.maxNotional) {
            revert ExceedsMaxNotional(participant, notional, p.totalOpenNotional, p.maxNotional);
        }
        
        p.totalOpenNotional = newTotal;
        
        emit NotionalAdded(participant, notional, newTotal);
    }

    /// @notice Remove notional from a participant's open positions.
    /// @dev Called when a position is closed or compressed.
    /// @param participant The address of the participant.
    /// @param notional The notional amount to remove.
    function removeNotional(address participant, uint256 notional) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (!_participants[participant].isWhitelisted) revert NotWhitelisted(participant);
        if (notional == 0) revert ZeroAmount();

        Participant storage p = _participants[participant];
        
        // Ensure we don't underflow
        if (notional > p.totalOpenNotional) {
            p.totalOpenNotional = 0;
        } else {
            p.totalOpenNotional -= notional;
        }
        
        emit NotionalRemoved(participant, notional, p.totalOpenNotional);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Check if an address is whitelisted and validity is not expired.
    /// @param participant The address to check.
    /// @return True if the address is whitelisted and validity is not expired.
    function isWhitelisted(address participant) external view returns (bool) {
        Participant memory p = _participants[participant];
        return p.isWhitelisted && p.validUntil > block.timestamp;
    }

    /// @notice Check if an address is whitelisted (without KYC expiry check).
    /// @param participant The address to check.
    /// @return True if the address is whitelisted.
    function isWhitelistedRaw(address participant) external view returns (bool) {
        return _participants[participant].isWhitelisted;
    }

    /// @notice Check if whitelist validity is expired for a participant.
    /// @param participant The address to check.
    /// @return True if whitelist validity is expired.
    function isExpired(address participant) external view returns (bool) {
        return _participants[participant].validUntil < block.timestamp;
    }

    /// @notice Get the participant details.
    /// @param participant The address to look up.
    /// @return The participant struct.
    function getParticipant(address participant) external view returns (Participant memory) {
        return _participants[participant];
    }


    /// @notice Get the maxNotional for a participant.
    /// @param participant The address to look up.
    /// @return The maximum cumulative notional allowed.
    function getMaxNotional(address participant) external view returns (uint256) {
        return _participants[participant].maxNotional;
    }

    /// @notice Get the total open notional for a participant.
    /// @param participant The address to look up.
    /// @return The current cumulative notional from all open positions.
    function getTotalOpenNotional(address participant) external view returns (uint256) {
        return _participants[participant].totalOpenNotional;
    }

    /// @notice Get the available notional for a participant.
    /// @param participant The address to look up.
    /// @return The available notional (maxNotional - totalOpenNotional).
    function getAvailableNotional(address participant) external view returns (uint256) {
        Participant memory p = _participants[participant];
        if (p.totalOpenNotional >= p.maxNotional) {
            return 0;
        }
        return p.maxNotional - p.totalOpenNotional;
    }

    /// @notice Get the whitelist validity expiry for a participant.
    /// @param participant The address to look up.
    /// @return The whitelist validity expiration timestamp.
    function getValidUntil(address participant) external view returns (uint64) {
        return _participants[participant].validUntil;
    }

    /// @notice Check if adding notional would exceed the participant's limit.
    /// @param participant The address to check.
    /// @param notional The notional amount to check.
    /// @return True if within limit.
    function checkNotionalLimit(address participant, uint256 notional) external view returns (bool) {
        Participant memory p = _participants[participant];
        return (p.totalOpenNotional + notional) <= p.maxNotional;
    }

    /// @notice Get the accountId for a whitelisted address.
    /// @param participant The address to look up.
    /// @return The bytes32 accountId.
    function getAccountId(address participant) external view returns (bytes32) {
        return _accountIds[participant];
    }

    /// @notice Get the owner address for an accountId.
    /// @param accountId The account identifier to look up.
    /// @return The owner address.
    function getAccountOwner(bytes32 accountId) external view returns (address) {
        return _accountOwners[accountId];
    }

    // ─── ReceiverTemplate Implementation ─────────────────────────────────

    /// @inheritdoc AccessControl
    /// @dev Overrides supportsInterface to include both AccessControl and ReceiverTemplate interfaces.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, ReceiverTemplate) returns (bool) {
        return AccessControl.supportsInterface(interfaceId) || ReceiverTemplate.supportsInterface(interfaceId);
    }

    /// @notice Process the report data from Chainlink CRE.
    /// @dev Called by ReceiverTemplate.onReport() after validation.
    ///      Supports three report types:
    ///      1. Add participant: abi.encode(uint8(0), participant, accountId, tier, customMaxNotional, validUntil)
    ///      2. Remove participant: abi.encode(uint8(1), participant)
    ///      3. Update participant: abi.encode(uint8(2), participant, newMaxNotional, newValidUntil)
    /// @param report ABI-encoded report data with type prefix
    function _processReport(
        bytes calldata report
    ) internal override {
        // Decode the first byte to determine report type
        (uint8 reportType) = abi.decode(report[:32], (uint8));

        if (reportType == 0) {
            // Add participant report
            // Decode: (uint8, address participant, bytes32 accountId, uint256 maxNotional, uint64 validUntil)
            (, address participant, bytes32 accountId, uint256 maxNotional, uint64 validUntil) = abi.decode(
                report,
                (uint8, address, bytes32, uint256, uint64)
            );
            _addParticipant(participant, accountId, maxNotional, validUntil);
        } else if (reportType == 1) {
            // Remove participant report
            // Decode: (uint8, address participant)
            (, address participant) = abi.decode(
                report,
                (uint8, address)
            );
            _removeParticipant(participant);
        } else if (reportType == 2) {
            // Update participant report
            // Decode: (uint8, address participant, uint256 newMaxNotional, uint64 newValidUntil)
            (, address participant, uint256 newMaxNotional, uint64 newValidUntil) = abi.decode(
                report,
                (uint8, address, uint256, uint64)
            );
            _updateParticipant(participant, newMaxNotional, newValidUntil);
        } else {
            revert InvalidReportType(reportType);
        }
    }
}
