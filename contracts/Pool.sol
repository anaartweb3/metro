pragma solidity 0.8.9;

import "./utils/ReentrancyGuard.sol";
import "./storage/PoolStorage.sol";
import "./lib/WadRayMath.sol";
import "./utils/Pauseable.sol";

contract Pool is ReentrancyGuard, Pauseable, PoolStorageV4 {
    using SafeERC20 for IERC20;
    using SafeERC20 for ISyntheticToken;
    using WadRayMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MappedEnumerableSet for MappedEnumerableSet.AddressSet;

    uint256 public constant MAX_TOKENS_PER_USER = 30;

    modifier onlyIfAdditionWillNotReachMaxTokens(address account_) {
        if (debtTokensOfAccount.length(account_) + depositTokensOfAccount.length(account_) >= MAX_TOKENS_PER_USER) {
            revert UserReachedMaxTokens();
        }
        _;
    }

    modifier onlyIfDepositTokenExists(IDepositToken depositToken_) {
        if (!doesDepositTokenExist(depositToken_)) revert DepositTokenDoesNotExist();
        _;
    }

    modifier onlyIfSyntheticTokenExists(ISyntheticToken syntheticToken_) {
        if (!doesSyntheticTokenExist(syntheticToken_)) revert SyntheticDoesNotExist();
        _;
    }

    modifier onlyIfMsgSenderIsDebtToken() {
        if (!doesDebtTokenExist(IDebtToken(msg.sender))) revert SenderIsNotDebtToken();
        _;
    }

    modifier onlyIfMsgSenderIsDepositToken() {
        if (!doesDepositTokenExist(IDepositToken(msg.sender))) revert SenderIsNotDepositToken();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(IPoolRegistry poolRegistry_) public initializer {
        if (address(poolRegistry_) == address(0)) revert PoolRegistryIsNull();
        __ReentrancyGuard_init();
        __Pauseable_init();
        poolRegistry = poolRegistry_;
        isSwapActive = true;
        maxLiquidable = 0.5e18; // 50%
    }

    function addToDebtTokensOfAccount(address account_) external onlyIfMsgSenderIsDebtToken onlyIfAdditionWillNotReachMaxTokens(account_) {
        if (!debtTokensOfAccount.add(account_, msg.sender)) revert DebtTokenAlreadyExists();
    }

    function addToDepositTokensOfAccount(address account_) external onlyIfMsgSenderIsDepositToken onlyIfAdditionWillNotReachMaxTokens(account_) {
        if (!depositTokensOfAccount.add(account_, msg.sender)) revert DepositTokenAlreadyExists();
    }

    function debtOf(address account_) public view override returns (uint256 _debtInUsd) {
        IMasterOracle _masterOracle = masterOracle();
        uint256 _length = debtTokensOfAccount.length(account_);
        for (uint256 i; i < _length; ++i) {
            IDebtToken _debtToken = IDebtToken(debtTokensOfAccount.at(account_, i));
            _debtInUsd += _masterOracle.quoteTokenToUsd(address(_debtToken.syntheticToken()), _debtToken.balanceOf(account_));
        }
    }

    function debtPositionOf(address account_) public view override returns (bool _isHealthy, uint256 _depositInUsd, uint256 _debtInUsd, uint256 _issuableLimitInUsd, uint256 _issuableInUsd) {
        _debtInUsd = debtOf(account_);
        (_depositInUsd, _issuableLimitInUsd) = depositOf(account_);
        _isHealthy = _debtInUsd <= _issuableLimitInUsd;
        _issuableInUsd = _debtInUsd < _issuableLimitInUsd ? _issuableLimitInUsd - _debtInUsd : 0;
    }

    function depositOf(address account_) public view override returns (uint256 _depositInUsd, uint256 _issuableLimitInUsd) {
        IMasterOracle _masterOracle = masterOracle();
        uint256 _length = depositTokensOfAccount.length(account_);
        for (uint256 i; i < _length; ++i) {
            IDepositToken _depositToken = IDepositToken(depositTokensOfAccount.at(account_, i));
            uint256 _amountInUsd = _masterOracle.quoteTokenToUsd(address(_depositToken.underlying()), _depositToken.balanceOf(account_));
            _depositInUsd += _amountInUsd;
            _issuableLimitInUsd += _amountInUsd.wadMul(_depositToken.collateralFactor());
        }
    }

    function everythingStopped() public view override(IPauseable, Pauseable) returns (bool) {
        return super.everythingStopped() || poolRegistry.everythingStopped();
    }

    function feeCollector() external view override returns (address) {
        return poolRegistry.feeCollector();
    }

    /**
     * @dev WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed to mostly be used by view accessors that are queried without any gas fees.
     */
    function getDebtTokens() external view override returns (address[] memory) {
        return debtTokens.values();
    }

    /**
     * @dev WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed to mostly be used by view accessors that are queried without any gas fees.
     */
    function getDebtTokensOfAccount(address account_) external view override returns (address[] memory) {
        return debtTokensOfAccount.values(account_);
    }

    /**
     * @dev WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed to mostly be used by view accessors that are queried without any gas fees.
     */
    function getDepositTokens() external view override returns (address[] memory) {
        return depositTokens.values();
    }

    /**
     * @dev WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed to mostly be used by view accessors that are queried without any gas fees.
     */
    function getDepositTokensOfAccount(address account_) external view override returns (address[] memory) {
        return depositTokensOfAccount.values(account_);
    }

    function getRewardsDistributors() external view override returns (address[] memory) {
        return rewardsDistributors.values();
    }

    function doesDebtTokenExist(IDebtToken debtToken_) public view override returns (bool) {
        return debtTokens.contains(address(debtToken_));
    }

    function doesDepositTokenExist(IDepositToken depositToken_) public view override returns (bool) {
        return depositTokens.contains(address(depositToken_));
    }

    function doesSyntheticTokenExist(ISyntheticToken syntheticToken_) public view override returns (bool) {
        return address(debtTokenOf[syntheticToken_]) != address(0);
    }

    function quoteLiquidateIn(ISyntheticToken syntheticToken_, uint256 totalToSeize_, IDepositToken depositToken_) public view override returns (uint256 _amountToRepay, uint256 _toLiquidator, uint256 _fee) {
        (uint128 _liquidatorIncentive, uint128 _protocolFee) = feeProvider.liquidationFees();
        uint256 _totalFees = _protocolFee + _liquidatorIncentive;
        uint256 _repayAmountInCollateral = totalToSeize_;
        if (_totalFees > 0) {
            _repayAmountInCollateral = _repayAmountInCollateral.wadDiv(1e18 + _totalFees);
        }
        _amountToRepay = masterOracle().quote(address(depositToken_.underlying()), address(syntheticToken_), _repayAmountInCollateral);
        if (_protocolFee > 0) {
            _fee = _repayAmountInCollateral.wadMul(_protocolFee);
        }
        if (_liquidatorIncentive > 0) {
            _toLiquidator = _repayAmountInCollateral.wadMul(1e18 + _liquidatorIncentive);
        }
    }

    function quoteLiquidateMax(ISyntheticToken syntheticToken_, address account_, IDepositToken depositToken_) external view override returns (uint256 _maxAmountToRepay) {
        (bool _isHealthy, , , , ) = debtPositionOf(account_);
        if (_isHealthy) {
            return 0;
        }
        (uint256 _amountToRepay, , ) = quoteLiquidateIn(syntheticToken_, depositToken_.balanceOf(account_), depositToken_);
        _maxAmountToRepay = debtTokenOf[syntheticToken_].balanceOf(account_).wadMul(maxLiquidable);
        if (_amountToRepay < _maxAmountToRepay) {
            _maxAmountToRepay = _amountToRepay;
        }
    }

    function quoteLiquidateOut(ISyntheticToken syntheticToken_, uint256 amountToRepay_, IDepositToken depositToken_) public view override returns (uint256 _totalToSeize, uint256 _toLiquidator, uint256 _fee) {
        _toLiquidator = masterOracle().quote(address(syntheticToken_), address(depositToken_.underlying()), amountToRepay_);
        (uint128 _liquidatorIncentive, uint128 _protocolFee) = feeProvider.liquidationFees();
        if (_protocolFee > 0) {
            _fee = _toLiquidator.wadMul(_protocolFee);
        }
        if (_liquidatorIncentive > 0) {
            _toLiquidator += _toLiquidator.wadMul(_liquidatorIncentive);
        }
        _totalToSeize = _fee + _toLiquidator;
    }

    function quoteSwapIn(ISyntheticToken syntheticTokenIn_, ISyntheticToken syntheticTokenOut_, uint256 amountOut_) external view override returns (uint256 _amountIn, uint256 _fee) {
        uint256 _swapFee = feeProvider.swapFeeFor(msg.sender);
        if (_swapFee > 0) {
            amountOut_ = amountOut_.wadDiv(1e18 - _swapFee);
            _fee = amountOut_.wadMul(_swapFee);
        }
        _amountIn = poolRegistry.masterOracle().quote(address(syntheticTokenOut_), address(syntheticTokenIn_), amountOut_);
    }

    function quoteSwapOut(ISyntheticToken syntheticTokenIn_, ISyntheticToken syntheticTokenOut_, uint256 amountIn_) public view override returns (uint256 _amountOut, uint256 _fee) {
        _amountOut = poolRegistry.masterOracle().quote(address(syntheticTokenIn_), address(syntheticTokenOut_), amountIn_);
        uint256 _swapFee = feeProvider.swapFeeFor(msg.sender);
        if (_swapFee > 0) {
            _fee = _amountOut.wadMul(_swapFee);
            _amountOut -= _fee;
        }
    }

    function liquidate(ISyntheticToken syntheticToken_, address account_, uint256 amountToRepay_, IDepositToken depositToken_) external override whenNotShutdown nonReentrant onlyIfSyntheticTokenExists(syntheticToken_) onlyIfDepositTokenExists(depositToken_) returns (uint256 _totalSeized, uint256 _toLiquidator, uint256 _fee){
        if (amountToRepay_ == 0) revert AmountIsZero();
        if (msg.sender == account_) revert CanNotLiquidateOwnPosition();
        IDebtToken _debtToken = debtTokenOf[syntheticToken_];
        _debtToken.accrueInterest();
        (bool _isHealthy, , , , ) = debtPositionOf(account_);
        if (_isHealthy) {
            revert PositionIsHealthy();
        }
        uint256 _debtTokenBalance = _debtToken.balanceOf(account_);
        if (amountToRepay_.wadDiv(_debtTokenBalance) > maxLiquidable) {
            revert AmountGreaterThanMaxLiquidable();
        }
        IMasterOracle _masterOracle = masterOracle();
        if (debtFloorInUsd > 0) {
            uint256 _newDebtInUsd = _masterOracle.quoteTokenToUsd(address(syntheticToken_), _debtTokenBalance - amountToRepay_
            );
            if (_newDebtInUsd > 0 && _newDebtInUsd < debtFloorInUsd) {
                revert RemainingDebtIsLowerThanTheFloor();
            }
        }
        (_totalSeized, _toLiquidator, _fee) = quoteLiquidateOut(syntheticToken_, amountToRepay_, depositToken_);
        if (_totalSeized > depositToken_.balanceOf(account_)) {
            revert AmountIsTooHigh();
        }
        syntheticToken_.burn(msg.sender, amountToRepay_);
        _debtToken.burn(account_, amountToRepay_);
        depositToken_.seize(account_, msg.sender, _toLiquidator);
        if (_fee > 0) {
            depositToken_.seize(account_, poolRegistry.feeCollector(), _fee);
        }
    }

    function masterOracle() public view override returns (IMasterOracle) {
        return poolRegistry.masterOracle();
    }

    function paused() public view override(IPauseable, Pauseable) returns (bool) {
        return super.paused() || poolRegistry.paused();
    }

    function removeFromDebtTokensOfAccount(address account_) external onlyIfMsgSenderIsDebtToken {
        if (!debtTokensOfAccount.remove(account_, msg.sender)) revert DebtTokenDoesNotExist();
    }

    function removeFromDepositTokensOfAccount(address account_) external onlyIfMsgSenderIsDepositToken {
        if (!depositTokensOfAccount.remove(account_, msg.sender)) revert DepositTokenDoesNotExist();
    }

    function swap(ISyntheticToken syntheticTokenIn_, ISyntheticToken syntheticTokenOut_, uint256 amountIn_) external override whenNotShutdown nonReentrant onlyIfSyntheticTokenExists(syntheticTokenIn_) onlyIfSyntheticTokenExists(syntheticTokenOut_) returns (uint256 _amountOut, uint256 _fee){
        if (!isSwapActive) revert SwapFeatureIsInactive();
        if (amountIn_ == 0 || amountIn_ > syntheticTokenIn_.balanceOf(msg.sender)) revert AmountInIsInvalid();
        syntheticTokenIn_.burn(msg.sender, amountIn_);
        (_amountOut, _fee) = quoteSwapOut(syntheticTokenIn_, syntheticTokenOut_, amountIn_);
        if (_fee > 0) {
            syntheticTokenOut_.mint(poolRegistry.feeCollector(), _fee);
        }
        syntheticTokenOut_.mint(msg.sender, _amountOut);
    }

    function addDebtToken(IDebtToken debtToken_) external onlyGovernor {
        if (address(debtToken_) == address(0)) revert AddressIsNull();
        ISyntheticToken _syntheticToken = debtToken_.syntheticToken();
        if (address(_syntheticToken) == address(0)) revert SyntheticIsNull();
        if (address(debtTokenOf[_syntheticToken]) != address(0)) revert SyntheticIsInUse();
        if (!debtTokens.add(address(debtToken_))) revert DebtTokenAlreadyExists();
        debtTokenOf[_syntheticToken] = debtToken_;
    }

    function addDepositToken(address depositToken_) external onlyGovernor {
        if (depositToken_ == address(0)) revert AddressIsNull();
        IERC20 _underlying = IDepositToken(depositToken_).underlying();
        if (address(depositTokenOf[_underlying]) != address(0)) revert UnderlyingAssetInUse();
        // Note: Fee collector collects deposit tokens as fee
        if (depositTokens.length() >= MAX_TOKENS_PER_USER) revert ReachedMaxDepositTokens();
        if (!depositTokens.add(depositToken_)) revert DepositTokenAlreadyExists();
        depositTokenOf[_underlying] = IDepositToken(depositToken_);
    }

    function addRewardsDistributor(IRewardsDistributor distributor_) external onlyGovernor {
        if (address(distributor_) == address(0)) revert AddressIsNull();
        if (!rewardsDistributors.add(address(distributor_))) revert RewardDistributorAlreadyExists();
    }

    function removeDebtToken(IDebtToken debtToken_) external onlyGovernor {
        if (debtToken_.totalSupply() > 0) revert TotalSupplyIsNotZero();
        if (!debtTokens.remove(address(debtToken_))) revert DebtTokenDoesNotExist();
        delete debtTokenOf[debtToken_.syntheticToken()];
    }

    function removeDepositToken(IDepositToken depositToken_) external onlyGovernor {
        if (depositToken_.totalSupply() > 0) revert TotalSupplyIsNotZero();
        if (!depositTokens.remove(address(depositToken_))) revert DepositTokenDoesNotExist();
        delete depositTokenOf[depositToken_.underlying()];
    }

    function removeRewardsDistributor(IRewardsDistributor distributor_) external onlyGovernor {
        if (address(distributor_) == address(0)) revert AddressIsNull();
        if (!rewardsDistributors.remove(address(distributor_))) revert RewardDistributorDoesNotExist();
    }

    function toggleIsSwapActive() external onlyGovernor {
        bool _newIsSwapActive = !isSwapActive;
        isSwapActive = _newIsSwapActive;
    }

    function updateDebtFloor(uint256 newDebtFloorInUsd_) external onlyGovernor {
        uint256 _currentDebtFloorInUsd = debtFloorInUsd;
        if (newDebtFloorInUsd_ == _currentDebtFloorInUsd) revert NewValueIsSameAsCurrent();
        debtFloorInUsd = newDebtFloorInUsd_;
    }

    function updateMaxLiquidable(uint256 newMaxLiquidable_) external onlyGovernor {
        if (newMaxLiquidable_ > 1e18) revert MaxLiquidableTooHigh();
        uint256 _currentMaxLiquidable = maxLiquidable;
        if (newMaxLiquidable_ == _currentMaxLiquidable) revert NewValueIsSameAsCurrent();
        maxLiquidable = newMaxLiquidable_;
    }

    function updateTreasury(ITreasury newTreasury_) external onlyGovernor {
        if (address(newTreasury_) == address(0)) revert AddressIsNull();
        ITreasury _currentTreasury = treasury;
        if (newTreasury_ == _currentTreasury) revert NewValueIsSameAsCurrent();
        if (address(_currentTreasury) != address(0)) {
            _currentTreasury.migrateTo(address(newTreasury_));
        }
        treasury = newTreasury_;
    }

    function updateFeeProvider(IFeeProvider feeProvider_) external onlyGovernor {
        if (address(feeProvider_) == address(0)) revert AddressIsNull();
        IFeeProvider _current = feeProvider;
        if (feeProvider_ == _current) revert NewValueIsSameAsCurrent();
        feeProvider = feeProvider_;
    }

    function updateSmartFarmingManager(ISmartFarmingManager newSmartFarmingManager_) external onlyGovernor {
        if (address(newSmartFarmingManager_) == address(0)) revert AddressIsNull();
        ISmartFarmingManager _current = smartFarmingManager;
        if (newSmartFarmingManager_ == _current) revert NewValueIsSameAsCurrent();
        smartFarmingManager = newSmartFarmingManager_;
    }

    function toggleBridgingIsActive() external onlyGovernor {
        bool _newIsBridgingActive = !isBridgingActive;
        isBridgingActive = _newIsBridgingActive;
    }
}
