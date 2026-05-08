// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {ISafe} from "./interfaces/ISafe.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {ICLGauge} from "./interfaces/ICLGauge.sol";
import {INonfungiblePositionManager as INPM} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

import {TickMath} from "./libraries/TickMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {FixedPoint96} from "./libraries/FixedPoint96.sol";

/// @title AerodromeRebalancer
/// @notice Gnosis Safe module that rebalances the Safe's Aerodrome SlipStream
///         concentrated-liquidity position so it is always centered on the current pool tick.
///         `rebalance(deadline)` is callable by the Safe and Safe-allowlisted keepers. Every external
///         call routed through the Safe is locked to immutable target contracts and to the
///         minimum sequence of operations required to keep the position in range.
contract AerodromeRebalancer is ReentrancyGuard {
    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                  */
    /* -------------------------------------------------------------------------- */

    uint256 public constant BPS_DENOM = 10_000;
    uint16 public constant MAX_ALLOWED_SLIPPAGE_BPS = 500;
    uint16 public constant MAX_ALLOWED_LOSS_BPS = 500;
    int24 public constant MAX_ALLOWED_TICK_DEVIATION = 1000;
    address public constant AERODROME_CL_FACTORY_2 = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address public constant AERODROME_CL_FACTORY_3 = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    uint24 internal constant UNIVERSAL_ROUTER_CL_FACTORY_2_FLAG = 0x100000;
    uint24 internal constant UNIVERSAL_ROUTER_CL_FACTORY_3_FLAG = 0x080000;

    /* -------------------------------------------------------------------------- */
    /*                                  Immutables                                 */
    /* -------------------------------------------------------------------------- */

    address public immutable SAFE;
    address public immutable POOL;
    address public immutable GAUGE;
    address public immutable NPM;
    address public immutable SWAP_ROUTER;
    address public immutable POOL_FACTORY;
    address public immutable TOKEN0;
    address public immutable TOKEN1;
    int24 public immutable TICK_SPACING;

    /* -------------------------------------------------------------------------- */
    /*                                Mutable state                                */
    /* -------------------------------------------------------------------------- */

    uint256 public currentTokenId;
    uint32 public twapWindow;
    int24 public maxTickDeviation;
    uint16 public maxSlippageBps;
    uint16 public maxRebalanceLossBps;
    bool public paused;
    mapping(address => bool) public keepers;

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                    */
    /* -------------------------------------------------------------------------- */

    error ZeroAddress();
    error ConfigMismatch();
    error NotSafe();
    error IsPaused();
    error InRange();
    error TwapDeviation();
    error WidthChanged();
    error NotInRange();
    error NotStaked();
    error StaleApproval();
    error ValueFloor();
    error SafeCallFailed();
    error TokenIdUnset();
    error InvalidParam();
    error ExecFailed();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                    */
    /* -------------------------------------------------------------------------- */

    event Rebalanced(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 currentTick,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 valueBefore,
        uint256 valueAfter,
        uint256 swapIn,
        uint256 swapOut
    );
    event PausedSet(bool paused);
    event CurrentTokenIdSet(uint256 indexed previous, uint256 indexed current);
    event TwapWindowSet(uint32 previous, uint32 current);
    event MaxTickDeviationSet(int24 previous, int24 current);
    event MaxSlippageBpsSet(uint16 previous, uint16 current);
    event MaxRebalanceLossBpsSet(uint16 previous, uint16 current);
    event KeeperSet(address indexed keeper, bool allowed);

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                  */
    /* -------------------------------------------------------------------------- */

    modifier onlySafe() {
        if (msg.sender != SAFE) revert NotSafe();
        _;
    }

    modifier onlyKeeperOrSafe() {
        if (msg.sender != SAFE && !keepers[msg.sender]) revert NotSafe();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Constructor                                 */
    /* -------------------------------------------------------------------------- */

    struct ConstructorParams {
        address safe;
        address pool;
        address gauge;
        address npm;
        address swapRouter;
        address[] initialKeepers;
        uint32 twapWindow;
        int24 maxTickDeviation;
        uint16 maxSlippageBps;
        uint16 maxRebalanceLossBps;
    }

    constructor(ConstructorParams memory p) {
        if (
            p.safe == address(0) || p.pool == address(0) || p.gauge == address(0) || p.npm == address(0)
                || p.swapRouter == address(0)
        ) revert ZeroAddress();
        if (
            p.twapWindow == 0 || p.maxSlippageBps > MAX_ALLOWED_SLIPPAGE_BPS
                || p.maxRebalanceLossBps > MAX_ALLOWED_LOSS_BPS || p.maxTickDeviation < 0
                || p.maxTickDeviation > MAX_ALLOWED_TICK_DEVIATION
        ) {
            revert InvalidParam();
        }

        SAFE = p.safe;
        POOL = p.pool;
        GAUGE = p.gauge;
        NPM = p.npm;
        SWAP_ROUTER = p.swapRouter;

        // Defense-in-depth: read pool, confirm immutables match its on-chain state.
        ICLPool poolI = ICLPool(p.pool);
        POOL_FACTORY = poolI.factory();
        TOKEN0 = poolI.token0();
        TOKEN1 = poolI.token1();
        TICK_SPACING = poolI.tickSpacing();
        if (TICK_SPACING <= 0) revert InvalidParam();
        if (poolI.gauge() != p.gauge) revert ConfigMismatch();
        _validateTwapWindow(poolI, p.twapWindow);

        twapWindow = p.twapWindow;
        maxTickDeviation = p.maxTickDeviation;
        maxSlippageBps = p.maxSlippageBps;
        maxRebalanceLossBps = p.maxRebalanceLossBps;

        for (uint256 i = 0; i < p.initialKeepers.length; ++i) {
            address keeper = p.initialKeepers[i];
            if (keeper != address(0) && !keepers[keeper]) {
                keepers[keeper] = true;
                emit KeeperSet(keeper, true);
            }
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                              Safe-only setters                              */
    /* -------------------------------------------------------------------------- */

    function setCurrentTokenId(uint256 newId) external onlySafe {
        if (newId == 0) revert InvalidParam();
        (,, address token0, address token1, int24 spacing, int24 tickLower, int24 tickUpper, uint128 liq,,,,) =
            INPM(NPM).positions(newId);
        if (
            token0 != TOKEN0 || token1 != TOKEN1 || spacing != TICK_SPACING || liq == 0 || tickLower >= tickUpper
                || (tickLower % TICK_SPACING) != 0 || (tickUpper % TICK_SPACING) != 0
        ) revert ConfigMismatch();
        if (!ICLGauge(GAUGE).stakedContains(SAFE, newId)) revert NotStaked();
        emit CurrentTokenIdSet(currentTokenId, newId);
        currentTokenId = newId;
    }

    function setTwapWindow(uint32 newWindow) external onlySafe {
        if (newWindow == 0) revert InvalidParam();
        _validateTwapWindow(ICLPool(POOL), newWindow);
        emit TwapWindowSet(twapWindow, newWindow);
        twapWindow = newWindow;
    }

    function setMaxTickDeviation(int24 newDeviation) external onlySafe {
        if (newDeviation < 0 || newDeviation > MAX_ALLOWED_TICK_DEVIATION) revert InvalidParam();
        emit MaxTickDeviationSet(maxTickDeviation, newDeviation);
        maxTickDeviation = newDeviation;
    }

    function setMaxSlippageBps(uint16 newBps) external onlySafe {
        if (newBps > MAX_ALLOWED_SLIPPAGE_BPS) revert InvalidParam();
        emit MaxSlippageBpsSet(maxSlippageBps, newBps);
        maxSlippageBps = newBps;
    }

    function setMaxRebalanceLossBps(uint16 newBps) external onlySafe {
        if (newBps > MAX_ALLOWED_LOSS_BPS) revert InvalidParam();
        emit MaxRebalanceLossBpsSet(maxRebalanceLossBps, newBps);
        maxRebalanceLossBps = newBps;
    }

    function setKeeper(address keeper, bool allowed) external onlySafe {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function pause() external onlySafe {
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlySafe {
        paused = false;
        emit PausedSet(false);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Rebalance                                  */
    /* -------------------------------------------------------------------------- */

    struct RebalanceCtx {
        uint256 tokenId;
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 twapTick;
        uint160 twapSqrtX96;
        int24 oldLower;
        int24 oldUpper;
        uint128 oldLiquidity;
        int24 newLower;
        int24 newUpper;
        uint160 newSqrtA;
        uint160 newSqrtB;
        uint256 valueBefore;
        uint256 valueAfter;
        uint256 swapIn;
        uint256 swapOut;
        uint256 newTokenId;
        uint256 amount0ToUse;
        uint256 amount1ToUse;
    }

    function rebalance(uint256 deadline) external nonReentrant onlyKeeperOrSafe returns (RebalanceCtx memory ctx) {
        if (paused) revert IsPaused();
        if (deadline < block.timestamp) revert InvalidParam();

        ctx.tokenId = currentTokenId;
        if (ctx.tokenId == 0) revert TokenIdUnset();

        _readPoolAndPosition(ctx);
        _checkTwapAndOutOfRange(ctx);
        _computeNewTicks(ctx);

        ctx.valueBefore = _snapshotValue(ctx, ctx.oldLiquidity);

        // 1) unstake (collects fees & AERO into SAFE in one call)
        _safeExec(GAUGE, abi.encodeCall(ICLGauge.withdraw, (ctx.tokenId)));

        // 2) drain liquidity from old NFT, sweep dust, burn the empty NFT
        _safeExec(
            NPM,
            abi.encodeCall(
                INPM.decreaseLiquidity,
                (
                    INPM.DecreaseLiquidityParams({
                        tokenId: ctx.tokenId,
                        liquidity: ctx.oldLiquidity,
                        amount0Min: _withdrawAmountMin(ctx, true),
                        amount1Min: _withdrawAmountMin(ctx, false),
                        deadline: deadline
                    })
                )
            )
        );
        _safeExec(
            NPM,
            abi.encodeCall(
                INPM.collect,
                (
                    INPM.CollectParams({
                        tokenId: ctx.tokenId,
                        recipient: SAFE,
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                )
            )
        );
        _safeExec(NPM, abi.encodeCall(INPM.burn, (ctx.tokenId)));

        uint256 post0 = _safeBalance(TOKEN0);
        uint256 post1 = _safeBalance(TOKEN1);
        ctx.amount0ToUse = post0;
        ctx.amount1ToUse = post1;

        // 3) one-leg swap to balance, if needed
        _balanceAndSwap(ctx, deadline);

        // 4) mint new position with all balances; NPM refunds dust
        ctx.newTokenId = _mintNewPosition(ctx, deadline);

        // 5) re-stake into the gauge
        _safeExec(NPM, abi.encodeCall(INPM.approve, (GAUGE, ctx.newTokenId)));
        _safeExec(GAUGE, abi.encodeCall(ICLGauge.deposit, (ctx.newTokenId)));

        // 6) post-state invariants
        _enforcePostInvariants(ctx);

        emit CurrentTokenIdSet(ctx.tokenId, ctx.newTokenId);
        currentTokenId = ctx.newTokenId;

        emit Rebalanced(
            ctx.tokenId,
            ctx.newTokenId,
            ctx.currentTick,
            ctx.newLower,
            ctx.newUpper,
            ctx.valueBefore,
            ctx.valueAfter,
            ctx.swapIn,
            ctx.swapOut
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                              Internal helpers                                */
    /* -------------------------------------------------------------------------- */

    function _readPoolAndPosition(RebalanceCtx memory ctx) internal view {
        (ctx.sqrtPriceX96, ctx.currentTick,,,,) = ICLPool(POOL).slot0();
        (,,,,, ctx.oldLower, ctx.oldUpper, ctx.oldLiquidity,,,,) = INPM(NPM).positions(ctx.tokenId);
        if (ctx.oldLiquidity == 0) revert InvalidParam();
    }

    function _checkTwapAndOutOfRange(RebalanceCtx memory ctx) internal view {
        // out-of-range gate
        if (ctx.currentTick >= ctx.oldLower && ctx.currentTick < ctx.oldUpper) revert InRange();

        // TWAP sanity vs spot
        ctx.twapTick = OracleLibrary.consult(POOL, twapWindow);
        int24 dev = ctx.currentTick > ctx.twapTick ? ctx.currentTick - ctx.twapTick : ctx.twapTick - ctx.currentTick;
        if (dev > maxTickDeviation) revert TwapDeviation();
        ctx.twapSqrtX96 = TickMath.getSqrtRatioAtTick(ctx.twapTick);
    }

    /// @dev Inherit width, recenter on `currentTick`. Aligns to TICK_SPACING grid.
    function _computeNewTicks(RebalanceCtx memory ctx) internal view {
        int24 width = ctx.oldUpper - ctx.oldLower;
        int24 halfWidth = width / 2;
        int24 lower = _floorToSpacing(ctx.currentTick - halfWidth);
        int24 upper = lower + width; // width is a multiple of TICK_SPACING because old position was aligned
        if (ctx.currentTick >= upper) {
            lower += TICK_SPACING;
            upper += TICK_SPACING;
        }
        if (upper - lower != width) revert WidthChanged();
        if (!(ctx.currentTick >= lower && ctx.currentTick < upper)) revert NotInRange();
        ctx.newLower = lower;
        ctx.newUpper = upper;
        ctx.newSqrtA = TickMath.getSqrtRatioAtTick(lower);
        ctx.newSqrtB = TickMath.getSqrtRatioAtTick(upper);
    }

    /// @dev Floor toward negative infinity, snapped to TICK_SPACING multiple.
    function _floorToSpacing(int24 t) internal view returns (int24) {
        int24 spacing = TICK_SPACING;
        int24 q = t / spacing;
        if (t < 0 && (t % spacing != 0)) q -= 1;
        return q * spacing;
    }

    /// @dev Token1-denominated value of the old position's LP principal, priced at the *TWAP* sqrt price.
    ///      Using TWAP (not spot) for the snapshot makes the floor invariant manipulation-resistant.
    function _snapshotValue(RebalanceCtx memory ctx, uint128 liquidity) internal pure returns (uint256 value) {
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            ctx.twapSqrtX96,
            TickMath.getSqrtRatioAtTick(ctx.oldLower),
            TickMath.getSqrtRatioAtTick(ctx.oldUpper),
            liquidity
        );
        value = a1 + _token0ToToken1(a0, ctx.twapSqrtX96);
    }

    /// @dev Token1-denominated value of a freshly-staked new position with `liquidity`
    ///      sitting between `newLower` / `newUpper`, plus current Safe balances, at TWAP price.
    function _valueAtNewRange(RebalanceCtx memory ctx, uint128 liquidity, uint256 b0, uint256 b1)
        internal
        pure
        returns (uint256 value)
    {
        (uint256 a0, uint256 a1) =
            LiquidityAmounts.getAmountsForLiquidity(ctx.twapSqrtX96, ctx.newSqrtA, ctx.newSqrtB, liquidity);
        value = b1 + a1 + _token0ToToken1(b0 + a0, ctx.twapSqrtX96);
    }

    /// @dev token1 = token0 * (sqrtP^2 / 2^192)
    function _token0ToToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // sqrt^2 / Q192. Avoid overflow by FullMath: amount0 * sqrt / Q96 then again * sqrt / Q96.
        uint256 step = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(step, sqrtPriceX96, FixedPoint96.Q96);
    }

    function _token1ToToken0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 step = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96);
        return FullMath.mulDiv(step, FixedPoint96.Q96, sqrtPriceX96);
    }

    /// @dev Compute the binding liquidity at the new range with current Safe balances; if one
    ///      side is in surplus, swap part of that side toward the range-implied token ratio.
    ///      Anything left over after `mint` becomes Safe dust and is re-used on the next rebalance.
    function _balanceAndSwap(RebalanceCtx memory ctx, uint256 deadline) internal {
        uint256 b0 = ctx.amount0ToUse;
        uint256 b1 = ctx.amount1ToUse;

        uint128 L = LiquidityAmounts.getLiquidityForAmounts(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, b0, b1);
        if (L == 0) {
            (bool shouldSwap, bool swapZeroForOne, uint256 swapAmountIn,) = _zeroLiquiditySwap(ctx, b0, b1);
            if (shouldSwap) {
                _swapExact(
                    ctx, swapZeroForOne ? TOKEN0 : TOKEN1, swapZeroForOne ? TOKEN1 : TOKEN0, swapAmountIn, deadline
                );
            }
            return;
        }
        (uint256 req0, uint256 req1) =
            LiquidityAmounts.getAmountsForLiquidity(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, L);

        bool zeroForOne;
        uint256 amountIn;
        if (b0 > req0) {
            zeroForOne = true;
            amountIn = (b0 - req0) / 2;
        } else if (b1 > req1) {
            zeroForOne = false;
            amountIn = (b1 - req1) / 2;
        }
        if (amountIn == 0) return;

        _swapExact(ctx, zeroForOne ? TOKEN0 : TOKEN1, zeroForOne ? TOKEN1 : TOKEN0, amountIn, deadline);
    }

    function _zeroLiquiditySwap(RebalanceCtx memory ctx, uint256 b0, uint256 b1)
        internal
        pure
        returns (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 expectedOut)
    {
        // When one side is dust, the combined balances can still compute to L == 0.
        // Rebalance by value toward the token ratio implied by the new range.
        (uint256 ref0, uint256 ref1) =
            LiquidityAmounts.getAmountsForLiquidity(ctx.sqrtPriceX96, ctx.newSqrtA, ctx.newSqrtB, uint128(1e18));
        if (ref0 == 0 || ref1 == 0) return (false, false, 0, 0);

        uint256 ref0In1 = _token0ToToken1(ref0, ctx.twapSqrtX96);
        uint256 totalRefIn1 = ref0In1 + ref1;
        if (totalRefIn1 == 0) return (false, false, 0, 0);

        uint256 totalIn1 = b1 + _token0ToToken1(b0, ctx.twapSqrtX96);
        if (totalIn1 == 0) return (false, false, 0, 0);

        uint256 target1 = FullMath.mulDiv(totalIn1, ref1, totalRefIn1);
        if (b1 > target1) {
            amountIn = b1 - target1;
            expectedOut = _token1ToToken0(amountIn, ctx.twapSqrtX96);
            return (expectedOut > 0, false, amountIn, expectedOut);
        }

        uint256 missing1 = target1 - b1;
        amountIn = _token1ToToken0(missing1, ctx.twapSqrtX96);
        if (amountIn > b0) amountIn = b0;
        expectedOut = _token0ToToken1(amountIn, ctx.twapSqrtX96);
        return (amountIn > 0 && expectedOut > 0, true, amountIn, expectedOut);
    }

    function _swapExact(RebalanceCtx memory ctx, address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline)
        internal
    {
        if (amountIn == 0) return;

        bool zeroForOne = tokenIn == TOKEN0;
        uint256 expectedOut =
            zeroForOne ? _token0ToToken1(amountIn, ctx.twapSqrtX96) : _token1ToToken0(amountIn, ctx.twapSqrtX96);
        uint256 minOut = expectedOut * (BPS_DENOM - maxSlippageBps) / BPS_DENOM;

        uint256 preIn = _safeBalance(tokenIn);
        uint256 preOut = _safeBalance(tokenOut);

        // Transfer funds in first so the Universal Router pays from its own balance, avoiding
        // Permit2 and leaving no persistent Safe approval behind.
        _safeExec(tokenIn, abi.encodeCall(IERC20Minimal.transfer, (SWAP_ROUTER, amountIn)));
        bytes memory commands = hex"00";
        bytes memory path = abi.encodePacked(tokenIn, _universalRouterPoolParam(), tokenOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(SAFE, amountIn, minOut, path, false, false);
        _safeExec(SWAP_ROUTER, abi.encodeCall(IUniversalRouter.execute, (commands, inputs, deadline)));

        uint256 spentIn = preIn - _safeBalance(tokenIn);
        uint256 amountOut = _safeBalance(tokenOut) - preOut;

        if (zeroForOne) {
            ctx.amount0ToUse -= spentIn;
            ctx.amount1ToUse += amountOut;
        } else {
            ctx.amount1ToUse -= spentIn;
            ctx.amount0ToUse += amountOut;
        }
        ctx.swapIn = spentIn;
        ctx.swapOut = amountOut;
    }

    function _universalRouterPoolParam() internal view returns (uint24 poolParam) {
        poolParam = uint24(uint256(int256(TICK_SPACING)));
        if (POOL_FACTORY == AERODROME_CL_FACTORY_2) return poolParam | UNIVERSAL_ROUTER_CL_FACTORY_2_FLAG;
        if (POOL_FACTORY == AERODROME_CL_FACTORY_3) return poolParam | UNIVERSAL_ROUTER_CL_FACTORY_3_FLAG;
    }

    function _mintNewPosition(RebalanceCtx memory ctx, uint256 deadline) internal returns (uint256 newTokenId) {
        uint256 b0 = ctx.amount0ToUse;
        uint256 b1 = ctx.amount1ToUse;

        // Mint-side mins should match the pool state NPM will actually use after the balancing swap.
        (uint160 spotSqrtX96,,,,,) = ICLPool(POOL).slot0();
        uint160 mintSqrtX96 = _clampSqrtToRange(spotSqrtX96, ctx.newSqrtA, ctx.newSqrtB);
        uint128 expectedL = LiquidityAmounts.getLiquidityForAmounts(mintSqrtX96, ctx.newSqrtA, ctx.newSqrtB, b0, b1);
        if (expectedL == 0) revert InvalidParam();
        (uint256 expA0, uint256 expA1) =
            LiquidityAmounts.getAmountsForLiquidity(mintSqrtX96, ctx.newSqrtA, ctx.newSqrtB, expectedL);
        uint256 a0Min = expA0 * (BPS_DENOM - maxSlippageBps) / BPS_DENOM;
        uint256 a1Min = expA1 * (BPS_DENOM - maxSlippageBps) / BPS_DENOM;

        _safeApprove(TOKEN0, NPM, b0);
        _safeApprove(TOKEN1, NPM, b1);

        bytes memory ret = _safeExec(
            NPM,
            abi.encodeCall(
                INPM.mint,
                (
                    INPM.MintParams({
                        token0: TOKEN0,
                        token1: TOKEN1,
                        tickSpacing: TICK_SPACING,
                        tickLower: ctx.newLower,
                        tickUpper: ctx.newUpper,
                        amount0Desired: b0,
                        amount1Desired: b1,
                        amount0Min: a0Min,
                        amount1Min: a1Min,
                        recipient: SAFE,
                        deadline: deadline,
                        sqrtPriceX96: 0
                    })
                )
            )
        );
        (newTokenId,,,) = abi.decode(ret, (uint256, uint128, uint256, uint256));

        _safeApprove(TOKEN0, NPM, 0);
        _safeApprove(TOKEN1, NPM, 0);
    }

    function _enforcePostInvariants(RebalanceCtx memory ctx) internal view {
        // staked & in range
        if (!ICLGauge(GAUGE).stakedContains(SAFE, ctx.newTokenId)) revert NotStaked();
        (,,,,, int24 mintedLower, int24 mintedUpper, uint128 mintedLiquidity,,,,) = INPM(NPM).positions(ctx.newTokenId);
        if (mintedLiquidity == 0) revert InvalidParam();
        if (mintedLower != ctx.newLower || mintedUpper != ctx.newUpper) revert NotInRange();
        (, int24 finalTick,,,,) = ICLPool(POOL).slot0();
        if (!(finalTick >= mintedLower && finalTick < mintedUpper)) revert NotInRange();

        // no leftover approvals to router or NPM for either token
        if (
            IERC20Minimal(TOKEN0).allowance(SAFE, NPM) != 0 || IERC20Minimal(TOKEN1).allowance(SAFE, NPM) != 0
                || IERC20Minimal(TOKEN0).allowance(SAFE, SWAP_ROUTER) != 0
                || IERC20Minimal(TOKEN1).allowance(SAFE, SWAP_ROUTER) != 0
        ) revert StaleApproval();

        // Count both the freshly staked LP and any token dust left in the Safe.
        ctx.valueAfter = _valueAtNewRange(ctx, mintedLiquidity, _safeBalance(TOKEN0), _safeBalance(TOKEN1));
        uint256 floor = ctx.valueBefore * (BPS_DENOM - maxRebalanceLossBps) / BPS_DENOM;
        if (ctx.valueAfter < floor) revert ValueFloor();
    }

    function _withdrawAmountMin(RebalanceCtx memory ctx, bool amount0) internal view returns (uint256) {
        (uint256 expA0, uint256 expA1) = LiquidityAmounts.getAmountsForLiquidity(
            ctx.twapSqrtX96,
            TickMath.getSqrtRatioAtTick(ctx.oldLower),
            TickMath.getSqrtRatioAtTick(ctx.oldUpper),
            ctx.oldLiquidity
        );
        uint256 expected = amount0 ? expA0 : expA1;
        return expected * (BPS_DENOM - maxSlippageBps) / BPS_DENOM;
    }

    function _clampSqrtToRange(uint160 sqrtPriceX96, uint160 sqrtA, uint160 sqrtB) internal pure returns (uint160) {
        if (sqrtPriceX96 < sqrtA) return sqrtA;
        if (sqrtPriceX96 >= sqrtB) return sqrtB - 1;
        return sqrtPriceX96;
    }

    function _validateTwapWindow(ICLPool poolI, uint32 window) internal view {
        if (window == 0) revert InvalidParam();
        // Cardinality catches obviously uninitialized or single-observation pools; `consult`
        // below remains the authoritative check that the requested window has enough history.
        (,,, uint16 observationCardinality,,) = poolI.slot0();
        if (observationCardinality < 2) revert InvalidParam();
        OracleLibrary.consult(address(poolI), window);
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        bytes memory ret = _safeExec(token, abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (ret.length > 0 && !abi.decode(ret, (bool))) revert ExecFailed();
    }

    function _safeBalance(address token) internal view returns (uint256) {
        return IERC20Minimal(token).balanceOf(SAFE);
    }

    function isModuleEnabled() public view returns (bool enabled) {
        (bool ok, bytes memory ret) = SAFE.staticcall(abi.encodeCall(ISafe.isModuleEnabled, (address(this))));
        enabled = ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function _safeExec(address to, bytes memory data) internal returns (bytes memory ret) {
        if (!isModuleEnabled()) revert NotSafe();
        bool ok;
        (ok, ret) = ISafe(SAFE).execTransactionFromModuleReturnData(to, 0, data, ISafe.Operation.Call);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert SafeCallFailed();
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Preview                                    */
    /* -------------------------------------------------------------------------- */

    struct PreviewResult {
        bool canRebalance;
        bytes4 reason; // selector of the would-be revert; 0 if canRebalance == true
        int24 currentTick;
        int24 twapTick;
        int24 newLower;
        int24 newUpper;
        bool zeroForOne;
        uint256 amountIn;
        uint256 expectedAmountOut;
    }

    function previewRebalance() external view returns (PreviewResult memory r) {
        if (paused) {
            r.reason = IsPaused.selector;
            return r;
        }
        uint256 tid = currentTokenId;
        if (tid == 0) {
            r.reason = TokenIdUnset.selector;
            return r;
        }

        (uint160 sqrtPriceX96, int24 currentTick,,,,) = ICLPool(POOL).slot0();
        (,,,,, int24 oldLower, int24 oldUpper, uint128 oldL,,,,) = INPM(NPM).positions(tid);
        r.currentTick = currentTick;

        if (currentTick >= oldLower && currentTick < oldUpper) {
            r.reason = InRange.selector;
            return r;
        }

        r.twapTick = OracleLibrary.consult(POOL, twapWindow);
        int24 dev = currentTick > r.twapTick ? currentTick - r.twapTick : r.twapTick - currentTick;
        if (dev > maxTickDeviation) {
            r.reason = TwapDeviation.selector;
            return r;
        }

        int24 width = oldUpper - oldLower;
        r.newLower = _floorToSpacing(currentTick - width / 2);
        r.newUpper = r.newLower + width;
        if (currentTick >= r.newUpper) {
            r.newLower += TICK_SPACING;
            r.newUpper += TICK_SPACING;
        }
        if (!(currentTick >= r.newLower && currentTick < r.newUpper)) {
            r.reason = NotInRange.selector;
            return r;
        }

        uint160 sqrtA = TickMath.getSqrtRatioAtTick(r.newLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(r.newUpper);
        uint160 twapSqrtX96 = TickMath.getSqrtRatioAtTick(r.twapTick);
        RebalanceCtx memory ctx;
        ctx.sqrtPriceX96 = sqrtPriceX96;
        ctx.twapSqrtX96 = twapSqrtX96;
        ctx.newSqrtA = sqrtA;
        ctx.newSqrtB = sqrtB;

        uint256 b0 = IERC20Minimal(TOKEN0).balanceOf(SAFE);
        uint256 b1 = IERC20Minimal(TOKEN1).balanceOf(SAFE);
        // simulate post-withdraw balances by adding the position's amounts at TWAP
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            twapSqrtX96, TickMath.getSqrtRatioAtTick(oldLower), TickMath.getSqrtRatioAtTick(oldUpper), oldL
        );
        b0 += a0;
        b1 += a1;

        uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, b0, b1);
        uint256 sim0 = b0;
        uint256 sim1 = b1;
        if (L > 0) {
            (uint256 req0, uint256 req1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, L);
            if (b0 > req0) {
                r.zeroForOne = true;
                r.amountIn = (b0 - req0) / 2;
                r.expectedAmountOut = _token0ToToken1(r.amountIn, twapSqrtX96);
                sim0 -= r.amountIn;
                sim1 += r.expectedAmountOut;
            } else if (b1 > req1) {
                r.zeroForOne = false;
                r.amountIn = (b1 - req1) / 2;
                r.expectedAmountOut = _token1ToToken0(r.amountIn, twapSqrtX96);
                sim1 -= r.amountIn;
                sim0 += r.expectedAmountOut;
            }
        } else {
            (bool shouldSwap, bool zeroForOne, uint256 amountIn, uint256 expectedOut) = _zeroLiquiditySwap(ctx, b0, b1);
            if (shouldSwap) {
                r.zeroForOne = zeroForOne;
                r.amountIn = amountIn;
                r.expectedAmountOut = expectedOut;
                if (zeroForOne) {
                    sim0 -= amountIn;
                    sim1 += expectedOut;
                } else {
                    sim1 -= amountIn;
                    sim0 += expectedOut;
                }
            }
        }

        uint160 mintSqrtX96 = _clampSqrtToRange(sqrtPriceX96, sqrtA, sqrtB);
        if (LiquidityAmounts.getLiquidityForAmounts(mintSqrtX96, sqrtA, sqrtB, sim0, sim1) == 0) {
            r.reason = InvalidParam.selector;
            return r;
        }
        r.canRebalance = true;
    }
}
