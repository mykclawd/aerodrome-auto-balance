// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISafe} from "../../src/interfaces/ISafe.sol";

/// @notice Bare-bones Safe stand-in for fork tests. Records enabled modules and
///         forwards module calls. Holds NFTs and tokens like a real Safe.
contract MinimalSafe {
    mapping(address => bool) public enabledModules;

    receive() external payable {}

    function enableModule(address m) external {
        enabledModules[m] = true;
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return enabledModules[module];
    }

    /// @notice Mirrors Safe's `execTransactionFromModuleReturnData` for `Operation.Call` only.
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, ISafe.Operation op)
        external
        returns (bool success, bytes memory returnData)
    {
        require(enabledModules[msg.sender], "module not enabled");
        require(op == ISafe.Operation.Call, "delegatecall not supported");
        (success, returnData) = to.call{value: value}(data);
    }

    /// @notice Convenience helper for tests: lets the test harness do arbitrary calls
    ///         appearing to come from the Safe (e.g. mint a position before rebalancing).
    function execAsSafe(address to, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        require(ok, "exec failed");
    }

    /// @notice ERC721 receiver hook so the Safe can hold position NFTs.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}
