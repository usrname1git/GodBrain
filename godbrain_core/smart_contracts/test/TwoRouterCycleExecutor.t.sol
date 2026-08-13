// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { SolverBase } from "@atlas/solver/SolverBase.sol";

import { GodBrainMEV } from "../src/GodBrainMEV.sol";
import { TwoRouterCycleExecutor } from "../src/TwoRouterCycleExecutor.sol";
import { ITwoRouterCycleExecutor } from "../src/interfaces/ITwoRouterCycleExecutor.sol";
import { MockAtlas } from "./mocks/MockAtlas.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFeeOnTransferERC20 } from "./mocks/MockFeeOnTransferERC20.sol";
import { MockResetFailureERC20 } from "./mocks/MockResetFailureERC20.sol";
import { MockRouter02 } from "./mocks/MockRouter02.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MockZeroFirstERC20 } from "./mocks/MockZeroFirstERC20.sol";

contract TwoRouterCycleExecutorTest is Test {
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal executionEnvironment = makeAddr("executionEnvironment");

    MockAtlas internal atlas;
    MockWETH internal weth;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockRouter02 internal routerOne;
    MockRouter02 internal routerTwo;
    GodBrainMEV internal solver;
    TwoRouterCycleExecutor internal executor;

    function setUp() external {
        atlas = new MockAtlas();
        weth = new MockWETH();
        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
        routerOne = new MockRouter02(address(tokenA), address(tokenB), 120 ether);
        routerTwo = new MockRouter02(address(tokenB), address(tokenA), 110 ether);
        solver = new GodBrainMEV(address(weth), address(atlas), owner);
        executor = new TwoRouterCycleExecutor(address(solver));

        _allow(address(executor), true);
        _allow(address(routerOne), true);
        _allow(address(routerTwo), true);

        tokenA.mint(address(solver), 1000 ether);
        tokenB.mint(address(routerOne), 10_000 ether);
        tokenA.mint(address(routerTwo), 10_000 ether);
    }

    function testConstructorAndAccessControl() external {
        assertEq(executor.solver(), address(solver));

        vm.expectRevert(TwoRouterCycleExecutor.OnlySolver.selector);
        executor.executeCycle(_params());

        vm.expectRevert(abi.encodeWithSelector(TwoRouterCycleExecutor.InvalidContract.selector, stranger));
        new TwoRouterCycleExecutor(stranger);
    }

    function testCycleRequiresOfficialAtlasCallerAndOwnerOrigin() external {
        vm.expectRevert(SolverBase.InvalidEntry.selector);
        solver.atlasSolverCall(owner, executionEnvironment, address(0), 0, _executionData(5 ether), bytes(""));

        vm.expectRevert(SolverBase.InvalidCaller.selector);
        atlas.callSolver(solver, stranger, executionEnvironment, address(0), 0, _executionData(5 ether));
    }

    function testCycleRejectsDirectSolverEntry() external {
        vm.expectRevert(GodBrainMEV.OnlySelf.selector);
        solver.executeCycle(address(executor), _params(), 5 ether);
    }

    function testTwoLegCycleReturnsPrincipalAndCountsOnlyGrossProfit() external {
        uint256 balanceBefore = tokenA.balanceOf(address(solver));

        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(10 ether));

        assertEq(tokenA.balanceOf(address(solver)), balanceBefore + 10 ether);
        _assertNoAllowancesOrResidue();
    }

    function testPrincipalIsNotProfit() external {
        routerTwo.setAmountOut(100 ether);
        ITwoRouterCycleExecutor.CycleParams memory params = _params();
        params.minimumAmountOutSecond = 100 ether;
        params.minimumReturnedAmount = 100 ether;

        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InsufficientNetOutputIncrease.selector, 0, 1));
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, 1));
    }

    function testSameTokenAtlasBidReducesNetProfit() external {
        vm.expectRevert(abi.encodeWithSelector(GodBrainMEV.InsufficientNetOutputIncrease.selector, 4 ether, 5 ether));
        atlas.callSolver(solver, owner, executionEnvironment, address(tokenA), 6 ether, _executionData(5 ether));

        atlas.callSolver(solver, owner, executionEnvironment, address(tokenA), 5 ether, _executionData(5 ether));
        assertEq(tokenA.balanceOf(executionEnvironment), 5 ether);
    }

    function testCycleRetainsNativeValueForAtlasReconciliation() external {
        atlas.setShortfall(9, 1 ether);
        vm.deal(address(this), 1 ether);

        atlas.callSolver{ value: 1 ether }(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));

        assertEq(atlas.reconciledGasLiability(), 9);
        assertEq(atlas.reconciledNative(), 1 ether);
    }

    function testCycleCanonicalEncodingVector() external view {
        ITwoRouterCycleExecutor.CycleParams memory params = ITwoRouterCycleExecutor.CycleParams({
            tokenA: 0x1111111111111111111111111111111111111111,
            tokenB: 0x2222222222222222222222222222222222222222,
            routerOne: 0x3333333333333333333333333333333333333333,
            routerTwo: 0x4444444444444444444444444444444444444444,
            amountIn: 100,
            minimumAmountOutFirst: 120,
            minimumAmountOutSecond: 109,
            minimumReturnedAmount: 110,
            deadline: 1_800_000_000
        });
        bytes memory encoded =
            abi.encodeCall(solver.executeCycle, (0x5555555555555555555555555555555555555555, params, 4));

        assertEq(encoded.length, 356);
        // The fixed vector is long enough and its leading four bytes are the ABI selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(encoded), solver.executeCycle.selector);
        assertEq(keccak256(encoded), 0x498aa10974c124c3bf48db1d0ea9eaa5108e2f962e652bc556c926469f255cf3);
    }

    function testCycleRejectsTrailingOrMalformedEncoding() external {
        bytes memory trailing = bytes.concat(_executionData(5 ether), hex"00");
        vm.expectRevert(GodBrainMEV.InvalidSolverOpData.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, trailing);

        bytes memory truncated = _executionData(5 ether);
        assembly ("memory-safe") {
            mstore(truncated, sub(mload(truncated), 1))
        }
        vm.expectRevert(GodBrainMEV.InvalidSolverOpData.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, truncated);
    }

    function testWrongExecutorBindingRejected() external {
        GodBrainMEV otherSolver = new GodBrainMEV(address(weth), address(atlas), owner);
        TwoRouterCycleExecutor wrongExecutor = new TwoRouterCycleExecutor(address(otherSolver));
        _allow(address(wrongExecutor), true);

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(
            solver,
            owner,
            executionEnvironment,
            address(0),
            0,
            abi.encodeCall(solver.executeCycle, (address(wrongExecutor), _params(), 5 ether))
        );
    }

    function testExecutorOrRouterRemovalFailsClosed() external {
        _allow(address(executor), false);
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));

        _allow(address(executor), true);
        _allow(address(routerTwo), false);
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));
    }

    function testWrongPathAndSameRouterRejected() external {
        ITwoRouterCycleExecutor.CycleParams memory params = _params();
        params.tokenB = address(tokenA);
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, 5 ether));

        params = _params();
        params.routerTwo = address(routerOne);
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, 5 ether));
    }

    function testExpiredDeadlineAndMinimumOutputsRevert() external {
        ITwoRouterCycleExecutor.CycleParams memory params = _params();
        params.deadline = block.timestamp - 1;
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, 5 ether));

        params = _params();
        params.minimumAmountOutFirst = 121 ether;
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, 5 ether));

        params = _params();
        params.minimumReturnedAmount = 111 ether;
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, 5 ether));
    }

    function testZeroFirstAndStaleAllowancesAreCleared() external {
        (
            GodBrainMEV zeroFirstSolver,
            TwoRouterCycleExecutor zeroFirstExecutor,
            MockZeroFirstERC20 zeroFirstToken,
            MockERC20 intermediate,
            MockRouter02 first,
            MockRouter02 second
        ) = _zeroFirstSystem();

        vm.prank(address(zeroFirstSolver));
        zeroFirstToken.approve(address(zeroFirstExecutor), 7);
        vm.prank(address(zeroFirstExecutor));
        zeroFirstToken.approve(address(first), 9);

        ITwoRouterCycleExecutor.CycleParams memory params = ITwoRouterCycleExecutor.CycleParams({
            tokenA: address(zeroFirstToken),
            tokenB: address(intermediate),
            routerOne: address(first),
            routerTwo: address(second),
            amountIn: 100 ether,
            minimumAmountOutFirst: 120 ether,
            minimumAmountOutSecond: 109 ether,
            minimumReturnedAmount: 110 ether,
            deadline: block.timestamp + 1 hours
        });
        atlas.callSolver(
            zeroFirstSolver,
            owner,
            executionEnvironment,
            address(0),
            0,
            abi.encodeCall(zeroFirstSolver.executeCycle, (address(zeroFirstExecutor), params, 5 ether))
        );

        assertEq(zeroFirstToken.allowance(address(zeroFirstSolver), address(zeroFirstExecutor)), 0);
        assertEq(zeroFirstToken.allowance(address(zeroFirstExecutor), address(first)), 0);
    }

    function testRouterFailureRollsBackEntireCycle() external {
        uint256 solverBefore = tokenA.balanceOf(address(solver));
        uint256 firstTokenABefore = tokenA.balanceOf(address(routerOne));
        uint256 firstTokenBBefore = tokenB.balanceOf(address(routerOne));
        routerTwo.setBehavior(MockRouter02.Behavior.RevertCall, bytes(""));

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));

        assertEq(tokenA.balanceOf(address(solver)), solverBefore);
        assertEq(tokenA.balanceOf(address(routerOne)), firstTokenABefore);
        assertEq(tokenB.balanceOf(address(routerOne)), firstTokenBBefore);
        _assertNoAllowancesOrResidue();
    }

    function testPartialPullExcessPullMalformedOutputAndRebaseRevert() external {
        _expectBehaviorFailure(routerOne, MockRouter02.Behavior.PartialPull);
        _expectBehaviorFailure(routerOne, MockRouter02.Behavior.ExcessPull);
        _expectBehaviorFailure(routerOne, MockRouter02.Behavior.MalformedOutput);
        _expectBehaviorFailure(routerOne, MockRouter02.Behavior.RebaseInput);
    }

    function testRouterCallbackCannotReenterExecutor() external {
        bytes memory callback = abi.encodeCall(executor.executeCycle, (_params()));
        routerOne.setBehavior(MockRouter02.Behavior.Callback, callback);

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));
        _assertNoAllowancesOrResidue();
    }

    function testFeeOnTransferInputRejectedAndRolledBack() external {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee", "FEE");
        MockERC20 intermediate = new MockERC20("Intermediate", "INT");
        MockRouter02 first = new MockRouter02(address(feeToken), address(intermediate), 120 ether);
        MockRouter02 second = new MockRouter02(address(intermediate), address(feeToken), 110 ether);
        GodBrainMEV feeSolver = new GodBrainMEV(address(weth), address(atlas), owner);
        TwoRouterCycleExecutor feeExecutor = new TwoRouterCycleExecutor(address(feeSolver));
        _allowOn(feeSolver, address(feeExecutor), true);
        _allowOn(feeSolver, address(first), true);
        _allowOn(feeSolver, address(second), true);
        feeToken.mint(address(feeSolver), 1000 ether);
        intermediate.mint(address(first), 1000 ether);
        feeToken.mint(address(second), 1000 ether);
        ITwoRouterCycleExecutor.CycleParams memory params = ITwoRouterCycleExecutor.CycleParams({
            tokenA: address(feeToken),
            tokenB: address(intermediate),
            routerOne: address(first),
            routerTwo: address(second),
            amountIn: 100 ether,
            minimumAmountOutFirst: 120 ether,
            minimumAmountOutSecond: 109 ether,
            minimumReturnedAmount: 110 ether,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(
            feeSolver,
            owner,
            executionEnvironment,
            address(0),
            0,
            abi.encodeCall(feeSolver.executeCycle, (address(feeExecutor), params, 5 ether))
        );
        assertEq(feeToken.balanceOf(address(feeSolver)), 1000 ether);
        assertEq(feeToken.allowance(address(feeSolver), address(feeExecutor)), 0);
    }

    function testAllowanceResetFailureRevertsAndRollsBack() external {
        MockResetFailureERC20 resetToken = new MockResetFailureERC20("Reset", "RST");
        MockERC20 intermediate = new MockERC20("Intermediate", "INT");
        MockRouter02 first = new MockRouter02(address(resetToken), address(intermediate), 120 ether);
        MockRouter02 second = new MockRouter02(address(intermediate), address(resetToken), 110 ether);
        GodBrainMEV resetSolver = new GodBrainMEV(address(weth), address(atlas), owner);
        TwoRouterCycleExecutor resetExecutor = new TwoRouterCycleExecutor(address(resetSolver));
        _allowOn(resetSolver, address(resetExecutor), true);
        _allowOn(resetSolver, address(first), true);
        _allowOn(resetSolver, address(second), true);
        resetToken.mint(address(resetSolver), 1000 ether);
        intermediate.mint(address(first), 1000 ether);
        resetToken.mint(address(second), 1000 ether);
        resetToken.setFailZeroApproval(true);
        ITwoRouterCycleExecutor.CycleParams memory params = ITwoRouterCycleExecutor.CycleParams({
            tokenA: address(resetToken),
            tokenB: address(intermediate),
            routerOne: address(first),
            routerTwo: address(second),
            amountIn: 100 ether,
            minimumAmountOutFirst: 120 ether,
            minimumAmountOutSecond: 109 ether,
            minimumReturnedAmount: 110 ether,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(
            resetSolver,
            owner,
            executionEnvironment,
            address(0),
            0,
            abi.encodeCall(resetSolver.executeCycle, (address(resetExecutor), params, 5 ether))
        );
        assertEq(resetToken.balanceOf(address(resetSolver)), 1000 ether);
        assertEq(resetToken.allowance(address(resetSolver), address(resetExecutor)), 0);
        assertEq(resetToken.balanceOf(address(resetExecutor)), 0);
    }

    function testAccidentalDustBlocksExecutionAndOwnerCanRecoverIt() external {
        tokenA.mint(address(executor), 1 ether);
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));

        uint256 before = tokenA.balanceOf(address(solver));
        vm.prank(owner);
        solver.recoverExecutorToken(address(executor), address(tokenA));
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenA.balanceOf(address(solver)), before + 1 ether);
    }

    function testFuzzCycleAmountsAndMinima(
        uint128 amountInRaw,
        uint128 grossProfitRaw,
        uint128 minimumNetRaw
    )
        external
    {
        uint256 amountIn = bound(uint256(amountInRaw), 1, 1_000_000 ether);
        uint256 grossProfit = bound(uint256(grossProfitRaw), 1, 1_000_000 ether);
        uint256 minimumNet = bound(uint256(minimumNetRaw), 1, grossProfit);
        uint256 intermediate = amountIn + 1;
        uint256 returned = amountIn + grossProfit;

        routerOne.setAmountOut(intermediate);
        routerTwo.setAmountOut(returned);
        tokenA.mint(address(solver), amountIn);
        tokenB.mint(address(routerOne), intermediate);
        tokenA.mint(address(routerTwo), returned);
        ITwoRouterCycleExecutor.CycleParams memory params = _params();
        params.amountIn = amountIn;
        params.minimumAmountOutFirst = intermediate;
        params.minimumAmountOutSecond = returned;
        params.minimumReturnedAmount = returned;
        uint256 before = tokenA.balanceOf(address(solver));

        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(params, minimumNet));

        assertEq(tokenA.balanceOf(address(solver)), before + grossProfit);
        _assertNoAllowancesOrResidue();
    }

    function _expectBehaviorFailure(MockRouter02 router, MockRouter02.Behavior behavior) internal {
        router.setBehavior(behavior, bytes(""));
        uint256 solverBefore = tokenA.balanceOf(address(solver));
        vm.expectRevert(SolverBase.SolverCallUnsuccessful.selector);
        atlas.callSolver(solver, owner, executionEnvironment, address(0), 0, _executionData(5 ether));
        assertEq(tokenA.balanceOf(address(solver)), solverBefore);
        _assertNoAllowancesOrResidue();
        router.setBehavior(MockRouter02.Behavior.Success, bytes(""));
    }

    function _zeroFirstSystem()
        internal
        returns (
            GodBrainMEV zeroFirstSolver,
            TwoRouterCycleExecutor zeroFirstExecutor,
            MockZeroFirstERC20 zeroFirstToken,
            MockERC20 intermediate,
            MockRouter02 first,
            MockRouter02 second
        )
    {
        zeroFirstToken = new MockZeroFirstERC20("Zero First", "ZERO");
        intermediate = new MockERC20("Intermediate", "INT");
        first = new MockRouter02(address(zeroFirstToken), address(intermediate), 120 ether);
        second = new MockRouter02(address(intermediate), address(zeroFirstToken), 110 ether);
        zeroFirstSolver = new GodBrainMEV(address(weth), address(atlas), owner);
        zeroFirstExecutor = new TwoRouterCycleExecutor(address(zeroFirstSolver));
        _allowOn(zeroFirstSolver, address(zeroFirstExecutor), true);
        _allowOn(zeroFirstSolver, address(first), true);
        _allowOn(zeroFirstSolver, address(second), true);
        zeroFirstToken.mint(address(zeroFirstSolver), 1000 ether);
        intermediate.mint(address(first), 1000 ether);
        zeroFirstToken.mint(address(second), 1000 ether);
    }

    function _assertNoAllowancesOrResidue() internal view {
        assertEq(tokenA.allowance(address(solver), address(executor)), 0);
        assertEq(tokenA.allowance(address(executor), address(routerOne)), 0);
        assertEq(tokenB.allowance(address(executor), address(routerTwo)), 0);
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    function _allow(address target, bool allowed) internal {
        _allowOn(solver, target, allowed);
    }

    function _allowOn(GodBrainMEV targetSolver, address target, bool allowed) internal {
        vm.prank(owner);
        targetSolver.setTargetAllowed(target, allowed);
    }

    function _executionData(uint256 minimumNetOutputIncrease) internal view returns (bytes memory) {
        return _executionData(_params(), minimumNetOutputIncrease);
    }

    function _executionData(
        ITwoRouterCycleExecutor.CycleParams memory params,
        uint256 minimumNetOutputIncrease
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(solver.executeCycle, (address(executor), params, minimumNetOutputIncrease));
    }

    function _params() internal view returns (ITwoRouterCycleExecutor.CycleParams memory params) {
        params = ITwoRouterCycleExecutor.CycleParams({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            routerOne: address(routerOne),
            routerTwo: address(routerTwo),
            amountIn: 100 ether,
            minimumAmountOutFirst: 120 ether,
            minimumAmountOutSecond: 109 ether,
            minimumReturnedAmount: 110 ether,
            deadline: block.timestamp + 1 hours
        });
    }
}
