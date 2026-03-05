// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Whitelist} from "../access/Whitelist.sol";

/// @title MarginVault
/// @notice  margin ledger that tracks collateral per accountId.
/// @dev Manages total collateral, locked initial margin, and free margin.
///      Stablecoins are valued at 1:1 with USD — no haircuts or price feeds needed.
///      Access control: Only whitelisted participants can deposit/withdraw for their own accounts.
///      Only the ClearingHouse can lock/release IM and settle variation margin.
contract MarginVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");
    bytes32 public constant LIQUIDATION_ENGINE_ROLE = keccak256("LIQUIDATION_ENGINE_ROLE");

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Margin accounts indexed by accountId.
    mapping(bytes32 => bool) public marginAccountExists;

    /// @notice Per-account per-token collateral breakdown.
    mapping(bytes32 => mapping(address => uint256)) public tokenCollateral;

    /// @notice Per-account per-token locked initial margin.
    mapping(bytes32 => mapping(address => uint256)) public lockedIMByToken;

    /// @notice Accepted stablecoin tokens.
    mapping(address => bool) public acceptedTokens;

    /// @notice List of accepted tokens for enumeration.
    address[] public tokenList;

    /// @notice Reference to the Whitelist contract for access control.
    Whitelist public whitelist;

    // ─── Events ─────────────────────────────────────────────────────────
    event MarginDeposited(bytes32 indexed accountId, address indexed token, uint256 amount);
    event MarginWithdrawn(bytes32 indexed accountId, address indexed token, uint256 amount);
    event InitialMarginLocked(bytes32 indexed accountId, uint256 amount);
    event InitialMarginReleased(bytes32 indexed accountId, uint256 amount);
    event VariationMarginSettled(bytes32 indexed accountId, address collateralToken, int256 amount);
    event TokenAccepted(address indexed token);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AccountNotInitialized(bytes32 accountId);
    error InsufficientFreeMargin(bytes32 accountId, uint256 requested, uint256 available);
    error InsufficientLockedMargin(bytes32 accountId, uint256 requested, uint256 locked);
    error InsufficientTokenBalance(bytes32 accountId, address token, uint256 requested, uint256 available);
    error TokenNotAccepted(address token);
    error ZeroAmount();
    error InvalidAddress();
    error NotAuthorized(address caller, bytes32 accountId);
    error UnauthorizedForVMSettlement(address account, bytes32 neededRole1, bytes32 neededRole2);
    error WhitelistNotSet();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the MarginVault.
    /// @param admin The admin address.
    /// @param whitelist_ The Whitelist contract address.
    /// @param initialTokens Initially accepted stablecoin addresses.
    constructor(address admin, address whitelist_, address[] memory initialTokens) {
        if (admin == address(0)) revert InvalidAddress();
        if (whitelist_ == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        whitelist = Whitelist(whitelist_);

        for (uint256 i; i < initialTokens.length; ++i) {
            acceptedTokens[initialTokens[i]] = true;
            tokenList.push(initialTokens[i]);
            emit TokenAccepted(initialTokens[i]);
        }
    }

    // ─── Margin Operations ──────────────────────────────────────────────

    /// @notice Deposit collateral into a margin account.
    /// @param accountId The account identifier.
    /// @param token The stablecoin token to deposit.
    /// @param amount The amount to deposit.
    function depositMargin(
        bytes32 accountId,
        address token,
        uint256 amount
    ) external nonReentrant {
        // Access control: caller must be whitelisted and own the accountId
        if (!whitelist.isWhitelisted(msg.sender)) revert NotAuthorized(msg.sender, accountId);
        if (whitelist.getAccountId(msg.sender) != accountId) revert NotAuthorized(msg.sender, accountId);
        
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();

        if (!marginAccountExists[accountId]) {
            marginAccountExists[accountId] = true;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        tokenCollateral[accountId][token] += amount;

        emit MarginDeposited(accountId, token, amount);
    }

    /// @notice Withdraw collateral from a margin account.
    /// @dev Can only withdraw from free margin (totalCollateral - lockedIM).
    /// @param accountId The account identifier.
    /// @param token The stablecoin token to withdraw.
    /// @param amount The amount to withdraw.
    /// @param to The address to send withdrawn funds to.
    function withdrawMargin(
        bytes32 accountId,
        address token,
        uint256 amount,
        address to
    ) external nonReentrant {
        // Access control: caller must be whitelisted and own the accountId
        if (!whitelist.isWhitelisted(msg.sender)) revert NotAuthorized(msg.sender, accountId);
        if (whitelist.getAccountId(msg.sender) != accountId) revert NotAuthorized(msg.sender, accountId);
        
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidAddress();

        if (!marginAccountExists[accountId]) revert AccountNotInitialized(accountId);

        uint256 free = getFreeMarginByToken(accountId, token);
        if (amount > free) {
            revert InsufficientFreeMargin(accountId, amount, free);
        }

        if (tokenCollateral[accountId][token] < amount) {
            revert InsufficientTokenBalance(
                accountId, token, amount, tokenCollateral[accountId][token]
            );
        }

        tokenCollateral[accountId][token] -= amount;

        IERC20(token).safeTransfer(to, amount);

        emit MarginWithdrawn(accountId, token, amount);
    }

    /// @notice Lock initial margin for a new position with a specific token.
    /// @param accountId The account identifier.
    /// @param token The collateral token to lock.
    /// @param amount The amount to lock.
    function lockInitialMargin(
        bytes32 accountId,
        address token,
        uint256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);

        if (!marginAccountExists[accountId]) revert AccountNotInitialized(accountId);

        // Check free margin in the specific token
        uint256 freeInToken = getFreeMarginByToken(accountId, token);
        if (amount > freeInToken) {
            revert InsufficientFreeMargin(accountId, amount, freeInToken);
        }

        lockedIMByToken[accountId][token] += amount;

        emit InitialMarginLocked(accountId, amount);
    }

    /// @notice Release locked initial margin with specific token (e.g., on position compression or maturity).
    /// @param accountId The account identifier.
    /// @param token The collateral token to release.
    /// @param amount The amount to release.
    function releaseInitialMargin(
        bytes32 accountId,
        address token,
        uint256 amount
    ) external onlyRole(CLEARING_HOUSE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);

        if (!marginAccountExists[accountId]) revert AccountNotInitialized(accountId);
        
        if (lockedIMByToken[accountId][token] < amount) {
            revert InsufficientLockedMargin(accountId, amount, lockedIMByToken[accountId][token]);
        }

        lockedIMByToken[accountId][token] -= amount;

        emit InitialMarginReleased(accountId, amount);
    }

    /// @notice Settle variation margin for an account with a specific token.
    /// @dev Positive amount = credit (account gains), negative = debit (account loses).
    ///      Only ClearingHouse or LiquidationEngine can settle variation margin.
    /// @param accountId The account identifier.
    /// @param token The collateral token for VM settlement.
    /// @param amount Signed variation margin amount.
    function settleVariationMargin(
        bytes32 accountId,
        address token,
        int256 amount
    ) external {
        if (!hasRole(CLEARING_HOUSE_ROLE, msg.sender) && !hasRole(LIQUIDATION_ENGINE_ROLE, msg.sender)) {
            revert UnauthorizedForVMSettlement(msg.sender, CLEARING_HOUSE_ROLE, LIQUIDATION_ENGINE_ROLE);
        }
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);

        if (!marginAccountExists[accountId]) revert AccountNotInitialized(accountId);

        // Update totalCollateral based on net VM
        if (amount > 0) {
            tokenCollateral[accountId][token] += uint256(amount);
        } else if (amount < 0) {
            uint256 debit = uint256(-amount);
            if (tokenCollateral[accountId][token] >= debit) {
                tokenCollateral[accountId][token] -= debit;
            } else {
                tokenCollateral[accountId][token] = 0;
            }
        }

        emit VariationMarginSettled(accountId, token, amount);
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

    /// @notice Get the free (withdrawable) margin for an account in a specific token.
    /// @dev Free margin in token = tokenCollateral - lockedIM in that token.
    /// @param accountId The account identifier.
    /// @param token The collateral token.
    /// @return free The amount of free margin available in the specific token.
    function getFreeMarginByToken(bytes32 accountId, address token) public view returns (uint256 free) {
        uint256 collateral = tokenCollateral[accountId][token];
        uint256 locked = lockedIMByToken[accountId][token];
        if (collateral >= locked) {
            free = collateral - locked;
        } else {
            free = 0;
        }
    }

    /// @notice Get the total collateral for an account for a specific token.
    /// @param accountId The account identifier.
    /// @param token The collateral token.
    /// @return The total collateral amount for the specific token.
    function getTotalCollateral(bytes32 accountId, address token) external view returns (uint256) {
        return tokenCollateral[accountId][token];
    }

    /// @notice Check if an account exists.
    /// @param accountId The  account identifier.
    /// @return True if the account has been initialized.
    function accountExists(bytes32 accountId) external view returns (bool) {
        return marginAccountExists[accountId];
    }

    /// @notice Get the locked initial margin for an account for a specific token.
    /// @param accountId The account identifier.
    /// @param token The collateral token.
    /// @return The locked IM amount for the specific token.
    function getLockedIMByToken(bytes32 accountId, address token) external view returns (uint256) {
        return lockedIMByToken[accountId][token];
    }
}
