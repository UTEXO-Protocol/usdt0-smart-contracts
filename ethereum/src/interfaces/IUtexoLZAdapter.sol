// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IUtexoLZAdapter
/// @notice Bidirectional adapter between the Utexo `Bridge` and the LayerZero / USDT0 stack
///         on Arbitrum. Handles two distinct flows:
///
///           • Inbound  (non-Arbitrum EVM → RGB): receives USDT0 via LayerZero compose
///                       and calls `Bridge.fundsIn` to lock it.
///           • Outbound (RGB → non-Arbitrum EVM): receives USDT0 from `Bridge.fundsOut`
///                       and forwards it via `OFT.send` to the user's destination chain.
interface IUtexoLZAdapter {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Snapshot of an inbound compose payload whose `Bridge.fundsIn`
    ///         call reverted. Held on the adapter until federation governance
    ///         releases it via `refundStuckFunds`.
    /// @param amountLD            USDT0 amount that the OFT minted to the adapter.
    /// @param nativeValue         Native (wei) the LayerZero Executor forwarded
    ///                            into `lzCompose` — non-zero on NATIVE-currency
    ///                            commission routes, zero on TOKEN routes.
    /// @param operationId         Backend-assigned operation id from `composeMsg`.
    /// @param sourceChainId       EVM chain id of the source chain, set by
    ///                            `UtexoSourceEntrypoint` from `block.chainid` at
    ///                            deposit time and cross-checked in `lzCompose`
    ///                            against the transport `srcEid` via `eidToChainId`.
    /// @param destinationChainId  Final destination chain id (`uint256`): real
    ///                            `block.chainid` values for EVM legs, reserved
    ///                            namespace ids above the EVM range for non-EVM
    ///                            endpoints (e.g. RGB = 1_000_001).
    /// @param destinationAddress  Final recipient on the destination chain.
    /// @param settlementData      Opaque blob plumbed through to the
    ///                            destination route's `SettlementModule.onFundsIn`
    ///                            on the Bridge.
    struct StuckFunds {
        uint256 amountLD;
        uint256 nativeValue;
        uint256 operationId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        string  destinationAddress;
        bytes   settlementData;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidEndpoint();
    error InvalidOft();
    error InvalidToken();
    error InvalidBridge();
    error InvalidMultisigProxy();
    error InvalidRecipient();
    error InvalidSrcEid();
    error InvalidChainId();
    error NotEndpoint();
    error NotMultisigProxy();
    error NotFromOft();
    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();
    error NoStuckFunds(bytes32 guid);
    error StuckFundsAlreadyExist(bytes32 guid);
    error UntrustedComposeSource(uint32 srcEid, bytes32 composeFrom);
    error SourceChainIdMismatch(uint32 srcEid, uint256 sourceChainId);
    error SettlementDataTooLong(uint256 length, uint256 maxLength);
    error DestinationAddressTooLong(uint256 length, uint256 maxLength);
    error ComposeValueMismatch(uint256 provided, uint256 expected);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on a successful inbound `lzCompose` → `Bridge.fundsIn` call.
    /// @param guid                LayerZero message guid.
    /// @param sourceChainId       EVM chain id of the source chain (from `composeMsg`,
    ///                            set by `UtexoSourceEntrypoint` from `block.chainid`).
    /// @param amountLD            Amount of USDT0 forwarded into the Bridge (gross).
    /// @param destinationChainId  Target chain id (`uint256`; backend-assigned for
    ///                            non-EVM destinations).
    /// @param destinationAddress  Target address on the destination chain.
    /// @param operationId         Backend-assigned operation identifier.
    /// @param settlementData      Opaque blob forwarded to the destination
    ///                            route's `SettlementModule.onFundsIn` on the
    ///                            Bridge. Empty for routes registered with
    ///                            `NullSettlementModule`.
    event ComposeFundsIn(
        bytes32 indexed guid,
        uint256 sourceChainId,
        uint256 amountLD,
        uint256 destinationChainId,
        string  destinationAddress,
        uint256 operationId,
        bytes   settlementData
    );

    /// @notice Emitted on a successful outbound `sendOut` → `OFT.send` call.
    /// @param guid       LayerZero message guid returned by the OFT.
    /// @param dstEid     Destination LayerZero endpoint id.
    /// @param recipient  Recipient address on the destination chain (left-padded bytes32).
    /// @param amountLD   Amount of USDT0 sent.
    event SendOut(
        bytes32 indexed guid,
        uint32  dstEid,
        bytes32 recipient,
        uint256 amountLD
    );

    /// @notice Emitted when `Bridge.fundsIn` reverted inside `lzCompose`. The
    ///         minted USDT0 (and any forwarded native) is held on the adapter
    ///         under `stuckFunds[guid]` until resolved.
    /// @param reason Raw revert returndata from `Bridge.fundsIn` — keep as
    ///               `bytes` because Bridge can revert with any custom error.
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

