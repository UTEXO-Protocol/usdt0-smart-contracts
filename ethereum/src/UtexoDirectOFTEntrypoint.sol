// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }    from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {
    IOFT,
    SendParam,
    OFTReceipt
} from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol';
import { MessagingFee, MessagingReceipt } from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol';

import { IUtexoDirectOFTEntrypoint } from './interfaces/IUtexoDirectOFTEntrypoint.sol';

/// @title UtexoDirectOFTEntrypoint
/// @notice Demo-only entrypoint that forwards user funds through a direct USDT0
///         OFT transfer, without Utexo Bridge, LZ adapter, settlement, or compose.
/// @dev Deploy one instance per fixed source -> destination route.
contract UtexoDirectOFTEntrypoint is IUtexoDirectOFTEntrypoint, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @inheritdoc IUtexoDirectOFTEntrypoint
    address public immutable override token;

    /// @inheritdoc IUtexoDirectOFTEntrypoint
    address public immutable override oft;

    /// @inheritdoc IUtexoDirectOFTEntrypoint
    uint32 public immutable override dstEid;

    /// @inheritdoc IUtexoDirectOFTEntrypoint
    uint256 public immutable override destinationChainId;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param token_               ERC-20 pulled from users and supplied to the OFT.
    /// @param oft_                 USDT0 OFT on this source chain.
    /// @param dstEid_              LayerZero endpoint id of the destination chain.
    /// @param destinationChainId_   Business chain id used in Utexo backend records.
    constructor(
        address token_,
        address oft_,
        uint32 dstEid_,
        uint256 destinationChainId_
    ) {
        if (token_ == address(0)) revert InvalidTokenAddress();
        if (oft_ == address(0)) revert InvalidOftAddress();
        if (dstEid_ == 0) revert InvalidDstEid();
        if (destinationChainId_ == 0) revert InvalidDestinationChainId();

        token = token_;
        oft = oft_;
        dstEid = dstEid_;
        destinationChainId = destinationChainId_;
    }

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @inheritdoc IUtexoDirectOFTEntrypoint
    function deposit(DepositParams calldata depositParams)
        external
        payable
        override
        nonReentrant
        returns (bytes32 guid)
    {
        _validateDepositParams(depositParams);

        IERC20(token).safeTransferFrom(msg.sender, address(this), depositParams.amountLD);
        IERC20(token).safeIncreaseAllowance(oft, depositParams.amountLD);

        SendParam memory sp = _buildSendParam(depositParams);
        MessagingFee memory fee = IOFT(oft).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) =
            IOFT(oft).send{ value: fee.nativeFee }(sp, fee, msg.sender);
        guid = receipt.guid;

        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = msg.sender.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit Deposit(
            guid,
            msg.sender,
            depositParams.recipient,
            oftReceipt.amountSentLD,
            oftReceipt.amountReceivedLD,
            block.chainid,
            destinationChainId,
            dstEid
        );
    }

    /// @inheritdoc IUtexoDirectOFTEntrypoint
    function quote(DepositParams calldata depositParams)
        external
        view
        override
        returns (uint256 nativeFee)
    {
        _validateDepositParams(depositParams);

        SendParam memory sp = _buildSendParam(depositParams);
        return IOFT(oft).quoteSend(sp, false).nativeFee;
    }

    function _buildSendParam(DepositParams calldata depositParams)
        private
        view
        returns (SendParam memory)
    {
        return SendParam({
            dstEid:       dstEid,
            to:           depositParams.recipient,
            amountLD:     depositParams.amountLD,
            minAmountLD:  depositParams.minAmountLD,
            extraOptions: depositParams.extraOptions,
            composeMsg:   '',
            oftCmd:       ''
        });
    }

    function _validateDepositParams(DepositParams calldata depositParams) private pure {
        if (depositParams.recipient == bytes32(0)) revert InvalidRecipient();
        if (depositParams.amountLD == 0) revert ZeroAmount();
    }
}
