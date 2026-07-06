pragma solidity 0.8.9;

import "./utils/ReentrancyGuard.sol";
import "./dependencies/openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "./dependencies/openzeppelin/utils/math/Math.sol";
import "./interfaces/external/IStargateComposerWithRetry.sol";
import "./access/Manageable.sol";
import "./storage/SmartFarmingManagerStorage.sol";
import "./lib/WadRayMath.sol";
import "./lib/CrossChainLib.sol";

// Note: The `IPoolRegistry` wasn't updated to avoid changing interface Refs: https://github.com/autonomoussoftware/metronome-synth/issues/877
interface IPoolRegistryV3 is IPoolRegistry {
    function isCrossChainFlashRepayActive() external view returns (bool);
}

contract SmartFarmingManager is ReentrancyGuard, Manageable, SmartFarmingManagerStorageV1 {
    using SafeERC20 for IERC20;
    using SafeERC20 for ISyntheticToken;
    using WadRayMath for uint256;

    modifier onlyIfCrossChainDispatcher() {
        if (msg.sender != address(crossChainDispatcher())) revert SenderIsNotCrossChainDispatcher();
        _;
    }

    modifier onlyIfDepositTokenExists(IDepositToken depositToken_) {
        if (!pool.doesDepositTokenExist(depositToken_)) revert DepositTokenDoesNotExist();
        _;
    }

    modifier onlyIfSyntheticTokenExists(ISyntheticToken syntheticToken_) {
        if (!pool.doesSyntheticTokenExist(syntheticToken_)) revert SyntheticDoesNotExist();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(IPool pool_) public initializer {
        if (address(pool_) == address(0)) revert PoolIsNull();
        __ReentrancyGuard_init();
        __Manageable_init(pool_);
    }

    function crossChainDispatcher() public view returns (ICrossChainDispatcher _crossChainDispatcher) {
        return pool.poolRegistry().crossChainDispatcher();
    }

    function crossChainFlashRepay(ISyntheticToken syntheticToken_, IDepositToken depositToken_, uint256 withdrawAmount_, IERC20 bridgeToken_, uint256 bridgeTokenAmountMin_, uint256 swapAmountOutMin_, uint256 repayAmountMin_, bytes calldata lzArgs_) external payable override nonReentrant onlyIfDepositTokenExists(depositToken_) onlyIfSyntheticTokenExists(syntheticToken_) {
        if (withdrawAmount_ == 0) revert AmountIsZero();
        if (!IPoolRegistryV3(address(pool.poolRegistry())).isCrossChainFlashRepayActive())
            revert CrossChainFlashRepayInactive();
        ICrossChainDispatcher _crossChainDispatcher;
        {
            IDebtToken _debtToken = pool.debtTokenOf(syntheticToken_);
            _debtToken.accrueInterest();
            if (repayAmountMin_ > _debtToken.balanceOf(msg.sender)) revert AmountIsTooHigh();
            _crossChainDispatcher = crossChainDispatcher();
        }
        uint256 _amountIn;
        {
            // 1. withdraw collateral
            // Note: No need to check healthy because this function ensures withdrawing only from unlocked balance
            (_amountIn, ) = depositToken_.withdrawFrom(msg.sender, withdrawAmount_);
            // 2. swap collateral for bridge token
            _amountIn = _swap({swapper_: swapper(), tokenIn_: _collateralOf(depositToken_), tokenOut_: bridgeToken_, amountIn_: _amountIn, amountOutMin_: bridgeTokenAmountMin_, to_: address(_crossChainDispatcher)});
        }
        // 3. store request and trigger swap
        _triggerFlashRepaySwap({crossChainDispatcher_: _crossChainDispatcher, swapTokenIn_: bridgeToken_, swapTokenOut_: syntheticToken_, swapAmountIn_: _amountIn, swapAmountOutMin_: swapAmountOutMin_, repayAmountMin_: repayAmountMin_, lzArgs_: lzArgs_});
    }

    function _triggerFlashRepaySwap(ICrossChainDispatcher crossChainDispatcher_, IERC20 swapTokenIn_, ISyntheticToken swapTokenOut_, uint256 swapAmountIn_, uint256 swapAmountOutMin_, uint256 repayAmountMin_, bytes calldata lzArgs_) private {
        uint256 _id = _nextCrossChainRequestId();
        (uint16 _dstChainId, , ) = CrossChainLib.decodeLzArgs(lzArgs_);
        crossChainFlashRepays[_id] = CrossChainFlashRepay({dstChainId: _dstChainId, syntheticToken: swapTokenOut_, repayAmountMin: repayAmountMin_, account: msg.sender, finished: false});
        crossChainDispatcher_.triggerFlashRepaySwap{value: msg.value}({id_: _id, account_: payable(msg.sender), tokenIn_: address(swapTokenIn_), tokenOut_: address(swapTokenOut_), amountIn_: swapAmountIn_, amountOutMin_: swapAmountOutMin_, lzArgs_: lzArgs_});
    }

    function crossChainFlashRepayCallback(uint256 id_, uint256 swapAmountOut_) external override whenNotShutdown nonReentrant onlyIfCrossChainDispatcher returns (uint256 _repaid) {
        CrossChainFlashRepay memory _request = crossChainFlashRepays[id_];
        if (_request.account == address(0)) revert CrossChainRequestInvalidKey();
        if (_request.finished) revert CrossChainRequestCompletedAlready();
        crossChainFlashRepays[id_].finished = true;
        swapAmountOut_ = _safeTransferFrom(_request.syntheticToken, msg.sender, swapAmountOut_);
        IDebtToken _debtToken = pool.debtTokenOf(_request.syntheticToken);
        (uint256 _maxRepayAmount, ) = _debtToken.quoteRepayIn(_debtToken.balanceOf(_request.account));
        uint256 _repayAmount = Math.min(swapAmountOut_, _maxRepayAmount);
        if (_repayAmount > 0) (_repaid, ) = _debtToken.repay(_request.account, _repayAmount);
        if (_repaid < _request.repayAmountMin) revert FlashRepaySlippageTooHigh();
        if (swapAmountOut_ > _repayAmount) {
            _request.syntheticToken.safeTransfer(_request.account, swapAmountOut_ - _repayAmount);
        }
    }

    // @dev Keep this function to avoid changing interface Refs: https://github.com/autonomoussoftware/metronome-synth/issues/877
    function crossChainLeverage(IERC20, IDepositToken, ISyntheticToken, uint256, uint256, uint256, uint256, bytes calldata) external payable override {
        revert("deprecated");
    }

    function crossChainLeverage(IERC20 tokenIn_, ISyntheticToken syntheticToken_, IERC20 bridgeToken_, IDepositToken depositToken_, uint256 amountIn_, uint256 leverage_, uint256 swapAmountOutMin_, uint256 depositAmountMin_, bytes calldata lzArgs_) external payable
        // Note: Not adding this function to the `ISmartFarmingInterface` to avoid changing interface
        // Refs: https://github.com/autonomoussoftware/metronome-synth/issues/877
        // override
        nonReentrant
        onlyIfDepositTokenExists(depositToken_)
        onlyIfSyntheticTokenExists(syntheticToken_)
    {
        IERC20 _tokenIn = tokenIn_; // stack too deep
        if (amountIn_ == 0) revert AmountIsZero();
        if (leverage_ <= 1e18) revert LeverageTooLow();
        if (leverage_ > uint256(1e18).wadDiv(1e18 - depositToken_.collateralFactor())) revert LeverageTooHigh();
        if (address(_tokenIn) == address(0)) revert TokenInIsNull();
        if (address(bridgeToken_) == address(0)) revert BridgeTokenIsNull();
        uint256 _debtAmount;
        uint256 _issued;
        {
            amountIn_ = _safeTransferFrom(_tokenIn, msg.sender, amountIn_);
            _debtAmount = _calculateLeverageDebtAmount(_tokenIn, syntheticToken_, amountIn_, leverage_);
            (_issued, ) = pool.debtTokenOf(syntheticToken_).flashIssue(address(crossChainDispatcher()), _debtAmount);
        }
        bytes memory _swapArgs = abi.encode(syntheticToken_, bridgeToken_, _issued, swapAmountOutMin_);
        IDepositToken _depositToken = depositToken_;
        _triggerCrossChainLeverageSwap({tokenIn_: _tokenIn, amountIn_: amountIn_, debtAmount_: _debtAmount, swapArgs_: _swapArgs, depositToken_: _depositToken, depositAmountMin_: depositAmountMin_, lzArgs_: lzArgs_});
    }

    function _triggerCrossChainLeverageSwap(IERC20 tokenIn_, uint256 amountIn_, uint256 debtAmount_, bytes memory swapArgs_, IDepositToken depositToken_, uint256 depositAmountMin_, bytes calldata lzArgs_) private {
        uint256 _id = _nextCrossChainRequestId();
        (ISyntheticToken _swapTokenIn, IERC20 _swapTokenOut, uint256 _swapAmountIn, uint256 _swapAmountOutMin) = abi.decode(swapArgs_, (ISyntheticToken, IERC20, uint256, uint256));
        {
            (uint16 _dstChainId, , ) = CrossChainLib.decodeLzArgs(lzArgs_);
            crossChainLeverages[_id] = CrossChainLeverage({dstChainId: _dstChainId, tokenIn: tokenIn_, syntheticToken: _swapTokenIn, bridgeToken: _swapTokenOut, depositToken: depositToken_, amountIn: amountIn_, debtAmount: debtAmount_, depositAmountMin: depositAmountMin_, account: msg.sender, finished: false});
        }
        crossChainDispatcher().triggerLeverageSwap{value: msg.value}({id_: _id, account_: payable(msg.sender), tokenIn_: address(_swapTokenIn), tokenOut_: address(_swapTokenOut), amountIn_: _swapAmountIn, amountOutMin: _swapAmountOutMin, lzArgs_: lzArgs_});
    }

    function crossChainLeverageCallback(uint256 id_, uint256 swapAmountOut_) external override whenNotShutdown nonReentrant onlyIfCrossChainDispatcher returns (uint256 _deposited) {
        CrossChainLeverage memory _request = crossChainLeverages[id_];
        if (_request.account == address(0)) revert CrossChainRequestInvalidKey();
        if (_request.finished) revert CrossChainRequestCompletedAlready();
        IERC20 _collateral = _collateralOf(_request.depositToken);
        crossChainLeverages[id_].finished = true;
        swapAmountOut_ = _safeTransferFrom(_request.bridgeToken, msg.sender, swapAmountOut_);
        // Note: The internal `_swap()` doesn't swap if `tokenIn` and `tokenOut` are the same
        uint256 _depositAmount;
        if (_request.tokenIn == _request.bridgeToken) {
            _depositAmount = _swap(swapper(), _request.tokenIn, _collateral, _request.amountIn + swapAmountOut_, 0);
        } else {
            _depositAmount = _swap(swapper(), _request.tokenIn, _collateral, _request.amountIn, 0);
            _depositAmount += _swap(swapper(), _request.bridgeToken, _collateral, swapAmountOut_, 0);
        }
        if (_depositAmount < _request.depositAmountMin) revert LeverageSlippageTooHigh();
        _collateral.safeApprove(address(_request.depositToken), 0);
        _collateral.safeApprove(address(_request.depositToken), _depositAmount);
        (_deposited, ) = _request.depositToken.deposit(_depositAmount, _request.account);
        IPool _pool = pool;
        _pool.debtTokenOf(_request.syntheticToken).mint(_request.account, _request.debtAmount);
        (bool _isHealthy, , , , ) = _pool.debtPositionOf(_request.account);
        if (!_isHealthy) revert PositionIsNotHealthy();
    }

    function flashRepay(ISyntheticToken syntheticToken_, IDepositToken depositToken_, uint256 withdrawAmount_, uint256 repayAmountMin_) external override whenNotShutdown nonReentrant onlyIfDepositTokenExists(depositToken_) onlyIfSyntheticTokenExists(syntheticToken_) returns (uint256 _withdrawn, uint256 _repaid){
        if (withdrawAmount_ == 0) revert AmountIsZero();
        if (withdrawAmount_ > depositToken_.balanceOf(msg.sender)) revert AmountIsTooHigh();
        IPool _pool = pool;
        IDebtToken _debtToken = _pool.debtTokenOf(syntheticToken_);
        if (repayAmountMin_ > _debtToken.balanceOf(msg.sender)) revert AmountIsTooHigh();
        (_withdrawn, ) = depositToken_.flashWithdraw(msg.sender, withdrawAmount_);
        uint256 _amountToRepay = _swap(swapper(), _collateralOf(depositToken_), syntheticToken_, _withdrawn, 0);
        (_repaid, ) = _debtToken.repay(msg.sender, _amountToRepay);
        if (_repaid < repayAmountMin_) revert FlashRepaySlippageTooHigh();
        (bool _isHealthy, , , , ) = _pool.debtPositionOf(msg.sender);
        if (!_isHealthy) revert PositionIsNotHealthy();
    }

    function leverage(IERC20 tokenIn_, IDepositToken depositToken_, ISyntheticToken syntheticToken_, uint256 amountIn_, uint256 leverage_, uint256 depositAmountMin_) external override whenNotShutdown nonReentrant onlyIfDepositTokenExists(depositToken_) onlyIfSyntheticTokenExists(syntheticToken_) returns (uint256 _deposited, uint256 _issued){
        if (amountIn_ == 0) revert AmountIsZero();
        if (leverage_ <= 1e18) revert LeverageTooLow();
        if (leverage_ > uint256(1e18).wadDiv(1e18 - depositToken_.collateralFactor())) revert LeverageTooHigh();
        ISwapper _swapper = swapper();
        IERC20 _collateral = _collateralOf(depositToken_);
        if (address(tokenIn_) == address(0)) tokenIn_ = _collateral;
        amountIn_ = _safeTransferFrom(tokenIn_, msg.sender, amountIn_);
        if (tokenIn_ != _collateral) {
            // Note: `amountOutMin_` is `0` because slippage will be checked later on
            amountIn_ = _swap(_swapper, tokenIn_, _collateral, amountIn_, 0);
        }
        {
            uint256 _debtAmount = _calculateLeverageDebtAmount(_collateral, syntheticToken_, amountIn_, leverage_);
            IDebtToken _debtToken = pool.debtTokenOf(syntheticToken_);
            (_issued, ) = _debtToken.flashIssue(address(this), _debtAmount);
            _debtToken.mint(msg.sender, _debtAmount);
        }
        uint256 _depositAmount = amountIn_ + _swap(_swapper, syntheticToken_, _collateral, _issued, 0);
        if (_depositAmount < depositAmountMin_) revert LeverageSlippageTooHigh();
        _collateral.safeApprove(address(depositToken_), 0);
        _collateral.safeApprove(address(depositToken_), _depositAmount);
        (_deposited, ) = depositToken_.deposit(_depositAmount, msg.sender);
        (bool _isHealthy, , , , ) = pool.debtPositionOf(msg.sender);
        if (!_isHealthy) revert PositionIsNotHealthy();
    }

    function retryCrossChainFlashRepayCallback(uint16 srcChainId_, bytes calldata srcAddress_, uint64 nonce_, uint256 amount_, bytes calldata payload_, uint256 newRepayAmountMin_) external {
        (, , uint256 _requestId) = CrossChainLib.decodeFlashRepayCallbackPayload(payload_);
        CrossChainFlashRepay memory _request = crossChainFlashRepays[_requestId];
        if (_request.account == address(0)) revert CrossChainRequestInvalidKey();
        if (_request.finished) revert CrossChainRequestCompletedAlready();
        // Note: Only user can change slippage param
        if (msg.sender == _request.account) {
            crossChainFlashRepays[_requestId].repayAmountMin = newRepayAmountMin_;
        }
        ICrossChainDispatcher _crossChainDispatcher = crossChainDispatcher();
        bytes memory _from = abi.encodePacked(_crossChainDispatcher.crossChainDispatcherOf(srcChainId_));
        _request.syntheticToken.proxyOFT().retryOFTReceived({_srcChainId: srcChainId_, _srcAddress: srcAddress_, _nonce: nonce_, _from: _from, _to: address(_crossChainDispatcher), _amount: amount_, _payload: payload_});
    }

    function retryCrossChainLeverageCallback(uint16 srcChainId_, bytes calldata srcAddress_, uint64 nonce_, address token_, uint256 amount_, bytes calldata payload_, uint256 newDepositAmountMin_) external {
        (, uint256 _requestId) = CrossChainLib.decodeLeverageCallbackPayload(payload_);
        CrossChainLeverage memory _request = crossChainLeverages[_requestId];
        if (_request.account == address(0)) revert CrossChainRequestInvalidKey();
        if (_request.finished) revert CrossChainRequestCompletedAlready();
        // Note: Only user can change slippage param
        if (msg.sender == _request.account) {
            crossChainLeverages[_requestId].depositAmountMin = newDepositAmountMin_;
        }
        ICrossChainDispatcher _crossChainDispatcher = crossChainDispatcher();
        address _from = _crossChainDispatcher.crossChainDispatcherOf(srcChainId_);
        bytes memory _sgReceiveCallData = abi.encodeWithSelector(IStargateReceiver.sgReceive.selector, srcChainId_, abi.encodePacked(_from), nonce_, token_, amount_, payload_);
        IStargateComposerWithRetry(address(_crossChainDispatcher.stargateComposer())).clearCachedSwap(srcChainId_, srcAddress_, nonce_, address(_crossChainDispatcher), _sgReceiveCallData);
    }

    function swapper() public view returns (ISwapper _swapper) {
        return pool.poolRegistry().swapper();
    }

    function _calculateLeverageDebtAmount(IERC20 collateral_, ISyntheticToken syntheticToken_, uint256 amountIn_, uint256 leverage_) private view returns (uint256 _debtAmount) {
        return pool.masterOracle().quote(address(collateral_), address(syntheticToken_), (leverage_ - 1e18).wadMul(amountIn_));
    }

    /**
     * @dev `collateral` is a better name than `underlying`. See more: https://github.com/autonomoussoftware/metronome-synth/issues/905
     */
    function _collateralOf(IDepositToken depositToken_) private view returns (IERC20) {
        return depositToken_.underlying();
    }

    /**
     * @dev Generates cross-chain request id by hashing `chainId`+`requestId` in order to avoid having same id across supported chains
     * Note: The cross-chain code mostly uses LZ chain ids but in this case, we're using native id.
     */
    function _nextCrossChainRequestId() private returns (uint256 _id) {
        return uint256(keccak256(abi.encode(block.chainid, address(this), ++crossChainRequestsLength)));
    }

    function _safeTransferFrom(IERC20 token_, address from_, uint256 amount_) private returns (uint256 _transferred) {
        uint256 _before = token_.balanceOf(address(this));
        token_.safeTransferFrom(from_, address(this), amount_);
        return token_.balanceOf(address(this)) - _before;
    }

    function _swap(ISwapper swapper_, IERC20 tokenIn_, IERC20 tokenOut_, uint256 amountIn_, uint256 amountOutMin_) private returns (uint256 _amountOut) {
        return _swap(swapper_, tokenIn_, tokenOut_, amountIn_, amountOutMin_, address(this));
    }

    function _swap(ISwapper swapper_, IERC20 tokenIn_, IERC20 tokenOut_, uint256 amountIn_, uint256 amountOutMin_, address to_) private returns (uint256 _amountOut) {
        if (tokenIn_ != tokenOut_) {
            tokenIn_.safeApprove(address(swapper_), 0);
            tokenIn_.safeApprove(address(swapper_), amountIn_);
            uint256 _tokenOutBefore = tokenOut_.balanceOf(to_);
            swapper_.swapExactInput(address(tokenIn_), address(tokenOut_), amountIn_, amountOutMin_, to_);
            return tokenOut_.balanceOf(to_) - _tokenOutBefore;
        } else if (to_ != address(this)) {
            tokenIn_.safeTransfer(to_, amountIn_);
        }
        return amountIn_;
    }
}
