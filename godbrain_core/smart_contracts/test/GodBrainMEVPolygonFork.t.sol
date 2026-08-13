// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { GodBrainMEV } from "../src/GodBrainMEV.sol";

contract GodBrainMEVPolygonForkTest is Test {
    address internal constant POLYGON_ATLAS = 0x4A394bD4Bc2f4309ac0b75c052b242ba3e0f32e0;
    address internal constant POLYGON_WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    function testPolygonAtlasDeploymentWhenRpcConfigured() external {
        string memory rpcUrl = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl);
        assertGt(POLYGON_ATLAS.code.length, 0, "Atlas deployment has no code");
        assertGt(POLYGON_WETH.code.length, 0, "Polygon WETH deployment has no code");

        GodBrainMEV solver = new GodBrainMEV(POLYGON_WETH, POLYGON_ATLAS, address(this));
        assertEq(solver.atlas(), POLYGON_ATLAS);
        assertEq(solver.WETH_ADDRESS(), POLYGON_WETH);
    }
}
