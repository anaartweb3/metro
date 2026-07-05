// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "../../dependencies/@layerzerolabs/solidity-examples/interfaces/ILayerZeroEndpoint.sol";

interface IStargateBridge {
    function layerZeroEndpoint() external view returns (ILayerZeroEndpoint _lzEndpoint);
}
