// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "../interfaces/ISyntheticToken.sol";
import "../interfaces/IProxyOFT.sol";

abstract contract ProxyOFTStorageV1 is IProxyOFT {
    /**
     * @notice The synthetic token contract
     */
    ISyntheticToken internal syntheticToken;
}
