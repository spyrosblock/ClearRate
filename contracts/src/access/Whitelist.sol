// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Whitelist
/// @notice KYC/governance-controlled address registry for CCP participants.
/// @dev Only whitelisted addresses may deposit collateral and submit trades.
contract Whitelist is AccessControl {
    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Mapping from address to whitelisted status.
    mapping(address => bool) private _whitelisted;

    /// @notice Mapping from address to their global accountId (bytes32).
    mapping(address => bytes32) private _accountIds;

    /// @notice Mapping from accountId to the primary address.
    mapping(bytes32 => address) private _accountOwners;

    /// @notice Total number of whitelisted participants.
    uint256 public participantCount;

    // ─── Events ─────────────────────────────────────────────────────────
    event ParticipantAdded(address indexed participant, bytes32 indexed accountId);
    event ParticipantRemoved(address indexed participant, bytes32 indexed accountId);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AlreadyWhitelisted(address participant);
    error NotWhitelisted(address participant);
    error InvalidAddress();
    error InvalidAccountId();
    error AccountIdTaken(bytes32 accountId);

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the Whitelist and assign initial admin.
    /// @param admin The address granted DEFAULT_ADMIN_ROLE and WHITELIST_ADMIN_ROLE.
    constructor(address admin) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WHITELIST_ADMIN_ROLE, admin);
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Add a participant to the whitelist.
    /// @param participant The address to whitelist.
    /// @param accountId The global account identifier for this participant.
    function addParticipant(
        address participant,
        bytes32 accountId
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        if (participant == address(0)) revert InvalidAddress();
        if (accountId == bytes32(0)) revert InvalidAccountId();
        if (_whitelisted[participant]) revert AlreadyWhitelisted(participant);
        if (_accountOwners[accountId] != address(0)) revert AccountIdTaken(accountId);

        _whitelisted[participant] = true;
        _accountIds[participant] = accountId;
        _accountOwners[accountId] = participant;
        ++participantCount;

        emit ParticipantAdded(participant, accountId);
    }

    /// @notice Remove a participant from the whitelist.
    /// @param participant The address to remove.
    function removeParticipant(
        address participant
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        if (!_whitelisted[participant]) revert NotWhitelisted(participant);

        bytes32 accountId = _accountIds[participant];
        _whitelisted[participant] = false;
        delete _accountIds[participant];
        delete _accountOwners[accountId];
        --participantCount;

        emit ParticipantRemoved(participant, accountId);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Check if an address is whitelisted.
    /// @param participant The address to check.
    /// @return True if the address is whitelisted.
    function isWhitelisted(address participant) external view returns (bool) {
        return _whitelisted[participant];
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
}
