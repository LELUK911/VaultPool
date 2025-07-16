// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyStMnt} from "./interfaces/IStrategy.sol";

/**
 * @title StableSwapSecurityExtensions
 * @notice Security mechanisms and MEV protection for the StableSwap protocol
 * @dev Provides locked profit degradation, rate limiting, and emergency controls
 * @author Your Team
 */
contract StableSwapSecurityExtensions {
    // =================================================================
    // CONSTANTS
    // =================================================================

    /// @notice Maximum coefficient for degradation calculations (100% in 18 decimals)
    uint256 public constant DEGRADATION_COEFFICIENT = 1e18;

    /// @notice Minimum cooldown period (5 minutes)
    uint256 public constant MIN_COOLDOWN = 5 minutes;

    /// @notice Maximum cooldown period (1 day)
    uint256 public constant MAX_COOLDOWN = 1 days;

    /// @notice Maximum loss threshold (10%)
    uint256 public constant MAX_LOSS_THRESHOLD = 1000;

    // =================================================================
    // STATE VARIABLES - SANITY CHECKS
    // =================================================================

    /// @notice Tracks the total virtual assets (physical + lent to strategy)
    /// @dev Used for sanity checks to ensure no funds are lost
    uint256 public totalVirtualAssets;

    /// @notice Maximum allowed loss per operation in basis points (default: 1%)
    /// @dev Prevents catastrophic losses from single operations
    uint256 internal maxLossThreshold = 100;

    /// @notice Minimum time between major operations to prevent flash loan attacks
    uint256 public cooldownPeriod = 1 hours;

    /// @notice Mapping of user addresses to their last operation timestamp
    mapping(address => uint256) public lastOperationTime;

    // =================================================================
    // STATE VARIABLES - LOCKED PROFIT DEGRADATION
    // =================================================================

    /// @notice Amount of profit currently locked and degrading over time
    /// @dev Gradually unlocked to prevent MEV/sandwich attacks
    uint256 public lockedProfit;

    /// @notice Timestamp of the last report from strategy
    uint256 public lastReport;

    /// @notice Rate at which locked profit degrades per second
    /// @dev Higher value = faster degradation. Default: ~6 hours to unlock fully
    uint256 public lockedProfitDegradation = 46e15;

    // =================================================================
    // STATE VARIABLES - EMERGENCY CONTROLS
    // =================================================================

    /// @notice Flag indicating if emergency shutdown is active
    bool internal emergencyShutdown = false;



    uint256 internal minGuaranteedTrade = 15000 ether; // Sempre permesso
    uint256 internal maxRelativeTradeSize = 2000; // 20% del balance
    uint256 internal maxAbsoluteTradeSize = 15000000 ether; // Hard cap per pool grandi

    // =================================================================
    // EVENTS
    // =================================================================

    /**
     * @notice Emitted when a sanity check fails
     * @param reason Description of the failed check
     * @param expected Expected value
     * @param actual Actual value
     */
    event SanityCheckFailed(string reason, uint256 expected, uint256 actual);

    /**
     * @notice Emitted when locked profit is updated
     * @param newLockedProfit New amount of locked profit
     * @param timestamp Current block timestamp
     */
    event LockedProfitUpdated(uint256 newLockedProfit, uint256 timestamp);

    /**
     * @notice Emitted when a security parameter is updated
     * @param parameter Name of the parameter
     * @param oldValue Previous value
     * @param newValue New value
     */
    event SecurityParameterUpdated(
        string parameter,
        uint256 oldValue,
        uint256 newValue
    );

    /**
     * @notice Emitted when an operation cooldown is triggered
     * @param user Address of the user
     * @param timestamp Current block timestamp
     */
    event OperationCooledDown(address user, uint256 timestamp);

    /**
     * @notice Emitted when emergency shutdown is activated
     * @param activated Whether emergency shutdown is activated
     */
    event EmergencyShutdown(bool activated);

    event BalanceDiscrepancyDetected(
        uint256 recorded0,
        uint256 actual0,
        uint256 recorded1,
        uint256 actual1
    );

    event BalancesSynced(uint256 newBalance0, uint256 newBalance1);

    // =================================================================
    // MODIFIERS
    // =================================================================

    /// @notice Prevents operations during cooldown period to mitigate flash loan attacks
    modifier rateLimited() {
        require(
            block.timestamp >= lastOperationTime[msg.sender] + cooldownPeriod,
            "Operation rate limited"
        );
        lastOperationTime[msg.sender] = block.timestamp;
        emit OperationCooledDown(msg.sender, block.timestamp);
        _;
    }

    /// @notice Only governance can call (implemented in inheriting contract)
    modifier onlyGovernance() virtual {
        _;
    }

    // =================================================================
    // CORE SECURITY FUNCTIONS
    // =================================================================

    /**
     * @notice Calculates the amount of locked profit that has degraded over time
     * @dev Uses linear degradation to prevent MEV/sandwich attacks on profit distribution
     * @return The amount of profit currently locked and not available for pricing
     */
    function _calculateLockedProfit() internal view returns (uint256) {
        uint256 timeSinceReport = block.timestamp - lastReport;
        uint256 degradationRate = timeSinceReport * lockedProfitDegradation;

        // If enough time has passed, all profit is unlocked
        if (degradationRate >= DEGRADATION_COEFFICIENT) {
            return 0;
        }

        // Calculate remaining locked ratio
        uint256 lockedFundsRatio = DEGRADATION_COEFFICIENT - degradationRate;
        return (lockedProfit * lockedFundsRatio) / DEGRADATION_COEFFICIENT;
    }

    /**
     * @notice Updates locked profit after strategy reports gains or losses
     * @dev Called when strategy reports to gradually unlock new profits
     * @param _gain Amount of gain reported by strategy
     * @param _loss Amount of loss reported by strategy
     */
    function _updateLockedProfit(uint256 _gain, uint256 _loss) internal {
        // Get current locked profit after degradation
        uint256 currentLocked = _calculateLockedProfit();

        if (_gain > 0) {
            // Add new profit to existing locked profit
            lockedProfit = currentLocked + _gain;
        } else if (_loss > 0) {
            // Losses reduce locked profit immediately for accurate pricing
            lockedProfit = currentLocked > _loss ? currentLocked - _loss : 0;
        } else {
            // No gain or loss, just update with current degraded amount
            lockedProfit = currentLocked;
        }

        lastReport = block.timestamp;
        emit LockedProfitUpdated(lockedProfit, block.timestamp);
    }

    // =================================================================
    // EMERGENCY FUNCTIONS
    // =================================================================

    /**
     * @notice Emergency function to halt all operations
     * @dev Sets emergency shutdown flag to pause protocol operations
     */
    function emergencyPause() external onlyGovernance {
        emergencyShutdown = true;
        emit EmergencyShutdown(true);
    }

    /**
     * @notice Resume operations after emergency shutdown
     * @dev Only governance can resume operations for safety
     */
    function emergencyResume() external onlyGovernance {
        emergencyShutdown = false;
        emit EmergencyShutdown(false);
    }

    // =================================================================
    // GOVERNANCE FUNCTIONS
    // =================================================================

    /**
     * @notice Updates the maximum allowed loss threshold per operation
     * @dev Helps prevent catastrophic losses from single operations
     * @param _newThreshold New threshold in basis points (100 = 1%, max 1000 = 10%)
     */
    function setMaxLossThreshold(
        uint256 _newThreshold
    ) external onlyGovernance {
        require(_newThreshold <= MAX_LOSS_THRESHOLD, "Threshold too high");
        uint256 oldThreshold = maxLossThreshold;
        maxLossThreshold = _newThreshold;
        emit SecurityParameterUpdated(
            "maxLossThreshold",
            oldThreshold,
            _newThreshold
        );
    }

    /**
     * @notice Updates the cooldown period between major operations
     * @dev Prevents rapid-fire operations that could be used in flash loan attacks
     * @param _newCooldown New cooldown period in seconds (min 5 minutes, max 1 day)
     */
    function setCooldownPeriod(uint256 _newCooldown) external onlyGovernance {
        require(_newCooldown <= MAX_COOLDOWN, "Cooldown too long");
        require(_newCooldown >= MIN_COOLDOWN, "Cooldown too short");
        uint256 oldCooldown = cooldownPeriod;
        cooldownPeriod = _newCooldown;
        emit SecurityParameterUpdated(
            "cooldownPeriod",
            oldCooldown,
            _newCooldown
        );
    }

    /**
     * @notice Updates the locked profit degradation rate
     * @dev Controls how quickly locked profit becomes available for pricing
     * @param _newDegradation New degradation rate per second (higher = faster unlock)
     */
    function setLockedProfitDegradation(
        uint256 _newDegradation
    ) external onlyGovernance {
        require(
            _newDegradation <= DEGRADATION_COEFFICIENT,
            "Degradation rate too high"
        );
        uint256 oldDegradation = lockedProfitDegradation;
        lockedProfitDegradation = _newDegradation;
        emit SecurityParameterUpdated(
            "lockedProfitDegradation",
            oldDegradation,
            _newDegradation
        );
    }

    // =================================================================
    // VIEW FUNCTIONS
    // =================================================================

    /**
     * @notice Returns the current amount of locked profit after degradation
     * @return Current locked profit amount
     */
    function getCurrentLockedProfit() external view returns (uint256) {
        return _calculateLockedProfit();
    }

    /**
     * @notice Returns the current maximum loss threshold
     * @return Maximum loss threshold in basis points
     */
    function getMaxLossThreshold() external view returns (uint256) {
        return maxLossThreshold;
    }

    /**
     * @notice Returns whether emergency shutdown is currently active
     * @return True if emergency shutdown is active
     */
    function isEmergencyShutdown() external view returns (bool) {
        return emergencyShutdown;
    }

    /**
     * @notice Calculates time remaining until a user can perform next operation
     * @param user Address of the user to check
     * @return Time remaining in seconds (0 if can operate now)
     */
    function getTimeUntilNextOperation(
        address user
    ) external view returns (uint256) {
        uint256 nextOperationTime = lastOperationTime[user] + cooldownPeriod;
        if (block.timestamp >= nextOperationTime) {
            return 0;
        }
        return nextOperationTime - block.timestamp;
    }

    /**
     * @notice Calculates the percentage of profit currently locked
     * @return Locked percentage in basis points (e.g., 5000 = 50%)
     */
    function getLockedProfitPercentage() external view returns (uint256) {
        if (lockedProfit == 0) {
            return 0;
        }
        uint256 currentLocked = _calculateLockedProfit();
        return (currentLocked * 10000) / lockedProfit;
    }

    /**
     * @notice Estimates when all locked profit will be fully degraded
     * @return Timestamp when locked profit reaches zero
     */
    function getFullUnlockTime() external view returns (uint256) {
        if (lockedProfit == 0 || lockedProfitDegradation == 0) {
            return block.timestamp;
        }

        uint256 currentLocked = _calculateLockedProfit();
        if (currentLocked == 0) {
            return block.timestamp;
        }

        // Calculate time needed to fully degrade current locked profit
        uint256 timeToUnlock = (currentLocked * DEGRADATION_COEFFICIENT) /
            (lockedProfit * lockedProfitDegradation);

        return block.timestamp + timeToUnlock;
    }

    // =================================================================
    // INTERNAL UTILITY FUNCTIONS
    // =================================================================

    /**
     * @notice Validates that a loss amount doesn't exceed the threshold
     * @dev Used internally to check operation safety
     * @param totalAssets Total assets before operation
     * @param loss Amount of loss from operation
     * @return True if loss is within acceptable threshold
     */
    function _isLossAcceptable(
        uint256 totalAssets,
        uint256 loss
    ) internal view returns (bool) {
        if (totalAssets == 0) {
            return loss == 0;
        }
        uint256 maxAllowedLoss = (totalAssets * maxLossThreshold) / 10000;
        return loss <= maxAllowedLoss;
    }

    /**
     * @notice Updates virtual assets tracking for sanity checks
     * @dev Should be called whenever assets are moved to/from strategy
     * @param newVirtualAssets New total virtual asset amount
     */
    function _updateVirtualAssets(uint256 newVirtualAssets) internal {
        totalVirtualAssets = newVirtualAssets;
    }
}
