// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Whitelist} from "../../src/access/Whitelist.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title WhitelistTest
/// @notice Comprehensive unit tests for the Whitelist KYC registry contract.
contract WhitelistTest is Test {
    // ─── Constants & Fixtures ───────────────────────────────────────────

    Whitelist internal whitelist;

    address internal admin = makeAddr("admin");
    address internal nonAdmin = makeAddr("nonAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    bytes32 internal constant ALICE_ACCOUNT = keccak256("ALICE_ACCOUNT");
    bytes32 internal constant BOB_ACCOUNT = keccak256("BOB_ACCOUNT");
    bytes32 internal constant CHARLIE_ACCOUNT = keccak256("CHARLIE_ACCOUNT");

    bytes32 internal constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    // ─── Events (re-declared for expectEmit) ────────────────────────────
    event ParticipantAdded(address indexed participant, bytes32 indexed accountId);
    event ParticipantRemoved(address indexed participant, bytes32 indexed accountId);

    // ─── Setup ──────────────────────────────────────────────────────────

    function setUp() public {
        whitelist = new Whitelist(admin);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    function test_constructor_grantsDefaultAdminRole() public view {
        assertTrue(whitelist.hasRole(whitelist.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_grantsWhitelistAdminRole() public view {
        assertTrue(whitelist.hasRole(WHITELIST_ADMIN_ROLE, admin));
    }

    function test_constructor_initialParticipantCountIsZero() public view {
        assertEq(whitelist.participantCount(), 0);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(Whitelist.InvalidAddress.selector);
        new Whitelist(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  addParticipant — Happy Path
    // ═══════════════════════════════════════════════════════════════════

    function test_addParticipant_setsWhitelistedTrue() public {
        vm.prank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        assertTrue(whitelist.isWhitelisted(alice));
    }

    function test_addParticipant_storesAccountId() public {
        vm.prank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        assertEq(whitelist.getAccountId(alice), ALICE_ACCOUNT);
    }

    function test_addParticipant_storesAccountOwner() public {
        vm.prank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        assertEq(whitelist.getAccountOwner(ALICE_ACCOUNT), alice);
    }

    function test_addParticipant_incrementsParticipantCount() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        assertEq(whitelist.participantCount(), 1);

        whitelist.addParticipant(bob, BOB_ACCOUNT);
        assertEq(whitelist.participantCount(), 2);
        vm.stopPrank();
    }

    function test_addParticipant_emitsParticipantAdded() public {
        vm.expectEmit(true, true, false, false, address(whitelist));
        emit ParticipantAdded(alice, ALICE_ACCOUNT);

        vm.prank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
    }

    function test_addParticipant_multipleParticipants() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.addParticipant(bob, BOB_ACCOUNT);
        whitelist.addParticipant(charlie, CHARLIE_ACCOUNT);
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(alice));
        assertTrue(whitelist.isWhitelisted(bob));
        assertTrue(whitelist.isWhitelisted(charlie));
        assertEq(whitelist.participantCount(), 3);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  addParticipant — Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_addParticipant_revertsWhenCallerLacksRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(nonAdmin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
    }

    function test_addParticipant_revertsOnZeroAddress() public {
        vm.expectRevert(Whitelist.InvalidAddress.selector);
        vm.prank(admin);
        whitelist.addParticipant(address(0), ALICE_ACCOUNT);
    }

    function test_addParticipant_revertsOnZeroAccountId() public {
        vm.expectRevert(Whitelist.InvalidAccountId.selector);
        vm.prank(admin);
        whitelist.addParticipant(alice, bytes32(0));
    }

    function test_addParticipant_revertsIfAlreadyWhitelisted() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        vm.expectRevert(abi.encodeWithSelector(Whitelist.AlreadyWhitelisted.selector, alice));
        whitelist.addParticipant(alice, keccak256("DIFFERENT_ACCOUNT"));
        vm.stopPrank();
    }

    function test_addParticipant_revertsIfAccountIdTaken() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        vm.expectRevert(abi.encodeWithSelector(Whitelist.AccountIdTaken.selector, ALICE_ACCOUNT));
        whitelist.addParticipant(bob, ALICE_ACCOUNT);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  removeParticipant — Happy Path
    // ═══════════════════════════════════════════════════════════════════

    function test_removeParticipant_setsWhitelistedFalse() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.removeParticipant(alice);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(alice));
    }

    function test_removeParticipant_clearsAccountId() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.removeParticipant(alice);
        vm.stopPrank();

        assertEq(whitelist.getAccountId(alice), bytes32(0));
    }

    function test_removeParticipant_clearsAccountOwner() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.removeParticipant(alice);
        vm.stopPrank();

        assertEq(whitelist.getAccountOwner(ALICE_ACCOUNT), address(0));
    }

    function test_removeParticipant_decrementsParticipantCount() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.addParticipant(bob, BOB_ACCOUNT);
        assertEq(whitelist.participantCount(), 2);

        whitelist.removeParticipant(alice);
        assertEq(whitelist.participantCount(), 1);

        whitelist.removeParticipant(bob);
        assertEq(whitelist.participantCount(), 0);
        vm.stopPrank();
    }

    function test_removeParticipant_emitsParticipantRemoved() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        vm.expectEmit(true, true, false, false, address(whitelist));
        emit ParticipantRemoved(alice, ALICE_ACCOUNT);

        whitelist.removeParticipant(alice);
        vm.stopPrank();
    }

    function test_removeParticipant_doesNotAffectOtherParticipants() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.addParticipant(bob, BOB_ACCOUNT);

        whitelist.removeParticipant(alice);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(alice));
        assertTrue(whitelist.isWhitelisted(bob));
        assertEq(whitelist.getAccountId(bob), BOB_ACCOUNT);
        assertEq(whitelist.getAccountOwner(BOB_ACCOUNT), bob);
    }

    function test_removeParticipant_freesAccountIdForReuse() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.removeParticipant(alice);

        // The same accountId can now be assigned to a different address
        whitelist.addParticipant(bob, ALICE_ACCOUNT);
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(bob));
        assertEq(whitelist.getAccountOwner(ALICE_ACCOUNT), bob);
    }

    function test_removeParticipant_allowsReAddWithNewAccountId() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.removeParticipant(alice);

        // Alice can be re-added with a different accountId
        bytes32 newAccountId = keccak256("NEW_ALICE_ACCOUNT");
        whitelist.addParticipant(alice, newAccountId);
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(alice));
        assertEq(whitelist.getAccountId(alice), newAccountId);
        assertEq(whitelist.getAccountOwner(newAccountId), alice);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  removeParticipant — Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_removeParticipant_revertsWhenCallerLacksRole() public {
        vm.prank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(nonAdmin);
        whitelist.removeParticipant(alice);
    }

    function test_removeParticipant_revertsIfNotWhitelisted() public {
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        vm.prank(admin);
        whitelist.removeParticipant(alice);
    }

    function test_removeParticipant_revertsIfAlreadyRemoved() public {
        vm.startPrank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
        whitelist.removeParticipant(alice);

        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, alice));
        whitelist.removeParticipant(alice);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  View Functions — Default / Edge Behavior
    // ═══════════════════════════════════════════════════════════════════

    function test_isWhitelisted_returnsFalseForUnknownAddress() public {
        assertFalse(whitelist.isWhitelisted(makeAddr("unknown")));
    }

    function test_getAccountId_returnsZeroForUnknownAddress() public {
        assertEq(whitelist.getAccountId(makeAddr("unknown")), bytes32(0));
    }

    function test_getAccountOwner_returnsZeroForUnknownAccountId() public view {
        assertEq(whitelist.getAccountOwner(keccak256("UNKNOWN")), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Access Control — Role Management
    // ═══════════════════════════════════════════════════════════════════

    function test_adminCanGrantWhitelistRole() public {
        vm.prank(admin);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, nonAdmin);

        assertTrue(whitelist.hasRole(WHITELIST_ADMIN_ROLE, nonAdmin));
    }

    function test_grantedRoleCanAddParticipant() public {
        vm.prank(admin);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, nonAdmin);

        vm.prank(nonAdmin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        assertTrue(whitelist.isWhitelisted(alice));
    }

    function test_grantedRoleCanRemoveParticipant() public {
        vm.prank(admin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);

        vm.prank(admin);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, nonAdmin);

        vm.prank(nonAdmin);
        whitelist.removeParticipant(alice);

        assertFalse(whitelist.isWhitelisted(alice));
    }

    function test_revokedRoleCannotAddParticipant() public {
        vm.startPrank(admin);
        whitelist.grantRole(WHITELIST_ADMIN_ROLE, nonAdmin);
        whitelist.revokeRole(WHITELIST_ADMIN_ROLE, nonAdmin);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonAdmin,
                WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(nonAdmin);
        whitelist.addParticipant(alice, ALICE_ACCOUNT);
    }

    function test_adminCanRenounceOwnRole() public {
        vm.prank(admin);
        whitelist.renounceRole(WHITELIST_ADMIN_ROLE, admin);

        assertFalse(whitelist.hasRole(WHITELIST_ADMIN_ROLE, admin));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  WHITELIST_ADMIN_ROLE constant
    // ═══════════════════════════════════════════════════════════════════

    function test_whitelistAdminRoleConstant() public view {
        assertEq(whitelist.WHITELIST_ADMIN_ROLE(), keccak256("WHITELIST_ADMIN_ROLE"));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_addParticipant(address participant, bytes32 accountId) public {
        vm.assume(participant != address(0));
        vm.assume(accountId != bytes32(0));

        vm.prank(admin);
        whitelist.addParticipant(participant, accountId);

        assertTrue(whitelist.isWhitelisted(participant));
        assertEq(whitelist.getAccountId(participant), accountId);
        assertEq(whitelist.getAccountOwner(accountId), participant);
        assertEq(whitelist.participantCount(), 1);
    }

    function testFuzz_addAndRemoveParticipant(address participant, bytes32 accountId) public {
        vm.assume(participant != address(0));
        vm.assume(accountId != bytes32(0));

        vm.startPrank(admin);
        whitelist.addParticipant(participant, accountId);
        whitelist.removeParticipant(participant);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(participant));
        assertEq(whitelist.getAccountId(participant), bytes32(0));
        assertEq(whitelist.getAccountOwner(accountId), address(0));
        assertEq(whitelist.participantCount(), 0);
    }

    function testFuzz_nonAdminCannotAdd(address caller, address participant, bytes32 accountId) public {
        vm.assume(caller != admin);
        vm.assume(participant != address(0));
        vm.assume(accountId != bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                caller,
                WHITELIST_ADMIN_ROLE
            )
        );
        vm.prank(caller);
        whitelist.addParticipant(participant, accountId);
    }
}
