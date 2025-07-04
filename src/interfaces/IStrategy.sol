// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IStrategyStMnt
 * @notice Interface for the StrategyStMnt contract
 * @dev Defines all external and public functions of the Strategy,
 *      enabling type-safe interaction between the Pool and other contracts
 * @author Your Team
 */
interface IStrategyStMnt {
    // =================================================================
    // STATE VARIABLE GETTERS
    // =================================================================

    /**
     * @notice Returns the address of the token this strategy aims to maximize (MNT)
     * @return Address of the want token
     */
    function want() external view returns (address);

    /**
     * @notice Returns the address of the staking vault (stMNT) where strategy deposits funds
     * @return Address of the staking vault
     */
    function stVault() external view returns (address);

    /**
     * @notice Returns the address of the liquidity pool connected to this strategy
     * @return Address of the stable swap pool
     */
    function pool() external view returns (address);

    /**
     * @notice Returns the amount of MNT tokens that the pool has lent to this strategy
     * @dev This represents the strategy's debt to the pool
     * @return Amount of MNT tokens owed to the pool
     */
    function balanceMNTTGivenPool() external view returns (uint256);

    // =================================================================
    // BALANCE QUERY FUNCTIONS
    // =================================================================

    /**
     * @notice Returns the balance of want tokens (MNT) currently held by this contract
     * @return Balance of MNT tokens in the strategy contract
     */
    function balanceWmnt() external view returns (uint256);

    /**
     * @notice Returns the balance of vault shares (stMNT) held by this contract
     * @return Balance of stMNT vault shares owned by the strategy
     */
    function balanceStMnt() external view returns (uint256);

    /**
     * @notice Returns the total estimated assets under management by this strategy
     * @dev Includes liquid MNT + staked MNT value + pool debt
     * @return Total estimated asset value in MNT terms
     */
    function estimatedTotalAssets() external view returns (uint256);

    // =================================================================
    // POOL INTERACTION FUNCTIONS
    // =================================================================

    /**
     * @notice Receives MNT tokens from the pool and invests them in the vault
     * @dev Called by the pool when lending funds to this strategy
     * @param _amount Amount of MNT tokens to invest
     */
    function invest(uint256 _amount) external;

    /**
     * @notice Withdraws MNT tokens from the vault and returns them to the pool
     * @dev Called by the pool when liquidity is needed for user withdrawals
     * @param _amount Amount of MNT tokens to withdraw
     * @return Amount of MNT tokens actually withdrawn and sent to pool
     */
    function poolCallWithdraw(uint256 _amount) external returns (uint256);

    /**
     * @notice Withdraws specified amount of MNT tokens from the vault
     * @dev Generic withdrawal function for strategy management
     * @param _amount Amount of MNT tokens to withdraw
     */
    function withdraw(uint256 _amount) external;

    // =================================================================
    // STRATEGY OPERATIONS
    // =================================================================

    /**
     * @notice Executes the yield harvesting cycle and reports results to pool
     * @dev Deposits idle funds, collects rewards, calculates profit/loss, and reports to pool
     * @return _profit Amount of profit generated in this harvest cycle
     */
    function harvest() external returns (uint256 _profit);

    // =================================================================
    // GOVERNANCE FUNCTIONS
    // =================================================================

    /**
     * @notice Approves or revokes unlimited spending allowance for the pool
     * @dev Useful for debt repayment or migration scenarios
     * @param _approve If true, sets allowance to MAX_UINT256, otherwise sets to 0
     */
    function updateUnlimitedSpendingPool(bool _approve) external;

    /**
     * @notice Approves or revokes unlimited spending allowance for the vault
     * @dev Required for depositing funds into the staking vault
     * @param _approve If true, sets allowance to MAX_UINT256, otherwise sets to 0
     */
    function updateUnlimitedSpendingVault(bool _approve) external;

    /**
     * @notice Sets the performance fee taken from strategy profits
     * @dev Only strategy manager can call this function
     * @param _boostFee New boost fee in basis points (max 10000 = 100%)
     */
    function setBoostFee(uint24 _boostFee) external;

    /**
     * @notice Sets the address of an additional stMNT strategy for coordination
     * @dev Used for future strategy composition and yield optimization
     * @param _stMntStrategy Address of the stMNT strategy contract
     */
    function setStMntStrategy(address _stMntStrategy) external;

    /**
     * @notice Recovers accidentally sent ERC20 tokens from the strategy
     * @dev Cannot recover want tokens or vault shares for security
     * @param token Address of the token to recover
     * @param to Address to send the recovered tokens to
     */
    function recoverERC20(address token, address to) external;

    // =================================================================
    // EMERGENCY FUNCTIONS
    // =================================================================

    /**
     * @notice Emergency function to withdraw all funds and return to pool
     * @dev Pauses strategy, exits all positions, and triggers pool emergency mode
     */
    function emergencyWithdrawAll() external;

    /**
     * @notice Pauses all strategy operations
     * @dev Can be called by guardian or governance in emergency situations
     */
    function pause() external;

    /**
     * @notice Resumes strategy operations after pause
     * @dev Only governance can unpause for security reasons
     */
    function unpause() external;

    // =================================================================
    // ACCESS CONTROL FUNCTIONS
    // =================================================================

    /**
     * @notice Grants a role to an account
     * @dev Only admin can grant roles to maintain security hierarchy
     * @param role The role identifier to grant
     * @param account The address to receive the role
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account
     * @dev Only admin can revoke roles to maintain security hierarchy
     * @param role The role identifier to revoke
     * @param account The address to lose the role
     */
    function revokeRole(bytes32 role, address account) external;
}
