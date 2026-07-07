pragma solidity 0.8.9;

import "../dependencies/openzeppelin/utils/structs/EnumerableSet.sol";
import "../lib/MappedEnumerableSet.sol";
import "../interfaces/IPool.sol";
import "../interfaces/ISmartFarmingManager.sol";

abstract contract PoolStorageV1 is IPool {
    /**
     * @notice The debt floor (in USD) for each synthetic token. This parameters is used to keep incentive for liquidators (i.e. cover gas and provide enough profit)
     */
    uint256 public override debtFloorInUsd;

    uint256 private depositFee__DEPRECATED;

    uint256 private issueFee__DEPRECATED;

    uint256 private withdrawFee__DEPRECATED;

    uint256 private repayFee__DEPRECATED;

    uint256 private swapFee__DEPRECATED;

    uint256 private liquidationFees__DEPRECATED;

    /**
     * @notice The max percent of the debt allowed to liquidate. Use 18 decimals (e.g. 1e16 = 1%)
     */
    uint256 public override maxLiquidable;

    IPoolRegistry public override poolRegistry;

    bool public override isSwapActive;

    ITreasury public override treasury;

    EnumerableSet.AddressSet internal depositTokens;

    mapping(IERC20 => IDepositToken) public override depositTokenOf;

    EnumerableSet.AddressSet internal debtTokens;

    MappedEnumerableSet.AddressSet internal depositTokensOfAccount;

    MappedEnumerableSet.AddressSet internal debtTokensOfAccount;

    IRewardsDistributor[] internal rewardsDistributors__DEPRECATED;

    mapping(ISyntheticToken => IDebtToken) public override debtTokenOf;
}

abstract contract PoolStorageV2 is PoolStorageV1 {
    ISwapper private swapper__DEPRECATED;

    IFeeProvider public override feeProvider;

    EnumerableSet.AddressSet internal rewardsDistributors;
}

abstract contract PoolStorageV3 is PoolStorageV2 {

    ISmartFarmingManager public smartFarmingManager;
}

abstract contract PoolStorageV4 is PoolStorageV3 {

    bool public isBridgingActive;
}
