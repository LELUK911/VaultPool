// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IStableSwap} from "./interfaces/IstableSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";

contract IntelliSwap {
    IStableSwap private vaultSwap;
    IVault private stMNT;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_ITERATIONS = 20;
    uint256 private constant CONVERGENCE_THRESHOLD = 1e12; // 0.000001 precision

    uint16 private optimizeFee ;

    constructor(address _vSwap, address _stMNT) {
        vaultSwap = IStableSwap(_vSwap);
        stMNT = IVault(_stMNT);
    }

    function setOptimizeFee(uint16 _fee) external {
        optimizeFee = _fee;
    }

    function _previewSwap(
        uint256 _amount
    )
        internal
        view
        returns (uint256 _amountOut, uint256 fee, uint256 priceImpact)
    {
        (_amountOut, fee, priceImpact) = vaultSwap.previewSwap(0, 1, _amount);
    }

    function _previewStake(
        uint256 _amount
    ) internal view returns (uint256 _amountOut) {
        uint256 priceShare = stMNT.pricePerShare();
        _amountOut = _amount / priceShare;
    }

    function _previewHybrid(
        uint256 _amount
    )
        public
        view
        returns (
            uint256 amountOut,
            uint256 swapAmount,
            uint256 stakeAmount,
            uint256 swapOutput,
            uint256 stakeOutput
        )
    {
        // First, check edge cases
        if (_amount == 0) return (0, 0, 0, 0, 0);

        // Get outputs for full swap and full stake
        (uint256 fullSwapOut, , ) = _previewSwap(_amount);
        uint256 fullStakeOut = _previewStake(_amount);

        // If staking is always better, stake everything
        if (fullStakeOut >= fullSwapOut) {
            return (fullStakeOut, 0, _amount, 0, fullStakeOut);
        }

        // Binary search for optimal split
        uint256 left = 0;
        uint256 right = _amount;
        uint256 optimalSwap = 0;
        uint256 maxOutput = 0;

        // Use binary search to find optimal split
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            uint256 mid = (left + right) / 2;

            // Calculate outputs for this split
            (uint256 swapOut, , ) = mid > 0 ? _previewSwap(mid) : (0, 0, 0);
            uint256 stakeOut = (_amount - mid) > 0
                ? _previewStake(_amount - mid)
                : 0;
            uint256 totalOut = swapOut + stakeOut;

            // Check if we found a better split
            if (totalOut > maxOutput) {
                maxOutput = totalOut;
                optimalSwap = mid;
                swapOutput = swapOut;
                stakeOutput = stakeOut;
            }

            // Calculate marginal rates to determine search direction
            uint256 swapDelta = 1e15; // Small amount for derivative approximation

            // Marginal output from swapping a bit more
            (uint256 swapOutPlus, , ) = _previewSwap(mid + swapDelta);
            uint256 marginalSwap = swapOutPlus > swapOut
                ? ((swapOutPlus - swapOut) * PRECISION) / swapDelta
                : 0;

            // Marginal output from staking (constant rate)
            uint256 marginalStake = (PRECISION * PRECISION) /
                stMNT.pricePerShare();

            // Adjust search range based on marginal rates
            if (marginalSwap > marginalStake) {
                left = mid + 1;
            } else {
                right = mid;
            }

            // Check for convergence
            if (right - left <= CONVERGENCE_THRESHOLD) {
                break;
            }
        }

        swapAmount = optimalSwap;
        stakeAmount = _amount - optimalSwap;
        amountOut = maxOutput;
    }

    //? L'INTERFACCIA PUO FARE LA SIMULAZIONE  E LA FUNZIONE DEVE RESTITUIRE
    //? 1. SOLO SWAP, 2. SOLO stMNT , 3. SOLUZIONE IBRIDA

    function previewOptimizerSwap(
        uint256 _amount
    ) external view returns (uint256 _swap, uint256 _stMNT, uint256 _hybrid) {
        (_swap, , ) = _previewSwap(_amount);
        _stMNT = _previewStake(_amount);
        (_hybrid, , , , ) = _previewHybrid(_amount);
    }

    function executeHybridSwap(
        uint256 amountOut,
        uint256 swapAmount,
        uint256 stakeAmount,
        uint256 swapOutput,
        uint256 stakeOutput
    ) external returns (uint256 _amountOut) {

        uint256 _stSwapOut = vaultSwap.swap(0,1,swapAmount,((swapOutput*9999)/10000));
        uint256 _stStakeOut = stMNT.deposit(stakeAmount,address(this));
        require(_stSwapOut == ((stakeOutput*9999)/10000), "stake Slipage is higer");

        






    }
}
