// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyStMnt} from "./interfaces/IStrategy.sol";
import {StableSwapSecurityExtensions} from "./stableSwapSecurityExtension.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {console} from "forge-std/console.sol";

/**
 * @title Math Library
 * @notice Provides basic mathematical operations for the StableSwap contract
 */
library Math {
    /**
     * @notice Calculates the absolute difference between two numbers
     * @param x First number
     * @param y Second number
     * @return The absolute difference between x and y
     */
    function abs(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x - y : y - x;
    }
}

/**
 * @title StableSwap
 * @notice A stable swap AMM for trading between MNT and stMNT tokens with integrated yield strategy
 * @dev Implements Curve-style stable swap math with security extensions and strategy integration
 * @author Your Team
 */
contract StableSwap is
    ERC20,
    StableSwapSecurityExtensions,
    ReentrancyGuard,
    AccessControl,
    Pausable
{
    using SafeERC20 for IERC20;

    // =================================================================
    // ROLE DEFINITIONS
    // =================================================================

    /// @notice Default admin role - can grant/revoke all other roles
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

    // =================================================================
    // CONSTANTS AND IMMUTABLES
    // =================================================================

    /// @notice Number of tokens in the pool (always 2: MNT and stMNT)
    uint256 internal constant N = 2;

    /// @notice Amplification coefficient multiplied by N^(N-1)
    /// @dev Higher value makes curve flatter, lower makes it more like constant product AMM
    uint256 private constant A = 1000 * (N ** (N - 1));

    /// @notice Base swap fee in basis points (0.03%)
    uint256 private constant SWAP_FEE = 300;

    /// @notice Liquidity fee derived from swap fee for balanced operations
    /// @dev Formula: (SWAP_FEE * N) / (4 * (N - 1))
    uint256 private constant LIQUIDITY_FEE = (SWAP_FEE * N) / (4 * (N - 1));

    /// @notice Fee denominator for basis point calculations
    uint256 private constant FEE_DENOMINATOR = 1e6;

    // =================================================================
    // STATE VARIABLES
    // =================================================================

    /// @notice Array of token addresses [MNT, stMNT]
    address[N] public tokens;

    /// @notice Multipliers to normalize tokens to 18 decimals
    /// @dev Both tokens use 18 decimals, so both multipliers are 1
    uint256[N] private multipliers = [1, 1];

    /// @notice Internal accounting balances for each token
    uint256[N] public balances;

    /// @notice Balance of tokens currently lent to strategy (unused)
    uint256[N] public balanceInStrategy;

    /// @notice Address of the yield strategy contract
    address public strategy;

    /// @notice Total amount of MNT currently lent to the strategy
    uint256 public totalLentToStrategy;

    /// @notice Flag to pause strategy operations independently
    bool private strategyPaused = false;

    // =================================================================
    // EVENTS
    // =================================================================

    /**
     * @notice Emitted when tokens are swapped
     * @param buyer Address that performed the swap
     * @param tokenIn Index of input token
     * @param tokenOut Index of output token
     * @param amountIn Amount of input tokens
     * @param amountOut Amount of output tokens
     * @param fee Fee paid for the swap
     */
    event TokenSwap(
        address indexed buyer,
        uint256 indexed tokenIn,
        uint256 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    /**
     * @notice Emitted when liquidity is added
     * @param provider Address that added liquidity
     * @param amounts Array of token amounts added
     * @param fees Array of fees paid
     * @param shares LP tokens minted
     */
    event AddLiquidity(
        address indexed provider,
        uint256[N] amounts,
        uint256[N] fees,
        uint256 shares
    );

    /**
     * @notice Emitted when liquidity is removed
     * @param provider Address that removed liquidity
     * @param amounts Array of token amounts withdrawn
     * @param shares LP tokens burned
     */
    event RemoveLiquidity(
        address indexed provider,
        uint256[N] amounts,
        uint256 shares
    );

    // =================================================================
    // CONSTRUCTOR
    // =================================================================

    /**
     * @notice Initializes the StableSwap contract
     * @param _tokens Array of token addresses [MNT, stMNT]
     * @param _admin Address with admin privileges
     * @param _governance Address with governance privileges
     * @param _guardian Address with guardian privileges
     */
    constructor(
        address[N] memory _tokens,
        address _admin,
        address _governance,
        address _guardian
    ) ERC20("StableSwap MNT/stMNT", "SS-MNT/stMNT") {
        require(_admin != address(0), "Invalid admin address");
        require(_governance != address(0), "Invalid governance address");
        require(_guardian != address(0), "Invalid guardian address");

        tokens = _tokens;

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

        // Initialize security extensions
        lastReport = block.timestamp;
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
    modifier onlyGovernance() override {
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

    /// @notice Only the strategy contract address can call
    modifier onlyStrategyContract() {
        require(msg.sender == strategy, "Not a trusted strategy");
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
    // CORE AMM MATHEMATICS
    // =================================================================

    /**
     * @notice Returns precision-adjusted balances including strategy funds
     * @dev Includes total MNT (physical + lent to strategy) for pricing calculations
     * @return xp Array of precision-adjusted balances
     */
    function _xp() private view returns (uint256[N] memory xp) {
        // MNT balance includes funds lent to strategy
        xp[0] = (balances[0] + totalLentToStrategy) * multipliers[0];
        // stMNT balance is only physical tokens in contract
        xp[1] = balances[1] * multipliers[1];
    }

    /**
     * @notice Calculate D (total liquidity) using Newton's method
     * @dev Implements Curve's stable swap invariant calculation
     * @param xp Precision-adjusted balances
     * @return D Total liquidity value
     */
    function _getD(uint256[N] memory xp) private pure returns (uint256) {
        uint256 a = A * N; // An^n

        uint256 s; // Sum of balances
        for (uint256 i; i < N; ++i) {
            s += xp[i];
        }

        // Newton's method convergence
        uint256 d = s;
        uint256 d_prev;
        for (uint256 i; i < 255; ++i) {
            uint256 p = d;
            for (uint256 j; j < N; ++j) {
                p = (p * d) / (N * xp[j]);
            }
            d_prev = d;
            d = ((a * s + N * p) * d) / ((a - 1) * d + (N + 1) * p);

            if (Math.abs(d, d_prev) <= 1) {
                return d;
            }
        }
        revert("D didn't converge");
    }

    /**
     * @notice Calculate new balance of token j given new balance of token i
     * @dev Used for swap calculations using Newton's method
     * @param i Index of input token
     * @param j Index of output token
     * @param x New balance of token i after deposit
     * @param xp Current precision-adjusted balances
     * @return New balance of token j
     */
    function _getY(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[N] memory xp
    ) private pure returns (uint256) {
        uint256 a = A * N;
        uint256 d = _getD(xp);
        uint256 s;
        uint256 c = d;

        uint256 _x;
        for (uint256 k; k < N; ++k) {
            if (k == i) {
                _x = x;
            } else if (k == j) {
                continue;
            } else {
                _x = xp[k];
            }

            s += _x;
            c = (c * d) / (N * _x);
        }
        c = (c * d) / (N * a);
        uint256 b = s + d / a;

        // Newton's method
        uint256 y_prev;
        uint256 y = d;
        for (uint256 _i; _i < 255; ++_i) {
            y_prev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (Math.abs(y, y_prev) <= 1) {
                return y;
            }
        }
        revert("y didn't converge");
    }

    /**
     * @notice Calculate token balance given target liquidity D
     * @dev Used for liquidity calculations
     * @param i Index of token to calculate
     * @param xp Precision-adjusted balances
     * @param d Target liquidity value
     * @return New balance of token i
     */
    function _getYD(
        uint256 i,
        uint256[N] memory xp,
        uint256 d
    ) private pure returns (uint256) {
        uint256 a = A * N;
        uint256 s;
        uint256 c = d;

        uint256 _x;
        for (uint256 k; k < N; ++k) {
            if (k != i) {
                _x = xp[k];
            } else {
                continue;
            }

            s += _x;
            c = (c * d) / (N * _x);
        }
        c = (c * d) / (N * a);
        uint256 b = s + d / a;

        // Newton's method
        uint256 y_prev;
        uint256 y = d;
        for (uint256 _i; _i < 255; ++_i) {
            y_prev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (Math.abs(y, y_prev) <= 1) {
                return y;
            }
        }
        revert("y didn't converge");
    }

    // =================================================================
    // VIEW FUNCTIONS
    // =================================================================

    /**
     * @notice Calculate virtual price of LP tokens
     * @dev Represents the value of 1 LP token in terms of underlying assets
     * @return Virtual price scaled to 18 decimals
     */
    function getVirtualPrice() public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return 0;
        }
        uint256 d = _getD(_xpWithFreeFunds());
        return (d * 10 ** decimals()) / _totalSupply;
    }

    /**
     * @notice Returns precision-adjusted balances considering locked profit
     * @dev Used for pricing to prevent MEV attacks during profit distribution
     * @return xp Array of free funds balances
     */
    function _xpWithFreeFunds() internal view returns (uint256[N] memory xp) {
        uint256 totalMNT = balances[0] + totalLentToStrategy;
        uint256 freeMNT = totalMNT; // Default: all MNT is free

        uint256 totalAssets = _totalAssets();
        uint256 lockedProfit = _calculateLockedProfit();

        // Calculate free MNT considering locked profit
        if (totalAssets > 0 && lockedProfit > 0 && totalMNT > 0) {
            uint256 lockedMNT = (lockedProfit * totalMNT) / totalAssets;
            freeMNT = totalMNT > lockedMNT ? totalMNT - lockedMNT : totalMNT;
        }

        xp[0] = freeMNT * multipliers[0];
        xp[1] = balances[1] * multipliers[1];
    }

    /**
     * @notice Returns total assets under management
     * @return Total assets including strategy funds
     */
    function _totalAssets() internal view returns (uint256) {
        return IStrategyStMnt(strategy).estimatedTotalAssets() + balances[0];
    }

    /**
     * @notice Returns free funds available for operations
     * @dev Excludes locked profit to prevent MEV during harvests
     * @return Available funds considering locked profit degradation
     */
    function _freeFunds() internal view returns (uint256) {
        uint256 total = _totalAssets();
        uint256 locked = _calculateLockedProfit();
        return total > locked ? total - locked : 0;
    }

    /**
     * @notice Public getter for free funds
     * @return Free funds (total assets minus locked profit)
     */
    function getFreeFunds() external view returns (uint256) {
        return _freeFunds();
    }

    // =================================================================
    // SWAP FUNCTIONS
    // =================================================================

    /**
     * @notice Swap tokens in the pool
     * @param i Index of input token (0 = MNT, 1 = stMNT)
     * @param j Index of output token (0 = MNT, 1 = stMNT)
     * @param dx Amount of input tokens
     * @param minDy Minimum amount of output tokens (slippage protection)
     * @return dy Amount of output tokens received
     */
    function swap(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy
    ) external nonReentrant whenNotPaused returns (uint256 dy) {
        require(!emergencyShutdown, "Emergency shutdown active");
        require(i != j, "Cannot swap same token");

        IERC20(tokens[i]).transferFrom(msg.sender, address(this), dx);

        // Calculate output amount using stable swap math
        uint256[N] memory xp = _xp();
        uint256 x = xp[i] + dx * multipliers[i];

        uint256 y0 = xp[j];
        uint256 y1 = _getY(i, j, x, xp);
        dy = (y0 - y1 - 1) / multipliers[j];

        uint256 fee = (dy * SWAP_FEE) / FEE_DENOMINATOR;
        dy -= fee;
        require(dy >= minDy, "Insufficient output amount");

        // Handle MNT withdrawals from strategy if needed
        if (j == 0 && IERC20(tokens[0]).balanceOf(address(this)) < dy) {
            uint256 amountNeeded = dy -
                IERC20(tokens[0]).balanceOf(address(this));
            IStrategyStMnt(strategy).poolCallWithdraw(amountNeeded);
        }

        // Update internal accounting
        balances[i] += dx;
        balances[j] -= dy;

        // Transfer output tokens to user
        IERC20(tokens[j]).transfer(msg.sender, dy);
    }

    // =================================================================
    // LIQUIDITY FUNCTIONS
    // =================================================================

    /**
     * @notice Add liquidity to the pool
     * @param amounts Array of token amounts to add [MNT, stMNT]
     * @param minShares Minimum LP tokens to receive (slippage protection)
     * @return shares Amount of LP tokens minted
     */
    function addLiquidity(
        uint256[N] calldata amounts,
        uint256 minShares
    )
        external
        nonReentrant
        rateLimited
        sanityCheck
        whenNotPaused
        returns (uint256 shares)
    {
        require(!emergencyShutdown, "Emergency shutdown active");

        // Calculate current liquidity
        uint256 _totalSupply = totalSupply();
        uint256 d0;
        uint256[N] memory old_xs = _xpWithFreeFunds();

        if (_totalSupply > 0) {
            d0 = _getD(old_xs);
        }

        // Transfer tokens and calculate new balances
        uint256[N] memory new_xs;
        for (uint256 i; i < N; ++i) {
            uint256 amount = amounts[i];
            if (amount > 0) {
                IERC20(tokens[i]).transferFrom(
                    msg.sender,
                    address(this),
                    amount
                );
                new_xs[i] = old_xs[i] + amount * multipliers[i];
            } else {
                new_xs[i] = old_xs[i];
            }
        }

        // Calculate new liquidity
        uint256 d1 = _getD(new_xs);
        require(d1 > d0, "Liquidity must increase");

        // Calculate liquidity accounting for imbalance fees
        uint256 d2;
        if (_totalSupply > 0) {
            for (uint256 i; i < N; ++i) {
                uint256 idealBalance = (old_xs[i] * d1) / d0;
                uint256 diff = Math.abs(new_xs[i], idealBalance);
                new_xs[i] -= (LIQUIDITY_FEE * diff) / FEE_DENOMINATOR;
            }
            d2 = _getD(new_xs);
        } else {
            d2 = d1;
        }

        // Update balances
        for (uint256 i; i < N; ++i) {
            balances[i] += amounts[i];
        }

        // Calculate shares to mint
        if (_totalSupply > 0) {
            shares = ((d2 - d0) * _totalSupply) / d0;
        } else {
            shares = d2;
        }
        require(shares >= minShares, "Insufficient shares");
        _mint(msg.sender, shares);
    }

    /**
     * @notice Remove liquidity proportionally
     * @param shares Amount of LP tokens to burn
     * @param minAmountsOut Minimum amounts to receive [MNT, stMNT]
     * @return amountsOut Actual amounts withdrawn
     */
    function removeLiquidity(
        uint256 shares,
        uint256[N] calldata minAmountsOut
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256[N] memory amountsOut)
    {
        require(!emergencyShutdown, "Emergency shutdown active");

        uint256 _totalSupply = totalSupply();

        uint256 mntAmountOut = (balances[0] * shares) / _totalSupply;
        require(mntAmountOut >= minAmountsOut[0], "Insufficient MNT output");

        uint256 stMntAmountOut = (balances[1] * shares) / _totalSupply;
        require(
            stMntAmountOut >= minAmountsOut[1],
            "Insufficient stMNT output"
        );

        uint256 liquidMnt = balances[0] - totalLentToStrategy;

        // Recall funds from strategy if needed
        if (liquidMnt < mntAmountOut) {
            uint256 amountToRecall = mntAmountOut - liquidMnt;
            uint256 actualRecalled = IStrategyStMnt(strategy).poolCallWithdraw(
                amountToRecall
            );

            if (totalLentToStrategy < actualRecalled) {
                totalLentToStrategy = 0;
            } else {
                totalLentToStrategy -= actualRecalled;
            }
        }

        // Handle potential shortfall gracefully
        uint256 actualBalance = IERC20(tokens[0]).balanceOf(address(this));
        uint256 actualMntOut = actualBalance < mntAmountOut
            ? actualBalance
            : mntAmountOut;

        balances[0] -= mntAmountOut;
        balances[1] -= stMntAmountOut;

        amountsOut[0] = actualMntOut;
        amountsOut[1] = stMntAmountOut;

        _burn(msg.sender, shares);

        IERC20(tokens[0]).safeTransfer(msg.sender, actualMntOut);
        IERC20(tokens[1]).safeTransfer(msg.sender, stMntAmountOut);
    }

    /**
     * @notice Calculate withdrawal amount for single token
     * @param shares Amount of LP tokens to burn
     * @param i Index of token to withdraw
     * @return dy Amount of token i to receive
     * @return fee Fee for imbalanced withdrawal
     */
    function _calcWithdrawOneToken(
        uint256 shares,
        uint256 i
    ) private view returns (uint256 dy, uint256 fee) {
        uint256 _totalSupply = totalSupply();
        uint256[N] memory xp = _xp();

        // Calculate target liquidity after withdrawal
        uint256 d0 = _getD(xp);
        uint256 d1 = d0 - (d0 * shares) / _totalSupply;

        // Calculate withdrawal amount before fees
        uint256 y0 = _getYD(i, xp, d1);
        uint256 dy0 = (xp[i] - y0) / multipliers[i];

        // Apply imbalance fees
        uint256 dx;
        for (uint256 j; j < N; ++j) {
            if (j == i) {
                dx = (xp[j] * d1) / d0 - y0;
            } else {
                dx = xp[j] - (xp[j] * d1) / d0;
            }
            xp[j] -= (LIQUIDITY_FEE * dx) / FEE_DENOMINATOR;
        }

        // Recalculate with fees
        uint256 y1 = _getYD(i, xp, d1);
        dy = (xp[i] - y1 - 1) / multipliers[i];
        fee = dy0 - dy;
    }

    /**
     * @notice Calculate single token withdrawal (view function)
     * @param shares Amount of LP tokens to burn
     * @param i Index of token to withdraw
     * @return dy Amount of token i to receive
     * @return fee Fee for imbalanced withdrawal
     */
    function calcWithdrawOneToken(
        uint256 shares,
        uint256 i
    ) external view returns (uint256 dy, uint256 fee) {
        return _calcWithdrawOneToken(shares, i);
    }

    /**
     * @notice Simulates a swap to preview output amount and fees
     * @param i Index of input token
     * @param j Index of output token
     * @param dx Amount of input tokens
     * @return dy Expected output amount
     * @return fee Fee amount that will be charged
     * @return priceImpact Price impact in basis points
     */
    function previewSwap(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256 dy, uint256 fee, uint256 priceImpact) {
        require(i != j, "Cannot swap same token");

        // Get current balances
        uint256[N] memory xp = _xp();
        uint256 x = xp[i] + dx * multipliers[i];

        // Calculate output before fees
        uint256 y0 = xp[j];
        uint256 y1 = _getY(i, j, x, xp);
        uint256 dyBeforeFee = (y0 - y1 - 1) / multipliers[j];

        // Calculate fee
        fee = (dyBeforeFee * SWAP_FEE) / FEE_DENOMINATOR;
        dy = dyBeforeFee - fee;

        // Calculate price impact
        uint256 idealRate = (xp[j] * 1e18) / xp[i]; // Current exchange rate
        uint256 actualRate = (dy * 1e18) / dx; // Rate user gets
        priceImpact = idealRate > actualRate
            ? ((idealRate - actualRate) * 10000) / idealRate
            : 0;
    }

    /**
     * @notice Preview add liquidity operation without executing it
     * @dev Simulates addLiquidity to show expected LP tokens and fees
     * @param amounts Array of token amounts to deposit [MNT, stMNT]
     * @return shares Expected amount of LP tokens to be minted
     * @return fees Array of fees for imbalanced deposits [MNT_fee, stMNT_fee]
     */
    function previewAddLiquidity(
        uint256[N] calldata amounts
    ) external view returns (uint256 shares, uint256[N] memory fees) {
        // Calculate current liquidity
        uint256 _totalSupply = totalSupply();
        uint256 d0;
        uint256[N] memory old_xs = _xpWithFreeFunds();

        if (_totalSupply > 0) {
            d0 = _getD(old_xs);
        }

        // Calculate new balances after deposit
        uint256[N] memory new_xs;
        for (uint256 i; i < N; ++i) {
            new_xs[i] = old_xs[i] + amounts[i] * multipliers[i];
        }

        // Calculate new liquidity
        uint256 d1 = _getD(new_xs);
        require(d1 > d0, "Liquidity must increase");

        // Calculate fees for imbalanced deposits
        uint256[N] memory new_xs_with_fees = new_xs;
        fees = [uint256(0), uint256(0)]; // Initialize fees array

        if (_totalSupply > 0) {
            for (uint256 i; i < N; ++i) {
                uint256 idealBalance = (old_xs[i] * d1) / d0;
                uint256 diff = Math.abs(new_xs[i], idealBalance);
                uint256 fee = (LIQUIDITY_FEE * diff) / FEE_DENOMINATOR;

                // Calculate fee in token terms
                fees[i] = fee / multipliers[i];
                new_xs_with_fees[i] -= fee;
            }
        }

        // Calculate final liquidity after fees
        uint256 d2;
        if (_totalSupply > 0) {
            d2 = _getD(new_xs_with_fees);
        } else {
            d2 = d1;
        }

        // Calculate shares to mint
        if (_totalSupply > 0) {
            shares = ((d2 - d0) * _totalSupply) / d0;
        } else {
            shares = d2;
        }
    }

    /**
     * @notice Preview remove liquidity operation without executing it
     * @dev Simulates removeLiquidity to show expected token amounts
     * @param shares Amount of LP tokens to burn
     * @return amountsOut Array of token amounts that would be received [MNT, stMNT]
     * @return actualAmountsOut Array of actual withdrawable amounts considering liquidity [MNT, stMNT]
     */
    function previewRemoveLiquidity(
        uint256 shares
    )
        external
        view
        returns (
            uint256[N] memory amountsOut,
            uint256[N] memory actualAmountsOut
        )
    {
        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "No liquidity to remove");
        require(shares <= _totalSupply, "Cannot burn more shares than supply");

        // Calculate proportional amounts
        uint256 mntAmountOut = (balances[0] * shares) / _totalSupply;
        uint256 stMntAmountOut = (balances[1] * shares) / _totalSupply;

        amountsOut[0] = mntAmountOut;
        amountsOut[1] = stMntAmountOut;

        // Calculate actual withdrawable amounts considering strategy funds
        uint256 liquidMnt = balances[0] > totalLentToStrategy
            ? balances[0] - totalLentToStrategy
            : 0;

        // For MNT: check if we have enough liquid funds
        actualAmountsOut[0] = liquidMnt >= mntAmountOut
            ? mntAmountOut
            : liquidMnt;

        // For stMNT: should always be available as it's not lent to strategy
        actualAmountsOut[1] = stMntAmountOut;
    }

    /**
     * @notice Preview remove liquidity with strategy recall simulation
     * @dev More accurate preview that accounts for strategy withdrawal capacity
     * @param shares Amount of LP tokens to burn
     * @return amountsOut Expected token amounts [MNT, stMNT]
     * @return needsRecall Whether strategy funds need to be recalled
     * @return recallAmount Amount that needs to be recalled from strategy
     */
    function previewRemoveLiquidityWithRecall(
        uint256 shares
    )
        external
        view
        returns (
            uint256[N] memory amountsOut,
            bool needsRecall,
            uint256 recallAmount
        )
    {
        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "No liquidity to remove");
        require(shares <= _totalSupply, "Cannot burn more shares than supply");

        // Calculate proportional amounts
        uint256 mntAmountOut = (balances[0] * shares) / _totalSupply;
        uint256 stMntAmountOut = (balances[1] * shares) / _totalSupply;

        amountsOut[0] = mntAmountOut;
        amountsOut[1] = stMntAmountOut;

        // Check if strategy recall is needed
        uint256 liquidMnt = balances[0] > totalLentToStrategy
            ? balances[0] - totalLentToStrategy
            : 0;

        if (liquidMnt < mntAmountOut) {
            needsRecall = true;
            recallAmount = mntAmountOut - liquidMnt;
        } else {
            needsRecall = false;
            recallAmount = 0;
        }
    }

    /**
     * @notice Preview add liquidity with detailed breakdown
     * @dev Provides comprehensive preview including price impact and optimal ratios
     * @param amounts Array of token amounts to deposit [MNT, stMNT]
     * @return shares Expected LP tokens
     * @return fees Deposit fees [MNT_fee, stMNT_fee]
     * @return priceImpact Price impact in basis points
     * @return optimalRatio Optimal deposit ratio for minimal fees
     */
    function previewAddLiquidityDetailed(
        uint256[N] calldata amounts
    )
        external
        view
        returns (
            uint256 shares,
            uint256[N] memory fees,
            uint256 priceImpact,
            uint256[N] memory optimalRatio
        )
    {
        // Get basic preview
        (shares, fees) = this.previewAddLiquidity(amounts);

        // Calculate current pool ratios
        uint256 totalValue = balances[0] + balances[1]; // Simplified for same decimals
        if (totalValue > 0) {
            optimalRatio[0] = (balances[0] * 1e18) / totalValue;
            optimalRatio[1] = (balances[1] * 1e18) / totalValue;
        } else {
            optimalRatio[0] = 5e17; // 50%
            optimalRatio[1] = 5e17; // 50%
        }

        // Calculate price impact (simplified)
        uint256 totalDeposit = amounts[0] + amounts[1];
        uint256 totalFees = fees[0] + fees[1];

        if (totalDeposit > 0) {
            priceImpact = (totalFees * 10000) / totalDeposit; // In basis points
        } else {
            priceImpact = 0;
        }
    }

    /**
     * @notice Preview single token withdrawal with detailed breakdown
     * @dev Enhanced version of calcWithdrawOneToken with liquidity and strategy considerations
     * @param shares Amount of LP tokens to burn
     * @param i Index of token to withdraw (0 = MNT, 1 = stMNT)
     * @return dy Amount of token i that would be received
     * @return fee Imbalance fee for single-sided withdrawal
     * @return actualWithdrawable Actual amount withdrawable considering liquidity
     * @return needsRecall Whether strategy funds need to be recalled (only for MNT)
     * @return recallAmount Amount that needs to be recalled from strategy
     */
    function previewRemoveLiquidityOneToken(
        uint256 shares,
        uint256 i
    )
        external
        view
        returns (
            uint256 dy,
            uint256 fee,
            uint256 actualWithdrawable,
            bool needsRecall,
            uint256 recallAmount
        )
    {
        // Get basic calculation (already implemented)
        (dy, fee) = _calcWithdrawOneToken(shares, i);

        // For stMNT (index 1), always fully withdrawable
        if (i == 1) {
            actualWithdrawable = dy;
            needsRecall = false;
            recallAmount = 0;
            return (dy, fee, actualWithdrawable, needsRecall, recallAmount);
        }

        // For MNT (index 0), check strategy liquidity
        uint256 liquidMnt = IERC20(tokens[0]).balanceOf(address(this));

        if (liquidMnt >= dy) {
            // Enough liquid MNT available
            actualWithdrawable = dy;
            needsRecall = false;
            recallAmount = 0;
        } else {
            // Need to recall from strategy
            needsRecall = true;
            recallAmount = dy - liquidMnt;

            // Check if strategy has enough funds
            if (totalLentToStrategy >= recallAmount) {
                actualWithdrawable = dy;
            } else {
                // Strategy doesn't have enough, limit withdrawal
                actualWithdrawable = liquidMnt + totalLentToStrategy;
            }
        }
    }

    /**
     * @notice Preview single token withdrawal with price impact analysis
     * @dev Provides comprehensive analysis including price impact and efficiency
     * @param shares Amount of LP tokens to burn
     * @param i Index of token to withdraw (0 = MNT, 1 = stMNT)
     * @return dy Amount of token i that would be received
     * @return fee Imbalance fee charged
     * @return priceImpact Price impact in basis points
     * @return efficiency Withdrawal efficiency vs proportional withdrawal (in basis points)
     * @return proportionalAmount Amount that would be received in proportional withdrawal
     */
    function previewRemoveLiquidityOneTokenDetailed(
        uint256 shares,
        uint256 i
    )
        external
        view
        returns (
            uint256 dy,
            uint256 fee,
            uint256 priceImpact,
            uint256 efficiency,
            uint256 proportionalAmount
        )
    {
        // Get single token withdrawal amount
        (dy, fee) = _calcWithdrawOneToken(shares, i);

        // Calculate proportional withdrawal for comparison
        uint256 _totalSupply = totalSupply();
        proportionalAmount = (balances[i] * shares) / _totalSupply;

        // Calculate efficiency (how much you get vs proportional)
        if (proportionalAmount > 0) {
            efficiency = (dy * 10000) / proportionalAmount; // In basis points
        } else {
            efficiency = 10000; // 100% if no comparison possible
        }

        // Calculate price impact based on fee
        if (dy + fee > 0) {
            priceImpact = (fee * 10000) / (dy + fee); // In basis points
        } else {
            priceImpact = 0;
        }
    }

    /**
     * @notice Compare withdrawal options for optimal user experience
     * @dev Helps users choose between proportional and single-token withdrawal
     * @param shares Amount of LP tokens to burn
     * @return proportionalAmounts Amounts from proportional withdrawal [MNT, stMNT]
     * @return singleTokenMNT Amount from MNT-only withdrawal (after fees)
     * @return singleTokenStMNT Amount from stMNT-only withdrawal (after fees)
     * @return feeMNT Fee for MNT-only withdrawal
     * @return feeStMNT Fee for stMNT-only withdrawal
     * @return bestOption Recommended option (0=proportional, 1=MNT only, 2=stMNT only)
     */
    function compareWithdrawalOptions(
        uint256 shares
    )
        external
        view
        returns (
            uint256[N] memory proportionalAmounts,
            uint256 singleTokenMNT,
            uint256 singleTokenStMNT,
            uint256 feeMNT,
            uint256 feeStMNT,
            uint256 bestOption
        )
    {
        // Get proportional withdrawal amounts
        (proportionalAmounts, ) = this.previewRemoveLiquidity(shares);

        // Get single token withdrawal amounts
        (singleTokenMNT, feeMNT) = _calcWithdrawOneToken(shares, 0);
        (singleTokenStMNT, feeStMNT) = _calcWithdrawOneToken(shares, 1);

        // Calculate total value for each option (simplified - assumes 1:1 ratio)
        uint256 proportionalValue = proportionalAmounts[0] +
            proportionalAmounts[1];
        uint256 mntOnlyValue = singleTokenMNT;
        uint256 stMntOnlyValue = singleTokenStMNT;

        // Determine best option
        if (
            proportionalValue >= mntOnlyValue &&
            proportionalValue >= stMntOnlyValue
        ) {
            bestOption = 0; // Proportional
        } else if (mntOnlyValue >= stMntOnlyValue) {
            bestOption = 1; // MNT only
        } else {
            bestOption = 2; // stMNT only
        }
    }

    /**
     * @notice Remove liquidity in single token
     * @param shares Amount of LP tokens to burn
     * @param i Index of token to withdraw (0 = MNT, 1 = stMNT)
     * @param minAmountOut Minimum amount to receive
     * @return amountOut Actual amount withdrawn
     */
    function removeLiquidityOneToken(
        uint256 shares,
        uint256 i,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        (amountOut, ) = _calcWithdrawOneToken(shares, i);
        require(amountOut >= minAmountOut, "Insufficient output");

        // Handle MNT withdrawals with strategy recall
        if (i == 0) {
            uint256 actualBalance = IERC20(tokens[0]).balanceOf(address(this));
            uint256 tolerance = amountOut / 1000000; // 0.0001% tolerance
            if (tolerance == 0) tolerance = 1; // Minimum 1 wei tolerance

            // Only recall if significantly short
            if (actualBalance + tolerance < amountOut) {
                uint256 amountToRecall = amountOut - actualBalance;
                uint256 actualRecalled = IStrategyStMnt(strategy)
                    .poolCallWithdraw(amountToRecall);

                if (totalLentToStrategy < actualRecalled) {
                    totalLentToStrategy = 0;
                } else {
                    totalLentToStrategy -= actualRecalled;
                }
            }

            uint256 finalBalance = IERC20(tokens[0]).balanceOf(address(this));
            if (finalBalance < amountOut) {
                amountOut = finalBalance;
            }
        }

        balances[i] -= amountOut;
        _burn(msg.sender, shares);

        IERC20(tokens[i]).safeTransfer(msg.sender, amountOut);
    }

    // =================================================================
    // STRATEGY INTEGRATION
    // =================================================================

    /**
     * @notice Set the yield strategy contract
     * @param _strategy Address of the new strategy
     */
    function setStrategy(address _strategy) external onlyStrategyManager {
        require(_strategy != address(0), "Invalid strategy");
        require(
            totalLentToStrategy == 0 || hasRole(GOVERNANCE_ROLE, msg.sender),
            "Cannot change strategy with active debt"
        );
        strategy = _strategy;
    }

    /**
     * @notice Lend idle MNT to the yield strategy
     * @dev Maintains 30% buffer for liquidity needs
     */
    function lendToStrategy() external onlyKeeper whenNotPaused nonReentrant {
        require(!strategyPaused, "Strategy paused");
        require(strategy != address(0), "Strategy not set");

        uint256 bufferAmount = (balances[0] * 30) / 100;
        uint256 mntInContract = IERC20(tokens[0]).balanceOf(address(this));

        if (mntInContract > bufferAmount) {
            uint256 amountToLend = mntInContract - bufferAmount;

            totalLentToStrategy += amountToLend;

            IERC20(tokens[0]).safeTransfer(strategy, amountToLend);
            IStrategyStMnt(strategy).invest(amountToLend);
        }
    }

    /**
     * @notice Receive profit/loss report from strategy
     * @param _profit Amount of profit generated by strategy
     * @param _loss Amount of loss incurred by strategy
     * @param _newTotalDebt New total debt amount owed by strategy
     */
    function report(
        uint256 _profit,
        uint256 _loss,
        uint256 _newTotalDebt
    ) external onlyStrategyContract {
        require(_profit == 0 || _loss == 0, "Cannot have both profit and loss");

        _updateLockedProfit(_profit, _loss);

        // Update strategy debt tracking
        totalLentToStrategy = _newTotalDebt;

        // Distribute profit to all LP holders
        if (_profit > 0) {
            balances[0] += _profit;
        }

        // Account for losses
        if (_loss > 0) {
            balances[0] -= _loss;
        }
    }

    /**
     * @notice Pause/unpause strategy operations
     * @param _pause True to pause, false to unpause
     */
    function setStrategyInPause(bool _pause) external onlyGuardianOrGovernance {
        strategyPaused = _pause;
    }

    /**
     * @notice Emergency callback from strategy when issues occur
     * @dev Pauses pool, strategy operations, and resets debt accounting
     */
    function callEmergencyCall() external onlyStrategyContract {
        _pause();
        strategyPaused = true;
        totalLentToStrategy = 0; // Strategy returns all funds
        balances[0] = IERC20(tokens[0]).balanceOf(address(this));
    }

    // =================================================================
    // SECURITY AND EMERGENCY FUNCTIONS
    // =================================================================

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
    // GOVERNANCE FUNCTIONS
    // =================================================================

    /**
     * @notice Recover accidentally sent ERC20 tokens
     * @param token Address of token to recover
     * @param to Address to send recovered tokens to
     */
    function recoverERC20(address token, address to) external onlyGovernance {
        require(token != tokens[0], "Cannot recover token 0");
        require(token != tokens[1], "Cannot recover token 1");
        require(token != address(this), "Cannot recover LP tokens");
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    // =================================================================
    // INTERNAL HELPER FUNCTIONS
    // =================================================================

    /**
     * @notice Internal function to recall funds from strategy
     * @param _amount Amount of MNT to recall
     */
    function recallMntfromStrategy(uint256 _amount) internal {
        require(strategy != address(0), "Strategy not set");
        require(totalLentToStrategy >= _amount, "Not enough lent to strategy");
        uint256 _wmntOut = IStrategyStMnt(strategy).poolCallWithdraw(_amount);
        require(_wmntOut >= _amount, "Withdrawn amount is less than requested");

        totalLentToStrategy -= _wmntOut;
    }
}
