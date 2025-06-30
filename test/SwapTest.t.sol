// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {StableSwap} from "../src/StableSwap.sol";
import {StrategyStMnt} from "../src/StrategyStMnt.sol";
import {IVault} from "../src/interfaces/IVault.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract SwapTest is Test {
    IWETH public WMNT =
        IWETH(address(0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8));
    IVault public stMNT =
        IVault(address(0xc0205beC85Cbb7f654c4a35d3d1D2a96a2217436));

    StableSwap public pool;
    StrategyStMnt public strategy;

    IVault public stVault =
        IVault(address(0xc0205beC85Cbb7f654c4a35d3d1D2a96a2217436));

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
        vm.stopPrank();

        strategy = new StrategyStMnt(
            address(WMNT),
            address(stVault),
            address(pool)
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
    ) internal {
        vm.startPrank(_user);
        WMNT.approve(address(pool), amountWMNT);
        stMNT.approve(address(pool), amountStMNT);
        pool.addLiquidity([amountWMNT, amountStMNT], 0);
        vm.stopPrank();
    }


    function testFirstSetup() public {
        setUpPoolAndStrategy();
    }

    function testDepositInPool() public {
        setUpPoolAndStrategy();
        giveMeWMNT(alice, 300 ether);
        giveMeStMNT(alice, 110 ether);

        // ✅ AGGIUNGI QUESTE VERIFICHE:

        // 1. Record before
        uint256 aliceWMNTBefore = WMNT.balanceOf(alice);
        uint256 aliceStMNTBefore = stMNT.balanceOf(alice);
        uint256 poolWMNTBefore = WMNT.balanceOf(address(pool));
        uint256 poolStMNTBefore = stMNT.balanceOf(address(pool));

        depositInPool(alice, 100 ether, 100 ether);

        // 2. Verify after
        console.log("=== LIQUIDITY VERIFICATION ===");

        // Check Alice's tokens were transferred
        assertEq(
            WMNT.balanceOf(alice),
            aliceWMNTBefore - 100 ether,
            "Alice WMNT not transferred"
        );
        assertEq(
            stMNT.balanceOf(alice),
            aliceStMNTBefore - 100 ether,
            "Alice stMNT not transferred"
        );

        // Check pool received the tokens
        assertEq(
            WMNT.balanceOf(address(pool)),
            poolWMNTBefore + 100 ether,
            "Pool didn't receive WMNT"
        );
        assertEq(
            stMNT.balanceOf(address(pool)),
            poolStMNTBefore + 100 ether,
            "Pool didn't receive stMNT"
        );

        // Check Alice received LP shares
        uint256 aliceShares = pool.balanceOf(alice);
        assertGt(aliceShares, 0, "Alice should have LP shares");

        // Check total supply increased
        assertGt(pool.totalSupply(), 0, "Total LP supply should be > 0");

        // Check pool internal accounting
        assertEq(
            pool.balances(0),
            100 ether,
            "Pool balance[0] should be 100 ether"
        );
        assertEq(
            pool.balances(1),
            100 ether,
            "Pool balance[1] should be 100 ether"
        );

        console.log(" Pool WMNT balance:", WMNT.balanceOf(address(pool)));
        console.log(" Pool stMNT balance:", stMNT.balanceOf(address(pool)));
        console.log(" Alice LP shares:", aliceShares);
        console.log(" Total LP supply:", pool.totalSupply());
        console.log(" Virtual price:", pool.getVirtualPrice());

        console.log(" LIQUIDITY DEPOSIT SUCCESSFUL!");
    }

    function testFirstSwap() public {
        // Setup and initial liquidity
        setUpPoolAndStrategy();
        giveMeWMNT(alice, 1300 ether);
        giveMeStMNT(alice, 110 ether);
        depositInPool(alice, 100 ether, 100 ether);

        // Give tokens to Bob for swapping
        giveMeWMNT(bob, 1300 ether);
        giveMeStMNT(bob, 300 ether);

        console.log("=== INITIAL POOL STATE ===");
        console.log("Pool WMNT:", WMNT.balanceOf(address(pool)));
        console.log("Pool stMNT:", stMNT.balanceOf(address(pool)));
        console.log("Virtual Price:", pool.getVirtualPrice());

        // =================================================================
        // 🔄 SWAP 1: Bob buys 1 stMNT with WMNT
        // =================================================================

        console.log(unicode"\n=== SWAP 1: WMNT → stMNT ===");
        uint256 bobWMNTBefore = WMNT.balanceOf(bob);
        uint256 bobStMNTBefore = stMNT.balanceOf(bob);
        uint256 poolWMNTBefore = WMNT.balanceOf(address(pool));
        uint256 poolStMNTBefore = stMNT.balanceOf(address(pool));

        // Bob swaps 1 WMNT for stMNT
        uint256 stMNTReceived = buyStMNt(bob, 1 ether);

        console.log("Bob paid WMNT:", bobWMNTBefore - WMNT.balanceOf(bob));
        console.log("Bob received stMNT:", stMNTReceived);
        console.log("Pool WMNT after:", WMNT.balanceOf(address(pool)));
        console.log("Pool stMNT after:", stMNT.balanceOf(address(pool)));
        console.log("Virtual Price after:", pool.getVirtualPrice());

        // Verify swap 1
        assertEq(
            WMNT.balanceOf(bob),
            bobWMNTBefore - 1 ether,
            "Bob should pay 1 WMNT"
        );
        assertGt(stMNTReceived, 0, "Bob should receive stMNT");
        assertEq(
            WMNT.balanceOf(address(pool)),
            poolWMNTBefore + 1 ether,
            "Pool should gain 1 WMNT"
        );
        assertEq(
            stMNT.balanceOf(address(pool)),
            poolStMNTBefore - stMNTReceived,
            "Pool should lose stMNT"
        );

        // =================================================================
        // 🔄 SWAP 2: Bob sells stMNT for WMNT (reverse)
        // =================================================================

        console.log(unicode"\n=== SWAP 2: stMNT → WMNT ===");
        uint256 bobWMNTBefore2 = WMNT.balanceOf(bob);
        uint256 bobStMNTBefore2 = stMNT.balanceOf(bob);
        uint256 poolWMNTBefore2 = WMNT.balanceOf(address(pool));
        uint256 poolStMNTBefore2 = stMNT.balanceOf(address(pool));

        // Bob sells 0.5 stMNT for WMNT
        uint256 wmntReceived = sellStMNt(bob, 0.5 ether);

        console.log("Bob paid stMNT:", bobStMNTBefore2 - stMNT.balanceOf(bob));
        console.log("Bob received WMNT:", wmntReceived);
        console.log("Pool WMNT after:", WMNT.balanceOf(address(pool)));
        console.log("Pool stMNT after:", stMNT.balanceOf(address(pool)));
        console.log("Virtual Price after:", pool.getVirtualPrice());

        // Verify swap 2
        assertEq(
            stMNT.balanceOf(bob),
            bobStMNTBefore2 - 0.5 ether,
            "Bob should pay 0.5 stMNT"
        );
        assertGt(wmntReceived, 0, "Bob should receive WMNT");
        assertEq(
            stMNT.balanceOf(address(pool)),
            poolStMNTBefore2 + 0.5 ether,
            "Pool should gain 0.5 stMNT"
        );
        assertEq(
            WMNT.balanceOf(address(pool)),
            poolWMNTBefore2 - wmntReceived,
            "Pool should lose WMNT"
        );

        // =================================================================
        // 🔄 SWAP 3: Larger swap - 10 WMNT → stMNT
        // =================================================================

        console.log(unicode"\n=== SWAP 3: Large WMNT → stMNT ===");
        uint256 bobWMNTBefore3 = WMNT.balanceOf(bob);
        uint256 bobStMNTBefore3 = stMNT.balanceOf(bob);
        uint256 poolWMNTBefore3 = WMNT.balanceOf(address(pool));
        uint256 poolStMNTBefore3 = stMNT.balanceOf(address(pool));
        uint256 virtualPriceBefore3 = pool.getVirtualPrice();

        // Bob swaps 10 WMNT for stMNT
        uint256 stMNTReceived3 = buyStMNt(bob, 10 ether);

        console.log("Bob paid WMNT:", bobWMNTBefore3 - WMNT.balanceOf(bob));
        console.log("Bob received stMNT:", stMNTReceived3);
        console.log("Pool WMNT after:", WMNT.balanceOf(address(pool)));
        console.log("Pool stMNT after:", stMNT.balanceOf(address(pool)));
        console.log("Virtual Price after:", pool.getVirtualPrice());
        console.log(
            "Price impact:",
            int256(pool.getVirtualPrice()) - int256(virtualPriceBefore3)
        );

        // Verify swap 3
        assertEq(
            WMNT.balanceOf(bob),
            bobWMNTBefore3 - 10 ether,
            "Bob should pay 10 WMNT"
        );
        assertGt(stMNTReceived3, 0, "Bob should receive stMNT");
        assertLt(
            stMNTReceived3,
            10 ether,
            "Should receive less than 10 stMNT due to slippage"
        );

        // =================================================================
        // 🔄 SWAP 4: Even larger reverse swap - 8 stMNT → WMNT
        // =================================================================

        console.log(unicode"\n=== SWAP 4: Large stMNT → WMNT ===");
        uint256 bobWMNTBefore4 = WMNT.balanceOf(bob);
        uint256 bobStMNTBefore4 = stMNT.balanceOf(bob);
        uint256 poolWMNTBefore4 = WMNT.balanceOf(address(pool));
        uint256 poolStMNTBefore4 = stMNT.balanceOf(address(pool));
        uint256 virtualPriceBefore4 = pool.getVirtualPrice();

        // Bob sells 8 stMNT for WMNT
        uint256 wmntReceived4 = sellStMNt(bob, 8 ether);

        console.log("Bob paid stMNT:", bobStMNTBefore4 - stMNT.balanceOf(bob));
        console.log("Bob received WMNT:", wmntReceived4);
        console.log("Pool WMNT after:", WMNT.balanceOf(address(pool)));
        console.log("Pool stMNT after:", stMNT.balanceOf(address(pool)));
        console.log("Virtual Price after:", pool.getVirtualPrice());
        console.log(
            "Price impact:",
            int256(pool.getVirtualPrice()) - int256(virtualPriceBefore4)
        );

        // Verify swap 4
        assertEq(
            stMNT.balanceOf(bob),
            bobStMNTBefore4 - 8 ether,
            "Bob should pay 8 stMNT"
        );
        assertGt(wmntReceived4, 0, "Bob should receive WMNT");
        assertLt(
            wmntReceived4,
            8 ether,
            "Should receive less than 8 WMNT due to slippage"
        );

        // =================================================================
        // 📊 FINAL VERIFICATION & SUMMARY
        // =================================================================

        console.log("\n=== FINAL POOL STATE ===");
        console.log("Final Pool WMNT:", WMNT.balanceOf(address(pool)));
        console.log("Final Pool stMNT:", stMNT.balanceOf(address(pool)));
        console.log("Final Virtual Price:", pool.getVirtualPrice());
        console.log("Final Pool Balance[0]:", pool.balances(0));
        console.log("Final Pool Balance[1]:", pool.balances(1));

        // Check that pool still has liquidity
        assertGt(
            WMNT.balanceOf(address(pool)),
            0,
            "Pool should still have WMNT"
        );
        assertGt(
            stMNT.balanceOf(address(pool)),
            0,
            "Pool should still have stMNT"
        );

        // Check that virtual price is reasonable (should be close to 1.0)
        uint256 finalVirtualPrice = pool.getVirtualPrice();
        assertGt(
            finalVirtualPrice,
            0.9 ether,
            "Virtual price shouldn't deviate too much"
        );
        assertLt(
            finalVirtualPrice,
            1.1 ether,
            "Virtual price shouldn't deviate too much"
        );

        // Verify pool accounting integrity
        uint256 totalPoolTokens = WMNT.balanceOf(address(pool)) +
            stMNT.balanceOf(address(pool));
        assertGt(
            totalPoolTokens,
            150 ether,
            "Pool should maintain significant liquidity"
        );

      
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
}
