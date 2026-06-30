// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 }          from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 }       from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { Ownable }         from '@openzeppelin/contracts/access/Ownable.sol';
import { Ownable2Step }    from '@openzeppelin/contracts/access/Ownable2Step.sol';
import { Pausable }        from '@openzeppelin/contracts/utils/Pausable.sol';
import { ReentrancyGuard } from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { IOFT, SendParam }                from '@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol';
import { MessagingFee, MessagingReceipt } from '@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol';

import { IUtexoSourceEntrypoint } from './interfaces/IUtexoSourceEntrypoint.sol';

/// @title UtexoSourceEntrypoint
/// @notice Utexo's user-facing deposit contract on source chains (Ethereum, OP, Base, …).
/// @dev
///     ┌────────────┐ transferFrom  ┌────────────────────┐   OFT.send    ┌──────────────┐
///     │  user EOA  │──────────────▶│ UtexoSource        │──────────────▶│ USDT0 OFT    │
///     └────────────┘               │ Entrypoint (this)  │               └──────┬───────┘
///                                  └────────────────────┘                      │
///                                                                              │ LayerZero
///                                                                              ▼
///                                                               ┌──────────────────────┐
///                                                               │ UtexoLZAdapter       │
///                                                               │ (destination chain)  │
///                                                               └──────────────────────┘
///
///     Properties:
///       • Owner-controlled emergency pause for deposits, with two-step
///         ownership transfers and ownership renunciation disabled.
///       • Non-upgradeable. Replacement = redeploy.
///       • `dstEid` and `lzAdapter` are fixed at construction and cannot be
///         re-pointed at a different destination by the caller or anyone else.
///       • `composeMsg` is built by the entrypoint as
///         `abi.encode(block.chainid, destinationChainId, destinationAddress, operationId, settlementData)`,
///         where the destination fields and `settlementData` are extracted from
///         the caller-supplied `payload` blob via `abi.decode`. All chain
///         identifiers are `uint256` (real `block.chainid` for EVM endpoints,
///         backend-assigned ids above the EVM range). `settlementData` is an opaque blob whose layout
///         is dictated by the destination route's `SettlementModule` on
///         Arbitrum — the entrypoint plumbs it through unchanged. For routes
///         registered with `NullSettlementModule` (the default for LZ-adapter
///         flows) it is empty (`""`). A malformed `payload` reverts here on the
///         source chain so no LZ fee is ever paid for an un-decodable compose,
///         and the `sourceChainId` part is non-spoofable.
///       • LayerZero fee is re-quoted on-chain; surplus `msg.value` is refunded to
///         `msg.sender`.
contract UtexoSourceEntrypoint is IUtexoSourceEntrypoint, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OwnershipRenunciationDisabled();

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Upper bound on the `settlementData` byte length, mirroring
    ///         `UtexoLZAdapter.MAX_SETTLEMENT_DATA_LENGTH`. Capping it here keeps
    ///         an honest deposit from ever encoding an oversized blob into the
    ///         LayerZero `composeMsg`, which the destination adapter would then
    ///         have to bound (or strand) on the failure path. 1024 bytes is ample
    ///         for the empty `NullSettlementModule` blob used by LZ routes.
    uint256 public constant MAX_SETTLEMENT_DATA_LENGTH = 1024;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @inheritdoc IUtexoSourceEntrypoint
    address public immutable override token;

    /// @inheritdoc IUtexoSourceEntrypoint
    address public immutable override oft;

    /// @inheritdoc IUtexoSourceEntrypoint
    uint32  public immutable override dstEid;

    /// @inheritdoc IUtexoSourceEntrypoint
    bytes32 public immutable override lzAdapter;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param token_      ERC-20 that will be pulled from users and forwarded into
    ///                    the OFT. On Ethereum this is canonical USDT; on chains
    ///                    where USDT0 is native this is the USDT0 token itself.
    /// @param oft_        USDT0 OFT on this chain.
    /// @param dstEid_     LayerZero endpoint id of the destination chain (Arbitrum).
    /// @param lzAdapter_  `UtexoLZAdapter` address on the destination chain, encoded
    ///                    as bytes32 (address left-padded, per LayerZero V2 convention).
    /// @param initialOwner_  Address that receives ownership at deployment.
    constructor(
        address token_,
        address oft_,
        uint32  dstEid_,
        bytes32 lzAdapter_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (token_ == address(0))      revert InvalidTokenAddress();
        if (oft_ == address(0))        revert InvalidOftAddress();
        if (dstEid_ == 0)              revert InvalidDstEid();
        if (lzAdapter_ == bytes32(0))  revert InvalidLZAdapter();

        token     = token_;
        oft       = oft_;
        dstEid    = dstEid_;
        lzAdapter = lzAdapter_;
    }

    // =========================================================================
    // User entry point
    // =========================================================================

    /// @inheritdoc IUtexoSourceEntrypoint
    function deposit(DepositParams calldata depositParams)
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (bytes32 guid)
    {
        if (depositParams.amountLD == 0) revert ZeroAmount();

        // 1. Pull the user's tokens into this contract, then allow the OFT to pull
        //    exactly `amountLD` on `send()`. The OFT consumes the entire allowance
        //    via `transferFrom`;
        IERC20(token).safeTransferFrom(msg.sender, address(this), depositParams.amountLD);
        IERC20(token).safeIncreaseAllowance(oft, depositParams.amountLD);

        // 2. Decode the caller's payload to validate format and extract the
        //    destination fields, then re-encode the actual `composeMsg` with
        //    `block.chainid` prepended. A malformed `payload` reverts here —
        //    on the source chain, before any LZ fee is paid — so honest deposits
        //    can never feed malformed bytes into `UtexoLZAdapter.lzCompose`.
        (
            uint256 destinationChainId,
            string memory destinationAddress,
            uint256 operationId,
            bytes memory settlementData
        ) = abi.decode(depositParams.payload, (uint256, string, uint256, bytes));

        // Bound the opaque blob at the source so an oversized settlementData
        // can never enter the cross-chain composeMsg.
        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }

        bytes memory composeMsg = abi.encode(
            block.chainid,
            destinationChainId,
            destinationAddress,
            operationId,
            settlementData
        );

        // 3. Build the LayerZero send parameters. `dstEid` and `to` are immutable
        //    on this contract — the caller cannot redirect the funds.
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           lzAdapter,
            amountLD:     depositParams.amountLD,
            minAmountLD:  depositParams.minAmountLD,
            extraOptions: depositParams.extraOptions,
            composeMsg:   composeMsg,
            oftCmd:       ''
        });

        // 4. Re-quote the LayerZero fee on-chain. This defends against the window
        //    between `quoteSend` off-chain and transaction inclusion, during which
        //    LayerZero pricing may change.
        MessagingFee memory fee = IOFT(oft).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        // 5. Forward exactly `fee.nativeFee` to the OFT; refund surplus ourselves.
        //    Using `msg.sender` as `refundAddress` is defensive only: with this call
        //    shape the OFT has no surplus to refund.
        (MessagingReceipt memory receipt, ) =
            IOFT(oft).send{ value: fee.nativeFee }(sp, fee, msg.sender);
        guid = receipt.guid;

        // 6. Refund the user's native surplus (msg.value - nativeFee).
        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = msg.sender.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit Deposit(
            guid,
            msg.sender,
            depositParams.amountLD,
            block.chainid,
            destinationChainId,
            destinationAddress,
            operationId,
            settlementData
        );
    }

    /// @inheritdoc IUtexoSourceEntrypoint
    function quote(DepositParams calldata depositParams)
        external
        view
        override
        returns (uint256 nativeFee)
    {
        // Mirror `deposit`'s payload handling so the quote covers the exact
        // composeMsg the actual send would carry.
        (
            uint256 destinationChainId,
            string memory destinationAddress,
            uint256 operationId,
            bytes memory settlementData
        ) = abi.decode(depositParams.payload, (uint256, string, uint256, bytes));

        // Same cap as `deposit` so the quote reverts on exactly the inputs the
        // send would reject.
        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }

        bytes memory composeMsg = abi.encode(
            block.chainid,
            destinationChainId,
            destinationAddress,
            operationId,
            settlementData
        );
        SendParam memory sp = SendParam({
            dstEid:       dstEid,
            to:           lzAdapter,
            amountLD:     depositParams.amountLD,
            minAmountLD:  depositParams.minAmountLD,
            extraOptions: depositParams.extraOptions,
            composeMsg:   composeMsg,
            oftCmd:       ''
        });
        return IOFT(oft).quoteSend(sp, false).nativeFee;
    }

    // =========================================================================
    // Owner actions
    // =========================================================================

    /// @notice Pauses deposits.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes deposits.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Ownership cannot be renounced to preserve access to emergency controls.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }
}
