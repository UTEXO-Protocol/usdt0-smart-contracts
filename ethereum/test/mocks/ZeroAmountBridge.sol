// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @dev Deposit stub that rejects a zero token amount.
contract ZeroAmountBridge {
    error AmountBelowMinimum(uint256 amount, uint256 minimum);

    function fundsIn(uint256 amount, uint256, bytes32, uint256, string calldata, bytes calldata)
        external
        payable
        returns (bytes32)
    {
        if (amount == 0) revert AmountBelowMinimum(0, 1);
        return bytes32(0);
    }

    receive() external payable {}
}
