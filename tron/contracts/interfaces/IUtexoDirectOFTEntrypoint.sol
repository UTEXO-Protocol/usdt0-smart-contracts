// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IUtexoDirectOFTEntrypoint
/// @notice Demo-only entrypoint for direct USDT0 OFT transfers between chains
///         supported by USDT0 itself.
interface IUtexoDirectOFTEntrypoint {
    // =========================================================================
    // Types
    // =========================================================================

    /// @param recipient    Destination OFT recipient, encoded as bytes32 using
    ///                     LayerZero V2 address convention.
    /// @param amountLD     Amount of `token` to send, in local decimals.
    /// @param minAmountLD  Minimum amount that must be credited on destination.
    /// @param extraOptions LayerZero executor options for the destination
    ///                     `lzReceive`.
    struct DepositParams {
        bytes32 recipient;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes   extraOptions;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidTokenAddress();
    error InvalidOftAddress();
    error InvalidDstEid();
    error InvalidDestinationChainId();
    error InvalidRecipient();
    error ZeroAmount();
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error NativeRefundFailed();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted after a direct OFT transfer is accepted on the source chain.
    /// @param guid                LayerZero message guid; match this with
    ///                            `OFTReceived` on the destination OFT.
    /// @param user                Caller whose tokens were pulled.
    /// @param recipient           Destination OFT recipient.
    /// @param amountSentLD        Amount actually debited by the source OFT.
    /// @param amountReceivedLD    Amount expected to be credited by the remote OFT.
    /// @param sourceChainId       Source `block.chainid` captured at deposit time.
    /// @param destinationChainId  Business chain id configured for this entrypoint.
    /// @param dstEid              LayerZero destination endpoint id.
    event Deposit(
        bytes32 indexed guid,
        address indexed user,
        bytes32 indexed recipient,
        uint256 amountSentLD,
        uint256 amountReceivedLD,
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint32  dstEid
    );

    // =========================================================================
    // State views
    // =========================================================================

    function token() external view returns (address);
    function oft() external view returns (address);
    function dstEid() external view returns (uint32);
    function destinationChainId() external view returns (uint256);

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @notice Pulls `p.amountLD` from the caller and sends it directly through
    ///         the configured USDT0 OFT route.
    function deposit(DepositParams calldata p) external payable returns (bytes32 guid);

    /// @notice Convenience re-export of `IOFT.quoteSend` for the direct send
    ///         shape used by `deposit`.
    function quote(DepositParams calldata p) external view returns (uint256 nativeFee);
}
