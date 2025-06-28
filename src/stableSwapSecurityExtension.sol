// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// ================================
// SECURITY MECHANISMS TO ADD TO STABLESWAP
// ================================

contract StableSwapSecurityExtensions {
    // =================================================================
    // SANITY CHECK VARIABLES
    // =================================================================

    /// @notice Tracks the total virtual assets (physical + lent to strategy)
    /// @dev Used for sanity checks to ensure no funds are lost
    uint256 public totalVirtualAssets;

    /// @notice Maximum allowed loss per operation (in basis points)
    /// @dev Default: 100 = 1%, prevents catastrophic losses
    uint256 public maxLossThreshold = 100; // 1%

    /// @notice Minimum time between major operations to prevent flash loan attacks
    uint256 public cooldownPeriod = 1 hours;

    /// @notice Last time a major operation was performed
    mapping(address => uint256) public lastOperationTime;

    // =================================================================
    // LOCKED PROFIT DEGRADATION (Anti-Sandwich/MEV Protection)
    // =================================================================

    /// @notice Amount of profit currently locked and degrading over time
    uint256 public lockedProfit;

    /// @notice Timestamp of the last report from strategy
    uint256 public lastReport;

    /// @notice Rate at which locked profit degrades (per second)
    /// @dev Higher = faster degradation. Default: ~6 hours to unlock fully
    uint256 public lockedProfitDegradation = 46e15; // ~6 hours degradation

    /// @notice Maximum coefficient for degradation calculations
    uint256 public constant DEGRADATION_COEFFICIENT = 1e18;

    // =================================================================
    // EVENTS FOR MONITORING
    // =================================================================

    event SanityCheckFailed(string reason, uint256 expected, uint256 actual);
    event LockedProfitUpdated(uint256 newLockedProfit, uint256 timestamp);
    event SecurityParameterUpdated(
        string parameter,
        uint256 oldValue,
        uint256 newValue
    );
    event OperationCooledDown(address user, uint256 timestamp);

    // =================================================================
    // MODIFIERS
    // =================================================================

    /// @notice Prevents operations during cooldown period
    modifier rateLimited() {
        require(
            block.timestamp >= lastOperationTime[msg.sender] + cooldownPeriod,
            "Operation rate limited"
        );
        lastOperationTime[msg.sender] = block.timestamp;
        _;
    }

    /// @notice Validates balance changes don't exceed loss threshold
    modifier sanityCheck() {
        uint256 balanceBefore = _totalAssets();
        _;
        uint256 balanceAfter = _totalAssets();

        if (balanceAfter < balanceBefore) {
            uint256 loss = balanceBefore - balanceAfter;
            uint256 maxAllowedLoss = (balanceBefore * maxLossThreshold) / 10000;
            require(loss <= maxAllowedLoss, "Loss exceeds threshold");
        }
    }

    // =================================================================
    // CORE SECURITY FUNCTIONS
    // =================================================================

    /**
     * @notice Calculates the amount of locked profit that has degraded
     * @dev Uses linear degradation over time to prevent MEV/sandwich attacks
     * @return The amount of profit currently locked (not available for withdrawal)
     */
    function _calculateLockedProfit() internal view returns (uint256) {
        uint256 timeSinceReport = block.timestamp - lastReport;
        uint256 degradationRate = timeSinceReport * lockedProfitDegradation;

        if (degradationRate >= DEGRADATION_COEFFICIENT) {
            return 0; // Fully degraded
        }

        uint256 lockedFundsRatio = DEGRADATION_COEFFICIENT - degradationRate;
        return (lockedProfit * lockedFundsRatio) / DEGRADATION_COEFFICIENT;
    }

    /**
     * @notice Returns free funds available for operations (total - locked profit)
     * @dev This is used instead of raw totalAssets for pricing calculations
     * @return Available funds considering locked profit degradation
     */
    function _freeFunds() internal view returns (uint256) {
        uint256 total = _totalAssets();
        uint256 locked = _calculateLockedProfit();
        return total > locked ? total - locked : 0;
    }

    /**
     * @notice Updates locked profit after strategy reports
     * @dev Called when strategy reports gains to gradually unlock them
     * @param _gain Amount of gain reported by strategy
     * @param _loss Amount of loss reported by strategy
     */
    function _updateLockedProfit(uint256 _gain, uint256 _loss) internal {
        // Add new profit to existing locked profit (losses reduce immediately)
        uint256 currentLocked = _calculateLockedProfit();

        if (_gain > 0) {
            lockedProfit = currentLocked + _gain;
        } else if (_loss > 0) {
            // Losses reduce locked profit immediately
            lockedProfit = currentLocked > _loss ? currentLocked - _loss : 0;
        } else {
            lockedProfit = currentLocked;
        }

        lastReport = block.timestamp;
        emit LockedProfitUpdated(lockedProfit, block.timestamp);
    }
/** 
    /**
     * @notice Comprehensive sanity check for the entire system
     * @dev Verifies that accounting matches reality across all components
     * @return isHealthy True if all checks pass
     */
    function _performSanityCheck() internal view returns (bool isHealthy) {
        // Check 1: Verify total supply math
        uint256 virtualPrice = getVirtualPrice();
        uint256 calculatedTotalValue = (totalSupply() * virtualPrice) / 1e18;
        uint256 actualTotalAssets = _totalAssets();

        if (
            _abs(calculatedTotalValue, actualTotalAssets) >
            (actualTotalAssets * 50) / 10000
        ) {
            // 0.5% tolerance
            emit SanityCheckFailed(
                "Virtual price mismatch",
                calculatedTotalValue,
                actualTotalAssets
            );
            return false;
        }

        // Check 2: Verify strategy debt accounting
        if (strategy != address(0)) {
            uint256 claimedAssets = IStrategyStMnt(strategy)
                .estimatedTotalAssets();
            if (
                _abs(totalLentToStrategy, claimedAssets) >
                (totalLentToStrategy * 100) / 10000
            ) {
                // 1% tolerance
                emit SanityCheckFailed(
                    "Strategy debt mismatch",
                    totalLentToStrategy,
                    claimedAssets
                );
                return false;
            }
        }

        // Check 3: Verify individual token balances
        for (uint256 i = 0; i < N; ++i) {
            uint256 contractBalance = IERC20(tokens[i]).balanceOf(
                address(this)
            );
            uint256 expectedMinBalance = (balances[i] * 95) / 100; // Allow 5% variance for rounding

            if (contractBalance < expectedMinBalance) {
                emit SanityCheckFailed(
                    "Token balance too low",
                    balances[i],
                    contractBalance
                );
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Emergency function to pause all operations if sanity checks fail
     * @dev Can only be called by guardian or governance, sets emergency flag
     */
    function emergencyPause() external {
        require(
            msg.sender == guardian || msg.sender == governance,
            "Not authorized for emergency pause"
        );

        emergencyShutdown = true;
        emit EmergencyShutdown(true);
    }

    // =================================================================
    // GOVERNANCE FUNCTIONS FOR SECURITY PARAMETERS
    // =================================================================

    /**
     * @notice Updates the maximum allowed loss threshold
     * @param _newThreshold New threshold in basis points (100 = 1%)
     */
    function setMaxLossThreshold(
        uint256 _newThreshold
    ) external onlyGovernance {
        require(_newThreshold <= 1000, "Threshold too high"); // Max 10%
        uint256 oldThreshold = maxLossThreshold;
        maxLossThreshold = _newThreshold;
        emit SecurityParameterUpdated(
            "maxLossThreshold",
            oldThreshold,
            _newThreshold
        );
    }

    /**
     * @notice Updates the cooldown period between operations
     * @param _newCooldown New cooldown period in seconds
     */
    function setCooldownPeriod(uint256 _newCooldown) external onlyGovernance {
        require(_newCooldown <= 1 days, "Cooldown too long");
        require(_newCooldown >= 5 minutes, "Cooldown too short");
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
     * @param _newDegradation New degradation rate (higher = faster unlock)
     */
    function setLockedProfitDegradation(
        uint256 _newDegradation
    ) external onlyGovernance {
        require(
            _newDegradation <= DEGRADATION_COEFFICIENT,
            "Degradation too high"
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
     * @notice Returns the current amount of locked profit
     * @return Current locked profit after degradation
     */
    function getCurrentLockedProfit() external view returns (uint256) {
        return _calculateLockedProfit();
    }

    /**
     * @notice Returns the current free funds available
     * @return Free funds (total assets minus locked profit)
     */
    function getFreeFunds() external view returns (uint256) {
        return _freeFunds();
    }

    /**
     * @notice Performs a health check and returns results
     * @return isHealthy Whether all sanity checks pass
     */
    function performHealthCheck() external view returns (bool isHealthy) {
        return _performSanityCheck();
    }

    // =================================================================
    // UTILITY FUNCTIONS
    // =================================================================

    /**
     * @notice Calculates absolute difference between two numbers
     * @param a First number
     * @param b Second number
     * @return Absolute difference
     */
    function _abs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    /**
     * @notice Returns total assets including strategy debt
     * @dev This should be implemented in the main contract
     * @return Total assets under management
     */
    function _totalAssets() internal view virtual returns (uint256);

    // =================================================================
    // PLACEHOLDER VARIABLES (should exist in main contract)
    // =================================================================

    // These should be defined in your main StableSwap contract:
    // address public governance;
    // address public guardian;
    // bool public emergencyShutdown;
    // uint256[N] public balances;
    // address[N] public tokens;
    // address public strategy;
    // uint256 public totalLentToStrategy;
    // uint256 constant N = 2;

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }
}
