// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { MockERC20 } from './MockERC20.sol';

/// @dev Allows normal nonzero approvals but rejects zero approvals, which
///      models a catch-cleanup failure in `UtexoLZAdapter.lzCompose`.
contract ZeroApprovalRevertingERC20 is MockERC20 {
    constructor() MockERC20('Bad USDT', 'BAD') {}

    function approve(address spender, uint256 value) public override returns (bool) {
        if (value == 0) revert('ZeroApprovalRevertingERC20: zero approval');
        return super.approve(spender, value);
    }
}
