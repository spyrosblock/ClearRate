// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GlobalMarginVault
/// @notice Hub-chain global margin ledger that tracks collateral per accountId.
/// @dev Manages total collateral, locked initial margin, and free margin.
///      Stablecoins are valued at 1:1 with USD — no haircuts or price feeds needed.
contract GlobalMarginVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");
    bytes32 public constant MARGIN_OPERATOR_ROLE = keccak256("MARGIN_OPERATOR_ROLE");

    // ─── Structs ────────────────────────────────────────────────────────

    /// @notice Margin account state for a participant.
    struct MarginAccount {
        uint256 totalCollateral;   // Total stablecoin collateral deposited (across all accepted tokens)
        uint256 lockedIM;          // Collateral locked as Initial Margin
        uint256 vmBalance;         // Variation Margin balance (can be positive or negative via int tracking)
        bool exists;               // Whether the account has been initialized
    }

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Margin accounts indexed by accountId.
    mapping(bytes32 => MarginAccount) public marginAccounts;

    /// @notice Per-account per-token collateral breakdown.
    mapping(bytes32 => mapping(address => uint256)) public tokenCollateral;

    /// @notice Signed variation margin balance (positive = credit, negative = debit).
    mapping(bytes32 => int256) public vmBalanceSigned;

    /// @notice Accepted stablecoin tokens.
    mapping(address => bool) public acceptedTokens;

    /// @notice List of accepted tokens for enumeration.
    address[] public tokenList;

    // ─── Events ─────────────────────────────────────────────────────────
    event MarginDeposited(bytes32 indexed accountId, address indexed token, uint256 amount);
    event MarginWithdrawn(bytes32 indexed accountId, address indexed token, uint256 amount);
    event InitialMarginLocked(bytes32 indexed accountId, uint256 amount);
    event InitialMarginReleased(bytes32 indexed accountId, uint256 amount);
    event VariationMarginSettled(bytes32 indexed accountId, int256 amount);
    event TokenAccepted(address indexed token);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AccountNotInitialized(bytes32 accountId);
    error InsufficientFreeMargin(bytes32 accountId, uint256 requested, uint256 available);
    error InsufficientLockedMargin(bytes32 accountId, uint256 requested, uint256 locked);
    error InsufficientTokenBalance(bytes32 accountId, address token, uint256 requested, uint256 available);
    error TokenNotAccepted(address token);
    error ZeroAmount();
    error InvalidAddress();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the GlobalMarginVault.
    /// @param admin The admin address.
    /// @param initialTokens Initially accepted stablecoin addresses.
    constructor(address admin, address[] memory initialTokens) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MARGIN_OPERATOR_ROLE, admin);

        for (uint256 i; i < initialTokens.length; ++i) {
            acceptedTokens[initialTokens[i]] = true;
            tokenList.push(initialTokens[i]);
            emit TokenAccepted(initialTokens[i]);
        }
    }

    // ─── Margin Operations ──────────────────────────────────────────────

    /// @notice Deposit collateral into a margin account.
    /// @param accountId The global account identifier.
    /// @param token The stablecoin token to deposit.
    /// @param amount The amount to deposit.
    function depositMargin(
        bytes32 accountId,
        address token,
        uint256 amount
    ) external nonReentrant onlyRole(MARGIN_OPERATOR_ROLE) {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();

        MarginAccount storage account = marginAccounts[accountId];
        if (!account.exists) {
            account.exists = true;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        account.totalCollateral += amount;
        tokenCollateral[accountId][token] += amount;

        emit MarginDeposited(accountId, token, amount);
    }

    /// @notice Withdraw collateral from a margin account.
    /// @dev Can only withdraw from free margin (totalCollateral - lockedIM - vmDebit).
    /// @param accountId The global account identifier.
    /// @param token The stablecoin token to withdraw.
    /// @param amount The amount to withdraw.
    /// @param to The address to send withdrawn funds to.
    function withdrawMargin(
        bytes32 accountId,
        address token,
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(MARGIN_OPERATOR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidAddress();

        MarginAccount storage account = marginAccounts[accountId];
        if (!account.exists) revert AccountNotInitialized(accountId);

        uint256 free = getFreeMargin(accountId);
        if (amount > free) {
            revert InsufficientFreeMargin(accountId, amount, free);
        }

        if (tokenCollateral[accountId][token] < amount) {
            revert InsufficientTokenBalance(
                accountId, token, amount, tokenCollateral[accountId][token]
            );
        }

        account.totalCollateral -= amount;
        tokenCollateral[accountId][token] -= amount;

        IERC20(token).safeTransfer(to, amount);

        emit MarginWithdrawn(accountId, token, amount);
    }

    /// @notice Lock initial margin for a new position.
    /// @param accountId The global account identifier.
    /// @param amount The amount to lock.
    function lockInitialMargin(
        bytes32 accountId,
        uint256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (amount == 0) revert ZeroAmount();

        MarginAccount storage account = marginAccounts[accountId];
        if (!account.exists) revert AccountNotInitialized(accountId);

        uint256 free = getFreeMargin(accountId);
        if (amount > free) {
            revert InsufficientFreeMargin(accountId, amount, free);
        }

        account.lockedIM += amount;
        emit InitialMarginLocked(accountId, amount);
    }

    /// @notice Release locked initial margin (e.g., on position compression or maturity).
    /// @param accountId The global account identifier.
    /// @param amount The amount to release.
    function releaseInitialMargin(
        bytes32 accountId,
        uint256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (amount == 0) revert ZeroAmount();

        MarginAccount storage account = marginAccounts[accountId];
        if (!account.exists) revert AccountNotInitialized(accountId);
        if (account.lockedIM < amount) {
            revert InsufficientLockedMargin(accountId, amount, account.lockedIM);
        }

        account.lockedIM -= amount;
        emit InitialMarginReleased(accountId, amount);
    }

    /// @notice Settle variation margin for an account.
    /// @dev Positive amount = credit (account gains), negative = debit (account loses).
    /// @param accountId The global account identifier.
    /// @param amount Signed variation margin amount.
    function settleVariationMargin(
        bytes32 accountId,
        int256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        MarginAccount storage account = marginAccounts[accountId];
        if (!account.exists) revert AccountNotInitialized(accountId);

        vmBalanceSigned[accountId] += amount;

        // Update totalCollateral based on net VM
        if (amount > 0) {
            account.totalCollateral += uint256(amount);
        } else if (amount < 0) {
            uint256 debit = uint256(-amount);
            // Allow totalCollateral to go below lockedIM (triggers liquidation check)
            if (account.totalCollateral >= debit) {
                account.totalCollateral -= debit;
            } else {
                account.totalCollateral = 0;
            }
        }

        emit VariationMarginSettled(accountId, amount);
    }

    /// @notice Add an accepted stablecoin token.
    /// @param token The token address to accept.
    function addAcceptedToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        acceptedTokens[token] = true;
        tokenList.push(token);
        emit TokenAccepted(token);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get the free (withdrawable) margin for an account.
    /// @param accountId The global account identifier.
    /// @return free The amount of free margin available.
    function getFreeMargin(bytes32 accountId) public view returns (uint256 free) {
        MarginAccount storage account = marginAccounts[accountId];
        if (!account.exists) return 0;

        if (account.totalCollateral > account.lockedIM) {
            free = account.totalCollateral - account.lockedIM;
        }
    }

    /// @notice Get the total collateral for an account.
    /// @param accountId The global account identifier.
    /// @return The total collateral amount.
    function getTotalCollateral(bytes32 accountId) external view returns (uint256) {
        return marginAccounts[accountId].totalCollateral;
    }

    /// @notice Get the locked initial margin for an account.
    /// @param accountId The global account identifier.
    /// @return The locked IM amount.
    function getLockedIM(bytes32 accountId) external view returns (uint256) {
        return marginAccounts[accountId].lockedIM;
    }

    /// @notice Check if an account exists.
    /// @param accountId The global account identifier.
    /// @return True if the account has been initialized.
    function accountExists(bytes32 accountId) external view returns (bool) {
        return marginAccounts[accountId].exists;
    }
}
