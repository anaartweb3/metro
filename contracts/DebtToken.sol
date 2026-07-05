pragma solidity 0.8.9;

import "./utils/ReentrancyGuard.sol";
import "./utils/TokenHolder.sol";
import "./access/Manageable.sol";
import "./storage/DebtTokenStorage.sol";
import "./lib/WadRayMath.sol";

contract DebtToken is ReentrancyGuard, TokenHolder, Manageable, DebtTokenStorageV2 {
    using WadRayMath for uint256;

    string public constant VERSION = "1.3.0";

    uint256 public constant SECONDS_PER_YEAR = 365.25 days;
    uint256 private constant HUNDRED_PERCENT = 1e18;

    modifier onlyIfSmartFarmingManager() {
        if (msg.sender != address(pool.smartFarmingManager())) revert SenderIsNotSmartFarmingManager();
        _;
    }

    modifier onlyIfSyntheticTokenExists() {
        if (!pool.doesSyntheticTokenExist(syntheticToken)) revert SyntheticDoesNotExist();
        _;
    }

    modifier onlyIfDebtTokenIsActive() {
        if (!isActive) revert DebtTokenInactive();
        _;
    }

    modifier onlyIfSyntheticTokenIsActive() {
        if (!syntheticToken.isActive()) revert SyntheticIsInactive();
        _;
    }

    // @dev Should be called before balance changes (i.e. mint/burn)
    modifier updateRewardsBeforeMintOrBurn(address account_) {
        address[] memory _rewardsDistributors = pool.getRewardsDistributors();
        ISyntheticToken _syntheticToken = syntheticToken;
        uint256 _length = _rewardsDistributors.length;
        for (uint256 i; i < _length; ++i) {
            IRewardsDistributor(_rewardsDistributors[i]).updateBeforeMintOrBurn(_syntheticToken, account_);
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, IPool pool_, ISyntheticToken syntheticToken_, uint256 interestRate_, uint256 maxTotalSupply_) external initializer {
        if (bytes(name_).length == 0) revert NameIsNull();
        if (bytes(symbol_).length == 0) revert SymbolIsNull();
        if (address(pool_) == address(0)) revert PoolIsNull();
        if (address(syntheticToken_) == address(0)) revert SyntheticIsNull();
        __ReentrancyGuard_init();
        __Manageable_init(pool_);
        name = name_;
        symbol = symbol_;
        decimals = syntheticToken_.decimals();
        syntheticToken = syntheticToken_;
        lastTimestampAccrued = block.timestamp;
        debtIndex = 1e18;
        interestRate = interestRate_;
        maxTotalSupply = maxTotalSupply_;
        isActive = true;
    }

    function accrueInterest() public override {
        (uint256 _interestAmountAccrued,uint256 _debtIndex,uint256 _lastTimestampAccrued) = _calculateInterestAccrual();
        if (block.timestamp == _lastTimestampAccrued) {
            return;
        }
        lastTimestampAccrued = block.timestamp;
        if (_interestAmountAccrued > 0) {
            totalSupply_ += _interestAmountAccrued;
            debtIndex = _debtIndex;
            // Note: Address states where minting will fail (e.g. the token is inactive, it reached max supply, etc)
            try syntheticToken.mint(pool.feeCollector(), _interestAmountAccrued + pendingInterestFee) {
                pendingInterestFee = 0;
            } catch {
                pendingInterestFee += _interestAmountAccrued;
            }
        }
    }

    function allowance(address /*owner_*/, address /*spender_*/) external pure override returns (uint256) {
        revert AllowanceNotSupported();
    }

    function approve(address /*spender_*/, uint256 /*amount_*/) external override returns (bool) {
        revert ApprovalNotSupported();
    }

    // @notice Get the updated (principal + interest) user's debt
    function balanceOf(address account_) public view override returns (uint256) {
        uint256 _principal = principalOf[account_];
        if (_principal == 0) {
            return 0;
        }
        (, uint256 _debtIndex, ) = _calculateInterestAccrual();
        // Note: The `debtIndex / debtIndexOf` gives the interest to apply to the principal amount
        return (_principal * _debtIndex) / debtIndexOf[account_];
    }

    function burn(address from_, uint256 amount_) external override onlyPool {
        _burn(from_, amount_);
    }

    function collectPendingInterestFee() external {
        uint256 _pendingInterestFee = pendingInterestFee;
        if (_pendingInterestFee > 0) {
            syntheticToken.mint(pool.feeCollector(), _pendingInterestFee);
            pendingInterestFee = 0;
        }
    }

    // @notice Lock collateral and mint synthetic token
    function issue(uint256 amount_, address to_) external override whenNotShutdown nonReentrant onlyIfSyntheticTokenExists returns (uint256 _issued, uint256 _fee){
        if (amount_ == 0) revert AmountIsZero();
        accrueInterest();
        IPool _pool = pool;
        ISyntheticToken _syntheticToken = syntheticToken;
        (, , , , uint256 _issuableInUsd) = _pool.debtPositionOf(msg.sender);
        IMasterOracle _masterOracle = _pool.masterOracle();
        if (amount_ > _masterOracle.quoteUsdToToken(address(_syntheticToken), _issuableInUsd)) {
            revert NotEnoughCollateral();
        }
        _mint(_pool, _masterOracle, msg.sender, amount_);
        (_issued, _fee) = quoteIssueOut(amount_);
        if (_fee > 0) {
            _syntheticToken.mint(_pool.feeCollector(), _fee);
        }
        _syntheticToken.mint(to_, _issued);
    }

    /**
     * @notice Issue synth without checking collateral and without minting debt tokens
     * @dev The healthy of outcome position must be done afterhand
     */
    function flashIssue(address to_, uint256 amount_) external override onlyIfSmartFarmingManager whenNotShutdown nonReentrant onlyIfSyntheticTokenExists onlyIfDebtTokenIsActive returns (uint256 _issued, uint256 _fee){
        if (amount_ == 0) revert AmountIsZero();
        accrueInterest();
        ISyntheticToken _syntheticToken = syntheticToken;
        (_issued, _fee) = quoteIssueOut(amount_);
        if (_fee > 0) {
            _syntheticToken.mint(pool.feeCollector(), _fee);
        }
        _syntheticToken.mint(to_, _issued);
    }

    function interestRatePerSecond() public view override returns (uint256) {
        return interestRate / SECONDS_PER_YEAR;
    }

    // @notice onlySmartFarmingManager:: Mint `amount_` of debtToken at `to_`.
    function mint(address to_, uint256 amount_) external override onlyIfSmartFarmingManager whenNotShutdown nonReentrant onlyIfSyntheticTokenExists onlyIfSyntheticTokenIsActive {
        accrueInterest();
        IPool _pool = pool;
        _mint(_pool, _pool.masterOracle(), to_, amount_);
    }

    // @notice Quote gross `_amount` to issue `amountToIssue_` synthetic tokens
    function quoteIssueIn(uint256 amountToIssue_) external view override returns (uint256 _amount, uint256 _fee) {
        uint256 _issueFee = pool.feeProvider().issueFee();
        if (_issueFee == 0) {
            return (amountToIssue_, _fee);
        }
        _amount = amountToIssue_.wadDiv(HUNDRED_PERCENT - _issueFee);
        _fee = _amount - amountToIssue_;
    }

    // @notice Quote synthetic tokens `_amountToIssue` by using gross `_amount`
    function quoteIssueOut(uint256 amount_) public view override returns (uint256 _amountToIssue, uint256 _fee) {
        uint256 _issueFee = pool.feeProvider().issueFee();
        if (_issueFee == 0) {
            return (amount_, _fee);
        }
        _fee = amount_.wadMul(_issueFee);
        _amountToIssue = amount_ - _fee;
    }

    // @notice Quote synthetic token `_amount` need to repay `amountToRepay_` debt
    function quoteRepayIn(uint256 amountToRepay_) public view override returns (uint256 _amount, uint256 _fee) {
        uint256 _repayFee = pool.feeProvider().repayFee();
        if (_repayFee == 0) {
            return (amountToRepay_, _fee);
        }
        _fee = amountToRepay_.wadMul(_repayFee);
        _amount = amountToRepay_ + _fee;
    }

    // @notice Quote debt `_amountToRepay` by burning `_amount` synthetic tokens
    function quoteRepayOut(uint256 amount_) public view override returns (uint256 _amountToRepay, uint256 _fee) {
        uint256 _repayFee = pool.feeProvider().repayFee();
        if (_repayFee == 0) {
            return (amount_, _fee);
        }
        _amountToRepay = amount_.wadDiv(HUNDRED_PERCENT + _repayFee);
        _fee = amount_ - _amountToRepay;
    }

    // @notice Send synthetic token to decrease debt
    function repay(address onBehalfOf_, uint256 amount_) external override whenNotShutdown nonReentrant onlyIfSyntheticTokenExists returns (uint256 _repaid, uint256 _fee){
        if (amount_ == 0) revert AmountIsZero();
        accrueInterest();
        IPool _pool = pool;
        ISyntheticToken _syntheticToken = syntheticToken;
        (_repaid, _fee) = quoteRepayOut(amount_);
        if (_fee > 0) {
            _syntheticToken.seize(msg.sender, _pool.feeCollector(), _fee);
        }
        uint256 _debtFloorInUsd = _pool.debtFloorInUsd();
        if (_debtFloorInUsd > 0) {
            uint256 _newDebtInUsd = _pool.masterOracle().quoteTokenToUsd(
                address(_syntheticToken),
                balanceOf(onBehalfOf_) - _repaid
            );
            if (_newDebtInUsd > 0 && _newDebtInUsd < _debtFloorInUsd) {
                revert RemainingDebtIsLowerThanTheFloor();
            }
        }
        _syntheticToken.burn(msg.sender, _repaid);
        _burn(onBehalfOf_, _repaid);
    }

    // @notice Send synthetic token to decrease debt
    function repayAll(address onBehalfOf_) external override whenNotShutdown nonReentrant onlyIfSyntheticTokenExists returns (uint256 _repaid, uint256 _fee){
        accrueInterest();
        _repaid = balanceOf(onBehalfOf_);
        if (_repaid == 0) revert AmountIsZero();
        ISyntheticToken _syntheticToken = syntheticToken;
        uint256 _amount;
        (_amount, _fee) = quoteRepayIn(_repaid);
        if (_fee > 0) {
            _syntheticToken.seize(msg.sender, pool.feeCollector(), _fee);
        }
        _syntheticToken.burn(msg.sender, _repaid);
        _burn(onBehalfOf_, _repaid);
    }

    function totalSupply() external view override returns (uint256) {
        (uint256 _interestAmountAccrued, , ) = _calculateInterestAccrual();
        return totalSupply_ + _interestAmountAccrued;
    }

    function transfer(address /*recipient_*/, uint256 /*amount_*/) external override returns (bool) {
        revert TransferNotSupported();
    }

    function transferFrom(
        address /*sender_*/,
        address /*recipient_*/,
        uint256 /*amount_*/
    ) external override returns (bool) {
        revert TransferNotSupported();
    }

    // @notice Destroy `amount` tokens from `account`, reducing the total supply
    function _burn(address account_, uint256 amount_) private updateRewardsBeforeMintOrBurn(account_) {
        if (account_ == address(0)) revert BurnFromNullAddress();
        uint256 _accountBalance = balanceOf(account_);
        if (_accountBalance < amount_) revert BurnAmountExceedsBalance();
        unchecked {
            principalOf[account_] = _accountBalance - amount_;
            debtIndexOf[account_] = debtIndex;
            totalSupply_ -= amount_;
        }
        // Remove this token from the debt tokens list if the sender's balance goes to zero
        if (amount_ > 0 && balanceOf(account_) == 0) {
            pool.removeFromDebtTokensOfAccount(account_);
        }
    }

    /**
     * @dev This util function avoids code duplication across `balanceOf` and `accrueInterest`
     * @return _interestAmountAccrued The total amount of debt tokens accrued
     * @return _debtIndex The new `debtIndex` value
     */
    function _calculateInterestAccrual() private view returns (uint256 _interestAmountAccrued, uint256 _debtIndex, uint256 _lastTimestampAccrued){
        _lastTimestampAccrued = lastTimestampAccrued;
        _debtIndex = debtIndex;
        if (block.timestamp > _lastTimestampAccrued) {
            uint256 _interestRateToAccrue = interestRatePerSecond() * (block.timestamp - _lastTimestampAccrued);
            if (_interestRateToAccrue > 0) {
                _interestAmountAccrued = _interestRateToAccrue.wadMul(totalSupply_);
                _debtIndex += _interestRateToAccrue.wadMul(debtIndex);
            }
        }
    }

    // @dev Create `amount` tokens and assigns them to `account`, increasing the total supply
    function _mint(IPool pool_, IMasterOracle masterOracle_, address account_, uint256 amount_) private onlyIfDebtTokenIsActive updateRewardsBeforeMintOrBurn(account_) {
        if (account_ == address(0)) revert MintToNullAddress();
        uint256 _debtFloorInUsd = pool_.debtFloorInUsd();
        uint256 _balanceBefore = balanceOf(account_);
        if (_debtFloorInUsd > 0 && masterOracle_.quoteTokenToUsd(address(syntheticToken), _balanceBefore + amount_) < _debtFloorInUsd) {
            revert DebtLowerThanTheFloor();
        }
        totalSupply_ += amount_;
        if (totalSupply_ > maxTotalSupply) revert SurpassMaxDebtSupply();
        principalOf[account_] = _balanceBefore + amount_;
        debtIndexOf[account_] = debtIndex;
        //  Add this token to the debt tokens list if the recipient is receiving it for the 1st time
        if (_balanceBefore == 0 && amount_ > 0) {
            pool.addToDebtTokensOfAccount(account_);
        }
    }

    function _requireCanSweep() internal view override onlyGovernor {}

    function updateMaxTotalSupply(uint256 newMaxTotalSupply_) external override onlyGovernor {
        uint256 _currentMaxTotalSupply = maxTotalSupply;
        if (newMaxTotalSupply_ == _currentMaxTotalSupply) revert NewValueIsSameAsCurrent();
        maxTotalSupply = newMaxTotalSupply_;
    }

    function updateInterestRate(uint256 newInterestRate_) external override onlyGovernor {
        accrueInterest();
        uint256 _currentInterestRate = interestRate;
        if (newInterestRate_ == _currentInterestRate) revert NewValueIsSameAsCurrent();
        interestRate = newInterestRate_;
    }

    function toggleIsActive() external override onlyGovernor {
        bool _newIsActive = !isActive;
        isActive = _newIsActive;
    }
}
