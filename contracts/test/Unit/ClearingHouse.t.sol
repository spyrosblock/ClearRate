// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.24;

// import {Test} from "forge-std/Test.sol";
// import {Vm} from "forge-std/Vm.sol";
// import {IClearingHouse} from "../../src/interfaces/IClearingHouse.sol";
// import {ClearingHouse} from "../../src/core/ClearingHouse.sol";
// import {IRSInstrument} from "../../src/core/IRSInstrument.sol";
// import {MarginVault} from "../../src/margin/MarginVault.sol";
// import {RiskEngine} from "../../src/margin/RiskEngine.sol";
// import {Whitelist} from "../../src/access/Whitelist.sol";
// import {ERC20Mock} from "../mocks/ERC20Mock.sol";
// import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// /// @title ClearingHouseTest
// /// @notice Unit tests for the ClearingHouse contract - happy path tests.
// contract ClearingHouseTest is Test {
//     // ─── Contracts ──────────────────────────────────────────────────────
//     ClearingHouse internal clearingHouse;
//     IRSInstrument internal instrument;
//     MarginVault internal marginVault;
//     RiskEngine internal riskEngine;
//     Whitelist internal whitelist;
//     ERC20Mock internal usdc;

//     // ─── Actors ─────────────────────────────────────────────────────────
//     address internal admin = makeAddr("admin");
//     address internal operator = makeAddr("operator");
//     address internal settler = makeAddr("settler");
//     address internal forwarder = makeAddr("forwarder");

//     Vm.Wallet internal aliceWallet;
//     Vm.Wallet internal bobWallet;
//     address internal alice;
//     address internal bob;

//     // ─── Account Ids ────────────────────────────────────────────────────
//     bytes32 internal constant ALICE_ACCOUNT = keccak256("ALICE_ACCOUNT");
//     bytes32 internal constant BOB_ACCOUNT = keccak256("BOB_ACCOUNT");

//     // ─── Trade Constants ────────────────────────────────────────────────
//     uint256 internal constant NOTIONAL = 1_000_000e6;
//     uint256 internal constant FIXED_RATE_BPS = 500;
//     uint256 internal constant ONE_YEAR = 365 days;
//     uint256 internal constant NINETY_DAYS = 90 days;
//     bytes32 internal constant SOFR_INDEX = keccak256("SOFR");

//     // ─── Role Constants ─────────────────────────────────────────────────
//     bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
//     bytes32 internal constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
//     bytes32 internal constant CLEARING_HOUSE_ROLE = keccak256("CLEARING_HOUSE_ROLE");

//     // ─── Events ─────────────────────────────────────────────────────────
//     event TradeSubmitted(
//         bytes32 indexed tradeId, bytes32 indexed partyA, bytes32 indexed partyB,
//         uint256 notional, uint256 fixedRateBps
//     );
//     event VariationMarginSettled(bytes32 indexed tradeId, int256 npvChange, uint256 timestamp);
//     event PositionCompressed(
//         bytes32 indexed accountId, bytes32 indexed tradeIdA, bytes32 indexed tradeIdB,
//         uint256 notionalReduced
//     );
//     event PositionMatured(bytes32 indexed tradeId, uint256 timestamp);
//     event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

//     // ─── Setup ──────────────────────────────────────────────────────────

//     function setUp() public {
//         aliceWallet = vm.createWallet("alice");
//         bobWallet = vm.createWallet("bob");
//         alice = aliceWallet.addr;
//         bob = bobWallet.addr;

//         usdc = new ERC20Mock("USD Coin", "USDC", 6);

//         whitelist = new Whitelist(admin, forwarder);
//         vm.startPrank(admin);
//         // addParticipant(address participant, bytes32 accountId, uint256 customMaxNotional, uint64 kycExpiry)
//         whitelist.addParticipant(alice, ALICE_ACCOUNT, 1000000e6, uint64(block.timestamp) + 365 days);
//         whitelist.addParticipant(bob, BOB_ACCOUNT, 1000000e6, uint64(block.timestamp) + 365 days);
//         vm.stopPrank();

