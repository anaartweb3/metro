// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import "./utils/ReentrancyGuard.sol";
import "./utils/TokenHolder.sol";
import "./interfaces/IVesperGateway.sol";
import "./interfaces/IDepositToken.sol";

error SenderIsNotGovernor();
error UnregisteredPool();

/**
 * @title Helper contract to easily support vTokens as collateral
 */
contract VesperGateway is ReentrancyGuard, TokenHolder, IVesperGateway {
    using SafeERC20 for IERC20;
    using SafeERC20 for IDepositToken;
    using SafeERC20 for IVPool;

    IPoolRegistry public immutable poolRegistry;

    modifier onlyGovernor() {
        if (poolRegistry.governor() != msg.sender) revert SenderIsNotGovernor();
        _;
    }

    constructor(IPoolRegistry poolRegistry_) initializer {
        // Note: This contract isn't upgradable but extends `ReentrancyGuard` therefore we need to initialize it
        __ReentrancyGuard_init();
        poolRegistry = poolRegistry_;
    }

    /**
     * @notice Deposit `vToken` as collateral using underlying asset.
     * @param pool_ The Pool contract
     * @param vToken_ The vToken to deposit
     * @param amount_ The amount of `underlying` asset to deposit
     */
    function deposit(IPool pool_, IVPool vToken_, uint256 amount_) external override {
        if (!poolRegistry.isPoolRegistered(address(pool_))) revert UnregisteredPool();

        // 1. Get `underlying` asset
        IERC20 _underlying = IERC20(vToken_.token());
        _underlying.safeTransferFrom(msg.sender, address(this), amount_);

        // 2. Deposit `underlying` to `VPool`
        _underlying.safeApprove(address(vToken_), 0);
        _underlying.safeApprove(address(vToken_), amount_);
        uint256 _balanceBefore = vToken_.balanceOf(address(this));
        vToken_.deposit(amount_);
        uint256 _vTokenAmount = vToken_.balanceOf(address(this)) - _balanceBefore;

        // 3. Deposit `VPool` to `Synth` and send `msdTokens` to the `msg.sender`
        IDepositToken _depositToken = pool_.depositTokenOf(vToken_);
        vToken_.safeApprove(address(_depositToken), 0);
        vToken_.safeApprove(address(_depositToken), _vTokenAmount);
        _depositToken.deposit(_vTokenAmount, msg.sender);
    }

    /**
     * @notice Withdraws the `vToken` deposit of msg.sender.
     * @param pool_ The Pool contract
     * @param vToken_ The vToken to withdraw
     * @param amount_ The amount of deposit tokens to withdraw and receive underlying
     */
    function withdraw(IPool pool_, IVPool vToken_, uint256 amount_) external override nonReentrant {
        if (!poolRegistry.isPoolRegistered(address(pool_))) revert UnregisteredPool();

        // 1. Get `msdTokens`
        IDepositToken _depositToken = pool_.depositTokenOf(vToken_);
        _depositToken.safeTransferFrom(msg.sender, address(this), amount_);

        // 2. Withdraw `vTokens` from `Synth`
        (uint256 _vTokenAmount, ) = _depositToken.withdraw(amount_, address(this));

        // 3. Withdraw `underlying` from `VPool`
        IERC20 _underlying = IERC20(vToken_.token());
        uint256 _balanceBefore = _underlying.balanceOf(address(this));
        vToken_.withdraw(_vTokenAmount);
        uint256 _underlyingAmount = _underlying.balanceOf(address(this)) - _balanceBefore;

        // 4. Transfer `underlying` to the `msg.sender`
        _underlying.safeTransfer(msg.sender, _underlyingAmount);
    }

    /// @inheritdoc TokenHolder
    // solhint-disable-next-line no-empty-blocks
    function _requireCanSweep() internal view override onlyGovernor {}
}
