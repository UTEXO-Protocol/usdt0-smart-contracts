// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IOAppComposer} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppComposer.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IMessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

import {IOFT, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {IUtexoLZAdapter} from "./interfaces/IUtexoLZAdapter.sol";
import {IBridge} from "@bridge-smart-contracts/interfaces/IBridge.sol";

/// @notice Local OFT peer lookup used when configuring routes.
interface IOftPeerView {
    function peers(uint32 eid) external view returns (bytes32);
}

/// @title UtexoLZAdapter
/// @notice Connects the Arbitrum Bridge to USDT0 OFT deposits and outbound transfers.
/// @dev Inbound composes require the configured endpoint, OFT and trusted source binding.
///      MultisigProxy submits outbound transfers and manages routes and recovery.
///      Endpoint, token, Bridge and MultisigProxy addresses are immutable.
contract UtexoLZAdapter is IUtexoLZAdapter, IOAppComposer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum inbound settlement payload length, in bytes.
    /// @dev Bounds the data forwarded to Bridge and stored when a deposit fails.
    uint256 public constant MAX_SETTLEMENT_DATA_LENGTH = 128;

    /// @notice Maximum inbound destination address length, in bytes.
    uint256 public constant MAX_DESTINATION_ADDRESS_LENGTH = 512;

    /// @dev OFTCore queues its single compose callback at index zero.
    uint16 private constant OFT_COMPOSE_INDEX = 0;

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

    /// @inheritdoc IUtexoLZAdapter
    mapping(address oft => bool known) public override knownOfts;

    /// @inheritdoc IUtexoLZAdapter
    mapping(uint32 srcEid => bytes32 entrypoint) public override trustedEntrypoints;

    /// @inheritdoc IUtexoLZAdapter
    mapping(uint32 srcEid => uint256 chainId) public override eidToChainId;

    /// @dev Failed deposits keyed by LayerZero guid, including undecodable payloads.
    mapping(bytes32 guid => StuckFunds) internal _stuckFunds;

    /// @inheritdoc IUtexoLZAdapter
    uint256 public override totalRecordedStuckToken;

    /// @inheritdoc IUtexoLZAdapter
    mapping(bytes32 composeKey_ => bool recovered) public override recoveredComposes;

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts calls to the configured MultisigProxy.
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
        if (endpoint_ == address(0)) revert InvalidEndpoint();
        if (token_ == address(0)) revert InvalidToken();
        if (bridge_ == address(0)) revert InvalidBridge();
        if (multisigProxy_ == address(0)) revert InvalidMultisigProxy();
        if (oftEids_.length == 0) revert NoOftRoutes();
        if (oftEids_.length != ofts_.length) {
            revert OftRouteLengthMismatch(oftEids_.length, ofts_.length);
        }

        endpoint = endpoint_;
        token = token_;
        bridge = bridge_;
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
    /// @notice Forwards an authenticated OFT deposit to Bridge.
    /// @dev Token credit and compose execution are separate transactions. Permanent payload,
    ///      binding and Bridge failures are recorded for refund. Caller-correctable native-value
    ///      mismatches and failures while recording or clearing allowance revert and remain pending.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata /*_extraData*/
    )
        external
        payable
        override
        nonReentrant
    {
        if (msg.sender != endpoint) revert NotEndpoint();

        // Authenticate the local OFT against the transport source EID.
        uint32 srcEid_ = OFTComposeMsgCodec.srcEid(_message);
        bytes32 key = composeKey(_from, _guid, keccak256(_message));
        if (recoveredComposes[key]) {
            uint256 nativeValue = msg.value;
            if (nativeValue != 0) {
                (bool refunded,) = payable(_executor).call{value: nativeValue}("");
                if (!refunded) revert NativeRefundFailed();
            }
            emit RecoveredComposeIgnored(_guid, key, _from, nativeValue);
            return;
        }

        address expectedOft = _requireOftRoute(srcEid_);
        if (_from != expectedOft) revert UnexpectedOft(srcEid_, _from, expectedOft);

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

        // Bind the source entrypoint to the EID authenticated by the transport.
        bytes32 composeFrom_ = OFTComposeMsgCodec.composeFrom(_message);
        bytes32 expected = trustedEntrypoints[srcEid_];
        if (expected == bytes32(0) || composeFrom_ != expected) {
            _parkCompose(
                _guid,
                amountLD,
                bytes32(0),
                0,
                0,
                "",
                "",
                abi.encodeWithSelector(UntrustedComposeSource.selector, srcEid_, composeFrom_)
            );
            return;
        }

        bytes memory payload = OFTComposeMsgCodec.composeMsg(_message);

        // An external self-call makes ABI decoding failures catchable.
        try this.decodeComposeMsg(payload) returns (
            uint256 sourceChainId,
            bytes32 sourceSender,
            uint256 destinationChainId,
            string memory destinationAddress,
            bytes memory settlementData,
            uint256 expectedComposeValue
        ) {
            _composeIn(
                _guid,
                srcEid_,
                amountLD,
                sourceChainId,
                sourceSender,
                destinationChainId,
                destinationAddress,
                settlementData,
                expectedComposeValue
            );
        } catch {
            _parkUndecodableCompose(_guid, amountLD);
        }
    }

    /// @notice Decodes the inbound business payload.
    /// @dev Called externally by `lzCompose` so ABI decoding failures can be caught.
    function decodeComposeMsg(bytes calldata payload)
        external
        pure
        returns (
            uint256 sourceChainId,
            bytes32 sourceSender,
            uint256 destinationChainId,
            string memory destinationAddress,
            bytes memory settlementData,
            uint256 expectedComposeValue
        )
    {
        return abi.decode(payload, (uint256, bytes32, uint256, string, bytes, uint256));
    }

    /// @dev Validates decoded fields and forwards the deposit, recording a caught Bridge failure.
    function _composeIn(
        bytes32 guid,
        uint32 srcEid_,
        uint256 amountLD,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData,
        uint256 expectedComposeValue
    ) private {
        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            _parkCompose(
                guid,
                amountLD,
                sourceSender,
                sourceChainId,
                destinationChainId,
                destinationAddress,
                "",
                abi.encodeWithSelector(
                    SettlementDataTooLong.selector, settlementData.length, MAX_SETTLEMENT_DATA_LENGTH
                )
            );
            return;
        }
        if (bytes(destinationAddress).length > MAX_DESTINATION_ADDRESS_LENGTH) {
            _parkCompose(
                guid,
                amountLD,
                sourceSender,
                sourceChainId,
                destinationChainId,
                "",
                settlementData,
                abi.encodeWithSelector(
                    DestinationAddressTooLong.selector, bytes(destinationAddress).length, MAX_DESTINATION_ADDRESS_LENGTH
                )
            );
            return;
        }
        // Source chain id selects the Bridge route and fee rule; bind it to the transport EID.
        if (eidToChainId[srcEid_] != sourceChainId) {
            _parkCompose(
                guid,
                amountLD,
                sourceSender,
                sourceChainId,
                destinationChainId,
                destinationAddress,
                settlementData,
                abi.encodeWithSelector(SourceChainIdMismatch.selector, srcEid_, sourceChainId)
            );
            return;
        }
        // Endpoint compose is permissionless: a caller supplying the wrong value must not
        // force an otherwise valid deposit into governance recovery.
        if (msg.value != expectedComposeValue) {
            revert ComposeValueMismatch(msg.value, expectedComposeValue);
        }

        // Never let a retry consume tokens reserved for an unrelated parked deposit.
        uint256 available = availableUntrackedToken();
        if (amountLD > available) revert InsufficientUntrackedToken(amountLD, available);

        IERC20(token).safeIncreaseAllowance(bridge, amountLD);

        try IBridge(bridge).fundsIn{value: msg.value}(
            amountLD, sourceChainId, sourceSender, destinationChainId, destinationAddress, settlementData
        ) returns (
            bytes32 operationId
        ) {
            emit ComposeFundsIn(
                guid,
                operationId,
                sourceSender,
                sourceChainId,
                amountLD,
                destinationChainId,
                destinationAddress,
                settlementData
            );
        } catch (bytes memory reason) {
            // Clear the unused allowance before recording the failure; cleanup failure reverts compose.
            IERC20(token).forceApprove(bridge, 0);

            _parkCompose(
                guid,
                amountLD,
                sourceSender,
                sourceChainId,
                destinationChainId,
                destinationAddress,
                settlementData,
                reason
            );
        }
    }

    /// @dev Records the credited amount and native value when business fields cannot be decoded.
    function _parkUndecodableCompose(bytes32 guid, uint256 amountLD) private {
        _parkCompose(guid, amountLD, bytes32(0), 0, 0, "", "", bytes("malformed compose payload"));
    }

    /// @dev Stores one terminal failed delivery. Oversized dynamic fields are omitted by callers.
    function _parkCompose(
        bytes32 guid,
        uint256 amountLD,
        bytes32 sourceSender,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData,
        bytes memory reason
    ) private {
        if (_stuckFunds[guid].isStuck) revert StuckFundsAlreadyExist(guid);

        // A pending credit may have been consumed by an outbound operation before compose.
        // Never create an undercollateralized reserve; leave the compose retryable instead.
        uint256 available = availableUntrackedToken();
        if (amountLD > available) revert InsufficientUntrackedToken(amountLD, available);

        StuckFunds storage record = _stuckFunds[guid];
        record.amountLD = amountLD;
        record.nativeValue = msg.value;
        record.sourceSender = sourceSender;
        record.sourceChainId = sourceChainId;
        record.destinationChainId = destinationChainId;
        record.destinationAddress = destinationAddress;
        record.settlementData = settlementData;
        record.isStuck = true;
        totalRecordedStuckToken += amountLD;

        emit ComposeFundsInFailed(
            guid,
            sourceSender,
            sourceChainId,
            amountLD,
            msg.value,
            destinationChainId,
            destinationAddress,
            settlementData,
            reason
        );
    }

    // =========================================================================
    // Outbound transfers and fee quotes
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function sendOut(uint32 dstEid, bytes32 recipient, uint256 amount, uint256 minAmountLD, bytes calldata extraOptions)
        external
        payable
        override
        onlyMultisigProxy
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == bytes32(0)) revert InvalidRecipient();

        // Preserve tokens reserved by recorded inbound failures.
        uint256 available = availableUntrackedToken();
        if (amount > available) revert InsufficientUntrackedToken(amount, available);

        address oft_ = _requireOftRoute(dstEid);

        // An empty compose message requests token delivery without a destination compose call.
        SendParam memory sp = SendParam({
            dstEid: dstEid,
            to: recipient,
            amountLD: amount,
            minAmountLD: minAmountLD,
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = IOFT(oft_).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({provided: msg.value, required: fee.nativeFee});
        }

        IERC20(token).safeIncreaseAllowance(oft_, amount);

        (MessagingReceipt memory receipt,) =
            IOFT(oft_).send{value: fee.nativeFee}(
                sp,
                fee,
                tx.origin /* OFT refund recipient */
            );

        // The relayer funds lzFundsOutCall; refund its surplus rather than paying MultisigProxy.
        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok,) = tx.origin.call{value: excess}("");
            if (!ok) revert NativeRefundFailed();
        }

        emit SendOut(receipt.guid, dstEid, recipient, amount);
    }

    /// @inheritdoc IUtexoLZAdapter
    function quoteSendOut(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes calldata extraOptions
    ) external view override returns (uint256 nativeFee) {
        address oft_ = _requireOftRoute(dstEid);
        SendParam memory sp = SendParam({
            dstEid: dstEid,
            to: recipient,
            amountLD: amount,
            minAmountLD: minAmountLD,
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
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
    function hasStuckFunds(bytes32 guid) external view override returns (bool) {
        return _stuckFunds[guid].isStuck;
    }

    /// @inheritdoc IUtexoLZAdapter
    function refundStuckFunds(bytes32 guid, address recipient) external override onlyMultisigProxy nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient();

        if (!_stuckFunds[guid].isStuck) revert NoStuckFunds(guid);
        StuckFunds memory record = _stuckFunds[guid];

        delete _stuckFunds[guid];
        totalRecordedStuckToken -= record.amountLD;

        if (record.amountLD != 0) IERC20(token).safeTransfer(recipient, record.amountLD);

        // A failed native refund restores the token transfer, record and reserve counter.
        if (record.nativeValue != 0) {
            (bool ok,) = recipient.call{value: record.nativeValue}("");
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
    function recoverPendingCompose(address oft_, bytes32 guid, bytes calldata message, address recipient)
        external
        override
        onlyMultisigProxy
        nonReentrant
    {
        if (recipient == address(0)) revert InvalidRecipient();

        if (!knownOfts[oft_]) revert OftNotKnown(oft_);

        bytes32 messageHash = keccak256(message);
        bytes32 key = composeKey(oft_, guid, messageHash);
        if (recoveredComposes[key]) revert ComposeAlreadyRecovered(key);

        bytes32 queuedHash = IMessagingComposer(endpoint).composeQueue(oft_, address(this), guid, OFT_COMPOSE_INDEX);
        if (queuedHash != messageHash) revert ComposeNotPending(guid, queuedHash, messageHash);

        uint256 amountLD = OFTComposeMsgCodec.amountLD(message);
        if (amountLD == 0) revert ZeroAmount();

        uint256 available = availableUntrackedToken();
        if (amountLD > available) revert InsufficientUntrackedToken(amountLD, available);

        // Persist the terminal state before the token interaction. A later retry returns
        // successfully without approving Bridge, allowing EndpointV2 to consume the queue entry.
        recoveredComposes[key] = true;
        IERC20(token).safeTransfer(recipient, amountLD);
        emit PendingComposeRecovered(guid, key, oft_, recipient, amountLD);
    }

    /// @inheritdoc IUtexoLZAdapter
    function composeKey(address oft_, bytes32 guid, bytes32 messageHash) public pure override returns (bytes32) {
        return keccak256(abi.encode(oft_, guid, messageHash));
    }

    // =========================================================================
    // OFT route registry
    // =========================================================================

    /// @inheritdoc IUtexoLZAdapter
    function setOftRoute(uint32 eid, address oft_) external override onlyMultisigProxy {
        _setOftRoute(eid, oft_);
    }

    /// @dev Requires the adapter token and a nonzero peer for the EID; a zero OFT revokes the route.
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
        knownOfts[oft_] = true;
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
    function setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId)
        external
        override
        onlyMultisigProxy
    {
        if (srcEid == 0) revert InvalidSrcEid();

        if (entrypoint == bytes32(0)) {
            delete trustedEntrypoints[srcEid];
            delete eidToChainId[srcEid];
            emit TrustedEntrypointSet(srcEid, bytes32(0), 0);
            return;
        }

        if (chainId == 0) revert InvalidChainId();

        trustedEntrypoints[srcEid] = entrypoint;
        eidToChainId[srcEid] = chainId;
        emit TrustedEntrypointSet(srcEid, entrypoint, chainId);
    }
}
