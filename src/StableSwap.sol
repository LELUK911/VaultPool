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

library Math {
    function abs(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x - y : y - x;
    }
}

contract StableSwap is
    ERC20,
    StableSwapSecurityExtensions,
    ReentrancyGuard,
    AccessControl,
    Pausable
{
    using SafeERC20 for IERC20;

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

    // Number of tokens
    uint256 internal constant N = 2;
    // Amplification coefficient multiplied by N^(N - 1)
    // Higher value makes the curve more flat
    // Lower value makes the curve more like constant product AMM
    uint256 private constant A = 1000 * (N ** (N - 1));
    // 0.03%
    uint256 private constant SWAP_FEE = 300;
    // Liquidity fee is derived from 2 constraints
    // 1. Fee is 0 for adding / removing liquidity that results in a balanced pool
    // 2. Swapping in a balanced pool is like adding and then removing liquidity
    //    from a balanced pool
    // swap fee = add liquidity fee + remove liquidity fee
    uint256 private constant LIQUIDITY_FEE = (SWAP_FEE * N) / (4 * (N - 1));
    uint256 private constant FEE_DENOMINATOR = 1e6;

    address[N] public tokens;
    // Normalize each token to 18 decimals
    // Example - DAI (18 decimals), USDC (6 decimals), USDT (6 decimals)
    uint256[N] private multipliers = [1, 1];
    uint256[N] public balances;

    // 1 share = 1e18, 18 decimals

    //! MODIFICHE PER STRATEGIA
    uint256[N] public balanceInStrategy;

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

    // Return precision-adjusted balances, adjusted to 18 decimals
    /*
    function _xp() private view returns (uint256[N] memory xp) {
        for (uint256 i; i < N; ++i) {
            xp[i] = balances[i] * multipliers[i];
        }
    }*/
    function _xp() private view returns (uint256[N] memory xp) {
        // Saldo di MNT = MNT nel contratto + MNT prestato alla strategy
        xp[0] = (balances[0] + totalLentToStrategy) * multipliers[0];

        // Saldo di stMNT (invariato)
        xp[1] = balances[1] * multipliers[1];
    }

    /**
     * @notice Calculate D, sum of balances in a perfectly balanced pool
     * If balances of x_0, x_1, ... x_(n-1) then sum(x_i) = D
     * @param xp Precision-adjusted balances
     * @return D
     */
    function _getD(uint256[N] memory xp) private pure returns (uint256) {
        /*
        Newton's method to compute D
        -----------------------------
        f(D) = ADn^n + D^(n + 1) / (n^n prod(x_i)) - An^n sum(x_i) - D 
        f'(D) = An^n + (n + 1) D^n / (n^n prod(x_i)) - 1

                     (as + np)D_n
        D_(n+1) = -----------------------
                  (a - 1)D_n + (n + 1)p

        a = An^n
        s = sum(x_i)
        p = (D_n)^(n + 1) / (n^n prod(x_i))
        */
        uint256 a = A * N; // An^n

        uint256 s; // x_0 + x_1 + ... + x_(n-1)
        for (uint256 i; i < N; ++i) {
            s += xp[i];
        }

        // Newton's method
        // Initial guess, d <= s
        uint256 d = s;
        uint256 d_prev;
        for (uint256 i; i < 255; ++i) {
            // p = D^(n + 1) / (n^n * x_0 * ... * x_(n-1))
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
     * @notice Calculate the new balance of token j given the new balance of token i
     * @param i Index of token in
     * @param j Index of token out
     * @param x New balance of token i
     * @param xp Current precision-adjusted balances
     */
    function _getY(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[N] memory xp
    ) private pure returns (uint256) {
        /*
        Newton's method to compute y
        -----------------------------
        y = x_j

        f(y) = y^2 + y(b - D) - c

                    y_n^2 + c
        y_(n+1) = --------------
                   2y_n + b - D

        where
        s = sum(x_k), k != j
        p = prod(x_k), k != j
        b = s + D / (An^n)
        c = D^(n + 1) / (n^n * p * An^n)
        */
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
        // Initial guess, y <= d
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
     * @notice Calculate the new balance of token i given precision-adjusted
     * balances xp and liquidity d
     * @dev Equation is calculate y is same as _getY
     * @param i Index of token to calculate the new balance
     * @param xp Precision-adjusted balances
     * @param d Liquidity d
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
        // Initial guess, y <= d
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

    // Estimate value of 1 share
    // How many tokens is one share worth?
    function getVirtualPrice() public view returns (uint256) {
        //uint256 d = _getD(_xp());
        uint256 d = _getD(_xpWithFreeFunds()); // Use free funds, not total
        uint256 _totalSupply = totalSupply();
        if (_totalSupply > 0) {
            return (d * 10 ** decimals()) / _totalSupply;
        }
        return 0;
    }

    /**
     * @notice Swap dx amount of token i for token j
     * @param i Index of token in
     * @param j Index of token out
     * @param dx Token in amount
     * @param minDy Minimum token out
     */
    function swap(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy
    ) external nonReentrant returns (uint256 dy) {
        //rateLimited sanityCheck  //! non so se lo voglio davvero qui
        require(!emergencyShutdown, "Emergency shutdown active");
        require(i != j, "i = j");

        IERC20(tokens[i]).transferFrom(msg.sender, address(this), dx);

        // Calculate dy (logica invariata)
        uint256[N] memory xp = _xp();
        uint256 x = xp[i] + dx * multipliers[i];

        uint256 y0 = xp[j];
        uint256 y1 = _getY(i, j, x, xp);
        dy = (y0 - y1 - 1) / multipliers[j];

        uint256 fee = (dy * SWAP_FEE) / FEE_DENOMINATOR;
        dy -= fee;
        require(dy >= minDy, "dy < min");

        // ======================= INIZIO MODIFICA LOGICA =======================
        // Se stiamo prelevando MNT (j=0) e non ne abbiamo abbastanza liquidi...
        if (j == 0 && IERC20(tokens[0]).balanceOf(address(this)) < dy) {
            uint256 amountNeeded = dy -
                IERC20(tokens[0]).balanceOf(address(this));
            // ...lo richiamiamo dalla Strategy.
            IStrategyStMnt(strategy).poolCallWithdraw(amountNeeded);
        }
        // ======================== FINE MODIFICA LOGICA ========================

        // Aggiorna la contabilità interna della pool (logica invariata)
        balances[i] += dx;
        balances[j] -= dy;

        // Trasferisci i fondi all'utente (logica invariata)
        IERC20(tokens[j]).transfer(msg.sender, dy);
    }

    function addLiquidity(
        uint256[N] calldata amounts,
        uint256 minShares
    ) external nonReentrant rateLimited sanityCheck returns (uint256 shares) {
        require(!emergencyShutdown, "Emergency shutdown active");

        // Check deposit size limits
        //! se il deposito è ancora zero fallisce sempre, la devo rivedere dopo
        //uint256 totalDeposit = amounts[0] + amounts[1];
        //require(totalDeposit <= _freeFunds() / 10, "Deposit too large");

        // calculate current liquidity d0
        uint256 _totalSupply = totalSupply();
        uint256 d0;
        uint256[N] memory old_xs = _xpWithFreeFunds();
        //uint256[N] memory old_xs = _xp();

        if (_totalSupply > 0) {
            d0 = _getD(old_xs);
        }
        // Transfer tokens in
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

        // Calculate new liquidity d1
        uint256 d1 = _getD(new_xs);
        require(d1 > d0, "liquidity didn't increase");

        // Recalculate D accounting for fee on imbalance
        uint256 d2;
        if (_totalSupply > 0) {
            for (uint256 i; i < N; ++i) {
                // TODO: why old_xs[i] * d1 / d0? why not d1 / N?
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

        // Shares to mint = (d2 - d0) / d0 * total supply
        // d1 >= d2 >= d0
        if (_totalSupply > 0) {
            shares = ((d2 - d0) * _totalSupply) / d0;
        } else {
            shares = d2;
        }
        require(shares >= minShares, "shares < min");
        _mint(msg.sender, shares);
    }

    function removeLiquidity(
        uint256 shares,
        uint256[N] calldata minAmountsOut
    ) external nonReentrant returns (uint256[N] memory amountsOut) {
        require(!emergencyShutdown, "Emergency shutdown active");

        uint256 _totalSupply = totalSupply();

        uint256 mntAmountOut = (balances[0] * shares) / _totalSupply;
        require(mntAmountOut >= minAmountsOut[0], "MNT out < min");

        uint256 stMntAmountOut = (balances[1] * shares) / _totalSupply;
        require(stMntAmountOut >= minAmountsOut[1], "stMNT out < min");

        uint256 liquidMnt = balances[0] - totalLentToStrategy;

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

        //!!DA RIVEDERE HO DELLE RISERVE
        uint256 actualBalance = IERC20(tokens[0]).balanceOf(address(this));
        uint256 actualMntOut = actualBalance < mntAmountOut
            ? actualBalance
            : mntAmountOut;

        balances[0] -= mntAmountOut;
        balances[1] -= stMntAmountOut;

        amountsOut[0] = actualMntOut;
        amountsOut[1] = stMntAmountOut;

        _burn(msg.sender, shares);

        // Trasferisci quello che hai
        IERC20(tokens[0]).safeTransfer(msg.sender, actualMntOut);
        IERC20(tokens[1]).safeTransfer(msg.sender, stMntAmountOut);

        console.log("Requested:", mntAmountOut);
        console.log("Actually transferred:", actualMntOut);
    }

    /**
     * @notice Calculate amount of token i to receive for shares
     * @param shares Shares to burn
     * @param i Index of token to withdraw
     * @return dy Amount of token i to receive
     *         fee Fee for withdraw. Fee already included in dy
     */
    function _calcWithdrawOneToken(
        uint256 shares,
        uint256 i
    ) private view returns (uint256 dy, uint256 fee) {
        uint256 _totalSupply = totalSupply();
        uint256[N] memory xp = _xp();

        // Calculate d0 and d1
        uint256 d0 = _getD(xp);
        uint256 d1 = d0 - (d0 * shares) / _totalSupply;

        // Calculate reduction in y if D = d1
        uint256 y0 = _getYD(i, xp, d1);
        // d1 <= d0 so y must be <= xp[i]
        uint256 dy0 = (xp[i] - y0) / multipliers[i];

        // Calculate imbalance fee, update xp with fees
        uint256 dx;
        for (uint256 j; j < N; ++j) {
            if (j == i) {
                dx = (xp[j] * d1) / d0 - y0;
            } else {
                // d1 / d0 <= 1
                dx = xp[j] - (xp[j] * d1) / d0;
            }
            xp[j] -= (LIQUIDITY_FEE * dx) / FEE_DENOMINATOR;
        }

        // Recalculate y with xp including imbalance fees
        uint256 y1 = _getYD(i, xp, d1);
        // - 1 to round down
        dy = (xp[i] - y1 - 1) / multipliers[i];
        fee = dy0 - dy;
    }

    function calcWithdrawOneToken(
        uint256 shares,
        uint256 i
    ) external view returns (uint256 dy, uint256 fee) {
        return _calcWithdrawOneToken(shares, i);
    }

    /**
     * @notice Withdraw liquidity in token i
     * @param shares Shares to burn
     * @param i Token to withdraw
     * @param minAmountOut Minimum amount of token i that must be withdrawn
     */
    function removeLiquidityOneToken(
        uint256 shares,
        uint256 i,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        (amountOut, ) = _calcWithdrawOneToken(shares, i);
        require(amountOut >= minAmountOut, "out < min");

        // Se si preleva MNT (i=0) e non ce n'è abbastanza, lo richiamiamo
        if (i == 0 && IERC20(tokens[0]).balanceOf(address(this)) < amountOut) {
            IStrategyStMnt(strategy).poolCallWithdraw(
                amountOut - IERC20(tokens[0]).balanceOf(address(this))
            );
        }

        balances[i] -= amountOut;
        _burn(msg.sender, shares);

        IERC20(tokens[i]).safeTransfer(msg.sender, amountOut);
    }

    //!   // =================================================================

    //! FUNZIONI CUSTOMIZATE PER LA STRATEGIA

    address public strategy;
    uint256 public totalLentToStrategy; // Il "debito" che la Strategy ha verso la Pool

    function setStrategy(address _strategy) external onlyStrategyManager {
        strategy = _strategy;
    }

    function lendToStrategy() external onlyKeeper {
        require(strategy != address(0), "Strategy not set");

        // Calcola il 30% del saldo di MNT come buffer
        uint256 bufferAmount = (balances[0] * 30) / 100;
        uint256 mntInContract = IERC20(tokens[0]).balanceOf(address(this));

        if (mntInContract > bufferAmount) {
            uint256 amountToLend = mntInContract - bufferAmount;

            // Aggiorna la contabilità del debito
            totalLentToStrategy += amountToLend;

            // Invia i fondi alla strategy
            IERC20(tokens[0]).safeTransfer(strategy, amountToLend);

            // Chiama la funzione di investimento sulla strategy
            //!PER ORA TENIAMO UN APPROCCIO MANUALE, DEVO CHIAMARE L'HARVEST IO, COSI IMPLEMENTO IL MECCANISCO DI DEGRADAZIONE PER EVITARE EXPLOIT
            IStrategyStMnt(strategy).invest(amountToLend);
        }
    }

    function recallMntfromStrategy(uint256 _amount) internal /*onlyOwner*/ {
        require(strategy != address(0), "Strategy not set");
        require(totalLentToStrategy >= _amount, "Not enough lent to strategy");
        uint256 _wmntOut = IStrategyStMnt(strategy).poolCallWithdraw(_amount);
        require(_wmntOut >= _amount, "Withdrawn amount is less than requested");

        totalLentToStrategy -= _wmntOut;
    }

    function report(
        uint256 _profit,
        uint256 _loss,
        uint256 _newTotalDebt
    ) external {
        require(msg.sender == strategy, "Not a trusted strategy");
        require(_profit == 0 || _loss == 0, "Cannot have both profit and loss");

        _updateLockedProfit(_profit, _loss);

        // Aggiorna il debito totale
        totalLentToStrategy = _newTotalDebt;

        // Se c'è stato un profitto, lo aggiungiamo alla contabilità.
        // Questo aumenta il valore delle quote di tutti gli LP.
        if (_profit > 0) {
            balances[0] += _profit;
        }

        // Se c'è stata una perdita, la sottraiamo.
        if (_loss > 0) {
            balances[0] -= _loss;
        }
    }

    /**
     * @notice Returns total assets including strategy debt
     * @dev This should be implemented in the main contract
     * @return Total assets under management
     */
    function _totalAssets() internal view returns (uint256) {
        return IStrategyStMnt(strategy).estimatedTotalAssets() + balances[0];
    }

    /**
     * @notice Performs a health check and returns results
     * @return isHealthy Whether all sanity checks pass
     */
    function performHealthCheck() external view returns (bool isHealthy) {
        return false; //_performSanityCheck();
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
     * @notice Returns the current free funds available
     * @return Free funds (total assets minus locked profit)
     */
    function getFreeFunds() external view returns (uint256) {
        return _freeFunds();
    }

    function _xpWithFreeFunds() internal view returns (uint256[N] memory xp) {
        uint256 totalMNT = balances[0] + totalLentToStrategy;
        uint256 freeMNT = totalMNT; // Default: all MNT is free

        uint256 totalAssets = _totalAssets();
        uint256 lockedProfit = _calculateLockedProfit();

        // 🛡️ SAFETY: Check for division by zero
        if (totalAssets > 0 && lockedProfit > 0 && totalMNT > 0) {
            uint256 lockedMNT = (lockedProfit * totalMNT) / totalAssets;
            freeMNT = totalMNT > lockedMNT ? totalMNT - lockedMNT : totalMNT;
        }

        xp[0] = freeMNT * multipliers[0];
        xp[1] = balances[1] * multipliers[1];
    }
}
