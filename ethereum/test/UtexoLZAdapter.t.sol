// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {MessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/MessagingComposer.sol";

import {UtexoLZAdapter} from "../src/UtexoLZAdapter.sol";
import {IUtexoLZAdapter} from "../src/interfaces/IUtexoLZAdapter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOFT} from "./mocks/MockOFT.sol";
import {MockBridge} from "./mocks/MockBridge.sol";
import {ZeroApprovalRevertingERC20} from "./mocks/ZeroApprovalRevertingERC20.sol";
import {ZeroAmountBridge} from "./mocks/ZeroAmountBridge.sol";

/// @dev Unmodified LayerZero compose queue used by message-specific recovery tests.
contract ComposeEndpoint is MessagingComposer {}

/// @title UtexoLZAdapterTest
/// @notice Adapter authentication, forwarding, fee handling and recovery tests.
contract UtexoLZAdapterTest is Test {
    // -- Events (re-declared for vm.expectEmit) -------------------------------
    event ComposeFundsIn(
        bytes32 indexed guid,
        bytes32 indexed operationId,
        bytes32 sourceSender,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 destinationChainId,
        string destinationAddress,
        bytes settlementData
    );

    event SendOut(bytes32 indexed guid, uint32 dstEid, bytes32 recipient, uint256 amountLD);

    event ComposeFundsInFailed(
        bytes32 indexed guid,
        bytes32 indexed sourceSender,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 nativeValue,
        uint256 destinationChainId,
        string destinationAddress,
        bytes settlementData,
        bytes reason
    );

    event StuckFundsRefunded(bytes32 indexed guid, address indexed recipient, uint256 amountLD, uint256 nativeValue);

    event TrustedEntrypointSet(uint32 indexed srcEid, bytes32 entrypoint, uint256 chainId);
    event OftRouteSet(uint32 indexed eid, address indexed oft);
    event PendingComposeRecovered(
        bytes32 indexed guid, bytes32 indexed composeKey, address indexed oft, address recipient, uint256 amountLD
    );
    event RecoveredComposeIgnored(
        bytes32 indexed guid, bytes32 indexed composeKey, address indexed oft, uint256 refundedNative
    );

    // -- Constants ------------------------------------------------------------
    uint32 constant SRC_EID = 30101; // LZ endpoint id of the inbound packet
    uint32 constant DST_EID = 30110; // Arbitrum eid (outbound stub)
    uint32 constant LEGACY_EID = 30420; // Tron eid (legacy USDT0 mesh)
    uint256 constant SOURCE_CHAIN_ID = 1; // Default `block.chainid` carried by composeMsg
    uint256 constant RGB_CHAIN_ID = 1_000_001; // Synthetic destination fixture
    uint256 constant NATIVE_FEE = 0.01 ether;
    bytes constant EMPTY_SETTLEMENT_DATA = "";

    /// @dev Source entrypoint registered for `SRC_EID` in setUp.
    bytes32 constant TRUSTED_ENTRYPOINT_B32 = bytes32(uint256(0xE471) << 240);

    /// @dev Source caller encoded in compose fixtures.
    bytes32 SOURCE_SENDER = bytes32(uint256(uint160(makeAddr("sourceSender"))));

    /// @dev RGB lock ID used in settlement-payload fixtures.
    uint256 constant RGB_LOCK_ID = 42;

    // -- Actors ---------------------------------------------------------------
    address endpoint;
    address multisigProxy = makeAddr("multisigProxy");
    address relayer = makeAddr("relayer");
    address recipientEoa = makeAddr("recipient");
    bytes32 recipientB32 = bytes32(uint256(uint160(makeAddr("recipient"))));

    // -- SUT ------------------------------------------------------------------
    MockERC20 token;
    MockOFT oft;
    MockBridge bridge;
    ComposeEndpoint composeEndpoint;
    UtexoLZAdapter adapter;

    function setUp() public {
        token = new MockERC20("USDT", "USDT");
        oft = new MockOFT(address(token));
        bridge = new MockBridge(address(token));
        composeEndpoint = new ComposeEndpoint();
        endpoint = address(composeEndpoint);
        oft.setNativeFee(NATIVE_FEE);

        oft.setPeer(SRC_EID, bytes32(uint256(1)));
        oft.setPeer(DST_EID, bytes32(uint256(2)));

        uint32[] memory eids = new uint32[](2);
        eids[0] = SRC_EID;
        eids[1] = DST_EID;
        address[] memory ofts = new address[](2);
        ofts[0] = address(oft);
        ofts[1] = address(oft);

        adapter = new UtexoLZAdapter(endpoint, address(token), address(bridge), multisigProxy, eids, ofts);

        vm.deal(endpoint, 100 ether);
        vm.deal(multisigProxy, 100 ether);
        vm.deal(relayer, 100 ether);

        // Bind the fixture entrypoint and source chain id to SRC_EID.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID);
    }

    // =========================================================================
    // Construction
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(adapter.endpoint(), endpoint, "endpoint");
        assertEq(adapter.token(), address(token), "token");
        assertEq(adapter.bridge(), address(bridge), "bridge");
        assertEq(adapter.multisigProxy(), multisigProxy, "multisigProxy");
        assertEq(adapter.oftByEid(SRC_EID), address(oft), "source oft route");
        assertEq(adapter.oftByEid(DST_EID), address(oft), "destination oft route");
        assertTrue(adapter.knownOfts(address(oft)), "configured oft retained for recovery");
    }

    function test_constructor_revertsOnZeroEndpoint() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidEndpoint.selector);
        _deploySingleRoute(address(0), address(token), address(bridge), multisigProxy, SRC_EID, address(oft));
    }

    function test_constructor_revertsOnZeroOft() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidOft.selector);
        _deploySingleRoute(endpoint, address(token), address(bridge), multisigProxy, SRC_EID, address(0));
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidToken.selector);
        _deploySingleRoute(endpoint, address(0), address(bridge), multisigProxy, SRC_EID, address(oft));
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidBridge.selector);
        _deploySingleRoute(endpoint, address(token), address(0), multisigProxy, SRC_EID, address(oft));
    }

    function test_constructor_revertsOnZeroMultisigProxy() public {
        vm.expectRevert(IUtexoLZAdapter.InvalidMultisigProxy.selector);
        _deploySingleRoute(endpoint, address(token), address(bridge), address(0), SRC_EID, address(oft));
    }

    function test_constructor_revertsWithoutOftRoutes() public {
        uint32[] memory eids = new uint32[](0);
        address[] memory ofts = new address[](0);

        vm.expectRevert(IUtexoLZAdapter.NoOftRoutes.selector);
        new UtexoLZAdapter(endpoint, address(token), address(bridge), multisigProxy, eids, ofts);
    }

    function test_constructor_revertsOnOftRouteLengthMismatch() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = SRC_EID;
        address[] memory ofts = new address[](0);

        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.OftRouteLengthMismatch.selector, 1, 0));
        new UtexoLZAdapter(endpoint, address(token), address(bridge), multisigProxy, eids, ofts);
    }

    function test_constructor_revertsOnDuplicateOftEid() public {
        uint32[] memory eids = new uint32[](2);
        eids[0] = SRC_EID;
        eids[1] = SRC_EID;
        address[] memory ofts = new address[](2);
        ofts[0] = address(oft);
        ofts[1] = address(oft);

        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.DuplicateOftRoute.selector, SRC_EID));
        new UtexoLZAdapter(endpoint, address(token), address(bridge), multisigProxy, eids, ofts);
    }

    // =========================================================================
    // lzCompose — inbound (FundsIn) happy paths
    // =========================================================================

    function test_lzCompose_happyPath_forwardsToBridge() public {
        uint256 amount = 500e6;
        token.mint(address(adapter), amount);

        uint256 destChainId = RGB_CHAIN_ID;
        string memory destAddr = "tb1q-dest-addr";
        bytes memory settlementData = abi.encode(RGB_LOCK_ID, type(uint64).max);

        bytes32 opId = keccak256("derived-op-id");
        bridge.setOperationIdToReturn(opId);

        bytes memory message = _encodeCompose(
            uint64(7),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, destChainId, destAddr, settlementData, 0.005 ether)
        );

        bytes32 guid = keccak256("inbound-guid");

        vm.expectEmit(true, true, false, true, address(adapter));
        emit ComposeFundsIn(guid, opId, SOURCE_SENDER, SOURCE_CHAIN_ID, amount, destChainId, destAddr, settlementData);

        vm.prank(endpoint);
        adapter.lzCompose{value: 0.005 ether}(address(oft), guid, message, address(0), "");

        // Bridge received the tokens, the value, and the args byte-for-byte.
        assertEq(token.balanceOf(address(bridge)), amount, "bridge holds tokens");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter cleared of tokens");
        assertEq(bridge.lastAmount(), amount, "amount forwarded");
        assertEq(bridge.lastSourceChainId(), SOURCE_CHAIN_ID, "sourceChainId forwarded");
        assertEq(bridge.lastSourceSender(), SOURCE_SENDER, "sourceSender forwarded");
        assertEq(bridge.lastDestinationChainId(), destChainId, "destChainId forwarded");
        assertEq(bridge.lastDestinationAddress(), destAddr, "destAddr forwarded");
        assertEq(bridge.lastSettlementData(), settlementData, "settlementData forwarded");
        assertEq(bridge.lastMsgValue(), 0.005 ether, "msg.value forwarded");
        assertEq(bridge.lastCaller(), address(adapter), "caller is adapter");

        // Allowance fully consumed.
        assertEq(token.allowance(address(adapter), address(bridge)), 0, "allowance consumed");
    }

    function test_lzCompose_forwardsSourceSenderToBridge() public {
        uint256 amount = 123e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32("src-sender"), message, address(0), "");

        assertEq(bridge.lastSourceSender(), SOURCE_SENDER, "decoded sourceSender forwarded to Bridge");
    }

    function test_lzCompose_emitsDerivedOperationId() public {
        uint256 amount = 321e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        // Check the operation id returned by MockBridge against the emitted event.
        bytes32 guid = bytes32("derived-guid");

        vm.recordLogs();
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        bytes32 derived = bridge.lastReturnedOperationId();
        assertTrue(derived != bytes32(0), "bridge derived a non-zero operationId");

        // The event's second indexed topic (operationId) equals the Bridge's return.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            // topic0 == keccak of the ComposeFundsIn signature, topic2 == operationId.
            if (logs[i].topics.length == 3 && logs[i].topics[0] == ComposeFundsIn.selector && logs[i].topics[1] == guid)
            {
                assertEq(logs[i].topics[2], derived, "ComposeFundsIn.operationId == Bridge return");
                found = true;
            }
        }
        assertTrue(found, "ComposeFundsIn emitted");
    }

    function test_lzCompose_zeroNativeValue_okForTokenRoutes() public {
        // Exercise a compose with no forwarded native value.
        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose{value: 0}(address(oft), bytes32(0), message, address(0), "");

        assertEq(bridge.lastMsgValue(), 0, "zero value forwarded");
        assertEq(token.balanceOf(address(bridge)), amount, "bridge holds tokens");
    }

    function test_lzCompose_emitsSourceChainIdFromPayload() public {
        uint256 customChainId = 137; // pretend the deposit came from Polygon
        uint256 amount = 7e6;
        token.mint(address(adapter), amount);

        // Bind SRC_EID -> customChainId so the declared sourceChainId is accepted.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, customChainId);

        bytes32 opId = keccak256("op-src-chain");
        bridge.setOperationIdToReturn(opId);

        bytes memory message = _encodeCompose(
            uint64(99),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(customChainId, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.expectEmit(true, true, false, true, address(adapter));
        emit ComposeFundsIn(
            bytes32("g"), opId, SOURCE_SENDER, customChainId, amount, RGB_CHAIN_ID, "b", EMPTY_SETTLEMENT_DATA
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32("g"), message, address(0), "");

        assertEq(bridge.lastSourceChainId(), customChainId, "sourceChainId forwarded to Bridge");
    }

    function test_lzCompose_settlementData_roundTrips() public {
        uint256 amount = 50e6;
        bytes memory data = hex"deadbeefcafe0001";
        token.mint(address(adapter), amount);

        bytes32 opId = keccak256("op-roundtrip");
        bridge.setOperationIdToReturn(opId);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), data, uint256(0))
        );

        bytes32 guid = bytes32("rt-guid");

        vm.expectEmit(true, true, false, true, address(adapter));
        emit ComposeFundsIn(guid, opId, SOURCE_SENDER, SOURCE_CHAIN_ID, amount, RGB_CHAIN_ID, "addr", data);

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        assertEq(bridge.lastSettlementData(), data, "settlementData byte-for-byte to Bridge");
    }

    function test_lzCompose_storesSettlementDataOnStuckRecord() public {
        bridge.setReverts(true);

        uint256 amount = 1e6;
        bytes memory data = hex"1234";
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), data, uint256(0))
        );

        bytes32 guid = bytes32("rt-stuck");

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.settlementData, data, "stuck settlementData preserved");
    }

    // =========================================================================
    // lzCompose — access control & failure paths
    // =========================================================================

    function test_lzCompose_revertsIfNotEndpoint() public {
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            1e6,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IUtexoLZAdapter.NotEndpoint.selector);
        adapter.lzCompose(address(oft), bytes32(0), message, address(0), "");
    }

    function test_lzCompose_revertsIfFromIsNotOft() public {
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            1e6,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        address wrongOft = makeAddr("not-oft");
        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.UnexpectedOft.selector, SRC_EID, wrongOft, address(oft)));
        adapter.lzCompose(wrongOft, bytes32(0), message, address(0), "");
    }

    function test_lzCompose_selectsOftBySourceEidAcrossMeshes() public {
        MockOFT legacyOft = new MockOFT(address(token));
        legacyOft.setPeer(LEGACY_EID, bytes32(uint256(0xBEEF)));

        vm.prank(multisigProxy);
        adapter.setOftRoute(LEGACY_EID, address(legacyOft));
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(LEGACY_EID, TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID);

        uint256 amount = 5e6;
        token.mint(address(adapter), amount);
        bytes memory message = _encodeCompose(
            uint64(1),
            LEGACY_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(
                SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("tron-user"), EMPTY_SETTLEMENT_DATA, uint256(0)
            )
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(legacyOft), bytes32("legacy-in"), message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), amount, "legacy route forwarded");
    }

    function test_lzCompose_rejectsOftConfiguredForDifferentEid() public {
        MockOFT legacyOft = new MockOFT(address(token));
        legacyOft.setPeer(LEGACY_EID, bytes32(uint256(0xBEEF)));

        vm.prank(multisigProxy);
        adapter.setOftRoute(LEGACY_EID, address(legacyOft));

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            1e6,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.UnexpectedOft.selector, SRC_EID, address(legacyOft), address(oft))
        );
        adapter.lzCompose(address(legacyOft), bytes32("wrong-mesh"), message, address(0), "");
    }

    function test_lzCompose_revertsWhenSourceEidHasNoOftRoute() public {
        uint32 unknownEid = 40_161;
        bytes memory message = _encodeCompose(
            uint64(1),
            unknownEid,
            1e6,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.OftRouteNotConfigured.selector, unknownEid));
        adapter.lzCompose(address(oft), bytes32("missing-route"), message, address(0), "");
    }

    /// @dev Allowance cleanup failure reverts compose before a recovery record is written.
    function test_lzCompose_revertsWhenAllowanceCleanupFails() public {
        ZeroApprovalRevertingERC20 badToken = new ZeroApprovalRevertingERC20();
        MockOFT badOft = new MockOFT(address(badToken));
        MockBridge badBridge = new MockBridge(address(badToken));
        badOft.setPeer(SRC_EID, bytes32(uint256(1)));
        UtexoLZAdapter badAdapter = _deploySingleRoute(
            endpoint, address(badToken), address(badBridge), multisigProxy, SRC_EID, address(badOft)
        );

        vm.prank(multisigProxy);
        badAdapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID);

        uint256 amount = 1e6;
        uint256 nativeValue = 0.005 ether;
        bytes32 guid = bytes32("cleanup-fail");

        badBridge.setReverts(true);
        badToken.mint(address(badAdapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, "tb1q-cleanup", EMPTY_SETTLEMENT_DATA, nativeValue)
        );

        vm.prank(endpoint);
        vm.expectRevert(bytes("ZeroApprovalRevertingERC20: zero approval"));
        badAdapter.lzCompose{value: nativeValue}(address(badOft), guid, message, address(0), "");

        assertEq(badToken.balanceOf(address(badAdapter)), amount, "adapter still holds tokens");
        assertEq(badToken.balanceOf(address(badBridge)), 0, "bridge unchanged");
        assertEq(address(badAdapter).balance, 0, "native value reverted");
        assertEq(badToken.allowance(address(badAdapter), address(badBridge)), 0, "allowance reverted");

        IUtexoLZAdapter.StuckFunds memory rec = badAdapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, "no stuck amount");
        assertEq(rec.nativeValue, 0, "no stuck native value");
        assertEq(rec.sourceSender, bytes32(0), "no stuck source sender");
    }

    /// @dev OFT dust conversion can credit zero tokens; native value must remain refundable.
    function test_lzCompose_zeroAmountRecordRefundsNativeValue() public {
        ZeroAmountBridge zeroBridge = new ZeroAmountBridge();
        UtexoLZAdapter zeroAdapter =
            _deploySingleRoute(endpoint, address(token), address(zeroBridge), multisigProxy, SRC_EID, address(oft));

        vm.prank(multisigProxy);
        zeroAdapter.setTrustedEntrypoint(SRC_EID, TRUSTED_ENTRYPOINT_B32, SOURCE_CHAIN_ID);

        uint256 nativeValue = 0.004 ether;
        bytes32 guid = bytes32("zero-credit");

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            0,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, "tb1q-zero", EMPTY_SETTLEMENT_DATA, nativeValue)
        );

        vm.expectEmit(true, true, false, true, address(zeroAdapter));
        emit ComposeFundsInFailed(
            guid,
            SOURCE_SENDER,
            SOURCE_CHAIN_ID,
            0,
            nativeValue,
            RGB_CHAIN_ID,
            "tb1q-zero",
            EMPTY_SETTLEMENT_DATA,
            abi.encodeWithSelector(ZeroAmountBridge.AmountBelowMinimum.selector, uint256(0), uint256(1))
        );

        vm.prank(endpoint);
        zeroAdapter.lzCompose{value: nativeValue}(address(oft), guid, message, address(0), "");

        assertEq(address(zeroAdapter).balance, nativeValue, "adapter holds native");
        assertEq(token.balanceOf(address(zeroAdapter)), 0, "no token amount credited");
        assertEq(token.allowance(address(zeroAdapter), address(zeroBridge)), 0, "allowance reset");

        IUtexoLZAdapter.StuckFunds memory rec = zeroAdapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, "zero stuck amount");
        assertEq(rec.nativeValue, nativeValue, "native value stored");
        assertEq(rec.sourceSender, SOURCE_SENDER, "source sender stored");
        assertEq(rec.sourceChainId, SOURCE_CHAIN_ID, "source chain stored");
        assertEq(rec.destinationChainId, RGB_CHAIN_ID, "destination chain stored");
        assertEq(rec.destinationAddress, "tb1q-zero", "destination stored");
        assertEq(rec.settlementData, EMPTY_SETTLEMENT_DATA, "settlement data stored");
        assertTrue(rec.isStuck, "zero-token record marked as stuck");
        assertTrue(zeroAdapter.hasStuckFunds(guid), "zero-token record exists");

        address refundTo = makeAddr("refundTo");
        vm.prank(multisigProxy);
        zeroAdapter.refundStuckFunds(guid, refundTo);

        assertEq(refundTo.balance, nativeValue, "native-only record refunded");
        assertEq(address(zeroAdapter).balance, 0, "adapter native balance cleared");
        assertFalse(zeroAdapter.hasStuckFunds(guid), "existence marker cleared");
    }

    /// @dev A caught Bridge rejection records this funded deposit and completes the compose.
    function test_lzCompose_storesStuckRecordIfBridgeReverts() public {
        bridge.setReverts(true);

        uint256 amount = 1e6;
        uint256 nativeValue = 0.005 ether;
        token.mint(address(adapter), amount);

        uint256 destChainId = RGB_CHAIN_ID;
        string memory destAddr = "tb1q-stuck";

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, destChainId, destAddr, EMPTY_SETTLEMENT_DATA, nativeValue)
        );

        bytes32 guid = bytes32("stuck-guid");

        // Check the indexed guid and source sender; revert-data preservation is tested separately.
        vm.expectEmit(true, true, false, false, address(adapter));
        emit ComposeFundsInFailed(
            guid, SOURCE_SENDER, SOURCE_CHAIN_ID, amount, nativeValue, destChainId, destAddr, EMPTY_SETTLEMENT_DATA, ""
        );

        vm.prank(endpoint);
        adapter.lzCompose{value: nativeValue}(address(oft), guid, message, address(0), "");

        // Funds did NOT leave the adapter — Bridge rejected the call.
        assertEq(token.balanceOf(address(bridge)), 0, "bridge unchanged");
        assertEq(token.balanceOf(address(adapter)), amount, "adapter still holds tokens");
        assertEq(address(adapter).balance, nativeValue, "adapter holds native");

        // Allowance from the failed attempt was reset to 0 so it does not
        // accumulate across compose calls with different guids.
        assertEq(token.allowance(address(adapter), address(bridge)), 0, "allowance reset");

        // Stuck record captured every field needed to drive a later refund.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "stuck amountLD");
        assertEq(rec.nativeValue, nativeValue, "stuck nativeValue");
        assertEq(rec.sourceSender, SOURCE_SENDER, "stuck sourceSender");
        assertEq(rec.sourceChainId, SOURCE_CHAIN_ID, "stuck sourceChainId");
        assertEq(rec.destinationChainId, destChainId, "stuck destChainId");
        assertEq(rec.destinationAddress, destAddr, "stuck destAddr");
        assertEq(rec.settlementData, EMPTY_SETTLEMENT_DATA, "stuck settlementData");
    }

    function test_lzCompose_happyPath_doesNotCreateStuckRecord() public {
        uint256 amount = 250e6;
        token.mint(address(adapter), amount);

        bytes32 guid = bytes32("happy-guid");
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, "no record on success");
        assertEq(rec.nativeValue, 0, "no record on success");
    }

    function test_lzCompose_duplicateGuidFailure_revertsAndPreservesRecord() public {
        bridge.setReverts(true);

        bytes32 guid = bytes32("dup-guid");

        // First failed compose parks a record under `guid`.
        uint256 amount1 = 1e6;
        token.mint(address(adapter), amount1);
        bytes memory message1 = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount1,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("first"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message1, address(0), "");

        IUtexoLZAdapter.StuckFunds memory first = adapter.getStuckFunds(guid);
        assertEq(first.amountLD, amount1, "record parked by first compose");
        assertEq(first.sourceSender, SOURCE_SENDER, "first sourceSender parked");

        // Second failed compose with the SAME guid but different fields must
        // revert, leaving the original record untouched.
        uint256 amount2 = 5e6;
        token.mint(address(adapter), amount2);
        bytes32 otherSender = bytes32(uint256(uint160(makeAddr("otherSender"))));
        bytes memory message2 = _encodeCompose(
            uint64(2),
            SRC_EID,
            amount2,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, otherSender, RGB_CHAIN_ID, string("second"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.StuckFundsAlreadyExist.selector, guid));
        adapter.lzCompose(address(oft), guid, message2, address(0), "");

        IUtexoLZAdapter.StuckFunds memory afterAttempt = adapter.getStuckFunds(guid);
        assertEq(afterAttempt.amountLD, amount1, "amountLD unchanged");
        assertEq(afterAttempt.sourceSender, SOURCE_SENDER, "sourceSender unchanged");
        assertEq(afterAttempt.destinationAddress, "first", "destAddr unchanged");
    }

    function test_lzCompose_parksOversizedSettlementDataWithoutStoringIt() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        uint256 cap = adapter.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory tooBig = new bytes(cap + 1);
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), tooBig, uint256(0))
        );

        bytes32 guid = bytes32("big-guid");
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "credited amount parked");
        assertEq(rec.destinationAddress, "addr", "bounded destination preserved");
        assertEq(rec.settlementData, "", "oversized settlement data omitted");
        assertEq(adapter.totalRecordedStuckToken(), amount, "parked amount reserved");
    }

    function test_lzCompose_acceptsSettlementDataAtMaxBoundary() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory atMax = new bytes(adapter.MAX_SETTLEMENT_DATA_LENGTH());
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), atMax, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32("ok-guid"), message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), amount, "forwarded to bridge at cap boundary");
        assertEq(adapter.getStuckFunds(bytes32("ok-guid")).amountLD, 0, "no stuck record at boundary");
    }

    function test_lzCompose_parksOversizedDestinationAddressWithoutStoringIt() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        uint256 cap = adapter.MAX_DESTINATION_ADDRESS_LENGTH();
        string memory tooLong = string(new bytes(cap + 1));
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, tooLong, EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32("long-addr-guid");
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "credited amount parked");
        assertEq(rec.destinationAddress, "", "oversized destination omitted");
        assertEq(rec.settlementData, EMPTY_SETTLEMENT_DATA, "bounded settlement data preserved");
        assertEq(adapter.totalRecordedStuckToken(), amount, "parked amount reserved");
    }

    function test_lzCompose_acceptsDestinationAddressAtMaxBoundary() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        string memory atMax = string(new bytes(adapter.MAX_DESTINATION_ADDRESS_LENGTH()));
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, atMax, EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32("ok-addr-guid"), message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), amount, "forwarded to bridge at cap boundary");
        assertEq(adapter.getStuckFunds(bytes32("ok-addr-guid")).amountLD, 0, "no stuck record at boundary");
    }

    function test_lzCompose_revertsOnComposeValueMismatch() public {
        uint256 amount = 1e6;
        uint256 expected = 0.01 ether; // what the depositor funded as the drop
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, expected)
        );

        vm.prank(endpoint);
        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.ComposeValueMismatch.selector, uint256(0.005 ether), expected)
        );
        adapter.lzCompose{value: 0.005 ether}(address(oft), bytes32("grief"), message, address(0), "");

        // Nothing parked; tokens untouched — the compose is retryable.
        assertEq(adapter.getStuckFunds(bytes32("grief")).amountLD, 0, "no stuck record");
        assertEq(token.balanceOf(address(bridge)), 0, "bridge untouched");
    }

    function test_lzCompose_valueMismatchRemainsPendingAndSucceedsOnRetry() public {
        uint256 amount = 1e6;
        uint256 expected = 0.01 ether;
        bytes32 guid = bytes32("retry-value");
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, expected)
        );
        _queueCompose(guid, message);

        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.ComposeValueMismatch.selector, uint256(0.005 ether), expected)
        );
        composeEndpoint.lzCompose{value: 0.005 ether}(address(oft), address(adapter), guid, 0, message, "");

        assertEq(
            composeEndpoint.composeQueue(address(oft), address(adapter), guid, 0),
            keccak256(message),
            "failed attempt remains queued"
        );
        assertEq(adapter.getStuckFunds(guid).amountLD, 0, "retryable mismatch not parked");

        composeEndpoint.lzCompose{value: expected}(address(oft), address(adapter), guid, 0, message, "");
        assertEq(token.balanceOf(address(bridge)), amount, "correct retry reaches Bridge");
        assertEq(
            composeEndpoint.composeQueue(address(oft), address(adapter), guid, 0),
            bytes32(uint256(1)),
            "correct retry consumes queue entry"
        );
    }

    function test_lzCompose_cannotSpendRecordedStuckReserve() public {
        uint256 amount = 1e6;
        _createStuckRecord(bytes32("reserved"), amount, 0, RGB_CHAIN_ID, "addr");

        bytes memory message = _encodeCompose(
            uint64(2),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("other"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.InsufficientUntrackedToken.selector, amount, 0));
        adapter.lzCompose(address(oft), bytes32("other-guid"), message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), 0, "reserve never reaches Bridge");
        assertEq(adapter.getStuckFunds(bytes32("reserved")).amountLD, amount, "reserve record unchanged");
    }

    function test_lzCompose_honestlyFundedButBridgeReverts_parksRecoverable() public {
        bridge.setReverts(true);

        uint256 amount = 1e6;
        uint256 expected = 0.01 ether;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, expected)
        );

        vm.prank(endpoint);
        adapter.lzCompose{value: expected}(address(oft), bytes32("honest-park"), message, address(0), "");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32("honest-park"));
        assertEq(rec.amountLD, amount, "honest deposit parked (recoverable)");
        assertEq(rec.nativeValue, expected, "parked native value");
    }

    function test_lzCompose_malformedPayload_parksRecoverableRecord() public {
        uint256 amount = 3e6;
        uint256 nativeValue = 0.004 ether;
        token.mint(address(adapter), amount);

        // Truncated business payload: cannot decode as the 6-field tuple.
        bytes memory badPayload = abi.encode(uint256(0xdeadbeef));
        bytes memory message = _encodeCompose(uint64(1), SRC_EID, amount, TRUSTED_ENTRYPOINT_B32, badPayload);

        bytes32 guid = bytes32("malformed-guid");

        vm.expectEmit(true, true, false, true, address(adapter));
        emit ComposeFundsInFailed(
            guid, bytes32(0), 0, amount, nativeValue, 0, "", "", bytes("malformed compose payload")
        );

        // Does NOT revert — the malformed compose is parked, not stranded.
        vm.prank(endpoint);
        adapter.lzCompose{value: nativeValue}(address(oft), guid, message, address(0), "");

        // Minimal recoverable record: only amountLD + nativeValue are known.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "parked amountLD");
        assertEq(rec.nativeValue, nativeValue, "parked nativeValue");
        assertEq(rec.sourceSender, bytes32(0), "sourceSender default");
        assertEq(rec.sourceChainId, 0, "sourceChainId default");
        assertEq(rec.destinationChainId, 0, "destChainId default");
        assertEq(rec.destinationAddress, "", "destAddr default");
        assertEq(rec.settlementData, "", "settlementData default");

        // Funds stayed on the adapter (not forwarded to the Bridge), recoverable
        // via refundStuckFunds.
        assertEq(token.balanceOf(address(adapter)), amount, "adapter still holds tokens");
        assertEq(token.balanceOf(address(bridge)), 0, "bridge untouched");
    }

    function test_lzCompose_malformedPayload_guidGuardRevertsOnSecond() public {
        token.mint(address(adapter), 5e6);
        bytes memory badPayload = abi.encode(uint256(1));
        bytes memory message = _encodeCompose(uint64(1), SRC_EID, 2e6, TRUSTED_ENTRYPOINT_B32, badPayload);
        bytes32 guid = bytes32("dup-malformed");

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.StuckFundsAlreadyExist.selector, guid));
        adapter.lzCompose(address(oft), guid, message, address(0), "");
    }

    // =========================================================================
    // sendOut — outbound (FundsOut) happy paths
    // =========================================================================

    function test_sendOut_happyPath_forwardsToOft() public {
        uint256 amount = 1_000e6;
        token.mint(address(adapter), amount);

        bytes memory extraOptions = hex"0003010011010000000000000000000000000000ea60";

        uint256 proxyBalBefore = multisigProxy.balance;

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode("mock-guid", uint64(1))), DST_EID, recipientB32, amount);

        // Set the transaction origin separately to check the OFT refund address.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, amount, amount, extraOptions);

        // OFT received the tokens and the routing parameters byte-for-byte.
        assertEq(token.balanceOf(address(oft)), amount, "oft holds tokens");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter cleared");
        assertEq(uint256(oft.lastDstEid()), DST_EID, "dstEid forwarded");
        assertEq(oft.lastTo(), recipientB32, "to forwarded");
        assertEq(oft.lastAmountLD(), amount, "amount forwarded");
        assertEq(oft.lastMinAmountLD(), amount, "minAmount forwarded");
        assertEq(oft.lastExtraOptions(), extraOptions, "extraOptions forwarded");
        assertEq(oft.lastComposeMsg().length, 0, "composeMsg empty");
        assertEq(oft.lastOftCmd().length, 0, "oftCmd empty");
        assertEq(oft.lastMsgValue(), NATIVE_FEE, "native fee forwarded");
        // The OFT refund recipient is the transaction origin.
        assertEq(oft.lastRefundAddress(), relayer, "refund addr = tx.origin");

        // Exact-fee call: proxy balance drops by exactly NATIVE_FEE.
        assertEq(multisigProxy.balance, proxyBalBefore - NATIVE_FEE, "no surplus expected");

        // Adapter holds nothing afterward.
        assertEq(token.allowance(address(adapter), address(oft)), 0, "oft allowance consumed");
        assertEq(address(adapter).balance, 0, "no native residue");
    }

    function test_sendOut_surplusNativeRefundedToTxOrigin() public {
        uint256 amount = 250e6;
        uint256 surplus = 0.05 ether;
        token.mint(address(adapter), amount);

        uint256 proxyBalBefore = multisigProxy.balance;
        uint256 relayerBalBefore = relayer.balance;

        // tx.origin = relayer → surplus is refunded to relayer.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE + surplus}(DST_EID, recipientB32, amount, amount, hex"0003");

        // Proxy paid the full msg.value (fee + surplus).
        assertEq(multisigProxy.balance, proxyBalBefore - NATIVE_FEE - surplus, "proxy paid fee + surplus");
        // Relayer received exactly the surplus as refund from the adapter.
        assertEq(relayer.balance, relayerBalBefore + surplus, "surplus refunded to tx.origin");
        assertEq(address(adapter).balance, 0, "no native residue");
    }

    function test_sendOut_emitsUniqueGuidPerCall() public {
        token.mint(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode("mock-guid", uint64(1))), DST_EID, recipientB32, 50e6);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, 50e6, 50e6, hex"0003");

        token.mint(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(keccak256(abi.encode("mock-guid", uint64(2))), DST_EID, recipientB32, 50e6);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, 50e6, 50e6, hex"0003");
    }

    function test_sendOut_selectsOftByDestinationEid() public {
        MockOFT legacyOft = new MockOFT(address(token));
        legacyOft.setPeer(LEGACY_EID, bytes32(uint256(0xBEEF)));
        legacyOft.setNativeFee(NATIVE_FEE);

        vm.prank(multisigProxy);
        adapter.setOftRoute(LEGACY_EID, address(legacyOft));

        uint256 amount = 9e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE}(LEGACY_EID, recipientB32, amount, amount, hex"0003");

        assertEq(token.balanceOf(address(legacyOft)), amount, "selected legacy OFT");
        assertEq(token.balanceOf(address(oft)), 0, "native OFT untouched");
        assertEq(legacyOft.lastDstEid(), LEGACY_EID, "destination EID forwarded");
    }

    // =========================================================================
    // sendOut — access control & input validation
    // =========================================================================

    function test_sendOut_revertsIfNotMultisigProxy() public {
        token.mint(address(adapter), 100e6);

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, 100e6, 100e6, hex"0003");
    }

    function test_sendOut_revertsOnZeroAmount() public {
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(IUtexoLZAdapter.ZeroAmount.selector);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, 0, 0, hex"0003");
    }

    function test_sendOut_revertsOnZeroRecipient() public {
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, bytes32(0), 100e6, 100e6, hex"0003");
    }

    function test_sendOut_revertsWhenDestinationEidHasNoOftRoute() public {
        uint32 unknownEid = 40_161;
        token.mint(address(adapter), 100e6);
        vm.prank(multisigProxy, relayer);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.OftRouteNotConfigured.selector, unknownEid));
        adapter.sendOut{value: NATIVE_FEE}(unknownEid, recipientB32, 100e6, 100e6, hex"0003");
    }

    function test_sendOut_cannotConsumeRecordedStuckFunds() public {
        uint256 stuckAmount = 10e6;
        _createStuckRecord(bytes32("send-protected"), stuckAmount, 0, RGB_CHAIN_ID, "addr");

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.InsufficientUntrackedToken.selector, stuckAmount, 0));
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, stuckAmount, stuckAmount, hex"0003");
    }

    function test_sendOut_canUseFreshBalanceWhileRecordedFundsRemainReserved() public {
        uint256 stuckAmount = 10e6;
        uint256 outboundAmount = 5e6;
        _createStuckRecord(bytes32("send-reserve"), stuckAmount, 0, RGB_CHAIN_ID, "addr");
        token.mint(address(adapter), outboundAmount);

        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, outboundAmount, outboundAmount, hex"0003");

        assertEq(token.balanceOf(address(adapter)), stuckAmount, "recorded balance remains");
        assertEq(adapter.totalRecordedStuckToken(), stuckAmount, "recorded reserve remains");
        assertEq(token.balanceOf(address(oft)), outboundAmount, "fresh balance sent");
    }

    function test_sendOut_revertsOnInsufficientNativeFee() public {
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.InsufficientNativeFee.selector, NATIVE_FEE - 1, NATIVE_FEE)
        );
        adapter.sendOut{value: NATIVE_FEE - 1}(DST_EID, recipientB32, 100e6, 100e6, hex"0003");
    }

    function test_sendOut_revertsIfOftReverts() public {
        oft.setSendReverts(true);
        token.mint(address(adapter), 100e6);

        vm.prank(multisigProxy, relayer);
        vm.expectRevert(bytes("MockOFT: forced revert"));
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, 100e6, 100e6, hex"0003");
    }

    /// @dev A rejecting transaction-origin fixture exercises native-refund failure.
    function test_sendOut_revertsIfRefundFails() public {
        RejectingRecipient rr = new RejectingRecipient();

        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, address(rr));
        vm.expectRevert(IUtexoLZAdapter.NativeRefundFailed.selector);
        adapter.sendOut{value: NATIVE_FEE + 1}(DST_EID, recipientB32, amount, amount, hex"0003");
    }

    function test_sendOut_exactFee_skipsRefundBranch() public {
        RejectingRecipient rr = new RejectingRecipient();

        uint256 amount = 100e6;
        token.mint(address(adapter), amount);

        vm.prank(multisigProxy, address(rr));
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, amount, amount, hex"0003");

        assertEq(token.balanceOf(address(oft)), amount, "tokens forwarded");
    }

    // =========================================================================
    // quoteSendOut
    // =========================================================================

    function test_quoteSendOut_matchesOft() public {
        oft.setNativeFee(0.0042 ether);
        uint256 fee = adapter.quoteSendOut(DST_EID, recipientB32, 1e6, 1e6, hex"0003");
        assertEq(fee, 0.0042 ether, "quote matches oft");
    }

    function test_quoteSendOut_selectsOftByDestinationEid() public {
        MockOFT legacyOft = new MockOFT(address(token));
        legacyOft.setPeer(LEGACY_EID, bytes32(uint256(0xBEEF)));
        legacyOft.setNativeFee(0.0077 ether);

        vm.prank(multisigProxy);
        adapter.setOftRoute(LEGACY_EID, address(legacyOft));

        uint256 fee = adapter.quoteSendOut(LEGACY_EID, recipientB32, 1e6, 1e6, hex"0003");
        assertEq(fee, 0.0077 ether, "legacy OFT quote selected");
    }

    // =========================================================================
    // Stuck-funds — getStuckFunds + refundStuckFunds
    // =========================================================================

    function test_getStuckFunds_returnsZeroForUnknownGuid() public view {
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(bytes32("unknown"));
        assertEq(rec.amountLD, 0, "amountLD");
        assertEq(rec.nativeValue, 0, "nativeValue");
        assertEq(rec.sourceSender, bytes32(0), "sourceSender");
        assertEq(rec.sourceChainId, 0, "sourceChainId");
        assertEq(rec.destinationChainId, 0, "destinationChainId");
        assertEq(rec.destinationAddress, "", "destinationAddress");
        assertEq(rec.settlementData, "", "settlementData");
        assertFalse(rec.isStuck, "isStuck");
    }

    function test_refundStuckFunds_happyPath_tokenAndNative() public {
        uint256 amount = 1_500e6;
        uint256 nativeValue = 0.02 ether;
        bytes32 guid = bytes32("to-refund");

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, "tb1q-bad");

        address payable refundTo = payable(makeAddr("refundTo"));
        uint256 tokenBalBefore = token.balanceOf(refundTo);
        uint256 nativeBalBefore = refundTo.balance;

        vm.expectEmit(true, true, false, true, address(adapter));
        emit StuckFundsRefunded(guid, refundTo, amount, nativeValue);

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        // Funds left the adapter and landed on the recipient.
        assertEq(token.balanceOf(refundTo), tokenBalBefore + amount, "tokens transferred");
        assertEq(refundTo.balance, nativeBalBefore + nativeValue, "native transferred");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter cleared of tokens");
        assertEq(address(adapter).balance, 0, "adapter cleared of native");

        // Record is gone.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, "record deleted");
        assertFalse(rec.isStuck, "record no longer marked as stuck");
    }

    function test_refundStuckFunds_rejectsSecondRefundForSameGuid() public {
        uint256 amount = 1_500e6;
        uint256 nativeValue = 0.02 ether;
        bytes32 guid = bytes32("single-use-refund");

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, "tb1q-once");

        address payable refundTo = payable(makeAddr("refundTo"));

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        uint256 tokenAfterFirst = token.balanceOf(refundTo);
        uint256 nativeAfterFirst = refundTo.balance;

        assertEq(tokenAfterFirst, amount, "first refund sent tokens");
        assertEq(nativeAfterFirst, nativeValue, "first refund sent native");

        vm.prank(multisigProxy);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.NoStuckFunds.selector, guid));
        adapter.refundStuckFunds(guid, refundTo);

        assertEq(token.balanceOf(refundTo), tokenAfterFirst, "second refund sends no tokens");
        assertEq(refundTo.balance, nativeAfterFirst, "second refund sends no native");
    }

    function test_refundStuckFunds_tokenOnlyWhenNativeValueIsZero() public {
        uint256 amount = 800e6;
        bytes32 guid = bytes32("token-only");

        _createStuckRecord(guid, amount, 0, RGB_CHAIN_ID, "addr");

        address refundTo = makeAddr("refundTo");

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        assertEq(token.balanceOf(refundTo), amount, "tokens transferred");
        assertEq(refundTo.balance, 0, "no native delivered");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter cleared");
    }

    function test_refundStuckFunds_doesNotSweepUntrackedToken() public {
        uint256 orphanAmount = 300e6;
        uint256 stuckAmount = 700e6;
        bytes32 guid = bytes32("partial-recovery");

        token.mint(address(adapter), orphanAmount);
        _createStuckRecord(guid, stuckAmount, 0, RGB_CHAIN_ID, "addr");

        address refundTo = makeAddr("refundTo");

        assertEq(token.balanceOf(address(adapter)), orphanAmount + stuckAmount, "pre adapter total");
        assertEq(token.balanceOf(refundTo), 0, "pre recipient");

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, refundTo);

        assertEq(token.balanceOf(refundTo), stuckAmount, "only stuck amount recovered");
        assertEq(token.balanceOf(address(adapter)), orphanAmount, "orphan balance remains");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, 0, "stuck record deleted");
    }

    function test_recoverPendingCompose_retryCannotSpendAnotherDepositsReserve() public {
        uint256 pendingAmount = 300e6;
        uint256 stuckAmount = 700e6;
        bytes32 stuckGuid = bytes32("protected-stuck");
        bytes32 pendingGuid = bytes32("pending-recovery");

        _createStuckRecord(stuckGuid, stuckAmount, 0, RGB_CHAIN_ID, "addr");
        token.mint(address(adapter), pendingAmount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            pendingAmount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        _queueCompose(pendingGuid, message);

        assertEq(adapter.totalRecordedStuckToken(), stuckAmount, "recorded reserve");
        assertEq(adapter.availableUntrackedToken(), pendingAmount, "only pending credit available");

        address recipient = makeAddr("recoveryRecipient");
        bytes32 key = adapter.composeKey(address(oft), pendingGuid, keccak256(message));
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PendingComposeRecovered(pendingGuid, key, address(oft), recipient, pendingAmount);

        vm.prank(multisigProxy);
        adapter.recoverPendingCompose(address(oft), pendingGuid, message, recipient);

        assertEq(token.balanceOf(recipient), pendingAmount, "pending credit recovered");
        assertEq(token.balanceOf(address(adapter)), stuckAmount, "recorded tokens protected");
        assertEq(adapter.totalRecordedStuckToken(), stuckAmount, "reserve unchanged");
        assertEq(adapter.getStuckFunds(stuckGuid).amountLD, stuckAmount, "record preserved");
        assertTrue(adapter.recoveredComposes(key), "terminal recovery marker stored");

        // The old queue entry remains executable, but adapter acknowledges it without
        // approving Bridge or consuming the unrelated stuck deposit.
        uint256 retryNative = 0.003 ether;
        uint256 relayerBalanceBefore = relayer.balance;
        vm.expectEmit(true, true, true, true, address(adapter));
        emit RecoveredComposeIgnored(pendingGuid, key, address(oft), retryNative);
        vm.prank(relayer);
        composeEndpoint.lzCompose{value: retryNative}(address(oft), address(adapter), pendingGuid, 0, message, "");

        assertEq(token.balanceOf(address(bridge)), 0, "recovered compose never reaches Bridge");
        assertEq(token.balanceOf(address(adapter)), stuckAmount, "retry leaves reserve intact");
        assertEq(relayer.balance, relayerBalanceBefore, "retry native value refunded to executor");
        assertEq(
            composeEndpoint.composeQueue(address(oft), address(adapter), pendingGuid, 0),
            bytes32(uint256(1)),
            "endpoint consumed recovered compose"
        );
    }

    function test_recoverPendingCompose_revertsBeforeConsumingRecordedFunds() public {
        uint256 pendingAmount = 300e6;
        uint256 stuckAmount = 700e6;
        _createStuckRecord(bytes32("protected"), stuckAmount, 0, RGB_CHAIN_ID, "addr");

        bytes32 guid = bytes32("underfunded-pending");
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            pendingAmount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        _queueCompose(guid, message);

        vm.prank(multisigProxy);
        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.InsufficientUntrackedToken.selector, pendingAmount, uint256(0))
        );
        adapter.recoverPendingCompose(address(oft), guid, message, makeAddr("recipient"));
    }

    function test_recoverPendingCompose_rejectsMessageHashMismatch() public {
        uint256 amount = 4_998_500;
        bytes32 guid = bytes32("hash-mismatch");
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        _queueCompose(guid, message);

        bytes memory otherMessage = _encodeCompose(
            uint64(2),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(multisigProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUtexoLZAdapter.ComposeNotPending.selector, guid, keccak256(message), keccak256(otherMessage)
            )
        );
        adapter.recoverPendingCompose(address(oft), guid, otherMessage, makeAddr("recipient"));
    }

    function test_recoverPendingCompose_rejectsAbsentAndDeliveredQueueEntries() public {
        uint256 amount = 1e6;
        bytes32 guid = bytes32("queue-state");
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(multisigProxy);
        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.ComposeNotPending.selector, guid, bytes32(0), keccak256(message))
        );
        adapter.recoverPendingCompose(address(oft), guid, message, makeAddr("absentRecipient"));

        token.mint(address(adapter), amount);
        _queueCompose(guid, message);
        composeEndpoint.lzCompose(address(oft), address(adapter), guid, 0, message, "");

        vm.prank(multisigProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUtexoLZAdapter.ComposeNotPending.selector, guid, bytes32(uint256(1)), keccak256(message)
            )
        );
        adapter.recoverPendingCompose(address(oft), guid, message, makeAddr("deliveredRecipient"));
    }

    function test_recoverPendingCompose_revertsIfNotMultisigProxy() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.recoverPendingCompose(address(oft), bytes32("guid"), hex"00", makeAddr("recipient"));
    }

    function test_recoverPendingCompose_revertsOnZeroRecipient() public {
        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.recoverPendingCompose(address(oft), bytes32("guid"), hex"00", address(0));
    }

    function test_recoverPendingCompose_rejectsSecondRecovery() public {
        uint256 amount = 1e6;
        bytes32 guid = bytes32("single-recovery");
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        token.mint(address(adapter), amount);
        _queueCompose(guid, message);

        vm.prank(multisigProxy);
        adapter.recoverPendingCompose(address(oft), guid, message, makeAddr("firstRecipient"));

        bytes32 key = adapter.composeKey(address(oft), guid, keccak256(message));
        vm.prank(multisigProxy);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.ComposeAlreadyRecovered.selector, key));
        adapter.recoverPendingCompose(address(oft), guid, message, makeAddr("secondRecipient"));
    }

    function test_recoverPendingCompose_supportsHistoricalOftAfterRouteRotation() public {
        uint256 amount = 2e6;
        bytes32 guid = bytes32("historical-oft");
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        token.mint(address(adapter), amount);
        _queueCompose(guid, message);

        MockOFT replacement = new MockOFT(address(token));
        replacement.setPeer(SRC_EID, bytes32(uint256(0xCAFE)));
        vm.prank(multisigProxy);
        adapter.setOftRoute(SRC_EID, address(replacement));

        address recipient = makeAddr("historicalRecipient");
        vm.prank(multisigProxy);
        adapter.recoverPendingCompose(address(oft), guid, message, recipient);
        assertEq(token.balanceOf(recipient), amount, "historical credit recovered");

        // Although the route now expects the replacement OFT, the terminal marker is
        // checked first so the old queue entry can be consumed without touching Bridge.
        composeEndpoint.lzCompose(address(oft), address(adapter), guid, 0, message, "");
        assertEq(token.balanceOf(address(bridge)), 0, "historical retry ignored");
    }

    function test_recoverPendingCompose_rejectsOftThatWasNeverConfigured() public {
        address unknownOft = makeAddr("unknownOft");
        vm.prank(multisigProxy);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.OftNotKnown.selector, unknownOft));
        adapter.recoverPendingCompose(unknownOft, bytes32("guid"), hex"00", makeAddr("recipient"));
    }

    function test_refundStuckFunds_decrementsRecordedReserve() public {
        uint256 amount = 700e6;
        bytes32 guid = bytes32("reserve-refund");
        _createStuckRecord(guid, amount, 0, RGB_CHAIN_ID, "addr");
        assertEq(adapter.totalRecordedStuckToken(), amount, "reserve created");

        vm.prank(multisigProxy);
        adapter.refundStuckFunds(guid, makeAddr("recipient"));

        assertEq(adapter.totalRecordedStuckToken(), 0, "reserve released");
        assertEq(adapter.availableUntrackedToken(), 0, "no residual surplus");
    }

    function test_refundStuckFunds_revertsIfNotMultisigProxy() public {
        bytes32 guid = bytes32("any");
        _createStuckRecord(guid, 1e6, 0, RGB_CHAIN_ID, "addr");

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.refundStuckFunds(guid, attacker);
    }

    function test_refundStuckFunds_revertsOnZeroRecipient() public {
        bytes32 guid = bytes32("any");
        _createStuckRecord(guid, 1e6, 0, RGB_CHAIN_ID, "addr");

        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidRecipient.selector);
        adapter.refundStuckFunds(guid, address(0));
    }

    function test_refundStuckFunds_revertsIfNoStuckFunds() public {
        bytes32 unknown = bytes32("unknown");
        vm.prank(multisigProxy);
        vm.expectRevert(abi.encodeWithSelector(IUtexoLZAdapter.NoStuckFunds.selector, unknown));
        adapter.refundStuckFunds(unknown, makeAddr("any"));
    }

    function test_refundStuckFunds_revertsAndPreservesRecordIfNativeRefundFails() public {
        uint256 amount = 100e6;
        uint256 nativeValue = 0.01 ether;
        bytes32 guid = bytes32("native-fail");

        _createStuckRecord(guid, amount, nativeValue, RGB_CHAIN_ID, "addr");

        RejectingRecipient rr = new RejectingRecipient();

        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.NativeRefundFailed.selector);
        adapter.refundStuckFunds(guid, address(rr));

        // Record + adapter balances preserved by the revert rollback.
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "record preserved");
        assertEq(rec.nativeValue, nativeValue, "record preserved");
        assertEq(token.balanceOf(address(adapter)), amount, "tokens preserved");
        assertEq(address(adapter).balance, nativeValue, "native preserved");
    }

    // =========================================================================
    // OFT route registry — setOftRoute
    // =========================================================================

    function test_setOftRoute_setsReplacesAndRevokesRoute() public {
        MockOFT legacyOft = new MockOFT(address(token));
        legacyOft.setPeer(LEGACY_EID, bytes32(uint256(0xBEEF)));

        vm.expectEmit(true, true, false, true, address(adapter));
        emit OftRouteSet(LEGACY_EID, address(legacyOft));
        vm.prank(multisigProxy);
        adapter.setOftRoute(LEGACY_EID, address(legacyOft));
        assertEq(adapter.oftByEid(LEGACY_EID), address(legacyOft), "route set");

        vm.expectEmit(true, true, false, true, address(adapter));
        emit OftRouteSet(LEGACY_EID, address(0));
        vm.prank(multisigProxy);
        adapter.setOftRoute(LEGACY_EID, address(0));
        assertEq(adapter.oftByEid(LEGACY_EID), address(0), "route revoked");
    }

    function test_setOftRoute_revertsIfNotMultisigProxy() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IUtexoLZAdapter.NotMultisigProxy.selector);
        adapter.setOftRoute(LEGACY_EID, address(oft));
    }

    function test_setOftRoute_revertsOnZeroEid() public {
        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidSrcEid.selector);
        adapter.setOftRoute(0, address(oft));
    }

    function test_setOftRoute_revertsForNonContractOft() public {
        vm.prank(multisigProxy);
        vm.expectRevert(IUtexoLZAdapter.InvalidOft.selector);
        adapter.setOftRoute(LEGACY_EID, makeAddr("not-contract"));
    }

    function test_setOftRoute_revertsWhenOftUsesDifferentToken() public {
        MockERC20 otherToken = new MockERC20("OTHER", "OTHER");
        MockOFT wrongTokenOft = new MockOFT(address(otherToken));
        wrongTokenOft.setPeer(LEGACY_EID, bytes32(uint256(0xBEEF)));

        vm.prank(multisigProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUtexoLZAdapter.OftTokenMismatch.selector, address(wrongTokenOft), address(otherToken), address(token)
            )
        );
        adapter.setOftRoute(LEGACY_EID, address(wrongTokenOft));
    }

    function test_setOftRoute_revertsWhenOftHasNoPeerForEid() public {
        MockOFT unconnectedOft = new MockOFT(address(token));

        vm.prank(multisigProxy);
        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.OftPeerNotConfigured.selector, address(unconnectedOft), LEGACY_EID)
        );
        adapter.setOftRoute(LEGACY_EID, address(unconnectedOft));
    }

    // =========================================================================
    // Trusted entrypoint registry — setTrustedEntrypoint
    // =========================================================================

    function test_setTrustedEntrypoint_setsAndUnsets() public {
        uint32 eid = 40161; // some other transport eid
        bytes32 ep = bytes32(uint256(0xC0FFEE));
        uint256 chain = 8453; // Chain A fixture

        // Initial state: nothing registered for this eid.
        assertEq(adapter.trustedEntrypoints(eid), bytes32(0), "starts unregistered");
        assertEq(adapter.eidToChainId(eid), 0, "starts unmapped");

        // Register: srcEid -> (entrypoint, chainId).
        vm.expectEmit(true, false, false, true, address(adapter));
        emit TrustedEntrypointSet(eid, ep, chain);

        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(eid, ep, chain);
        assertEq(adapter.trustedEntrypoints(eid), ep, "entrypoint set");
        assertEq(adapter.eidToChainId(eid), chain, "chainId set");

        // Revoke: entrypoint == 0 clears both halves of the binding.
        vm.expectEmit(true, false, false, true, address(adapter));
        emit TrustedEntrypointSet(eid, bytes32(0), 0);

        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(eid, bytes32(0), 0);
        assertEq(adapter.trustedEntrypoints(eid), bytes32(0), "entrypoint cleared");
        assertEq(adapter.eidToChainId(eid), 0, "chainId cleared");
    }

    function test_setTrustedEntrypoint_revertsIfNotMultisigProxy() public {
        bytes32 ep = bytes32(uint256(0xC0FFEE));
        address attacker = makeAddr("attacker");

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

    function test_lzCompose_parksUntrustedComposeSource() public {
        bytes32 attackerB32 = bytes32(uint256(0xBADBAD));
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            attackerB32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("a"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32("x");
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        // The configured OFT already authenticated the token credit, so the permanent
        // entrypoint mismatch is parked and the endpoint can consume the compose.
        assertEq(token.balanceOf(address(bridge)), 0, "bridge untouched");
        assertEq(token.balanceOf(address(adapter)), amount, "adapter still holds tokens");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "credited amount parked");
        assertEq(rec.sourceSender, bytes32(0), "untrusted business payload not decoded");
        assertEq(adapter.totalRecordedStuckToken(), amount, "parked amount reserved");
    }

    function test_lzCompose_permanentFailureParksAndConsumesEndpointQueue() public {
        bytes32 attackerB32 = bytes32(uint256(0xBADBAD));
        uint256 amount = 1e6;
        bytes32 guid = bytes32("terminal-park");
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            attackerB32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("a"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        _queueCompose(guid, message);

        composeEndpoint.lzCompose(address(oft), address(adapter), guid, 0, message, "");

        assertEq(adapter.getStuckFunds(guid).amountLD, amount, "permanent failure parked");
        assertEq(
            composeEndpoint.composeQueue(address(oft), address(adapter), guid, 0),
            bytes32(uint256(1)),
            "endpoint consumed terminal failure"
        );
    }

    function test_lzCompose_permanentFailureCannotCreateUndercollateralizedReserve() public {
        uint256 stuckAmount = 700e6;
        uint256 pendingAmount = 300e6;
        bytes32 pendingGuid = bytes32("spent-pending");
        _createStuckRecord(bytes32("existing-reserve"), stuckAmount, 0, RGB_CHAIN_ID, "addr");

        // Model an OFT credit whose compose has not executed yet.
        token.mint(address(adapter), pendingAmount);
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            pendingAmount,
            bytes32(uint256(0xBADBAD)),
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("a"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );
        _queueCompose(pendingGuid, message);

        // Governance spends only the currently unreserved balance. The compose credit
        // is therefore no longer available to collateralize a new stuck record.
        vm.prank(multisigProxy, relayer);
        adapter.sendOut{value: NATIVE_FEE}(DST_EID, recipientB32, pendingAmount, pendingAmount, "");
        assertEq(token.balanceOf(address(adapter)), stuckAmount, "only existing reserve remains");
        assertEq(adapter.totalRecordedStuckToken(), stuckAmount, "existing reserve unchanged");

        vm.expectRevert(
            abi.encodeWithSelector(IUtexoLZAdapter.InsufficientUntrackedToken.selector, pendingAmount, uint256(0))
        );
        composeEndpoint.lzCompose(address(oft), address(adapter), pendingGuid, 0, message, "");

        assertFalse(adapter.hasStuckFunds(pendingGuid), "insolvent record not created");
        assertEq(adapter.totalRecordedStuckToken(), stuckAmount, "reserve remains solvent");
        assertGe(token.balanceOf(address(adapter)), adapter.totalRecordedStuckToken(), "reserve fully collateralized");
        assertEq(
            composeEndpoint.composeQueue(address(oft), address(adapter), pendingGuid, 0),
            keccak256(message),
            "insolvent compose remains retryable"
        );
    }

    function test_lzCompose_parksWhenTrustedEntrypointRevoked() public {
        // Revoke the binding that `setUp` registered for SRC_EID.
        vm.prank(multisigProxy);
        adapter.setTrustedEntrypoint(SRC_EID, bytes32(0), 0);

        uint256 amount = 1e6;
        token.mint(address(adapter), amount);
        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("b"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32("y");
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        assertEq(adapter.getStuckFunds(guid).amountLD, amount, "revoked route credit parked");
    }

    // =========================================================================
    // Source EID binding
    // =========================================================================

    function test_lzCompose_parksOnSourceChainIdMismatch() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        // Keep the trusted entrypoint but declare a different source chain id.
        uint256 wrongChainId = SOURCE_CHAIN_ID + 999;

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(wrongChainId, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32("mismatch");
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), 0, "bridge untouched");
        assertEq(token.balanceOf(address(adapter)), amount, "adapter still holds tokens");
        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "mismatched delivery parked");
        assertEq(rec.sourceChainId, wrongChainId, "declared source chain retained for diagnosis");
    }

    function test_lzCompose_parksWhenEntrypointTrustedForDifferentSrcEid() public {
        uint32 otherEid = 40161; // not registered in setUp
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        // Leave the source identity unregistered for this EID.
        oft.setPeer(otherEid, bytes32(uint256(3)));
        vm.prank(multisigProxy);
        adapter.setOftRoute(otherEid, address(oft));

        // Reuse the entrypoint bytes under an EID that has no trusted binding.
        bytes memory message = _encodeCompose(
            uint64(1),
            otherEid,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32("wrong-eid");
        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), 0, "bridge untouched");
        assertEq(token.balanceOf(address(adapter)), amount, "adapter still holds tokens");
        assertEq(adapter.getStuckFunds(guid).amountLD, amount, "unregistered entrypoint credit parked");
    }

    function test_lzCompose_succeedsWhenSrcEidEntrypointAndChainIdAllMatch() public {
        uint256 amount = 1e6;
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, RGB_CHAIN_ID, string("addr"), EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), bytes32("ok"), message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), amount, "bridge received tokens");
        assertEq(bridge.lastSourceChainId(), SOURCE_CHAIN_ID, "sourceChainId forwarded");
    }

    // =========================================================================
    // lzCompose — credited amount accounting
    // =========================================================================

    /// @dev The compose envelope supplies the credited amount, independently of existing balance.
    function test_lzCompose_usesCreditedAmountNotSourceRequestedAmount() public {
        uint256 sourceRequestedAmount = 10e6;
        uint256 creditedAmount = 7e6;
        token.mint(address(adapter), sourceRequestedAmount);

        uint256 destChainId = RGB_CHAIN_ID;
        string memory destAddr = "tb1q-credited";

        bytes32 opId = keccak256("op-credited");
        bridge.setOperationIdToReturn(opId);

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            creditedAmount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, destChainId, destAddr, EMPTY_SETTLEMENT_DATA, uint256(0))
        );

        bytes32 guid = bytes32("credited-guid");

        vm.expectEmit(true, true, false, true, address(adapter));
        emit ComposeFundsIn(
            guid, opId, SOURCE_SENDER, SOURCE_CHAIN_ID, creditedAmount, destChainId, destAddr, EMPTY_SETTLEMENT_DATA
        );

        vm.prank(endpoint);
        adapter.lzCompose(address(oft), guid, message, address(0), "");

        assertEq(bridge.lastAmount(), creditedAmount, "credited amount forwarded");
        assertEq(token.balanceOf(address(bridge)), creditedAmount, "bridge receives credited amount");
        assertEq(
            token.balanceOf(address(adapter)), sourceRequestedAmount - creditedAmount, "adapter retains excess balance"
        );
        assertEq(token.allowance(address(adapter), address(bridge)), 0, "allowance consumed");
    }

    // =========================================================================
    // lzCompose — Bridge revert reason regression
    // =========================================================================

    function test_lzCompose_bridgeRevertReasonPreserved() public {
        bridge.setReverts(true);

        uint256 amount = 3e6;
        uint256 nativeValue = 0.007 ether;
        token.mint(address(adapter), amount);

        bytes32 guid = bytes32("reason-guid");
        uint256 destChainId = RGB_CHAIN_ID;
        string memory destAddr = "tb1q-reason";
        bytes memory settlementData = hex"feedbeef";
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "MockBridge: forced revert");

        bytes memory message = _encodeCompose(
            uint64(1),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, destChainId, destAddr, settlementData, nativeValue)
        );

        vm.expectEmit(true, true, false, true, address(adapter));
        emit ComposeFundsInFailed(
            guid,
            SOURCE_SENDER,
            SOURCE_CHAIN_ID,
            amount,
            nativeValue,
            destChainId,
            destAddr,
            settlementData,
            expectedReason
        );

        vm.prank(endpoint);
        adapter.lzCompose{value: nativeValue}(address(oft), guid, message, address(0), "");

        assertEq(token.balanceOf(address(bridge)), 0, "bridge unchanged");
        assertEq(token.balanceOf(address(adapter)), amount, "adapter still holds tokens");
        assertEq(address(adapter).balance, nativeValue, "adapter holds native");
        assertEq(token.allowance(address(adapter), address(bridge)), 0, "allowance reset");

        IUtexoLZAdapter.StuckFunds memory rec = adapter.getStuckFunds(guid);
        assertEq(rec.amountLD, amount, "stuck amountLD");
        assertEq(rec.nativeValue, nativeValue, "stuck nativeValue");
        assertEq(rec.sourceSender, SOURCE_SENDER, "stuck sourceSender");
        assertEq(rec.sourceChainId, SOURCE_CHAIN_ID, "stuck sourceChainId");
        assertEq(rec.destinationChainId, destChainId, "stuck destChainId");
        assertEq(rec.destinationAddress, destAddr, "stuck destAddr");
        assertEq(rec.settlementData, settlementData, "stuck settlementData");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _queueCompose(bytes32 guid, bytes memory message) internal {
        vm.prank(address(oft));
        composeEndpoint.sendCompose(address(adapter), guid, 0, message);
    }

    function _deploySingleRoute(
        address endpoint_,
        address token_,
        address bridge_,
        address multisigProxy_,
        uint32 eid_,
        address oft_
    ) internal returns (UtexoLZAdapter deployed) {
        uint32[] memory eids = new uint32[](1);
        eids[0] = eid_;
        address[] memory ofts = new address[](1);
        ofts[0] = oft_;
        deployed = new UtexoLZAdapter(endpoint_, token_, bridge_, multisigProxy_, eids, ofts);
    }

    /// @dev Records a failed deposit through the reverting Bridge fixture.
    function _createStuckRecord(
        bytes32 guid,
        uint256 amount,
        uint256 nativeValue,
        uint256 destChainId,
        string memory destAddr
    ) internal {
        bridge.setReverts(true);
        token.mint(address(adapter), amount);

        bytes memory message = _encodeCompose(
            uint64(0),
            SRC_EID,
            amount,
            TRUSTED_ENTRYPOINT_B32,
            abi.encode(SOURCE_CHAIN_ID, SOURCE_SENDER, destChainId, destAddr, EMPTY_SETTLEMENT_DATA, nativeValue)
        );

        vm.prank(endpoint);
        adapter.lzCompose{value: nativeValue}(address(oft), guid, message, address(0), "");
    }

    /// @dev OFT envelope: nonce (8 bytes), source EID (4), amount (32), composeFrom (32), then payload.
    function _encodeCompose(
        uint64 nonce_,
        uint32 srcEid_,
        uint256 amountLD_,
        bytes32 composeFrom_,
        bytes memory businessPayload
    ) internal pure returns (bytes memory) {
        return OFTComposeMsgCodec.encode(nonce_, srcEid_, amountLD_, abi.encodePacked(composeFrom_, businessPayload));
    }
}

/// @dev Rejects native refunds when used as a transaction-origin fixture.
contract RejectingRecipient {}
