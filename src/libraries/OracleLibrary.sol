// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ICLPool} from "../interfaces/ICLPool.sol";

/// @title Oracle library
/// @notice Computes the arithmetic-mean tick over a window using a CL pool's `observe` function.
/// @dev Vendored subset of Uniswap v3-periphery OracleLibrary; adapted for solc 0.8.28.
library OracleLibrary {
    /// @notice Returns arithmetic-mean tick over the given window (`secondsAgo`).
    /// @dev Reverts on `secondsAgo == 0` because the pool will revert on a zero-window observe.
    function consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
        require(secondsAgo != 0);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = ICLPool(pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
        // Round towards negative infinity to match Uniswap library behavior.
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) {
            arithmeticMeanTick--;
        }
    }
}
