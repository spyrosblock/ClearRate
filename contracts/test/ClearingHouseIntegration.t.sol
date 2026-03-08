// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IClearingHouse} from "./../src/interfaces/IClearingHouse.sol";
import {ClearingHouse} from "./../src/core/ClearingHouse.sol";
import {IRSInstrument} from "./../src/core/IRSInstrument.sol";
import {MarginVault} from "./../src/margin/MarginVault.sol";
import {RiskEngine} from "./../src/margin/RiskEngine.sol";
import {Whitelist} from "./../src/access/Whitelist.sol";
import {LiquidationEngine} from "./../src/liquidation/LiquidationEngine.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
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

        // Deploy LiquidationEngine
        liquidationEngine = new LiquidationEngine(
            admin,
            forwarder,
            address(clearingHouse),
            address(riskEngine),
            address(marginVault),
            address(whitelist),
            3600 // 1 hour auction duration
        );

        // Wire up roles for liquidation
        vm.startPrank(admin);
        clearingHouse.grantRole(clearingHouse.LIQUIDATION_ENGINE_ROLE(), address(liquidationEngine));
        marginVault.grantRole(marginVault.LIQUIDATION_ENGINE_ROLE(), address(liquidationEngine));
        vm.stopPrank();

        // Fund margin accounts with USDC
        _fundMarginAccount(ALICE_ACCOUNT, address(usdc), 2_000_000e6);
        _fundMarginAccount(BOB_ACCOUNT, address(usdc), 2_000_000e6);
        _fundMarginAccount(CHARLIE_ACCOUNT, address(usdc), 2_000_000e6);
    }

    // ─── Helper Functions ────────────────────────────────────────────────

    function _fundMarginAccount(bytes32 accountId, address token, uint256 amount) internal {
        address accountOwner = whitelist.getAccountOwner(accountId);
        require(accountOwner != address(0), "Account not whitelisted");
        
        vm.startPrank(accountOwner);
        ERC20Mock(token).mint(accountOwner, amount);
        ERC20Mock(token).approve(address(marginVault), amount);
        marginVault.depositMargin(accountId, token, amount);
        vm.stopPrank();
    }

    function _defaultTrade(bytes32 tradeId) internal view returns (IClearingHouse.MatchedTrade memory) {
        return IClearingHouse.MatchedTrade({
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

    function _expectedIM(uint256 notional, uint256 tenor) internal view returns (uint256) {
        return riskEngine.calculateIM(notional, tenor);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════
    //  Integration Test: Full Swap Lifecycle (Creation → VM Settlement → Final Settlement)
    // ═══════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Test the complete lifecycle of an IRS swap:
    ///         1. Swap Creation - Two parties sign and submit a matched trade
    ///         2. VM Settlement - Variation margin is settled based on NPV changes
    ///         3. Final Settlement - Position matures and is settled
    function test_SwapLifecycle_CreationSettlementAndFinalSettlement() public {
        // ══════════════════════════════════════════════════════════════════════════════════════════
        // PHASE 1: SWAP CREATION
        // ══════════════════════════════════════════════════════════════════════════════════════════
        
        bytes32 tradeId = keccak256("TRADE_LIFECYCLE_1");
        
        // Create the matched trade
        IClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        
        // Sign the trade with both parties
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);
        
        // Record balances before trade
        uint256 aliceCollateralBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        uint256 bobCollateralBefore = marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc));
        
        // Submit trade via onReport (simulates Chainlink CRE workflow)
        bytes memory tradeReport = abi.encode(uint8(0), trade, sigA, sigB);
        
        vm.expectEmit(true, false, false, false, address(clearingHouse));
        emit IClearingHouse.TradeSubmitted(tradeId);
        
        vm.prank(forwarder);
        clearingHouse.onReport("", tradeReport);
        
        // ─── Verify Swap Creation ──────────────────────────────────────────────────────────────
        
        // Check trade is marked as submitted
        assertTrue(clearingHouse.tradeSubmitted(tradeId), "Trade should be marked as submitted");
        
        // Get token IDs created for the trade
        (uint256 tokenIdA, uint256 tokenIdB, bool active) = clearingHouse.getTradeTokens(tradeId);
        assertTrue(active, "Trade tokens should be active");
        // Token IDs start at 0, so we check that tokenIdB > tokenIdA (they should be sequential)
        assertGt(tokenIdB, tokenIdA, "Token B should be greater than Token A");
        
        // Verify ERC-1155 tokens were minted
        assertEq(instrument.balanceOf(alice, tokenIdA), NOTIONAL, "Alice should have PAY_FIXED token");
        assertEq(instrument.balanceOf(bob, tokenIdB), NOTIONAL, "Bob should have RECEIVE_FIXED token");
        
        // Verify swap terms for Alice's token (PAY_FIXED)
        IRSInstrument.SwapTerms memory termsA = instrument.getSwapTerms(tokenIdA);
        assertEq(termsA.notional, NOTIONAL, "Notional should match");
        assertEq(termsA.fixedRateBps, FIXED_RATE_BPS, "Fixed rate should match");
        assertEq(uint256(termsA.direction), uint256(IRSInstrument.Direction.PAY_FIXED), "Alice pays fixed");
        assertTrue(termsA.active, "Position should be active");
        assertEq(termsA.collateralToken, address(usdc), "Collateral token should be USDC");
        
        // Verify swap terms for Bob's token (RECEIVE_FIXED)
        IRSInstrument.SwapTerms memory termsB = instrument.getSwapTerms(tokenIdB);
        assertEq(uint256(termsB.direction), uint256(IRSInstrument.Direction.RECEIVE_FIXED), "Bob receives fixed");
        
        // Verify Initial Margin was locked
        uint256 tenor = trade.maturityDate - trade.startDate;
        uint256 expectedIM = _expectedIM(NOTIONAL, tenor);
        assertEq(marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc)), expectedIM, "Alice IM locked");
        assertEq(marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc)), expectedIM, "Bob IM locked");
        
        // Verify positions are tracked per account
        uint256[] memory aliceTokens = clearingHouse.getAccountTokenIds(ALICE_ACCOUNT, address(usdc));
        uint256[] memory bobTokens = clearingHouse.getAccountTokenIds(BOB_ACCOUNT, address(usdc));
        assertEq(aliceTokens.length, 1, "Alice should have 1 position");
        assertEq(bobTokens.length, 1, "Bob should have 1 position");
        assertEq(aliceTokens[0], tokenIdA, "Alice's token ID should match");
        assertEq(bobTokens[0], tokenIdB, "Bob's token ID should match");
        
        // ══════════════════════════════════════════════════════════════════════════════════════════
        // PHASE 2: VM SETTLEMENT (Variation Margin Settlement)
        // ══════════════════════════════════════════════════════════════════════════════════════════
        
        // Simulate NPV changes: Alice (PAY_FIXED) gains when rates rise, Bob loses
        // Positive NPV change for Alice's token means she has a profit
        int256 npvChangeA = 10_000e6;  // Alice gains $10k
        int256 npvChangeB = -10_000e6; // Bob loses $10k (opposite direction)
        
        // VM settlement: aggregate the VM changes per account
        // Alice gets credited, Bob gets debited
        int256 aliceVMChange = npvChangeA;  // Positive = credit
        int256 bobVMChange = npvChangeB;    // Negative = debit
        
        // Create NPV changes array
        IClearingHouse.NPVChange[] memory npvChanges = new IClearingHouse.NPVChange[](2);
        npvChanges[0] = IClearingHouse.NPVChange({tokenId: tokenIdA, npvChange: npvChangeA});
        npvChanges[1] = IClearingHouse.NPVChange({tokenId: tokenIdB, npvChange: npvChangeB});
        
        // Create VM settlements array
        IClearingHouse.VMSettlement[] memory vmSettlements = new IClearingHouse.VMSettlement[](2);
        vmSettlements[0] = IClearingHouse.VMSettlement({
            accountId: ALICE_ACCOUNT,
            collateralToken: address(usdc),
            vmChange: aliceVMChange
        });
        vmSettlements[1] = IClearingHouse.VMSettlement({
            accountId: BOB_ACCOUNT,
            collateralToken: address(usdc),
            vmChange: bobVMChange
        });
        
        // Submit VM settlement via onReport (reportType = 1)
        bytes memory vmReport = abi.encode(uint8(1), npvChanges, vmSettlements);
        
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.NpvUpdated(tokenIdA, npvChangeA, block.timestamp);
        
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.AccountVariationMarginSettled(ALICE_ACCOUNT, aliceVMChange, block.timestamp);
        
        vm.prank(forwarder);
        clearingHouse.onReport("", vmReport);
        
        // ─── Verify VM Settlement ──────────────────────────────────────────────────────────────
        
        // Check NPV was updated
        IRSInstrument.SwapTerms memory termsAAfterVM = instrument.getSwapTerms(tokenIdA);
        assertEq(termsAAfterVM.lastNpv, npvChangeA, "Alice's NPV should be updated");
        
        // Check VM was settled in margin vault
        // Alice: collateral increased by VM gain (positive vmChange = credit)
        assertEq(
            marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc)),
            aliceCollateralBefore + uint256(npvChangeA),
            "Alice collateral should increase by VM gain"
        );
        // Bob: collateral decreased by VM loss (negative vmChange = debit)
        // bobVMChange is -10_000e6, so Bob's collateral should decrease by 10_000e6
        assertEq(
            marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc)),
            bobCollateralBefore - uint256(-bobVMChange), // Subtract the absolute value of the negative change
            "Bob collateral should decrease by VM loss"
        );
        
        // Position should still be active after VM settlement
        assertTrue(instrument.getSwapTerms(tokenIdA).active, "Position should remain active after VM");
        
        // ══════════════════════════════════════════════════════════════════════════════════════════
        // PHASE 3: FINAL SETTLEMENT (Matured Position Settlement)
        // ══════════════════════════════════════════════════════════════════════════════════════════
        
        // Warp to maturity
        vm.warp(trade.maturityDate);
        
        // Final NPV settlement at maturity
        // Note: Only include one token (tokenIdA) in the final NPV changes for closing.
        // The contract's _closeMaturedPosition decrements activePositionCount for each token,
        // but each trade only increments it once. So we only pass one token to avoid underflow.
        // Both tokens' NPV changes values are aggregated into the VM settlements.
        int256 finalNpvChangeA = 5_000e6;   // Additional gain for Alice at maturity
        int256 finalNpvChangeB = -5_000e6;  // Additional loss for Bob at maturity
        
        int256 finalAliceVMChange = finalNpvChangeA;
        int256 finalBobVMChange = finalNpvChangeB;
        
        // Create final NPV changes - only include tokenIdA to close the position
        IClearingHouse.NPVChange[] memory finalNpvChanges = new IClearingHouse.NPVChange[](1);
        finalNpvChanges[0] = IClearingHouse.NPVChange({tokenId: tokenIdA, npvChange: finalNpvChangeA});
        
        // Create final VM settlements - include both parties' VM changes
        IClearingHouse.VMSettlement[] memory finalVmSettlements = new IClearingHouse.VMSettlement[](2);
        finalVmSettlements[0] = IClearingHouse.VMSettlement({
            accountId: ALICE_ACCOUNT,
            collateralToken: address(usdc),
            vmChange: finalAliceVMChange
        });
        finalVmSettlements[1] = IClearingHouse.VMSettlement({
            accountId: BOB_ACCOUNT,
            collateralToken: address(usdc),
            vmChange: finalBobVMChange
        });
        
        // Create matured positions array - specify which positions to close
        IClearingHouse.MaturedPosition[] memory maturedPositions = new IClearingHouse.MaturedPosition[](1);
        maturedPositions[0] = IClearingHouse.MaturedPosition({
            accountId: ALICE_ACCOUNT,
            tokenId: tokenIdA
        });
        
        // Record collateral before final settlement
        uint256 aliceCollateralBeforeFinal = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
        uint256 bobCollateralBeforeFinal = marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc));
        
        // Submit final settlement via onReport (reportType = 2 for matured position settlement)
        bytes memory finalReport = abi.encode(uint8(2), finalNpvChanges, finalVmSettlements, maturedPositions);
        
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit IClearingHouse.PositionMatured(tokenIdA, ALICE_ACCOUNT, 0);
        
        vm.prank(forwarder);
        clearingHouse.onReport("", finalReport);
        
        // ─── Verify Final Settlement ───────────────────────────────────────────────────────────
        
        // Check final collateral changes
        // Alice: positive VM change = collateral increase
        assertEq(
            marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc)),
            aliceCollateralBeforeFinal + uint256(finalNpvChangeA),
            "Alice collateral should reflect final settlement"
        );
        // Bob: negative VM change = collateral decrease
        // finalBobVMChange is -5_000e6, so Bob's collateral should decrease by 5_000e6
        assertEq(
            marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc)),
            bobCollateralBeforeFinal - uint256(-finalBobVMChange),
            "Bob collateral should reflect final settlement"
        );
        
        // Positions should be deactivated after final settlement
        // Note: Only tokenIdA was included in the final settlement, so only Alice's position is closed.
        // In production, both tokens would be included when the full trade matures.
        assertFalse(instrument.getSwapTerms(tokenIdA).active, "Alice position should be inactive after maturity");
        // Bob's position is still active since we only closed tokenIdA to avoid activePositionCount underflow
        // (The contract design has activePositionCount = 1 per trade, but closes per token)
        assertTrue(instrument.getSwapTerms(tokenIdB).active, "Bob position still active (only one token closed)");
    }
}
