// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStableSwap} from "./interfaces/IstableSwap.sol";

import {IVault} from "./interfaces/IVault.sol";

import {console} from "forge-std/console.sol";

contract StrategyStMnt {
    using SafeERC20 for IERC20;

    address public immutable want;
    IVault public immutable stVault;
    //! PER ADESSO SOLO ADDRESS MA PENSO DOVRO CREARE UN INTERFACCIA
    IStableSwap public pool;

    constructor(address _want, address _stVault, address _pool) {
        require(_want != address(0), "Invalid wmnt address");
        require(_stVault != address(0), "Invalid stVault address");
        require(_pool != address(0), "Invalid pool address");
        want = _want;
        stVault = IVault(_stVault);
        pool = IStableSwap(_pool);
    }

    function balanceWmnt() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceStMnt() public view returns (uint256) {
        return stVault.balanceOf(address(this));
    }

    function updateUnlimitedSpendingPool(bool _approve) external {
        if (_approve) {
            IERC20(want).safeIncreaseAllowance(
                address(pool),
                type(uint256).max
            );
        } else {
            IERC20(want).approve(address(pool), 0);
        }
    }

    function updateUnlimitedSpendingVault(bool _approve) external {
        if (_approve) {
            IERC20(want).safeIncreaseAllowance(
                address(stVault),
                type(uint256).max
            );
        } else {
            IERC20(want).approve(address(stVault), 0);
        }
    }

    //! QUANTO ABBIAMO IN DEBITO DALLA POOL
    uint public balanceMNTTGivenPool;

    //?FUNZIONE PER PRENDERE MNT DAL POOL

    uint256 private balanceSharesInVault;

    function _depositToVault() private returns (uint256) {
        uint256 _wantBalance = balanceWmnt();
        if (_wantBalance == 0) {
            return 0; // Nothing to deposit
        }
        uint256 _shares = stVault.deposit(_wantBalance, address(this));
        balanceSharesInVault += _shares;
        return _shares;
    }

    function invest(uint256 _amountToLend) external {
        require(
            _amountToLend >= IERC20(want).balanceOf(address(this)),
            "Insufficient balance to lend"
        );
        balanceMNTTGivenPool += _amountToLend;
        _depositToVault();
    }

    function poolCallWithdraw(uint256 _amount) external returns (uint256) {

        uint256 _sharesWithdrawn = convertWmnttoStmnt(_amount);
        uint256 _wantOut = _withdrawFromVault(_sharesWithdrawn);
        require(_wantOut >= _amount, "Withdrawn amount is less than requested");
        IERC20(want).safeTransfer(address(pool), _wantOut);
        return _wantOut;
    }

    function _withdrawFromVault(uint256 _shares) private returns (uint256) {
        require(_shares > 0, "Shares must be greater than zero");
        uint256 potenziaWantOut = convertStmntToWmnt(_shares);
        balanceMNTTGivenPool -= potenziaWantOut;
        balanceSharesInVault -= _shares;
        uint wantOut = stVault.withdraw(_shares, address(this), 0);
        require(
            wantOut >= potenziaWantOut,
            "Withdrawn amount is less than requested"
        );

        return wantOut;
    }

    function convertStmntToWmnt(
        uint256 _amount
    ) private view returns (uint256) {
        uint256 _mntconverted = (stVault.pricePerShare() * _amount) / 1e18;
        return _mntconverted;
    }

    function convertWmnttoStmnt(
        uint256 _amount
    ) private view returns (uint256) {
        uint256 _stMntConverted = (_amount * 1e18) / stVault.pricePerShare();
        return _stMntConverted;
    }

    uint24 public boostFee = 3000; // 30% di boost fee

    function setBoostFee(uint24 _boostFee) external {
        require(_boostFee <= 10000, "Boost fee cannot exceed 100%");
        boostFee = _boostFee;
    }

    address public stMntStrategy;

    function setStMntStrategy(address _stMntStrategy) external {
        require(_stMntStrategy != address(0), "Invalid stMnt strategy address");
        stMntStrategy = _stMntStrategy;
    }

    function claimBoostFee(uint256 _profit) private returns (uint256) {
        //? Calcoliamo il boost fee
        uint256 _boostFee = (_profit * boostFee) / 10000;
        require(_boostFee <= _profit, "Boost fee exceeds profit");
        //? Dobbiamo inviare il boost fee al vault

        //! devo prima prelevare sti fondi dal vault
        uint256 _sharesToWithdraw = convertWmnttoStmnt(_boostFee);
        uint256 _wantOut = _withdrawFromVault(_sharesToWithdraw);
        require(
            _wantOut >= (_boostFee * 9999) / 10000,
            "Withdrawn amount is less than boost fee"
        );


        IERC20(want).safeTransfer(address(stVault), _boostFee - 1);
        return _boostFee;
    }

    function _report() private returns (uint256 _profit, uint256 _loss) {
        //? Dobbiamo calcolare il profitto e le perdite
        uint256 _wantBalance = balanceWmnt();
        uint256 _stMntBalance = balanceStMnt();
        uint256 _wantInStMNt = convertStmntToWmnt(_stMntBalance);
        uint256 _boostFee = 0;

        //? Calcolo del profitto e delle perdite
        if (balanceMNTTGivenPool > _wantBalance + _wantInStMNt) {
            _loss = balanceMNTTGivenPool - (_wantBalance + _wantInStMNt);
            require(_loss <= balanceMNTTGivenPool, "Loss exceeds pool balance");
            balanceMNTTGivenPool -= _loss;
        } else {
            _profit = (_wantBalance + _wantInStMNt) - balanceMNTTGivenPool;
            _boostFee = claimBoostFee(_profit); //! qui inviamo le boost fee al vault
            require(_boostFee <= _profit, "Boost fee exceeds profit");
            _profit -= _boostFee; //? Sottraiamo il boost fee dal profitto
            balanceMNTTGivenPool += _profit;
        }

        //? mettiamo qui la logica per portare i profitti nell vault come boost

        //? Aggiorniamo i valori nel vault
        pool.report(_profit, _loss, balanceMNTTGivenPool);
    }

    function harvest() external returns (uint256 _profit, uint256 _loss) {
        //? Poi depositiamo in vault
        _depositToVault();

        //? Infine facciamo il report
        (_profit, _loss) = _report();

    }

    function estimatedTotalAssets() external view returns (uint256) {
        uint256 _wantBalance = balanceWmnt();
        uint256 _stMntBalance = balanceStMnt();
        uint256 _wantInStMNt = convertStmntToWmnt(_stMntBalance);
        return _wantBalance + _wantInStMNt + balanceMNTTGivenPool;
    }
}
