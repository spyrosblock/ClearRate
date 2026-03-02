// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title InsuranceFund
/// @notice Backstop capital pool that absorbs losses when a liquidated account goes bankrupt.
/// @dev Funded by clearinghouse fees and governance. Drawn upon by the LiquidationEngine.
contract InsuranceFund is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");
    bytes32 public constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Mapping of accepted stablecoins to their balance in the fund.
    mapping(address => uint256) public fundBalance;

    /// @notice Set of accepted stablecoin token addresses.
    mapping(address => bool) public acceptedTokens;

    /// @notice Array of accepted token addresses for enumeration.
    address[] public tokenList;

    // ─── Events ─────────────────────────────────────────────────────────
    event CapitalInjected(address indexed token, address indexed from, uint256 amount);
    event DeficitClaimed(address indexed token, address indexed to, uint256 amount);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    // ─── Errors ─────────────────────────────────────────────────────────
    error TokenNotAccepted(address token);
    error InsufficientFundBalance(address token, uint256 requested, uint256 available);
    error TokenAlreadyAccepted(address token);
    error InvalidAddress();
    error ZeroAmount();

    // ─── Constructor ────────────────────────────────────────────────────

    /// @notice Deploy the InsuranceFund.
    /// @param admin The admin address.
    /// @param initialTokens Array of initially accepted stablecoin addresses.
    constructor(address admin, address[] memory initialTokens) {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FUND_MANAGER_ROLE, admin);

        for (uint256 i; i < initialTokens.length; ++i) {
            if (initialTokens[i] == address(0)) revert InvalidAddress();
            acceptedTokens[initialTokens[i]] = true;
            tokenList.push(initialTokens[i]);
            emit TokenAdded(initialTokens[i]);
        }
    }

    // ─── External Functions ─────────────────────────────────────────────

    /// @notice Inject capital into the insurance fund.
    /// @param token The stablecoin token address.
    /// @param amount The amount to inject.
    function injectCapital(
        address token,
        uint256 amount
    ) external nonReentrant onlyRole(FUND_MANAGER_ROLE) {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        fundBalance[token] += amount;

        emit CapitalInjected(token, msg.sender, amount);
    }

    /// @notice Claim a deficit from the insurance fund to cover a bankrupt account.
    /// @dev Only callable by the ClearingHouse/LiquidationEngine.
    /// @param token The stablecoin to draw.
    /// @param to The address to send funds to (e.g., the margin vault).
    /// @param amount The amount to claim.
    function claimDeficit(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant onlyRole(CLEARING_HOUSE_ROLE) {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidAddress();
        if (fundBalance[token] < amount) {
            revert InsufficientFundBalance(token, amount, fundBalance[token]);
        }

        fundBalance[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit DeficitClaimed(token, to, amount);
    }

    /// @notice Add an accepted stablecoin token.
    /// @param token The token address to accept.
    function addToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        if (acceptedTokens[token]) revert TokenAlreadyAccepted(token);
        acceptedTokens[token] = true;
        tokenList.push(token);
        emit TokenAdded(token);
    }

    /// @notice Remove an accepted stablecoin token.
    /// @param token The token address to remove.
    function removeToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!acceptedTokens[token]) revert TokenNotAccepted(token);
        acceptedTokens[token] = false;

        // Swap-and-pop from tokenList
        uint256 len = tokenList.length;
        for (uint256 i; i < len; ++i) {
            if (tokenList[i] == token) {
                tokenList[i] = tokenList[len - 1];
                tokenList.pop();
                break;
            }
        }
        emit TokenRemoved(token);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get the total fund balance across all accepted tokens (stablecoins at 1:1 USD).
    /// @return total The total USD-equivalent fund balance.
    function totalFundBalance() external view returns (uint256 total) {
        uint256 len = tokenList.length;
        for (uint256 i; i < len; ++i) {
            total += fundBalance[tokenList[i]];
        }
    }

    /// @notice Get all accepted token addresses.
    /// @return Array of accepted token addresses.
    function getAcceptedTokens() external view returns (address[] memory) {
        return tokenList;
    }
}
