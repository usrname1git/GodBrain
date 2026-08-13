// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { GodBrainMEV } from "../src/GodBrainMEV.sol";

contract GodBrainMEVPolygonForkTest is Test {
    address internal constant POLYGON_ATLAS = 0x4A394bD4Bc2f4309ac0b75c052b242ba3e0f32e0;
    address internal constant POLYGON_WRAPPED_NATIVE = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    function testPolygonAtlasDeploymentWhenRpcConfigured() external {
        string memory rpcUrl = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl);
        assertGt(POLYGON_ATLAS.code.length, 0, "Atlas deployment has no code");
        assertGt(POLYGON_WRAPPED_NATIVE.code.length, 0, "Polygon wrapped-native deployment has no code");

        GodBrainMEV solver = new GodBrainMEV(POLYGON_WRAPPED_NATIVE, POLYGON_ATLAS, address(this));
        assertEq(solver.atlas(), POLYGON_ATLAS);
        assertEq(solver.WETH_ADDRESS(), POLYGON_WRAPPED_NATIVE);
    }
}
