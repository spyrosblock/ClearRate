// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IClearingHouse} from "../../src/interfaces/IClearingHouse.sol";
import {ClearingHouse} from "../../src/core/ClearingHouse.sol";
import {IRSInstrument} from "../../src/core/IRSInstrument.sol";
import {MarginVault} from "../../src/margin/MarginVault.sol";
import {RiskEngine} from "../../src/margin/RiskEngine.sol";
import {Whitelist} from "../../src/access/Whitelist.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title ClearingHouseIntegrationTest
/// @notice Integration test covering the happy path lifecycle of a novated IRS trade.
/// @dev This test exercises the full flow: setup → trade submission → VM settlement → compression → maturity.
contract ClearingHouseIntegrationTest is Test {
    // ─── Contracts ──────────────────────────────────────────────────────
    ClearingHouse internal clearingHouse;
    IRSInstrument internal instrument;
    MarginVault internal marginVault;
    RiskEngine internal riskEngine;
    Whitelist internal whitelist;
    ERC20Mock internal usdc;
    ERC20Mock internal dai;

    // ─── Actors ─────────────────────────────────────────────────────────
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal settler = makeAddr("settler");

    Vm.Wallet internal aliceWallet;
    Vm.Wallet internal bobWallet;
    Vm.Wallet internal charlieWallet;
    address internal alice;
    address internal bob;
    address internal charlie;

    // ─── Account Ids ────────────────────────────────────────────────────
    bytes32 internal ALICE_ACCOUNT;
    bytes32 internal BOB_ACCOUNT;
    bytes32 internal CHARLIE_ACCOUNT;

    // ─── Trade Constants ────────────────────────────────────────────────
    uint256 internal constant NOTIONAL = 1_000_000e6; // $1M USDC-precision
    uint256 internal constant NOTIONAL_2 = 500_000e6; // $500k for second trade
    uint256 internal constant FIXED_RATE_BPS = 500;   // 5.00%
    uint256 internal constant ONE_YEAR = 365 days;
    uint256 internal constant NINETY_DAYS = 90 days;
    bytes32 internal constant SOFR_INDEX = keccak256("SOFR");

    // ─── Role Constants ─────────────────────────────────────────────────
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 internal constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── Setup ──────────────────────────────────────────────────────────

    function setUp() public {
        // Create wallets for EIP-712 signing
        aliceWallet = vm.createWallet("alice");
        bobWallet = vm.createWallet("bob");
        charlieWallet = vm.createWallet("charlie");
        alice = aliceWallet.addr;
        bob = bobWallet.addr;
        charlie = charlieWallet.addr;

        // Set account IDs
        ALICE_ACCOUNT = keccak256(abi.encodePacked(alice));
        BOB_ACCOUNT = keccak256(abi.encodePacked(bob));
        CHARLIE_ACCOUNT = keccak256(abi.encodePacked(charlie));

        // Deploy mock stablecoins
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        dai = new ERC20Mock("Dai", "DAI", 18);

        // Deploy Whitelist and add participants
        whitelist = new Whitelist(admin);
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.addParticipant(bob, BOB_ACCOUNT);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT);
        vm.stopPrank();

        // Deploy MarginVault with multiple tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);
        marginVault = new MarginVault(admin, address(whitelist), tokens);

        // Deploy RiskEngine: 99% confidence, 75% MM ratio
        riskEngine = new RiskEngine(admin, address(marginVault), 9900, 7500);

        // Deploy YieldCurveOracle
        uint256[] memory tenors = new uint256[](3);
        tenors[0] = NINETY_DAYS;
        tenors[1] = ONE_YEAR;
        tenors[2] = 2 * ONE_YEAR;

        // Deploy IRSInstrument
        instrument = new IRSInstrument(admin, "https://metadata.clearrate.io/{id}.json");

        // Deploy ClearingHouse
        clearingHouse = new ClearingHouse(
            admin,
            address(0), // Forwarder - use address(0) for testing (no CRE reports)
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist)
        );

        // Wire up roles
        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));

        // Set risk weights for different tenors
        riskEngine.setRiskWeight(NINETY_DAYS, 100);   // 1% for 90 days
        riskEngine.setRiskWeight(ONE_YEAR, 200);      // 2% for 1 year
        riskEngine.setRiskWeight(2 * ONE_YEAR, 300); // 3% for 2 years

        // Grant operator & settler roles
        clearingHouse.grantRole(OPERATOR_ROLE, operator);
        clearingHouse.grantRole(SETTLEMENT_ROLE, settler);
        vm.stopPrank();

        // Fund margin accounts with USDC
        _fundMarginAccount(ALICE_ACCOUNT, address(usdc), 2_000_000e6);
        _fundMarginAccount(BOB_ACCOUNT, address(usdc), 2_000_000e6);
        _fundMarginAccount(CHARLIE_ACCOUNT, address(usdc), 2_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Happy Path Integration Test
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Full happy path test: submit trade → settle VM → mature
    function test_fullHappyPath_integration() public {
        // ═══════════════════════════════════════════════════════════════
        // Step 1: Verify initial state
        // ═══════════════════════════════════════════════════════════════
        assertEq(clearingHouse.activePositionCount(), 0);
        assertTrue(whitelist.isWhitelisted(alice));
        assertTrue(whitelist.isWhitelisted(bob));
        
        uint256 aliceFreeBefore = marginVault.getFreeMargin(ALICE_ACCOUNT);
        uint256 bobFreeBefore = marginVault.getFreeMargin(BOB_ACCOUNT);
        assertEq(aliceFreeBefore, 2_000_000e6);
        assertEq(bobFreeBefore, 2_000_000e6);

        // ═══════════════════════════════════════════════════════════════
        // Step 2: Submit matched trade (novation)
        // ═══════════════════════════════════════════════════════════════
        bytes32 tradeId = keccak256("TRADE_INTEGRATION_1");
        
        IClearingHouse.MatchedTrade memory trade = IClearingHouse.MatchedTrade({
            tradeId: tradeId,
            partyA: ALICE_ACCOUNT,
            partyB: BOB_ACCOUNT,
            notional: NOTIONAL,
            fixedRateBps: FIXED_RATE_BPS,
            startDate: block.timestamp,
            maturityDate: block.timestamp + ONE_YEAR,
            paymentInterval: NINETY_DAYS,
            dayCountConvention: 0,
            floatingRateIndex: SOFR_INDEX,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);

        // Verify trade was submitted
        assertTrue(clearingHouse.tradeSubmitted(tradeId));
        assertEq(clearingHouse.activePositionCount(), 1);

        // Verify position was created
        IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.tradeId, tradeId);
        assertEq(pos.partyA, ALICE_ACCOUNT);
        assertEq(pos.partyB, BOB_ACCOUNT);
        assertEq(pos.notional, NOTIONAL);
        assertTrue(pos.active);

        // Verify ERC-1155 tokens were minted
        assertEq(instrument.balanceOf(alice, pos.tokenIdA), NOTIONAL);
        assertEq(instrument.balanceOf(bob, pos.tokenIdB), NOTIONAL);

        // Verify swap terms stored correctly
        IRSInstrument.SwapTerms memory termsA = instrument.getSwapTerms(pos.tokenIdA);
        assertTrue(termsA.direction == IRSInstrument.Direction.PAY_FIXED);
        assertEq(termsA.notional, NOTIONAL);
        
        IRSInstrument.SwapTerms memory termsB = instrument.getSwapTerms(pos.tokenIdB);
        assertTrue(termsB.direction == IRSInstrument.Direction.RECEIVE_FIXED);

        // Verify IM was locked
        uint256 expectedIM = riskEngine.calculateIM(NOTIONAL, ONE_YEAR);
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), expectedIM);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), expectedIM);
        assertEq(marginVault.getFreeMargin(ALICE_ACCOUNT), aliceFreeBefore - expectedIM);
        assertEq(marginVault.getFreeMargin(BOB_ACCOUNT), bobFreeBefore - expectedIM);

        // Verify account positions tracked
        bytes32[] memory alicePositions = clearingHouse.getAccountPositions(ALICE_ACCOUNT);
        bytes32[] memory bobPositions = clearingHouse.getAccountPositions(BOB_ACCOUNT);
        assertEq(alicePositions.length, 1);
        assertEq(alicePositions[0], tradeId);
        assertEq(bobPositions.length, 1);
        assertEq(bobPositions[0], tradeId);

        // ═══════════════════════════════════════════════════════════════
        // Step 3: Settle variation margin mid-trade
        // ═══════════════════════════════════════════════════════════════
        uint256 aliceCollateralBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobCollateralBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);

        // Alice (fixed payer) profits from rate increase
        int256 npvChange = 10_000e6; // $10k profit for Alice

        // Get current position to calculate newNpv (contract expects absolute NPV, not delta)
        IClearingHouse.NovatedPosition memory posBeforeVM = clearingHouse.getPosition(tradeId);
        int256 newNpv = posBeforeVM.lastNpv + npvChange;

        vm.prank(settler);
        clearingHouse.settleVariationMarginSinglePosition(tradeId, newNpv);

        // Verify VM settlement
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceCollateralBefore + uint256(npvChange));
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobCollateralBefore - uint256(npvChange));

        // Verify lastNpv updated
        IClearingHouse.NovatedPosition memory posAfterVM = clearingHouse.getPosition(tradeId);
        assertEq(posAfterVM.lastNpv, newNpv);
        assertTrue(posAfterVM.active); // Still active

        // ═══════════════════════════════════════════════════════════════
        // Step 4: Warp to maturity and settle positions
        // ═══════════════════════════════════════════════════════════════
        vm.warp(block.timestamp + ONE_YEAR + 1);

        // Settle the matured position
        uint256 aliceLockedBeforeMaturity = marginVault.getLockedIM(ALICE_ACCOUNT);
        uint256 bobLockedBeforeMaturity = marginVault.getLockedIM(BOB_ACCOUNT);

        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId, 0);

        // Verify position settled
        IClearingHouse.NovatedPosition memory posMatured = clearingHouse.getPosition(tradeId);
        assertFalse(posMatured.active);

        // Verify IM released
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), aliceLockedBeforeMaturity - expectedIM);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), bobLockedBeforeMaturity - expectedIM);

        // Verify tokens burned
        assertEq(instrument.balanceOf(alice, posMatured.tokenIdA), 0);
        assertEq(instrument.balanceOf(bob, posMatured.tokenIdB), 0);

        // ═══════════════════════════════════════════════════════════════
        // Step 5: Verify final state
        // ═══════════════════════════════════════════════════════════════
        assertEq(clearingHouse.activePositionCount(), 0);

        // Both should have their IM released
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), 0);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Additional Happy Path: Multiple Parties
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Test multiple trades between different parties (using unique nonces per account pair)
    function test_multipleTrades_multipleParties_happyPath() public {
        // Alice trades with Bob (nonce=1)
        bytes32 tradeId1 = keccak256("TRADE_MULTI_1");
        _submitTrade(tradeId1, ALICE_ACCOUNT, BOB_ACCOUNT, NOTIONAL, 1);

        // Bob trades with Charlie (nonce=2, different from Bob's nonce in trade 1)
        bytes32 tradeId2 = keccak256("TRADE_MULTI_2");
        _submitTrade(tradeId2, BOB_ACCOUNT, CHARLIE_ACCOUNT, NOTIONAL_2, 2);

        // Note: Can't do Alice-Charlie trade easily because would need nonce=2 for both
        // which would conflict with existing nonces. The happy path is tested above.

        assertEq(clearingHouse.activePositionCount(), 2);

        // Verify each party's positions
        assertEq(clearingHouse.getAccountPositions(ALICE_ACCOUNT).length, 1);
        assertEq(clearingHouse.getAccountPositions(BOB_ACCOUNT).length, 2);
        assertEq(clearingHouse.getAccountPositions(CHARLIE_ACCOUNT).length, 1);

        // Settle VM for each position using batch settlement
        IClearingHouse.VMSettlement[] memory settlements = new IClearingHouse.VMSettlement[](2);
        settlements[0] = IClearingHouse.VMSettlement({tradeId: tradeId1, npvChange: int256(5_000e6)});
        settlements[1] = IClearingHouse.VMSettlement({tradeId: tradeId2, npvChange: int256(3_000e6)});

        vm.prank(settler);
        clearingHouse.settleVariationMarginBatch(settlements);

        // Verify balances updated (net effect)
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), 2_000_000e6 + 5_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), 2_000_000e6 + 5_000e6 + 3_000e6);
        assertEq(marginVault.getTotalCollateral(CHARLIE_ACCOUNT), 2_000_000e6 - 3_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helper Functions
    // ═══════════════════════════════════════════════════════════════════

    function _fundMarginAccount(bytes32 accountId, address token, uint256 amount) internal {
        // Get the account owner from whitelist
        address accountOwner = whitelist.getAccountOwner(accountId);
        require(accountOwner != address(0), "Account not whitelisted");
        
        vm.startPrank(accountOwner);
        ERC20Mock(token).mint(accountOwner, amount);
        ERC20Mock(token).approve(address(marginVault), amount);
        marginVault.depositMargin(accountId, token, amount);
        vm.stopPrank();
    }

    function _submitTrade(
        bytes32 tradeId,
        bytes32 partyA,
        bytes32 partyB,
        uint256 notional,
        uint256 nonce
    ) internal {
        IClearingHouse.MatchedTrade memory trade = IClearingHouse.MatchedTrade({
            tradeId: tradeId,
            partyA: partyA,
            partyB: partyB,
            notional: notional,
            fixedRateBps: FIXED_RATE_BPS,
            startDate: block.timestamp,
            maturityDate: block.timestamp + ONE_YEAR,
            paymentInterval: NINETY_DAYS,
            dayCountConvention: 0,
            floatingRateIndex: SOFR_INDEX,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });

        // Get the wallets for signing based on account
        Vm.Wallet memory walletA = _getWalletForAccount(partyA);
        Vm.Wallet memory walletB = _getWalletForAccount(partyB);

        bytes memory sigA = _signTrade(trade, walletA);
        bytes memory sigB = _signTrade(trade, walletB);

        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function _getWalletForAccount(bytes32 accountId) internal view returns (Vm.Wallet memory) {
        if (accountId == ALICE_ACCOUNT) return aliceWallet;
        if (accountId == BOB_ACCOUNT) return bobWallet;
        if (accountId == CHARLIE_ACCOUNT) return charlieWallet;
        revert("Unknown account");
    }

    function _signTrade(
        IClearingHouse.MatchedTrade memory trade,
        Vm.Wallet memory wallet
    ) internal returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                clearingHouse.MATCHED_TRADE_TYPEHASH(),
                trade.tradeId, trade.partyA, trade.partyB,
                trade.notional, trade.fixedRateBps,
                trade.startDate, trade.maturityDate, trade.paymentInterval,
                trade.dayCountConvention, trade.floatingRateIndex,
                trade.nonce, trade.deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ClearRate CCP"),
                keccak256("1"),
                block.chainid,
                address(clearingHouse)
            )
        );
    }
}
