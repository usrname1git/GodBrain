// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MockERC20 } from "./MockERC20.sol";

contract MockResetFailureERC20 is MockERC20 {
    bool public failZeroApproval;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_) { }

    function setFailZeroApproval(bool fail) external {
        failZeroApproval = fail;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (failZeroApproval && amount == 0) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }
}
