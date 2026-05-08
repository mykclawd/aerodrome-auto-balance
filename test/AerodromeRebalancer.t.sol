// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AerodromeRebalancer} from "../src/AerodromeRebalancer.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockNPM} from "./mocks/MockNPM.sol";
import {MockGauge} from "./mocks/MockGauge.sol";
import {MinimalSafe} from "./mocks/MinimalSafe.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {INonfungiblePositionManager as INPM} from "../src/interfaces/INonfungiblePositionManager.sol";

contract AerodromeRebalancerTest is Test {
    MockPool internal pool;
    MockNPM internal npm;
    MockGauge internal gaugeMock;
    address internal safe = address(0xCAFE);
    address internal swapRouter = address(0xDEAD);
    address internal token0 = address(0xA);
    address internal token1 = address(0xB);
    int24 internal constant TICK_SPACING = 100;

    AerodromeRebalancer internal mod;

    function setUp() public {
        gaugeMock = new MockGauge();
        pool = new MockPool(token0, token1, TICK_SPACING, address(gaugeMock));
        npm = new MockNPM();
        mod = _deploy();

        vm.prank(safe);
        mod.setKeeper(address(this), true);
    }

    function _deploy() internal returns (AerodromeRebalancer) {
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(pool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });
        return new AerodromeRebalancer(p);
    }

    function _emptyKeepers() internal pure returns (address[] memory keepers) {
        keepers = new address[](0);
    }

    function _setValidPosition(uint256 tokenId, int24 lower, int24 upper, uint128 liq) internal {
        npm.setPositionConfig(tokenId, token0, token1, TICK_SPACING, lower, upper, liq);
        gaugeMock.setStaked(safe, tokenId, true);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(mod.SAFE(), safe);
        assertEq(mod.POOL(), address(pool));
        assertEq(mod.GAUGE(), address(gaugeMock));
        assertEq(mod.NPM(), address(npm));
        assertEq(mod.SWAP_ROUTER(), swapRouter);
        assertEq(mod.POOL_FACTORY(), address(pool));
        assertEq(mod.TOKEN0(), token0);
        assertEq(mod.TOKEN1(), token1);
        assertEq(int256(mod.TICK_SPACING()), int256(TICK_SPACING));
    }

    function test_constructor_setsInitialKeepersWhenProvided() public {
        address[] memory initialKeepers = new address[](3);
        initialKeepers[0] = address(0xBEEF);
        initialKeepers[1] = address(0xCA11);
        initialKeepers[2] = address(0xBEEF);

        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(pool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: initialKeepers,
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });

        AerodromeRebalancer withKeeper = new AerodromeRebalancer(p);
        assertTrue(withKeeper.keepers(initialKeepers[0]));
        assertTrue(withKeeper.keepers(initialKeepers[1]));
    }

    function test_constructor_revertsOnGaugeMismatch() public {
        MockPool wrongPool = new MockPool(token0, token1, TICK_SPACING, address(0xDEAD));
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(wrongPool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });
        vm.expectRevert(AerodromeRebalancer.ConfigMismatch.selector);
        new AerodromeRebalancer(p);
    }

    function test_constructor_revertsOnSlippageOverHardCap() public {
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(pool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: uint16(501),
            maxRebalanceLossBps: 100
        });
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        new AerodromeRebalancer(p);
    }

    function test_constructor_revertsOnLossOverHardCap() public {
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(pool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: uint16(501)
        });
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        new AerodromeRebalancer(p);
    }

    function test_constructor_revertsOnTickDeviationOverHardCap() public {
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(pool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: int24(1001),
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        new AerodromeRebalancer(p);
    }

    function test_constructor_revertsOnZeroTickSpacing() public {
        MockPool zeroSpacingPool = new MockPool(token0, token1, 0, address(gaugeMock));
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(zeroSpacingPool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        new AerodromeRebalancer(p);
    }

    function test_constructor_revertsWhenOracleCardinalityTooLow() public {
        pool.increaseObservationCardinalityNext(1);
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: address(pool),
            gauge: address(gaugeMock),
            npm: address(npm),
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        new AerodromeRebalancer(p);
    }

    function test_setters_revertWhenNotSafe() public {
        vm.expectRevert(AerodromeRebalancer.NotSafe.selector);
        mod.setTwapWindow(60);

        vm.expectRevert(AerodromeRebalancer.NotSafe.selector);
        mod.setKeeper(address(0xBEEF), true);
    }

    function test_setters_updateStateWhenSafe() public {
        _setValidPosition(1, -1000, 1000, 1e18);

        vm.startPrank(safe);
        mod.setTwapWindow(900);
        assertEq(uint256(mod.twapWindow()), 900);

        mod.setMaxTickDeviation(80);
        assertEq(int256(mod.maxTickDeviation()), 80);

        mod.setMaxSlippageBps(70);
        assertEq(uint256(mod.maxSlippageBps()), 70);

        mod.setMaxRebalanceLossBps(150);
        assertEq(uint256(mod.maxRebalanceLossBps()), 150);

        mod.setCurrentTokenId(1);
        assertEq(mod.currentTokenId(), 1);

        mod.setKeeper(address(0xBEEF), true);
        assertTrue(mod.keepers(address(0xBEEF)));

        mod.pause();
        assertTrue(mod.paused());
        mod.unpause();
        assertFalse(mod.paused());
        vm.stopPrank();
    }

    function test_setMaxSlippageBps_rejectsOverflow() public {
        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        mod.setMaxSlippageBps(uint16(501));
    }

    function test_setMaxRebalanceLossBps_rejectsOverflow() public {
        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        mod.setMaxRebalanceLossBps(uint16(501));
    }

    function test_setMaxTickDeviation_rejectsOverflow() public {
        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        mod.setMaxTickDeviation(int24(1001));
    }

    function test_setTwapWindow_revertsWhenOracleCardinalityTooLow() public {
        pool.increaseObservationCardinalityNext(1);
        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        mod.setTwapWindow(120);
    }

    function test_setCurrentTokenId_rejectsZero() public {
        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        mod.setCurrentTokenId(0);
    }

    function test_setCurrentTokenId_revertsOnPoolConfigMismatch() public {
        npm.setPositionConfig(1, token1, token0, TICK_SPACING, -1000, 1000, 1e18);
        gaugeMock.setStaked(safe, 1, true);

        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.ConfigMismatch.selector);
        mod.setCurrentTokenId(1);
    }

    function test_setCurrentTokenId_revertsWhenNotStaked() public {
        npm.setPositionConfig(1, token0, token1, TICK_SPACING, -1000, 1000, 1e18);

        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.NotStaked.selector);
        mod.setCurrentTokenId(1);
    }

    function test_setCurrentTokenId_revertsOnInvalidTickGeometry() public {
        npm.setPositionConfig(1, token0, token1, TICK_SPACING, 100, 100, 1e18);
        gaugeMock.setStaked(safe, 1, true);

        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.ConfigMismatch.selector);
        mod.setCurrentTokenId(1);
    }

    function test_setCurrentTokenId_revertsOnUnalignedWidth() public {
        npm.setPositionConfig(1, token0, token1, TICK_SPACING, -950, 1000, 1e18);
        gaugeMock.setStaked(safe, 1, true);

        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.ConfigMismatch.selector);
        mod.setCurrentTokenId(1);
    }

    function test_setCurrentTokenId_revertsOnUnalignedLowerTick() public {
        npm.setPositionConfig(1, token0, token1, TICK_SPACING, 50, 250, 1e18);
        gaugeMock.setStaked(safe, 1, true);

        vm.prank(safe);
        vm.expectRevert(AerodromeRebalancer.ConfigMismatch.selector);
        mod.setCurrentTokenId(1);
    }

    function test_rebalance_revertsWhenCallerNotKeeper() public {
        vm.prank(address(0x1234));
        vm.expectRevert(AerodromeRebalancer.NotSafe.selector);
        mod.rebalance(block.timestamp);
    }

    function test_rebalance_revertsWhenPaused() public {
        vm.prank(safe);
        mod.pause();

        vm.expectRevert(AerodromeRebalancer.IsPaused.selector);
        mod.rebalance(block.timestamp);
    }

    function test_rebalance_revertsWhenDeadlineExpired() public {
        vm.warp(100);
        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        mod.rebalance(block.timestamp - 1);
    }

    function test_rebalance_revertsWhenTokenIdUnset() public {
        vm.expectRevert(AerodromeRebalancer.TokenIdUnset.selector);
        mod.rebalance(block.timestamp);
    }

    function test_rebalance_revertsWhenInRange() public {
        _setValidPosition(1, -1000, 1000, 1e18);
        vm.startPrank(safe);
        mod.setCurrentTokenId(1);
        vm.stopPrank();

        pool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        vm.expectRevert(AerodromeRebalancer.InRange.selector);
        mod.rebalance(block.timestamp);
    }

    function test_rebalance_revertsOnTwapDeviation() public {
        _setValidPosition(1, -1000, 1000, 1e18);
        vm.startPrank(safe);
        mod.setCurrentTokenId(1);
        vm.stopPrank();

        pool.setSlot0(TickMath.getSqrtRatioAtTick(1500), 1500);
        pool.setTickCumulatives(0, 0);

        vm.expectRevert(AerodromeRebalancer.TwapDeviation.selector);
        mod.rebalance(block.timestamp);
    }

    function test_mintNewPosition_usesPostSwapSpotForAmountMins() public {
        MockERC20 token0Mock = new MockERC20();
        MockERC20 token1Mock = new MockERC20();
        MinimalSafe safeMock = new MinimalSafe();
        MockGauge gauge = new MockGauge();
        MockPool spotPool = new MockPool(address(token0Mock), address(token1Mock), TICK_SPACING, address(gauge));
        MintSpyNPM spyNpm = new MintSpyNPM(token0Mock, token1Mock, TICK_SPACING, -1000, 1000, 1e18);

        AerodromeRebalancerHarness harness =
            _deployHarness(address(safeMock), address(spotPool), address(gauge), address(spyNpm));
        safeMock.enableModule(address(harness));
        token0Mock.mint(address(safeMock), 10e18);
        token1Mock.mint(address(safeMock), 10e18);

        int24 lower = -500;
        int24 upper = 500;
        uint160 spotSqrt = TickMath.getSqrtRatioAtTick(200);
        uint160 twapSqrt = TickMath.getSqrtRatioAtTick(-200);
        spotPool.setSlot0(spotSqrt, 200);

        AerodromeRebalancer.RebalanceCtx memory ctx;
        ctx.newLower = lower;
        ctx.newUpper = upper;
        ctx.newSqrtA = TickMath.getSqrtRatioAtTick(lower);
        ctx.newSqrtB = TickMath.getSqrtRatioAtTick(upper);
        ctx.twapSqrtX96 = twapSqrt;
        ctx.amount0ToUse = 10e18;
        ctx.amount1ToUse = 10e18;

        harness.exposedMintNewPosition(ctx, block.timestamp + 1);

        uint128 spotL = LiquidityAmounts.getLiquidityForAmounts(
            spotSqrt, ctx.newSqrtA, ctx.newSqrtB, ctx.amount0ToUse, ctx.amount1ToUse
        );
        (uint256 spotA0, uint256 spotA1) =
            LiquidityAmounts.getAmountsForLiquidity(spotSqrt, ctx.newSqrtA, ctx.newSqrtB, spotL);
        uint256 expectedSpotMin0 = spotA0 * 9950 / 10_000;
        uint256 expectedSpotMin1 = spotA1 * 9950 / 10_000;

        uint128 twapL = LiquidityAmounts.getLiquidityForAmounts(
            twapSqrt, ctx.newSqrtA, ctx.newSqrtB, ctx.amount0ToUse, ctx.amount1ToUse
        );
        (uint256 twapA0, uint256 twapA1) =
            LiquidityAmounts.getAmountsForLiquidity(twapSqrt, ctx.newSqrtA, ctx.newSqrtB, twapL);

        assertEq(spyNpm.lastAmount0Min(), expectedSpotMin0, "amount0Min uses spot");
        assertEq(spyNpm.lastAmount1Min(), expectedSpotMin1, "amount1Min uses spot");
        assertNotEq(spyNpm.lastAmount0Min(), twapA0 * 9950 / 10_000, "amount0Min should not use twap");
        assertNotEq(spyNpm.lastAmount1Min(), twapA1 * 9950 / 10_000, "amount1Min should not use twap");
    }

    function test_rangeRatioSwap_handlesZeroLiquidityDustOnRequiredSide() public {
        AerodromeRebalancerHarness harness = _deployHarness(safe, address(pool), address(gaugeMock), address(npm));

        AerodromeRebalancer.RebalanceCtx memory ctx;
        ctx.sqrtPriceX96 = TickMath.getSqrtRatioAtTick(-265764);
        ctx.twapSqrtX96 = ctx.sqrtPriceX96;
        ctx.newSqrtA = TickMath.getSqrtRatioAtTick(-265780);
        ctx.newSqrtB = TickMath.getSqrtRatioAtTick(-265750);

        uint256 b0 = 27;
        uint256 b1 = 11_366_373;
        assertEq(
            LiquidityAmounts.getLiquidityForAmounts(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, b0, b1),
            0,
            "dust WETH should compute zero liquidity before swap"
        );

        (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 expectedOut) =
            harness.exposedRangeRatioSwap(ctx, b0, b1);

        assertTrue(shouldSwap, "should swap surplus cbBTC");
        assertFalse(zeroForOne, "cbBTC -> WETH");
        assertGt(amountIn, 0, "swap input");
        assertGt(expectedOut, 0, "swap output");

        b1 -= amountIn;
        b0 += expectedOut;
        assertGt(
            LiquidityAmounts.getLiquidityForAmounts(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, b0, b1),
            0,
            "post-swap balances should mint positive liquidity"
        );
    }

    function test_rangeRatioSwap_handlesPositiveLiquidityDustOnRequiredSide() public {
        AerodromeRebalancerHarness harness = _deployHarness(safe, address(pool), address(gaugeMock), address(npm));

        AerodromeRebalancer.RebalanceCtx memory ctx;
        ctx.sqrtPriceX96 = TickMath.getSqrtRatioAtTick(-265764);
        ctx.twapSqrtX96 = ctx.sqrtPriceX96;
        ctx.newSqrtA = TickMath.getSqrtRatioAtTick(-265780);
        ctx.newSqrtB = TickMath.getSqrtRatioAtTick(-265750);

        uint256 b0 = 1_000;
        uint256 b1 = 11_366_373;
        uint128 preL = LiquidityAmounts.getLiquidityForAmounts(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, b0, b1);
        assertGt(preL, 0, "dust WETH should compute positive but tiny liquidity");

        (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 expectedOut) =
            harness.exposedRangeRatioSwap(ctx, b0, b1);

        assertTrue(shouldSwap, "should swap surplus cbBTC");
        assertFalse(zeroForOne, "cbBTC -> WETH");
        assertGt(amountIn, 0, "swap input");
        assertGt(expectedOut, 0, "swap output");

        b1 -= amountIn;
        b0 += expectedOut;
        assertGt(
            LiquidityAmounts.getLiquidityForAmounts(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, b0, b1),
            preL,
            "post-swap liquidity should improve"
        );
    }

    function test_mintNewPosition_revertsBeforeNpmWhenExpectedLiquidityZero() public {
        MockERC20 token0Mock = new MockERC20();
        MockERC20 token1Mock = new MockERC20();
        MinimalSafe safeMock = new MinimalSafe();
        MockGauge gauge = new MockGauge();
        MockPool spotPool = new MockPool(address(token0Mock), address(token1Mock), TICK_SPACING, address(gauge));
        MintSpyNPM spyNpm = new MintSpyNPM(token0Mock, token1Mock, TICK_SPACING, -265850, -265820, 1e18);

        AerodromeRebalancerHarness harness =
            _deployHarness(address(safeMock), address(spotPool), address(gauge), address(spyNpm));
        spotPool.setSlot0(TickMath.getSqrtRatioAtTick(-265764), -265764);

        AerodromeRebalancer.RebalanceCtx memory ctx;
        ctx.newLower = -265780;
        ctx.newUpper = -265750;
        ctx.newSqrtA = TickMath.getSqrtRatioAtTick(ctx.newLower);
        ctx.newSqrtB = TickMath.getSqrtRatioAtTick(ctx.newUpper);
        ctx.amount0ToUse = 27;
        ctx.amount1ToUse = 11_366_373;

        vm.expectRevert(AerodromeRebalancer.InvalidParam.selector);
        harness.exposedMintNewPosition(ctx, block.timestamp + 1);
    }

    function test_enforcePostInvariants_countsIdleSafeBalancesInValueAfter() public {
        MockERC20 token0Mock = new MockERC20();
        MockERC20 token1Mock = new MockERC20();
        MinimalSafe safeMock = new MinimalSafe();
        MockGauge gauge = new MockGauge();
        MockPool valuePool = new MockPool(address(token0Mock), address(token1Mock), TICK_SPACING, address(gauge));
        MintSpyNPM spyNpm = new MintSpyNPM(token0Mock, token1Mock, TICK_SPACING, -1000, 1000, 1);

        AerodromeRebalancerHarness harness =
            _deployHarness(address(safeMock), address(valuePool), address(gauge), address(spyNpm));
        safeMock.enableModule(address(harness));

        int24 lower = -500;
        int24 upper = 500;
        valuePool.setSlot0(TickMath.getSqrtRatioAtTick(0), 0);
        token1Mock.mint(address(safeMock), 1_000);
        spyNpm.setPositionConfig(42, address(token0Mock), address(token1Mock), TICK_SPACING, lower, upper, 1);
        gauge.setStaked(address(safeMock), 42, true);

        AerodromeRebalancer.RebalanceCtx memory ctx;
        ctx.newTokenId = 42;
        ctx.newLower = lower;
        ctx.newUpper = upper;
        ctx.newSqrtA = TickMath.getSqrtRatioAtTick(lower);
        ctx.newSqrtB = TickMath.getSqrtRatioAtTick(upper);
        ctx.twapSqrtX96 = TickMath.getSqrtRatioAtTick(0);
        ctx.valueBefore = 1_000;

        uint256 valueAfter = harness.exposedEnforcePostInvariants(ctx);
        assertGe(valueAfter, 990, "idle token balance should satisfy value floor");
    }

    function _deployHarness(address safe_, address pool_, address gauge_, address npm_)
        internal
        returns (AerodromeRebalancerHarness)
    {
        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe_,
            pool: pool_,
            gauge: gauge_,
            npm: npm_,
            swapRouter: swapRouter,
            initialKeepers: _emptyKeepers(),
            twapWindow: 600,
            maxTickDeviation: 50,
            maxSlippageBps: 50,
            maxRebalanceLossBps: 100
        });
        return new AerodromeRebalancerHarness(p);
    }
}

