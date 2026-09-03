// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 }    from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { IOAppComposer }      from '@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppComposer.sol';
import { ILayerZeroComposer } from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol';
import { OFTComposeMsgCodec } from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol';

import { IOFT, SendParam }                  from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol';
import { MessagingFee, MessagingReceipt }   from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol';

import { IUtexoLZAdapter } from './interfaces/IUtexoLZAdapter.sol';
import { IBridge }         from '@bridge-smart-contracts/interfaces/IBridge.sol';

/// @dev Minimal OApp-core view used to ensure a candidate local OFT is wired to
///      a remote peer for the EID it is being registered against.
interface IOftPeerView {
    function peers(uint32 eid) external view returns (bytes32);
}

/// @title UtexoLZAdapter
/// @notice Bidirectional adapter between the Utexo `Bridge` (on Arbitrum) and the
///         USDT0 OFT / LayerZero V2 stack. Lives in the USDT0 layer repo so the
///         core security contracts (Bridge, MultisigProxy, CommissionManager) stay
///         free of LayerZero dependencies.
///
/// @dev Two flows are supported:
///
///      ┌──────────────────────────── Inbound (FundsIn) ───────────────────────────┐
///      │  LayerZero ──► OFT.lzReceive (mints USDT0 to this contract)              │
///      │                                                                          │
///      │  LayerZero ──► UtexoLZAdapter.lzCompose                                  │
///      │                  │                                                       │
///      │                  ├─► validate endpoint + OFT selected by srcEid         │
///      │                  ├─► validate composeFrom == trustedEntrypoints[srcEid]  │
///      │                  ├─► decode amountLD + business payload                  │
///      │                  ├─► validate eidToChainId[srcEid] == sourceChainId      │
///      │                  ├─► approve Bridge for amountLD                         │
///      │                  ├─► try Bridge.fundsIn{value: msg.value}                │
///      │                  │     • on success: emit ComposeFundsIn                 │
///      │                  │     • on revert : park funds in _stuckFunds[guid],    │
///      │                  │                   emit ComposeFundsInFailed,          │
///      │                  │                   return ok (frees the LZ queue)     │
///      │                  └─► release via refundStuckFunds (federation only)      │
///      └──────────────────────────────────────────────────────────────────────────┘
///
///      ┌──────────────────────────── Outbound (FundsOut) ─────────────────────────┐
///      │  MultisigProxy.executeBatch ──► [0] Bridge.fundsOut(recipient = adapter)│
///      │                            └──► [1] UtexoLZAdapter.sendOut               │
///      │                                       │                                  │
///      │                                       ├─► validate msg.sender == proxy   │
///      │                                       ├─► re-quote LZ fee on-chain       │
///      │                                       ├─► approve OFT for amount         │
///      │                                       └─► OFT.send(SendParam{...})       │
///      └──────────────────────────────────────────────────────────────────────────┘
///
///      The endpoint, token, Bridge and MultisigProxy addresses are immutable.
///      OFTs are selected per LayerZero EID because USDT0's native and legacy
///      meshes can coexist on the same local chain while serving different
///      remote chains. OFT routes are governed by `MultisigProxy`.
contract UtexoLZAdapter is IUtexoLZAdapter, IOAppComposer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Upper bound on the inbound `settlementData` byte length.
    ///         `settlementData` is plumbed through to the destination route's
    ///         `SettlementModule.onFundsIn` and, on the failure path, written to
    ///         `_stuckFunds[guid]` storage. An unbounded blob
    ///         from a buggy/compromised entrypoint could make the catch-branch
    ///         storage write exhaust the LayerZero Executor gas budget. LZ-adapter
    ///         routes carry only a small blob (the RGB route's `abi.encode(uint256
    ///         rgbOpId)` is 32 bytes; empty for routes needing none), so 1024
    ///         bytes is ample headroom. The same cap is mirrored on the
    ///         source-chain `UtexoSourceEntrypoint`.
    uint256 public constant MAX_SETTLEMENT_DATA_LENGTH = 1024;

    /// @notice Upper bound on the inbound `destinationAddress` byte length.
    ///         It is forwarded into `Bridge.fundsIn` (which itself caps at
    ///         `MAX_ADDRESS_LENGTH = 512`), re-emitted in `ComposeFundsIn`, and
    ///         written to `_stuckFunds[guid]` on the failure path. Bounding it
    ///         here keeps the cap aligned with the Bridge and the source-chain
    ///         `UtexoSourceEntrypoint`, and stops an oversized value from
    ///         inflating event logs or stuck-funds storage.
    uint256 public constant MAX_DESTINATION_ADDRESS_LENGTH = 512;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override endpoint;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override token;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override bridge;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override multisigProxy;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    mapping(uint32 eid => address oft) public override oftByEid;

    /// @notice Trusted source registry, keyed by the LayerZero transport source
    ///         id (`srcEid`) rather than by raw caller address. For each `srcEid`
    ///         it stores the single entrypoint allowed to drive `lzCompose` from
    ///         that transport origin. `lzCompose` accepts a call only if
    ///         `OFTComposeMsgCodec.composeFrom(_message)` equals the entrypoint
    ///         registered for the message's `srcEid`.
    ///
    ///         `srcEid` is stamped by the LayerZero protocol (not by the payload
    ///         author), so binding trust to it — instead of to a bare address —
    ///         means an entrypoint trusted for one source chain cannot have its
    ///         messages honoured as if they arrived from another, and trust no
    ///         longer survives an address being reused/resurrected elsewhere.
    ///
    ///         Entrypoint stored as `bytes32` so the same registry works for EVM
    ///         (address left-padded) and non-EVM source chains (full 32-byte
    ///         address). `bytes32(0)` means "no trusted entrypoint for this
    ///         srcEid". Maintained by federation governance via
    ///         `setTrustedEntrypoint` (callable only by `multisigProxy`).
    mapping(uint32 srcEid => bytes32 entrypoint) public override trustedEntrypoints;

    /// @notice Expected business `sourceChainId` for each LayerZero `srcEid`.
    ///         `lzCompose` requires the self-declared `sourceChainId` carried in
    ///         the payload to equal this value. Because `sourceChainId` selects
    ///         the destination route (settlement module + verifier) and the
    ///         commission rule, pinning it to the transport origin stops a
    ///         compromised/buggy entrypoint from declaring an arbitrary source
    ///         chain for a real deposit. `0` means "unregistered srcEid".
    ///         Set together with `trustedEntrypoints` via `setTrustedEntrypoint`.
    mapping(uint32 srcEid => uint256 chainId) public override eidToChainId;

    /// @dev Records of inbound compose payloads whose `Bridge.fundsIn` call
    ///      reverted. Keyed by LayerZero compose guid (unique per packet).
    mapping(bytes32 guid => StuckFunds) internal _stuckFunds;

    /// @inheritdoc IUtexoLZAdapter
    uint256 public override totalRecordedStuckToken;

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to `multisigProxy`. The proxy itself gates
    ///      each call behind federation governance (M-of-N + timelock), so a
    ///      function carrying this modifier is effectively a federation-only
    ///      administrative entrypoint.
    modifier onlyMultisigProxy() {
        if (msg.sender != multisigProxy) revert NotMultisigProxy();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param endpoint_      LayerZero V2 EndpointV2 on Arbitrum.
    /// @param token_         USDT0 token on Arbitrum.
    /// @param bridge_        Utexo `Bridge` contract on Arbitrum.
    /// @param multisigProxy_ Utexo `MultisigProxy`.
    /// @param oftEids_       LayerZero EIDs to configure atomically at deploy.
    /// @param ofts_          Local USDT0 OFTs corresponding to `oftEids_`.
    constructor(
        address endpoint_,
        address token_,
        address bridge_,
        address multisigProxy_,
        uint32[] memory oftEids_,
        address[] memory ofts_
    ) {
        if (endpoint_      == address(0)) revert InvalidEndpoint();
        if (token_         == address(0)) revert InvalidToken();
        if (bridge_        == address(0)) revert InvalidBridge();
        if (multisigProxy_ == address(0)) revert InvalidMultisigProxy();
        if (oftEids_.length == 0) revert NoOftRoutes();
        if (oftEids_.length != ofts_.length) {
            revert OftRouteLengthMismatch(oftEids_.length, ofts_.length);
        }

        endpoint      = endpoint_;
        token         = token_;
        bridge        = bridge_;
        multisigProxy = multisigProxy_;

        for (uint256 i; i < oftEids_.length; ++i) {
            if (ofts_[i] == address(0)) revert InvalidOft();
            for (uint256 j; j < i; ++j) {
                if (oftEids_[i] == oftEids_[j]) revert DuplicateOftRoute(oftEids_[i]);
            }
            _setOftRoute(oftEids_[i], ofts_[i]);
        }
    }

    // =========================================================================
    // Inbound — LayerZero compose hook
    // =========================================================================

    /// @inheritdoc ILayerZeroComposer
    /// @dev Tokens have already been credited to this contract by `OFT._lzReceive`.
    ///      This call decodes the compose payload and forwards it into
    ///      `Bridge.fundsIn`. If the forwarded call reverts the payload is
    ///      captured under `_stuckFunds[_guid]` and an `ComposeFundsInFailed`
    ///      event is emitted — `lzCompose` itself returns successfully so the
    ///      LayerZero endpoint clears its compose queue and stops retrying.
    ///      The parked funds can later be released to a federation-approved
    ///      recipient via `refundStuckFunds`.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes   calldata _message,
        address /*_executor*/,
        bytes   calldata /*_extraData*/
    )
        external
        payable
        override
        nonReentrant
    {
        if (msg.sender != endpoint) revert NotEndpoint();

        // A single Arbitrum token can be served by more than one USDT0 mesh.
        // Select the expected local OFT from the protocol-stamped source EID,
        // then bind `_from` to that exact route before processing the payload.
        uint32 srcEid_ = OFTComposeMsgCodec.srcEid(_message);
        address expectedOft = _requireOftRoute(srcEid_);
        if (_from != expectedOft) revert UnexpectedOft(srcEid_, _from, expectedOft);

        // 1. Bind trust to the LayerZero transport origin. `srcEid` is stamped by
        //    the LayerZero protocol (not by the payload author) and is therefore
        //    non-spoofable. Accept the packet only if its `composeFrom` matches
        //    the single entrypoint registered for that `srcEid`; an unregistered
        //    srcEid (expected == 0) is rejected.
        bytes32 composeFrom_ = OFTComposeMsgCodec.composeFrom(_message);
        bytes32 expected     = trustedEntrypoints[srcEid_];
        if (expected == bytes32(0) || composeFrom_ != expected) {
            revert UntrustedComposeSource(srcEid_, composeFrom_);
        }

        // 2. Decode the LayerZero transport envelope (always well-formed).
        uint256 amountLD     = OFTComposeMsgCodec.amountLD(_message);
        bytes memory payload = OFTComposeMsgCodec.composeMsg(_message);

        // 3. Decode the business payload behind an external self-call so a
        //    malformed payload (from a buggy or compromised trusted entrypoint)
        //    is caught and parked as a recoverable record — instead of reverting
        //    before any `_stuckFunds` anchor exists, which would strand the
        //    OFT-credited USDT0. A bare `abi.decode` cannot be wrapped in
        //    try/catch, hence the external `decodeComposeMsg` helper.
        try this.decodeComposeMsg(payload) returns (
            uint256 sourceChainId,
            bytes32 sourceSender,
            uint256 destinationChainId,
            string memory destinationAddress,
            bytes memory settlementData,
            uint256 expectedComposeValue
        ) {
            _composeIn(
                _guid, srcEid_, amountLD, sourceChainId, sourceSender, destinationChainId,
                destinationAddress, settlementData, expectedComposeValue
            );
        } catch {
            _parkUndecodableCompose(_guid, amountLD);
        }
    }

    /// @notice External pure decoder that exists only so `lzCompose` can wrap the
    ///         business-payload `abi.decode` in try/catch (a bare `abi.decode`
    ///         is not catchable). Reverts on a malformed payload; the caller
    ///         turns that revert into a recoverable `_stuckFunds` record.
    function decodeComposeMsg(bytes calldata payload)
        external
        pure
        returns (
            uint256 sourceChainId,
            bytes32 sourceSender,
            uint256 destinationChainId,
            string  memory destinationAddress,
            bytes   memory settlementData,
            uint256 expectedComposeValue
        )
    {
        return abi.decode(payload, (uint256, bytes32, uint256, string, bytes, uint256));
    }

    /// @dev Validate the decoded compose fields, forward into `Bridge.fundsIn`,
    ///      and — if the Bridge rejects the call — park a full recoverable record
    ///      under `_stuckFunds[guid]`. Input-validation failures (caps, srcEid,
    ///      native value) revert so LayerZero can retry; only a Bridge revert
    ///      parks. Reached only after a successful payload decode.
    function _composeIn(
        bytes32 guid,
        uint32  srcEid_,
        uint256 amountLD,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string  memory destinationAddress,
        bytes   memory settlementData,
        uint256 expectedComposeValue
    ) private {
        // Bound the decoded inputs before they are plumbed onward / stored.
        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (bytes(destinationAddress).length > MAX_DESTINATION_ADDRESS_LENGTH) {
            revert DestinationAddressTooLong(bytes(destinationAddress).length, MAX_DESTINATION_ADDRESS_LENGTH);
        }
        // Bind the self-declared `sourceChainId` to the transport origin.
        if (eidToChainId[srcEid_] != sourceChainId) {
            revert SourceChainIdMismatch(srcEid_, sourceChainId);
        }
        // Anti-grief: the forwarded native value must equal the drop the
        // depositor budgeted (bound in `composeMsg`). A wrong `msg.value` reverts
        // so LayerZero retries with the funded value rather than parking.
        if (msg.value != expectedComposeValue) {
            revert ComposeValueMismatch(msg.value, expectedComposeValue);
        }

        // Approve Bridge to pull the USDT0 credited by `OFT._lzReceive`, then
        // forward. If the Bridge rejects the call (paused, route disabled,
        // settlement/native-value mismatch, …) the funds are parked and
        // recoverable off the hot path.
        IERC20(token).safeIncreaseAllowance(bridge, amountLD);

        try IBridge(bridge).fundsIn{ value: msg.value }(
            amountLD,
            sourceChainId,
            sourceSender,
            destinationChainId,
            destinationAddress,
            settlementData
        ) returns (bytes32 operationId) {
            emit ComposeFundsIn(
                guid, operationId, sourceSender, sourceChainId, amountLD,
                destinationChainId, destinationAddress, settlementData
            );
        } catch (bytes memory reason) {
            // Bridge did not pull the approved allowance — reset it so the
            // unconsumed approval cannot accumulate across repeated failures.
            IERC20(token).forceApprove(bridge, 0);

            // Never overwrite an existing parked record (unique-guid guard).
            if (_stuckFunds[guid].amountLD != 0) revert StuckFundsAlreadyExist(guid);

            _stuckFunds[guid] = StuckFunds({
                amountLD:           amountLD,
                nativeValue:        msg.value,
                sourceSender:       sourceSender,
                sourceChainId:      sourceChainId,
                destinationChainId: destinationChainId,
                destinationAddress: destinationAddress,
                settlementData:     settlementData
            });
            totalRecordedStuckToken += amountLD;

            emit ComposeFundsInFailed(
                guid, sourceSender, sourceChainId, amountLD, msg.value,
                destinationChainId, destinationAddress, settlementData, reason
            );
        }
    }

    /// @dev A malformed compose payload cannot be decoded, so no business fields
    ///      are known. Record only the OFT-credited `amountLD` and the forwarded
    ///      native — enough for `refundStuckFunds` to release both. The remaining
    ///      fields stay at their zero/empty storage defaults.
    function _parkUndecodableCompose(bytes32 guid, uint256 amountLD) private {
        StuckFunds storage record = _stuckFunds[guid];
        if (record.amountLD != 0) revert StuckFundsAlreadyExist(guid);

        record.amountLD    = amountLD;
        record.nativeValue = msg.value;
        totalRecordedStuckToken += amountLD;

        emit ComposeFundsInFailed(
            guid, bytes32(0), 0, amountLD, msg.value, 0, '', '', bytes('malformed compose payload')
        );
    }

    // =========================================================================
    // Outbound — MultisigProxy-only OFT send
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function sendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    )
        external
        payable
        override
        onlyMultisigProxy
        nonReentrant
    {
        if (amount    == 0)          revert ZeroAmount();
        if (recipient == bytes32(0)) revert InvalidRecipient();

        // A normal outbound batch first transfers fresh Bridge liquidity to
        // this adapter. Do not let `sendOut` consume token amounts reserved by
        // failed inbound compose records already held at the same address.
        uint256 available = availableUntrackedToken();
        if (amount > available) revert InsufficientUntrackedToken(amount, available);

        address oft_ = _requireOftRoute(dstEid);

        // 1. Build the LayerZero send parameters. `composeMsg` is empty — we are
        //    delivering plain USDT0 to the user, not invoking any compose hook on
        //    the destination.
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           recipient,
            amountLD:     amount,
            minAmountLD:  minAmountLD,
            extraOptions: extraOptions,
            composeMsg:   '',
            oftCmd:       ''
        });

        // 2. Re-quote on-chain — defends against the off-chain quote going stale
        //    between TEE signing and MultisigProxy.executeBatch inclusion.
        MessagingFee memory fee = IOFT(oft_).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        // 3. Approve OFT to pull the USDT0 we received from Bridge.fundsOut.
        IERC20(token).safeIncreaseAllowance(oft_, amount);

        // 4. Forward exactly `fee.nativeFee` to the OFT. Refund handled below.
        (MessagingReceipt memory receipt, ) = IOFT(oft_).send{ value: fee.nativeFee }(
            sp,
            fee,
            tx.origin /* refundAddress — defensive only; OFT consumes the full fee */
        );

        // 5. Refund native surplus to `tx.origin` — the relayer EOA that
        //    submitted `MultisigProxy.executeBatch`.
        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = tx.origin.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit SendOut(receipt.guid, dstEid, recipient, amount);
    }

    /// @inheritdoc IUtexoLZAdapter
    function quoteSendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    )
        external
        view
        override
        returns (uint256 nativeFee)
    {
        address oft_ = _requireOftRoute(dstEid);
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           recipient,
            amountLD:     amount,
            minAmountLD:  minAmountLD,
            extraOptions: extraOptions,
            composeMsg:   '',
            oftCmd:       ''
        });
        return IOFT(oft_).quoteSend(sp, false).nativeFee;
    }

    // =========================================================================
    // Stuck-funds recovery
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function getStuckFunds(bytes32 guid) external view override returns (StuckFunds memory) {
        return _stuckFunds[guid];
    }

    /// @inheritdoc IUtexoLZAdapter
    /// @dev Federation governance entrypoint: `MultisigProxy` is the only
    ///      caller. The proxy itself gates this on the M-of-N federation
    ///      timelock (see its `proposeAdminExecute*` flow). Off-chain the
    ///      backend reimburses the original user from `recipient`.
    function refundStuckFunds(bytes32 guid, address recipient)
        external
        override
        onlyMultisigProxy
        nonReentrant
    {
        if (recipient == address(0)) revert InvalidRecipient();

        StuckFunds memory record = _stuckFunds[guid];
        if (record.amountLD == 0) revert NoStuckFunds(guid);

        delete _stuckFunds[guid];
        totalRecordedStuckToken -= record.amountLD;

        // Token leg. SafeERC20 reverts on failure, the whole call rolls back.
        IERC20(token).safeTransfer(recipient, record.amountLD);

        // Native leg, if any. A revert here also rolls back the token transfer
        // and the delete — the record stays recoverable.
        if (record.nativeValue != 0) {
            (bool ok, ) = recipient.call{ value: record.nativeValue }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit StuckFundsRefunded(guid, recipient, record.amountLD, record.nativeValue);
    }

    /// @inheritdoc IUtexoLZAdapter
    function availableUntrackedToken() public view override returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = totalRecordedStuckToken;
        return balance > reserved ? balance - reserved : 0;
    }

    /// @inheritdoc IUtexoLZAdapter
    /// @dev Covers tokens credited by an OFT before `lzCompose` reverted on a
    ///      transport-level check, where no guid-based record could be created.
    ///      Live stuck records are protected by `totalRecordedStuckToken`.
    function recoverUntrackedToken(address recipient, uint256 amount)
        external
        override
        onlyMultisigProxy
        nonReentrant
    {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();

        uint256 available = availableUntrackedToken();
        if (amount > available) revert InsufficientUntrackedToken(amount, available);

        IERC20(token).safeTransfer(recipient, amount);
        emit UntrackedTokenRecovered(recipient, amount);
    }

    // =========================================================================
    // OFT route registry
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function setOftRoute(uint32 eid, address oft_)
        external
        override
        onlyMultisigProxy
    {
        _setOftRoute(eid, oft_);
    }

    /// @dev A route is valid only when the local OFT serves this adapter's
    ///      immutable token and is actually connected to the requested remote
    ///      EID. Passing zero deliberately revokes the route.
    function _setOftRoute(uint32 eid, address oft_) private {
        if (eid == 0) revert InvalidSrcEid();

        if (oft_ == address(0)) {
            delete oftByEid[eid];
            emit OftRouteSet(eid, address(0));
            return;
        }

        if (oft_.code.length == 0) revert InvalidOft();

        address routeToken = IOFT(oft_).token();
        if (routeToken != token) revert OftTokenMismatch(oft_, routeToken, token);
        if (IOftPeerView(oft_).peers(eid) == bytes32(0)) {
            revert OftPeerNotConfigured(oft_, eid);
        }

        oftByEid[eid] = oft_;
        emit OftRouteSet(eid, oft_);
    }

    function _requireOftRoute(uint32 eid) private view returns (address oft_) {
        oft_ = oftByEid[eid];
        if (oft_ == address(0)) revert OftRouteNotConfigured(eid);
    }

    // =========================================================================
    // Trusted entrypoint registry
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    /// @dev Federation governance entrypoint: `MultisigProxy` is the only
    ///      caller. The proxy gates this on its M-of-N timelock flow, so
    ///      mutating the trusted set is a deliberate federation decision —
    ///      e.g. adding a freshly deployed source-chain entrypoint, rotating
    ///      an entrypoint after redeploy, or revoking a compromised one.
    ///
    ///      Registers (or revokes) the trusted entrypoint AND its expected
    ///      business `sourceChainId` for a transport `srcEid` in one atomic
    ///      write, so the two halves of the trust binding can never drift apart.
    ///      Pass `entrypoint == bytes32(0)` to revoke a `srcEid` entirely.
    function setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId)
        external
        override
        onlyMultisigProxy
    {
        if (srcEid == 0) revert InvalidSrcEid();

        // Revoke: clear both halves of the binding for this srcEid.
        if (entrypoint == bytes32(0)) {
            delete trustedEntrypoints[srcEid];
            delete eidToChainId[srcEid];
            emit TrustedEntrypointSet(srcEid, bytes32(0), 0);
            return;
        }

        // Register: an entrypoint must always be bound to a real business chain id.
        if (chainId == 0) revert InvalidChainId();

        trustedEntrypoints[srcEid] = entrypoint;
        eidToChainId[srcEid]       = chainId;
        emit TrustedEntrypointSet(srcEid, entrypoint, chainId);
    }
}
