// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IVault
 * @notice Interface for staking vault contracts that accept deposits and issue shares
 * @dev Extends IERC20 as vault shares are ERC20 tokens representing ownership stakes
 * @author Your Team
 */
interface IVault is IERC20 {
    // =================================================================
    // CORE VAULT FUNCTIONS
    // =================================================================

    /**
     * @notice Deposits assets into the vault and mints shares to recipient
     * @dev Converts deposited assets to vault shares based on current exchange rate
     * @param amount Amount of underlying assets to deposit
     * @param _recipient Address that will receive the minted vault shares
     * @return shares Amount of vault shares minted to the recipient
     */
    function deposit(
        uint256 amount,
        address _recipient
    ) external returns (uint256 shares);

    /**
     * @notice Withdraws underlying assets by burning vault shares
     * @dev Burns shares from caller and transfers proportional underlying assets
     * @param maxShare Maximum amount of shares to burn for withdrawal
     * @param recipient Address that will receive the withdrawn assets
     * @param maxLoss Maximum acceptable loss during withdrawal (in basis points)
     * @return assets Amount of underlying assets withdrawn
     */
    function withdraw(
        uint256 maxShare,
        address recipient,
        uint256 maxLoss
    ) external returns (uint256 assets);

    // =================================================================
    // PRICING AND VALUATION
    // =================================================================

    /**
     * @notice Returns the current exchange rate between vault shares and underlying assets
     * @dev Represents how many underlying assets each vault share is worth
     * @return price Price per share in underlying asset terms (scaled to 18 decimals)
     */
    function pricePerShare() external view returns (uint256 price);

    // =================================================================
    // BALANCE QUERIES
    // =================================================================

    /**
     * @notice Returns the vault share balance of a specific account
     * @dev Inherited from IERC20 but documented here for clarity
     * @param account Address to query the vault share balance for
     * @return balance Amount of vault shares owned by the account
     */
    function balanceOf(address account) external view returns (uint256 balance);

    function transfer(address account, uint256 amount) external returns (bool);
}
