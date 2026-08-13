// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MockERC20 } from "./MockERC20.sol";

contract MockFeeOnTransferERC20 is MockERC20 {
    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_) { }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        uint256 fee = amount / 100;
        _balanceOf[sender] -= amount;
        _balanceOf[recipient] += amount - fee;
        emit Transfer(sender, recipient, amount - fee);
        emit Transfer(sender, address(0), fee);
    }
}
