// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IUtexoLZAdapter
/// @notice Arbitrum integration between the Utexo Bridge and USDT0 OFT.
interface IUtexoLZAdapter {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Failed deposit recorded during compose processing.
    /// @dev Undecodable payloads retain only the credited amount and native value.
    /// @param amountLD Token amount credited by the destination OFT, in local decimals.
    /// @param nativeValue Native value received by `lzCompose`, in wei.
    /// @param sourceSender Authenticated caller encoded by the source entrypoint.
    /// @param sourceChainId Source `block.chainid`, checked against the EID binding.
    /// @param destinationChainId Final destination network id; RGB uses 827166.
    /// @param destinationAddress Destination address from the compose payload.
    /// @param settlementData Original opaque settlement payload, retained for diagnostics.
    struct StuckFunds {
        uint256 amountLD;
        uint256 nativeValue;
        bytes32 sourceSender;
        uint256 sourceChainId;
        uint256 destinationChainId;
        string destinationAddress;
        bytes settlementData;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidEndpoint();
    error InvalidOft();
    error NoOftRoutes();
    error OftRouteLengthMismatch(uint256 eidsLength, uint256 oftsLength);
    error DuplicateOftRoute(uint32 eid);
    error OftRouteNotConfigured(uint32 eid);
    error UnexpectedOft(uint32 eid, address provided, address expected);
    error OftTokenMismatch(address oft, address actualToken, address expectedToken);
    error OftPeerNotConfigured(address oft, uint32 eid);
    error InvalidToken();
    error InvalidBridge();
    error InvalidMultisigProxy();
    error InvalidRecipient();
    error InvalidSrcEid();
    error InvalidChainId();
    error NotEndpoint();
    error NotMultisigProxy();
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
    error InsufficientUntrackedToken(uint256 requested, uint256 available);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted after Bridge accepts an inbound deposit.
    /// @param guid LayerZero message identifier.
    /// @param operationId Record id returned by Bridge; matches `BridgeFundsIn.operationId`.
    /// @param sourceSender Authenticated source caller from the compose payload.
    /// @param sourceChainId Source chain id checked against the transport binding.
    /// @param amountLD Gross token amount passed to Bridge, in local decimals.
    /// @param destinationChainId Final destination network id.
    /// @param destinationAddress Destination address from the compose payload.
    /// @param settlementData Opaque payload forwarded to the destination settlement module.
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

    /// @notice Emitted after an outbound OFT send.
    /// @param guid LayerZero message identifier returned by the OFT.
    /// @param dstEid Destination LayerZero EID.
    /// @param recipient Destination recipient encoded as bytes32.
    /// @param amountLD Requested token amount before OFT fees or rounding.
    event SendOut(bytes32 indexed guid, uint32 dstEid, bytes32 recipient, uint256 amountLD);

    /// @notice Emitted when a failed deposit is recorded for refund.
    /// @dev Undecodable payloads leave business fields at zero or empty values.
    /// @param reason Bridge revert data, or a diagnostic message for an undecodable payload.
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

    /// @notice Emitted after a recorded deposit is refunded.
    event StuckFundsRefunded(bytes32 indexed guid, address indexed recipient, uint256 amountLD, uint256 nativeValue);

    /// @notice Emitted when a source entrypoint and chain-id binding is set or revoked.
    /// @param srcEid Source LayerZero EID.
    /// @param entrypoint Encoded source entrypoint; zero revokes the binding.
    /// @param chainId Expected source chain id; zero after revocation.
    event TrustedEntrypointSet(uint32 indexed srcEid, bytes32 entrypoint, uint256 chainId);

    /// @notice Emitted when the Arbitrum-side OFT route for a LayerZero EID is
    ///         registered, replaced, or revoked (`oft == address(0)`).
    event OftRouteSet(uint32 indexed eid, address indexed oft);

    /// @notice Emitted after tokens outside the recorded reserve are recovered.
    event UntrackedTokenRecovered(address indexed recipient, uint256 amount);

    // =========================================================================
    // State views
    // =========================================================================

