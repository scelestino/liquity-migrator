pragma solidity ^0.7.6;
pragma abicoder v2;

import "hardhat/console.sol";
import "./interfaces/DSProxy.sol";
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';
import '@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import '@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol';
import '@uniswap/v3-periphery/contracts/base/PeripheryPayments.sol';
import '@uniswap/v3-periphery/contracts/base/PeripheryImmutableState.sol';
import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

contract UniswapFlashManager is IUniswapV3SwapCallback, PeripheryImmutableState, PeripheryPayments {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    ISwapRouter public immutable swapRouter;
    address immutable weth;
    address immutable dai;
    address immutable lusd;
    uint24 immutable fee;

    constructor(ISwapRouter _swapRouter, address _factory, address _weth, address _dai, address _lusd, uint24 _fee)
    PeripheryImmutableState(_factory, _weth) {
        swapRouter = _swapRouter;
        weth = _weth;
        dai = _dai;
        lusd = _lusd;
        fee = _fee;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        IUniswapV3Pool pool = CallbackValidation.verifyCallback(factory, decoded.poolKey);

        DSProxy(decoded.proxy).execute(
            decoded.migrator,
            abi.encodeWithSignature(
                "useLoanToPay(address,address,address,uint256,uint256,int256,address)", decoded.manager, decoded.ethJoin, decoded.daiJoin, decoded.cdp, decoded.wadC, amount0Delta, address(pool)
            )
        );
    }

    /// @param params The parameters necessary for flash and the callback, passed in as FlashParams
    /// @notice Calls the pools flash function with data needed in `uniswapV3FlashCallback`
    function initFlash(FlashParams memory params) external {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0 : lusd, token1 : dai, fee : fee});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtPriceX96After = SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(sqrtPriceX96, pool.liquidity(), uint(params.daiAmount), false);

        bytes memory cd = abi.encode(FlashCallbackData({
        poolKey : poolKey,
        manager : params.manager,
        ethJoin : params.ethJoin,
        daiJoin : params.daiJoin,
        cdp : params.cdp,
        wadC : params.wadC,
        proxy : params.proxy,
        migrator : params.migrator,
        daiAmount : params.daiAmount
        }));

        pool.swap(msg.sender, true, - params.daiAmount, sqrtPriceX96After, cd);
    }

    struct FlashCallbackData {
        PoolAddress.PoolKey poolKey;
        address manager;
        address ethJoin;
        address daiJoin;
        uint cdp;
        uint wadC;
        address proxy;
        address migrator;
        int256 daiAmount;
    }

    struct FlashParams {
        address manager;
        address ethJoin;
        address daiJoin;
        uint cdp;
        uint wadC;
        address proxy;
        address migrator;
        int256 daiAmount;
    }
}