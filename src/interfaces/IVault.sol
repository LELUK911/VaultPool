// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IVault is IERC20 {
    function deposit(uint256 amount, address _recipient) external returns (uint256);


    function pricePerShare() external view returns (uint256);

    function withdraw(
        uint256 maxShare,
        address recipient,
        uint256 maxLoss
    ) external returns (uint256);

    function balanceOf(address account) external view returns (uint256);

}