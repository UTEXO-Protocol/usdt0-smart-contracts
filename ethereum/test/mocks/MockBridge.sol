// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockBridge
/// @notice Deposit stub that records inputs and optionally rejects calls.
/// @dev Implements only the adapter-facing fundsIn overload.
contract MockBridge {
    address public immutable token;

    /// Force `fundsIn` to revert — used by failure-path tests.
    bool public reverts;

    /// @notice Whether deposits must match the configured native value.
    bool public checksMsgValue;
    uint256 public expectedMsgValue;

    /// @notice Optional operation-id override; zero selects the mock's deterministic derivation.
    bytes32 public operationIdToReturn;

    // Last-call recording -----------------------------------------------------
    uint256 public lastAmount;
    uint256 public lastSourceChainId;
    uint256 public lastDestinationChainId;
    string public lastDestinationAddress;
    bytes32 public lastSourceSender;
    bytes public lastSettlementData;
    uint256 public lastMsgValue;
    address public lastCaller;

    /// @notice Operation id returned by the last successful deposit.
    bytes32 public lastReturnedOperationId;

    constructor(address token_) {
        token = token_;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function setExpectedMsgValue(uint256 expected) external {
        checksMsgValue = true;
        expectedMsgValue = expected;
    }

    function setOperationIdToReturn(bytes32 v) external {
        operationIdToReturn = v;
    }

    /// @notice Pulls tokens and records the adapter deposit parameters.
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable returns (bytes32 operationId) {
        require(!reverts, "MockBridge: forced revert");
        require(!checksMsgValue || msg.value == expectedMsgValue, "MockBridge: native value mismatch");

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastAmount = amount;
        lastSourceChainId = sourceChainId;
        lastSourceSender = sourceSender;
        lastDestinationChainId = destinationChainId;
        lastDestinationAddress = destinationAddress;
        lastSettlementData = settlementData;
        lastMsgValue = msg.value;
        lastCaller = msg.sender;

        operationId = operationIdToReturn != bytes32(0)
            ? operationIdToReturn
            : keccak256(
                abi.encode(sourceChainId, sourceSender, amount, destinationChainId, destinationAddress, settlementData)
            );
        lastReturnedOperationId = operationId;
    }

    receive() external payable {}
}
