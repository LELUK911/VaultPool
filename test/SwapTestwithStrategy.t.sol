// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseTest} from "./baseTest.t.sol";

contract SwapTestWithStrategy is BaseTest {
    function harvestingTime(uint24 _days) internal {
        skip(_days * 1 days);
        harvestStrategyActionInVault();
    }

    function testMultiUserOperations() public {
        // === SETUP ===
        setUpPoolAndStrategy();

        console.log("=== INITIAL SETUP ===");

        // Give tokens to all users
        giveMeWMNT(alice, 2000 ether);
        giveMeStMNT(alice, 1000 ether);
        giveMeWMNT(bob, 1500 ether);
        giveMeStMNT(bob, 800 ether);
        giveMeWMNT(carol, 1200 ether);
        giveMeStMNT(carol, 600 ether);
        giveMeWMNT(dave, 1000 ether);
        giveMeStMNT(dave, 500 ether);

        // === PHASE 1: INITIAL LIQUIDITY PROVIDERS ===
        console.log("\n=== PHASE 1: INITIAL LIQUIDITY ===");

        // Alice: Big LP
        uint256 aliceShares = depositInPool(alice, 800 ether, 700 ether);
        console.log("Alice shares received:", aliceShares);

        // Bob: Medium LP
        uint256 bobShares = depositInPool(bob, 400 ether, 350 ether);
        console.log("Bob shares received:", bobShares);

        lendtoStrategyAction();

        uint256 poolBalance0 = pool.balances(0);
        uint256 poolBalance1 = pool.balances(1);
        uint256 totalLent = pool.totalLentToStrategy();
        console.log("Pool WMNT balance:", poolBalance0);
        console.log("Pool stMNT balance:", poolBalance1);
        console.log("Total lent to strategy:", totalLent);

        // === PHASE 2: GENERATE SOME YIELD ===
        console.log("\n=== PHASE 2: GENERATE YIELD ===");

        harvestingTime(15);
        skip(8 hours);
        harvestStrategyAction();

        uint256 virtualPrice1 = pool.getVirtualPrice();
        console.log("Virtual price after first harvest:", virtualPrice1);

        // === PHASE 3: MULTIPLE SWAPS ===
        console.log("\n=== PHASE 3: SWAP FRENZY ===");

        // Carol: Series of swaps
        uint256 carolStMNT1 = buyStMNt(carol, 50 ether);
        console.log("Carol stMNT received:", carolStMNT1);

        uint256 carolWMNT1 = sellStMNt(carol, 25 ether);
        console.log("Carol WMNT received:", carolWMNT1);

        // Dave: Counter-swaps
        uint256 daveWMNT1 = sellStMNt(dave, 80 ether);
        console.log("Dave WMNT received:", daveWMNT1);

        uint256 daveStMNT1 = buyStMNt(dave, 60 ether);
        console.log("Dave stMNT received:", daveStMNT1);

        // === PHASE 4: MORE LIQUIDITY PROVIDERS ===
        console.log("\n=== PHASE 4: NEW LP JOINS ===");

        // Carol decides to provide liquidity too
        uint256 carolShares = depositInPool(carol, 300 ether, 250 ether);
        console.log("Carol shares received:", carolShares);

        uint256 totalSupply1 = pool.totalSupply();
        console.log("Total pool shares:", totalSupply1);

        // === PHASE 5: MORE YIELD GENERATION ===
        console.log("\n=== PHASE 5: MORE YIELD ===");

        harvestingTime(20);
        skip(6 hours);
        harvestStrategyAction();

        uint256 virtualPrice2 = pool.getVirtualPrice();
        console.log("Virtual price after second harvest:", virtualPrice2);

        // === PHASE 6: INTENSE SWAP ACTIVITY ===
        console.log("\n=== PHASE 6: INTENSE TRADING ===");

        // Bob: Large swaps
        uint256 bobStMNT2 = buyStMNt(bob, 200 ether);
        console.log("Bob stMNT received:", bobStMNT2);

        // Alice: Counter-trade
        uint256 aliceWMNT1 = sellStMNt(alice, 150 ether);
        console.log("Alice WMNT received:", aliceWMNT1);

        // Dave: More small trades
        uint256 daveStMNT2 = buyStMNt(dave, 30 ether);
        console.log("Dave stMNT received:", daveStMNT2);
        uint256 daveWMNT2 = sellStMNt(dave, 40 ether);
        console.log("Dave WMNT received:", daveWMNT2);

        // === PHASE 7: PARTIAL WITHDRAWALS ===
        console.log("\n=== PHASE 7: SOME USERS EXIT ===");

        // Bob withdraws half his liquidity
        uint256 bobWithdrawShares = bobShares / 2;
        (uint256 bobWMNTOut, uint256 bobStMNTOut) = withdrawLiquidity(
            bob,
            bobWithdrawShares
        );
        console.log("Bob shares withdrawn:", bobWithdrawShares);
        console.log("Bob WMNT received:", bobWMNTOut);
        console.log("Bob stMNT received:", bobStMNTOut);

        // === PHASE 8: FINAL YIELD AND VERIFICATION ===
        console.log("\n=== PHASE 8: FINAL VERIFICATION ===");

        harvestingTime(10);
        skip(8 hours);
        harvestStrategyAction();

        uint256 finalVirtualPrice = pool.getVirtualPrice();
        uint256 finalTotalSupply = pool.totalSupply();
        uint256 finalPoolBalance0 = pool.balances(0);
        uint256 finalPoolBalance1 = pool.balances(1);
        uint256 finalTotalLent = pool.totalLentToStrategy();
        uint256 finalStrategyAssets = strategy.estimatedTotalAssets();

        console.log("\n=== FINAL STATE ===");
        console.log("Final virtual price:", finalVirtualPrice);
        console.log("Final total supply:", finalTotalSupply);
        console.log("Final pool WMNT balance:", finalPoolBalance0);
        console.log("Final pool stMNT balance:", finalPoolBalance1);
        console.log("Final total lent:", finalTotalLent);
        console.log("Final strategy assets:", finalStrategyAssets);

        // === COHERENCE CHECKS ===
        console.log("\n=== COHERENCE CHECKS ===");

        // 1. Virtual price should have increased (yield generation)
        assertGt(
            finalVirtualPrice,
            virtualPrice1,
            "Virtual price should increase over time"
        );
        console.log("Virtual price start:", virtualPrice1);
        console.log("Virtual price end:", finalVirtualPrice);

        // 2. Total supply should be reasonable (some withdrawals happened)
        assertLt(
            finalTotalSupply,
            totalSupply1,
            "Total supply should decrease after withdrawals"
        );
        console.log("Total supply start:", totalSupply1);
        console.log("Total supply end:", finalTotalSupply);

        // 3. System should still have assets
        uint256 totalSystemAssets = finalPoolBalance0 + finalStrategyAssets;
        assertGt(totalSystemAssets, 0, "System should have assets");
        console.log("Total system assets:", totalSystemAssets);

        // 4. Pool balances should be reasonable
        assertGt(finalPoolBalance0, 0, "Pool should have WMNT");
        assertGt(finalPoolBalance1, 0, "Pool should have stMNT");
        console.log("Pool WMNT:", finalPoolBalance0);
        console.log("Pool stMNT:", finalPoolBalance1);

        // 5. Strategy should still have significant assets
        assertGt(
            finalStrategyAssets,
            100 ether,
            "Strategy should have meaningful assets"
        );
        console.log("Strategy assets:", finalStrategyAssets);

        // === USER BALANCE CHECKS ===
        console.log("\n=== USER FINAL BALANCES ===");

        console.log("Alice WMNT:", WMNT.balanceOf(alice));
        console.log("Alice stMNT:", stMNT.balanceOf(alice));
        console.log("Alice Shares:", pool.balanceOf(alice));
        console.log("Bob WMNT:", WMNT.balanceOf(bob));
        console.log("Bob stMNT:", stMNT.balanceOf(bob));
        console.log("Bob Shares:", pool.balanceOf(bob));
        console.log("Carol WMNT:", WMNT.balanceOf(carol));
        console.log("Carol stMNT:", stMNT.balanceOf(carol));
        console.log("Carol Shares:", pool.balanceOf(carol));
        console.log("Dave WMNT:", WMNT.balanceOf(dave));
        console.log("Dave stMNT:", stMNT.balanceOf(dave));
        console.log("Dave Shares:", pool.balanceOf(dave));

        // All users should have some tokens (no one should be completely drained)
        assertGt(
            WMNT.balanceOf(alice) + stMNT.balanceOf(alice),
            0,
            "Alice should have tokens"
        );
        assertGt(
            WMNT.balanceOf(bob) + stMNT.balanceOf(bob),
            0,
            "Bob should have tokens"
        );
        assertGt(
            WMNT.balanceOf(carol) + stMNT.balanceOf(carol),
            0,
            "Carol should have tokens"
        );
        assertGt(
            WMNT.balanceOf(dave) + stMNT.balanceOf(dave),
            0,
            "Dave should have tokens"
        );

        console.log("\n ALL COHERENCE CHECKS PASSED! SYSTEM IS STABLE! ");
    }
}
