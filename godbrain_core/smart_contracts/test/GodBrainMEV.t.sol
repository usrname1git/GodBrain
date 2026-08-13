// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { SolverBase } from "@atlas/solver/SolverBase.sol";

import { GodBrainMEV } from "../src/GodBrainMEV.sol";
import { MockAtlas } from "./mocks/MockAtlas.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockTarget } from "./mocks/MockTarget.sol";
import { MockWETH } from "./mocks/MockWETH.sol";

contract GodBrainMEVTest is Test {
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal executionEnvironment = makeAddr("executionEnvironment");

    MockAtlas internal atlas;
    MockWETH internal weth;
    MockERC20 internal outputToken;
    MockERC20 internal bidToken;
    MockTarget internal target;
    GodBrainMEV internal solver;

    function setUp() external {
        atlas = new MockAtlas();
        weth = new MockWETH();
        outputToken = new MockERC20("Output", "OUT");
        bidToken = new MockERC20("Bid", "BID");
        target = new MockTarget();
        solver = new GodBrainMEV(address(weth), address(atlas), owner);

        vm.prank(owner);
        solver.setTargetAllowed(address(target), true);
        outputToken.mint(address(target), 1000 ether);
    }

    function testConstructorStoresImmutableConfiguration() external view {
        assertEq(solver.owner(), owner);
        assertEq(solver.atlas(), address(atlas));
        assertEq(solver.WETH_ADDRESS(), address(weth));
    }

    function testConstructorRejectsZeroAddress() external {
        vm.expectRevert(GodBrainMEV.InvalidAddress.selector);
        new GodBrainMEV(address(0), address(atlas), owner);
    }

    function testConstructorRejectsNonContractAtlas() external {
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InvalidContract.selector, stranger));
        new GodBrainMEV(address(weth), stranger, owner);
    }

    function testAtlasSolverCallRejectsNonAtlasCaller() external {
        vm.expectRevert(SolverBase.InvalidEntry.selector);
        solver.atlasSolverCall(owner, executionEnvironment, address(0), 0, _executionData(1 ether), bytes(""));
    }

    function testAtlasSolverCallRejectsNonOwnerSolverOpFrom() external {
        vm.expectRevert(SolverBase.InvalidCaller.selector);
        atlas.callSolver(solver, stranger, executionEnvironment, address(0), 0, _executionData(1 ether));
    }

    function testAtlasSolverCallRejectsWrongSolverOpSelector() external {
        bytes memory solverOpData = abi.encodeCall(solver.withdrawNative, (owner, 1));

        vm.expectRevert(GodBrainMEV.InvalidSolverOpData.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, solverOpData);
    }

    function testAtlasSolverCallRejectsMalformedSolverOpData() external {
        bytes memory solverOpData = abi.encodePacked(GodBrainMEV.execute.selector, bytes32(0));

        vm.expectRevert();
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, solverOpData);
    }

    function testAtlasSolverCallRejectsTrailingSolverOpData() external {
        bytes memory solverOpData = bytes.concat(_executionData(1 ether), hex"00");

        vm.expectRevert(GodBrainMEV.InvalidSolverOpData.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, solverOpData);
    }

    function testExecuteRejectsDirectCaller() external {
        vm.expectRevert(GodBrainMEV.OnlySelf.selector);
        solver.execute(address(target), _deliverData(1 ether), address(outputToken), 1 ether);
    }

    function testExecuteRejectsUnallowedTarget() external {
        MockTarget unallowed = new MockTarget();
        bytes memory solverOpData = abi.encodeCall(
            solver.execute, (address(unallowed), abi.encodeCall(unallowed.fail, ()), address(outputToken), 1 ether)
        );

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, solverOpData);
    }

    function testOwnerCanDisableTarget() external {
        vm.prank(owner);
        solver.setTargetAllowed(address(target), false);

        assertFalse(solver.isTargetAllowed(address(target)));
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(1 ether));
    }

    function testNonOwnerCannotManageTargets() external {
        vm.expectRevert(GodBrainMEV.NotOwner.selector);
        solver.setTargetAllowed(address(target), false);
    }

    function testCannotAllowEOATarget() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InvalidContract.selector, stranger));
        solver.setTargetAllowed(stranger, true);
    }

    function testCannotAllowSolverOrAtlasAsTarget() external {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InvalidContract.selector, address(solver)));
        solver.setTargetAllowed(address(solver), true);
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InvalidContract.selector, address(atlas)));
        solver.setTargetAllowed(address(atlas), true);
        vm.stopPrank();
    }

    function testCannotAllowContractOwnerAsTarget() external {
        GodBrainMEV contractOwnedSolver = new GodBrainMEV(address(weth), address(atlas), address(this));

        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InvalidContract.selector, address(this)));
        contractOwnedSolver.setTargetAllowed(address(this), true);
    }

    function testExecuteRejectsEmptyCallData() external {
        vm.prank(address(solver));
        vm.expectRevert(GodBrainMEV.EmptyCallData.selector);
        solver.execute(address(target), bytes(""), address(outputToken), 1);
    }

    function testExecuteRejectsInvalidOutputToken() external {
        vm.prank(address(solver));
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InvalidContract.selector, stranger));
        solver.execute(address(target), _deliverData(1), stranger, 1);
    }

    function testExecuteRejectsZeroMinimumOutputIncrease() external {
        vm.prank(address(solver));
        vm.expectRevert(GodBrainMEV.InvalidAmount.selector);
        solver.execute(address(target), _deliverData(1), address(outputToken), 0);
    }

    function testTargetFailureRevertsAtlasExecution() external {
        bytes memory solverOpData =
            abi.encodeCall(solver.execute, (address(target), abi.encodeCall(target.fail, ()), address(outputToken), 1));

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, solverOpData);
    }

    function testOutputIncreaseMustMeetMinimum() external {
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InsufficientNetOutputIncrease.selector, 1 ether, 2 ether));
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(2 ether));
    }

    function testSuccessfulExecutionEnforcesOutputIncrease() external {
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(1 ether));

        assertEq(outputToken.balanceOf(address(solver)), 1 ether);
    }

    function testNativeBidPaidToExecutionEnvironment() external {
        vm.deal(address(solver), 3 ether);

        atlas.callSolver(solver, owner, executionEnvironment, address(0), 2 ether, _executionData(1 ether));

        assertEq(executionEnvironment.balance, 2 ether);
        assertEq(address(solver).balance, 1 ether);
    }

    function testTokenBidPaidToExecutionEnvironment() external {
        bidToken.mint(address(solver), 4 ether);

        atlas.callSolver(solver, owner, executionEnvironment, address(bidToken), 3 ether, _executionData(1 ether));

        assertEq(bidToken.balanceOf(executionEnvironment), 3 ether);
        assertEq(bidToken.balanceOf(address(solver)), 1 ether);
    }

    function testSameOutputTokenBidRevertsWhenNetOutputIsBelowMinimum() external {
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InsufficientNetOutputIncrease.selector, 1 ether, 2 ether));
        atlas.callSolver(
            solver,
            owner,
            executionEnvironment,
            address(outputToken),
            2 ether,
            _executionDataFor(outputToken, 3 ether, 2 ether)
        );
    }

    function testSameOutputTokenBidPassesAtExactNetMinimum() external {
        atlas.callSolver(
            solver,
            owner,
            executionEnvironment,
            address(outputToken),
            2 ether,
            _executionDataFor(outputToken, 3 ether, 1 ether)
        );

        assertEq(outputToken.balanceOf(address(solver)), 1 ether);
        assertEq(outputToken.balanceOf(executionEnvironment), 2 ether);
    }

    function testWrappedNativeOutputAccountsForNativeBidUnwrap() external {
        vm.deal(address(weth), 2 ether);
        weth.mint(address(target), 3 ether);

        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InsufficientNetOutputIncrease.selector, 1 ether, 2 ether));
        atlas.callSolver(
            solver, owner, executionEnvironment, address(0), 2 ether, _executionDataFor(weth, 3 ether, 2 ether)
        );

        atlas.callSolver(
            solver, owner, executionEnvironment, address(0), 2 ether, _executionDataFor(weth, 3 ether, 1 ether)
        );
        assertEq(weth.balanceOf(address(solver)), 1 ether);
        assertEq(executionEnvironment.balance, 2 ether);
    }

    function testNativeValueIsRetainedForReconciliation() external {
        atlas.setShortfall(7, 1 ether);
        vm.deal(address(this), 1 ether);

        atlas.callSolver{ value: 1 ether }(solver, owner, executionEnvironment, address(0), 0, _executionData(1 ether));

        assertEq(atlas.reconciledGasLiability(), 7);
        assertEq(atlas.reconciledNative(), 1 ether);
        assertEq(address(target).balance, 0);
    }

    function testOwnerCanWithdrawToken() external {
        outputToken.mint(address(solver), 3 ether);

        vm.prank(owner);
        solver.withdrawToken(address(outputToken), owner, 2 ether);

        assertEq(outputToken.balanceOf(owner), 2 ether);
        assertEq(outputToken.balanceOf(address(solver)), 1 ether);
    }

    function testNonOwnerCannotWithdrawToken() external {
        vm.expectRevert(GodBrainMEV.NotOwner.selector);
        solver.withdrawToken(address(outputToken), stranger, 1);
    }

    function testOwnerCanWithdrawNative() external {
        vm.deal(address(solver), 2 ether);

        vm.prank(owner);
        solver.withdrawNative(owner, 2 ether);

        assertEq(owner.balance, 2 ether);
        assertEq(address(solver).balance, 0);
    }

    function testWithdrawRejectsZeroRecipient() external {
        vm.prank(owner);
        vm.expectRevert(GodBrainMEV.InvalidAddress.selector);
        solver.withdrawNative(address(0), 1);
    }

    function _executionData(uint256 minimumNetOutputIncrease) internal view returns (bytes memory) {
        return _executionDataFor(outputToken, 1 ether, minimumNetOutputIncrease);
    }

    function _executionDataFor(
        MockERC20 token,
        uint256 grossOutput,
        uint256 minimumNetOutputIncrease
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            solver.execute,
            (
                address(target),
                abi.encodeCall(target.deliver, (token, address(solver), grossOutput)),
                address(token),
                minimumNetOutputIncrease
            )
        );
    }

    function _deliverData(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(target.deliver, (outputToken, address(solver), amount));
    }
}
