// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { ITwoRouterCycleExecutor } from "./interfaces/ITwoRouterCycleExecutor.sol";

/// @title GodBrainMEV
/// @notice Minimal Atlas solver skeleton for allowlisted ERC-20 output-producing calls.
/// @dev SolverBase enforces Atlas entry, owner-originated solver operations, bid payment, and reconciliation.
contract GodBrainMEV is SolverBase {
    uint256 public constant MAX_SOLVER_OP_DATA_LENGTH = 16 * 1024;

    mapping(address target => bool allowed) public isTargetAllowed;

    error NotOwner();
    error OnlySelf();
    error InvalidAddress();
    error InvalidContract(address account);
    error InvalidAmount();
    error EmptyCallData();
    error InvalidSolverOpData();
    error SolverOpDataTooLarge(uint256 actual, uint256 maximum);
    error TargetNotAllowed(address target);
    error TargetCallFailed(bytes returnData);
    error InvalidExecutorBinding(address executor, address expectedSolver);
    error ExecutorCallFailed(address executor, bytes4 reason);
    error UnexpectedAllowance(address token, address spender, uint256 actual, uint256 expected);
    error UnexpectedTokenBalance(address token, uint256 actual, uint256 expected);
    error InvalidCycle();
    error InsufficientNetOutputIncrease(uint256 actual, uint256 minimum);

    event TargetPermissionUpdated(address indexed target, bool allowed);
    event SolverExecution(address indexed target, address indexed outputToken, uint256 grossOutputIncrease);
    event CycleExecution(
        address indexed executor,
        address indexed inputToken,
        uint256 returnedPrincipal,
        uint256 returnedAmount,
        uint256 grossProfit,
        uint256 minimumReturnedAmount,
        uint256 minimumNetProfit
    );
    event ExecutorTokenRecovered(address indexed executor, address indexed token, uint256 amount);
    event NetOutputVerified(address indexed outputToken, uint256 netOutputIncrease, uint256 minimumNetOutputIncrease);
    event TokenWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event NativeWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier enforceMinimumNetOutput(bytes calldata solverOpData) {
        (address outputToken, uint256 minimumNetOutputIncrease) = _decodeSolverOpData(solverOpData);
        if (outputToken == address(0)) revert InvalidAddress();
        if (outputToken.code.length == 0) revert InvalidContract(outputToken);
        if (minimumNetOutputIncrease == 0) revert InvalidAmount();

        uint256 balanceBefore = SafeTransferLib.balanceOf(outputToken, address(this));
        _;
        uint256 balanceAfter = SafeTransferLib.balanceOf(outputToken, address(this));
        uint256 netOutputIncrease = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (netOutputIncrease < minimumNetOutputIncrease) {
            revert InsufficientNetOutputIncrease(netOutputIncrease, minimumNetOutputIncrease);
        }

        emit NetOutputVerified(outputToken, netOutputIncrease, minimumNetOutputIncrease);
    }

    constructor(address wrappedNative, address atlas_, address owner_) SolverBase(wrappedNative, atlas_, owner_) {
        if (wrappedNative == address(0) || atlas_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        if (wrappedNative.code.length == 0) revert InvalidContract(wrappedNative);
        if (atlas_.code.length == 0) revert InvalidContract(atlas_);
    }

    receive() external payable { }

    function owner() external view returns (address) {
        return _owner;
    }

    function atlas() external view returns (address) {
        return _atlas;
    }

    /// @inheritdoc SolverBase
    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata
    )
        external
        payable
        override
        safetyFirst(executionEnvironment, solverOpFrom)
        enforceMinimumNetOutput(solverOpData)
        payBids(executionEnvironment, bidToken, bidAmount)
    {
        (bool success,) = address(this).call{ value: msg.value }(solverOpData);
        if (!success) revert SolverCallUnsuccessful();
    }

    /// @notice Allows or removes an execution target.
    /// @dev Targets must be reviewed contracts. Atlas, this solver, and a contract owner cannot be targets.
    function setTargetAllowed(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert InvalidAddress();
        if (allowed && (target.code.length == 0 || target == address(this) || target == _atlas || target == _owner)) {
            revert InvalidContract(target);
        }

        isTargetAllowed[target] = allowed;
        emit TargetPermissionUpdated(target, allowed);
    }

    /// @notice Executes one allowlisted call and measures its gross ERC-20 output.
    /// @dev Must be encoded as solverOpData and reached through atlasSolverCall.
    /// The minimum applies to the net token increase after SolverBase pays the bid, not to this gross measurement.
    /// Native value is retained by this contract for SolverBase reconciliation and is never forwarded to the target.
    function execute(
        address target,
        bytes calldata callData,
        address outputToken,
        uint256 minimumNetOutputIncrease
    )
        external
        payable
        onlySelf
    {
        if (!isTargetAllowed[target]) revert TargetNotAllowed(target);
        if (callData.length == 0) revert EmptyCallData();
        if (outputToken == address(0)) revert InvalidAddress();
        if (outputToken.code.length == 0) revert InvalidContract(outputToken);
        if (minimumNetOutputIncrease == 0) revert InvalidAmount();

        uint256 balanceBefore = SafeTransferLib.balanceOf(outputToken, address(this));
        (bool success, bytes memory returnData) = target.call(callData);
        if (!success) revert TargetCallFailed(returnData);

        uint256 balanceAfter = SafeTransferLib.balanceOf(outputToken, address(this));
        uint256 grossOutputIncrease = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        emit SolverExecution(target, outputToken, grossOutputIncrease);
    }

    /// @notice Executes one typed two-router cycle through a solver-bound, allowlisted executor.
    /// @dev Must be encoded as solverOpData and reached through atlasSolverCall. Native value remains in this solver.
    function executeCycle(
        address executor,
        ITwoRouterCycleExecutor.CycleParams calldata params,
        uint256 minimumNetOutputIncrease
    )
        external
        payable
        onlySelf
    {
        _validateCycle(executor, params, minimumNetOutputIncrease);

        uint256 balanceBefore = SafeTransferLib.balanceOf(params.tokenA, address(this));
        if (balanceBefore < params.amountIn) revert InvalidAmount();

        _setExactAllowance(params.tokenA, executor, params.amountIn);
        uint256 returnedAmount = _callExecutor(executor, params);
        _clearAllowance(params.tokenA, executor);

        uint256 expectedBalance = balanceBefore - params.amountIn + returnedAmount;
        uint256 balanceAfter = SafeTransferLib.balanceOf(params.tokenA, address(this));
        if (balanceAfter != expectedBalance) {
            revert UnexpectedTokenBalance(params.tokenA, balanceAfter, expectedBalance);
        }
        if (returnedAmount < params.minimumReturnedAmount || returnedAmount < params.amountIn) {
            revert InvalidAmount();
        }

        emit CycleExecution(
            executor,
            params.tokenA,
            params.amountIn,
            returnedAmount,
            returnedAmount - params.amountIn,
            params.minimumReturnedAmount,
            minimumNetOutputIncrease
        );
    }

    /// @notice Returns accidental executor residue to this solver for ordinary owner withdrawal.
    function recoverExecutorToken(address executor, address token) external onlyOwner {
        _validateExecutor(executor);
        if (token == address(0)) revert InvalidAddress();
        if (token.code.length == 0) revert InvalidContract(token);
        uint256 amount = ITwoRouterCycleExecutor(executor).recoverToken(token);
        emit ExecutorTokenRecovered(executor, token, amount);
    }

    function withdrawToken(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (token.code.length == 0) revert InvalidContract(token);
        if (amount == 0) revert InvalidAmount();

        SafeTransferLib.safeTransfer(token, recipient, amount);
        emit TokenWithdrawn(token, recipient, amount);
    }

    function withdrawNative(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        SafeTransferLib.safeTransferETH(recipient, amount);
        emit NativeWithdrawn(recipient, amount);
    }

    function _decodeSolverOpData(bytes calldata solverOpData)
        internal
        pure
        returns (address outputToken, uint256 minimumNetOutputIncrease)
    {
        if (solverOpData.length > MAX_SOLVER_OP_DATA_LENGTH) {
            revert SolverOpDataTooLarge(solverOpData.length, MAX_SOLVER_OP_DATA_LENGTH);
        }
        if (solverOpData.length < 4) revert InvalidSolverOpData();

        bytes4 selector;
        assembly {
            selector := calldataload(solverOpData.offset)
        }
        if (selector == GodBrainMEV.execute.selector) {
            return _decodeGenericExecution(solverOpData);
        }
        if (selector == GodBrainMEV.executeCycle.selector) {
            return _decodeCycleExecution(solverOpData);
        }
        revert InvalidSolverOpData();
    }

    function _decodeGenericExecution(bytes calldata solverOpData)
        private
        pure
        returns (address outputToken, uint256 minimumNetOutputIncrease)
    {
        if (solverOpData.length < 164) revert InvalidSolverOpData();
        uint256 dynamicOffset;
        uint256 dynamicLength;
        assembly ("memory-safe") {
            dynamicOffset := calldataload(add(solverOpData.offset, 36))
            dynamicLength := calldataload(add(solverOpData.offset, 132))
        }
        if (dynamicOffset != 128 || dynamicLength > type(uint256).max - 31) revert InvalidSolverOpData();
        uint256 paddedLength = (dynamicLength + 31) & ~uint256(31);
        if (paddedLength > type(uint256).max - 164 || solverOpData.length != 164 + paddedLength) {
            revert InvalidSolverOpData();
        }

        (address target, bytes memory callData, address decodedOutputToken, uint256 decodedMinimum) =
            abi.decode(solverOpData[4:], (address, bytes, address, uint256));
        bytes memory canonicalData =
            abi.encodeWithSelector(GodBrainMEV.execute.selector, target, callData, decodedOutputToken, decodedMinimum);
        if (keccak256(solverOpData) != keccak256(canonicalData)) revert InvalidSolverOpData();
        return (decodedOutputToken, decodedMinimum);
    }

    function _decodeCycleExecution(bytes calldata solverOpData)
        private
        pure
        returns (address outputToken, uint256 minimumNetOutputIncrease)
    {
        if (solverOpData.length != 356) revert InvalidSolverOpData();
        (address executor, ITwoRouterCycleExecutor.CycleParams memory params, uint256 decodedMinimum) =
            abi.decode(solverOpData[4:], (address, ITwoRouterCycleExecutor.CycleParams, uint256));
        bytes memory canonicalData =
            abi.encodeWithSelector(GodBrainMEV.executeCycle.selector, executor, params, decodedMinimum);
        if (keccak256(solverOpData) != keccak256(canonicalData)) revert InvalidSolverOpData();
        return (params.tokenA, decodedMinimum);
    }

    function _validateCycle(
        address executor,
        ITwoRouterCycleExecutor.CycleParams calldata params,
        uint256 minimumNetOutputIncrease
    )
        private
        view
    {
        _validateExecutor(executor);
        if (!isTargetAllowed[params.routerOne]) revert TargetNotAllowed(params.routerOne);
        if (!isTargetAllowed[params.routerTwo]) revert TargetNotAllowed(params.routerTwo);
        if (params.routerOne.code.length == 0) revert InvalidContract(params.routerOne);
        if (params.routerTwo.code.length == 0) revert InvalidContract(params.routerTwo);
        if (params.tokenA == address(0) || params.tokenB == address(0)) revert InvalidAddress();
        if (params.tokenA.code.length == 0) revert InvalidContract(params.tokenA);
        if (params.tokenB.code.length == 0) revert InvalidContract(params.tokenB);
        if (
            params.tokenA == params.tokenB || params.routerOne == params.routerTwo || params.routerOne == executor
                || params.routerTwo == executor
        ) {
            revert InvalidCycle();
        }
        if (
            params.amountIn == 0 || params.minimumAmountOutFirst == 0 || params.minimumAmountOutSecond == 0
                || params.minimumReturnedAmount < params.amountIn || minimumNetOutputIncrease == 0
        ) {
            revert InvalidAmount();
        }
    }

    function _validateExecutor(address executor) private view {
        if (!isTargetAllowed[executor]) revert TargetNotAllowed(executor);
        if (executor.code.length == 0) revert InvalidContract(executor);
        address boundSolver = _boundSolver(executor);
        if (boundSolver != address(this)) revert InvalidExecutorBinding(executor, address(this));
    }

    function _boundSolver(address executor) private view returns (address boundSolver) {
        bool success;
        uint256 returnDataLength;
        uint256 selector = uint256(bytes32(ITwoRouterCycleExecutor.solver.selector)) >> 224;
        assembly ("memory-safe") {
            let data := mload(0x40)
            mstore(data, shl(224, selector))
            success := staticcall(gas(), executor, data, 4, data, 32)
            returnDataLength := returndatasize()
            boundSolver := mload(data)
        }
        if (!success || returnDataLength != 32) {
            revert InvalidExecutorBinding(executor, address(this));
        }
    }

    function _callExecutor(
        address executor,
        ITwoRouterCycleExecutor.CycleParams calldata params
    )
        private
        returns (uint256 returnedAmount)
    {
        bytes memory callData = abi.encodeCall(ITwoRouterCycleExecutor.executeCycle, (params));
        bool success;
        uint256 returnDataLength;
        bytes4 reason;
        assembly ("memory-safe") {
            let returnData := mload(0x40)
            success := call(gas(), executor, 0, add(callData, 0x20), mload(callData), 0, 0)
            returnDataLength := returndatasize()
            if iszero(success) {
                if gt(returnDataLength, 3) {
                    returndatacopy(returnData, 0, 4)
                    reason := mload(returnData)
                }
            }
            if and(success, eq(returnDataLength, 0x20)) {
                returndatacopy(returnData, 0, 0x20)
                returnedAmount := mload(returnData)
            }
        }
        if (!success) revert ExecutorCallFailed(executor, reason);
        if (returnDataLength != 32) revert ExecutorCallFailed(executor, bytes4(0));
    }

    function _setExactAllowance(address token, address spender, uint256 amount) private {
        uint256 currentAllowance = _allowance(token, address(this), spender);
        if (currentAllowance != 0) {
            SafeTransferLib.safeApprove(token, spender, 0);
            _requireAllowance(token, spender, 0);
        }
        SafeTransferLib.safeApproveWithRetry(token, spender, amount);
        _requireAllowance(token, spender, amount);
    }

    function _clearAllowance(address token, address spender) private {
        SafeTransferLib.safeApprove(token, spender, 0);
        _requireAllowance(token, spender, 0);
    }

    function _requireAllowance(address token, address spender, uint256 expected) private view {
        uint256 actual = _allowance(token, address(this), spender);
        if (actual != expected) revert UnexpectedAllowance(token, spender, actual, expected);
    }

    function _allowance(address token, address owner_, address spender) private view returns (uint256 amount) {
        bool success;
        uint256 returnDataLength;
        assembly ("memory-safe") {
            let data := mload(0x40)
            mstore(data, shl(224, 0xdd62ed3e))
            mstore(add(data, 4), owner_)
            mstore(add(data, 36), spender)
            success := staticcall(gas(), token, data, 68, data, 32)
            returnDataLength := returndatasize()
            amount := mload(data)
        }
        if (!success || returnDataLength != 32) revert InvalidContract(token);
    }
}
