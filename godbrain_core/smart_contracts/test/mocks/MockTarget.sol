// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MockERC20 } from "./MockERC20.sol";

contract MockTarget {
    error TargetFailure();

    function deliver(MockERC20 token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount), "token transfer failed");
    }

    function fail() external pure {
        revert TargetFailure();
    }
}
