// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title MockBridge
/// @notice Minimal Bridge stub for testing `UtexoLZAdapter` in isolation. Pulls
///         the locked tokens via `transferFrom` (proves the caller set the
///         allowance) and records the call args + forwarded `msg.value` so
///         tests can assert byte-for-byte forwarding.
///
/// @dev    Implements only the adapter-only `fundsIn` overload that
///         `UtexoLZAdapter.lzCompose` invokes. Not declared as `IBridge` —
///         Solidity dispatches by selector at runtime, so a matching function
///         signature on this stub is sufficient. The full upstream `IBridge`
///         lives in the bridge-smart-contracts submodule and would require
///         stubbing many unrelated members (`fundsOut`, `setLZAdapter`, …)
///         that the adapter never calls in tests.
contract MockBridge {
    address public immutable token;

    /// Force `fundsIn` to revert — used by failure-path tests.
    bool public reverts;

    /// Optional exact native value expectation — used to model Bridge native
    /// commission mismatch without pulling in the real Bridge dependency.
    bool public checksMsgValue;
    uint256 public expectedMsgValue;

    /// @notice When non-zero, `fundsIn` returns this fixed operationId so tests
    ///         can assert the value the adapter surfaces on `ComposeFundsIn`.
    ///         Otherwise `fundsIn` returns a deterministic keccak derivation.
    bytes32 public operationIdToReturn;

    // Last-call recording -----------------------------------------------------
    uint256 public lastAmount;
    uint256 public lastSourceChainId;
    uint256 public lastDestinationChainId;
    string  public lastDestinationAddress;
    bytes32 public lastSourceSender;
    bytes   public lastSettlementData;
    uint256 public lastMsgValue;
    address public lastCaller;

    /// @notice The operationId the last `fundsIn` call returned — assertable by tests.
    bytes32 public lastReturnedOperationId;

    constructor(address token_) {
        token = token_;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function setExpectedMsgValue(uint256 expected) external {
        checksMsgValue  = true;
        expectedMsgValue = expected;
    }

    function setOperationIdToReturn(bytes32 v) external {
        operationIdToReturn = v;
    }

    /// @notice Mirrors the adapter-only overload
    ///         `Bridge.fundsIn(uint256 amount, uint256 sourceChainId,
    ///                         bytes32 sourceSender, uint256 destinationChainId,
    ///                         string destinationAddress, bytes settlementData)
    ///                         returns (bytes32 operationId)`.
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        bytes   calldata settlementData
    ) external payable returns (bytes32 operationId) {
        require(!reverts, 'MockBridge: forced revert');
        require(!checksMsgValue || msg.value == expectedMsgValue, 'MockBridge: native value mismatch');

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastAmount             = amount;
        lastSourceChainId      = sourceChainId;
        lastSourceSender       = sourceSender;
        lastDestinationChainId = destinationChainId;
        lastDestinationAddress = destinationAddress;
        lastSettlementData     = settlementData;
        lastMsgValue           = msg.value;
        lastCaller             = msg.sender;

        operationId = operationIdToReturn != bytes32(0)
            ? operationIdToReturn
            : keccak256(abi.encode(sourceChainId, sourceSender, amount, destinationChainId, destinationAddress, settlementData));
        lastReturnedOperationId = operationId;
    }

    receive() external payable {}
}
