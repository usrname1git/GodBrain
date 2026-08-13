// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MockERC20 } from "./MockERC20.sol";

contract MockZeroFirstERC20 is MockERC20 {
    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_) { }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (amount != 0 && allowance[msg.sender][spender] != 0) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }
}
