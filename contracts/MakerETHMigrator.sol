pragma solidity ^0.7.6;

import "./interfaces/Maker.sol";

contract MakerETHMigrator {

    function payDebt(address actions, address manager, address ethJoin, address daiJoin, uint cdp, uint wadC, uint wadD)
    public {
        DssProxyActions(actions).wipeAndFreeETH(manager, ethJoin, daiJoin, cdp, wadC, wadD);
    }

}