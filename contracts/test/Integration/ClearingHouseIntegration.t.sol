// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IClearingHouse} from "../../src/interfaces/IClearingHouse.sol";
import {ClearingHouse} from "../../src/core/ClearingHouse.sol";
import {IRSInstrument} from "../../src/core/IRSInstrument.sol";
import {MarginVault} from "../../src/margin/MarginVault.sol";
import {RiskEngine} from "../../src/margin/RiskEngine.sol";
import {Whitelist} from "../../src/access/Whitelist.sol";
import {LiquidationEngine} from "../../src/liquidation/LiquidationEngine.sol";
import {InsuranceFund} from "../../src/insurance/InsuranceFund.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title ClearingHouseIntegrationTest
/// @notice Integration test covering the happy path lifecycle of a novated IRS trade.
/// @dev This test exercises the full flow: setup → trade submission (via onReport) → VM settlement → compression → maturity.
contract ClearingHouseIntegrationTest is Test {
    // ─── Contracts ──────────────────────────────────────────────────────
    ClearingHouse internal clearingHouse;
    IRSInstrument internal instrument;
    MarginVault internal marginVault;
    RiskEngine internal riskEngine;
    Whitelist internal whitelist;
    LiquidationEngine internal liquidationEngine;
    InsuranceFund internal insuranceFund;
    ERC20Mock internal usdc;
    ERC20Mock internal dai;

    // ─── Actors ─────────────────────────────────────────────────────────
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal settler = makeAddr("settler");
    address internal forwarder = makeAddr("forwarder");

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
    bytes32 public constant LIQUIDATION_ENGINE_ROLE = keccak256("LIQUIDATION_ENGINE_ROLE");

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
        whitelist = new Whitelist(admin, forwarder);
        vm.startPrank(admin);
        // addParticipant(address participant, bytes32 accountId, uint256 customMaxNotional, uint64 kycExpiry)
        whitelist.addParticipant(alice, ALICE_ACCOUNT, 1000000e6, uint64(block.timestamp) + 365 days);
        whitelist.addParticipant(bob, BOB_ACCOUNT, 1000000e6, uint64(block.timestamp) + 365 days);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT, 1000000e6, uint64(block.timestamp) + 365 days);
        vm.stopPrank();

        // Deploy MarginVault with multiple tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);
        marginVault = new MarginVault(admin, address(whitelist), tokens);

        // Deploy RiskEngine: 99% confidence, 75% MM ratio
        riskEngine = new RiskEngine(admin, address(marginVault), 9900, 7500);

        // Deploy IRSInstrument
        instrument = new IRSInstrument(admin, "https://metadata.clearrate.io/{id}.json");

        // Deploy ClearingHouse with forwarder
        clearingHouse = new ClearingHouse(
            admin,
            forwarder, // Forwarder address
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist)
        );

        // Wire up roles
        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        marginVault.grantRole(LIQUIDATION_ENGINE_ROLE, address(liquidationEngine));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        whitelist.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));

        // Set risk weights for different tenors
        riskEngine.setRiskWeight(NINETY_DAYS, 100);   // 1% for 90 days
        riskEngine.setRiskWeight(ONE_YEAR, 200);      // 2% for 1 year
        riskEngine.setRiskWeight(2 * ONE_YEAR, 300); // 3% for 2 years

        // Deploy InsuranceFund
        address[] memory insuranceTokens = new address[](1);
        insuranceTokens[0] = address(usdc);
        insuranceFund = new InsuranceFund(admin, insuranceTokens);

        // Deploy LiquidationEngine
        liquidationEngine = new LiquidationEngine(
            admin,
            forwarder,
            address(clearingHouse),
            address(riskEngine),
            address(marginVault),
            address(insuranceFund),
            address(whitelist),
            3600, // 1 hour auction duration
            500   // 5% starting premium
        );

        // Wire up roles for liquidation
        vm.startPrank(admin);
        clearingHouse.grantRole(clearingHouse.LIQUIDATION_ENGINE_ROLE(), address(liquidationEngine));
        marginVault.grantRole(marginVault.LIQUIDATION_ENGINE_ROLE(), address(liquidationEngine));
        liquidationEngine.grantRole(liquidationEngine.CLEARING_HOUSE_ROLE(), address(clearingHouse));


        // Grant operator & settler roles - forwarder needs OPERATOR_ROLE to call onReport
        clearingHouse.grantRole(OPERATOR_ROLE, forwarder);
        clearingHouse.grantRole(OPERATOR_ROLE, operator);
        clearingHouse.grantRole(SETTLEMENT_ROLE, settler);
        vm.stopPrank();

        // Fund margin accounts with USDC
        _fundMarginAccount(ALICE_ACCOUNT, address(usdc), 2_000_000e6);
        _fundMarginAccount(BOB_ACCOUNT, address(usdc), 2_000_000e6);
        _fundMarginAccount(CHARLIE_ACCOUNT, address(usdc), 2_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Happy Path Integration Test
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Full happy path test: submit trade → settle VM → mature
    function test_fullHappyPath_integration() public {
        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 1: Verify initial state
        // ═══════════════════════════════════════════════════════════════════════════════
        assertEq(clearingHouse.activePositionCount(), 0);
        assertTrue(whitelist.isWhitelisted(alice));
        assertTrue(whitelist.isWhitelisted(bob));
        
        uint256 aliceFreeBefore = marginVault.getFreeMarginByToken(ALICE_ACCOUNT, address(usdc));
        uint256 bobFreeBefore = marginVault.getFreeMarginByToken(BOB_ACCOUNT, address(usdc));
        assertEq(aliceFreeBefore, 2_000_000e6);
        assertEq(bobFreeBefore, 2_000_000e6);

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 2: Submit matched trade via onReport (Chainlink CRE workflow)
        // ═══════════════════════════════════════════════════════════════════════════════
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
            deadline: block.timestamp + 1 hours,
            collateralToken: address(usdc)
        });

        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Submit trade via onReport (mocks Chainlink CRE workflow)
        // Report type 0 = trade submission
        bytes memory report = abi.encode(uint8(0), trade, sigA, sigB);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

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
        assertEq(marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc)), expectedIM);
        assertEq(marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc)), expectedIM);
        assertEq(marginVault.getFreeMarginByToken(ALICE_ACCOUNT, address(usdc)), aliceFreeBefore - expectedIM);
        assertEq(marginVault.getFreeMarginByToken(BOB_ACCOUNT, address(usdc)), bobFreeBefore - expectedIM);

        // Verify account positions tracked
        bytes32[] memory alicePositions = clearingHouse.getAccountPositions(ALICE_ACCOUNT, address(usdc));
        bytes32[] memory bobPositions = clearingHouse.getAccountPositions(BOB_ACCOUNT, address(usdc));
        assertEq(alicePositions.length, 1);
        assertEq(alicePositions[0], tradeId);
        assertEq(bobPositions.length, 1);
        assertEq(bobPositions[0], tradeId);

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 3: Settle variation margin via onReport
        // ═══════════════════════════════════════════════════════════════════════════════
        uint256 aliceCollateralBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        uint256 bobCollateralBefore = marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc));

        // Alice (fixed payer) profits from rate increase
        int256 npvChange = 10_000e6; // $10k profit for Alice

        // Get current position to calculate newNpv (contract expects absolute NPV, not delta)
        IClearingHouse.NovatedPosition memory posBeforeVM = clearingHouse.getPosition(tradeId);
        int256 newNpv = posBeforeVM.lastNpv + npvChange;

        // Submit VM settlement via onReport
        // Report type 1 = VM settlement
        IClearingHouse.VMSettlement[] memory settlements = new IClearingHouse.VMSettlement[](1);
        settlements[0] = IClearingHouse.VMSettlement({tradeId: tradeId, npvChange: npvChange});
        
        report = abi.encode(uint8(1), settlements);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

        // Verify VM settlement
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc)), aliceCollateralBefore + uint256(npvChange));
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc)), bobCollateralBefore - uint256(npvChange));

        // Verify lastNpv updated
        IClearingHouse.NovatedPosition memory posAfterVM = clearingHouse.getPosition(tradeId);
        assertEq(posAfterVM.lastNpv, newNpv);
        assertTrue(posAfterVM.active); // Still active

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 4: Warp to maturity and settle positions via onReport
        // ═══════════════════════════════════════════════════════════════════════════════
        vm.warp(block.timestamp + ONE_YEAR + 1);

        // Settle the matured position
        uint256 aliceLockedBeforeMaturity = marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc));
        uint256 bobLockedBeforeMaturity = marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc));

        // Submit matured position settlement via onReport
        // Report type 2 = matured position settlement
        IClearingHouse.MaturedPositionSettlement[] memory maturedSettlements = new IClearingHouse.MaturedPositionSettlement[](1);
        maturedSettlements[0] = IClearingHouse.MaturedPositionSettlement({tradeId: tradeId, finalNpvChange: 0});
        
        report = abi.encode(uint8(2), maturedSettlements);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

        // Verify position settled
        IClearingHouse.NovatedPosition memory posMatured = clearingHouse.getPosition(tradeId);
        assertFalse(posMatured.active);

        // Verify IM released
        assertEq(marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc)), aliceLockedBeforeMaturity - expectedIM);
        assertEq(marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc)), bobLockedBeforeMaturity - expectedIM);

        // Verify tokens burned
        assertEq(instrument.balanceOf(alice, posMatured.tokenIdA), 0);
        assertEq(instrument.balanceOf(bob, posMatured.tokenIdB), 0);

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 5: Verify final state
        // ═══════════════════════════════════════════════════════════════════════════════
        assertEq(clearingHouse.activePositionCount(), 0);

        // Both should have their IM released
        assertEq(marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc)), 0);
        assertEq(marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Liquidation Process Test
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test the complete liquidation process: trade → adverse VM → liquidation → auction → absorb
    function test_liquidationProcess_integration() public {
        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 1: Create a trade with Alice (undercollateralized after adverse move)
        // ═══════════════════════════════════════════════════════════════════════════════
        bytes32 tradeId = keccak256("TRADE_LIQUIDATION_1");
        
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
            nonce: 2,
            deadline: block.timestamp + 1 hours,
            collateralToken: address(usdc)
        });

        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Submit trade via onReport
        bytes memory report = abi.encode(uint8(0), trade, sigA, sigB);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

        // Verify trade was submitted and IM locked
        assertTrue(clearingHouse.tradeSubmitted(tradeId));
        assertEq(clearingHouse.activePositionCount(), 1);

        uint256 expectedIM = riskEngine.calculateIM(NOTIONAL, ONE_YEAR);
        assertEq(marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc)), expectedIM);
        assertEq(marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc)), expectedIM);

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 2: Simulate adverse move for Alice (fixed payer loses money)
        // ═══════════════════════════════════════════════════════════════════════════════
        uint256 aliceCollateralBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        uint256 bobCollateralBefore = marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc));

        // Alice (fixed payer) loses money from rate decrease - large negative NPV
        int256 adverseNpvChange = -1_990_000e6; // $1.99M loss for Alice

        // Submit VM settlement via onReport
        IClearingHouse.VMSettlement[] memory settlements = new IClearingHouse.VMSettlement[](1);
        settlements[0] = IClearingHouse.VMSettlement({tradeId: tradeId, npvChange: adverseNpvChange});
        
        report = abi.encode(uint8(1), settlements);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

        // Verify Alice's collateral decreased (she lost money)
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc)), aliceCollateralBefore - 1_990_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc)), bobCollateralBefore + 1_990_000e6);

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 3: Verify Alice is now undercollateralized and liquidatable
        // ═══════════════════════════════════════════════════════════════════════════════
        uint256 aliceTotalCollateral = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        uint256 aliceMM = riskEngine.accountMaintenanceMargin(ALICE_ACCOUNT, address(usdc));

        // Alice should be undercollateralized (total collateral < MM)
        assertTrue(aliceTotalCollateral < aliceMM, "Alice should be undercollateralized");
        assertTrue(riskEngine.isLiquidatable(ALICE_ACCOUNT, address(usdc)), "Alice should be liquidatable");

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 4: Start liquidation auction
        // ═══════════════════════════════════════════════════════════════════════════════
        vm.startPrank(charlie); // Liquidator starts auction
        
        // Verify no auction exists before
        assertFalse(liquidationEngine.isAuctionActive(ALICE_ACCOUNT, address(usdc)));
        
        // Start liquidation
        LiquidationEngine.LiquidationTarget[] memory liquidationTargets = new LiquidationEngine.LiquidationTarget[](1); 
        liquidationTargets[0] = LiquidationEngine.LiquidationTarget({accountId: ALICE_ACCOUNT, collateralToken: address(usdc)});
        liquidationEngine.liquidateAccounts(liquidationTargets);

        // Verify auction started
        assertTrue(liquidationEngine.isAuctionActive(ALICE_ACCOUNT, address(usdc)));
        
        // Verify auction details
        uint256 currentPremium = liquidationEngine.getCurrentPremium(ALICE_ACCOUNT, address(usdc));
        assertEq(currentPremium, 500); // 5% starting premium

        vm.stopPrank();

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 5: Wait for auction to progress and premium to decay
        // ═══════════════════════════════════════════════════════════════════════════════
        vm.warp(block.timestamp + 1800); // Wait 30 minutes (half of 1-hour auction)

        // Premium should have decayed
        uint256 decayedPremium = liquidationEngine.getCurrentPremium(ALICE_ACCOUNT, address(usdc));
        assertTrue(decayedPremium < 500, "Premium should have decayed");
        assertTrue(decayedPremium > 0, "Premium should not be zero yet");

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 6: Liquidator absorbs position at current premium
        // ═══════════════════════════════════════════════════════════════════════════════
        vm.startPrank(charlie);
        
        // Get Charlie's collateral before absorption
        uint256 charlieCollateralBefore = marginVault.getTotalCollateral(CHARLIE_ACCOUNT, address(usdc));
        
        console2.log(charlie);
        // Absorb Alice's position
        liquidationEngine.absorbPositions(ALICE_ACCOUNT, address(usdc));

        // Verify auction ended
        assertFalse(liquidationEngine.isAuctionActive(ALICE_ACCOUNT, address(usdc)));

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 7: Verify position transfer and margin handling
        // ═══════════════════════════════════════════════════════════════════════════════
        
        // Verify position was transferred to Charlie
        IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.partyA, CHARLIE_ACCOUNT, "Position should be transferred to liquidator");
        assertEq(pos.partyB, BOB_ACCOUNT, "Counterparty should remain Bob");

        // Verify Charlie now has the position in his account
        bytes32[] memory charliePositions = clearingHouse.getAccountPositions(CHARLIE_ACCOUNT, address(usdc));
        assertEq(charliePositions.length, 1);
        assertEq(charliePositions[0], tradeId);

        // Verify Alice no longer has the position
        bytes32[] memory alicePositions = clearingHouse.getAccountPositions(ALICE_ACCOUNT, address(usdc));
        assertEq(alicePositions.length, 0);

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 8: Verify margin requirements and premium transfer
        // ═══════════════════════════════════════════════════════════════════════════════
        
        // Charlie should have IM locked for the position
        uint256 charlieLockedIM = marginVault.getLockedIMByToken(CHARLIE_ACCOUNT, address(usdc));
        assertEq(charlieLockedIM, expectedIM, "Charlie should have IM locked");

        // Charlie should have received premium from Alice's remaining collateral
        uint256 charlieCollateralAfter = marginVault.getTotalCollateral(CHARLIE_ACCOUNT, address(usdc));
        uint256 premiumReceived = charlieCollateralAfter - charlieCollateralBefore;
        assertTrue(premiumReceived > 0, "Charlie should have received premium");

        // Alice's remaining collateral should be reduced by the premium
        uint256 aliceCollateralAfter = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        uint256 aliceCollateralUsedForPremium = aliceTotalCollateral - aliceCollateralAfter;
        assertEq(premiumReceived, aliceCollateralUsedForPremium, "Premium should match collateral transferred");

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 9: Verify maintenance margin updates
        // ═══════════════════════════════════════════════════════════════════════════════
        
        // Charlie's MM should be updated based on his new IM requirement
        uint256 charlieMM = riskEngine.accountMaintenanceMargin(CHARLIE_ACCOUNT, address(usdc));
        assertEq(charlieMM, riskEngine.calculateMM(expectedIM), "Charlie's MM should be based on his IM");

        // Alice's MM should be zero (no positions)
        uint256 aliceMMAfter = riskEngine.accountMaintenanceMargin(ALICE_ACCOUNT, address(usdc));
        assertEq(aliceMMAfter, 0, "Alice's MM should be zero after liquidation");

        // ═══════════════════════════════════════════════════════════════════════════════
        // Step 10: Verify notional tracking
        // ═══════════════════════════════════════════════════════════════════════════════
        
        // Charlie should have notional tracked
        uint256 charlieNotional = whitelist.getTotalOpenNotional(charlie);
        assertEq(charlieNotional, NOTIONAL, "Charlie should have notional tracked");

        // Alice should have zero notional
        uint256 aliceNotional = whitelist.getTotalOpenNotional(alice);
        assertEq(aliceNotional, 0, "Alice should have zero notional after liquidation");

        vm.stopPrank();
    }

    /// @notice Test liquidation when Alice has insufficient collateral to cover premium
    function test_liquidationWithInsufficientCollateral() public {
        // Create trade
        bytes32 tradeId = keccak256("TRADE_LIQUIDATION_2");
        
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
            nonce: 3,
            deadline: block.timestamp + 1 hours,
            collateralToken: address(usdc)
        });

        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        bytes memory report = abi.encode(uint8(0), trade, sigA, sigB);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

        // Simulate massive adverse move that wipes out Alice's collateral
        int256 massiveLoss = -2_500_000e6; // More than Alice's total collateral

        IClearingHouse.VMSettlement[] memory settlements = new IClearingHouse.VMSettlement[](1);
        settlements[0] = IClearingHouse.VMSettlement({tradeId: tradeId, npvChange: massiveLoss});
        
        report = abi.encode(uint8(1), settlements);
        vm.prank(forwarder);
        clearingHouse.onReport("", report);

        // Alice should be bankrupt (negative collateral)
        uint256 aliceCollateral = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        assertEq(aliceCollateral, 0, "Alice's collateral should be zero after massive loss");

        // Alice should still be liquidatable
        assertTrue(riskEngine.isLiquidatable(ALICE_ACCOUNT, address(usdc)));

        // Start liquidation
        vm.startPrank(charlie);
        LiquidationEngine.LiquidationTarget[] memory liquidationTargets = new LiquidationEngine.LiquidationTarget[](1); 
        liquidationTargets[0] = LiquidationEngine.LiquidationTarget({accountId: ALICE_ACCOUNT, collateralToken: address(usdc)});
        liquidationEngine.liquidateAccounts(liquidationTargets);
        assertTrue(liquidationEngine.isAuctionActive(ALICE_ACCOUNT, address(usdc)));

        // Liquidator absorbs position
        liquidationEngine.absorbPositions(ALICE_ACCOUNT, address(usdc));

        // Verify position transferred to Charlie
        IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.partyA, CHARLIE_ACCOUNT);

        // Charlie should have IM locked and MM updated
        uint256 expectedIM = riskEngine.calculateIM(NOTIONAL, ONE_YEAR);
        assertEq(marginVault.getLockedIMByToken(CHARLIE_ACCOUNT, address(usdc)), expectedIM);
        assertEq(riskEngine.accountMaintenanceMargin(CHARLIE_ACCOUNT, address(usdc)), riskEngine.calculateMM(expectedIM));

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Helper Functions
    // ═══════════════════════════════════════════════════════════════════════════════════════

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
                trade.nonce, trade.deadline, trade.collateralToken
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
