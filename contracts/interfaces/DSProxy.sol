pragma solidity ^0.7.6;

interface DSProxy {
    function execute(address _target, bytes memory _data) external payable returns (bytes memory response);
}

interface DSProxyFactory {
    event Created(address indexed sender, address indexed owner, address proxy, address cache);

    function build(address owner) external returns (DSProxy proxy);
}