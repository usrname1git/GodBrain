// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { ITwoRouterCycleExecutor } from "./interfaces/ITwoRouterCycleExecutor.sol";
import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router02.sol";

/// @title TwoRouterCycleExecutor
/// @notice Solver-bound executor for one exact-input token A -> token B -> token A cycle.
contract TwoRouterCycleExecutor is ITwoRouterCycleExecutor, ReentrancyGuard {
    address public immutable override solver;

    error OnlySolver();
    error InvalidAddress();
    error InvalidContract(address account);
    error InvalidAmount();
    error InvalidPath();
    error Expired(uint256 deadline, uint256 currentTimestamp);
    error UnexpectedAllowance(address token, address spender, uint256 actual, uint256 expected);
    error ExistingResidue(address token, uint256 amount);
    error UnexpectedBalance(address token, uint256 actual, uint256 expected);
    error RouterCallFailed(address router, bytes4 reason);
    error MalformedRouterOutput(address router, uint256 returnDataLength);
    error RouterAmountsMismatch(address router, uint256 reportedInput, uint256 reportedOutput, uint256 actualOutput);
    error InsufficientOutput(uint256 actual, uint256 minimum);

    event CycleExecuted(
        address indexed tokenA,
        address indexed tokenB,
        address indexed routerOne,
        address routerTwo,
        uint256 returnedPrincipal,
        uint256 intermediateAmount,
        uint256 returnedAmount,
        uint256 grossProfit,
        uint256 minimumReturnedAmount
    );
    event ResidueRecovered(address indexed token, uint256 amount);

    modifier onlySolver() {
        if (msg.sender != solver) revert OnlySolver();
        _;
    }

    constructor(address solver_) {
        if (solver_ == address(0)) revert InvalidAddress();
        if (solver_.code.length == 0) revert InvalidContract(solver_);
        solver = solver_;
    }

    function executeCycle(CycleParams calldata params)
        external
        override
        onlySolver
        nonReentrant
        returns (uint256 returnedAmount)
    {
        _validate(params);

        uint256 tokenABalance = SafeTransferLib.balanceOf(params.tokenA, address(this));
        uint256 tokenBBalance = SafeTransferLib.balanceOf(params.tokenB, address(this));
        if (tokenABalance != 0) revert ExistingResidue(params.tokenA, tokenABalance);
        if (tokenBBalance != 0) revert ExistingResidue(params.tokenB, tokenBBalance);
        _requireAllowance(params.tokenA, solver, address(this), params.amountIn);

        uint256 solverBalanceBefore = SafeTransferLib.balanceOf(params.tokenA, solver);
        SafeTransferLib.safeTransferFrom(params.tokenA, solver, address(this), params.amountIn);
        uint256 solverBalanceAfterPull = SafeTransferLib.balanceOf(params.tokenA, solver);
        if (solverBalanceBefore < params.amountIn || solverBalanceAfterPull != solverBalanceBefore - params.amountIn) {
            revert UnexpectedBalance(params.tokenA, solverBalanceAfterPull, solverBalanceBefore - params.amountIn);
        }
        _requireBalance(params.tokenA, params.amountIn);

        _setExactAllowance(params.tokenA, params.routerOne, params.amountIn);
        (uint256 reportedFirstInput, uint256 reportedFirstOutput) = _callRouter(
            params.routerOne,
            params.amountIn,
            params.minimumAmountOutFirst,
            params.tokenA,
            params.tokenB,
            params.deadline
        );
        _clearAllowance(params.tokenA, params.routerOne);

        _requireBalance(params.tokenA, 0);
        uint256 intermediateAmount = SafeTransferLib.balanceOf(params.tokenB, address(this));
        if (intermediateAmount < params.minimumAmountOutFirst) {
            revert InsufficientOutput(intermediateAmount, params.minimumAmountOutFirst);
        }
        if (reportedFirstInput != params.amountIn || reportedFirstOutput != intermediateAmount) {
            revert RouterAmountsMismatch(params.routerOne, reportedFirstInput, reportedFirstOutput, intermediateAmount);
        }

        _setExactAllowance(params.tokenB, params.routerTwo, intermediateAmount);
        (uint256 reportedSecondInput, uint256 reportedSecondOutput) = _callRouter(
            params.routerTwo,
            intermediateAmount,
            params.minimumAmountOutSecond,
            params.tokenB,
            params.tokenA,
            params.deadline
        );
        _clearAllowance(params.tokenB, params.routerTwo);

        _requireBalance(params.tokenB, 0);
        returnedAmount = SafeTransferLib.balanceOf(params.tokenA, address(this));
        if (returnedAmount < params.minimumAmountOutSecond) {
            revert InsufficientOutput(returnedAmount, params.minimumAmountOutSecond);
        }
        if (returnedAmount < params.minimumReturnedAmount) {
            revert InsufficientOutput(returnedAmount, params.minimumReturnedAmount);
        }
        if (reportedSecondInput != intermediateAmount || reportedSecondOutput != returnedAmount) {
            revert RouterAmountsMismatch(params.routerTwo, reportedSecondInput, reportedSecondOutput, returnedAmount);
        }

        SafeTransferLib.safeTransfer(params.tokenA, solver, returnedAmount);
        _requireBalance(params.tokenA, 0);
        uint256 solverBalanceAfterReturn = SafeTransferLib.balanceOf(params.tokenA, solver);
        if (solverBalanceAfterReturn != solverBalanceAfterPull + returnedAmount) {
            revert UnexpectedBalance(params.tokenA, solverBalanceAfterReturn, solverBalanceAfterPull + returnedAmount);
        }

        emit CycleExecuted(
            params.tokenA,
            params.tokenB,
            params.routerOne,
            params.routerTwo,
            params.amountIn,
            intermediateAmount,
            returnedAmount,
            returnedAmount - params.amountIn,
            params.minimumReturnedAmount
        );
    }

    /// @notice Returns accidental ERC-20 residue to the immutable solver.
    /// @dev The solver owner controls access to this function through the solver boundary.
    function recoverToken(address token) external override onlySolver nonReentrant returns (uint256 recoveredAmount) {
        if (token == address(0)) revert InvalidAddress();
        if (token.code.length == 0) revert InvalidContract(token);
        recoveredAmount = SafeTransferLib.balanceOf(token, address(this));
        if (recoveredAmount == 0) revert InvalidAmount();
        uint256 solverBalanceBefore = SafeTransferLib.balanceOf(token, solver);
        SafeTransferLib.safeTransfer(token, solver, recoveredAmount);
        _requireBalance(token, 0);
        uint256 solverBalanceAfter = SafeTransferLib.balanceOf(token, solver);
        if (solverBalanceAfter != solverBalanceBefore + recoveredAmount) {
            revert UnexpectedBalance(token, solverBalanceAfter, solverBalanceBefore + recoveredAmount);
        }
        emit ResidueRecovered(token, recoveredAmount);
    }

    function _validate(CycleParams calldata params) private view {
        if (
            params.tokenA == address(0) || params.tokenB == address(0) || params.routerOne == address(0)
                || params.routerTwo == address(0)
        ) {
            revert InvalidAddress();
        }
        if (params.tokenA.code.length == 0) revert InvalidContract(params.tokenA);
        if (params.tokenB.code.length == 0) revert InvalidContract(params.tokenB);
        if (params.routerOne.code.length == 0) revert InvalidContract(params.routerOne);
        if (params.routerTwo.code.length == 0) revert InvalidContract(params.routerTwo);
        if (
            params.tokenA == params.tokenB || params.routerOne == params.routerTwo || params.routerOne == address(this)
                || params.routerTwo == address(this) || params.routerOne == solver || params.routerTwo == solver
                || params.routerOne == params.tokenA || params.routerOne == params.tokenB
                || params.routerTwo == params.tokenA || params.routerTwo == params.tokenB
        ) {
            revert InvalidPath();
        }
        if (
            params.amountIn == 0 || params.minimumAmountOutFirst == 0 || params.minimumAmountOutSecond == 0
                || params.minimumReturnedAmount < params.amountIn
        ) {
            revert InvalidAmount();
        }
        // Router02 deadlines intentionally use the current block timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (params.deadline < block.timestamp) revert Expired(params.deadline, block.timestamp);
    }

    function _callRouter(
        address router,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address tokenIn,
        address tokenOut,
        uint256 deadline
    )
        private
        returns (uint256 reportedInput, uint256 reportedOutput)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        bytes memory callData = abi.encodeCall(
            IUniswapV2Router02.swapExactTokensForTokens, (amountIn, amountOutMinimum, path, address(this), deadline)
        );

        bool success;
        uint256 returnDataLength;
        bytes4 reason;
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            let returnData := mload(0x40)
            success := call(gas(), router, 0, add(callData, 0x20), mload(callData), 0, 0)
            returnDataLength := returndatasize()
            if iszero(success) {
                if gt(returnDataLength, 3) {
                    returndatacopy(returnData, 0, 4)
                    reason := mload(returnData)
                }
            }
            if and(success, eq(returnDataLength, 0x80)) {
                returndatacopy(returnData, 0, 0x80)
                offset := mload(returnData)
                length := mload(add(returnData, 0x20))
                reportedInput := mload(add(returnData, 0x40))
                reportedOutput := mload(add(returnData, 0x60))
            }
        }
        if (!success) revert RouterCallFailed(router, reason);
        if (returnDataLength != 128 || offset != 32 || length != 2) {
            revert MalformedRouterOutput(router, returnDataLength);
        }
    }

    function _setExactAllowance(address token, address spender, uint256 amount) private {
        uint256 currentAllowance = _allowance(token, address(this), spender);
        if (currentAllowance != 0) {
            SafeTransferLib.safeApprove(token, spender, 0);
            _requireAllowance(token, address(this), spender, 0);
        }
        SafeTransferLib.safeApproveWithRetry(token, spender, amount);
        _requireAllowance(token, address(this), spender, amount);
    }

    function _clearAllowance(address token, address spender) private {
        SafeTransferLib.safeApprove(token, spender, 0);
        _requireAllowance(token, address(this), spender, 0);
    }

    function _requireBalance(address token, uint256 expected) private view {
        uint256 actual = SafeTransferLib.balanceOf(token, address(this));
        if (actual != expected) revert UnexpectedBalance(token, actual, expected);
    }

    function _requireAllowance(address token, address owner, address spender, uint256 expected) private view {
        uint256 actual = _allowance(token, owner, spender);
        if (actual != expected) revert UnexpectedAllowance(token, spender, actual, expected);
    }

    function _allowance(address token, address owner, address spender) private view returns (uint256 amount) {
        bool success;
        uint256 returnDataLength;
        assembly ("memory-safe") {
            let data := mload(0x40)
            mstore(data, shl(224, 0xdd62ed3e))
            mstore(add(data, 4), owner)
            mstore(add(data, 36), spender)
            success := staticcall(gas(), token, data, 68, data, 32)
            returnDataLength := returndatasize()
            amount := mload(data)
        }
        if (!success || returnDataLength != 32) revert InvalidContract(token);
    }
}
