// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStableSwap} from "./interfaces/IstableSwap.sol";
import {IVault} from "./interfaces/IVault.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StrategyStMnt
 * @notice Yield strategy that stakes MNT tokens to earn stMNT rewards and shares profits with the pool
 * @dev Integrates with a staking vault to generate yield while maintaining accounting with the pool
 * @author Your Team
 */
contract StrategyStMnt is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =================================================================
    // IMMUTABLE VARIABLES
    // =================================================================

    /// @notice The token this strategy wants to maximize (MNT)
    address public immutable want;

    /// @notice The staking vault that issues stMNT for deposited MNT
    IVault public immutable stVault;

    /// @notice The stable swap pool that this strategy serves
    IStableSwap public pool;

    // =================================================================
    // ROLE DEFINITIONS
    // =================================================================

    /// @notice Default admin role - can grant/revoke all other roles
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /// @notice Governance role - can update parameters and strategy settings
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Guardian role - can pause/unpause, emergency functions
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Strategy Manager - can call strategy management functions
    bytes32 public constant STRATEGY_MANAGER_ROLE =
        keccak256("STRATEGY_MANAGER_ROLE");

    /// @notice Keeper role - can call harvest and maintenance functions
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Strategy role - reserved for future strategy coordination
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    // =================================================================
    // STATE VARIABLES
    // =================================================================

    /// @notice Amount of debt this strategy owes to the pool
    uint256 public balanceMNTTGivenPool;

    /// @notice Internal tracking of vault shares owned by this strategy
    uint256 private balanceSharesInVault;

    /// @notice Performance fee taken from profits (in basis points, 3000 = 30%)
    uint24 public boostFee = 3000;

    /// @notice Address of potential additional stMNT strategy (future use)
    address public stMntStrategy;

    /// @notice Flag to indicate emergency mode operations
    bool private emergencyAction = false;

    // =================================================================
    // EVENTS
    // =================================================================

    /**
     * @notice Emitted when funds are invested in the vault
     * @param amount Amount of MNT invested
     * @param shares Vault shares received
     */
    event Invested(uint256 amount, uint256 shares);

    /**
     * @notice Emitted when funds are withdrawn from the vault
     * @param shares Vault shares burned
     * @param amount Amount of MNT received
     */
    event Withdrawn(uint256 shares, uint256 amount);

    /**
     * @notice Emitted when strategy reports profit/loss
     * @param profit Amount of profit generated
     * @param loss Amount of loss incurred
     * @param totalDebt New total debt to pool
     */
    event Harvested(uint256 profit, uint256 loss, uint256 totalDebt);

    /**
     * @notice Emitted when boost fee is collected
     * @param amount Amount of boost fee collected
     * @param recipient Recipient of the boost fee
     */
    event BoostFeeCollected(uint256 amount, address recipient);

    // =================================================================
    // CONSTRUCTOR
    // =================================================================

    /**
     * @notice Initializes the strategy with required contracts and roles
     * @param _want Address of the MNT token
     * @param _stVault Address of the staking vault
     * @param _pool Address of the stable swap pool
     * @param _admin Address with admin privileges
     * @param _governance Address with governance privileges
     * @param _guardian Address with guardian privileges
     */
    constructor(
        address _want,
        address _stVault,
        address _pool,
        address _admin,
        address _governance,
        address _guardian
    ) {
        require(_want != address(0), "Invalid want token address");
        require(_stVault != address(0), "Invalid vault address");
        require(_pool != address(0), "Invalid pool address");
        require(_admin != address(0), "Invalid admin address");
        require(_governance != address(0), "Invalid governance address");
        require(_guardian != address(0), "Invalid guardian address");

        want = _want;
        stVault = IVault(_stVault);
        pool = IStableSwap(_pool);

        // Setup roles
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(GUARDIAN_ROLE, _guardian);

        // Admin can grant all roles
        _setRoleAdmin(GOVERNANCE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(STRATEGY_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(KEEPER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(STRATEGY_ROLE, ADMIN_ROLE);
    }

    // =================================================================
    // ACCESS CONTROL MODIFIERS
    // =================================================================

    /// @notice Only admin can call
    modifier onlyAdmin() {
        require(
            hasRole(ADMIN_ROLE, msg.sender),
            "AccessControl: sender must be admin"
        );
        _;
    }

    /// @notice Only governance can call
    modifier onlyGovernance() {
        require(
            hasRole(GOVERNANCE_ROLE, msg.sender),
            "AccessControl: sender must be governance"
        );
        _;
    }

    /// @notice Only guardian can call
    modifier onlyGuardian() {
        require(
            hasRole(GUARDIAN_ROLE, msg.sender),
            "AccessControl: sender must be guardian"
        );
        _;
    }

    /// @notice Guardian or governance can call
    modifier onlyGuardianOrGovernance() {
        require(
            hasRole(GUARDIAN_ROLE, msg.sender) ||
                hasRole(GOVERNANCE_ROLE, msg.sender),
            "AccessControl: sender must be guardian or governance"
        );
        _;
    }

    /// @notice Governance or strategy manager can call
    modifier onlyMultiRoleGovStra() {
        require(
            hasRole(GOVERNANCE_ROLE, msg.sender) ||
                hasRole(STRATEGY_MANAGER_ROLE, msg.sender),
            "AccessControl: sender must be strategy manager or governance"
        );
        _;
    }

    /// @notice Governance, strategy manager, or keeper can call
    modifier onlyMultiRoleGovStraKepp() {
        require(
            hasRole(GOVERNANCE_ROLE, msg.sender) ||
                hasRole(STRATEGY_MANAGER_ROLE, msg.sender) ||
                hasRole(KEEPER_ROLE, msg.sender),
            "AccessControl: sender must be strategy manager, governance, or keeper"
        );
        _;
    }

    /// @notice Strategy manager can call
    modifier onlyStrategyManager() {
        require(
            hasRole(STRATEGY_MANAGER_ROLE, msg.sender),
            "AccessControl: sender must be strategy manager"
        );
        _;
    }

    /// @notice Only keeper can call
    modifier onlyKeeper() {
        require(
            hasRole(KEEPER_ROLE, msg.sender),
            "AccessControl: sender must be keeper"
        );
        _;
    }

    /// @notice Only strategy contract can call
    modifier onlyStrategy() {
        require(
            hasRole(STRATEGY_ROLE, msg.sender),
            "AccessControl: sender must be strategy"
        );
        _;
    }

    /// @notice Only the pool contract can call
    modifier onlyPool() {
        require(
            msg.sender == address(pool),
            "AccessControl: sender must be pool"
        );
        _;
    }

    // =================================================================
    // ROLE MANAGEMENT FUNCTIONS
    // =================================================================

    /**
     * @notice Grant a role to an account
     * @param role The role to grant
     * @param account The account to grant the role to
     */
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyAdmin {
        _grantRole(role, account);
        emit RoleGranted(role, account, msg.sender);
    }

    /**
     * @notice Revoke a role from an account
     * @param role The role to revoke
     * @param account The account to revoke the role from
     */
    function revokeRole(
        bytes32 role,
        address account
    ) public override onlyAdmin {
        _revokeRole(role, account);
        emit RoleRevoked(role, account, msg.sender);
    }

    /**
     * @notice Emergency function to pause all operations
     */
    function pause() external onlyGuardianOrGovernance {
        _pause();
    }

    /**
     * @notice Unpause operations (only governance for safety)
     */
    function unpause() external onlyGovernance {
        _unpause();
    }

    // =================================================================
    // VIEW FUNCTIONS
    // =================================================================

    /**
     * @notice Returns the balance of want tokens held by this contract
     * @return Balance of MNT tokens in this contract
     */
    function balanceWmnt() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /**
     * @notice Returns the balance of vault shares held by this contract
     * @return Balance of stMNT vault shares
     */
    function balanceStMnt() public view returns (uint256) {
        return stVault.balanceOf(address(this));
    }

    /**
     * @notice Estimates total assets under management by this strategy
     * @dev Includes liquid MNT + staked MNT value + pool debt
     * @return Total estimated asset value in MNT terms
     */
    function estimatedTotalAssets() external view returns (uint256) {
        uint256 _wantBalance = balanceWmnt();
        uint256 _stMntBalance = balanceStMnt();
        uint256 _wantInStMNt = convertStmntToWmnt(_stMntBalance);
        return _wantBalance + _wantInStMNt + balanceMNTTGivenPool;
    }

    // =================================================================
    // GOVERNANCE FUNCTIONS
    // =================================================================

    /**
     * @notice Update unlimited spending approval for the pool
     * @param _approve True to approve unlimited spending, false to revoke
     */
    function updateUnlimitedSpendingPool(
        bool _approve
    ) external onlyGovernance {
        if (_approve) {
            IERC20(want).safeIncreaseAllowance(
                address(pool),
                type(uint256).max
            );
        } else {
            IERC20(want).approve(address(pool), 0);
        }
    }

    /**
     * @notice Update unlimited spending approval for the vault
     * @param _approve True to approve unlimited spending, false to revoke
     */
    function updateUnlimitedSpendingVault(
        bool _approve
    ) external onlyGovernance {
        if (_approve) {
            IERC20(want).safeIncreaseAllowance(
                address(stVault),
                type(uint256).max
            );
        } else {
            IERC20(want).approve(address(stVault), 0);
        }
    }

    /**
     * @notice Set the performance fee taken from profits
     * @param _boostFee New boost fee in basis points (max 10000 = 100%)
     */
    function setBoostFee(uint24 _boostFee) external onlyStrategyManager {
        require(_boostFee <= 10000, "Boost fee cannot exceed 100%");
        boostFee = _boostFee;
    }

    /**
     * @notice Set additional stMNT strategy address for future coordination
     * @param _stMntStrategy Address of the stMNT strategy
     */
    function setStMntStrategy(
        address _stMntStrategy
    ) external onlyStrategyManager {
        require(_stMntStrategy != address(0), "Invalid stMnt strategy address");
        stMntStrategy = _stMntStrategy;
    }

    /**
     * @notice Recover accidentally sent ERC20 tokens
     * @param token Address of token to recover
     * @param to Address to send recovered tokens to
     */
    function recoverERC20(address token, address to) external onlyGovernance {
        require(token != want, "Cannot recover want token");
        require(token != address(stVault), "Cannot recover vault shares");
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    // =================================================================
    // POOL INTERFACE FUNCTIONS
    // =================================================================

    /**
     * @notice Invest MNT tokens received from the pool
     * @dev Called by the pool when lending funds to this strategy
     * @param _amountToLend Amount of MNT tokens to invest
     */
    function invest(uint256 _amountToLend) external onlyPool nonReentrant {
        if (paused()) {
            return;
        } else {
            require(
                _amountToLend >= IERC20(want).balanceOf(address(this)),
                "Insufficient balance to lend"
            );
            balanceMNTTGivenPool += _amountToLend;
            _depositToVault();
        }
    }

    /**
     * @notice Withdraw MNT tokens for the pool
     * @dev Called by pool when users need liquidity
     * @param _amount Amount of MNT tokens to withdraw
     * @return Amount of MNT tokens actually withdrawn
     */
    function poolCallWithdraw(
        uint256 _amount
    ) external onlyPool nonReentrant returns (uint256) {
        if (paused()) {
            return 0;
        } else {
            uint256 _sharesWithdrawn = convertWmnttoStmnt(_amount);
            uint256 _wantOut = _withdrawFromVault(_sharesWithdrawn);
            require(
                _wantOut >= _amount,
                "Withdrawn amount is less than requested"
            );
            IERC20(want).safeTransfer(address(pool), _wantOut);
            return _wantOut;
        }
    }

    // =================================================================
    // STRATEGY OPERATIONS
    // =================================================================

    /**
     * @notice Harvest profits and report to pool
     * @dev Deposits idle funds, calculates profit/loss, and reports to pool
     * @return _profit Amount of profit generated
     * @return _loss Amount of loss incurred
     */
    function harvest()
        external
        onlyMultiRoleGovStraKepp
        returns (uint256 _profit, uint256 _loss)
    {
        _depositToVault();
        (_profit, _loss) = _report();

        emit Harvested(_profit, _loss, balanceMNTTGivenPool);
    }

    /**
     * @notice Emergency function to withdraw all funds and return to pool
     * @dev Pauses strategy, withdraws all vault positions, and reports final state
     */
    function emergencyWithdrawAll() external onlyGovernance {
        _pause();
        emergencyAction = true;

        uint256 shares = stVault.balanceOf(address(this));

        if (shares > 0) {
            // Withdraw directly from vault to avoid internal accounting conflicts
            uint256 actualOut = stVault.withdraw(shares, address(this), 0);
            balanceSharesInVault = 0;

            emit Withdrawn(shares, actualOut);
        }

        uint256 balance = IERC20(want).balanceOf(address(this));
        uint256 _profit = 0;
        uint256 _loss = 0;

        // Calculate final profit/loss
        if (balanceMNTTGivenPool > balance) {
            _loss = balanceMNTTGivenPool - balance;
        } else if (balance > balanceMNTTGivenPool) {
            _profit = balance - balanceMNTTGivenPool;
        }

        // Return all funds to pool
        if (balance > 0) {
            IERC20(want).safeTransfer(address(pool), balance);
            balanceMNTTGivenPool = 0;
        }

        pool.report(_profit, _loss, balanceMNTTGivenPool);
        pool.callEmergencyCall();

        emit Harvested(_profit, _loss, 0);
    }

    // =================================================================
    // INTERNAL FUNCTIONS
    // =================================================================

    /**
     * @notice Deposit all available MNT into the staking vault
     * @return shares Amount of vault shares received
     */
    function _depositToVault() private returns (uint256) {
        uint256 _wantBalance = balanceWmnt();
        if (_wantBalance == 0) {
            return 0;
        }
        uint256 _shares = stVault.deposit(_wantBalance, address(this));
        balanceSharesInVault += _shares;

        emit Invested(_wantBalance, _shares);
        return _shares;
    }

    /**
     * @notice Withdraw funds from the staking vault
     * @param _shares Amount of vault shares to burn
     * @return wantOut Amount of MNT tokens received
     */
    function _withdrawFromVault(uint256 _shares) private returns (uint256) {
        require(_shares > 0, "Shares must be greater than zero");
        uint256 potentialWantOut = convertStmntToWmnt(_shares);
        balanceMNTTGivenPool -= potentialWantOut;
        balanceSharesInVault -= _shares;
        uint256 wantOut = stVault.withdraw(_shares, address(this), 0);
        require(
            wantOut >= potentialWantOut,
            "Withdrawn amount is less than expected"
        );

        emit Withdrawn(_shares, wantOut);
        return wantOut;
    }

    /**
     * @notice Convert stMNT shares to MNT value
     * @param _amount Amount of stMNT shares
     * @return Equivalent MNT value
     */
    function convertStmntToWmnt(
        uint256 _amount
    ) private view returns (uint256) {
        uint256 _mntconverted = (stVault.pricePerShare() * _amount) / 1e18;
        return _mntconverted;
    }

    /**
     * @notice Convert MNT amount to required stMNT shares
     * @param _amount Amount of MNT tokens
     * @return Required stMNT shares
     */
    function convertWmnttoStmnt(
        uint256 _amount
    ) private view returns (uint256) {
        uint256 _stMntConverted = (_amount * 1e18) / stVault.pricePerShare();
        return _stMntConverted;
    }

    /**
     * @notice Claim performance fee from profits
     * @param _profit Total profit amount
     * @return Amount of boost fee claimed
     */
    function claimBoostFee(uint256 _profit) private returns (uint256) {
        uint256 _boostFee = (_profit * boostFee) / 10000;
        require(_boostFee <= _profit, "Boost fee exceeds profit");

        // Withdraw boost fee from vault and send to vault as additional deposit
        uint256 _sharesToWithdraw = convertWmnttoStmnt(_boostFee);
        uint256 _wantOut = _withdrawFromVault(_sharesToWithdraw);
        require(
            _wantOut >= (_boostFee * 9999) / 10000,
            "Withdrawn amount is less than boost fee"
        );

        IERC20(want).safeTransfer(address(stVault), _boostFee - 1);

        emit BoostFeeCollected(_boostFee, address(stVault));
        return _boostFee;
    }

    /**
     * @notice Calculate and report profit/loss to the pool
     * @return _profit Amount of profit generated
     * @return _loss Amount of loss incurred
     */
    function _report() private returns (uint256 _profit, uint256 _loss) {
        uint256 _wantBalance = balanceWmnt();
        uint256 _stMntBalance = balanceStMnt();
        uint256 _wantInStMNt = convertStmntToWmnt(_stMntBalance);
        uint256 _boostFee = 0;

        // Calculate profit or loss
        if (balanceMNTTGivenPool > _wantBalance + _wantInStMNt) {
            _loss = balanceMNTTGivenPool - (_wantBalance + _wantInStMNt);
            require(_loss <= balanceMNTTGivenPool, "Loss exceeds pool balance");
            balanceMNTTGivenPool -= _loss;
        } else {
            _profit = (_wantBalance + _wantInStMNt) - balanceMNTTGivenPool;

            // Claim boost fee only if not in emergency mode
            if (!emergencyAction) {
                _boostFee = claimBoostFee(_profit);
                require(_boostFee <= _profit, "Boost fee exceeds profit");
                _profit -= _boostFee;
            }
            balanceMNTTGivenPool += _profit;
        }

        // Report to pool
        pool.report(_profit, _loss, balanceMNTTGivenPool);
    }
}
