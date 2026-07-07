import "../interfaces/ICrossChainDispatcher.sol";
import "../interfaces/IPoolRegistry.sol";

abstract contract CrossChainDispatcherStorageV1 is ICrossChainDispatcher {

    IPoolRegistry public poolRegistry;

    /**
     * @notice Overwritten swap slippage params
     * @dev Used by retry functions in case of swap failure due to slippage (See: `_swap()`)
     */
    mapping(uint256 => uint256) public swapAmountOutMin;

    mapping(uint16 => address) public crossChainDispatcherOf;

    /**
     * @dev This limit covers basic token transfer LZ cost
     */
    uint256 public lzBaseGasLimit;

    /**
     * @notice The slippage we're willing to accept for SG like:like transfers
     */
    uint256 public stargateSlippage;

    /**
     * @notice The gas limit to cover `_crossChainFlashRepayCallback()` call
     */
    uint64 public flashRepayCallbackTxGasLimit;

    /**
     * @notice The gas limit to cover `_swapAndTriggerFlashRepayCallback()` call
     */
    uint64 public flashRepaySwapTxGasLimit;

    /**
     * @notice The gas limit to cover `_crossChainLeverageCallback()` call
     */
    uint64 public leverageCallbackTxGasLimit;

    /**
     * @notice The gas limit to cover `_swapAndTriggerLeverageCallback()` call
     */
    uint64 public leverageSwapTxGasLimit;

    bool public isBridgingActive;

    IStargateComposer public stargateComposer;

    mapping(address => uint256) public stargatePoolIdOf;

    mapping(uint16 => bool) public isDestinationChainSupported;

    address public weth;

    address public sgeth;
}

abstract contract CrossChainDispatcherStorageV2 is CrossChainDispatcherStorageV1 {
    /**
     * @notice Store extra amount sent when retrying a failed tx due to low native fee
     */
    mapping(uint256 => uint256) public extraCallbackTxNativeFee;
}
