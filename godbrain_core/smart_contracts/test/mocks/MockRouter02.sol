// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IUniswapV2Router02 } from "../../src/interfaces/IUniswapV2Router02.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockRouter02 is IUniswapV2Router02 {
    enum Behavior {
        Success,
        RevertCall,
        MalformedOutput,
        PartialPull,
        ExcessPull,
        Callback,
        RebaseInput
    }

    error RouterFailure();
    error InvalidRoute();
    error Expired();
    error MinimumNotMet();

    address public immutable tokenIn;
    address public immutable tokenOut;
    uint256 public amountOut;
    Behavior public behavior;
    bytes public callbackData;

    constructor(address tokenIn_, address tokenOut_, uint256 amountOut_) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        amountOut = amountOut_;
    }

    function setAmountOut(uint256 amountOut_) external {
        amountOut = amountOut_;
    }

    function setBehavior(Behavior behavior_, bytes calldata callbackData_) external {
        behavior = behavior_;
        callbackData = callbackData_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        override
        returns (uint256[] memory amounts)
    {
        if (behavior == Behavior.RevertCall) revert RouterFailure();
        if (path.length != 2 || path[0] != tokenIn || path[1] != tokenOut || to != msg.sender) {
            revert InvalidRoute();
        }
        // The mock mirrors Router02's timestamp deadline semantics.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert Expired();
        if (amountOut < amountOutMin) revert MinimumNotMet();

        uint256 pullAmount = amountIn;
        if (behavior == Behavior.PartialPull) pullAmount = amountIn - 1;
        if (behavior == Behavior.ExcessPull) pullAmount = amountIn + 1;
        require(MockERC20(tokenIn).transferFrom(msg.sender, address(this), pullAmount));
        require(MockERC20(tokenOut).transfer(to, amountOut));

        if (behavior == Behavior.RebaseInput) MockERC20(tokenIn).mint(msg.sender, 1);
        if (behavior == Behavior.Callback) {
            (bool success,) = msg.sender.call(callbackData);
            require(success, "callback failed");
        }
        if (behavior == Behavior.MalformedOutput) {
            assembly ("memory-safe") {
                mstore(0, 0x20)
                mstore(0x20, 1)
                mstore(0x40, amountIn)
                return(0, 0x60)
            }
        }

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
