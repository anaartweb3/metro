pragma solidity 0.8.9;

import "../dependencies/openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import "../interfaces/IGovernable.sol";
import "../interfaces/IManageable.sol";

/**
 * @title Reusable contract that handles accesses
 */
abstract contract Manageable is IManageable, Initializable {
    IPool public pool;

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert SenderIsNotPool();
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor()) revert SenderIsNotGovernor();
        _;
    }

    modifier whenNotPaused() {
        if (pool.paused()) revert IsPaused();
        _;
    }

    modifier whenNotShutdown() {
        if (pool.everythingStopped()) revert IsShutdown();
        _;
    }

    function __Manageable_init(IPool pool_) internal onlyInitializing {
        if (address(pool_) == address(0)) revert PoolAddressIsNull();
        pool = pool_;
    }

    function governor() public view returns (address _governor) {
        _governor = IGovernable(address(pool)).governor();
    }

    uint256[49] private __gap;
}