//         address[] memory tokens = new address[](1);
//         tokens[0] = address(usdc);
//         marginVault = new MarginVault(admin, address(whitelist), tokens);

//         riskEngine = new RiskEngine(admin, address(marginVault), 9900, 7500);

//         instrument = new IRSInstrument(admin, "https://metadata.clearrate.io/{id}.json");

//         clearingHouse = new ClearingHouse(
//             admin,
//             forwarder,
//             address(instrument),
//             address(marginVault),
//             address(riskEngine),
//             address(whitelist)
//         );

//         vm.startPrank(admin);
//         instrument.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
//         marginVault.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
//         riskEngine.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));
//         whitelist.grantRole(CLEARING_HOUSE_ROLE, address(clearingHouse));

//         riskEngine.setRiskWeight(ONE_YEAR, 200);

//         // Grant roles - forwarder needs OPERATOR_ROLE to call onReport
//         clearingHouse.grantRole(OPERATOR_ROLE, forwarder);
//         clearingHouse.grantRole(OPERATOR_ROLE, operator);
//         clearingHouse.grantRole(SETTLEMENT_ROLE, settler);
//         vm.stopPrank();

//         _fundMarginAccount(ALICE_ACCOUNT, 500_000e6);
//         _fundMarginAccount(BOB_ACCOUNT, 500_000e6);
//     }

//     // ─── Helpers ────────────────────────────────────────────────────────

//     function _fundMarginAccount(bytes32 accountId, uint256 amount) internal {
//         address accountOwner = whitelist.getAccountOwner(accountId);
//         require(accountOwner != address(0), "Account not whitelisted");
        
//         vm.startPrank(accountOwner);
//         usdc.mint(accountOwner, amount);
//         usdc.approve(address(marginVault), amount);
//         marginVault.depositMargin(accountId, address(usdc), amount);
//         vm.stopPrank();
//     }

//     function _defaultTrade(bytes32 tradeId) internal view returns (IClearingHouse.MatchedTrade memory) {
//         return IClearingHouse.MatchedTrade({
//             tradeId: tradeId,
//             partyA: ALICE_ACCOUNT,
//             partyB: BOB_ACCOUNT,
//             notional: NOTIONAL,
//             fixedRateBps: FIXED_RATE_BPS,
//             startDate: block.timestamp,
//             maturityDate: block.timestamp + ONE_YEAR,
//             paymentInterval: NINETY_DAYS,
//             dayCountConvention: 0,
//             floatingRateIndex: SOFR_INDEX,
//             nonce: 1,
//             deadline: block.timestamp + 1 hours,
//             collateralToken: address(usdc)
//         });
//     }

//     function _signTrade(
//         IClearingHouse.MatchedTrade memory trade,
//         Vm.Wallet memory wallet
//     ) internal returns (bytes memory) {
//         bytes32 structHash = keccak256(
//             abi.encode(
//                 clearingHouse.MATCHED_TRADE_TYPEHASH(),
//                 trade.tradeId, trade.partyA, trade.partyB,
//                 trade.notional, trade.fixedRateBps,
//                 trade.startDate, trade.maturityDate, trade.paymentInterval,
//                 trade.dayCountConvention, trade.floatingRateIndex,
//                 trade.nonce, trade.deadline, trade.collateralToken
//             )
//         );
//         bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
//         (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
//         return abi.encodePacked(r, s, v);
//     }

//     function _domainSeparator() internal view returns (bytes32) {
//         return keccak256(
//             abi.encode(
//                 keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
//                 keccak256("ClearRate CCP"),
//                 keccak256("1"),
//                 block.chainid,
//                 address(clearingHouse)
//             )
//         );
//     }

//     function _submitDefaultTrade(bytes32 tradeId) internal {
//         IClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
//         bytes memory sigA = _signTrade(trade, aliceWallet);
//         bytes memory sigB = _signTrade(trade, bobWallet);
        
//         // Submit via onReport (mocks Chainlink CRE workflow)
//         bytes memory report = abi.encode(uint8(0), trade, sigA, sigB);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report);
//     }

//     function _expectedIM() internal pure returns (uint256) {
//         return (NOTIONAL * 200 * 9900) / (10_000 * 10_000);
//     }

