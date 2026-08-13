// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MockERC20 } from "./MockERC20.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") { }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool success,) = msg.sender.call{ value: amount }("");
        require(success, "ETH transfer failed");
    }
}
