// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from 'forge-std/Test.sol';
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { Pausable } from '@openzeppelin/contracts/utils/Pausable.sol';

import { UtexoSourceEntrypoint } from '../src/UtexoSourceEntrypoint.sol';
import { IUtexoSourceEntrypoint } from '../src/interfaces/IUtexoSourceEntrypoint.sol';

import { MockERC20 } from './mocks/MockERC20.sol';
import { MockOFT }   from './mocks/MockOFT.sol';

/// @title UtexoSourceEntrypointTest
/// @notice Verifies that `UtexoSourceEntrypoint` forwards deposits into the OFT
///         with immutable destination parameters, enforces the on-chain fee quote,
///         refunds surplus native, and never holds tokens after a call.
contract UtexoSourceEntrypointTest is Test {
    event Deposit(
        bytes32 indexed guid,
        address indexed user,
        uint256 amountLD,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  destinationAddress,
        uint256 operationId,
        bytes   settlementData
    );

    // -- Business payload constants (entrypoint decodes these from `payload`) --
    /// @dev Reserved-range id for the RGB endpoint (non-EVM). Anything above
    ///      the real EVM range is fine — backend owns this namespace.
    uint256 constant DEST_CHAIN_ID = 1_000_001;
    string  constant DEST_ADDR     = 'tb1q-dest-addr';
    uint256 constant OPERATION_ID  = 42;
    /// @dev Default settlementData for LZ-adapter flows: the route is registered
    ///      with `NullSettlementModule` on the destination side, so the blob is
    ///      empty. Non-empty values are exercised in `test_deposit_settlementData_roundTrips`.
    bytes   constant EMPTY_SETTLEMENT_DATA = '';

    // -- Constants ------------------------------------------------------------
    uint32  constant DST_EID = 30110; // Arbitrum LayerZero eid
    bytes32 constant LZ_ADAPTER = bytes32(uint256(uint160(0xC0d1e0000000000000000000000000000000CAfe)));
    uint256 constant NATIVE_FEE = 0.01 ether;

    // -- Actors ---------------------------------------------------------------
    address user         = makeAddr('user');
    address owner        = makeAddr('owner');
    address pendingOwner = makeAddr('pendingOwner');

    // -- SUT ------------------------------------------------------------------
    MockERC20 token;
    MockOFT   oft;
    UtexoSourceEntrypoint entrypoint;

    function setUp() public {
        token = new MockERC20('USDT', 'USDT');
        oft   = new MockOFT(address(token));
        oft.setNativeFee(NATIVE_FEE);

        entrypoint = new UtexoSourceEntrypoint(
            address(token),
            address(oft),
            DST_EID,
            LZ_ADAPTER,
            owner
        );

        token.mint(user, 1_000_000e6);
        vm.deal(user, 10 ether);
    }

    // =========================================================================
    // Construction
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(entrypoint.token(),          address(token), 'token');
        assertEq(entrypoint.oft(),            address(oft),   'oft');
        assertEq(uint256(entrypoint.dstEid()), DST_EID,       'dstEid');
        assertEq(entrypoint.lzAdapter(),      LZ_ADAPTER,     'lzAdapter');
    }

    function test_constructor_setsConfiguredOwner() public view {
        assertEq(entrypoint.owner(), owner, 'configured owner');
        assertEq(entrypoint.pendingOwner(), address(0), 'no pending owner');
        assertFalse(entrypoint.paused(), 'not paused');
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableInvalidOwner.selector,
            address(0)
        ));
        new UtexoSourceEntrypoint(
            address(token), address(oft), DST_EID, LZ_ADAPTER, address(0)
        );
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidTokenAddress.selector);
        new UtexoSourceEntrypoint(address(0), address(oft), DST_EID, LZ_ADAPTER, owner);
    }

    function test_constructor_revertsOnZeroOft() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidOftAddress.selector);
        new UtexoSourceEntrypoint(address(token), address(0), DST_EID, LZ_ADAPTER, owner);
    }

    function test_constructor_revertsOnZeroEid() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidDstEid.selector);
        new UtexoSourceEntrypoint(address(token), address(oft), 0, LZ_ADAPTER, owner);
    }

    function test_constructor_revertsOnZeroLZAdapter() public {
        vm.expectRevert(IUtexoSourceEntrypoint.InvalidLZAdapter.selector);
        new UtexoSourceEntrypoint(address(token), address(oft), DST_EID, bytes32(0), owner);
    }

    // =========================================================================
    // Ownership
    // =========================================================================

    function test_transferOwnership_requiresPendingOwnerAcceptance() public {
        vm.prank(owner);
        entrypoint.transferOwnership(pendingOwner);

        assertEq(entrypoint.owner(), owner, 'owner unchanged before acceptance');
        assertEq(entrypoint.pendingOwner(), pendingOwner, 'pending owner set');

        vm.prank(pendingOwner);
        entrypoint.acceptOwnership();

        assertEq(entrypoint.owner(), pendingOwner, 'ownership accepted');
        assertEq(entrypoint.pendingOwner(), address(0), 'pending owner cleared');

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            owner
        ));
        entrypoint.pause();

        vm.prank(pendingOwner);
        entrypoint.pause();
        assertTrue(entrypoint.paused(), 'new owner controls pause');
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            user
        ));
        entrypoint.transferOwnership(pendingOwner);
    }

    function test_acceptOwnership_revertsForNonPendingOwner() public {
        vm.prank(owner);
        entrypoint.transferOwnership(pendingOwner);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            user
        ));
        entrypoint.acceptOwnership();
    }

    function test_renounceOwnership_isDisabled() public {
        vm.prank(owner);
        vm.expectRevert(UtexoSourceEntrypoint.OwnershipRenunciationDisabled.selector);
        entrypoint.renounceOwnership();

        assertEq(entrypoint.owner(), owner, 'owner preserved');
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_pauseAndUnpause_areRestrictedToOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            user
        ));
        entrypoint.pause();

        vm.prank(owner);
        entrypoint.pause();
        assertTrue(entrypoint.paused(), 'paused');

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            user
        ));
        entrypoint.unpause();

        vm.prank(owner);
        entrypoint.unpause();
        assertFalse(entrypoint.paused(), 'unpaused');
    }

    function test_pause_revertsWhenAlreadyPaused() public {
        vm.startPrank(owner);
        entrypoint.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        entrypoint.pause();
        vm.stopPrank();
    }

    function test_unpause_revertsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        entrypoint.unpause();
    }

    function test_deposit_revertsWhilePaused_withoutMovingFunds() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(100e6);
        uint256 userTokenBalanceBefore = token.balanceOf(user);
        uint256 userNativeBalanceBefore = user.balance;

        vm.prank(owner);
        entrypoint.pause();

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(token.balanceOf(user), userTokenBalanceBefore, 'user tokens unchanged');
        assertEq(user.balance, userNativeBalanceBefore, 'user native unchanged');
        assertEq(token.balanceOf(address(entrypoint)), 0, 'entrypoint holds no tokens');
        assertEq(token.balanceOf(address(oft)), 0, 'oft untouched');
        assertEq(address(entrypoint).balance, 0, 'entrypoint holds no native');
    }

    function test_quote_remainsAvailableWhilePaused() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(5e6);

        vm.prank(owner);
        entrypoint.pause();

        assertEq(entrypoint.quote(p), NATIVE_FEE, 'quote remains available');
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_deposit_happyPath_forwardsAndEmits() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(100e6);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        uint256 userBalBefore = user.balance;

        vm.expectEmit(true, true, false, true, address(entrypoint));
        emit Deposit(
            keccak256(abi.encode('mock-guid', uint64(1))),
            user,
            p.amountLD,
            block.chainid,
            DEST_CHAIN_ID,
            DEST_ADDR,
            OPERATION_ID,
            EMPTY_SETTLEMENT_DATA
        );

        bytes32 guid = entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        // guid correlates with the mock's assigned value.
        assertEq(guid, keccak256(abi.encode('mock-guid', uint64(1))), 'guid');

        // OFT received tokens and the immutable routing params.
        assertEq(token.balanceOf(address(oft)), p.amountLD, 'oft holds tokens');
        assertEq(uint256(oft.lastDstEid()), DST_EID,       'dstEid forwarded');
        assertEq(oft.lastTo(),              LZ_ADAPTER,      'to forwarded');
        assertEq(oft.lastAmountLD(),        p.amountLD,    'amount forwarded');
        assertEq(oft.lastMinAmountLD(),     p.minAmountLD, 'minAmount forwarded');
        assertEq(oft.lastMsgValue(),        NATIVE_FEE,    'msg.value forwarded');
        assertEq(oft.lastRefundAddress(),   user,          'refund addr');

        // Entrypoint rewrote `composeMsg` with `block.chainid` prepended.
        bytes memory expectedComposeMsg = abi.encode(
            block.chainid, DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, EMPTY_SETTLEMENT_DATA, uint256(0)
        );
        assertEq(oft.lastComposeMsg(), expectedComposeMsg, 'composeMsg = chainid + business');

        // Exact-fee call: user's native balance drops by exactly NATIVE_FEE.
        assertEq(user.balance, userBalBefore - NATIVE_FEE, 'no surplus refund expected');

        // Entrypoint holds no tokens and no allowance after the call.
        assertEq(token.balanceOf(address(entrypoint)), 0, 'no token residue');
        assertEq(token.allowance(address(entrypoint), address(oft)), 0, 'allowance consumed');
    }

    function test_deposit_surplusNative_isRefunded() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(250e6);
        uint256 surplus = 0.05 ether;

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        uint256 userBalBefore = user.balance;
        entrypoint.deposit{ value: NATIVE_FEE + surplus }(p);
        vm.stopPrank();

        assertEq(user.balance, userBalBefore - NATIVE_FEE, 'surplus refunded');
        assertEq(address(entrypoint).balance, 0,           'no native residue');
    }

    /// @dev `extraOptions` is the only `bytes` field passed through unchanged.
    ///      `payload` is decoded and recombined with `block.chainid`, so it is
    ///      NOT byte-equal to `oft.lastComposeMsg()` — that case is exercised
    ///      by `test_deposit_happyPath_forwardsAndEmits`.
    function test_deposit_forwardsExtraOptionsUnchanged() public {
        bytes memory extra = hex'0003010011010000000000000000000000000000ea60';
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     42e6,
            minAmountLD:  42e6,
            extraOptions: extra,
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, EMPTY_SETTLEMENT_DATA),
            refundTo: address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(oft.lastExtraOptions(),  extra, 'extraOptions forwarded byte-for-byte');
        assertEq(oft.lastOftCmd().length, 0,     'oftCmd is always empty');
    }

    /// @dev Non-empty `settlementData` must round-trip byte-for-byte through the
    ///      payload → composeMsg pipeline so the destination route's
    ///      `SettlementModule.onFundsIn` sees exactly what the caller intended.
    ///      LZ-adapter flows default to empty data (NullSettlementModule), but
    ///      future routes (or future settlement modules) may consume a non-empty
    ///      blob and the entrypoint must not lose or mangle it.
    function test_deposit_settlementData_roundTrips() public {
        bytes memory blob = hex'deadbeefcafebabe1122334455667788';
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     7e6,
            minAmountLD:  7e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, blob),
            refundTo: address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        vm.expectEmit(true, true, false, true, address(entrypoint));
        emit Deposit(
            keccak256(abi.encode('mock-guid', uint64(1))),
            user, p.amountLD, block.chainid,
            DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, blob
        );

        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        bytes memory expectedComposeMsg = abi.encode(
            block.chainid, DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, blob, uint256(0)
        );
        assertEq(oft.lastComposeMsg(), expectedComposeMsg, 'composeMsg carries settlementData');
    }

    /// @dev Deposit binds `expectedComposeValue` into `composeMsg` so the
    ///      destination adapter can enforce the funded native value.
    function test_deposit_bindsExpectedComposeValueIntoComposeMsg() public {
        uint256 ecv = 0.02 ether;
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     7e6,
            minAmountLD:  7e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, EMPTY_SETTLEMENT_DATA),
            refundTo:     address(0),
            expectedComposeValue: ecv
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        bytes memory expectedComposeMsg = abi.encode(
            block.chainid, DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, EMPTY_SETTLEMENT_DATA, ecv
        );
        assertEq(oft.lastComposeMsg(), expectedComposeMsg, 'composeMsg carries expectedComposeValue');
    }

    /// @dev A malformed `payload` (cannot decode as (uint256, string, uint256, bytes))
    ///      must revert on the source chain, before the OFT pulls tokens or the
    ///      caller pays an LZ fee — preventing un-decodable composeMsgs from
    ///      ever being delivered to `UtexoLZAdapter.lzCompose`.
    function test_deposit_revertsOnMalformedPayload() public {
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      hex'01020304', // 4 bytes — too short to decode four dynamic fields
            refundTo: address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        // Abi.decode reverts with no data on insufficient input.
        vm.expectRevert();
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        // No token transfer happened, no LZ fee paid.
        assertEq(token.balanceOf(address(oft)),        0, 'oft untouched');
        assertEq(token.balanceOf(address(entrypoint)), 0, 'entrypoint did not pull');
    }

    /// @dev Deposit rejects an oversized settlementData before pulling
    ///      tokens or paying any LZ fee, so an oversized blob never enters the
    ///      cross-chain composeMsg.
    function test_deposit_revertsOnOversizedSettlementData() public {
        uint256 cap = entrypoint.MAX_SETTLEMENT_DATA_LENGTH();
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, new bytes(cap + 1)),
            refundTo: address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoSourceEntrypoint.SettlementDataTooLong.selector, cap + 1, cap
        ));
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(token.balanceOf(address(oft)),        0, 'oft untouched');
        assertEq(token.balanceOf(address(entrypoint)), 0, 'entrypoint did not pull');
    }

    /// @dev SettlementData exactly at the cap deposits fine.
    function test_deposit_acceptsSettlementDataAtMaxBoundary() public {
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, new bytes(entrypoint.MAX_SETTLEMENT_DATA_LENGTH())),
            refundTo: address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        bytes32 guid = entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(guid, keccak256(abi.encode('mock-guid', uint64(1))), 'deposit succeeds at cap boundary');
    }

    /// @dev Quote applies the same cap so it reverts on exactly the
    ///      input the matching deposit would reject.
    function test_quote_revertsOnOversizedSettlementData() public {
        uint256 cap = entrypoint.MAX_SETTLEMENT_DATA_LENGTH();
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, new bytes(cap + 1)),
            refundTo: address(0),
            expectedComposeValue: 0
        });

        vm.expectRevert(abi.encodeWithSelector(
            IUtexoSourceEntrypoint.SettlementDataTooLong.selector, cap + 1, cap
        ));
        entrypoint.quote(p);
    }

    /// @dev Deposit rejects an oversized destinationAddress before
    ///      pulling tokens or paying any LZ fee.
    function test_deposit_revertsOnOversizedDestinationAddress() public {
        uint256 cap = entrypoint.MAX_DESTINATION_ADDRESS_LENGTH();
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, string(new bytes(cap + 1)), OPERATION_ID, EMPTY_SETTLEMENT_DATA),
            refundTo:     address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoSourceEntrypoint.DestinationAddressTooLong.selector, cap + 1, cap
        ));
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(token.balanceOf(address(oft)),        0, 'oft untouched');
        assertEq(token.balanceOf(address(entrypoint)), 0, 'entrypoint did not pull');
    }

    /// @dev DestinationAddress exactly at the cap deposits fine.
    function test_deposit_acceptsDestinationAddressAtMaxBoundary() public {
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, string(new bytes(entrypoint.MAX_DESTINATION_ADDRESS_LENGTH())), OPERATION_ID, EMPTY_SETTLEMENT_DATA),
            refundTo:     address(0),
            expectedComposeValue: 0
        });

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        bytes32 guid = entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();

        assertEq(guid, keccak256(abi.encode('mock-guid', uint64(1))), 'deposit succeeds at cap boundary');
    }

    /// @dev Quote applies the same cap as deposit.
    function test_quote_revertsOnOversizedDestinationAddress() public {
        uint256 cap = entrypoint.MAX_DESTINATION_ADDRESS_LENGTH();
        IUtexoSourceEntrypoint.DepositParams memory p = IUtexoSourceEntrypoint.DepositParams({
            amountLD:     10e6,
            minAmountLD:  10e6,
            extraOptions: hex'0003',
            payload:      abi.encode(DEST_CHAIN_ID, string(new bytes(cap + 1)), OPERATION_ID, EMPTY_SETTLEMENT_DATA),
            refundTo:     address(0),
            expectedComposeValue: 0
        });

        vm.expectRevert(abi.encodeWithSelector(
            IUtexoSourceEntrypoint.DestinationAddressTooLong.selector, cap + 1, cap
        ));
        entrypoint.quote(p);
    }

    // =========================================================================
    // Reverts
    // =========================================================================

    function test_deposit_revertsOnZeroAmount() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(0);

        vm.prank(user);
        vm.expectRevert(IUtexoSourceEntrypoint.ZeroAmount.selector);
        entrypoint.deposit{ value: NATIVE_FEE }(p);
    }

    function test_deposit_revertsOnInsufficientNativeFee() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);

        vm.expectRevert(abi.encodeWithSelector(
            IUtexoSourceEntrypoint.InsufficientNativeFee.selector,
            NATIVE_FEE - 1,
            NATIVE_FEE
        ));
        entrypoint.deposit{ value: NATIVE_FEE - 1 }(p);
        vm.stopPrank();
    }

    function test_deposit_revertsIfTokenApprovalMissing() public {
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.prank(user);
        vm.expectRevert(); // ERC20: insufficient allowance
        entrypoint.deposit{ value: NATIVE_FEE }(p);
    }

    function test_deposit_propagatesOftRevert() public {
        oft.setSendReverts(true);
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        vm.expectRevert(bytes('MockOFT: forced revert'));
        entrypoint.deposit{ value: NATIVE_FEE }(p);
        vm.stopPrank();
    }

    function test_deposit_revertsIfRefundRecipientRejectsNative() public {
        // Rejecting-fallback contract as caller — surplus refund must fail.
        RejectingRecipient rec = new RejectingRecipient(entrypoint, token);
        token.mint(address(rec), 100e6);
        vm.deal(address(rec), 1 ether);

        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);

        vm.expectRevert(IUtexoSourceEntrypoint.NativeRefundFailed.selector);
        rec.go{ value: NATIVE_FEE + 1 }(p);
    }

    function test_deposit_exactFee_contractRecipient_ok() public {
        // Same rejecting contract, but with exact fee → no refund attempt, no revert.
        RejectingRecipient rec = new RejectingRecipient(entrypoint, token);
        token.mint(address(rec), 100e6);
        vm.deal(address(rec), 1 ether);

        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);
        rec.go{ value: NATIVE_FEE }(p);

        assertEq(token.balanceOf(address(oft)), p.amountLD, 'tokens forwarded');
    }

    /// @dev Surplus is refunded to the explicit `refundTo`, not to the caller.
    ///      Frontends pass the connected user's wallet here.
    function test_deposit_surplusRefundedToExplicitRefundTo() public {
        address refundDest = makeAddr('refundDest');
        IUtexoSourceEntrypoint.DepositParams memory p = _params(250e6);
        p.refundTo = refundDest;
        uint256 surplus = 0.05 ether;

        uint256 destBalBefore = refundDest.balance;
        uint256 userBalBefore = user.balance;

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        entrypoint.deposit{ value: NATIVE_FEE + surplus }(p);
        vm.stopPrank();

        assertEq(refundDest.balance,           destBalBefore + surplus,          'surplus to explicit refundTo');
        assertEq(user.balance,                 userBalBefore - NATIVE_FEE - surplus, 'caller charged full value');
        assertEq(address(entrypoint).balance,  0,                                'no native residue');
    }

    /// @dev A contract caller that cannot receive native is NOT
    ///      bricked when it names a native-capable `refundTo` — surplus goes
    ///      there and the deposit completes.
    function test_deposit_contractCallerNotBrickedWithExplicitRefundTo() public {
        RejectingRecipient rec = new RejectingRecipient(entrypoint, token);
        token.mint(address(rec), 100e6);
        vm.deal(address(rec), 1 ether);

        address refundDest = makeAddr('refundDest');
        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);
        p.refundTo = refundDest;

        uint256 destBalBefore = refundDest.balance;
        rec.go{ value: NATIVE_FEE + 1 }(p);

        assertEq(refundDest.balance,            destBalBefore + 1, 'surplus to refundTo, deposit not bricked');
        assertEq(token.balanceOf(address(oft)), p.amountLD,        'tokens forwarded');
    }

    /// @dev Pointing `refundTo` at a contract that rejects native still reverts —
    ///      the parameter consciously controls the target, so a bad choice is the
    ///      integrator's responsibility rather than a silent default brick.
    function test_deposit_explicitRefundToRejectingNative_reverts() public {
        RejectingRecipient bad = new RejectingRecipient(entrypoint, token);

        IUtexoSourceEntrypoint.DepositParams memory p = _params(10e6);
        p.refundTo = address(bad);

        vm.startPrank(user);
        token.approve(address(entrypoint), p.amountLD);
        vm.expectRevert(IUtexoSourceEntrypoint.NativeRefundFailed.selector);
        entrypoint.deposit{ value: NATIVE_FEE + 1 }(p);
        vm.stopPrank();
    }

    // =========================================================================
    // Quote
    // =========================================================================

    function test_quote_matchesOft() public {
        oft.setNativeFee(0.0037 ether);
        IUtexoSourceEntrypoint.DepositParams memory p = _params(5e6);
        assertEq(entrypoint.quote(p), 0.0037 ether, 'quote passthrough');
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _params(uint256 amount)
        internal
        pure
        returns (IUtexoSourceEntrypoint.DepositParams memory)
    {
        return IUtexoSourceEntrypoint.DepositParams({
            amountLD:     amount,
            minAmountLD:  amount,
            extraOptions: hex'0003',                 // arbitrary non-empty
            payload:      abi.encode(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, EMPTY_SETTLEMENT_DATA),
            refundTo: address(0),
            expectedComposeValue: 0
        });
    }
}

/// @dev Contract that rejects plain-ether transfers. Used to force the
///      `NativeRefundFailed` branch.
contract RejectingRecipient {
    UtexoSourceEntrypoint immutable ep;
    MockERC20             immutable tk;

    constructor(UtexoSourceEntrypoint ep_, MockERC20 tk_) {
        ep = ep_;
        tk = tk_;
    }

    function go(IUtexoSourceEntrypoint.DepositParams calldata p) external payable {
        tk.approve(address(ep), p.amountLD);
        ep.deposit{ value: msg.value }(p);
    }

    // No `receive()` / `fallback()` → any ETH sent to this contract reverts.
}
