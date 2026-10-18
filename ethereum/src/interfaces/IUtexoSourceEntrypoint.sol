// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IUtexoSourceEntrypoint
/// @notice Source-chain deposits into the Utexo bridge through USDT0 OFT.
interface IUtexoSourceEntrypoint {
    // =========================================================================
    // Types
    // =========================================================================

    /// @param amountLD Requested token amount in local decimals; must be nonzero.
    /// @param minAmountLD Minimum destination amount accepted by the OFT, in local decimals.
    /// @param extraOptions LayerZero executor options, combined with the OFT's enforced options.
    /// @param payload `abi.encode(uint256 destinationChainId, string destinationAddress, bytes settlementData)`.
    ///                The chain id must be nonzero. RGB uses id 827166, an empty address and
    ///                `abi.encode(uint256 rgbOpId)` for the canonical RGB settlement module.
    /// @param refundTo Native-surplus recipient and OFT refund address; zero selects the caller.
    /// @param expectedComposeValue Native value expected by the Arbitrum compose call, in wei.
    ///                Must match the value delivered under the effective executor options.
    ///                The entrypoint includes it in the payload but does not validate the options.
    struct DepositParams {
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes payload;
        address refundTo;
        uint256 expectedComposeValue;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidTokenAddress();
    error InvalidOftAddress();
    error OftTokenMismatch(address oft, address actualToken, address expectedToken);
    error InvalidLZAdapter();
    error InvalidDstEid();
    error InvalidDestinationChainId();
    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();
    error SettlementDataTooLong(uint256 length, uint256 maxLength);
    error DestinationAddressTooLong(uint256 length, uint256 maxLength);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted after a deposit is submitted to the source OFT.
    /// @param guid LayerZero message identifier.
    /// @param user Caller whose tokens and native fee fund the deposit.
    /// @param amountLD Requested source amount before OFT fees or rounding.
    /// @param sourceChainId Source `block.chainid` captured at deposit time.
    /// @param destinationChainId Final destination network id, distinct from the LayerZero EID.
    /// @param destinationAddress Destination address supplied in the deposit payload.
    /// @param settlementData Opaque payload interpreted by the destination settlement module.
    event Deposit(
        bytes32 indexed guid,
        address indexed user,
        uint256 amountLD,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string destinationAddress,
        bytes settlementData
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

    /// @notice Sends a deposit through OFT to the configured Arbitrum adapter.
    /// @dev Binds `block.chainid` and the caller as source identity. `msg.value` must cover the
    ///      LayerZero quote; surplus goes to `depositParams.refundTo`, or the caller when it is zero.
    /// @param depositParams Token amount, execution options and destination payload.
    /// @return guid LayerZero message identifier.
    function deposit(DepositParams calldata depositParams) external payable returns (bytes32 guid);

    /// @notice Quotes the LayerZero native fee for an OFT transfer with compose execution.
    /// @dev Remains available while deposits are paused. A quote does not check balances or allowance.
    /// @param depositParams Token amount, execution options and destination payload.
    /// @return nativeFee LayerZero fee in source-chain native units.
    function quote(DepositParams calldata depositParams) external view returns (uint256 nativeFee);
}
