// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "./UpgraderBase.sol";

contract FeeProviderUpgrader is UpgraderBase {
    constructor(address owner_) {
        transferOwnership(owner_);
    }

    /// @inheritdoc UpgraderBase
    function _calls() internal pure override returns (bytes[] memory callsList_) {
        callsList_ = new bytes[](6);
        callsList_[0] = abi.encodeWithSignature("depositFee()");
        callsList_[1] = abi.encodeWithSignature("issueFee()");
        callsList_[2] = abi.encodeWithSignature("withdrawFee()");
        callsList_[3] = abi.encodeWithSignature("repayFee()");
        callsList_[4] = abi.encodeWithSignature("liquidationFees()");
        callsList_[5] = abi.encodeWithSignature("defaultSwapFee()");
    }
}
