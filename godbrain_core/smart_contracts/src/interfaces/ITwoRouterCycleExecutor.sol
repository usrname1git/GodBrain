// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITwoRouterCycleExecutor {
    struct CycleParams {
        address tokenA;
        address tokenB;
        address routerOne;
        address routerTwo;
        uint256 amountIn;
        uint256 minimumAmountOutFirst;
        uint256 minimumAmountOutSecond;
        uint256 minimumReturnedAmount;
        uint256 deadline;
    }

    function solver() external view returns (address);

    function executeCycle(CycleParams calldata params) external returns (uint256 returnedAmount);

    function recoverToken(address token) external returns (uint256 recoveredAmount);
}
