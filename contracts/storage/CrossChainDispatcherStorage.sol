import "../interfaces/ICrossChainDispatcher.sol";
import "../interfaces/IPoolRegistry.sol";

abstract contract CrossChainDispatcherStorageV1 is ICrossChainDispatcher {
    IPoolRegistry public poolRegistry;
    mapping(uint256 => uint256) public swapAmountOutMin;
    mapping(uint16 => address) public crossChainDispatcherOf;
    uint256 public lzBaseGasLimit;
    uint256 public stargateSlippage;
    uint64 public flashRepayCallbackTxGasLimit;
    uint64 public flashRepaySwapTxGasLimit;
    uint64 public leverageCallbackTxGasLimit;
    uint64 public leverageSwapTxGasLimit;
    bool public isBridgingActive;
    IStargateComposer public stargateComposer;
    mapping(address => uint256) public stargatePoolIdOf;
    mapping(uint16 => bool) public isDestinationChainSupported;
    address public weth;
    address public sgeth;
}

abstract contract CrossChainDispatcherStorageV2 is CrossChainDispatcherStorageV1 {
    mapping(uint256 => uint256) public extraCallbackTxNativeFee;
}
