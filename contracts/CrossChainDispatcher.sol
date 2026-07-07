pragma solidity 0.8.9;

import "./utils/ReentrancyGuard.sol";
import "./dependencies/@layerzerolabs/solidity-examples/util/BytesLib.sol";
import "./dependencies/openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/external/IStargateComposerWithRetry.sol";
import "./interfaces/external/IWETH.sol";
import "./interfaces/external/IStargatePool.sol";
import "./interfaces/external/IStargateFactory.sol";
import "./storage/CrossChainDispatcherStorage.sol";
import "./interfaces/IProxyOFT.sol";
import "./interfaces/ISmartFarmingManager.sol";
import "./interfaces/ISyntheticToken.sol";
import "./interfaces/external/ISwapper.sol";
import "./lib/CrossChainLib.sol";

// Note: The `IPool` wasn't updated to avoid changing interface. Refs: https://github.com/autonomoussoftware/metronome-synth/issues/877
interface IPoolV4 is IPool {
    function isBridgingActive() external view returns (bool);
}

contract CrossChainDispatcher is ReentrancyGuard, CrossChainDispatcherStorageV2 {
    // @dev LayerZero adapter param version. See more: https://layerzero.gitbook.io/docs/evm-guides/advanced/relayer-adapter-parameters
    uint16 private constant LZ_ADAPTER_PARAMS_VERSION = 2;
    uint256 private constant MAX_BPS = 100_00;

    struct LayerZeroParams {
        address tokenIn;
        uint16 dstChainId;
        uint256 amountIn;
        uint256 nativeFee;
        bytes payload;
        address refundAddress;
        uint64 dstGasForCall;
        uint256 dstNativeAmount;
    }

    modifier onlyGovernor() {
        if (msg.sender != poolRegistry.governor()) revert SenderIsNotGovernor();
        _;
    }

    modifier onlyIfBridgingIsNotPaused() {
        if (!isBridgingActive || !IPoolV4(address(IManageable(msg.sender).pool())).isBridgingActive())
            revert BridgingIsPaused();
        _;
    }

    modifier onlyIfSmartFarmingManager() {
        IPool _pool = IManageable(msg.sender).pool();
        if (!poolRegistry.isPoolRegistered(address(_pool))) revert InvalidMsgSender();
        if (msg.sender != address(_pool.smartFarmingManager())) revert InvalidMsgSender();
        _;
    }

    modifier onlyIfStargateComposer() {
        if (msg.sender != address(stargateComposer)) revert InvalidMsgSender();
        _;
    }

    modifier onlyIfProxyOFT() {
        if (!_isValidProxyOFT(msg.sender)) revert InvalidMsgSender();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(IPoolRegistry poolRegistry_, address weth_, address sgeth_) external initializer {
        __ReentrancyGuard_init();
        poolRegistry = poolRegistry_;
        stargateSlippage = 50;
        lzBaseGasLimit = 200_000;
        flashRepayCallbackTxGasLimit = 750_000;
        flashRepaySwapTxGasLimit = 500_000;
        leverageCallbackTxGasLimit = 750_000;
        leverageSwapTxGasLimit = 750_000;
        weth = weth_;
        sgeth = sgeth_;
    }

    // @notice Called by the OFT contract when tokens are received from source chain.
    function onOFTReceived(uint16 srcChainId_, bytes calldata /*srcAddress_*/, uint64 /*nonce_*/, bytes calldata from_, uint amount_, bytes calldata payload_) external override onlyIfProxyOFT {
        address _from = from_.toAddress(0);
        if (_from == address(0) || _from != crossChainDispatcherOf[srcChainId_]) revert InvalidFromAddress();
        uint8 _op = CrossChainLib.getOperationType(payload_);
        if (_op == CrossChainLib.FLASH_REPAY) {
            _crossChainFlashRepayCallback(amount_, payload_);
        } else if (_op == CrossChainLib.LEVERAGE) {
            _swapAndTriggerLeverageCallback(srcChainId_, amount_, payload_);
        } else {
            revert InvalidOperationType();
        }
    }

    // @dev Finalize cross-chain flash repay process. The callback may fail due to slippage.
    function _crossChainFlashRepayCallback(uint amount_, bytes calldata payload_) private {
        (address proxyOFT_, address _smartFarmingManager, uint256 _requestId) = CrossChainLib.decodeFlashRepayCallbackPayload(payload_);
        IERC20 _syntheticToken = IERC20(IProxyOFT(proxyOFT_).token());
        _syntheticToken.safeApprove(_smartFarmingManager, 0);
        _syntheticToken.safeApprove(_smartFarmingManager, amount_);
        ISmartFarmingManager(_smartFarmingManager).crossChainFlashRepayCallback(_requestId, amount_);
    }

    function _swapAndTriggerLeverageCallback(uint16 srcChainId_, uint amountIn_, bytes calldata payload_) private {
        (address _srcSmartFarmingManager,address _dstProxyOFT,uint256 _requestId,uint256 _sgPoolId,address _account,uint256 _amountOutMin,uint256 _callbackTxNativeFee) = CrossChainLib.decodeLeverageSwapPayload(payload_);
        address _bridgeToken = IStargatePool(IStargateFactory(stargateComposer.factory()).getPool(_sgPoolId)).token();
        if (_bridgeToken == sgeth) _bridgeToken = weth;
        amountIn_ = _swap({requestId_: _requestId, tokenIn_: IProxyOFT(_dstProxyOFT).token(), tokenOut_: _bridgeToken, amountIn_: amountIn_, amountOutMin_: _amountOutMin});
        uint16 _srcChainId = srcChainId_;
        _sendUsingStargate(LayerZeroParams({tokenIn: _bridgeToken, dstChainId: _srcChainId, amountIn: amountIn_, nativeFee: _callbackTxNativeFee + extraCallbackTxNativeFee[_requestId], payload: CrossChainLib.encodeLeverageCallbackPayload(_srcSmartFarmingManager, _requestId), refundAddress: _account, dstGasForCall: leverageCallbackTxGasLimit, dstNativeAmount: 0}));
    }

    function sgReceive(uint16 srcChainId_, bytes memory srcAddress_, uint256 /*nonce_*/, address token_, uint256 amountLD_, bytes memory payload_) external override onlyIfStargateComposer {
        // Note: Stargate uses SGETH as `token_` when receiving native ETH
        if (token_ == sgeth) {
            IWETH(weth).deposit{value: amountLD_}();
            token_ = weth;
        }
        address _srcAddress = srcAddress_.toAddress(0);
        if (_srcAddress == address(0) || _srcAddress != crossChainDispatcherOf[srcChainId_])
            revert InvalidFromAddress();
        uint8 _op = CrossChainLib.getOperationType(payload_);
        if (_op == CrossChainLib.LEVERAGE) {
            _crossChainLeverageCallback(token_, amountLD_, payload_);
        } else if (_op == CrossChainLib.FLASH_REPAY) {
            _swapAndTriggerFlashRepayCallback(srcChainId_, token_, amountLD_, payload_);
        } else {
            revert InvalidOperationType();
        }
    }

    // @dev Finalize cross-chain leverage process. The callback may fail due to slippage.
    function _crossChainLeverageCallback(address bridgeToken_, uint256 amount_, bytes memory payload_) private {
        (address _smartFarmingManager, uint256 _requestId) = CrossChainLib.decodeLeverageCallbackPayload(payload_);
        IERC20(bridgeToken_).safeApprove(_smartFarmingManager, 0);
        IERC20(bridgeToken_).safeApprove(_smartFarmingManager, amount_);
        ISmartFarmingManager(_smartFarmingManager).crossChainLeverageCallback(_requestId, amount_);
    }

    function _sendUsingLayerZero(LayerZeroParams memory params_) private {
        address _to = crossChainDispatcherOf[params_.dstChainId];
        if (_to == address(0)) revert AddressIsNull();
        bytes memory _adapterParams = abi.encodePacked(LZ_ADAPTER_PARAMS_VERSION, uint256(lzBaseGasLimit + params_.dstGasForCall), params_.dstNativeAmount, (params_.dstNativeAmount > 0) ? _to : address(0));
        ISyntheticToken(params_.tokenIn).proxyOFT().sendAndCall{value: params_.nativeFee}({_from: address(this), _dstChainId: params_.dstChainId, _toAddress: abi.encodePacked(_to), _amount: params_.amountIn, _payload: params_.payload, _dstGasForCall: params_.dstGasForCall, _refundAddress: payable(params_.refundAddress), _zroPaymentAddress: address(0), _adapterParams: _adapterParams});
    }

    function _swapAndTriggerFlashRepayCallback(uint16 srcChainId_, address token_, uint256 amount_, bytes memory payload_) private {
        (address _srcSmartFarmingManager,address _dstProxyOFT,uint256 _requestId,address _account,uint256 _amountOutMin,uint256 _callbackTxNativeFee) = CrossChainLib.decodeFlashRepaySwapPayload(payload_);
        address _syntheticToken = IProxyOFT(_dstProxyOFT).token();
        amount_ = _swap({requestId_: _requestId, tokenIn_: token_, tokenOut_: _syntheticToken, amountIn_: amount_, amountOutMin_: _amountOutMin});
        uint16 _srcChainId = srcChainId_;
        address _srcProxyOFT = IProxyOFT(_dstProxyOFT).getProxyOFTOf(_srcChainId);
        _sendUsingLayerZero(LayerZeroParams({tokenIn: _syntheticToken, dstChainId: _srcChainId, amountIn: amount_, payload: CrossChainLib.encodeFlashRepayCallbackPayload(_srcProxyOFT, _srcSmartFarmingManager, _requestId), refundAddress: _account, dstGasForCall: flashRepayCallbackTxGasLimit, dstNativeAmount: 0, nativeFee: _callbackTxNativeFee + extraCallbackTxNativeFee[_requestId]}));
    }

    function retrySwapAndTriggerFlashRepayCallback(uint16 srcChainId_, bytes calldata srcAddress_, uint64 nonce_, address token_, uint256 amount_, bytes calldata payload_, uint256 newAmountOutMin_) external payable nonReentrant {
        IStargateComposerWithRetry _stargateComposer = IStargateComposerWithRetry(address(stargateComposer));
        bytes memory _sgReceiveCallData = abi.encodeWithSelector(IStargateReceiver.sgReceive.selector, srcChainId_, abi.encodePacked(crossChainDispatcherOf[srcChainId_]), nonce_, token_, amount_, payload_);
        (, , uint256 _requestId, address _account, , ) = CrossChainLib.decodeFlashRepaySwapPayload(payload_);
        if (msg.value > 0) {
            extraCallbackTxNativeFee[_requestId] += msg.value;
        }
        if (msg.sender == _account) {
            // Note: If `swapAmountOutMin[_requestId]` is `0` (default value), swap function will use payload's slippage param
            if (newAmountOutMin_ == 0) revert InvalidSlippageParam();
            swapAmountOutMin[_requestId] = newAmountOutMin_;
        }
        // Note: `clearCachedSwap()` has checks to ensure that the args are consistent
        _stargateComposer.clearCachedSwap(srcChainId_, srcAddress_, nonce_, address(this), _sgReceiveCallData);
    }

    function retrySwapAndTriggerLeverageCallback(uint16 srcChainId_, bytes calldata srcAddress_, uint64 nonce_, uint256 amount_, bytes calldata payload_, uint256 newAmountOutMin_) external payable nonReentrant {
        (, address _dstProxyOFT, uint256 _requestId, , address _account, , ) = CrossChainLib.decodeLeverageSwapPayload(payload_);
        if (!_isValidProxyOFT(_dstProxyOFT)) revert InvalidPayload();
        if (msg.value > 0) {
            extraCallbackTxNativeFee[_requestId] += msg.value;
        }
        if (msg.sender == _account) {
            // Note: If `swapAmountOutMin[_requestId]` is `0` (default value), swap function will use payload's slippage param
            if (newAmountOutMin_ == 0) revert InvalidSlippageParam();
            swapAmountOutMin[_requestId] = newAmountOutMin_;
        }
        // Note: `retryOFTReceived()` has checks to ensure that the args are consistent
        bytes memory _from = abi.encodePacked(crossChainDispatcherOf[srcChainId_]);
        IProxyOFT(_dstProxyOFT).retryOFTReceived(srcChainId_, srcAddress_, nonce_, _from, address(this), amount_, payload_);
    }

    function triggerFlashRepaySwap(uint256 requestId_, address payable account_, address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOutMin_, bytes calldata lzArgs_) external payable override nonReentrant onlyIfSmartFarmingManager onlyIfBridgingIsNotPaused {
        address _account = account_;
        (uint16 _dstChainId, uint256 callbackTxNativeFee_, uint64 flashRepaySwapTxGasLimit_) = CrossChainLib.decodeLzArgs(lzArgs_);
        bytes memory _payload;
        address _dstProxyOFT = ISyntheticToken(tokenOut_).proxyOFT().getProxyOFTOf(_dstChainId);
        if (_dstProxyOFT == address(0)) revert AddressIsNull();
        if (!isDestinationChainSupported[_dstChainId]) revert DestinationChainNotAllowed();
        uint256 _requestId = requestId_;
        _payload = CrossChainLib.encodeFlashRepaySwapPayload({srcSmartFarmingManager_: msg.sender, dstProxyOFT_: _dstProxyOFT, requestId_: _requestId, account_: _account, amountOutMin_: amountOutMin_, callbackTxNativeFee_: callbackTxNativeFee_});
        _sendUsingStargate(LayerZeroParams({tokenIn: tokenIn_, dstChainId: _dstChainId, amountIn: amountIn_, nativeFee: msg.value, payload: _payload, refundAddress: _account, dstGasForCall: flashRepaySwapTxGasLimit_, dstNativeAmount: callbackTxNativeFee_}));
    }

    // @dev Not checking if bridging is pause because `ProxyOFT._debitFrom()` does it
    function triggerLeverageSwap(uint256 requestId_, address payable account_, address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOutMin_, bytes calldata lzArgs_) external payable override nonReentrant onlyIfSmartFarmingManager onlyIfBridgingIsNotPaused {
        address _account = account_;
        (uint16 _dstChainId, uint256 _callbackTxNativeFee, uint64 _leverageSwapTxGasLimit) = CrossChainLib.decodeLzArgs(lzArgs_);
        bytes memory _payload;
        address _tokenOut = tokenOut_;
        uint256 _requestId = requestId_;
        uint256 _amountOutMin = amountOutMin_;
        address _dstProxyOFT = ISyntheticToken(tokenIn_).proxyOFT().getProxyOFTOf(_dstChainId);
        uint256 _sgPoolId = stargatePoolIdOf[_tokenOut];
        if (_dstProxyOFT == address(0)) revert AddressIsNull();
        if (!isDestinationChainSupported[_dstChainId]) revert DestinationChainNotAllowed();
        if (_sgPoolId == 0) revert BridgeTokenNotSupported();
        _payload = CrossChainLib.encodeLeverageSwapPayload({srcSmartFarmingManager_: msg.sender, dstProxyOFT_: _dstProxyOFT, requestId_: _requestId, sgPoolId_: _sgPoolId, account_: _account, amountOutMin_: _amountOutMin, callbackTxNativeFee_: _callbackTxNativeFee});
        _sendUsingLayerZero(LayerZeroParams({tokenIn: tokenIn_, dstChainId: _dstChainId, amountIn: amountIn_, payload: _payload, refundAddress: _account, dstGasForCall: _leverageSwapTxGasLimit, dstNativeAmount: _callbackTxNativeFee, nativeFee: msg.value}));
    }

    function _isValidProxyOFT(address proxyOFT_) private view returns (bool) {
        ISyntheticToken _syntheticToken = ISyntheticToken(IProxyOFT(proxyOFT_).token());
        if (!poolRegistry.doesSyntheticTokenExist(_syntheticToken)) return false;
        if (proxyOFT_ != address(_syntheticToken.proxyOFT())) return false;
        return true;
    }

    function _sendUsingStargate(LayerZeroParams memory params_) private {
        IStargateRouter.lzTxObj memory _lzTxParams;
        bytes memory _to = abi.encodePacked(crossChainDispatcherOf[params_.dstChainId]);
        if (_to.toAddress(0) == address(0)) revert AddressIsNull();
        _lzTxParams = IStargateRouter.lzTxObj({dstGasForCall: params_.dstGasForCall, dstNativeAmount: params_.dstNativeAmount, dstNativeAddr: (params_.dstNativeAmount > 0) ? _to : abi.encode(0)});
        uint256 _poolId = stargatePoolIdOf[params_.tokenIn];
        if (_poolId == 0) revert BridgeTokenNotSupported();
        uint256 _amountOutMin = (params_.amountIn * (MAX_BPS - stargateSlippage)) / MAX_BPS;
        bytes memory _payload = params_.payload;
        IStargateComposer _stargateComposer = stargateComposer;
        // Note: StargateComposer only accepts native for ETH pool
        if (params_.tokenIn == weth) {
            IWETH(weth).withdraw(params_.amountIn);
            params_.nativeFee += params_.amountIn;
        } else {
            IERC20(params_.tokenIn).safeApprove(address(_stargateComposer), 0);
            IERC20(params_.tokenIn).safeApprove(address(_stargateComposer), params_.amountIn);
        }
        _stargateComposer.swap{value: params_.nativeFee}({_dstChainId: params_.dstChainId, _srcPoolId: _poolId, _dstPoolId: _poolId, _refundAddress: payable(params_.refundAddress), _amountLD: params_.amountIn, _minAmountLD: _amountOutMin, _lzTxParams: _lzTxParams, _to: _to, _payload: _payload});
    }

    function _swap(uint256 requestId_, address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOutMin_) private returns (uint256 _amountOut) {
        uint256 _storedAmountOutMin = swapAmountOutMin[requestId_];
        if (_storedAmountOutMin > 0) {
            amountOutMin_ = _storedAmountOutMin;
            delete swapAmountOutMin[requestId_];
        }
        ISwapper _swapper = poolRegistry.swapper();
        IERC20(tokenIn_).safeApprove(address(_swapper), 0);
        IERC20(tokenIn_).safeApprove(address(_swapper), amountIn_);
        _amountOut = _swapper.swapExactInput({tokenIn_: tokenIn_, tokenOut_: tokenOut_, amountIn_: amountIn_, amountOutMin_: amountOutMin_, receiver_: address(this)});
    }

    // @dev Use LZ ids (https://stargateprotocol.gitbook.io/stargate/developers/pool-ids)
    function updateStargatePoolIdOf(address token_, uint256 newPoolId_) external onlyGovernor {
        uint256 _currentPoolId = stargatePoolIdOf[token_];
        if (newPoolId_ == _currentPoolId) revert NewValueIsSameAsCurrent();
        stargatePoolIdOf[token_] = newPoolId_;
    }

    function updateStargateSlippage(uint256 newStargateSlippage_) external onlyGovernor {
        uint256 _currentStargateSlippage = stargateSlippage;
        if (newStargateSlippage_ == _currentStargateSlippage) revert NewValueIsSameAsCurrent();
        stargateSlippage = newStargateSlippage_;
    }

    function updateStargateComposer(IStargateComposer newStargateComposer_) external onlyGovernor {
        IStargateComposer _currentStargateComposer = stargateComposer;
        if (newStargateComposer_ == _currentStargateComposer) revert NewValueIsSameAsCurrent();
        stargateComposer = newStargateComposer_;
    }

    function toggleBridgingIsActive() external onlyGovernor {
        bool _newIsBridgingActive = !isBridgingActive;
        isBridgingActive = _newIsBridgingActive;
    }

    function updateCrossChainDispatcherOf(uint16 chainId_, address crossChainDispatcher_) external onlyGovernor {
        address _current = crossChainDispatcherOf[chainId_];
        if (crossChainDispatcher_ == _current) revert NewValueIsSameAsCurrent();
        crossChainDispatcherOf[chainId_] = crossChainDispatcher_;
    }

    function toggleDestinationChainIsActive(uint16 chainId_) external onlyGovernor {
        bool _isDestinationChainSupported = !isDestinationChainSupported[chainId_];
        isDestinationChainSupported[chainId_] = _isDestinationChainSupported;
    }
}