    function endpoint() external view returns (address);
    function token() external view returns (address);
    function bridge() external view returns (address);
    function multisigProxy() external view returns (address);

    /// @notice Local OFT for a LayerZero EID; zero means the route is unconfigured.
    /// @dev Native and legacy USDT0 meshes can use different local OFTs for the same token.
    function oftByEid(uint32 eid) external view returns (address);

    /// @notice Sum of token amounts reserved by live `_stuckFunds` records.
    function totalRecordedStuckToken() external view returns (uint256);

    /// @notice Source entrypoint trusted for the LayerZero EID; zero means unregistered.
    /// @dev Matches OFT `composeFrom`, the source-side caller of `OFT.send`, encoded as bytes32.
    function trustedEntrypoints(uint32 srcEid) external view returns (bytes32);

    /// @notice Expected source chain id for the LayerZero EID; zero means unregistered.
    function eidToChainId(uint32 srcEid) external view returns (uint256);

    /// @notice Returns a recorded deposit, or zeroed fields for an unknown guid.
    /// @dev Refunds require a nonzero `amountLD`.
    function getStuckFunds(bytes32 guid) external view returns (StuckFunds memory);

    // =========================================================================
    // Outbound transfers and fee quotes
    // =========================================================================

    /// @notice Sends adapter-held tokens through the configured OFT. Callable only by MultisigProxy.
    /// @dev Recorded stuck-token reserves are excluded. Surplus native value goes to `tx.origin`.
    ///      Unreserved tokens can include credits awaiting compose execution.
    /// @param dstEid Destination LayerZero EID.
    /// @param recipient Destination recipient encoded as bytes32.
    /// @param amount Requested token amount in local decimals.
    /// @param minAmountLD Minimum destination amount accepted by the OFT, in local decimals.
    /// @param extraOptions LayerZero executor options.
    function sendOut(uint32 dstEid, bytes32 recipient, uint256 amount, uint256 minAmountLD, bytes calldata extraOptions)
        external
        payable;

    /// @notice Quotes the LayerZero native fee for an outbound token transfer.
    /// @dev Does not check caller authorization or the adapter's available balance.
    function quoteSendOut(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes calldata extraOptions
    ) external view returns (uint256 nativeFee);

    // =========================================================================
    // Stuck-funds recovery
    // =========================================================================

    /// @notice Refunds a recorded deposit to a nonzero recipient. Callable only by MultisigProxy.
    /// @dev Requires a nonzero token amount. Transfers tokens and recorded native value atomically;
    ///      a failed transfer preserves the record and reserve counter.
    /// @param guid LayerZero message identifier for the record.
    /// @param recipient Refund recipient on Arbitrum.
    function refundStuckFunds(bytes32 guid, address recipient) external;

    /// @notice Returns token balance above the recorded stuck-token reserve, or zero.
    /// @dev This includes OFT credits whose compose has not executed.
    function availableUntrackedToken() external view returns (uint256);

    /// @notice Recovers unreserved tokens to a nonzero recipient. Callable only by MultisigProxy.
    /// @dev Also covers credits whose compose cannot pass validation before a record is created.
    ///      Does not distinguish pending compose credits from other unreserved tokens.
    function recoverUntrackedToken(address recipient, uint256 amount) external;

    // =========================================================================
    // OFT route registry
    // =========================================================================

    /// @notice Sets the local OFT for an EID, or revokes it with zero. Callable only by MultisigProxy.
    /// @dev A nonzero OFT must contain code, serve the adapter token and have a nonzero peer for the EID.
    function setOftRoute(uint32 eid, address oft) external;

    // =========================================================================
    // Trusted entrypoint registry
    // =========================================================================

    /// @notice Sets a source entrypoint and chain-id binding. Callable only by MultisigProxy.
    /// @dev A zero entrypoint revokes both values. Otherwise both `srcEid` and `chainId` must be nonzero.
    /// @param srcEid Source LayerZero EID; must be nonzero even when revoking.
    /// @param entrypoint Source-side caller of `OFT.send` (`composeFrom`), encoded as bytes32.
    /// @param chainId Source chain id expected in the compose payload.
    function setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId) external;
}
