pragma solidity >=0.5.0;

interface DssProxyActions {
    function openLockETHAndDraw(address manager, address jug, address ethJoin, address daiJoin, bytes32 ilk, uint wadD)
    external payable returns (uint cdp);

    function wipeAndFreeETH(address manager, address ethJoin, address daiJoin, uint cdp, uint wadC, uint wadD) external;
}

interface GemLike {
    function approve(address, uint) external;

    function transfer(address, uint) external;

    function transferFrom(address, address, uint) external;

    function deposit() external payable;

    function withdraw(uint) external;
}

interface DaiJoinLike {
    function vat() external returns (VatLike);

    function dai() external returns (GemLike);

    function join(address, uint) external payable;

    function exit(address, uint) external;
}

interface VatLike {
    function can(address, address) external view returns (uint);

    function ilks(bytes32) external view returns (uint, uint, uint, uint, uint);

    function dai(address) external view returns (uint);

    function urns(bytes32, address) external view returns (uint, uint);

    function frob(bytes32, address, address, address, int, int) external;

    function hope(address) external;

    function move(address, address, uint) external;
}

interface GemJoinLike {
    function dec() external returns (uint);

    function gem() external returns (GemLike);

    function join(address, uint) external payable;

    function exit(address, uint) external;
}

interface ManagerLike {
    function cdpCan(address, uint, address) external view returns (uint);

    function ilks(uint) external view returns (bytes32);

    function owns(uint) external view returns (address);

    function last(address) external view returns (uint);

    function urns(uint) external view returns (address);

    function vat() external view returns (address);

    function open(bytes32, address) external returns (uint);

    function give(uint, address) external;

    function cdpAllow(uint, address, uint) external;

    function urnAllow(address, uint) external;

    function frob(uint, int, int) external;

    function flux(uint, address, uint) external;

    function move(uint, address, uint) external;

    function exit(address, uint, address, uint) external;

    function quit(uint, address) external;

    function enter(address, uint) external;

    function shift(uint, uint) external;
}