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
///      │                  ├─► validate msg.sender == endpoint, _from == oft       │
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
///      All five participating addresses (endpoint, oft, token, bridge, multisigProxy)
///      are immutable. To repoint any of them — redeploy the adapter and update the
///      reference via federation governance on `MultisigProxy`.
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
    ///         routes use `NullSettlementModule` (empty blob), so 1024 bytes is
    ///         ample headroom. The same cap is mirrored on the source-chain
    ///         `UtexoSourceEntrypoint`.
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
    address public immutable override oft;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override token;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override bridge;

    /// @inheritdoc IUtexoLZAdapter
    address public immutable override multisigProxy;

    // =========================================================================
    // Storage
    // =========================================================================

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
    /// @param oft_           USDT0 OFT contract on Arbitrum.
    /// @param token_         USDT0 token on Arbitrum.
    /// @param bridge_        Utexo `Bridge` contract on Arbitrum.
    /// @param multisigProxy_ Utexo `MultisigProxy`.
    constructor(
        address endpoint_,
        address oft_,
        address token_,
        address bridge_,
        address multisigProxy_
    ) {
        if (endpoint_      == address(0)) revert InvalidEndpoint();
        if (oft_           == address(0)) revert InvalidOft();
        if (token_         == address(0)) revert InvalidToken();
        if (bridge_        == address(0)) revert InvalidBridge();
        if (multisigProxy_ == address(0)) revert InvalidMultisigProxy();

        endpoint      = endpoint_;
        oft           = oft_;
        token         = token_;
        bridge        = bridge_;
        multisigProxy = multisigProxy_;
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
        if (_from      != oft)      revert NotFromOft();

        // 1. Bind trust to the LayerZero transport origin. `srcEid` is stamped by
        //    the LayerZero protocol (not by the payload author) and is therefore
        //    non-spoofable. Accept the packet only if its `composeFrom` matches
        //    the single entrypoint registered for that `srcEid`; an unregistered
        //    srcEid (expected == 0) is rejected.
        uint32  srcEid_      = OFTComposeMsgCodec.srcEid(_message);
        bytes32 composeFrom_ = OFTComposeMsgCodec.composeFrom(_message);
        bytes32 expected     = trustedEntrypoints[srcEid_];
        if (expected == bytes32(0) || composeFrom_ != expected) {
            revert UntrustedComposeSource(srcEid_, composeFrom_);
        }

        // 2. Decode the LayerZero compose data.
        uint256 amountLD     = OFTComposeMsgCodec.amountLD(_message);
        bytes memory payload = OFTComposeMsgCodec.composeMsg(_message);

        // 3. Decode the business payload. `sourceChainId` is the EVM chain id the
        //    source `UtexoSourceEntrypoint` captured from `block.chainid` at
        //    deposit time, but it is self-declared in the payload — it is only
        //    trustworthy once step 3a cross-checks it against the transport
        //    `srcEid`. `settlementData` is an opaque blob whose layout is dictated
        //    by the destination route's `SettlementModule` on Arbitrum; the
        //    adapter plumbs it through unchanged. For routes registered with
        //    `NullSettlementModule` (the default for LZ-adapter inbound flows) it
        //    is empty.
        (
            uint256 sourceChainId,
            uint256 destinationChainId,
            string memory destinationAddress,
            uint256 operationId,
            bytes memory settlementData,
            uint256 expectedComposeValue
        ) = abi.decode(payload, (uint256, uint256, string, uint256, bytes, uint256));

        // 3a. Bound the decoded inputs before they are plumbed onward or, on the
        //     failure path, written to `_stuckFunds[guid]` storage.
        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (bytes(destinationAddress).length > MAX_DESTINATION_ADDRESS_LENGTH) {
            revert DestinationAddressTooLong(bytes(destinationAddress).length, MAX_DESTINATION_ADDRESS_LENGTH);
        }

        // 3b. Bind the self-declared `sourceChainId` to the transport origin: the
        //     trusted entrypoint for this `srcEid` may only speak for the chain id
        //     registered to it. This turns `sourceChainId` — which drives route
        //     and commission selection downstream — from a self-asserted field
        //     into one corroborated by the LayerZero transport.
        if (eidToChainId[srcEid_] != sourceChainId) {
            revert SourceChainIdMismatch(srcEid_, sourceChainId);
        }

        // 3c. Anti-grief: the forwarded native value must match the drop the
        //     depositor budgeted (bound in `composeMsg` at deposit). A compose
        //     executed with a wrong `msg.value` reverts here — LayerZero can
        //     retry with the funded value instead of the deposit being parked.
        //     An honestly-funded compose proceeds; if the Bridge later rejects it
        //     (e.g. oracle drift moved the native commission), it lands in
        //     `_stuckFunds` (recoverable), not lost.
        if (msg.value != expectedComposeValue) {
            revert ComposeValueMismatch(msg.value, expectedComposeValue);
        }

        // 4. Approve Bridge to pull the USDT0 we just received via lzReceive.
        IERC20(token).safeIncreaseAllowance(bridge, amountLD);

        // 5. Forward the call. `msg.value` here is the value the LayerZero
        //    Executor forwarded into this lzCompose, sized off-chain by the
        //    backend to match the route's NATIVE commission (or 0 for
        //    TOKEN-currency routes). Calls the adapter-only `fundsIn` overload
        //    (6-arg, `onlyLZAdapter`-gated) so the non-spoofable
        //    `sourceChainId` reaches commission routing and `settlementData`
        //    reaches the route's `SettlementModule.onFundsIn`. If Bridge
        //    rejects the call (paused, route disabled, settlement module
        //    rejects, native-value mismatch, …) the funds are parked in
        //    `_stuckFunds[_guid]` and recoverable off the hot path.
        try IBridge(bridge).fundsIn{ value: msg.value }(
            amountLD,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            operationId,
            settlementData
        ) {
            emit ComposeFundsIn(
                _guid, sourceChainId, amountLD,
                destinationChainId, destinationAddress, operationId, settlementData
            );
        } catch (bytes memory reason) {
            // Bridge did not pull the approved allowance — reset it so the
            // unconsumed approval cannot accumulate across repeated failures.
            IERC20(token).forceApprove(bridge, 0);

            // Never overwrite an existing parked record. LayerZero guids are
            // unique per packet, so a second failed compose under the same
            // `_guid` is not expected; if it ever happens, preserve the
            // original (recoverable) record instead of clobbering it.
            if (_stuckFunds[_guid].amountLD != 0) revert StuckFundsAlreadyExist(_guid);

            _stuckFunds[_guid] = StuckFunds({
                amountLD:           amountLD,
                nativeValue:        msg.value,
                operationId:        operationId,
                sourceChainId:      sourceChainId,
                destinationChainId: destinationChainId,
                destinationAddress: destinationAddress,
                settlementData:     settlementData
            });

            emit ComposeFundsInFailed(
                _guid, sourceChainId, amountLD, msg.value,
                destinationChainId, destinationAddress, operationId, settlementData, reason
            );
        }
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
        MessagingFee memory fee = IOFT(oft).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        // 3. Approve OFT to pull the USDT0 we received from Bridge.fundsOut.
        IERC20(token).safeIncreaseAllowance(oft, amount);

        // 4. Forward exactly `fee.nativeFee` to the OFT. Refund handled below.
        (MessagingReceipt memory receipt, ) = IOFT(oft).send{ value: fee.nativeFee }(
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
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           recipient,
            amountLD:     amount,
            minAmountLD:  minAmountLD,
            extraOptions: extraOptions,
            composeMsg:   '',
            oftCmd:       ''
        });
        return IOFT(oft).quoteSend(sp, false).nativeFee;
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
