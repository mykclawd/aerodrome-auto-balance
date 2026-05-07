// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal SlipStream SwapRouter interface (Uniswap v3 SwapRouter02 with `tickSpacing` instead of `fee`).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
