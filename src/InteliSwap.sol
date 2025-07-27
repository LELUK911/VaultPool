// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {console} from "forge-std/console.sol";

import {IStableSwap} from "./interfaces/IstableSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// =================================================================
// CUSTOM ERRORS
// =================================================================
error AddressIncorrect();
error AmountZero();
error InsufficientOutput(uint256 received, uint256 minimum);
error SlippageTooHigh(uint256 expected, uint256 received);
error InsufficientFeeBalance(uint256 available, uint256 required);
error FeeTooHigh(uint256 fee, uint256 maxFee);
error RoundingError();

/**
 * @title IntelliSwap
 * @author Your Name
 * @notice Intelligent swap optimizer that automatically chooses between swapping MNT->stMNT
 *         via StableSwap or direct staking, or an optimal hybrid approach
 * @dev Uses binary search algorithm to find optimal split between swap and stake operations
 * @custom:security-contact security@yourproject.com
 */
contract IntelliSwap is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // =================================================================
    //  STATE VARIABLES
    // =================================================================

    /// @notice StableSwap pool for MNT/stMNT trading
    IStableSwap private immutable vaultSwap;

    /// @notice stMNT vault for direct staking
    IVault private immutable stMNT;

    /// @notice Strategy boost contract address (receives 80% of fees)
    address private strategyBoost;

    /// @notice Treasury address (receives 20% of fees)
    address private treasury;

    /// @notice Wrapped MNT token contract
    IERC20 private immutable WMNT =
        IERC20(0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8);

    /// @notice Precision for calculations (18 decimals)
    uint256 private constant PRECISION = 1e18;

    /// @notice Maximum iterations for binary search optimization
    uint256 private constant MAX_ITERATIONS = 20;

    /// @notice Convergence threshold for binary search (0.000001 precision)
    uint256 private constant CONVERGENCE_THRESHOLD = 1e12;

    /// @notice Maximum allowed optimization fee (10% = 1000 basis points)
    uint256 private constant MAX_OPTIMIZE_FEE = 1000;

    /// @notice Fee charged for optimization service (in basis points, 100 = 1%)
    uint16 private optimizeFee;

    /// @notice Accumulated fees available for collection
    uint256 private balanceFee;

    uint256 private balanceFeeStMNT;

    // =================================================================
    //  ACCESS CONTROL ROLES
    // =================================================================

    /// @notice Default admin role - can grant/revoke all other roles
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /// @notice Treasury admin role - can update fees and strategy parameters
    bytes32 public constant TREASURY_ADMIN = keccak256("TREASURY_ADMIN");

    /// @notice Guardian role - can pause/unpause operations for emergency response
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // =================================================================
    //  EVENTS
    // =================================================================

    /**
     * @notice Emitted when a hybrid swap is executed
     * @param user Address of the user executing the swap
     * @param inputAmount Total MNT amount provided
     * @param outputAmount Total stMNT amount received (after fees)
     * @param swapAmount Amount sent to StableSwap
     * @param stakeAmount Amount sent to direct staking
     * @param feeAmount Fee charged for optimization
     */
    event HybridSwapExecuted(
        address indexed user,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 swapAmount,
        uint256 stakeAmount,
        uint256 feeAmount
    );

    /**
     * @notice Emitted when optimization parameters are updated
     * @param swapAmount Optimal amount for swap operation
     * @param stakeAmount Optimal amount for stake operation
     * @param expectedOutput Expected total output from hybrid approach
     */
    event OptimizationCalculated(
        uint256 swapAmount,
        uint256 stakeAmount,
        uint256 expectedOutput
    );

    /**
     * @notice Emitted when fees are collected
     * @param strategyAmount Amount sent to strategy boost (80%)
     * @param treasuryAmount Amount sent to treasury (20%)
     * @param totalCollected Total fees collected
     */
    event FeesCollected(
        uint256 strategyAmount,
        uint256 treasuryAmount,
        uint256 totalCollected
    );

    /**
     * @notice Emitted when strategy boost address is updated
     * @param oldStrategy Previous strategy address
     * @param newStrategy New strategy address
     */
    event StrategyBoostUpdated(
        address indexed oldStrategy,
        address indexed newStrategy
    );

    /**
     * @notice Emitted when treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /**
     * @notice Emitted when optimization fee is updated
     * @param oldFee Previous fee in basis points
     * @param newFee New fee in basis points
     */
    event OptimizeFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Emitted when contract is paused
     * @param pauser Address that triggered the pause
     */
    event ContractPaused(address indexed pauser);

    /**
     * @notice Emitted when contract is unpaused
     * @param unpauser Address that triggered the unpause
     */
    event ContractUnpaused(address indexed unpauser);

    // =================================================================
    //  CONSTRUCTOR
    // =================================================================

    /**
     * @notice Initialize the IntelliSwap contract
     * @param _vSwap Address of the StableSwap pool contract
     * @param _stMNT Address of the stMNT vault contract
     * @param _admin Address to receive admin role
     * @param _treasuryAdm Address to receive treasury admin role
     * @param _guardianRole Address to receive guardian role
     */
    constructor(
        address _vSwap,
        address _stMNT,
        address _admin,
        address _treasuryAdm,
        address _guardianRole
    ) {
        if (
            _vSwap == address(0) ||
            _stMNT == address(0) ||
            _admin == address(0) ||
            _treasuryAdm == address(0) ||
            _guardianRole == address(0)
        ) {
            revert AddressIncorrect();
        }

        vaultSwap = IStableSwap(_vSwap);
        stMNT = IVault(_stMNT);

        // Grant roles
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(TREASURY_ADMIN, _treasuryAdm);
        _grantRole(GUARDIAN_ROLE, _guardianRole);

        // Set role admins
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURY_ADMIN, ADMIN_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);

        emit ContractUnpaused(_admin);
    }

    // =================================================================
    //  ACCESS CONTROL MODIFIERS
    // =================================================================

    /// @notice Only admin can call
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) {
            revert AddressIncorrect();
        }
        _;
    }

    /// @notice Only guardian or admin can call
    modifier onlyGuardian() {
        if (
            !hasRole(GUARDIAN_ROLE, msg.sender) &&
            !hasRole(ADMIN_ROLE, msg.sender)
        ) {
            revert AddressIncorrect();
        }
        _;
    }

    /// @notice Only treasury admin can call
    modifier onlyTreasury() {
        if (!hasRole(TREASURY_ADMIN, msg.sender)) {
            revert AddressIncorrect();
        }
        _;
    }

    // =================================================================
    //  EMERGENCY FUNCTIONS
    // =================================================================

    /**
     * @notice Pause all contract operations in case of emergency
     * @dev Can only be called by guardian or admin
     */
    function pause() external onlyGuardian {
        _pause();
        emit ContractPaused(msg.sender);
    }

    /**
     * @notice Resume contract operations after emergency
     * @dev Can only be called by guardian or admin
     */
    function unpause() external onlyGuardian {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    // =================================================================
    // ⚙️ CONFIGURATION FUNCTIONS
    // =================================================================

    /**
     * @notice Update the strategy boost contract address
     * @param _strategyBoost New strategy boost contract address
     * @dev Strategy boost receives 80% of collected fees
     */
    function setStrategyBoost(address _strategyBoost) external onlyTreasury {
        if (_strategyBoost == address(0)) {
            revert AddressIncorrect();
        }

        address oldStrategy = strategyBoost;
        strategyBoost = _strategyBoost;

        emit StrategyBoostUpdated(oldStrategy, _strategyBoost);
    }

    /**
     * @notice Update the optimization fee charged to users
     * @param _fee New fee in basis points (100 = 1%, max 1000 = 10%)
     * @dev Fee is charged on the output amount for optimization service
     */
    function setOptimizeFee(uint16 _fee) external onlyTreasury {
        if (_fee == 0) {
            revert AmountZero();
        }
        if (_fee > MAX_OPTIMIZE_FEE) {
            revert FeeTooHigh(_fee, MAX_OPTIMIZE_FEE);
        }

        uint256 oldFee = optimizeFee;
        optimizeFee = _fee;

        emit OptimizeFeeUpdated(oldFee, _fee);
    }

    /**
     * @notice Update the treasury address
     * @param _treasury New treasury address
     * @dev Treasury receives 20% of collected fees
     */
    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) {
            revert AddressIncorrect();
        }

        address oldTreasury = treasury;
        treasury = _treasury;

        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    // =================================================================
    //  PREVIEW FUNCTIONS (VIEW ONLY)
    // =================================================================

    /**
     * @notice Preview output from StableSwap operation
     * @param _amount Amount of MNT to swap
     * @return _amountOut Expected stMNT output
     * @return fee Swap fee charged by StableSwap
     * @return priceImpact Price impact of the swap
     */
    function _previewSwapIn(
        uint256 _amount
    )
        internal
        view
        returns (uint256 _amountOut, uint256 fee, uint256 priceImpact)
    {
        (_amountOut, fee, priceImpact) = vaultSwap.previewSwap(0, 1, _amount);
    }

    function _previewSwapOut(
        uint256 _amount
    )
        internal
        view
        returns (uint256 _amountOut, uint256 fee, uint256 priceImpact)
    {
        (_amountOut, fee, priceImpact) = vaultSwap.previewSwap(1, 0, _amount);
    }

    /**
     * @notice Preview output from direct staking operation
     * @param _amount Amount of MNT to stake
     * @return _amountOut Expected stMNT shares
     */
    function _previewStake(
        uint256 _amount
    ) internal view returns (uint256 _amountOut) {
        uint256 priceShare = stMNT.pricePerShare();
        _amountOut = (_amount * PRECISION) / priceShare;
    }

    function _previewUnStake(
        uint256 _amount
    ) internal view returns (uint256 _amountOut) {
        uint256 priceShare = stMNT.pricePerShare();
        _amountOut = (_amount * priceShare) / PRECISION;
    }

    /**
     * @notice Calculate optimal hybrid approach using binary search
     * @param _amount Total amount of MNT to convert
     * @return amountOut Total expected stMNT output
     * @return swapAmount Optimal amount to send to StableSwap
     * @return stakeAmount Optimal amount to send to direct staking
     * @return swapOutput Expected output from swap portion
     * @return stakeOutput Expected output from stake portion
     * @dev Uses binary search to find the split that maximizes total output
     */
    function _previewHybridIn(
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
        // Handle edge case
        if (_amount == 0) return (0, 0, 0, 0, 0);

        // Get outputs for full swap and full stake
        (uint256 fullSwapOut, , ) = _previewSwapIn(_amount);
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

        // Binary search algorithm
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            uint256 mid = (left + right) / 2;

            // Calculate outputs for this split
            (uint256 swapOut, , ) = mid > 0 ? _previewSwapIn(mid) : (0, 0, 0);
            uint256 stakeOut = (_amount - mid) > 0
                ? _previewStake(_amount - mid)
                : 0;
            uint256 totalOut = swapOut + stakeOut;

            // Update best result if this is better
            if (totalOut > maxOutput) {
                maxOutput = totalOut;
                optimalSwap = mid;
                swapOutput = swapOut;
                stakeOutput = stakeOut;
            }

            // Calculate marginal rates for search direction
            uint256 swapDelta = 1e15; // Small amount for derivative approximation

            // Marginal output from swapping more
            (uint256 swapOutPlus, , ) = _previewSwapIn(mid + swapDelta);
            uint256 marginalSwap = swapOutPlus > swapOut
                ? ((swapOutPlus - swapOut) * PRECISION) / swapDelta
                : 0;

            // Marginal output from staking (constant rate)
            uint256 marginalStake = (PRECISION * PRECISION) /
                stMNT.pricePerShare();

            // Adjust search range
            if (marginalSwap > marginalStake) {
                left = mid + 1;
            } else {
                right = mid;
            }

            // Check convergence
            if (right - left <= CONVERGENCE_THRESHOLD) {
                break;
            }
        }

        swapAmount = optimalSwap;
        stakeAmount = _amount - optimalSwap;
        amountOut = maxOutput;
    }

    /**
     * @notice Calculate optimal hybrid approach using binary search for unstaking
     * @param _amount Total amount of stMNT to convert
     * @return amountOut Total expected MNT output
     * @return swapAmount Optimal amount to send to StableSwap
     * @return unstakeAmount Optimal amount to send to direct unstaking
     * @return swapOutput Expected output from swap portion
     * @return unstakeOutput Expected output from unstake portion
     * @dev Uses binary search to find the split that maximizes total output
     */
   function _previewHybridOut(uint256 _amount)
    public
    view
    returns (
        uint256 amountOut,
        uint256 swapAmount,
        uint256 unstakeAmount,
        uint256 swapOutput,
        uint256 unstakeOutput
    )
{
    if (_amount == 0) return (0, 0, 0, 0, 0);

    (uint256 fullSwapOut, , ) = _previewSwapOut(_amount);
    uint256 fullUnstakeOut = _previewUnStake(_amount);

    // Se la differenza è minima, usa il migliore direttamente
    if (fullUnstakeOut >= fullSwapOut) {
        return (fullUnstakeOut, 0, _amount, 0, fullUnstakeOut);
    }

    uint256 left = 0;
    uint256 right = _amount;
    uint256 optimalSwap = _amount;  // 🚨 FIX: Start with pure swap as baseline
    uint256 maxOutput = fullSwapOut;
    uint256 bestSwapOutput = fullSwapOut;
    uint256 bestUnstakeOutput = 0;

    for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
        uint256 mid = (left + right) / 2;

        (uint256 swapOut, , ) = mid > 0 ? _previewSwapOut(mid) : (0, 0, 0);
        uint256 unstakeOut = (_amount - mid) > 0 ? _previewUnStake(_amount - mid) : 0;
        uint256 totalOut = swapOut + unstakeOut;

        if (totalOut > maxOutput) {
            maxOutput = totalOut;
            optimalSwap = mid;
            bestSwapOutput = swapOut;
            bestUnstakeOutput = unstakeOut;
        }

        // Edge case protection
        if (mid + 1e15 > _amount) break;

        uint256 swapDelta = 1e15;
        (uint256 swapOutPlus, , ) = _previewSwapOut(mid + swapDelta);
        uint256 marginalSwap = swapOutPlus > swapOut
            ? ((swapOutPlus - swapOut) * PRECISION) / swapDelta
            : 0;

        uint256 marginalUnstake = stMNT.pricePerShare();

        if (marginalSwap > marginalUnstake) {
            left = mid + 1;
        } else {
            right = mid;
        }

        if (right - left <= CONVERGENCE_THRESHOLD) break;
    }

    swapAmount = optimalSwap;
    unstakeAmount = _amount - optimalSwap;
    swapOutput = bestSwapOutput;
    unstakeOutput = bestUnstakeOutput;
    amountOut = maxOutput;
}

    /**
     * @notice Calculate and accumulate optimization fee
     * @param _amount Amount to calculate fee on
     * @return _fee Fee amount calculated
     */
    function _takeFee(
        uint256 _amount,
        bool _in
    ) internal returns (uint256 _fee) {
        _fee = (_amount * optimizeFee) / 10000;
        if (_in) {
            balanceFeeStMNT += _fee;
        } else {
            balanceFee += _fee;
        }
    }

    /**
     * @notice Preview all available conversion methods
     * @param _amount Amount of MNT to convert
     * @return _swap Expected output from pure swap
     * @return _stMNT Expected output from pure staking
     * @return _hybrid Expected output from optimal hybrid approach
     * @dev Use this to compare all methods before executing
     */
    function previewOptimizerSwapIn(
        uint256 _amount
    ) external view returns (uint256 _swap, uint256 _stMNT, uint256 _hybrid) {
        (_swap, , ) = _previewSwapIn(_amount);
        _stMNT = _previewStake(_amount);
        (_hybrid, , , , ) = _previewHybridIn(_amount);
    }

    function previewOptimizerSwapOut(
        uint256 _amount
    ) external view returns (uint256 _swap, uint256 _wmnt, uint256 _hybrid) {
        (_swap, , ) = _previewSwapOut(_amount);
        _wmnt = _previewUnStake(_amount);
        (_hybrid, , , , ) = _previewHybridOut(_amount);
    }

    // =================================================================
    //  MAIN EXECUTION FUNCTION
    // =================================================================

    /**
     * @notice Execute optimized hybrid swap operation
     * @param minOut Minimum acceptable stMNT output (slippage protection)
     * @param swapAmount Amount to send to StableSwap (from previewHybrid)
     * @param stakeAmount Amount to send to direct staking (from previewHybrid)
     * @param swapOutput Expected output from swap (for validation)
     * @param stakeOutput Expected output from stake (for validation)
     * @return _amountOut Actual stMNT amount received (after fees)
     * @dev User should call previewHybrid first to get optimal parameters
     */
    function executeHybridSwapIn(
        uint256 minOut,
        uint256 swapAmount,
        uint256 stakeAmount,
        uint256 swapOutput,
        uint256 stakeOutput
    ) external nonReentrant whenNotPaused returns (uint256 _amountOut) {
        uint256 totalInput = swapAmount + stakeAmount;

        if (totalInput == 0) {
            revert AmountZero();
        }

        // Transfer input tokens from user
        WMNT.safeTransferFrom(msg.sender, address(this), totalInput);

        uint256 actualSwapOut = 0;
        uint256 actualStakeOut = 0;

        // Execute swap portion if applicable
        if (swapAmount > 0) {
            // Approve StableSwap to spend WMNT
            WMNT.safeIncreaseAllowance(address(vaultSwap), swapAmount);

            // Execute swap with 0.01% slippage tolerance
            actualSwapOut = vaultSwap.swap(
                0,
                1,
                swapAmount,
                (swapOutput * 9999) / 10000
            );
        }

        // Execute stake portion if applicable
        if (stakeAmount > 0) {
            // Approve stMNT vault to spend WMNT
            WMNT.safeIncreaseAllowance(address(stMNT), stakeAmount);

            // Execute direct staking
            actualStakeOut = stMNT.deposit(stakeAmount, address(this));

            // Validate staking output (0.01% slippage tolerance)
            if (actualStakeOut < (stakeOutput * 9950) / 10000) {
                revert SlippageTooHigh(stakeOutput, actualStakeOut);
            }
        }

        // Calculate total output before fees
        uint256 totalOutput = actualSwapOut + actualStakeOut;

        // Calculate and deduct optimization fee
        uint256 feeAmount = _takeFee(totalOutput, true);
        _amountOut = totalOutput - feeAmount;

        // Validate minimum output requirement
        if (_amountOut < minOut) {
            revert InsufficientOutput(_amountOut, minOut);
        }

        // Transfer result to user
        stMNT.transfer(msg.sender, _amountOut);

        emit HybridSwapExecuted(
            msg.sender,
            totalInput,
            _amountOut,
            swapAmount,
            stakeAmount,
            feeAmount
        );

        emit OptimizationCalculated(swapAmount, stakeAmount, totalOutput);
    }

    function executeHybridSwapOut(
        uint256 minOut,
        uint256 swapAmount,
        uint256 unStakeAmount,
        uint256 swapOutput,
        uint256 stakeOutput
    ) external nonReentrant whenNotPaused returns (uint256 _amountOut) {
        uint256 totalInput = swapAmount + unStakeAmount;

        if (totalInput == 0) {
            revert AmountZero();
        }

        // Transfer input tokens from user
        stMNT.transferFrom(msg.sender, address(this), totalInput);

        uint256 actualSwapOut = 0;
        uint256 actualStakeOut = 0;

        // Execute swap portion if applicable
        if (swapAmount > 0) {
            stMNT.approve(address(vaultSwap), swapAmount);
            actualSwapOut = vaultSwap.swap(
                1,
                0,
                swapAmount,
                (swapOutput * 9999) / 10000
            );
        }

        // Execute unstake portion if applicable
        if (unStakeAmount > 0) {
            actualStakeOut = stMNT.withdraw(unStakeAmount, address(this), 0);

            console.log("actualStakeOut -> ", actualStakeOut);
            console.log("stakeOutput -> ", stakeOutput);

            if (actualStakeOut < (stakeOutput * 9950) / 10000) {
                revert SlippageTooHigh(stakeOutput, actualStakeOut);
            }
        }

        // Calculate total output before fees
        uint256 totalOutput = actualSwapOut + actualStakeOut;

        // Calculate and deduct optimization fee
        uint256 feeAmount = _takeFee(totalOutput, false);
        _amountOut = totalOutput - feeAmount;

        // Validate minimum output requirement
        if (_amountOut < minOut) {
            revert InsufficientOutput(_amountOut, minOut);
        }

        WMNT.safeTransfer(msg.sender, _amountOut);

        emit HybridSwapExecuted(
            msg.sender,
            totalInput,
            _amountOut,
            swapAmount,
            unStakeAmount,
            feeAmount
        );

        emit OptimizationCalculated(swapAmount, unStakeAmount, totalOutput);
    }

    // =================================================================
    //  FEE MANAGEMENT
    // =================================================================

    /**
     * @notice Collect accumulated optimization fees
     * @dev Distributes 80% to strategy boost and 20% to treasury
     * @dev Can only be called by treasury admin
     */
    function collectFee() external onlyTreasury {
        uint256 _balanceFeeStMNT = balanceFeeStMNT;
        if (_balanceFeeStMNT > 0) {
            balanceFeeStMNT = 0;
            uint256 amountOut = stMNT.withdraw(
                _balanceFeeStMNT,
                address(this),
                (_balanceFeeStMNT * 9999) / 10000
            );
            balanceFee += amountOut;
        }

        uint256 totalFees = balanceFee;
        if (totalFees == 0) {
            revert AmountZero();
        }
        uint256 _feeBoost = (totalFees * 8000) / 10000; // 80%
        uint256 _feeManagement = (totalFees * 2000) / 10000; // 20%

        // Validate calculation (should never fail, but safety check)
        if (_feeBoost + _feeManagement > totalFees) {
            revert RoundingError();
        }

        // Reset fee balance
        balanceFee = 0;

        // Distribute fees
        if (_feeBoost > 0 && strategyBoost != address(0)) {
            WMNT.safeTransfer(strategyBoost, _feeBoost);
        }

        if (_feeManagement > 0 && treasury != address(0)) {
            WMNT.safeTransfer(treasury, _feeManagement);
        }

        emit FeesCollected(_feeBoost, _feeManagement, totalFees);
    }

    // =================================================================
    //  VIEW FUNCTIONS
    // =================================================================

    /**
     * @notice Get current optimization fee rate
     * @return Fee in basis points (100 = 1%)
     */
    function getOptimizeFee() external view returns (uint16) {
        return optimizeFee;
    }

    /**
     * @notice Get current accumulated fee balance
     * @return Amount of fees ready for collection
     */
    function getBalanceFee() external view returns (uint256) {
        return balanceFee;
    }

    function getBalanceFeeStMNT() external view returns (uint256) {
        return balanceFeeStMNT;
    }

    /**
     * @notice Get strategy boost contract address
     * @return Address of strategy boost contract
     */
    function getStrategyBoost() external view returns (address) {
        return strategyBoost;
    }

    /**
     * @notice Get treasury address
     * @return Address of treasury
     */
    function getTreasury() external view returns (address) {
        return treasury;
    }

    /**
     * @notice Get StableSwap pool address
     * @return Address of StableSwap pool
     */
    function getVaultSwap() external view returns (address) {
        return address(vaultSwap);
    }

    /**
     * @notice Get stMNT vault address
     * @return Address of stMNT vault
     */
    function getStMNT() external view returns (address) {
        return address(stMNT);
    }
}
