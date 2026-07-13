// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @dev Minimal Bridge-shaped mock that rejects zero amount like the real Bridge
///      adapter overload does via its minimum-amount guard.
contract ZeroAmountBridge {
    error AmountBelowMinimum(uint256 amount, uint256 minimum);

    function fundsIn(
        uint256 amount,
        uint256,
        uint256,
        string calldata,
        uint256,
        bytes calldata
    ) external payable {
        if (amount == 0) revert AmountBelowMinimum(0, 1);
    }

    receive() external payable {}
}