//     function _submitReverseTrade(bytes32 tradeId, uint256 notional) internal {
//         IClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
//         trade.partyA = BOB_ACCOUNT;
//         trade.partyB = ALICE_ACCOUNT;
//         trade.nonce = 2;
//         trade.notional = notional;
//         bytes memory sigA = _signTrade(trade, bobWallet);
//         bytes memory sigB = _signTrade(trade, aliceWallet);
        
//         // Submit via onReport
//         bytes memory report = abi.encode(uint8(0), trade, sigA, sigB);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report);
//     }

//     // ═══════════════════════════════════════════════════════════════════════════════════════════════
//     //  submitMatchedTrade — Happy Path (via onReport)
//     // ═══════════════════════════════════════════════════════════════════════════════════════════════

//     function test_submitMatchedTrade_success() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         assertTrue(clearingHouse.tradeSubmitted(tradeId));
//         assertEq(clearingHouse.activePositionCount(), 1);
//     }

//     function test_submitMatchedTrade_createsNovatedPosition() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
//         assertEq(pos.tradeId, tradeId);
//         assertEq(pos.partyA, ALICE_ACCOUNT);
//         assertEq(pos.partyB, BOB_ACCOUNT);
//         assertEq(pos.notional, NOTIONAL);
//         assertEq(pos.fixedRateBps, FIXED_RATE_BPS);
//         assertTrue(pos.active);
//         assertEq(pos.lastNpv, 0);
//     }

//     function test_submitMatchedTrade_storesCorrectDates() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
//         assertEq(pos.startDate, block.timestamp);
//         assertEq(pos.maturityDate, block.timestamp + ONE_YEAR);
//     }

//     function test_submitMatchedTrade_mintsERC1155Tokens() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
//         assertEq(instrument.balanceOf(alice, pos.tokenIdA), NOTIONAL);
//         assertEq(instrument.balanceOf(bob, pos.tokenIdB), NOTIONAL);
//     }

//     function test_submitMatchedTrade_locksInitialMargin() public {
//         uint256 aliceFreeBefore = marginVault.getFreeMarginByToken(ALICE_ACCOUNT, address(usdc));
//         uint256 bobFreeBefore = marginVault.getFreeMarginByToken(BOB_ACCOUNT, address(usdc));

//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         uint256 im = _expectedIM();
//         assertEq(marginVault.getFreeMarginByToken(ALICE_ACCOUNT, address(usdc)), aliceFreeBefore - im);
//         assertEq(marginVault.getFreeMarginByToken(BOB_ACCOUNT, address(usdc)), bobFreeBefore - im);
//         assertEq(marginVault.getLockedIMByToken(ALICE_ACCOUNT, address(usdc)), im);
//         assertEq(marginVault.getLockedIMByToken(BOB_ACCOUNT, address(usdc)), im);
//     }

//     function test_submitMatchedTrade_tracksAccountPositions() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         bytes32[] memory alicePos = clearingHouse.getAccountPositions(ALICE_ACCOUNT, address(usdc));
//         bytes32[] memory bobPos = clearingHouse.getAccountPositions(BOB_ACCOUNT, address(usdc));
//         assertEq(alicePos.length, 1);
//         assertEq(alicePos[0], tradeId);
//         assertEq(bobPos.length, 1);
//         assertEq(bobPos[0], tradeId);
//     }

//     function test_submitMatchedTrade_multipleTrades() public {
//         // First trade with smaller notional to leave room for second trade
//         IClearingHouse.MatchedTrade memory trade1 = _defaultTrade(keccak256("TRADE_1"));
//         trade1.notional = 500_000e6; // Half of max notional
//         bytes memory sigA1 = _signTrade(trade1, aliceWallet);
//         bytes memory sigB1 = _signTrade(trade1, bobWallet);

//         bytes memory report1 = abi.encode(uint8(0), trade1, sigA1, sigB1);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report1);