    /// @notice Emitted when `refundStuckFunds` releases a stuck record to a
    ///         recipient designated by federation governance.
    event StuckFundsRefunded(
        bytes32 indexed guid,
        address indexed recipient,
        uint256 amountLD,
        uint256 nativeValue
    );

    /// @notice Emitted whenever a trusted-source binding is mutated by
    ///         federation governance.
    /// @param srcEid     LayerZero transport source id the binding applies to.
    /// @param entrypoint Source-chain entrypoint address as bytes32 (left-padded
    ///                   for EVM, full 32 bytes for non-EVM chains). `bytes32(0)`
    ///                   signals the binding was revoked.
    /// @param chainId    Expected business `sourceChainId` for this `srcEid`
    ///                   (`0` on revoke).
    event TrustedEntrypointSet(uint32 indexed srcEid, bytes32 entrypoint, uint256 chainId);

    // =========================================================================
    // State views
    // =========================================================================

    function endpoint()      external view returns (address);
    function oft()           external view returns (address);
    function token()         external view returns (address);
    function bridge()        external view returns (address);
    function multisigProxy() external view returns (address);

    /// @notice The source-chain entrypoint (as bytes32) trusted to drive
    ///         `lzCompose` for a given LayerZero transport `srcEid`.
    ///         `bytes32(0)` means no entrypoint is registered for that srcEid.
    function trustedEntrypoints(uint32 srcEid) external view returns (bytes32);

    /// @notice The business `sourceChainId` expected for a given LayerZero
    ///         transport `srcEid`. `0` means the srcEid is unregistered.
    function eidToChainId(uint32 srcEid) external view returns (uint256);

    /// @notice Returns the stuck-funds record for a given LayerZero guid.
    ///         `amountLD == 0` signals "no record".
    function getStuckFunds(bytes32 guid) external view returns (StuckFunds memory);

    // =========================================================================
    // Outbound — restricted to MultisigProxy
    // =========================================================================

    /// @notice Forward USDT0 (already held by this adapter as a result of a prior
    ///         `Bridge.fundsOut(recipient = address(this))` leg) to a user on a
    ///         destination LayerZero chain.
    /// @dev Re-quotes the LayerZero fee on-chain. `msg.value` must cover the quoted
    ///      `nativeFee`; any surplus is refunded to `tx.origin` (the relayer EOA
    ///      that submitted `MultisigProxy.executeBatch`).
    /// @param dstEid       Destination LayerZero endpoint id.
    /// @param recipient    Recipient on destination chain (address left-padded to bytes32).
    /// @param amount       Amount of USDT0 to send.
    /// @param minAmountLD  Slippage guard.
    /// @param extraOptions LayerZero executor options (`lzReceiveOption` only — no compose).
    /// @dev The LayerZero message guid is published only via the `SendOut`
    ///      event — the sole authorised caller (`MultisigProxy.executeBatch`)
    ///      cannot consume a return value anyway.
    function sendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    ) external payable;

    /// @notice Convenience re-export of `OFT.quoteSend` for the outbound shape.
    function quoteSendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    ) external view returns (uint256 nativeFee);

    // =========================================================================
    // Stuck-funds recovery
    // =========================================================================

    /// @notice Releases a stuck record to `recipient`, transferring both the
    ///         held USDT0 and any held native value. Callable only by
    ///         `multisigProxy` — federation governance gates this on the
    ///         proxy side (timelock + M-of-N).
    /// @param guid      LayerZero compose guid whose record to refund.
    /// @param recipient Destination for the refund (non-zero).
    function refundStuckFunds(bytes32 guid, address recipient) external;

    // =========================================================================
    // Trusted entrypoint registry
    // =========================================================================

    /// @notice Registers or revokes the trusted source binding for a LayerZero
    ///         transport `srcEid`. `lzCompose` requires the inbound packet's
    ///         `composeFrom` (the `msg.sender` of the original `OFT.send` on the
    ///         source chain, preserved by the OFT protocol) to equal `entrypoint`
    ///         AND the payload's self-declared `sourceChainId` to equal `chainId`
    ///         — otherwise the call reverts. Both halves are written atomically.
    ///         Callable only by `multisigProxy`, so changes go through federation
    ///         governance.
    /// @param srcEid     LayerZero transport source id this binding applies to. Non-zero.
    /// @param entrypoint Source-chain entrypoint address as bytes32 (left-padded
    ///                   for EVM, full 32 bytes for non-EVM chains). Pass
    ///                   `bytes32(0)` to revoke the binding for `srcEid`.
    /// @param chainId    Expected business `sourceChainId` for this `srcEid`.
    ///                   Must be non-zero when registering (ignored on revoke).
    function setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId) external;
}
