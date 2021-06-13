// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

interface DSProxy {
    function execute(address _target, bytes calldata _data) external payable returns (bytes memory response);

    function setOwner(address owner_) external;

    function owner() view external returns (address);
}

interface DSProxyFactory {
    event Created(address indexed sender, address indexed owner, address proxy, address cache);

    function build(address owner) external returns (DSProxy proxy);
}

interface ProxyRegistry {
    function proxies(address owner) external view returns (DSProxy proxy);
}