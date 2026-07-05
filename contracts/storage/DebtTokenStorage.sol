pragma solidity 0.8.9;

import "../interfaces/IDebtToken.sol";

abstract contract DebtTokenStorageV1 is IDebtToken {

    string public override name;

    string public override symbol;

    /**
     * @notice The mapping of the users' minted tokens
     * @dev This value changes within the mint and burn operations
     */
    mapping(address => uint256) internal principalOf;

    /**
     * @notice The `debtIndex` "snapshot" of the account's latest `principalOf` update (i.e. mint/burn)
     */
    mapping(address => uint256) internal debtIndexOf;

    uint256 public override maxTotalSupply;

    uint256 internal totalSupply_;

    uint256 public override lastTimestampAccrued;

    uint256 public override debtIndex;

    /**
     * @dev Use 0.1e18 for 10% APR
     */
    uint256 public override interestRate;

    ISyntheticToken public override syntheticToken;

    /**
     * @notice If true, disables msAsset minting on this pool
     */
    bool public override isActive;

    uint8 public override decimals;
}

abstract contract DebtTokenStorageV2 is DebtTokenStorageV1 {

    uint256 public pendingInterestFee;
}
