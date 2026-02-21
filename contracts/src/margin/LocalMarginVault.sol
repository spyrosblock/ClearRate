// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LocalMarginVault
/// @notice Spoke-chain stablecoin deposit vault where users deposit/withdraw collateral.
/// @dev Deposits are synced to the Hub chain via CCIPSpokeGateway.
///      Stablecoins are valued at 1:1 with USD — no haircuts.
contract LocalMarginVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Per-user per-token collateral balance on this spoke.
    mapping(address => mapping(address => uint256)) public userBalance;

    /// @notice Accepted stablecoin tokens on this spoke.
    mapping(address => bool) public acceptedTokens;

    /// @notice List of accepted tokens for enumeration.
    address[] public tokenList;

    /// @notice Gateway contract for CCIP cross-chain messaging.
    address public gateway;

    // ─── Events ─────────────────────────────────────────────────────────
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);
    event TokenAccepted(address indexed token);

    // ─── Errors ─────────────────────────────────────────────────────────
    error TokenNotAccepted(address token);
    error InsufficientBalance(address user, address token, uint256 requested, uint256 available);
    error ZeroAmount();
    error InvalidAddress();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the LocalMarginVault on a spoke chain.
    /// @param admin The admin address.
    /// @param initialTokens Initially accepted stablecoin addresses.
    constructor(address admin, address[] memory initialTokens) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        for (uint256 i; i < initialTokens.length; ++i) {
            if (initialTokens[i] == address(0)) revert InvalidAddress();
            acceptedTokens[initialTokens[i]] = true;
            tokenList.push(initialTokens[i]);
            emit TokenAccepted(initialTokens[i]);
        }
    }

    // ─── User-Facing Functions ──────────────────────────────────────────

    /// @notice Deposit stablecoin collateral into the local vault.
    /// @param token The stablecoin token address.
    /// @param amount The amount to deposit.
    function depositCollateral(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        userBalance[msg.sender][token] += amount;

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Withdraw stablecoin collateral from the local vault.
    /// @param token The stablecoin token address.
    /// @param amount The amount to withdraw.
    function withdrawCollateral(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (userBalance[msg.sender][token] < amount) {
            revert InsufficientBalance(
                msg.sender, token, amount, userBalance[msg.sender][token]
            );
        }

        userBalance[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    // ─── Gateway Functions ──────────────────────────────────────────────

    /// @notice Debit a user's balance when margin is synced to the Hub via CCIP.
    /// @dev Called by the CCIPSpokeGateway when sending margin to the Hub.
    /// @param user The user whose balance to debit.
    /// @param token The stablecoin token.
    /// @param amount The amount being synced.
    function debitForSync(
        address user,
        address token,
        uint256 amount
    ) external onlyRole(GATEWAY_ROLE) {
        if (userBalance[user][token] < amount) {
            revert InsufficientBalance(user, token, amount, userBalance[user][token]);
        }
        userBalance[user][token] -= amount;
    }

    /// @notice Credit a user's balance when margin is returned from the Hub via CCIP.
    /// @dev Called by the CCIPSpokeGateway when receiving margin from the Hub.
    /// @param user The user whose balance to credit.
    /// @param token The stablecoin token.
    /// @param amount The amount being returned.
    function creditFromSync(
        address user,
        address token,
        uint256 amount
    ) external onlyRole(GATEWAY_ROLE) {
        userBalance[user][token] += amount;
    }

    // ─── Admin Functions ────────────────────────────────────────────────

    /// @notice Set the gateway contract address.
    /// @param newGateway The new gateway address.
    function setGateway(address newGateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGateway == address(0)) revert InvalidAddress();
        address oldGateway = gateway;
        gateway = newGateway;

        // Grant/revoke the GATEWAY_ROLE
        if (oldGateway != address(0)) {
            _revokeRole(GATEWAY_ROLE, oldGateway);
        }
        _grantRole(GATEWAY_ROLE, newGateway);

        emit GatewayUpdated(oldGateway, newGateway);
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

    /// @notice Get a user's total collateral across all accepted tokens (1:1 USD).
    /// @param user The user address.
    /// @return total The total collateral value.
    function getUserTotalCollateral(address user) external view returns (uint256 total) {
        uint256 len = tokenList.length;
        for (uint256 i; i < len; ++i) {
            total += userBalance[user][tokenList[i]];
        }
    }

    /// @notice Get accepted tokens list.
    /// @return Array of accepted token addresses.
    function getAcceptedTokens() external view returns (address[] memory) {
        return tokenList;
    }
}
