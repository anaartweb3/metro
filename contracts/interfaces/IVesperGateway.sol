// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "./IPool.sol";
import "./external/IVPool.sol";

interface IVesperGateway {
    function deposit(IPool pool_, IVPool vToken_, uint256 amount_) external;

    function withdraw(IPool pool_, IVPool vToken_, uint256 amount_) external;
}
