// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Narrow interface for forwarding USDT0 deposits into the Arbitrum Bridge.
interface IBridgeFundsIn {
    struct FundsInAuthorization {
        bytes32 authorizationNonce;
        uint256 deadline;
        bytes signature;
    }

    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData,
        FundsInAuthorization calldata authorization
    ) external payable returns (bytes32 operationId);
}