contract AerodromeRebalancerHarness is AerodromeRebalancer {
    constructor(ConstructorParams memory p) AerodromeRebalancer(p) {}

    function exposedMintNewPosition(RebalanceCtx memory ctx, uint256 deadline) external returns (uint256) {
        return _mintNewPosition(ctx, deadline);
    }

    function exposedEnforcePostInvariants(RebalanceCtx memory ctx) external view returns (uint256) {
        _enforcePostInvariants(ctx);
        return ctx.valueAfter;
    }

    function exposedRangeRatioSwap(RebalanceCtx memory ctx, uint256 b0, uint256 b1)
        external
        pure
        returns (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 expectedOut)
    {
        return _rangeRatioSwap(ctx, b0, b1);
    }
}

contract MockERC20 is IERC20Minimal {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MintSpyNPM is INPM {
    struct Pos {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    MockERC20 public immutable token0Mock;
    MockERC20 public immutable token1Mock;
    int24 public immutable spacing;

    uint256 public lastAmount0Min;
    uint256 public lastAmount1Min;
    uint256 public nextTokenId = 42;
    mapping(uint256 => Pos) public posOf;

    constructor(
        MockERC20 _token0,
        MockERC20 _token1,
        int24 _spacing,
        int24 initialLower,
        int24 initialUpper,
        uint128 initialLiquidity
    ) {
        token0Mock = _token0;
        token1Mock = _token1;
        spacing = _spacing;
        setPositionConfig(1, address(_token0), address(_token1), _spacing, initialLower, initialUpper, initialLiquidity);
    }

    function setPositionConfig(
        uint256 tokenId,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) public {
        posOf[tokenId] = Pos({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        lastAmount0Min = params.amount0Min;
        lastAmount1Min = params.amount1Min;
        tokenId = nextTokenId++;
        liquidity = 1e18;
        amount0 = params.amount0Min;
        amount1 = params.amount1Min;
        setPositionConfig(
            tokenId, params.token0, params.token1, params.tickSpacing, params.tickLower, params.tickUpper, liquidity
        );
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {}

    function collect(CollectParams calldata) external payable returns (uint256 amount0, uint256 amount1) {}

    function burn(uint256) external payable {}

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Pos memory p = posOf[tokenId];
        return (0, address(0), p.token0, p.token1, p.tickSpacing, p.tickLower, p.tickUpper, p.liquidity, 0, 0, 0, 0);
    }

    function approve(address, uint256) external pure {}

    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }
}
