// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
/// @notice Sends source-chain deposits to the Utexo adapter on Arbitrum through USDT0 OFT.
/// @dev Routing is immutable. The owner can pause deposits and transfer ownership in two steps.
///      The compose payload binds the source chain and caller to the supplied destination data.
contract UtexoSourceEntrypoint is IUtexoSourceEntrypoint, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OwnershipRenunciationDisabled();

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum settlement payload length, in bytes.
    /// @dev Must not exceed the matching UtexoLZAdapter limit; oversized composes revert without a record.
    uint256 public constant MAX_SETTLEMENT_DATA_LENGTH = 128;

    /// @notice Maximum destination address length, in bytes.
    /// @dev Must not exceed the matching UtexoLZAdapter limit; oversized composes revert without a record.
    uint256 public constant MAX_DESTINATION_ADDRESS_LENGTH = 512;

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

    /// @param token_ Source token forwarded to the OFT.
    /// @param oft_ Source-chain OFT; its `token()` must equal `token_`.
    /// @param dstEid_ LayerZero EID of the destination chain (Arbitrum).
    /// @param lzAdapter_ Nonzero Arbitrum adapter address, left-padded with 12 zero bytes.
    /// @param initialOwner_ Initial owner; may differ from the deployer.
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
        if (lzAdapter_ == bytes32(0) || uint256(lzAdapter_) >> 160 != 0) revert InvalidLZAdapter();

        address oftToken = IOFT(oft_).token();
        if (oftToken != token_) revert OftTokenMismatch(oft_, oftToken, token_);

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

        IERC20(token).safeTransferFrom(msg.sender, address(this), depositParams.amountLD);
        IERC20(token).safeIncreaseAllowance(oft, depositParams.amountLD);

        (
            uint256 destinationChainId,
            string memory destinationAddress,
            bytes memory settlementData
        ) = abi.decode(depositParams.payload, (uint256, string, bytes));
        if (destinationChainId == 0) revert InvalidDestinationChainId();

        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (bytes(destinationAddress).length > MAX_DESTINATION_ADDRESS_LENGTH) {
            revert DestinationAddressTooLong(bytes(destinationAddress).length, MAX_DESTINATION_ADDRESS_LENGTH);
        }

        bytes memory composeMsg = abi.encode(
            block.chainid,
            bytes32(uint256(uint160(msg.sender))), // authenticated source sender, stamped by the entrypoint
            destinationChainId,
            destinationAddress,
            settlementData,
            depositParams.expectedComposeValue
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

        // Re-quote before sending to use execution-time LayerZero pricing.
        MessagingFee memory fee = IOFT(oft).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee({ provided: msg.value, required: fee.nativeFee });
        }

        address refundTo = depositParams.refundTo == address(0)
            ? msg.sender
            : depositParams.refundTo;

        // The OFT receives the quoted fee; refund the remaining value separately.
        (MessagingReceipt memory receipt, ) =
            IOFT(oft).send{ value: fee.nativeFee }(sp, fee, refundTo);
        guid = receipt.guid;

        uint256 excess = msg.value - fee.nativeFee;
        if (excess != 0) {
            (bool ok, ) = refundTo.call{ value: excess }('');
            if (!ok) revert NativeRefundFailed();
        }

        emit Deposit(
            guid,
            msg.sender,
            depositParams.amountLD,
            block.chainid,
            destinationChainId,
            destinationAddress,
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
        if (depositParams.amountLD == 0) revert ZeroAmount();

        (
            uint256 destinationChainId,
            string memory destinationAddress,
            bytes memory settlementData
        ) = abi.decode(depositParams.payload, (uint256, string, bytes));
        if (destinationChainId == 0) revert InvalidDestinationChainId();

        if (settlementData.length > MAX_SETTLEMENT_DATA_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_LENGTH);
        }
        if (bytes(destinationAddress).length > MAX_DESTINATION_ADDRESS_LENGTH) {
            revert DestinationAddressTooLong(bytes(destinationAddress).length, MAX_DESTINATION_ADDRESS_LENGTH);
        }

        bytes memory composeMsg = abi.encode(
            block.chainid,
            bytes32(uint256(uint160(msg.sender))), // authenticated source sender, stamped by the entrypoint
            destinationChainId,
            destinationAddress,
            settlementData,
            depositParams.expectedComposeValue
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

    /// @notice Always reverts; ownership cannot be renounced.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }
}
