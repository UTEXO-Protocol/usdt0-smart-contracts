// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IUtexoSourceEntrypoint
/// @notice User-facing deposit entrypoint on source chains (Ethereum, OP, Base, …).
///         Wraps the USDT0 OFT `send()` call so the visible protocol surface belongs
///         to Utexo rather than directly to Tether's OFT contract.
interface IUtexoSourceEntrypoint {
    // =========================================================================
    // Types
    // =========================================================================

    /// @param amountLD     Amount of `token` to deposit, in local decimals.
    /// @param minAmountLD  Minimum amount that must be credited on destination; serves
    ///                     as a slippage guard against OFT-side fees.
    /// @param extraOptions LayerZero executor options encoding `lzReceive` / `lzCompose`
    ///                     gas budgets and the destination-side `msg.value` forwarded
    ///                     into `UtexoLZAdapter.lzCompose`. Produced by the backend.
    /// @param payload      Caller-supplied business payload encoded as
    ///                     `abi.encode(uint256 destinationChainId, string destinationAddress, uint256 operationId, bytes settlementData)`.
    ///                     `settlementData` is an opaque blob consumed by the
    ///                     destination route's `SettlementModule` on Arbitrum
    ///                     (empty `""` for routes registered with
    ///                     `NullSettlementModule`, which is the default for
    ///                     LZ-adapter flows). The entrypoint decodes the payload
    ///                     on the source chain to validate the format (malformed
    ///                     input reverts here, before any LZ fee is paid) and
    ///                     re-encodes it with `block.chainid` prepended as the
    ///                     actual `composeMsg` forwarded to LayerZero.
    /// @param refundTo Address that receives the LayerZero native-fee
    ///                     surplus (and is passed as the OFT `refundAddress`).
    /// @param expectedComposeValue The native value the backend budgeted as the
    ///                     destination `lzCompose` drop (same amount set in
    ///                     `extraOptions`). Bound into `composeMsg` so the
    ///                     destination `UtexoLZAdapter` can reject a compose
    ///                     executed with a mismatched `msg.value` (griefing).
    ///                     MUST equal the `lzCompose` native drop in `extraOptions`.
    struct DepositParams {
        uint256 amountLD;
        uint256 minAmountLD;
        bytes   extraOptions;
        bytes   payload;
        address refundTo;
        uint256 expectedComposeValue;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidTokenAddress();
    error InvalidOftAddress();
    error InvalidLZAdapter();
    error InvalidDstEid();
    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();
    error SettlementDataTooLong(uint256 length, uint256 maxLength);
    error DestinationAddressTooLong(uint256 length, uint256 maxLength);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted for every successful deposit forwarded to the USDT0 OFT.
    /// @param guid                LayerZero message guid; correlates with the compose
    ///                            event on the destination chain.
    /// @param user                Address whose tokens were pulled and charged for the
    ///                            LZ fee.
    /// @param amountLD            Amount of `token` forwarded into the OFT (gross,
    ///                            pre-OFT-fee).
    /// @param sourceChainId       `block.chainid` captured at deposit time; embedded
    ///                            in the `composeMsg` and consumed by `Bridge.fundsIn`
    ///                            on Arbitrum for commission routing.
    /// @param destinationChainId  Final destination chain id (`uint256`; passes through
    ///                            to Bridge unchanged).
    /// @param destinationAddress  Final recipient address on `destinationChainId`.
    /// @param operationId         Backend-assigned operation id (consumed by the
    ///                            destination route's settlement module on Bridge).
    /// @param settlementData      Opaque blob plumbed through to
    ///                            `Bridge.fundsIn` and into the destination
    ///                            route's `SettlementModule.onFundsIn`. Empty
    ///                            for routes using `NullSettlementModule`.
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

    // =========================================================================
    // State views
    // =========================================================================

    function token() external view returns (address);
    function oft() external view returns (address);
    function dstEid() external view returns (uint32);
    function lzAdapter() external view returns (bytes32);

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @notice Pulls `p.amountLD` of `token` from the caller, forwards it into the
    ///         USDT0 OFT, and requests LayerZero delivery to the Utexo
    ///         `UtexoLZAdapter` on the destination chain. The entrypoint
    ///         constructs the `composeMsg` itself with `block.chainid` as the first
    ///         field so the caller cannot spoof the source-chain identifier that
    ///         `Bridge` will use for commission routing.
    /// @dev    `msg.value` must cover the LayerZero native fee returned by
    ///         `IOFT.quoteSend`. Surplus is refunded to the caller.
    function deposit(DepositParams calldata p) external payable returns (bytes32 guid);

    /// @notice Convenience re-export of `IOFT.quoteSend` so frontends can quote without
    ///         knowing the OFT address / hard-coded `dstEid` / `lzAdapter`. Builds
    ///         the same `composeMsg` as `deposit`.
    function quote(DepositParams calldata p) external view returns (uint256 nativeFee);
}
