// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GodBrainMEV - Polygon FastLane Atlas Solver Contract
/// @notice This contract executes MEV arbitrage on Polygon, triggered via FastLane Atlas.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAtlas {
    // Interface to interact with the main Atlas contract if needed
    function bond(uint256 amount) external;
    function unbond(uint256 amount) external;
}

contract GodBrainMEV {
    address public immutable owner;
    address public atlasContract; // The official FastLane Atlas Contract address on Polygon
    address public alETH;         // alETH token address for bonding

    error NotOwner();
    error NotAtlas();
    error ArbitrageFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAtlas() {
        if (msg.sender != atlasContract) revert NotAtlas();
        _;
    }

    constructor(address _atlasContract, address _alETH) {
        owner = msg.sender;
        atlasContract = _atlasContract;
        alETH = _alETH;
    }

    /// @notice Updates the Atlas contract address if FastLane upgrades
    function setAtlasContract(address _atlasContract) external onlyOwner {
        atlasContract = _atlasContract;
    }

    /// @notice FASTLANE ATLAS ENTRY POINT
    /// @dev Atlas calls this function when your EIP-712 SolverOperation wins the auction.
    /// @param data Encoded execution payload (which DEX to call, amounts, tokens) built by your C++ node.
    function atlasSolverCall(bytes calldata data) external payable onlyAtlas returns (bool) {
        // 1. Decode the payload created by poly_node_commander.cpp
        // Expected format: (address targetDEX, bytes memory swapPayload, address tokenToCheck, uint256 expectedMinProfit)
        (address target, bytes memory payload, address tokenOut, uint256 minProfit) = abi.decode(data, (address, bytes, address, uint256));

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // 2. Execute the Arbitrage Swap
        (bool success, ) = target.call(payload);
        if (!success) revert ArbitrageFailed();

        // 3. Verify Profit
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 profit = balanceAfter - balanceBefore;
        
        if (profit < minProfit) revert ArbitrageFailed();

        // 4. Return true so Atlas knows the transaction succeeded
        return true;
    }

    /// @notice Manually approve and bond alETH to Atlas for MEV participation
    function bondAlETH(uint256 amount) external onlyOwner {
        IERC20(alETH).approve(atlasContract, amount);
        IAtlas(atlasContract).bond(amount);
    }

    /// @notice Withdraw profits or tokens back to cold wallet
    function withdrawToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner, balance);
    }

    /// @notice Withdraw native MATIC/POL
    function withdrawNative() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}