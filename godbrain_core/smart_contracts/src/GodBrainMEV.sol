// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title GodBrainMEV
/// @notice Minimal Atlas solver skeleton for allowlisted ERC-20 output-producing calls.
/// @dev SolverBase enforces Atlas entry, owner-originated solver operations, bid payment, and reconciliation.
contract GodBrainMEV is SolverBase {
    mapping(address target => bool allowed) public isTargetAllowed;

    error NotOwner();
    error OnlySelf();
    error InvalidAddress();
    error InvalidContract(address account);
    error InvalidAmount();
    error EmptyCallData();
    error TargetNotAllowed(address target);
    error TargetCallFailed(bytes returnData);
    error InsufficientOutputIncrease(uint256 actual, uint256 minimum);

    event TargetPermissionUpdated(address indexed target, bool allowed);
    event SolverExecution(
        address indexed target, address indexed outputToken, uint256 outputIncrease, uint256 minimumOutputIncrease
    );
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

    constructor(address weth, address atlas_, address owner_) SolverBase(weth, atlas_, owner_) {
        if (weth == address(0) || atlas_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        if (weth.code.length == 0) revert InvalidContract(weth);
        if (atlas_.code.length == 0) revert InvalidContract(atlas_);
    }

    receive() external payable { }

    function owner() external view returns (address) {
        return _owner;
    }

    function atlas() external view returns (address) {
        return _atlas;
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

    /// @notice Executes one allowlisted call and requires an ERC-20 balance increase.
    /// @dev Must be encoded as solverOpData and reached through SolverBase.atlasSolverCall.
    /// Native value is retained by this contract for SolverBase reconciliation and is never forwarded to the target.
    function execute(
        address target,
        bytes calldata callData,
        address outputToken,
        uint256 minimumOutputIncrease
    )
        external
        payable
        onlySelf
    {
        if (!isTargetAllowed[target]) revert TargetNotAllowed(target);
        if (callData.length == 0) revert EmptyCallData();
        if (outputToken == address(0)) revert InvalidAddress();
        if (outputToken.code.length == 0) revert InvalidContract(outputToken);
        if (minimumOutputIncrease == 0) revert InvalidAmount();

        uint256 balanceBefore = SafeTransferLib.balanceOf(outputToken, address(this));
        (bool success, bytes memory returnData) = target.call(callData);
        if (!success) revert TargetCallFailed(returnData);

        uint256 balanceAfter = SafeTransferLib.balanceOf(outputToken, address(this));
        uint256 outputIncrease = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (outputIncrease < minimumOutputIncrease) {
            revert InsufficientOutputIncrease(outputIncrease, minimumOutputIncrease);
        }

        emit SolverExecution(target, outputToken, outputIncrease, minimumOutputIncrease);
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
}
