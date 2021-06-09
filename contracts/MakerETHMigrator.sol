pragma solidity =0.6.6;

import "hardhat/console.sol";
import "./interfaces/Maker.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/DSProxy.sol";
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-periphery/contracts/libraries/UniswapV2Library.sol';

contract MakerETHMigrator is IUniswapV2Callee {
    uint256 constant RAY = 10 ** 27;
    IUniswapV2Factory immutable factory;
    address immutable weth;
    address immutable dai;
    uint constant deadline = 10 days;

    constructor(address _factory, address _weth, address _dai) public {
        factory = IUniswapV2Factory(_factory);
        weth = _weth;
        dai = _dai;
    }

    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) override external {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        require(msg.sender == factory.getPair(token0, token1), "Unauthorized");

        (address manager, address ethJoin, address daiJoin, uint cdp, uint wadC)
        = abi.decode(data, (address, address, address, uint, uint));

        IERC20(token0).transfer(sender, amount0);

        DSProxy(sender).execute(
            address(this),
            abi.encodeWithSignature(
                "useLoanToPay(address,address,address,uint256,uint256)", manager, ethJoin, daiJoin, cdp, wadC
            )
        );
    }

    function useLoanToPay(address manager, address ethJoin, address daiJoin, uint cdp, uint wadC) public {

        uint borrowedAmount = IERC20(dai).balanceOf(address(this));

        wipeAllAndFreeETH(manager, ethJoin, daiJoin, cdp, wadC);


        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = dai;


        uint amountToRepay = UniswapV2Library.getAmountsIn(address(factory), borrowedAmount, path)[0];

        GemJoinLike(ethJoin).gem().transfer(factory.getPair(dai, weth), amountToRepay);
    }

    function payAllDebt(address manager, address ethJoin, address daiJoin, uint cdp, uint wadC, address self)
    public {
        address vat = ManagerLike(manager).vat();
        address urn = ManagerLike(manager).urns(cdp);
        bytes32 ilk = ManagerLike(manager).ilks(cdp);
        uint daiAmount = _getWipeAllWad(vat, urn, urn, ilk);


        bytes memory cd = abi.encode(manager, ethJoin, daiJoin, cdp, wadC);

        DSProxy(address(this)).setOwner(self);

        IUniswapV2Pair(factory.getPair(dai, weth)).swap(daiAmount, 0, self, cd);

        uint remainingWETH = IERC20(weth).balanceOf(address(this));

        // Converts WETH to ETH
        GemJoinLike(ethJoin).gem().withdraw(remainingWETH);
        // Sends ETH back to the user's wallet
        msg.sender.transfer(remainingWETH);

        DSProxy(address(this)).setOwner(tx.origin);
    }

    function wipeAllAndFreeETH(address manager, address ethJoin, address daiJoin, uint cdp, uint wadC) internal {
        address vat = ManagerLike(manager).vat();
        address urn = ManagerLike(manager).urns(cdp);
        bytes32 ilk = ManagerLike(manager).ilks(cdp);
        (, uint art) = VatLike(vat).urns(ilk, urn);

        // Joins DAI amount into the vat
        daiJoin_join(daiJoin, urn, _getWipeAllWad(vat, urn, urn, ilk));
        // Paybacks debt to the CDP and unlocks WETH amount from it
        ManagerLike(manager).frob(cdp, - toInt(wadC), - int(art));
        // Moves the amount from the CDP urn to proxy's address
        ManagerLike(manager).flux(cdp, address(this), wadC);
        // Exits WETH amount to proxy address as a token
        GemJoinLike(ethJoin).exit(address(this), wadC);
    }

    function _getWipeAllWad(address vat, address usr, address urn, bytes32 ilk) internal view returns (uint wad) {
        // Gets actual rate from the vat
        (, uint rate,,,) = VatLike(vat).ilks(ilk);
        // Gets actual art value of the urn
        (, uint art) = VatLike(vat).urns(ilk, urn);
        // Gets actual dai amount in the urn
        uint daiAmount = VatLike(vat).dai(usr);

        uint rad = sub(mul(art, rate), daiAmount);
        wad = rad / RAY;

        // If the rad precision has some dust, it will need to request for 1 extra wad wei
        wad = mul(wad, RAY) < rad ? wad + 1 : wad;
    }

    function daiJoin_join(address apt, address urn, uint wad) internal {
        // Approves adapter to take the DAI amount
        DaiJoinLike(apt).dai().approve(apt, wad);
        // Joins DAI into the vat
        DaiJoinLike(apt).join(urn, wad);
    }

    function toInt(uint x) internal pure returns (int y) {
        y = int(x);
        require(y >= 0, "int-overflow");
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, "mul-overflow");
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, "sub-overflow");
    }
}