// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISolverContract } from "@atlas/interfaces/ISolverContract.sol";

contract MockAtlas {
    uint256 public gasLiability;
    uint256 public borrowLiability;
    uint256 public reconciledGasLiability;
    uint256 public reconciledNative;

    function setShortfall(uint256 gasLiability_, uint256 borrowLiability_) external {
        gasLiability = gasLiability_;
        borrowLiability = borrowLiability_;
    }

    function shortfall() external view returns (uint256, uint256) {
        return (gasLiability, borrowLiability);
    }

    function reconcile(uint256 maxApprovedGasSpend) external payable returns (uint256 owed) {
        reconciledGasLiability = maxApprovedGasSpend;
        reconciledNative = msg.value;
        return msg.value;
    }

    function callSolver(
        ISolverContract solver,
        address solverOpFrom,
        address executionEnvironment,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData
    )
        external
        payable
    {
        solver.atlasSolverCall{ value: msg.value }(
            solverOpFrom, executionEnvironment, bidToken, bidAmount, solverOpData, bytes("")
        );
    }
}
