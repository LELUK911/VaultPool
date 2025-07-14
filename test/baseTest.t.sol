// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {StableSwap} from "../src/StableSwap.sol";
import {StrategyStMnt} from "../src/StrategyStMnt.sol";
import {IVault} from "../src/interfaces/IVault.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface StrategyAPI {
    function harvest() external;
}

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256) external;

    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);
}

contract MyToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract BaseTest is Test {
    IWETH public WMNT =
        IWETH(address(0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8));
    IVault public stMNT =
        IVault(address(0xc0205beC85Cbb7f654c4a35d3d1D2a96a2217436));

    StableSwap public pool;
    StrategyStMnt public strategy;

    IVault public stVault =
        IVault(address(0xc0205beC85Cbb7f654c4a35d3d1D2a96a2217436));

    StrategyAPI public strategy1st =
        StrategyAPI(address(0x0BDFBb46a717d4C881874d210cf6820AF0F069AF));

    StrategyAPI public strategy2nd =
        StrategyAPI(address(0x08fe7C489E6788fCdCcf9ebf3343f6B263eA5B7D));

    address public VAULT_KEEPER =
        address(0x6c1Ad07DA4C95c3D9Da4174F52C87401e9Ca3098);

    address public owner = address(0x123); // owner fa tutti i ruoli all'inizio

    address public alice = address(0x001);
    address public bob = address(0x002);
    address public carol = address(0x003);
    address public dave = address(0x004);

    function setUpPoolAndStrategy() internal {
        // Create the pool
        pool = new StableSwap(
            [address(WMNT), address(stMNT)],
            owner,
            owner,
            owner
        );

        vm.startPrank(owner);
        pool.grantRole(pool.STRATEGY_MANAGER_ROLE(), owner);
        pool.grantRole(pool.KEEPER_ROLE(), owner);
        vm.stopPrank();

        strategy = new StrategyStMnt(
            address(WMNT),
            address(stVault),
            address(pool),
            owner,
            owner,
            owner
        );

        vm.startPrank(owner);

        pool.setStrategy(address(strategy));

        strategy.updateUnlimitedSpendingPool(true);
        strategy.updateUnlimitedSpendingVault(true);
        vm.stopPrank();
    }

    function giveMeWMNT(address _user, uint256 amount) internal {
        vm.startPrank(_user);
        vm.deal(_user, amount);
        WMNT.deposit{value: amount}();
        vm.stopPrank();
    }

    function giveMeStMNT(address _user, uint256 amount) internal {
        vm.startPrank(_user);
        WMNT.approve(address(stMNT), amount);
        stMNT.deposit(amount, _user);
        vm.stopPrank();
    }

    function depositInPool(
        address _user,
        uint256 amountWMNT,
        uint256 amountStMNT
    ) internal returns (uint256 shares) {
        vm.startPrank(_user);
        WMNT.approve(address(pool), amountWMNT);
        stMNT.approve(address(pool), amountStMNT);
        shares = pool.addLiquidity([amountWMNT, amountStMNT], 0);
        vm.stopPrank();
    }

    function buyStMNt(
        address user,
        uint256 wmntAmount
    ) internal returns (uint256 stMNTReceived) {
        vm.startPrank(user);

        // Approve WMNT
        WMNT.approve(address(pool), wmntAmount);

        // Record before
        uint256 stMNTBefore = stMNT.balanceOf(user);

        // Swap: WMNT (index 0) → stMNT (index 1)
        pool.swap(0, 1, wmntAmount, 0);

        // Calculate received
        stMNTReceived = stMNT.balanceOf(user) - stMNTBefore;

        vm.stopPrank();
    }

    function sellStMNt(
        address user,
        uint256 stMNTAmount
    ) internal returns (uint256 wmntReceived) {
        vm.startPrank(user);

        // Approve stMNT
        stMNT.approve(address(pool), stMNTAmount);

        // Record before
        uint256 wmntBefore = WMNT.balanceOf(user);

        // Swap: stMNT (index 1) → WMNT (index 0)
        pool.swap(1, 0, stMNTAmount, 0);

        // Calculate received
        wmntReceived = WMNT.balanceOf(user) - wmntBefore;

        vm.stopPrank();
    }

    function withdrawOneToken(
        address user,
        uint256 shares,
        uint256 tokenIndex
    ) internal returns (uint256 amountReceived) {
        vm.startPrank(user);

        // Record balance before
        address tokenAddress = tokenIndex == 0 ? address(WMNT) : address(stMNT);
        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(user);

        // Withdraw one token
        amountReceived = pool.removeLiquidityOneToken(shares, tokenIndex, 0);

        // Verify balance change matches returned amount
        uint256 balanceAfter = IERC20(tokenAddress).balanceOf(user);
        uint256 actualReceived = balanceAfter - balanceBefore;

        //assertEq(
        //    amountReceived,
        //    actualReceived,
        //    "Returned amount should match balance change"
        //);

        vm.stopPrank();
    }

    function withdrawLiquidity(
        address user,
        uint256 shares
    ) internal returns (uint256 wmntReceived, uint256 stMNTReceived) {
        vm.startPrank(user);

        // Record balances before
        uint256 wmntBefore = WMNT.balanceOf(user);
        uint256 stMNTBefore = stMNT.balanceOf(user);

        // Withdraw liquidity
        uint256[2] memory minAmounts = [uint256(0), uint256(0)]; // Accept any amount
        uint256[2] memory amountsOut = pool.removeLiquidity(shares, minAmounts);

        // Calculate received amounts
        wmntReceived = WMNT.balanceOf(user) - wmntBefore;
        stMNTReceived = stMNT.balanceOf(user) - stMNTBefore;

        // Verify they match the returned values
        assertEq(
            wmntReceived,
            amountsOut[0],
            "WMNT received should match returned value"
        );
        assertEq(
            stMNTReceived,
            amountsOut[1],
            "stMNT received should match returned value"
        );

        vm.stopPrank();
    }

    function harvestStrategyAction() internal {
        vm.prank(owner);
        strategy.harvest();
    }

    function lendtoStrategyAction() internal {
        vm.prank(owner);
        pool.lendToStrategy();
    }

    function harvestStrategyActionInVault() internal {
        vm.prank(VAULT_KEEPER);
        strategy1st.harvest();
        skip(5 seconds); // Simulate time passing for the next harvest
        vm.prank(VAULT_KEEPER);
        strategy2nd.harvest();
        skip(5 seconds); // Simulate time passing for the next harvest
    }

    function emergencyCallStrAndPool(address _user) internal {
        vm.prank(_user);
        strategy.emergencyWithdrawAll();
    }

    function setStrategyInPause(address _user, bool _pause) internal {
        vm.prank(_user);
        pool.setStrategyInPause(_pause);
    }

    function recoverERC20Strategy(
        address _user,
        address token,
        address to
    ) internal {
        vm.prank(_user);
        strategy.recoverERC20(token, to);
    }

    function recoverERC20Pool(
        address _user,
        address token,
        address to
    ) internal {
        vm.prank(_user);
        pool.recoverERC20(token, to);
    }



    function sync() internal {
        vm.prank(owner);
        pool.sync();
        console.log("Sync submitted");
    }
}
