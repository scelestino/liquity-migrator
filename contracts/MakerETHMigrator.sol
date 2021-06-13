pragma solidity ^0.7.6;
pragma abicoder v2;

import "hardhat/console.sol";
import "./UniswapFlashManager.sol";
import "./interfaces/Maker.sol";
import "./interfaces/DSProxy.sol";
import "./interfaces/IBorrowerOperations.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';


contract MakerETHMigrator {
    uint256 constant RAY = 10 ** 27;

    UniswapFlashManager public immutable flashManager;
    address immutable weth;
    address immutable dai;
    address immutable lusd;
    IBorrowerOperations immutable borrowerOperations;

    constructor(UniswapFlashManager _flashManager, address _weth, address _dai, address _lusd, IBorrowerOperations _borrowerOperations) {
        flashManager = _flashManager;
        weth = _weth;
        dai = _dai;
        lusd = _lusd;
        borrowerOperations = _borrowerOperations;
    }

    function useLoanToPay(address manager, address ethJoin, address daiJoin, uint cdp, uint wadC, int256 lusdToRepay, address pool) public {
        // Pays maker debt with the DAI hold by the proxy & transfers the locked WETH to the proxy
        wipeAllAndFreeETH(manager, ethJoin, daiJoin, cdp, wadC);
        // Converts WETH to ETH
        GemJoinLike(ethJoin).gem().withdraw(wadC);
        // Open Liquity trove
        borrowerOperations.openTrove{value : wadC}(uint(10000327844848179), uint(lusdToRepay), address(this), address(this));
        // Complete swap
        IERC20(lusd).transfer(pool, uint(lusdToRepay));
    }


    function payAllDebt(address manager, address ethJoin, address daiJoin, uint cdp, uint wadC, address migrator) external {
        address vat = ManagerLike(manager).vat();
        address urn = ManagerLike(manager).urns(cdp);
        bytes32 ilk = ManagerLike(manager).ilks(cdp);
        uint daiAmount = _getWipeAllWad(vat, urn, urn, ilk);

        DSProxy(address(this)).setOwner(address(flashManager));

        flashManager.initFlash(UniswapFlashManager.FlashParams({
        manager : manager,
        ethJoin : ethJoin,
        daiJoin : daiJoin,
        cdp : cdp,
        wadC : wadC,
        proxy : address(this),
        migrator : migrator,
        daiAmount : int256(daiAmount)
        }));

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