//         // Second trade with remaining notional capacity
//         IClearingHouse.MatchedTrade memory trade2 = _defaultTrade(keccak256("TRADE_2"));
//         trade2.nonce = 2;
//         trade2.notional = 400_000e6; // Within remaining capacity
//         bytes memory sigA2 = _signTrade(trade2, aliceWallet);
//         bytes memory sigB2 = _signTrade(trade2, bobWallet);

//         bytes memory report2 = abi.encode(uint8(0), trade2, sigA2, sigB2);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report2);

//         assertEq(clearingHouse.activePositionCount(), 2);
//         assertEq(clearingHouse.getAccountPositions(ALICE_ACCOUNT, address(usdc)).length, 2);
//     }

//     function test_submitMatchedTrade_emitsTradeSubmitted() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         IClearingHouse.MatchedTrade memory trade = _defaultTrade(tradeId);
//         bytes memory sigA = _signTrade(trade, aliceWallet);
//         bytes memory sigB = _signTrade(trade, bobWallet);

//         vm.expectEmit(true, true, true, true, address(clearingHouse));
//         emit TradeSubmitted(tradeId, ALICE_ACCOUNT, BOB_ACCOUNT, NOTIONAL, FIXED_RATE_BPS);

//         bytes memory report = abi.encode(uint8(0), trade, sigA, sigB);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report);
//     }

//     // ═══════════════════════════════════════════════════════════════════════════════════════════════
//     //  settlePositionVM — Happy Path (via onReport)
//     // ═══════════════════════════════════════════════════════════════════════════════════════════════

//     function test_settlePositionVM_success() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
//         uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc));

//         int256 npvChange = 5_000e6;

//         vm.expectEmit(true, false, false, true, address(clearingHouse));
//         emit VariationMarginSettled(tradeId, npvChange, block.timestamp);

//         // Submit VM settlement via onReport
//         IClearingHouse.VMSettlement[] memory settlements = new IClearingHouse.VMSettlement[](1);
//         settlements[0] = IClearingHouse.VMSettlement({tradeId: tradeId, npvChange: npvChange});
        
//         bytes memory report = abi.encode(uint8(1), settlements);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report);

//         assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc)), aliceBefore + uint256(npvChange));
//         assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc)), bobBefore - uint256(npvChange));

//         IClearingHouse.NovatedPosition memory pos = clearingHouse.getPosition(tradeId);
//         assertEq(pos.lastNpv, npvChange);
//     }

//     function test_settlePositionVM_negativeNpv() public {
//         bytes32 tradeId = keccak256("TRADE_1");
//         _submitDefaultTrade(tradeId);

//         uint256 aliceBefore = marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc));
//         uint256 bobBefore = marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc));

//         int256 npvChange = -5_000e6;

//         // Submit VM settlement via onReport
//         IClearingHouse.VMSettlement[] memory settlements = new IClearingHouse.VMSettlement[](1);
//         settlements[0] = IClearingHouse.VMSettlement({tradeId: tradeId, npvChange: npvChange});
        
//         bytes memory report = abi.encode(uint8(1), settlements);
//         vm.prank(forwarder);
//         clearingHouse.onReport("", report);

//         assertEq(marginVault.getTotalCollateral(ALICE_ACCOUNT, address(usdc)), aliceBefore - 5_000e6);
//         assertEq(marginVault.getTotalCollateral(BOB_ACCOUNT, address(usdc)), bobBefore + 5_000e6);
//     }

//     // ═══════════════════════════════════════════════════════════════════════════════════════════════
//     //  Admin Functions
//     // ═══════════════════════════════════════════════════════════════════════════════════════════════

//     function test_setProtocolFee_success() public {
//         vm.expectEmit(false, false, false, true, address(clearingHouse));
//         emit ProtocolFeeUpdated(0, 50);

//         vm.prank(admin);
//         clearingHouse.setProtocolFee(50);

//         assertEq(clearingHouse.protocolFeeBps(), 50);
//     }

//     function test_setFeeRecipient_success() public {
//         address recipient = makeAddr("feeRecipient");
//         vm.prank(admin);
//         clearingHouse.setFeeRecipient(recipient);

//         assertEq(clearingHouse.feeRecipient(), recipient);
//     }
// }
