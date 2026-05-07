// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AerodromeRebalancer} from "../src/AerodromeRebalancer.sol";
import {MinimalSafe} from "./mocks/MinimalSafe.sol";

import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {ICLGauge} from "../src/interfaces/ICLGauge.sol";
import {INonfungiblePositionManager as INPM} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @notice End-to-end fork test against Base mainnet. Skips gracefully if BASE_RPC_URL is unset.
contract AerodromeRebalancerForkTest is Test {
    // Base mainnet
    address internal constant POOL = 0x42d4a22CaD0F5a49681a5715cE994Af73A43B76b;
    address internal constant GAUGE = 0x61E0B10423a0009C3f83ab4313813d29437d0817;
    address internal constant NPM = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
    address internal constant SWAP_ROUTER = 0xcAF22ce31298CF2BF1D152862F80216478ad7c67;
    // Per the on-chain pool layout: token0 = WETH, token1 = cbBTC (this is *opposite* to the
    // token-ordering used colloquially when referring to the pair "cbBTC/WETH").
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    int24 internal constant TICK_SPACING = 10;

    MinimalSafe internal safe;
    AerodromeRebalancer internal mod;
    address internal keeper = address(0xBEEF1);

    bool internal forkAvailable;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forkAvailable = false;
            return;
        }
        try vm.createSelectFork(rpc) returns (uint256) {
            forkAvailable = true;
        } catch {
            forkAvailable = false;
            return;
        }

        safe = new MinimalSafe();
        address[] memory initialKeepers = new address[](1);
        initialKeepers[0] = keeper;

        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: address(safe),
            pool: POOL,
            gauge: GAUGE,
            npm: NPM,
            swapRouter: SWAP_ROUTER,
            initialKeepers: initialKeepers,
            twapWindow: 60, // shorter window so a fresh fork has enough observations
            maxTickDeviation: 200, // permissive for test conditions
            maxSlippageBps: 200, // 2%
            maxRebalanceLossBps: 300 // 3%
        });
        mod = new AerodromeRebalancer(p);

        safe.enableModule(address(mod));
    }

    /// @dev mint an out-of-range position into the Safe and stake it in the gauge.
    /// @param lowerOffset / upperOffset relative to alignedCurrent in ticks (multiples of TICK_SPACING)
    /// @param fundWeth raw token0 (WETH, 18 decimals)
    /// @param fundCbBTC raw token1 (cbBTC, 8 decimals)
    function _setupOutOfRangePosition(int24 lowerOffset, int24 upperOffset, uint256 fundWeth, uint256 fundCbBTC)
        internal
        returns (uint256 tokenId, int24 lower, int24 upper)
    {
        // adjustTotalSupply=false: WETH on Base is the OP-style predeploy and `deal`'s
        // totalSupply slot detection fails on it. We don't care about totalSupply for the test.
        deal(WETH, address(safe), fundWeth, false);
        deal(CBBTC, address(safe), fundCbBTC, false);

        (, int24 currentTick,,,,) = ICLPool(POOL).slot0();
        int24 alignedCurrent = (currentTick / TICK_SPACING) * TICK_SPACING;
        if (currentTick < 0 && currentTick % TICK_SPACING != 0) alignedCurrent -= TICK_SPACING;
        lower = alignedCurrent + lowerOffset;
        upper = alignedCurrent + upperOffset;
        require(lower < upper, "bad ticks");
        require(lower % TICK_SPACING == 0 && upper % TICK_SPACING == 0, "tick alignment");

        safe.execAsSafe(WETH, abi.encodeCall(IERC20Minimal.approve, (NPM, fundWeth)));
        safe.execAsSafe(CBBTC, abi.encodeCall(IERC20Minimal.approve, (NPM, fundCbBTC)));

        bytes memory ret = safe.execAsSafe(
            NPM,
            abi.encodeCall(
                INPM.mint,
                (
                    INPM.MintParams({
                        token0: WETH,
                        token1: CBBTC,
                        tickSpacing: TICK_SPACING,
                        tickLower: lower,
                        tickUpper: upper,
                        amount0Desired: fundWeth,
                        amount1Desired: fundCbBTC,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(safe),
                        deadline: block.timestamp,
                        sqrtPriceX96: 0
                    })
                )
            )
        );
        (tokenId,,,) = abi.decode(ret, (uint256, uint128, uint256, uint256));

        safe.execAsSafe(WETH, abi.encodeCall(IERC20Minimal.approve, (NPM, 0)));
        safe.execAsSafe(CBBTC, abi.encodeCall(IERC20Minimal.approve, (NPM, 0)));

        safe.execAsSafe(NPM, abi.encodeCall(INPM.approve, (GAUGE, tokenId)));
        safe.execAsSafe(GAUGE, abi.encodeCall(ICLGauge.deposit, (tokenId)));

        vm.prank(address(safe));
        mod.setCurrentTokenId(tokenId);
    }

    function test_fork_rebalance_swapsCbBTCToWeth_priceAboveOldRange() public {
        if (!forkAvailable) return;

        // Old range BELOW current price → out of range above. After rebalance,
        // recentered range should contain currentTick.
        (, int24 originalTick,,,,) = ICLPool(POOL).slot0();
        // Old range BELOW currentTick → position drained to token1 (cbBTC) at mint time.
        (uint256 oldId, int24 oldLower, int24 oldUpper) = _setupOutOfRangePosition({
            lowerOffset: -3000,
            upperOffset: -1000,
            fundWeth: 0,
            fundCbBTC: 2e6 // 0.02 cbBTC (8 decimals)
        });
        // sanity: position should be out of range
        assertTrue(originalTick >= oldUpper || originalTick < oldLower, "expected out of range");

        assertTrue(ICLGauge(GAUGE).stakedContains(address(safe), oldId), "should be staked pre");

        // Anyone calls rebalance
        vm.prank(keeper);
        AerodromeRebalancer.RebalanceCtx memory ctx = mod.rebalance(block.timestamp + 5 minutes);

        // Post-state assertions
        assertGt(ctx.swapIn, 0, "cbBTC swap input");
        assertGt(ctx.swapOut, 0, "WETH swap output");
        assertGt(ctx.amount0ToUse, 0, "WETH available for centered mint");
        assertGt(ctx.newTokenId, 0, "new tokenId minted");
        assertEq(ctx.newTokenId, mod.currentTokenId(), "module tracks new tokenId");
        assertTrue(ICLGauge(GAUGE).stakedContains(address(safe), ctx.newTokenId), "new is staked");
        assertFalse(ICLGauge(GAUGE).stakedContains(address(safe), oldId), "old is unstaked");

        // new range strictly contains the currentTick at execution time
        (, int24 currentTick,,,,) = ICLPool(POOL).slot0();
        (,,,,, int24 newLower, int24 newUpper, uint128 newLiq,,,,) = INPM(NPM).positions(ctx.newTokenId);
        assertTrue(currentTick >= newLower && currentTick < newUpper, "new range contains currentTick");
        assertGt(uint256(newLiq), 0, "new liquidity positive");

        // width preserved
        assertEq(int256(newUpper - newLower), int256(oldUpper - oldLower), "width preserved");

        // approvals fully cleared
        assertEq(IERC20Minimal(CBBTC).allowance(address(safe), NPM), 0);
        assertEq(IERC20Minimal(WETH).allowance(address(safe), NPM), 0);
        assertEq(IERC20Minimal(CBBTC).allowance(address(safe), SWAP_ROUTER), 0);
        assertEq(IERC20Minimal(WETH).allowance(address(safe), SWAP_ROUTER), 0);
    }

    function test_fork_rebalance_swapsWethToCbBTC_priceBelowOldRange() public {
        if (!forkAvailable) return;

        (, int24 originalTick,,,,) = ICLPool(POOL).slot0();
        // Old range ABOVE currentTick -> position is token0-only (WETH) at mint time.
        (uint256 oldId, int24 oldLower, int24 oldUpper) = _setupOutOfRangePosition({
            lowerOffset: 1000,
            upperOffset: 3000,
            fundWeth: 5e17, // 0.5 WETH
            fundCbBTC: 0
        });
        assertTrue(originalTick >= oldUpper || originalTick < oldLower, "expected out of range");
        assertTrue(ICLGauge(GAUGE).stakedContains(address(safe), oldId), "should be staked pre");

        vm.prank(keeper);
        AerodromeRebalancer.RebalanceCtx memory ctx = mod.rebalance(block.timestamp + 5 minutes);

        assertGt(ctx.swapIn, 0, "WETH swap input");
        assertGt(ctx.swapOut, 0, "cbBTC swap output");
        assertGt(ctx.amount1ToUse, 0, "cbBTC available for centered mint");
        assertGt(ctx.newTokenId, 0, "new tokenId minted");
        assertEq(ctx.newTokenId, mod.currentTokenId(), "module tracks new tokenId");
        assertTrue(ICLGauge(GAUGE).stakedContains(address(safe), ctx.newTokenId), "new is staked");
        assertFalse(ICLGauge(GAUGE).stakedContains(address(safe), oldId), "old is unstaked");

        (, int24 currentTick,,,,) = ICLPool(POOL).slot0();
        (,,,,, int24 newLower, int24 newUpper, uint128 newLiq,,,,) = INPM(NPM).positions(ctx.newTokenId);
        assertTrue(currentTick >= newLower && currentTick < newUpper, "new range contains currentTick");
        assertGt(uint256(newLiq), 0, "new liquidity positive");
        assertEq(int256(newUpper - newLower), int256(oldUpper - oldLower), "width preserved");

        assertEq(IERC20Minimal(CBBTC).allowance(address(safe), NPM), 0);
        assertEq(IERC20Minimal(WETH).allowance(address(safe), NPM), 0);
        assertEq(IERC20Minimal(CBBTC).allowance(address(safe), SWAP_ROUTER), 0);
        assertEq(IERC20Minimal(WETH).allowance(address(safe), SWAP_ROUTER), 0);
    }

    function test_fork_rebalance_revertsWhenInRange() public {
        if (!forkAvailable) return;
        // mint a position whose range CONTAINS currentTick → should revert InRange
        _setupOutOfRangePosition({
            lowerOffset: -3000,
            upperOffset: 3000, // includes alignedCurrent, hence currentTick
            fundWeth: 5e17,
            fundCbBTC: 2e6
        });

        vm.prank(keeper);
        vm.expectRevert(AerodromeRebalancer.InRange.selector);
        mod.rebalance(block.timestamp + 5 minutes);
    }
}
