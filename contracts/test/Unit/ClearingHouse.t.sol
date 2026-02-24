// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ClearingHouse} from "../../src/core/ClearingHouse.sol";
import {IRSInstrument} from "../../src/core/IRSInstrument.sol";
import {MarginVault} from "../../src/margin/MarginVault.sol";
import {RiskEngine} from "../../src/margin/RiskEngine.sol";
import {Whitelist} from "../../src/access/Whitelist.sol";
import {YieldCurveOracle} from "../../src/oracles/YieldCurveOracle.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title ClearingHouseTest
/// @notice Comprehensive unit tests for the ClearingHouse contract.
contract ClearingHouseTest is Test {
    // ─── Contracts ──────────────────────────────────────────────────────
    ClearingHouse internal clearingHouse;
    IRSInstrument internal instrument;
    MarginVault internal marginVault;
    RiskEngine internal riskEngine;
    Whitelist internal whitelist;
    YieldCurveOracle internal oracle;
    ERC20Mock internal usdc;

    // ─── Actors ─────────────────────────────────────────────────────────
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal settler = makeAddr("settler");
    address internal nonOperator = makeAddr("nonOperator");

    Vm.Wallet internal aliceWallet;
    Vm.Wallet internal bobWallet;
    address internal alice;
    address internal bob;

    // ─── Account Ids ────────────────────────────────────────────────────
    bytes32 internal constant ALICE_ACCOUNT = keccak256("ALICE_ACCOUNT");
    bytes32 internal constant BOB_ACCOUNT = keccak256("BOB_ACCOUNT");

    // ─── Trade Constants ────────────────────────────────────────────────
    uint256 internal constant NOTIONAL = 1_000_000e6; // $1M USDC-precision
    uint256 internal constant FIXED_RATE_BPS = 500;   // 5.00%
    uint256 internal constant ONE_YEAR = 365 days;
    uint256 internal constant NINETY_DAYS = 90 days;
    bytes32 internal constant SOFR_INDEX = keccak256("SOFR");

    // ─── Role Constants ─────────────────────────────────────────────────
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 internal constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

    // ─── Events (re-declared for expectEmit) ────────────────────────────
    event TradeSubmitted(
        bytes32 indexed tradeId, bytes32 indexed partyA, bytes32 indexed partyB,
        uint256 notional, uint256 fixedRateBps
    );
    event TradeNovated(bytes32 indexed tradeId, uint256 tokenIdA, uint256 tokenIdB);
    event VariationMarginSettled(bytes32 indexed tradeId, int256 npvChange, uint256 timestamp);
    event PositionCompressed(
        bytes32 indexed accountId, bytes32 indexed tradeIdA, bytes32 indexed tradeIdB,
        uint256 notionalReduced
    );
    event PositionMatured(bytes32 indexed tradeId, uint256 timestamp);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // ─── Setup ──────────────────────────────────────────────────────────

    function setUp() public {
        // Create wallets for EIP-712 signing
        aliceWallet = vm.createWallet("alice");
        bobWallet = vm.createWallet("bob");
        alice = aliceWallet.addr;
        bob = bobWallet.addr;

        // Deploy mock stablecoin
        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        // Deploy Whitelist and add participants
        whitelist = new Whitelist(admin);
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.addParticipant(bob, BOB_ACCOUNT);
        vm.stopPrank();

        // Deploy MarginVault with USDC
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        marginVault = new MarginVault(admin, address(whitelist), tokens);

        // Deploy RiskEngine: 99% confidence, 75% MM ratio
        riskEngine = new RiskEngine(admin, address(marginVault), 9900, 7500);

        // Deploy YieldCurveOracle
        uint256[] memory tenors = new uint256[](1);
        tenors[0] = ONE_YEAR;
        oracle = new YieldCurveOracle(admin, 1 days, tenors);

        // Deploy IRSInstrument
        instrument = new IRSInstrument(admin, "https://metadata.clearrate.io/{id}.json");

        // Deploy ClearingHouse with a mock forwarder address
        address forwarder = makeAddr("forwarder");
        clearingHouse = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        // ── Wire up roles ──
        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));

        // Set risk weight for 1-year tenor: 200 bps (2%)
        riskEngine.setRiskWeight(ONE_YEAR, 200);

        // Grant operator & settler roles
        clearingHouse.grantRole(OPERATOR_ROLE, operator);
        clearingHouse.grantRole(SETTLEMENT_ROLE, settler);
        vm.stopPrank();

        // ── Fund margin accounts ──
        _fundMarginAccount(ALICE_ACCOUNT, 500_000e6);
        _fundMarginAccount(BOB_ACCOUNT, 500_000e6);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _fundMarginAccount(bytes32 accountId, uint256 amount) internal {
        // Get the account owner from whitelist
        address accountOwner = whitelist.getAccountOwner(accountId);
        require(accountOwner != address(0), "Account not whitelisted");
        
        vm.startPrank(accountOwner);
        usdc.mint(accountOwner, amount);
        usdc.approve(address(marginVault), amount);
        marginVault.depositMargin(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function _defaultTrade(bytes32 tradeId) internal view returns (ClearingHouse.MatchedTrade memory) {
        return ClearingHouse.MatchedTrade({
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
    }

    function _signTrade(
        ClearingHouse.MatchedTrade memory trade,
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

    function _submitDefaultTrade(bytes32 tradeId) internal {
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    /// @dev Expected IM for default trade: notional * 200 * 9900 / (10_000^2)
    function _expectedIM() internal pure returns (uint256) {
        return (NOTIONAL * 200 * 9900) / (10_000 * 10_000);
    }

    /// @dev Submit a second trade (Alice pays fixed to Bob) with nonce=2 and
    ///      the provided tradeId and notional. Parties are reversed so that
    ///      Alice is partyB (RECEIVE_FIXED) — useful for compression tests.
    function _submitReverseTrade(bytes32 tradeId, uint256 notional) internal {
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.partyA = BOB_ACCOUNT;   // Bob pays fixed
        trade.partyB = ALICE_ACCOUNT; // Alice receives fixed
        trade.nonce = 2;
        trade.notional = notional;
        bytes memory sigA = _signTrade(trade, bobWallet);
        bytes memory sigB = _signTrade(trade, aliceWallet);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    function test_constructor_grantsAdminDefaultAdminRole() public view {
        assertTrue(clearingHouse.hasRole(clearingHouse.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_grantsAdminOperatorRole() public view {
        assertTrue(clearingHouse.hasRole(OPERATOR_ROLE, admin));
    }

    function test_constructor_grantsAdminSettlementRole() public view {
        assertTrue(clearingHouse.hasRole(SETTLEMENT_ROLE, admin));
    }

    function test_constructor_setsImmutableDependencies() public view {
        assertEq(address(clearingHouse.instrument()), address(instrument));
        assertEq(address(clearingHouse.marginVault()), address(marginVault));
        assertEq(address(clearingHouse.riskEngine()), address(riskEngine));
        assertEq(address(clearingHouse.whitelist()), address(whitelist));
        assertEq(address(clearingHouse.oracle()), address(oracle));
    }

    function test_constructor_initialStateIsZero() public view {
        assertEq(clearingHouse.activePositionCount(), 0);
        assertEq(clearingHouse.protocolFeeBps(), 0);
        assertEq(clearingHouse.feeRecipient(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  submitMatchedTrade — Happy Path
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_success() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        assertTrue(clearingHouse.tradeSubmitted(tradeId));
        assertEq(clearingHouse.activePositionCount(), 1);
    }

    function test_submitMatchedTrade_createsNovatedPosition() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.tradeId, tradeId);
        assertEq(pos.partyA, ALICE_ACCOUNT);
        assertEq(pos.partyB, BOB_ACCOUNT);
        assertEq(pos.notional, NOTIONAL);
        assertEq(pos.fixedRateBps, FIXED_RATE_BPS);
        assertTrue(pos.active);
        assertEq(pos.lastNpv, 0);
    }

    function test_submitMatchedTrade_storesCorrectDates() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.startDate, block.timestamp);
        assertEq(pos.maturityDate, block.timestamp + ONE_YEAR);
    }

    function test_submitMatchedTrade_mintsERC1155Tokens() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(instrument.balanceOf(alice, pos.tokenIdA), NOTIONAL);
        assertEq(instrument.balanceOf(bob, pos.tokenIdB), NOTIONAL);
    }

    function test_submitMatchedTrade_tokenIdsAreSequential() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.tokenIdA, 0);
        assertEq(pos.tokenIdB, 1);
    }

    function test_submitMatchedTrade_locksInitialMargin() public {
        uint256 aliceFreeBefore = marginVault.getFreeMargin(ALICE_ACCOUNT);
        uint256 bobFreeBefore = marginVault.getFreeMargin(BOB_ACCOUNT);

        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        uint256 im = _expectedIM();
        assertEq(marginVault.getFreeMargin(ALICE_ACCOUNT), aliceFreeBefore - im);
        assertEq(marginVault.getFreeMargin(BOB_ACCOUNT), bobFreeBefore - im);
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), im);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), im);
    }

    function test_submitMatchedTrade_consumesNonces() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        assertTrue(clearingHouse.usedNonces(ALICE_ACCOUNT, 1));
        assertTrue(clearingHouse.usedNonces(BOB_ACCOUNT, 1));
    }

    function test_submitMatchedTrade_tracksAccountPositions() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        bytes32[] memory alicePos = clearingHouse.getAccountPositions(ALICE_ACCOUNT);
        bytes32[] memory bobPos = clearingHouse.getAccountPositions(BOB_ACCOUNT);
        assertEq(alicePos.length, 1);
        assertEq(alicePos[0], tradeId);
        assertEq(bobPos.length, 1);
        assertEq(bobPos[0], tradeId);
    }

    function test_submitMatchedTrade_emitsTradeSubmitted() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectEmit(true, true, true, true, address(clearingHouse));
        emit TradeSubmitted(tradeId, ALICE_ACCOUNT, BOB_ACCOUNT, NOTIONAL, FIXED_RATE_BPS);

        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_emitsTradeNovated() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectEmit(true, false, false, false, address(clearingHouse));
        emit TradeNovated(tradeId, 0, 0);

        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_multipleTrades() public {
        _submitDefaultTrade(keccak256("TRADE_1"));

        ClearingHouse.MatchedTrade memory trade2 = _defaultTrade(keccak256("TRADE_2"));
        trade2.nonce = 2;
        trade2.notional = 500_000e6;
        bytes memory sigA2 = _signTrade(trade2, aliceWallet);
        bytes memory sigB2 = _signTrade(trade2, bobWallet);

        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade2, sigA2, sigB2);

        assertEq(clearingHouse.activePositionCount(), 2);
        assertEq(clearingHouse.getAccountPositions(ALICE_ACCOUNT).length, 2);
    }

    function test_submitMatchedTrade_adminCanAlsoSubmit() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Admin was granted OPERATOR_ROLE in the constructor
        vm.prank(admin);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);

        assertTrue(clearingHouse.tradeSubmitted(tradeId));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  submitMatchedTrade — Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_revertsIfCallerLacksOperatorRole() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, OPERATOR_ROLE
            )
        );
        vm.prank(nonOperator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnDuplicateTradeId() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.MatchedTrade memory trade2 = _defaultTrade(tradeId);
        trade2.nonce = 2;
        bytes memory sigA = _signTrade(trade2, aliceWallet);
        bytes memory sigB = _signTrade(trade2, bobWallet);

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.TradeAlreadySubmitted.selector, tradeId));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade2, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnExpiredDeadline() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.deadline = block.timestamp - 1;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.SignatureExpired.selector, trade.deadline));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnZeroNotional() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.notional = 0;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(ClearingHouse.InvalidNotional.selector);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnMaturityEqualToStart() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.maturityDate = trade.startDate;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(ClearingHouse.InvalidTradeTerms.selector);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnMaturityBeforeStart() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.maturityDate = trade.startDate - 1;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(ClearingHouse.InvalidTradeTerms.selector);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnZeroFixedRate() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.fixedRateBps = 0;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(ClearingHouse.InvalidTradeTerms.selector);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnZeroPaymentInterval() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.paymentInterval = 0;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(ClearingHouse.InvalidTradeTerms.selector);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsIfSameParty() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.partyB = trade.partyA;
        bytes memory sigA = _signTrade(trade, aliceWallet);

        vm.expectRevert(ClearingHouse.InvalidTradeTerms.selector);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigA);
    }

    function test_submitMatchedTrade_revertsOnReusedNonce() public {
        _submitDefaultTrade(keccak256("TRADE_1"));

        ClearingHouse.MatchedTrade memory trade2 = _defaultTrade(keccak256("TRADE_2"));
        // nonce 1 is already consumed
        bytes memory sigA = _signTrade(trade2, aliceWallet);
        bytes memory sigB = _signTrade(trade2, bobWallet);

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.NonceAlreadyUsed.selector, ALICE_ACCOUNT, 1));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade2, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnInvalidSignatureA() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, bobWallet); // wrong signer
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InvalidSignature.selector, ALICE_ACCOUNT));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsOnInvalidSignatureB() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, aliceWallet); // wrong signer

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InvalidSignature.selector, BOB_ACCOUNT));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsIfPartyANotWhitelisted() public {
        // Remove Alice from whitelist
        vm.prank(admin);
        whitelist.removeParticipant(alice);

        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        // Signatures will fail because alice is no longer the account owner
        // The whitelist check on owner will revert since getAccountOwner returns address(0)
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Signature verification fails first because getAccountOwner(ALICE_ACCOUNT) returns address(0)
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InvalidSignature.selector, ALICE_ACCOUNT));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsIfPartyAInsufficientMargin() public {
        // Drain Alice's margin to leave 0 free
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        // Use notional so high that IM exceeds available margin
        trade.notional = 100_000_000_000e6; // $100B — IM will exceed $500k
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InsufficientMarginForTrade.selector, ALICE_ACCOUNT));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settleVM — Batch
    // ═══════════════════════════════════════════════════════════════════

    function test_settleVM_success() public {
        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);

        ClearingHouse.VMSettlement[] memory settlements = new ClearingHouse.VMSettlement[](2);
        settlements[0] = ClearingHouse.VMSettlement(ALICE_ACCOUNT, int256(10_000e6));
        settlements[1] = ClearingHouse.VMSettlement(BOB_ACCOUNT, -int256(10_000e6));

        vm.prank(settler);
        clearingHouse.settleVM(settlements);

        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore + 10_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore - 10_000e6);
    }

    function test_settleVM_revertsIfCallerLacksSettlementRole() public {
        ClearingHouse.VMSettlement[] memory settlements = new ClearingHouse.VMSettlement[](1);
        settlements[0] = ClearingHouse.VMSettlement(ALICE_ACCOUNT, int256(10_000e6));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, SETTLEMENT_ROLE
            )
        );
        vm.prank(nonOperator);
        clearingHouse.settleVM(settlements);
    }

    function test_settleVM_emptyArrayNoOp() public {
        ClearingHouse.VMSettlement[] memory settlements = new ClearingHouse.VMSettlement[](0);
        vm.prank(settler);
        clearingHouse.settleVM(settlements);
        // No revert — just a no-op
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settlePositionVM — Single Position
    // ═══════════════════════════════════════════════════════════════════

    function test_settlePositionVM_success() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);

        int256 newNpv = 5_000e6; // Fixed payer (Alice) profits

        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit VariationMarginSettled(tradeId, newNpv, block.timestamp);

        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, newNpv);

        // Alice gains, Bob loses
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore + uint256(newNpv));
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore - uint256(newNpv));

        // lastNpv is updated
        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.lastNpv, newNpv);
    }

    function test_settlePositionVM_subsequentSettlement() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // First settlement: NPV goes to +5000
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 5_000e6);

        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);

        // Second settlement: NPV goes to +3000 → change is -2000
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 3_000e6);

        // Alice loses 2000, Bob gains 2000
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore - 2_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore + 2_000e6);
    }

    function test_settlePositionVM_zeroChangeNoOp() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);

        // NPV = 0 (no change from initial)
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 0);

        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore);
    }

    function test_settlePositionVM_negativeNpv() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);

        int256 newNpv = -5_000e6; // Fixed payer (Alice) loses

        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, newNpv);

        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore - 5_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore + 5_000e6);
    }

    function test_settlePositionVM_revertsIfPositionNotActive() public {
        bytes32 tradeId = keccak256("NONEXISTENT");

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.PositionNotActive.selector, tradeId));
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 1_000e6);
    }

    function test_settlePositionVM_revertsIfCallerLacksSettlementRole() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, SETTLEMENT_ROLE
            )
        );
        vm.prank(nonOperator);
        clearingHouse.settlePositionVM(tradeId, 1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  compressPositions
    // ═══════════════════════════════════════════════════════════════════

    function test_compressPositions_fullCompression() public {
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        // Trade 1: Alice pays fixed to Bob (notional = 1M)
        _submitDefaultTrade(tradeId1);
        // Trade 2: Bob pays fixed to Alice (notional = 1M) — reverse direction
        _submitReverseTrade(tradeId2, NOTIONAL);

        uint256 aliceLockedBefore = marginVault.getLockedIM(ALICE_ACCOUNT);

        vm.expectEmit(true, true, true, true, address(clearingHouse));
        // Alice is posA.partyA and posB.partyB → commonAccount = ALICE_ACCOUNT
        emit PositionCompressed(ALICE_ACCOUNT, tradeId1, tradeId2, NOTIONAL);

        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        // Both positions should be deactivated
        ClearingHouse.NovatedPosition memory pos1 = clearingHouse.getPosition(tradeId1);
        ClearingHouse.NovatedPosition memory pos2 = clearingHouse.getPosition(tradeId2);
        assertFalse(pos1.active);
        assertFalse(pos2.active);
        assertEq(pos1.notional, 0);
        assertEq(pos2.notional, 0);

        // IM released for the common account
        uint256 imRelease = riskEngine.calculateIM(NOTIONAL, ONE_YEAR);
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), aliceLockedBefore - imRelease);
    }

    function test_compressPositions_partialCompression() public {
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        // Trade 1: Alice pays fixed 1M
        _submitDefaultTrade(tradeId1);
        // Trade 2: Bob pays fixed 600K to Alice
        _submitReverseTrade(tradeId2, 600_000e6);

        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        ClearingHouse.NovatedPosition memory pos1 = clearingHouse.getPosition(tradeId1);
        ClearingHouse.NovatedPosition memory pos2 = clearingHouse.getPosition(tradeId2);

        // Trade 1 reduced by 600K → 400K remaining, still active
        assertEq(pos1.notional, 400_000e6);
        assertTrue(pos1.active);

        // Trade 2 fully compressed → 0, deactivated
        assertEq(pos2.notional, 0);
        assertFalse(pos2.active);
    }

    function test_compressPositions_revertsIfPositionNotActive() public {
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        _submitDefaultTrade(tradeId1);
        // tradeId2 doesn't exist (not active)

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.PositionNotActive.selector, tradeId1));
        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);
    }

    function test_compressPositions_revertsIfNotCompressible() public {
        // Trade 1: Alice → Bob
        bytes32 tradeId1 = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId1);

        // Create Charlie and Dave accounts with no overlap to Alice/Bob
        Vm.Wallet memory charlieWallet = vm.createWallet("charlie");
        address charlie = charlieWallet.addr;
        bytes32 CHARLIE_ACCOUNT = keccak256("CHARLIE_ACCOUNT");

        Vm.Wallet memory daveWallet = vm.createWallet("dave");
        address dave = daveWallet.addr;
        bytes32 DAVE_ACCOUNT = keccak256("DAVE_ACCOUNT");

        vm.startPrank(admin);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT);
        whitelist.addParticipant(dave, DAVE_ACCOUNT);
        vm.stopPrank();
        _fundMarginAccount(CHARLIE_ACCOUNT, 500_000e6);
        _fundMarginAccount(DAVE_ACCOUNT, 500_000e6);

        // Trade 2: Charlie → Dave (no parties in common with Trade 1)
        bytes32 tradeId2 = keccak256("TRADE_2");
        ClearingHouse.MatchedTrade memory trade2 = _defaultTrade(tradeId2);
        trade2.partyA = CHARLIE_ACCOUNT;
        trade2.partyB = DAVE_ACCOUNT;
        trade2.nonce = 1;
        bytes memory sigA2 = _signTrade(trade2, charlieWallet);
        bytes memory sigB2 = _signTrade(trade2, daveWallet);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade2, sigA2, sigB2);

        // Try to compress — no common account at all
        vm.expectRevert(ClearingHouse.PositionsNotCompressible.selector);
        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);
    }

    function test_compressPositions_revertsIfCallerLacksOperatorRole() public {
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");
        _submitDefaultTrade(tradeId1);
        _submitReverseTrade(tradeId2, NOTIONAL);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, OPERATOR_ROLE
            )
        );
        vm.prank(nonOperator);
        clearingHouse.compressPositions(tradeId1, tradeId2);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settleMaturedPosition
    // ═══════════════════════════════════════════════════════════════════

    function test_settleMaturedPosition_success() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        uint256 aliceLockedBefore = marginVault.getLockedIM(ALICE_ACCOUNT);
        uint256 bobLockedBefore = marginVault.getLockedIM(BOB_ACCOUNT);

        // Warp past maturity
        vm.warp(block.timestamp + ONE_YEAR + 1);

        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit PositionMatured(tradeId, block.timestamp);

        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);

        // Position should be deactivated
        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertFalse(pos.active);

        // Active position count decremented
        assertEq(clearingHouse.activePositionCount(), 0);

        // IM released for both parties
        uint256 im = _expectedIM();
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), aliceLockedBefore - im);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), bobLockedBefore - im);

        // Tokens burned
        assertEq(instrument.balanceOf(alice, pos.tokenIdA), 0);
        assertEq(instrument.balanceOf(bob, pos.tokenIdB), 0);
    }

    function test_settleMaturedPosition_revertsIfNotMatured() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // Don't warp — still before maturity
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.PositionNotMatured.selector, tradeId));
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);
    }

    function test_settleMaturedPosition_revertsIfPositionNotActive() public {
        bytes32 tradeId = keccak256("NONEXISTENT");

        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.PositionNotActive.selector, tradeId));
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);
    }

    function test_settleMaturedPosition_revertsIfCallerLacksOperatorRole() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);
        vm.warp(block.timestamp + ONE_YEAR + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, OPERATOR_ROLE
            )
        );
        vm.prank(nonOperator);
        clearingHouse.settleMaturedPosition(tradeId);
    }

    function test_settleMaturedPosition_revertsIfAlreadySettled() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);
        vm.warp(block.timestamp + ONE_YEAR + 1);

        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);

        // Try again — position is no longer active
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.PositionNotActive.selector, tradeId));
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  setProtocolFee
    // ═══════════════════════════════════════════════════════════════════

    function test_setProtocolFee_success() public {
        vm.expectEmit(false, false, false, true, address(clearingHouse));
        emit ProtocolFeeUpdated(0, 50);

        vm.prank(admin);
        clearingHouse.setProtocolFee(50);

        assertEq(clearingHouse.protocolFeeBps(), 50);
    }

    function test_setProtocolFee_updatesFromPreviousValue() public {
        vm.prank(admin);
        clearingHouse.setProtocolFee(50);

        vm.expectEmit(false, false, false, true, address(clearingHouse));
        emit ProtocolFeeUpdated(50, 100);

        vm.prank(admin);
        clearingHouse.setProtocolFee(100);

        assertEq(clearingHouse.protocolFeeBps(), 100);
    }

    function test_setProtocolFee_revertsIfCallerLacksAdminRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, clearingHouse.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonOperator);
        clearingHouse.setProtocolFee(50);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  setFeeRecipient
    // ═══════════════════════════════════════════════════════════════════

    function test_setFeeRecipient_success() public {
        address recipient = makeAddr("feeRecipient");
        vm.prank(admin);
        clearingHouse.setFeeRecipient(recipient);

        assertEq(clearingHouse.feeRecipient(), recipient);
    }

    function test_setFeeRecipient_revertsIfCallerLacksAdminRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOperator, clearingHouse.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonOperator);
        clearingHouse.setFeeRecipient(makeAddr("feeRecipient"));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  getTradeDigest (View)
    // ═══════════════════════════════════════════════════════════════════

    function test_getTradeDigest_returnsConsistentHash() public view {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);

        // Build the digest manually the same way _signTrade does
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
        bytes32 expectedDigest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);

        // Workaround: getTradeDigest expects calldata, so we call via this
        bytes32 actual = this.callGetTradeDigest(trade);
        assertEq(actual, expectedDigest);
    }

    /// @dev External wrapper to allow calling getTradeDigest with calldata encoding.
    function callGetTradeDigest(
        ClearingHouse.MatchedTrade calldata trade
    ) external view returns (bytes32) {
        return clearingHouse.getTradeDigest(trade);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  End-to-End Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    function test_fullLifecycle_submitSettleVMAndMature() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // Settle VM mid-life
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 10_000e6);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.lastNpv, 10_000e6);
        assertTrue(pos.active);

        // Warp to maturity
        vm.warp(block.timestamp + ONE_YEAR + 1);

        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);

        pos = clearingHouse.getPosition(tradeId);
        assertFalse(pos.active);
        assertEq(clearingHouse.activePositionCount(), 0);
    }

    function test_multiplePositions_activeCountTracking() public {
        _submitDefaultTrade(keccak256("TRADE_1"));
        _submitReverseTrade(keccak256("TRADE_2"), 500_000e6);

        assertEq(clearingHouse.activePositionCount(), 2);

        // Mature first trade
        vm.warp(block.timestamp + ONE_YEAR + 1);
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(keccak256("TRADE_1"));
        assertEq(clearingHouse.activePositionCount(), 1);

        vm.prank(operator);
        clearingHouse.settleMaturedPosition(keccak256("TRADE_2"));
        assertEq(clearingHouse.activePositionCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  submitMatchedTrade — Additional Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_revertsIfPartyBNotWhitelisted() public {
        // Remove Bob from whitelist (Party B)
        vm.prank(admin);
        whitelist.removeParticipant(bob);

        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Signature verification fails first because getAccountOwner(BOB_ACCOUNT) returns address(0)
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InvalidSignature.selector, BOB_ACCOUNT));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_revertsIfOnlyPartyBInsufficientMargin() public {
        // Give Alice extra margin so she passes, but Bob's 500k is insufficient
        _fundMarginAccount(ALICE_ACCOUNT, 10_000_000e6); // +$10M more for Alice

        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        // $300M notional → IM = 300M * 200 * 9900 / 1e8 = $594k > Bob's $500k, but < Alice's $10.5M
        trade.notional = 300_000_000e6;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Alice passes IM check, Bob fails
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InsufficientMarginForTrade.selector, BOB_ACCOUNT));
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_submitMatchedTrade_highFixedRate() public {
        // Test with maximum reasonable fixed rate (100% = 10000 bps)
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.fixedRateBps = 10000; // 100%
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Should succeed - high rate is valid
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);

        assertTrue(clearingHouse.tradeSubmitted(tradeId));
        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.fixedRateBps, 10000);
    }

    function test_submitMatchedTrade_singlePaymentSwap() public {
        // Payment interval larger than tenor = single payment at maturity
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.paymentInterval = ONE_YEAR * 2; // Larger than tenor
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Should succeed - single payment is valid
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);

        assertTrue(clearingHouse.tradeSubmitted(tradeId));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  View Functions — Additional Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_getAccountPositions_emptyAccount() public view {
        // Account with no positions should return empty array
        bytes32[] memory emptyPos = clearingHouse.getAccountPositions(keccak256("NO_POSITIONS_ACCOUNT"));
        assertEq(emptyPos.length, 0);
    }

    function test_getPosition_nonexistent() public view {
        // Position that doesn't exist should return empty/default values
        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(keccak256("NONEXISTENT"));
        assertEq(pos.tradeId, bytes32(0));
        assertFalse(pos.active);
        assertEq(pos.notional, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  setProtocolFee — Additional Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_setProtocolFee_zeroFee() public {
        vm.prank(admin);
        clearingHouse.setProtocolFee(0);

        assertEq(clearingHouse.protocolFeeBps(), 0);
    }

    function test_setProtocolFee_maxBps() public {
        // Maximum BPS (100%) should be allowed
        vm.prank(admin);
        clearingHouse.setProtocolFee(10000);

        assertEq(clearingHouse.protocolFeeBps(), 10000);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  setFeeRecipient — Additional Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_setFeeRecipient_zeroAddress() public {
        // Setting fee recipient to zero address should succeed (disables fees)
        vm.prank(admin);
        clearingHouse.setFeeRecipient(address(0));

        assertEq(clearingHouse.feeRecipient(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  compressPositions — Additional Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_compressPositions_alreadyCompressedPosition() public {
        // First compression should work
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        _submitDefaultTrade(tradeId1);
        _submitReverseTrade(tradeId2, NOTIONAL);

        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        // Both should be fully compressed now
        ClearingHouse.NovatedPosition memory pos1 = clearingHouse.getPosition(tradeId1);
        ClearingHouse.NovatedPosition memory pos2 = clearingHouse.getPosition(tradeId2);
        assertFalse(pos1.active);
        assertFalse(pos2.active);

        // Trying to compress again should revert (position not active)
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.PositionNotActive.selector, tradeId1));
        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settleVM — Additional Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_settleVM_multipleAccounts() public {
        // Create a third account
        Vm.Wallet memory charlieWallet = vm.createWallet("charlie");
        address charlie = charlieWallet.addr;
        bytes32 CHARLIE_ACCOUNT = keccak256("CHARLIE_ACCOUNT");

        vm.startPrank(admin);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT);
        vm.stopPrank();
        _fundMarginAccount(CHARLIE_ACCOUNT, 500_000e6);

        // Settle VM for multiple accounts in one batch
        ClearingHouse.VMSettlement[] memory settlements = new ClearingHouse.VMSettlement[](3);
        settlements[0] = ClearingHouse.VMSettlement(ALICE_ACCOUNT, int256(10_000e6));
        settlements[1] = ClearingHouse.VMSettlement(BOB_ACCOUNT, -int256(5_000e6));
        settlements[2] = ClearingHouse.VMSettlement(CHARLIE_ACCOUNT, -int256(5_000e6));

        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);
        uint256 charlieBefore = marginVault.getTotalCollateral(CHARLIE_ACCOUNT);

        vm.prank(settler);
        clearingHouse.settleVM(settlements);

        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore + 10_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore - 5_000e6);
        assertEq(marginVault.getTotalCollateral(CHARLIE_ACCOUNT), charlieBefore - 5_000e6);
    }

    function test_settleVM_systemNetZeroConservation() public {
        // Verify that a balanced settlement (sum of VM = 0) conserves total system collateral
        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT);
        uint256 systemTotal = aliceBefore + bobBefore;

        // Alice +100k, Bob -100k → system net zero
        ClearingHouse.VMSettlement[] memory settlements = new ClearingHouse.VMSettlement[](2);
        settlements[0] = ClearingHouse.VMSettlement(ALICE_ACCOUNT, int256(100_000e6));
        settlements[1] = ClearingHouse.VMSettlement(BOB_ACCOUNT, -int256(100_000e6));

        vm.prank(settler);
        clearingHouse.settleVM(settlements);

        // Individual balances shift
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore + 100_000e6);
        assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT), bobBefore - 100_000e6);

        // Total collateral in the system is conserved
        uint256 systemAfter = marginVault.getTotalCollateral(ALICE_ACCOUNT)
            + marginVault.getTotalCollateral(BOB_ACCOUNT);
        assertEq(systemAfter, systemTotal);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Whitelist Interaction Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_tradeAfterPartyRemovedFromWhitelist() public {
        // Submit a trade first
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // Now remove Alice from whitelist
        vm.prank(admin);
        whitelist.removeParticipant(alice);

        // Trade should still be active (whitelist check only at submission)
        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertTrue(pos.active);
        assertEq(pos.partyA, ALICE_ACCOUNT);

        // VM settlement should still work
        uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT);
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 1_000e6);
        assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT), aliceBefore + 1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Position Lifecycle — Stress Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_multipleTradesSameParty() public {
        // Alice (partyA) enters multiple trades with different counterparties
        Vm.Wallet memory charlieWallet = vm.createWallet("charlie");
        address charlie = charlieWallet.addr;
        bytes32 CHARLIE_ACCOUNT = keccak256("CHARLIE_ACCOUNT");

        vm.startPrank(admin);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT);
        vm.stopPrank();
        _fundMarginAccount(CHARLIE_ACCOUNT, 500_000e6);

        // Alice trades with Bob
        bytes32 tradeId1 = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId1);

        // Alice trades with Charlie (Alice is partyA)
        ClearingHouse.MatchedTrade memory trade2 = _defaultTrade(keccak256("TRADE_2"));
        trade2.partyA = ALICE_ACCOUNT;
        trade2.partyB = CHARLIE_ACCOUNT;
        trade2.nonce = 2;
        bytes memory sigA2 = _signTrade(trade2, aliceWallet);
        bytes memory sigB2 = _signTrade(trade2, charlieWallet);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade2, sigA2, sigB2);

        // Alice should have 2 positions
        bytes32[] memory alicePos = clearingHouse.getAccountPositions(ALICE_ACCOUNT);
        assertEq(alicePos.length, 2);

        // Both should be active
        assertTrue(clearingHouse.getPosition(tradeId1).active);
        assertTrue(clearingHouse.getPosition(keccak256("TRADE_2")).active);
        assertEq(clearingHouse.activePositionCount(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Edge Cases — IM and Margin
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_withSmallNotional() public {
        // Use a smaller notional that definitely fits within margin
        bytes32 tradeId = keccak256("TRADE_1");

        // Use 100k notional which is well within 500k margin
        uint256 smallNotional = 100_000e6;

        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.notional = smallNotional;
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Should succeed
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);

        assertTrue(clearingHouse.tradeSubmitted(tradeId));
        // Free margin should be positive
        assertGt(marginVault.getFreeMargin(ALICE_ACCOUNT), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Timestamp edge cases
    // ═══════════════════════════════════════════════════════════════════

    function test_settlePositionVM_atMaturityBoundary() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // Warp to exactly at maturity
        vm.warp(block.timestamp + ONE_YEAR);

        // Should still be settlable before maturity check in settleMaturedPosition
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 1_000e6);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.lastNpv, 1_000e6);
        assertTrue(pos.active);
    }

    function test_settleMaturedPosition_atExactMaturity() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // Warp to exactly at maturity
        vm.warp(block.timestamp + ONE_YEAR);

        // Should now be settlable
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertFalse(pos.active);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Role Management
    // ═══════════════════════════════════════════════════════════════════

    function test_revokeOperatorRole() public {
        // Revoke operator role
        vm.prank(admin);
        clearingHouse.revokeRole(OPERATOR_ROLE, operator);

        assertFalse(clearingHouse.hasRole(OPERATOR_ROLE, operator));

        // Submitting trade should now fail
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator, OPERATOR_ROLE
            )
        );
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);
    }

    function test_grantAndRevokeSettlementRole() public {
        // Grant settlement role to a new address
        address newSettler = makeAddr("newSettler");
        vm.prank(admin);
        clearingHouse.grantRole(SETTLEMENT_ROLE, newSettler);

        assertTrue(clearingHouse.hasRole(SETTLEMENT_ROLE, newSettler));

        // New settler should be able to settle VM
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        vm.prank(newSettler);
        clearingHouse.settlePositionVM(tradeId, 1_000e6);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
        assertEq(pos.lastNpv, 1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Deadline Boundary
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_succeedsAtDeadlineBoundary() public {
        // Contract checks `block.timestamp > trade.deadline`, so deadline == block.timestamp should pass
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.deadline = block.timestamp; // exactly at boundary
        bytes memory sigA = _signTrade(trade, aliceWallet);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, sigA, sigB);

        assertTrue(clearingHouse.tradeSubmitted(tradeId));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Compression — Alternate Branch (posA.partyB == posB.partyA)
    // ═══════════════════════════════════════════════════════════════════

    function test_compressPositions_viaPartyBEqualsPartyABranch() public {
        // This exercises the `else if (posA.partyB == posB.partyA)` branch in compressPositions.
        // Trade 1: Alice(A) → Bob(B) — Bob is partyB
        // Trade 2: Bob(A) → Charlie(B) — Bob is partyA
        // Common account = BOB_ACCOUNT via posA.partyB == posB.partyA

        Vm.Wallet memory charlieWallet = vm.createWallet("charlie");
        address charlie = charlieWallet.addr;
        bytes32 CHARLIE_ACCOUNT = keccak256("CHARLIE_ACCOUNT");

        vm.startPrank(admin);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT);
        vm.stopPrank();
        _fundMarginAccount(CHARLIE_ACCOUNT, 500_000e6);

        // Trade 1: Alice pays fixed to Bob
        bytes32 tradeId1 = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId1);

        // Trade 2: Bob pays fixed to Charlie
        bytes32 tradeId2 = keccak256("TRADE_2");
        ClearingHouse.MatchedTrade memory trade2 = _defaultTrade(tradeId2);
        trade2.partyA = BOB_ACCOUNT;
        trade2.partyB = CHARLIE_ACCOUNT;
        trade2.nonce = 2;
        bytes memory sigA2 = _signTrade(trade2, bobWallet);
        bytes memory sigB2 = _signTrade(trade2, charlieWallet);
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade2, sigA2, sigB2);

        uint256 bobLockedBefore = marginVault.getLockedIM(BOB_ACCOUNT);

        // Compress: posA.partyB(BOB) == posB.partyA(BOB) → commonAccount = BOB_ACCOUNT
        vm.expectEmit(true, true, true, true, address(clearingHouse));
        emit PositionCompressed(BOB_ACCOUNT, tradeId1, tradeId2, NOTIONAL);

        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        // Both fully compressed
        assertFalse(clearingHouse.getPosition(tradeId1).active);
        assertFalse(clearingHouse.getPosition(tradeId2).active);

        // IM released for Bob
        uint256 imRelease = riskEngine.calculateIM(NOTIONAL, ONE_YEAR);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), bobLockedBefore - imRelease);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Compression — activePositionCount Decremented on Full Compression
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verifies that compressPositions properly decrements activePositionCount
    ///         when positions are fully deactivated. This ensures the counter stays
    ///         in sync with the actual number of active positions.
    function test_compressPositions_fullCompression_decrementsActivePositionCount() public {
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        _submitDefaultTrade(tradeId1);
        _submitReverseTrade(tradeId2, NOTIONAL);

        assertEq(clearingHouse.activePositionCount(), 2);

        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        // Both positions are deactivated
        assertFalse(clearingHouse.getPosition(tradeId1).active);
        assertFalse(clearingHouse.getPosition(tradeId2).active);

        // activePositionCount is properly decremented to 0
        assertEq(clearingHouse.activePositionCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settleMaturedPosition — After Partial Compression (Reduced Notional)
    // ═══════════════════════════════════════════════════════════════════

    function test_settleMaturedPosition_afterPartialCompression() public {
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        // Trade 1: Alice pays fixed 1M
        _submitDefaultTrade(tradeId1);
        // Trade 2: Bob pays fixed 600K → compress leaves Trade 1 with 400K
        _submitReverseTrade(tradeId2, 600_000e6);

        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        ClearingHouse.NovatedPosition memory pos1 = clearingHouse.getPosition(tradeId1);
        assertEq(pos1.notional, 400_000e6);
        assertTrue(pos1.active);

        // Warp past maturity and settle the residual position
        vm.warp(block.timestamp + ONE_YEAR + 1);

        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId1);

        pos1 = clearingHouse.getPosition(tradeId1);
        assertFalse(pos1.active);

        // Tokens are burned using originalNotional (1M), so all tokens are burned
        // regardless of the reduced notional after partial compression
        assertEq(instrument.balanceOf(alice, pos1.tokenIdA), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settleMaturedPosition — Token Already Transferred (balanceOf Guard)
    // ═══════════════════════════════════════════════════════════════════

    function test_settleMaturedPosition_skipsTokenBurnIfZeroBalance() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);

        // Alice transfers her position tokens to a third party before maturity
        // ERC-1155 safeTransferFrom is available since Alice holds the tokens
        address thirdParty = makeAddr("thirdParty");
        vm.prank(alice);
        instrument.safeTransferFrom(alice, thirdParty, pos.tokenIdA, NOTIONAL, "");

        // Verify alice has 0 balance
        assertEq(instrument.balanceOf(alice, pos.tokenIdA), 0);
        assertEq(instrument.balanceOf(thirdParty, pos.tokenIdA), NOTIONAL);

        // Warp past maturity
        vm.warp(block.timestamp + ONE_YEAR + 1);

        // settleMaturedPosition should not revert — it checks balanceOf > 0 before burn
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId);

        // Position is settled
        assertFalse(clearingHouse.getPosition(tradeId).active);

        // IM still released for both parties even though token was transferred
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), 0);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), 0);

        // Third party still holds the transferred tokens (not burned by settlement)
        assertEq(instrument.balanceOf(thirdParty, pos.tokenIdA), NOTIONAL);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  settlePositionVM — Subsequent Event Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_settlePositionVM_subsequentSettlementEmitsCorrectDelta() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        // First settlement: NPV goes to +5000
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 5_000e6);

        // Second settlement: NPV goes to +3000 → delta = 3000 - 5000 = -2000
        vm.expectEmit(true, false, false, true, address(clearingHouse));
        emit VariationMarginSettled(tradeId, -2_000e6, block.timestamp);

        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId, 3_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Malformed Signature
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_revertsOnTruncatedSignature() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigB = _signTrade(trade, bobWallet);

        // Truncated signature (only 32 bytes instead of 65)
        bytes memory truncatedSig = new bytes(32);

        vm.expectRevert(); // ECDSA.recover reverts on malformed signatures
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, truncatedSig, sigB);
    }

    function test_submitMatchedTrade_revertsOnEmptySignature() public {
        bytes32 tradeId = keccak256("TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigB = _signTrade(trade, bobWallet);

        vm.expectRevert(); // ECDSA.recover reverts on empty bytes
        vm.prank(operator);
        clearingHouse.submitMatchedTrade(trade, "", sigB);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Protocol Fee — Unbounded BPS (Design Observation)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Documents that setProtocolFee has no upper bound validation.
    ///         A fee > 10000 bps (>100%) could be set, which would over-charge
    ///         if any fee logic uses this value. Consider adding a cap.
    function test_setProtocolFee_acceptsValueAbove100Percent() public {
        vm.prank(admin);
        clearingHouse.setProtocolFee(20000); // 200%

        assertEq(clearingHouse.protocolFeeBps(), 20000);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ERC-1155 Token Metadata Correctness
    // ═══════════════════════════════════════════════════════════════════

    function test_submitMatchedTrade_storesCorrectSwapTermsOnTokens() public {
        bytes32 tradeId = keccak256("TRADE_1");
        _submitDefaultTrade(tradeId);

        ClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);

        // Verify Party A's token terms
        IRSInstrument.SwapTerms memory termsA = instrument.getSwapTerms(pos.tokenIdA);
        assertEq(termsA.notional, NOTIONAL);
        assertEq(termsA.fixedRateBps, FIXED_RATE_BPS);
        assertEq(termsA.startDate, pos.startDate);
        assertEq(termsA.maturityDate, pos.maturityDate);
        assertEq(termsA.paymentInterval, NINETY_DAYS);
        assertTrue(termsA.direction == IRSInstrument.Direction.PAY_FIXED);
        assertEq(termsA.floatingRateIndex, SOFR_INDEX);
        assertEq(termsA.dayCountConvention, 0);

        // Verify Party B's token terms
        IRSInstrument.SwapTerms memory termsB = instrument.getSwapTerms(pos.tokenIdB);
        assertEq(termsB.notional, NOTIONAL);
        assertEq(termsB.fixedRateBps, FIXED_RATE_BPS);
        assertTrue(termsB.direction == IRSInstrument.Direction.RECEIVE_FIXED);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Full Lifecycle with Compression
    // ═══════════════════════════════════════════════════════════════════

    function test_fullLifecycle_submitCompressAndMatureResidue() public {
        // Submit two trades
        bytes32 tradeId1 = keccak256("TRADE_1");
        bytes32 tradeId2 = keccak256("TRADE_2");

        _submitDefaultTrade(tradeId1);
        _submitReverseTrade(tradeId2, 600_000e6); // Partially offsetting

        assertEq(clearingHouse.activePositionCount(), 2);

        // Partial compression → Trade 1 residual = 400K
        vm.prank(operator);
        clearingHouse.compressPositions(tradeId1, tradeId2);

        assertTrue(clearingHouse.getPosition(tradeId1).active);
        assertFalse(clearingHouse.getPosition(tradeId2).active);

        // Settle VM on the residual position
        vm.prank(settler);
        clearingHouse.settlePositionVM(tradeId1, 2_000e6);

        ClearingHouse.NovatedPosition memory pos1 = clearingHouse.getPosition(tradeId1);
        assertEq(pos1.lastNpv, 2_000e6);
        assertEq(pos1.notional, 400_000e6);

        // Warp and mature the residual
        vm.warp(block.timestamp + ONE_YEAR + 1);
        vm.prank(operator);
        clearingHouse.settleMaturedPosition(tradeId1);

        assertFalse(clearingHouse.getPosition(tradeId1).active);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  _processReport (CRE Report Processing via onReport)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Helper to encode metadata for onReport (workflowId, workflowName, workflowOwner)
    function _encodeMetadata(
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(workflowId, workflowName, workflowOwner);
    }

    /// @notice Helper to encode the report data for _processReport
    function _encodeReport(
        ClearingHouse.MatchedTrade memory trade,
        bytes memory sigA,
        bytes memory sigB
    ) internal pure returns (bytes memory) {
        return abi.encode(trade, sigA, sigB);
    }

    function test_processReport_viaOnReport_success() public {
        // Deploy a new ClearingHouse with a forwarder address (not address(0))
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        // Grant roles to the new clearing house
        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        // Call onReport from the forwarder - should succeed
        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        assertTrue(chWithForwarder.tradeSubmitted(tradeId));
        assertEq(chWithForwarder.activePositionCount(), 1);
    }

    /// @notice Sign a trade for a specific ClearingHouse address (for EIP-712 domain separator)
    function _signTradeWithCH(
        ClearingHouse.MatchedTrade memory trade,
        Vm.Wallet memory wallet,
        ClearingHouse ch
    ) internal returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                ch.MATCHED_TRADE_TYPEHASH(),
                trade.tradeId, trade.partyA, trade.partyB,
                trade.notional, trade.fixedRateBps,
                trade.startDate, trade.maturityDate, trade.paymentInterval,
                trade.dayCountConvention, trade.floatingRateIndex,
                trade.nonce, trade.deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ClearRate CCP"),
                keccak256("1"),
                block.chainid,
                address(ch)
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_processReport_revertsIfCallerIsNotForwarder() public {
        address forwarder = makeAddr("forwarder");
        address attacker = makeAddr("attacker");

        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        // Attacker tries to call onReport - should revert with InvalidSender
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("InvalidSender(address,address)", attacker, forwarder));
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_revertsIfInvalidSignature() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        
        // Sign with wrong wallet (bob signs for alice)
        bytes memory sigA = _signTradeWithCH(trade, bobWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InvalidSignature.selector, ALICE_ACCOUNT));
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_revertsIfTradeAlreadySubmitted() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        // First call succeeds
        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        // Second call with same tradeId should revert
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.TradeAlreadySubmitted.selector, tradeId));
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_revertsIfPartyNotWhitelisted() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        // Remove Alice from whitelist
        whitelist.removeParticipant(alice);
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InvalidSignature.selector, ALICE_ACCOUNT));
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_revertsIfInsufficientMargin() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        // Very high notional that exceeds margin
        trade.notional = 100_000_000_000e6;
        
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.InsufficientMarginForTrade.selector, ALICE_ACCOUNT));
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_revertsIfExpiredDeadline() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        trade.deadline = block.timestamp - 1;
        
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(ClearingHouse.SignatureExpired.selector, trade.deadline));
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_withExpectedWorkflowId() public {
        address forwarder = makeAddr("forwarder");
        bytes32 expectedWorkflowId = bytes32("EXPECTED_WF_ID");
        
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        // Set expected workflow ID (test contract is owner since it deployed CH)
        chWithForwarder.setExpectedWorkflowId(expectedWorkflowId);

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        // Correct workflow ID - should succeed
        bytes memory metadata = _encodeMetadata(expectedWorkflowId, bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        assertTrue(chWithForwarder.tradeSubmitted(tradeId));
    }

    function test_processReport_revertsIfWrongWorkflowId() public {
        address forwarder = makeAddr("forwarder");
        bytes32 expectedWorkflowId = bytes32("EXPECTED_WF_ID");
        
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        // Set expected workflow ID (test contract is owner since it deployed CH)
        chWithForwarder.setExpectedWorkflowId(expectedWorkflowId);

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        // Wrong workflow ID - should revert
        bytes memory metadata = _encodeMetadata(bytes32("WRONG_WF_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        vm.expectRevert(); // InvalidWorkflowId error
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_withExpectedAuthor() public {
        address forwarder = makeAddr("forwarder");
        address expectedAuthor = makeAddr("expectedAuthor");
        
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        // Set expected author (test contract is owner since it deployed CH)
        chWithForwarder.setExpectedAuthor(expectedAuthor);

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        // Correct author - should succeed
        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), expectedAuthor);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        assertTrue(chWithForwarder.tradeSubmitted(tradeId));
    }

    function test_processReport_revertsIfWrongAuthor() public {
        address forwarder = makeAddr("forwarder");
        address expectedAuthor = makeAddr("expectedAuthor");
        address wrongAuthor = makeAddr("wrongAuthor");
        
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        // Set expected author (test contract is owner since it deployed CH)
        chWithForwarder.setExpectedAuthor(expectedAuthor);

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        // Wrong author - should revert
        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), wrongAuthor);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        vm.expectRevert(); // InvalidAuthor error
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_createsPositionWithCorrectTerms() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        // Verify position was created correctly
        ClearingHouse.NovatedPosition memory pos = chWithForwarder.getPosition(tradeId);
        assertEq(pos.tradeId, tradeId);
        assertEq(pos.partyA, ALICE_ACCOUNT);
        assertEq(pos.partyB, BOB_ACCOUNT);
        assertEq(pos.notional, NOTIONAL);
        assertEq(pos.fixedRateBps, FIXED_RATE_BPS);
        assertTrue(pos.active);
        assertEq(pos.lastNpv, 0);
    }

    function test_processReport_locksInitialMarginForBothParties() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        uint256 aliceFreeBefore = marginVault.getFreeMargin(ALICE_ACCOUNT);
        uint256 bobFreeBefore = marginVault.getFreeMargin(BOB_ACCOUNT);

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        uint256 im = _expectedIM();
        assertEq(marginVault.getFreeMargin(ALICE_ACCOUNT), aliceFreeBefore - im);
        assertEq(marginVault.getFreeMargin(BOB_ACCOUNT), bobFreeBefore - im);
        assertEq(marginVault.getLockedIM(ALICE_ACCOUNT), im);
        assertEq(marginVault.getLockedIM(BOB_ACCOUNT), im);
    }

    function test_processReport_mintsERC1155Tokens() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        ClearingHouse.NovatedPosition memory pos = chWithForwarder.getPosition(tradeId);
        assertEq(instrument.balanceOf(alice, pos.tokenIdA), NOTIONAL);
        assertEq(instrument.balanceOf(bob, pos.tokenIdB), NOTIONAL);
    }

    function test_processReport_emitsTradeSubmittedEvent() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.expectEmit(true, true, true, true, address(chWithForwarder));
        emit TradeSubmitted(tradeId, ALICE_ACCOUNT, BOB_ACCOUNT, NOTIONAL, FIXED_RATE_BPS);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_emitsTradeNovatedEvent() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.expectEmit(true, false, false, false, address(chWithForwarder));
        emit TradeNovated(tradeId, 0, 1);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);
    }

    function test_processReport_consumesNonces() public {
        address forwarder = makeAddr("forwarder");
        ClearingHouse chWithForwarder = new ClearingHouse(
            admin,
            forwarder,
            address(instrument),
            address(marginVault),
            address(riskEngine),
            address(whitelist),
            address(oracle)
        );

        vm.startPrank(admin);
        instrument.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        marginVault.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(chWithForwarder));
        vm.stopPrank();

        bytes32 tradeId = keccak256("CRE_TRADE_1");
        ClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
        bytes memory sigA = _signTradeWithCH(trade, aliceWallet, chWithForwarder);
        bytes memory sigB = _signTradeWithCH(trade, bobWallet, chWithForwarder);

        bytes memory metadata = _encodeMetadata(bytes32("WORKFLOW_ID"), bytes10("workflow"), forwarder);
        bytes memory report = _encodeReport(trade, sigA, sigB);

        vm.prank(forwarder);
        chWithForwarder.onReport(metadata, report);

        assertTrue(chWithForwarder.usedNonces(ALICE_ACCOUNT, 1));
        assertTrue(chWithForwarder.usedNonces(BOB_ACCOUNT, 1));
    }

}
