// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma abicoder v2;

import "hardhat/console.sol";
import "./FlashSwapManager.sol";
import "./interfaces/Maker.sol";
import "./interfaces/DSProxy.sol";
import "./interfaces/IBorrowerOperations.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';


contract MakerETHMigrator {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    uint256 constant RAY = 10 ** 27;

    FlashSwapManager immutable flashSwapManager;
    IBorrowerOperations immutable borrowerOperations;
    address immutable lusd;

    constructor(FlashSwapManager _flashManager, address _lusd, IBorrowerOperations _borrowerOperations) {
        flashSwapManager = _flashManager;
        lusd = _lusd;
        borrowerOperations = _borrowerOperations;
    }

    function migrateVaultToTrove(address manager, address ethJoin, address daiJoin, uint cdp, address migrator, uint24 fee) external {
        (uint ethCollateral, uint daiDebt) = vaultContents(manager, cdp);

        // Save current proxy owner
        address proxyOwner = DSProxy(address(this)).owner();
        // Swap proxy owner so the FlashSwapManager can call it (necessary indirection as the callback only gets passed to msg.sender)
        DSProxy(address(this)).setOwner(address(flashSwapManager));

        flashSwapManager.startFlashSwap(FlashSwapManager.FlashParams({
            manager : manager,
            ethJoin : ethJoin,
            daiJoin : daiJoin,
            cdp : cdp,
            ethToMove : ethCollateral,
            proxy : address(this),
            migrator : migrator,
            daiAmount : daiDebt,
            fee: fee
        }));

        // Restore proxy owner
        DSProxy(address(this)).setOwner(proxyOwner);
    }

    function continueMigration(FlashSwapManager.FlashCallbackData memory data, uint256 lusdToRepay, address pool) external {
        // Pays maker debt and withdraw collateral
        wipeAllAndFreeETH(data);
        // Open Liquity trove
        borrowerOperations.openTrove{value : data.ethToMove}(uint(10000327844848179), lusdToRepay, address(this), address(this));
        // Complete swap
        TransferHelper.safeTransfer(lusd, pool, lusdToRepay);
    }

    function wipeAllAndFreeETH(FlashSwapManager.FlashCallbackData memory data) internal {
        address urn = ManagerLike(data.manager).urns(data.cdp);
        bytes32 ilk = ManagerLike(data.manager).ilks(data.cdp);
        (, uint art) = VatLike(ManagerLike(data.manager).vat()).urns(ilk, urn);

        // Approves adapter to take the DAI amount
        DaiJoinLike(data.daiJoin).dai().approve(data.daiJoin, data.daiAmount);
        // Joins DAI into the vat
        DaiJoinLike(data.daiJoin).join(urn, data.daiAmount);
        // Paybacks debt to the CDP and unlocks WETH amount from it
        ManagerLike(data.manager).frob(data.cdp, - toInt(data.ethToMove), - int(art));
        // Moves the amount from the CDP urn to proxy's address
        ManagerLike(data.manager).flux(data.cdp, address(this), data.ethToMove);
        // Exits WETH amount to proxy address as a token
        GemJoinLike(data.ethJoin).exit(address(this), data.ethToMove);
        // Converts WETH to ETH
        GemJoinLike(data.ethJoin).gem().withdraw(data.ethToMove);
    }

    function vaultContents(address manager, uint cdp) internal view returns (uint ethCollateral, uint daiDebt) {
        address vat = ManagerLike(manager).vat();
        address urn = ManagerLike(manager).urns(cdp);
        bytes32 ilk = ManagerLike(manager).ilks(cdp);
        
        // Gets actual rate from the vat
        (, uint rate,,,) = VatLike(vat).ilks(ilk);
        // Gets actual art value of the urn
        (uint _eth, uint art) = VatLike(vat).urns(ilk, urn);
        ethCollateral = _eth;
        // Gets actual daiDebt amount in the urn
        uint dai = VatLike(vat).dai(urn);

        uint rad =  art.mul(rate).sub(dai);
        daiDebt = rad / RAY;

        // If the rad precision has some dust, it will need to request for 1 extra wad wei
        daiDebt = daiDebt.mul(RAY) < rad ? daiDebt + 1 : daiDebt;
    }

    function toInt(uint x) internal pure returns (int y) {
        y = int(x);
        require(y >= 0, "int-overflow");
    }
}