// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Universal Router interface used for exact-in CL swaps.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
