// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from 'forge-std/Test.sol';

import { OFTComposeMsgCodec } from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol';

import { UtexoLZAdapter }  from '../src/UtexoLZAdapter.sol';
import { IUtexoLZAdapter } from '../src/interfaces/IUtexoLZAdapter.sol';

import { MockERC20 }  from './mocks/MockERC20.sol';
import { MockOFT }    from './mocks/MockOFT.sol';
import { MockBridge } from './mocks/MockBridge.sol';

/// @title UtexoLZAdapterTest
/// @notice Verifies the inbound (`lzCompose` → `Bridge.fundsIn`) and outbound
///         (`sendOut` → `OFT.send`) flows of `UtexoLZAdapter`, plus access
///         control, native-fee handling, surplus refunds and refund failures.
contract UtexoLZAdapterTest is Test {
    // -- Events (re-declared for vm.expectEmit) -------------------------------
    event ComposeFundsIn(
        bytes32 indexed guid,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 destinationChainId,
        string  destinationAddress,
        uint256 operationId,
        bytes   settlementData
    );

    event SendOut(
        bytes32 indexed guid,
        uint32  dstEid,
        bytes32 recipient,
        uint256 amountLD
    );

    event ComposeFundsInFailed(
        bytes32 indexed guid,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 nativeValue,
        uint256 destinationChainId,
        string  destinationAddress,
        uint256 operationId,
        bytes   settlementData,
        bytes   reason
    );

    event StuckFundsRefunded(
        bytes32 indexed guid,
        address indexed recipient,
        uint256 amountLD,
        uint256 nativeValue
    );

    event TrustedEntrypointSet(uint32 indexed srcEid, bytes32 entrypoint, uint256 chainId);

    // -- Constants ------------------------------------------------------------
    uint32  constant SRC_EID         = 30101;     // LZ endpoint id of the inbound packet
    uint32  constant DST_EID         = 30110;     // Arbitrum eid (outbound stub)
    uint256 constant SOURCE_CHAIN_ID = 1;         // Default `block.chainid` carried by composeMsg
    uint256 constant RGB_CHAIN_ID    = 1_000_001; // Reserved-range id for RGB (non-EVM endpoint)
    uint256 constant NATIVE_FEE      = 0.01 ether;
    /// @dev Default settlementData for LZ-adapter routes: the destination route
    ///      is registered with `NullSettlementModule` on Bridge, so the blob is
    ///      empty. Non-empty values are exercised in
    ///      `test_lzCompose_settlementData_roundTrips`.
    bytes   constant EMPTY_SETTLEMENT_DATA = '';

    /// @dev Recognisable bytes32 used as `composeFrom` for every "honest" lzCompose
    ///      test — populated into `trustedEntrypoints` during `setUp`.
    bytes32 constant TRUSTED_ENTRYPOINT_B32 = bytes32(uint256(0xE471) << 240);

    // -- Actors ---------------------------------------------------------------
    address endpoint      = makeAddr('endpoint');
    address multisigProxy = makeAddr('multisigProxy');
    address relayer       = makeAddr('relayer');
    address recipientEoa  = makeAddr('recipient');
    bytes32 recipientB32  = bytes32(uint256(uint160(makeAddr('recipient'))));

    // -- SUT ------------------------------------------------------------------
    MockERC20      token;
    MockOFT        oft;
    MockBridge     bridge;
    UtexoLZAdapter adapter;

    function setUp() public {
        token  = new MockERC20('USDT', 'USDT');
        oft    = new MockOFT(address(token));
        bridge = new MockBridge(address(token));
        oft.setNativeFee(NATIVE_FEE);

        adapter = new UtexoLZAdapter(
            endpoint,
            address(oft),
            address(token),
            address(bridge),
            multisigProxy
        );

        vm.deal(endpoint,      100 ether);
        vm.deal(multisigProxy, 100 ether);

        // Register the trusted source used by every "honest" inbound test:
        // transport SRC_EID -> entrypoint, bound to business chain id SOURCE_CHAIN_ID.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID);
    }

    // =========================================================================
    // Construction
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(adapter.endpoint(),      endpoint,        'endpoint');
        assertEq(adapter.oft(),           address(oft),    'oft');
        assertEq(adapter.token(),         address(token),  'token');
        assertEq(adapter.bridge(),        address(bridge), 'bridge');
        assertEq(adapter.multisigProxy(), multisigProxy,   'multisigProxy');
    }

    function test_constructor_revertsOnZeroEndpoint() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidEndpoint.selector);
        new UtexoLZAdapter(address(0), address(oft), address(token), address(bridge), multisigProxy);
    }

    function test_constructor_revertsOnZeroOft() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidOft.selector);
        new UtexoLZAdapter(endpoint, address(0), address(token), address(bridge), multisigProxy);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidToken.selector);
        new UtexoLZAdapter(endpoint, address(oft), address(0), address(bridge), multisigProxy);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidBridge.selector);
        new UtexoLZAdapter(endpoint, address(oft), address(token), address(0), multisigProxy);
    }

    function test_constructor_revertsOnZeroMultisigProxy() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidMultisigProxy.selector);
        new UtexoLZAdapter(endpoint, address(oft), address(token), address(bridge), address(0));
    }

    // =========================================================================
    // lzCompose — inbound (FundsIn) happy paths
    // =========================================================================

    function test_lzCompose_happyPath_forwardsToBridge() public {
        uint256 amount = 500e6;
        token.mint(address(adapter), amount);

        uint256 destChainId = RGB_CHAIN_ID;
        string  memory destAddr = 'tb1q-dest-addr';
        uint256 opId            = 42;

        bytes memory message = _encodeCompose(
            uint64(7),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId, EMPTY_SETTLEMENT_DATA, 0.005 ether)
        );

        bytes32 guid = keccak256('inbound-guid');

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(guid, SOURCE_CHAIN_ID, amount, destChainId, destAddr, opId, EMPTY_SETTLEMENT_DATA);

        vm.prank(endpoint);
        adapter.lzCompose{ value: 0.005 ether }(
            address(oft),
            guid,
            message,
            address(0),
            ''
        );

        // Bridge received the tokens, the value, and the args byte-for-byte.
        assertEq(token.balanceOf(address(bridge)),    amount,           'bridge holds tokens');
        assertEq(token.balanceOf(address(adapter)),   0,                'adapter cleared of tokens');
        assertEq(bridge.lastAmount(),                 amount,           'amount forwarded');
        assertEq(bridge.lastSourceChainId(),          SOURCE_CHAIN_ID,  'sourceChainId forwarded');
        assertEq(bridge.lastDestinationChainId(),     destChainId,      'destChainId forwarded');
        assertEq(bridge.lastDestinationAddress(),     destAddr,         'destAddr forwarded');
        assertEq(bridge.lastOperationId(),            opId,             'opId forwarded');
        assertEq(bridge.lastSettlementData(),         EMPTY_SETTLEMENT_DATA, 'settlementData forwarded');
        assertEq(bridge.lastMsgValue(),               0.005 ether,      'msg.value forwarded');
        assertEq(bridge.lastCaller(),                 address(adapter), 'caller is adapter');

        // Allowance fully consumed.
        assertEq(token.allowance(address(adapter), address(bridge)), 0, 'allowance consumed');
    }

    function test_lzCompose_zeroNativeValue_okForTokenRoutes() public {
        // TOKEN-currency routes pass msg.value == 0. Adapter must still forward.
        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, string('rgb'), string('addr'), uint256(1), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: 0 }(address(oft), bytes32(0), message, address(0), '');

        assertEq(bridge.lastMsgValue(), 0, 'zero value forwarded');
        assertEq(token.balanceOf(address(bridge)), amount, 'bridge holds tokens');
    }

    /// @dev `sourceChainId` is read from the business payload (set by
    ///      `UtexoSourceEntrypoint` from `block.chainid` on the source side)
    ///      and surfaced both via the event and via the forwarded
    ///      `Bridge.fundsIn` call. Post R-M-02 the value must also match the
    ///      chain id registered for the transport `srcEid`, so this test binds
    ///      SRC_EID to the custom chain id before composing.
    function test_lzCompose_emitsSourceChainIdFromPayload() public {
        uint256 customChainId = 137; // pretend the deposit came from Polygon
        uint256 amount        = 7e6;
        token.mint(address(adapter), amount);

        // Bind SRC_EID -> customChainId so the declared sourceChainId is accepted.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, customChainId);

        bytes memory message = _encodeCompose(
            uint64(99),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(customChainId, RGB_CHAIN_ID, string('b'), uint256(0), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(bytes32('g'), customChainId, amount, RGB_CHAIN_ID, 'b', 0, EMPTY_SETTLEMENT_DATA);

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32('g'), message, address(0), '');

        assertEq(bridge.lastSourceChainId(), customChainId, 'sourceChainId forwarded to Bridge');
    }

    /// @dev `settlementData` is opaque to the adapter — whatever the source
    ///      side packs into the composeMsg must reach `Bridge.fundsIn`
    ///      byte-for-byte and surface on the `ComposeFundsIn` event. Routes
    ///      registered with `NullSettlementModule` happen to pass empty bytes,
    ///      but non-empty blobs are valid inputs for routes whose module
    ///      consumes them (e.g. RGB).
    function test_lzCompose_settlementData_roundTrips() public {
        uint256 amount      = 50e6;
        bytes   memory data = hex'deadbeefcafe0001';
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(11), data, uint256(0))
        );

        bytes32 guid = bytes32('rt-guid');

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(guid, SOURCE_CHAIN_ID, amount, RGB_CHAIN_ID, 'addr', 11, data);

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), '');

        assertEq(bridge.lastSettlementData(), data, 'settlementData byte-for-byte to Bridge');
    }

    /// @dev When Bridge.fundsIn reverts, the (non-empty) `settlementData` must
    ///      be captured on the stuck record so operators can inspect what the
    ///      destination route was supposed to receive.
    function test_lzCompose_storesSettlementDataOnStuckRecord() public {
        bridge.setReverts(true);

        uint256 amount      = 1e6;
        bytes   memory data = hex'1234';
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(2), data, uint256(0))
        );

        bytes32 guid = bytes32('rt-stuck');

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), '');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.settlementData, data, 'stuck settlementData preserved');
    }

    // =========================================================================
    // lzCompose — access control & failure paths
    // =========================================================================

    function test_lzCompose_revertsIfNotEndpoint() public {
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('b'), uint256(0), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(makeAddr('attacker'));
        vm.expectRevert(IUtexoLZAdapter.NotEndpoint.selector);
        adapter.lzCompose(address(oft), bytes32(0), message, address(0), '');
    }

    function test_lzCompose_revertsIfFromIsNotOft() public {
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('b'), uint256(0), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(IUtexoLZAdapter.NotFromOft.selector);
        adapter.lzCompose(makeAddr('not-oft'), bytes32(0), message, address(0), '');
    }

    /// @dev Bridge.fundsIn revert no longer makes `lzCompose` revert — instead
    ///      the funds are parked under `_stuckFunds[guid]` and a failure event
    ///      is emitted. `lzCompose` itself returns successfully so the LZ
    ///      endpoint clears its compose queue.
    function test_lzCompose_storesStuckRecordIfBridgeReverts() public {
        bridge.setReverts(true);

        uint256 amount      = 1e6;
        uint256 nativeValue = 0.005 ether;
        token.mint(address(adapter), amount);

        uint256 destChainId = RGB_CHAIN_ID;
        string  memory destAddr = 'tb1q-stuck';
        uint256 opId            = 99;

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId, EMPTY_SETTLEMENT_DATA, nativeValue)
        );

        bytes32 guid = bytes32('stuck-guid');

        // Reason data is the abi-encoded `Error(string)` for the mock's
        // revert message — assert the indexed guid and the non-indexed
        // scalar/string fields, ignore `reason` byte-for-byte.
        vm.expectEmit(true, false, false, false, address(adapter));
        emit ComposeFundsInFailed(
            guid, SOURCE_CHAIN_ID, amount, nativeValue, destChainId, destAddr, opId, EMPTY_SETTLEMENT_DATA, ''
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: nativeValue }(
            address(oft), guid, message, address(0), ''
        );

        // Funds did NOT leave the adapter — Bridge rejected the call.
        assertEq(token.balanceOf(address(bridge)),  0,      'bridge unchanged');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');
        assertEq(address(adapter).balance,          nativeValue, 'adapter holds native');

        // Allowance from the failed attempt was reset to 0 so it does not
        // accumulate across compose calls with different guids.
        assertEq(token.allowance(address(adapter), address(bridge)), 0, 'allowance reset');

        // Stuck record captured every field needed to drive a later refund.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,            amount,          'stuck amountLD');
        assertEq(rec.nativeValue,         nativeValue,     'stuck nativeValue');
        assertEq(rec.operationId,         opId,            'stuck opId');
        assertEq(rec.sourceChainId,       SOURCE_CHAIN_ID, 'stuck sourceChainId');
        assertEq(rec.destinationChainId,  destChainId,     'stuck destChainId');
        assertEq(rec.destinationAddress,  destAddr,        'stuck destAddr');
        assertEq(rec.settlementData,      EMPTY_SETTLEMENT_DATA, 'stuck settlementData');
    }

    function test_lzCompose_happyPath_doesNotCreateStuckRecord() public {
        uint256 amount = 250e6;
        token.mint(address(adapter), amount);

        bytes32 guid = bytes32('happy-guid');
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(7), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), '');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,    0, 'no record on success');
        assertEq(rec.nativeValue, 0, 'no record on success');
    }

    /// @dev A second failed compose under a guid that
    ///      already has a parked record must revert rather than overwrite it,
    ///      so the originally stranded funds stay recoverable via
    ///      `refundStuckFunds`. LayerZero guids are unique per packet, so this
    ///      is defensive hardening, exercised here directly.
    function test_lzCompose_duplicateGuidFailure_revertsAndPreservesRecord() public {
        bridge.setReverts(true);

        bytes32 guid = bytes32('dup-guid');

        // First failed compose parks a record under `guid`.
        uint256 amount1 = 1e6;
        token.mint(address(adapter), amount1);
        bytes memory message1 = _encodeCompose(
            uint64(1), SRC_EID, amount1, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('first'), uint256(1), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message1, address(0), '');

        IUtexoLZAdapter.StuckFunds memory first = adapter.getStuckFunds(guid);
        assertEq(first.amountLD,    amount1, 'record parked by first compose');
        assertEq(first.operationId, 1,       'first opId parked');

        // Second failed compose with the SAME guid but different fields must
        // revert, leaving the original record untouched.
        uint256 amount2 = 5e6;
        token.mint(address(adapter), amount2);
        bytes memory message2 = _encodeCompose(
            uint64(2), SRC_EID, amount2, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('second'), uint256(2), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.StuckFundsAlreadyExist.selector, guid));
        adapter.lzCompose(address(oft), guid, message2, address(0), '');

        // Original record preserved — not clobbered by the second attempt.
        IUtexoLZAdapter.StuckFunds memory afterAttempt = adapter.getStuckFunds(guid);
        assertEq(afterAttempt.amountLD,           amount1, 'amountLD unchanged');
        assertEq(afterAttempt.operationId,        1,       'opId unchanged');
        assertEq(afterAttempt.destinationAddress, 'first', 'destAddr unchanged');
    }

    /// @dev R-I-05: an inbound compose whose settlementData exceeds the cap is
    ///      rejected right after decode — before any onward plumbing or
    ///      `_stuckFunds` storage write.
    function test_lzCompose_revertsOnOversizedSettlementData() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        uint256 cap     = adapter.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory tooBig = new bytes(cap + 1);
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(1), tooBig, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.SettlementDataTooLong.selector, cap + 1, cap
        ));
        adapter.lzCompose(address(oft), bytes32('big-guid'), message, address(0), '');
    }

    /// @dev settlementData exactly at the cap is accepted and
    ///      flows through to the Bridge.
    function test_lzCompose_acceptsSettlementDataAtMaxBoundary() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory atMax = new bytes(adapter.MAX_SETTLEMENT_DATA_LENGTH());
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(1), atMax, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32('ok-guid'), message, address(0), '');

        assertEq(token.balanceOf(address(bridge)), amount, 'forwarded to bridge at cap boundary');
        assertEq(adapter.getStuckFunds(bytes32('ok-guid')).amountLD, 0, 'no stuck record at boundary');
    }

    /// @dev An inbound compose whose destinationAddress exceeds the cap
    ///      is rejected right after decode.
    function test_lzCompose_revertsOnOversizedDestinationAddress() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        uint256 cap = adapter.MAX_DESTINATION_ADDRESS_LENGTH();
        string memory tooLong = string(new bytes(cap + 1));
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, tooLong, uint256(1), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.DestinationAddressTooLong.selector, cap + 1, cap
        ));
        adapter.lzCompose(address(oft), bytes32('long-addr-guid'), message, address(0), '');
    }

    /// @dev DestinationAddress exactly at the cap flows through.
    function test_lzCompose_acceptsDestinationAddressAtMaxBoundary() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        string memory atMax = string(new bytes(adapter.MAX_DESTINATION_ADDRESS_LENGTH()));
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, atMax, uint256(1), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32('ok-addr-guid'), message, address(0), '');

        assertEq(token.balanceOf(address(bridge)), amount, 'forwarded to bridge at cap boundary');
        assertEq(adapter.getStuckFunds(bytes32('ok-addr-guid')).amountLD, 0, 'no stuck record at boundary');
    }

    /// @dev A compose executed with `msg.value` != the bound
    ///      `expectedComposeValue` (griefing) reverts — the deposit is NOT
    ///      parked, so LayerZero can retry with the funded value.
    function test_lzCompose_revertsOnComposeValueMismatch() public {
        uint256 amount   = 1e6;
        uint256 expected = 0.01 ether; // what the depositor funded as the drop
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(1), EMPTY_SETTLEMENT_DATA, expected)
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.ComposeValueMismatch.selector, uint256(0.005 ether), expected
        ));
        adapter.lzCompose{ value: 0.005 ether }(address(oft), bytes32('grief'), message, address(0), '');

        // Nothing parked; tokens untouched — the compose is retryable.
        assertEq(adapter.getStuckFunds(bytes32('grief')).amountLD, 0, 'no stuck record');
        assertEq(token.balanceOf(address(bridge)), 0, 'bridge untouched');
    }

    /// @dev An honestly-funded compose (`msg.value == expectedComposeValue`)
    ///      that the Bridge then rejects (e.g. oracle drift moved the native
    ///      commission) lands in `_stuckFunds` — recoverable, not reverted
    ///      without a record. This is the case a bare `< commission` guard
    ///      would wrongly drop.
    function test_lzCompose_honestlyFundedButBridgeReverts_parksRecoverable() public {
        bridge.setReverts(true);

        uint256 amount   = 1e6;
        uint256 expected = 0.01 ether;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(9), EMPTY_SETTLEMENT_DATA, expected)
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: expected }(address(oft), bytes32('honest-park'), message, address(0), '');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32('honest-park'));
        assertEq(rec.amountLD,    amount,   'honest deposit parked (recoverable)');
        assertEq(rec.nativeValue, expected, 'parked native value');
    }

    /// @dev A compose whose business payload cannot be decoded must NOT
    ///      revert (that would strand the OFT-credited USDT0 with no record).
    ///      Instead it parks a minimal recoverable record (amountLD + forwarded
    ///      native); the business fields are unknown, so they stay at defaults.
    function test_lzCompose_malformedPayload_parksRecoverableRecord() public {
        uint256 amount      = 3e6;
        uint256 nativeValue = 0.004 ether;
        token.mint(address(adapter), amount);

        // Truncated business payload: cannot decode as the 6-field tuple.
        bytes memory badPayload = abi.encode(uint256(0xdeadbeef));
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32, badPayload
        );

        bytes32 guid = bytes32('malformed-guid');

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsInFailed(
            guid, 0, amount, nativeValue, 0, '', 0, '', bytes('malformed compose payload')
        );

        // Does NOT revert — the malformed compose is parked, not stranded.
        vm.prank(endpoint);
        adapter.lzCompose{ value: nativeValue }(address(oft), guid, message, address(0), '');

        // Minimal recoverable record: only amountLD + nativeValue are known.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,           amount,      'parked amountLD');
        assertEq(rec.nativeValue,        nativeValue, 'parked nativeValue');
        assertEq(rec.operationId,        0,           'opId default');
        assertEq(rec.sourceChainId,      0,           'sourceChainId default');
        assertEq(rec.destinationChainId, 0,           'destChainId default');
        assertEq(rec.destinationAddress, '',          'destAddr default');
        assertEq(rec.settlementData,     '',          'settlementData default');

        // Funds stayed on the adapter (not forwarded to the Bridge), recoverable
        // via refundStuckFunds.
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');
        assertEq(token.balanceOf(address(bridge)),  0,      'bridge untouched');
    }

    /// @dev The unique-guid guard also covers the malformed-park path —
    ///      a second malformed compose for the same guid reverts rather than
    ///      overwriting the first parked record.
    function test_lzCompose_malformedPayload_guidGuardRevertsOnSecond() public {
        token.mint(address(adapter), 5e6);
        bytes memory badPayload = abi.encode(uint256(1));
        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 2e6, TRUSTED_ENTRYPOINT_B32, badPayload
        );
        bytes32 guid = bytes32('dup-malformed');

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), '');

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.StuckFundsAlreadyExist.selector, guid));
        adapter.lzCompose(address(oft), guid, message, address(0), '');
    }

    // =========================================================================
    // sendOut — outbound (FundsOut) happy paths
    // =========================================================================

    function test_sendOut_happyPath_forwardsToOft() public {
        uint256 amount = 1_000e6;
        token.mint(address(adapter), amount);

        bytes memory extraOptions = hex'0003010011010000000000000000000000000000ea60';

        uint256 proxyBalBefore = multisigProxy.balance;

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(
            keccak256(abi.encode('mock-guid', uint64(1))),
            DST_EID,
            recipientB32,
            amount
        );

        // `vm.prank(msgSender, txOrigin)` sets both — the adapter refunds
        // the native surplus to `tx.origin` (= the relayer EOA in production).
        // The MockOFT-generated guid is asserted via the `SendOut` event above;
        // the function intentionally returns nothing.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, amount, amount, extraOptions
        );

        // OFT received the tokens and the routing parameters byte-for-byte.
        assertEq(token.balanceOf(address(oft)),      amount,        'oft holds tokens');
        assertEq(token.balanceOf(address(adapter)),  0,             'adapter cleared');
        assertEq(uint256(oft.lastDstEid()),          DST_EID,       'dstEid forwarded');
        assertEq(oft.lastTo(),                       recipientB32,  'to forwarded');
        assertEq(oft.lastAmountLD(),                 amount,        'amount forwarded');
        assertEq(oft.lastMinAmountLD(),              amount,        'minAmount forwarded');
        assertEq(oft.lastExtraOptions(),             extraOptions,  'extraOptions forwarded');
        assertEq(oft.lastComposeMsg().length,        0,             'composeMsg empty');
        assertEq(oft.lastOftCmd().length,            0,             'oftCmd empty');
        assertEq(oft.lastMsgValue(),                 NATIVE_FEE,    'native fee forwarded');
        // OFT.send is called with refundAddress = tx.origin, which equals the
        // relayer EOA in production. Defensive only — OFT consumes the full fee.
        assertEq(oft.lastRefundAddress(),            relayer,       'refund addr = tx.origin');

        // Exact-fee call: proxy balance drops by exactly NATIVE_FEE.
        assertEq(multisigProxy.balance, proxyBalBefore - NATIVE_FEE, 'no surplus expected');

        // Adapter holds nothing afterward.
        assertEq(token.allowance(address(adapter), address(oft)), 0, 'oft allowance consumed');
        assertEq(address(adapter).balance, 0, 'no native residue');
    }

    function test_sendOut_surplusNativeRefundedToTxOrigin() public {
        uint256 amount  = 250e6;
        uint256 surplus = 0.05 ether;
        token.mint(address(adapter), amount);

        uint256 proxyBalBefore   = multisigProxy.balance;
        uint256 relayerBalBefore = relayer.balance;

        // tx.origin = relayer → surplus is refunded to relayer.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE + surplus }(
            DST_EID, recipientB32, amount, amount, hex'0003'
        );

        // Proxy paid the full msg.value (fee + surplus).
        assertEq(
            multisigProxy.balance,
            proxyBalBefore - NATIVE_FEE - surplus,
            'proxy paid fee + surplus'
        );
        // Relayer received exactly the surplus as refund from the adapter.
        assertEq(relayer.balance, relayerBalBefore + surplus, 'surplus refunded to tx.origin');
        assertEq(address(adapter).balance, 0, 'no native residue');
    }

    /// @dev `sendOut` no longer returns the guid — it is published only via
    ///      the `SendOut` event. Assert that each successive call emits a
    ///      distinct, MockOFT-derived guid.
    function test_sendOut_emitsUniqueGuidPerCall() public {
        token.mint(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode('mock-guid', uint64(1))), DST_EID, recipientB32, 50e6);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 50e6, 50e6, hex'0003'
        );

        token.mint(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode('mock-guid', uint64(2))), DST_EID, recipientB32, 50e6);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 50e6, 50e6, hex'0003'
        );
    }

    // =========================================================================
    // sendOut — access control & input validation
    // =========================================================================

    function test_sendOut_revertsIfNotMultisigProxy() public {
        token.mint(address(adapter), 100e6);

        address attacker = makeAddr('attacker');
        vm.deal(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 100e6, 100e6, hex'0003'
        );
    }

    function test_sendOut_revertsOnZeroAmount() public {
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(IUtexoLZAdapter.ZeroAmount.selector);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 0, 0, hex'0003'
        );
    }

    function test_sendOut_revertsOnZeroRecipient() public {
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, bytes32(0), 100e6, 100e6, hex'0003'
        );
    }

    function test_sendOut_revertsOnInsufficientNativeFee() public {
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.InsufficientNativeFee.selector,
            NATIVE_FEE - 1,
            NATIVE_FEE
        ));
        adapter.sendOut{ value: NATIVE_FEE - 1 }(
            DST_EID, recipientB32, 100e6, 100e6, hex'0003'
        );
    }

    function test_sendOut_revertsIfOftReverts() public {
        oft.setSendReverts(true);
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(bytes('MockOFT: forced revert'));
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, 100e6, 100e6, hex'0003'
        );
    }

    /// @dev Refund failure path: `tx.origin` is spoofed to a contract that
    ///      rejects plain-ether transfers (no `receive()`). Cannot happen in
    ///      production where `tx.origin` is always the backend relayer EOA,
    ///      but the branch is reachable on-chain so the revert must surface.
    function test_sendOut_revertsIfRefundFails() public {
        RejectingRecipient rr = new RejectingRecipient();

        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, address(rr));
        vm.expectRevert(IUtexoLZAdapter.NativeRefundFailed.selector);
        adapter.sendOut{ value: NATIVE_FEE + 1 }(
            DST_EID, recipientB32, amount, amount, hex'0003'
        );
    }

    /// @dev Exact-fee call skips the refund branch entirely, so even a
    ///      `tx.origin` that rejects ETH does not block the call.
    function test_sendOut_exactFee_skipsRefundBranch() public {
        RejectingRecipient rr = new RejectingRecipient();

        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, address(rr));
        adapter.sendOut{ value: NATIVE_FEE }(
            DST_EID, recipientB32, amount, amount, hex'0003'
        );

        assertEq(token.balanceOf(address(oft)), amount, 'tokens forwarded');
    }

    // =========================================================================
    // quoteSendOut
    // =========================================================================

    function test_quoteSendOut_matchesOft() public {
        oft.setNativeFee(0.0042 ether);
        uint256 fee = adapter.quoteSendOut(
            DST_EID, recipientB32, 1e6, 1e6, hex'0003'
        );
        assertEq(fee, 0.0042 ether, 'quote matches oft');
    }

    // =========================================================================
    // Stuck-funds — getStuckFunds + refundStuckFunds
    // =========================================================================

    function test_getStuckFunds_returnsZeroForUnknownGuid() public view {
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32('unknown'));
        assertEq(rec.amountLD,            0,  'amountLD');
        assertEq(rec.nativeValue,         0,  'nativeValue');
        assertEq(rec.operationId,         0,  'operationId');
        assertEq(rec.sourceChainId,       0,  'sourceChainId');
        assertEq(rec.destinationChainId,  0,  'destinationChainId');
        assertEq(rec.destinationAddress,  '', 'destinationAddress');
        assertEq(rec.settlementData,      '', 'settlementData');
    }

    function test_refundStuckFunds_happyPath_tokenAndNative() public {
        uint256 amount      = 1_500e6;
        uint256 nativeValue = 0.02 ether;
        bytes32 guid        = bytes32('to-refund');

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, 'tb1q-bad', 13);

        address payable refundTo = payable(makeAddr('refundTo'));
        uint256 tokenBalBefore   = token.balanceOf(refundTo);
        uint256 nativeBalBefore  = refundTo.balance;

        vm.expectEmit(true, true, false, true, address(adapter));
        emit StuckFundsRefunded(guid, refundTo, amount, nativeValue);

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        // Funds left the adapter and landed on the recipient.
        assertEq(token.balanceOf(refundTo),         tokenBalBefore + amount,      'tokens transferred');
        assertEq(refundTo.balance,                  nativeBalBefore + nativeValue, 'native transferred');
        assertEq(token.balanceOf(address(adapter)), 0,                            'adapter cleared of tokens');
        assertEq(address(adapter).balance,          0,                            'adapter cleared of native');

        // Record is gone.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, 'record deleted');
    }

    function test_refundStuckFunds_tokenOnlyWhenNativeValueIsZero() public {
        uint256 amount = 800e6;
        bytes32 guid   = bytes32('token-only');

        _createStuckRecord(guid, amount, 0, RGB_CHAIN_ID, 'addr', 1);

        address refundTo = makeAddr('refundTo');

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        assertEq(token.balanceOf(refundTo),         amount, 'tokens transferred');
        assertEq(refundTo.balance,                  0,      'no native delivered');
        assertEq(token.balanceOf(address(adapter)), 0,      'adapter cleared');
    }

    function test_refundStuckFunds_revertsIfNotMultisigProxy() public {
        bytes32 guid = bytes32('any');
        _createStuckRecord(guid, 1e6, 0, RGB_CHAIN_ID, 'addr', 1);

        address attacker = makeAddr('attacker');
        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.refundStuckFunds(guid, attacker);
    }

    function test_refundStuckFunds_revertsOnZeroRecipient() public {
        bytes32 guid = bytes32('any');
        _createStuckRecord(guid, 1e6, 0, RGB_CHAIN_ID, 'addr', 1);

        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.refundStuckFunds(guid, address(0));
    }

    function test_refundStuckFunds_revertsIfNoStuckFunds() public {
        bytes32 unknown = bytes32('unknown');
        vm.prank(multisigProxy);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.NoStuckFunds.selector, unknown
        ));
        adapter.refundStuckFunds(unknown, makeAddr('any'));
    }

    /// @dev Refund must atomically roll back if the native leg fails, so the
    ///      record stays recoverable on the next attempt.
    function test_refundStuckFunds_revertsAndPreservesRecordIfNativeRefundFails() public {
        uint256 amount      = 100e6;
        uint256 nativeValue = 0.01 ether;
        bytes32 guid        = bytes32('native-fail');

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, 'addr', 1);

        RejectingRecipient rr = new RejectingRecipient();

        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.NativeRefundFailed.selector);
        adapter.refundStuckFunds(guid, address(rr));

        // Record + adapter balances preserved by the revert rollback.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,    amount,      'record preserved');
        assertEq(rec.nativeValue, nativeValue, 'record preserved');
        assertEq(token.balanceOf(address(adapter)), amount,      'tokens preserved');
        assertEq(address(adapter).balance,          nativeValue, 'native preserved');
    }

    // =========================================================================
    // Trusted entrypoint registry — setTrustedEntrypoint
    // =========================================================================

    function test_setTrustedEntrypoint_setsAndUnsets() public {
        uint32  eid   = 40161;                    // some other transport eid
        bytes32 ep    = bytes32(uint256(0xC0FFEE));
        uint256 chain = 8453;                      // Base

        // Initial state: nothing registered for this eid.
        assertEq(adapter.trustedEntrypoints(eid), bytes32(0), 'starts unregistered');
        assertEq(adapter.eidToChainId(eid),       0,          'starts unmapped');

        // Register: srcEid -> (entrypoint, chainId).
        vm.expectEmit(true, false, false, true, address(adapter));
        emit TrustedEntrypointSet(eid, ep, chain);

        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(eid, ep, chain);
        assertEq(adapter.trustedEntrypoints(eid), ep,    'entrypoint set');
        assertEq(adapter.eidToChainId(eid),       chain, 'chainId set');

        // Revoke: entrypoint == 0 clears both halves of the binding.
        vm.expectEmit(true, false, false, true, address(adapter));
        emit TrustedEntrypointSet(eid, bytes32(0), 0);

        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(eid, bytes32(0), 0);
        assertEq(adapter.trustedEntrypoints(eid), bytes32(0), 'entrypoint cleared');
        assertEq(adapter.eidToChainId(eid),       0,          'chainId cleared');
    }

    function test_setTrustedEntrypoint_revertsIfNotMultisigProxy() public {
        bytes32 ep = bytes32(uint256(0xC0FFEE));
        address attacker = makeAddr('attacker');

        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.setTrustedEntrypoint(SRC_EID, ep, SOURCE_CHAIN_ID);
    }

    function test_setTrustedEntrypoint_revertsOnZeroSrcEid() public {
        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidSrcEid.selector);
        adapter.setTrustedEntrypoint(0, TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID);
    }

    function test_setTrustedEntrypoint_revertsOnZeroChainIdWhenRegistering() public {
        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidChainId.selector);
        adapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, 0);
    }

    // =========================================================================
    // lzCompose — trusted-entrypoint enforcement
    // =========================================================================

    /// @dev Any `composeFrom` outside `trustedEntrypoints` must revert before
    ///      the payload is decoded or any Bridge interaction starts.
    function test_lzCompose_revertsOnUntrustedComposeSource() public {
        bytes32 attackerB32 = bytes32(uint256(0xBADBAD));
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, attackerB32,
            abi.encode(SOURCE_CHAIN_ID, string('rgb'), string('a'), uint256(0), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.UntrustedComposeSource.selector, SRC_EID, attackerB32
        ));
        adapter.lzCompose(address(oft), bytes32('x'), message, address(0), '');

        // Funds did not move and no stuck record was created — the call
        // reverts entirely, leaving the LZ composeQueue intact.
        assertEq(token.balanceOf(address(bridge)),  0,      'bridge untouched');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32('x'));
        assertEq(rec.amountLD, 0, 'no stuck record for untrusted source');
    }

    function test_lzCompose_revertsWhenTrustedEntrypointRevoked() public {
        // Revoke the binding that `setUp` registered for SRC_EID.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(SRC_EID, bytes32(0), 0);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, 1e6, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('b'), uint256(0), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.UntrustedComposeSource.selector, SRC_EID, TRUSTED_ENTRYPOINT_B32
        ));
        adapter.lzCompose(address(oft), bytes32('y'), message, address(0), '');
    }

    // =========================================================================
    // R-M-02 regression — srcEid binding (post-fix)
    // =========================================================================

    /// @dev UT-FIX-04. After the fix, a packet whose payload `sourceChainId`
    ///      does not match the chain id registered for its transport `srcEid`
    ///      must be rejected — even when the caller IS the entrypoint trusted
    ///      for that srcEid. Proves `sourceChainId` (which drives route +
    ///      commission selection) is corroborated by the LayerZero transport
    ///      rather than taken on faith from the payload.
    function test_srcEidMustMatchDeclaredSourceChain_afterFix() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        // setUp registered SRC_EID -> (TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID).
        // Keep the trusted entrypoint, but declare a different sourceChainId.
        uint256 wrongChainId = SOURCE_CHAIN_ID + 999;

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(wrongChainId, RGB_CHAIN_ID, string('addr'), uint256(7), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.SourceChainIdMismatch.selector, SRC_EID, wrongChainId
        ));
        adapter.lzCompose(address(oft), bytes32('mismatch'), message, address(0), '');

        // The call reverts wholesale: no tokens moved, no stuck record created.
        assertEq(token.balanceOf(address(bridge)),  0,      'bridge untouched');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');
        assertEq(adapter.getStuckFunds(bytes32('mismatch')).amountLD, 0, 'no stuck record');
    }

    /// @dev An entrypoint trusted for one `srcEid` must NOT be honoured on a
    ///      different `srcEid` (here unregistered). Proves trust is bound to the
    ///      transport origin LayerZero attests, not to the bare caller address
    ///      — so a trusted entrypoint cannot have its messages accepted as if
    ///      they arrived from another source chain.
    function test_lzCompose_revertsWhenEntrypointTrustedForDifferentSrcEid_afterFix() public {
        uint32  otherEid = 40161; // not registered in setUp
        uint256 amount   = 1e6;
        token.mint(address(adapter), amount);

        // composeFrom is the entrypoint trusted for SRC_EID, but the transport
        // srcEid here is `otherEid`, for which nothing is registered.
        bytes memory message = _encodeCompose(
            uint64(1), otherEid, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(7), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(
            IUtexoLZAdapter.UntrustedComposeSource.selector, otherEid, TRUSTED_ENTRYPOINT_B32
        ));
        adapter.lzCompose(address(oft), bytes32('wrong-eid'), message, address(0), '');

        assertEq(token.balanceOf(address(bridge)),  0,      'bridge untouched');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');
    }

    /// @dev Happy path with all three bindings aligned: trusted entrypoint for
    ///      the transport `srcEid` AND a payload `sourceChainId` that matches the
    ///      chain id registered for that srcEid. The call must succeed and
    ///      forward to the Bridge.
    function test_lzCompose_succeedsWhenSrcEidEntrypointAndChainIdAllMatch_afterFix() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, RGB_CHAIN_ID, string('addr'), uint256(7), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32('ok'), message, address(0), '');

        assertEq(token.balanceOf(address(bridge)), amount,          'bridge received tokens');
        assertEq(bridge.lastSourceChainId(),       SOURCE_CHAIN_ID, 'sourceChainId forwarded');
    }

    // =========================================================================
    // lzCompose — credited amount accounting
    // =========================================================================

    /// @dev The adapter must forward the OFT-credited `amountLD` from the compose
    ///      envelope. It must not infer the amount from adapter balance or payload data.
    function test_lzCompose_usesCreditedAmountNotSourceRequestedAmount() public {
        uint256 sourceRequestedAmount = 10e6;
        uint256 creditedAmount        = 7e6;
        token.mint(address(adapter), sourceRequestedAmount);

        uint256 destChainId = RGB_CHAIN_ID;
        string  memory destAddr = 'tb1q-credited';
        uint256 opId            = 777;

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, creditedAmount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId, EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32('credited-guid');

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsIn(
            guid,
            SOURCE_CHAIN_ID,
            creditedAmount,
            destChainId,
            destAddr,
            opId,
            EMPTY_SETTLEMENT_DATA
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), '');

        assertEq(bridge.lastAmount(), creditedAmount, 'credited amount forwarded');
        assertEq(token.balanceOf(address(bridge)), creditedAmount, 'bridge receives credited amount');
        assertEq(
            token.balanceOf(address(adapter)),
            sourceRequestedAmount - creditedAmount,
            'adapter retains excess balance'
        );
        assertEq(token.allowance(address(adapter), address(bridge)), 0, 'allowance consumed');
    }

    // =========================================================================
    // lzCompose — Bridge revert reason regression
    // =========================================================================

    /// @dev The raw Bridge revert returndata is operationally important: indexers
    ///      and recovery tooling use it to classify why funds were parked.
    function test_lzCompose_bridgeRevertReasonPreserved() public {
        bridge.setReverts(true);

        uint256 amount      = 3e6;
        uint256 nativeValue = 0.007 ether;
        token.mint(address(adapter), amount);

        bytes32 guid        = bytes32('reason-guid');
        uint256 destChainId = RGB_CHAIN_ID;
        string  memory destAddr = 'tb1q-reason';
        uint256 opId            = 12345;
        bytes   memory settlementData = hex'feedbeef';
        bytes   memory expectedReason =
            abi.encodeWithSignature('Error(string)', 'MockBridge: forced revert');

        bytes memory message = _encodeCompose(
            uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId, settlementData, nativeValue)
        );

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ComposeFundsInFailed(
            guid,
            SOURCE_CHAIN_ID,
            amount,
            nativeValue,
            destChainId,
            destAddr,
            opId,
            settlementData,
            expectedReason
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: nativeValue }(
            address(oft), guid, message, address(0), ''
        );

        assertEq(token.balanceOf(address(bridge)),  0,      'bridge unchanged');
        assertEq(token.balanceOf(address(adapter)), amount, 'adapter still holds tokens');
        assertEq(address(adapter).balance,          nativeValue, 'adapter holds native');
        assertEq(token.allowance(address(adapter), address(bridge)), 0, 'allowance reset');

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD,           amount,          'stuck amountLD');
        assertEq(rec.nativeValue,        nativeValue,     'stuck nativeValue');
        assertEq(rec.operationId,        opId,            'stuck opId');
        assertEq(rec.sourceChainId,      SOURCE_CHAIN_ID, 'stuck sourceChainId');
        assertEq(rec.destinationChainId, destChainId,     'stuck destChainId');
        assertEq(rec.destinationAddress, destAddr,        'stuck destAddr');
        assertEq(rec.settlementData,     settlementData,  'stuck settlementData');
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Drive `lzCompose` against a reverting Bridge so a stuck record
    ///      is created for `guid`. `sourceChainId` is set to `SOURCE_CHAIN_ID`.
    function _createStuckRecord(
        bytes32 guid,
        uint256 amount,
        uint256 nativeValue,
        uint256 destChainId,
        string memory destAddr,
        uint256 opId
    ) internal {
        bridge.setReverts(true);
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(0), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, destChainId, destAddr, opId, EMPTY_SETTLEMENT_DATA, nativeValue)
        );

        vm.prank(endpoint);
        adapter.lzCompose{ value: nativeValue }(
            address(oft), guid, message, address(0), ''
        );
    }

    /// @dev Build the full LayerZero compose-message payload that the Endpoint
    ///      would deliver to `lzCompose`. Layout:
    ///        [nonce (8)][srcEid (4)][amountLD (32)][composeFrom (32)][business]
    function _encodeCompose(
        uint64  nonce_,
        uint32  srcEid_,
        uint256 amountLD_,
        bytes32 composeFrom_,
        bytes memory businessPayload
    ) internal pure returns (bytes memory) {
        return OFTComposeMsgCodec.encode(
            nonce_,
            srcEid_,
            amountLD_,
            abi.encodePacked(composeFrom_, businessPayload)
        );
    }
}

/// @dev Contract that rejects every plain-ether transfer. Used as a spoofed
///      `tx.origin` to force the `NativeRefundFailed` branch in `sendOut`.
///      No `receive()` / `fallback()` is declared, so any value-carrying call
///      reverts.
contract RejectingRecipient {}
