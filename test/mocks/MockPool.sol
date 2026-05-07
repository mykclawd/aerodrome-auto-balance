// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MockPool {
    address public factory;
    address public token0;
    address public token1;
    int24 public tickSpacing;
    address public gauge;

    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public observationCardinality;

    int56 public tickCumulativeAtWindowStart;
    int56 public tickCumulativeNow;

    constructor(address _token0, address _token1, int24 _tickSpacing, address _gauge) {
        factory = address(this);
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        gauge = _gauge;
        observationCardinality = 100;
    }

    function setSlot0(uint160 _sqrt, int24 _tick) external {
        sqrtPriceX96 = _sqrt;
        tick = _tick;
    }

    function setTickCumulatives(int56 atStart, int56 atNow) external {
        tickCumulativeAtWindowStart = atStart;
        tickCumulativeNow = atNow;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, tick, 0, observationCardinality, observationCardinality, true);
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory slpcX128)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulativeAtWindowStart;
        tickCumulatives[1] = tickCumulativeNow;
        slpcX128 = new uint160[](2);
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        observationCardinality = next;
    }
}
