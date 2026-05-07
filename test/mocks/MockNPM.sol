// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MockNPM {
    struct Pos {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token0;
        address token1;
        int24 tickSpacing;
    }

    mapping(uint256 => Pos) public posOf;

    function setPosition(uint256 tokenId, int24 lower, int24 upper, uint128 liquidity) external {
        posOf[tokenId].tickLower = lower;
        posOf[tokenId].tickUpper = upper;
        posOf[tokenId].liquidity = liquidity;
    }

    function setPositionConfig(
        uint256 tokenId,
        address token0,
        address token1,
        int24 spacing,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external {
        posOf[tokenId] = Pos({
            tickLower: lower,
            tickUpper: upper,
            liquidity: liquidity,
            token0: token0,
            token1: token1,
            tickSpacing: spacing
        });
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address t0,
            address t1,
            int24 spacing,
            int24 lower,
            int24 upper,
            uint128 liq,
            uint256 fg0,
            uint256 fg1,
            uint128 owed0,
            uint128 owed1
        )
    {
        Pos memory p = posOf[tokenId];
        return (0, address(0), p.token0, p.token1, p.tickSpacing, p.tickLower, p.tickUpper, p.liquidity, 0, 0, 0, 0);
    }
}
