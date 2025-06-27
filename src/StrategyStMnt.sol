// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStableSwap} from "./interfaces/IstableSwap.sol";

import {IVault} from "./interfaces/IVault.sol";

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
    /*
    function _requestMNTtoPool() private returns (uint256) {
        uint256 _poolWantBalance = pool.balances(0); // 0 è l'indice di wmnt
        uint256 _balanceInStrategy = pool.balanceInStrategy(0); // 0 è l'indice di wmnt

        //? CI SERVE SOLO IL 60 % DELLA LIQUIDITÀ TOTALE
        uint256 _amountToRequest = (_poolWantBalance +
            _balanceInStrategy *
            60) / 100;
        if (balanceMNTTGivenPool >= _amountToRequest) {
            _amountToRequest = 0; // Non abbiamo bisogno di richiedere nulla
        } else {
            _amountToRequest - balanceMNTTGivenPool;
        }

        IERC20(want).safeTransferFrom(
            address(pool),
            address(this),
            _amountToRequest
        );
        balanceMNTTGivenPool += _amountToRequest;
        //! qui dovro aggiornare questo valore anche nel contratto della pool
        return _amountToRequest;
    }*/

    uint256 private balanceSharesInVault;

    function _depositToVault() private returns (uint256) {
        uint256 _wantBalance = balanceWmnt();
        uint256 _shares = stVault.deposit(_wantBalance, address(this));
        balanceSharesInVault += _shares;
        return _shares;
    }



    function poolCallWithdraw(uint256 _amount) external returns (uint256) {
        uint256 _sharesWithdrawn = convertWmnttoStmnt(_amount);
        uint256 _wantOut = _withdrawFromVault(_sharesWithdrawn);
        require(_wantOut >= _amount, "Withdrawn amount is less than requested");
        return _wantOut;

    }

    function _withdrawFromVault(uint256 _shares) private returns (uint256) {
        require(_shares > 0, "Shares must be greater than zero");
        uint wantOut = stVault.withdraw(_shares, address(this), 0);
        balanceSharesInVault -= _shares;
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

    function _report() private returns (uint256) {
        //? Dobbiamo calcolare il profitto e le perdite
        uint256 _wantBalance = balanceWmnt();
        uint256 _stMntBalance = balanceStMnt();
        uint256 _wantInStMNt = convertStmntToWmnt(_stMntBalance);

        //? Calcolo del profitto e delle perdite
        uint256 _profit = (_wantBalance + _wantInStMNt) - balanceMNTTGivenPool;

        balanceMNTTGivenPool += _profit;

        //? Aggiorniamo i valori nel vault 
        //! ANCORA DA IMPLEMENTARE
        //pool.report(_profit, _loss, _shares);

        return _profit;
    }

    function harvest() external returns (uint256 _profit) {

        //? Poi depositiamo in vault
        _depositToVault();

        //? Infine facciamo il report
        _profit = _report();

        return _profit;
    }
}
