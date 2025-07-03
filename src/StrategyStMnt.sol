// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStableSwap} from "./interfaces/IstableSwap.sol";

import {IVault} from "./interfaces/IVault.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {console} from "forge-std/console.sol";

contract StrategyStMnt is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable want;
    IVault public immutable stVault;
    //! PER ADESSO SOLO ADDRESS MA PENSO DOVRO CREARE UN INTERFACCIA
    IStableSwap public pool;

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /// @notice Governance role - can update parameters and strategy
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Guardian role - can pause/unpause, emergency functions
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Strategy Manager - can call strategy functions
    bytes32 public constant STRATEGY_MANAGER_ROLE =
        keccak256("STRATEGY_MANAGER_ROLE");

    /// @notice Keeper role - can call harvest and maintenance functions
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Strategy role - only the strategy contract can report
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    constructor(
        address _want,
        address _stVault,
        address _pool,
        address _admin,
        address _governance,
        address _guardian
    ) {
        require(_want != address(0), "Invalid wmnt address");
        require(_stVault != address(0), "Invalid stVault address");
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
    // 🔒 ACCESS CONTROL MODIFIERS
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

    modifier onlyMultiRoleGovStra() {
        require(
            hasRole(GOVERNANCE_ROLE, msg.sender) ||
                hasRole(STRATEGY_MANAGER_ROLE, msg.sender),
            "AccessControl: sender must be strategy or governance"
        );
        _;
    }

    modifier onlyMultiRoleGovStraKepp() {
        require(
            hasRole(GOVERNANCE_ROLE, msg.sender) ||
                hasRole(STRATEGY_MANAGER_ROLE, msg.sender) ||
                hasRole(KEEPER_ROLE, msg.sender),
            "AccessControl: sender must be strategy,governanc oe keeper"
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

    modifier onlyPool() {
        require(
            msg.sender == address(pool),
            "AccessControl: sender must be pool"
        );
        _;
    }

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

    function balanceWmnt() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceStMnt() public view returns (uint256) {
        return stVault.balanceOf(address(this));
    }

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

    function poolCallWithdraw(
        uint256 _amount
    ) external onlyPool nonReentrant returns (uint256) {
        if (paused()) {
            return 0; // Nothing to withdraw if paused
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

    function setBoostFee(uint24 _boostFee) external onlyStrategyManager {
        require(_boostFee <= 10000, "Boost fee cannot exceed 100%");
        boostFee = _boostFee;
    }

    address public stMntStrategy;

    function setStMntStrategy(
        address _stMntStrategy
    ) external onlyStrategyManager {
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

    function harvest()
        external
        onlyMultiRoleGovStraKepp
        returns (uint256 _profit, uint256 _loss)
    {
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

    function emergencyWithdrawAll() external onlyGovernance {
        // Withdraw everything from vault
        _pause();
        uint256 shares = stVault.balanceOf(address(this));
        if (shares > 0) {
            stVault.withdraw(shares, address(this), 0);
        }

        // Send all to pool
        uint256 balance = IERC20(want).balanceOf(address(this));

        uint256 _profit = 0;
        uint256 _loss = 0;

        if (balanceMNTTGivenPool >= balance) {
            _loss = balanceMNTTGivenPool - balance;
        } else {
            _profit = balance - balanceMNTTGivenPool;
        }

        if (balance > 0) {
            IERC20(want).safeTransfer(address(pool), balance);
            balanceMNTTGivenPool = 0; // Reset debt
        }
        pool.report(_profit, _loss, balanceMNTTGivenPool);
    }
}
