// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma abicoder v2;

import "hardhat/console.sol";
import "./interfaces/DSProxy.sol";
import "./MakerETHMigrator.sol";
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';
import '@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import '@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol';
import '@uniswap/v3-periphery/contracts/base/PeripheryImmutableState.sol';
import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

contract FlashSwapManager is IUniswapV3SwapCallback, PeripheryImmutableState {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    address immutable dai;
    address immutable lusd;

    constructor(address _factory, address _weth, address _dai, address _lusd) PeripheryImmutableState(_factory, _weth) {
        dai = _dai;
        lusd = _lusd;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes calldata data) external override {
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        IUniswapV3Pool pool = CallbackValidation.verifyCallback(factory, decoded.poolKey);

        DSProxy(decoded.proxy).execute(
            decoded.migrator,
            abi.encodeWithSelector(
                MakerETHMigrator.continueMigration.selector, decoded, uint(amount0Delta), address(pool)
            )
        );
    }

    /// @param params The parameters necessary for flash and the callback, passed in as FlashParams
    /// @notice Calls the pools swap function with data needed in `uniswapV3SwapCallback`
    function startFlashSwap(FlashParams memory params) external {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0 : lusd, token1 : dai, fee : params.fee});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtPriceX96After = SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(sqrtPriceX96, pool.liquidity(), uint(params.daiAmount), false);

        pool.swap(
            params.proxy,
            true,
            - int(params.daiAmount),
            sqrtPriceX96After,
            abi.encode(
                FlashCallbackData({
                    poolKey : poolKey,
                    manager : params.manager,
                    ethJoin : params.ethJoin,
                    daiJoin : params.daiJoin,
                    cdp : params.cdp,
                    ethToMove : params.ethToMove,
                    proxy : params.proxy,
                    migrator : params.migrator,
                    daiAmount : params.daiAmount
                })
            )
        );
    }

    struct FlashCallbackData {
        PoolAddress.PoolKey poolKey;
        address manager;
        address ethJoin;
        address daiJoin;
        uint cdp;
        uint ethToMove;
        address proxy;
        address migrator;
        uint256 daiAmount;
    }

    struct FlashParams {
        address manager;
        address ethJoin;
        address daiJoin;
        uint cdp;
        uint ethToMove;
        address proxy;
        address migrator;
        uint256 daiAmount;
        uint24 fee;
    }
}