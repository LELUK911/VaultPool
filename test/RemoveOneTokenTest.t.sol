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

    function testRemoveLiquidityOneToken() public {
        setUpPoolAndStrategy();

        // === SETUP MULTIPLE LPs FOR REALISTIC SCENARIO ===
        giveMeWMNT(alice, 2000 ether);
        giveMeStMNT(alice, 1000 ether);
        giveMeWMNT(bob, 1500 ether);
        giveMeStMNT(bob, 800 ether);
        giveMeWMNT(carol, 1000 ether);
        giveMeStMNT(carol, 600 ether);

        console.log("=== INITIAL MULTI-LP SETUP ===");

        // Alice: Big LP - provides base liquidity
        uint256 aliceShares = depositInPool(alice, 800 ether, 700 ether);
        console.log("Alice shares received:", aliceShares);

        // Bob: Medium LP - provides more liquidity
        uint256 bobShares = depositInPool(bob, 600 ether, 500 ether);
        console.log("Bob shares received:", bobShares);

        // Carol: Small LP - provides additional depth
        uint256 carolShares = depositInPool(carol, 400 ether, 300 ether);
        console.log("Carol shares received:", carolShares);

        lendtoStrategyAction();

        // Pool state after initial setup
        uint256 poolBalance0Initial = pool.balances(0);
        uint256 poolBalance1Initial = pool.balances(1);
        uint256 totalSupplyInitial = pool.totalSupply();
        uint256 totalLentInitial = pool.totalLentToStrategy();

        console.log("=== AFTER INITIAL SETUP ===");
        console.log("Pool WMNT balance:", poolBalance0Initial);
        console.log("Pool stMNT balance:", poolBalance1Initial);
        console.log("Total supply:", totalSupplyInitial);
        console.log("Total lent to strategy:", totalLentInitial);
        console.log("Virtual price:", pool.getVirtualPrice());

        // === GENERATE YIELD ===
        console.log("=== GENERATING YIELD ===");
        skip(15 days);
        harvestStrategyActionInVault();
        skip(8 hours);
        harvestStrategyAction();
        skip(10 days);
        harvestStrategyActionInVault();
        skip(8 hours);
        harvestStrategyAction();
        skip(8 hours); // Full degradation

        // Pool state before withdrawal
        uint256 poolBalance0Before = pool.balances(0);
        uint256 poolBalance1Before = pool.balances(1);
        uint256 totalSupplyBefore = pool.totalSupply();
        uint256 virtualPriceBefore = pool.getVirtualPrice();

        console.log("=== BEFORE SINGLE TOKEN WITHDRAWAL ===");
        console.log("Pool WMNT balance:", poolBalance0Before);
        console.log("Pool stMNT balance:", poolBalance1Before);
        console.log("Total supply:", totalSupplyBefore);
        console.log("Virtual price:", virtualPriceBefore);

        // === BOB WITHDRAWS ONLY WMNT (REALISTIC SCENARIO) ===
        console.log("=== BOB SINGLE TOKEN WITHDRAWAL ===");

        // Bob wants to withdraw 1/3 of his shares as WMNT only
        uint256 bobWithdrawShares = bobShares / 3;
        console.log("Bob withdrawing shares:", bobWithdrawShares);
        console.log("Bob total shares:", bobShares);
        console.log(
            "Bob withdrawal percentage:",
            (bobWithdrawShares * 100) / bobShares
        );

        // Calculate expected amount and fee
        (uint256 expectedWMNT, uint256 expectedFee) = pool.calcWithdrawOneToken(
            bobWithdrawShares,
            0
        );
        console.log("Expected WMNT out:", expectedWMNT);
        console.log("Expected fee:", expectedFee);
        console.log("Fee percentage:", (expectedFee * 10000) / expectedWMNT);

        // Record Bob's balance before
        uint256 bobWMNTBefore = WMNT.balanceOf(bob);
        uint256 bobSharesBefore = pool.balanceOf(bob);

        console.log("Bob WMNT before:", bobWMNTBefore);
        console.log("Bob shares before:", bobSharesBefore);

        // Perform single token withdrawal
        uint256 actualWMNTReceived = withdrawOneToken(
            bob,
            bobWithdrawShares,
            0
        ); // 0 = WMNT

        // Record Bob's balance after
        uint256 bobWMNTAfter = WMNT.balanceOf(bob);
        uint256 bobSharesAfter = pool.balanceOf(bob);

        console.log("=== WITHDRAWAL RESULTS ===");
        console.log("Actual WMNT received:", actualWMNTReceived);
        console.log("Bob WMNT after:", bobWMNTAfter);
        console.log("Bob shares after:", bobSharesAfter);
        console.log("WMNT balance change:", bobWMNTAfter - bobWMNTBefore);
        console.log("Shares burned:", bobSharesBefore - bobSharesAfter);

        // === CAROL WITHDRAWS ONLY stMNT ===
        console.log("=== CAROL SINGLE TOKEN WITHDRAWAL ===");

        // Carol wants to withdraw 1/4 of her shares as stMNT only
        uint256 carolWithdrawShares = carolShares / 4;
        console.log("Carol withdrawing shares:", carolWithdrawShares);

        (uint256 expectedStMNT, uint256 expectedFeeStMNT) = pool
            .calcWithdrawOneToken(carolWithdrawShares, 1);
        console.log("Expected stMNT out:", expectedStMNT);
        console.log("Expected fee stMNT:", expectedFeeStMNT);

        uint256 carolStMNTBefore = stMNT.balanceOf(carol);
        uint256 actualStMNTReceived = withdrawOneToken(
            carol,
            carolWithdrawShares,
            1
        ); // 1 = stMNT
        uint256 carolStMNTAfter = stMNT.balanceOf(carol);

        console.log("Actual stMNT received:", actualStMNTReceived);
        console.log("Carol stMNT change:", carolStMNTAfter - carolStMNTBefore);

        // === POOL STATE AFTER WITHDRAWALS ===
        uint256 poolBalance0After = pool.balances(0);
        uint256 poolBalance1After = pool.balances(1);
        uint256 totalSupplyAfter = pool.totalSupply();
        uint256 virtualPriceAfter = pool.getVirtualPrice();

        console.log("=== POOL STATE AFTER WITHDRAWALS ===");
        console.log("Pool WMNT balance after:", poolBalance0After);
        console.log("Pool stMNT balance after:", poolBalance1After);
        console.log("Total supply after:", totalSupplyAfter);
        console.log("Virtual price after:", virtualPriceAfter);

        // === COHERENCE CHECKS ===
        console.log("=== COHERENCE CHECKS ===");

        // 1. Received amounts should match expected (within tolerance)
        uint256 wmntDifference = expectedWMNT > actualWMNTReceived
            ? expectedWMNT - actualWMNTReceived
            : actualWMNTReceived - expectedWMNT;
        uint256 wmntTolerance = expectedWMNT / 1000; // 0.1% tolerance
        assertLt(
            wmntDifference,
            wmntTolerance,
            "WMNT withdrawal should be within tolerance"
        );
        console.log("WMNT tolerance check passed");

        uint256 stmntDifference = expectedStMNT > actualStMNTReceived
            ? expectedStMNT - actualStMNTReceived
            : actualStMNTReceived - expectedStMNT;
        uint256 stmntTolerance = expectedStMNT / 1000; // 0.1% tolerance
        assertLt(
            stmntDifference,
            stmntTolerance,
            "stMNT withdrawal should be within tolerance"
        );
        console.log("stMNT tolerance check passed");

        // 2. Shares should have been burned correctly
        assertEq(
            pool.balanceOf(bob),
            bobShares - bobWithdrawShares,
            "Bob shares should be reduced correctly"
        );
        assertEq(
            pool.balanceOf(carol),
            carolShares - carolWithdrawShares,
            "Carol shares should be reduced correctly"
        );
        console.log("Share burning check passed");

        // 3. Pool should still be balanced and functional
        assertGt(poolBalance0After, 0, "Pool should still have WMNT");
        assertGt(poolBalance1After, 0, "Pool should still have stMNT");
        assertGt(
            totalSupplyAfter,
            0,
            "Pool should still have shares outstanding"
        );
        console.log("Pool balance check passed");

        // 4. Virtual price should not decrease significantly (small fee impact)
        assertGe(
            virtualPriceAfter * 1000,
            virtualPriceBefore * 995,
            "Virtual price should not drop more than 0.5%"
        );
        console.log("Virtual price stability check passed");

        // 5. Alice (non-withdrawing LP) should not be negatively affected
        uint256 aliceValueBefore = (aliceShares * virtualPriceBefore) / 1e18;
        uint256 aliceValueAfter = (aliceShares * virtualPriceAfter) / 1e18;
        assertGe(
            aliceValueAfter * 1000,
            aliceValueBefore * 995,
            "Alice LP value should be preserved"
        );
        console.log("Alice LP protection check passed");

        // === FINAL USER BALANCES ===
        console.log("=== FINAL USER BALANCES ===");
        console.log("Alice shares remaining:", pool.balanceOf(alice));
        console.log("Bob shares remaining:", pool.balanceOf(bob));
        console.log("Carol shares remaining:", pool.balanceOf(carol));
        console.log("Bob final WMNT:", WMNT.balanceOf(bob));
        console.log("Carol final stMNT:", stMNT.balanceOf(carol));

        // === FEE ANALYSIS ===
        console.log("=== FEE ANALYSIS ===");
        uint256 wmntFeeRate = (expectedFee * 10000) / expectedWMNT;
        uint256 stmntFeeRate = (expectedFeeStMNT * 10000) / expectedStMNT;
        console.log("WMNT withdrawal fee rate (bps):", wmntFeeRate);
        console.log("stMNT withdrawal fee rate (bps):", stmntFeeRate);

        // Fees should be reasonable (under 1%)
        assertLt(wmntFeeRate, 100, "WMNT fee should be under 1%");
        assertLt(stmntFeeRate, 100, "stMNT fee should be under 1%");
        console.log("Fee reasonableness check passed");

        console.log(
            "=== SINGLE TOKEN WITHDRAWAL TEST COMPLETED SUCCESSFULLY ==="
        );
    }





    function testStrategyRecallOnWithdrawal2() public {
        setUpPoolAndStrategy();

        console.log("=== SIMPLE STRATEGY RECALL TEST ===");

        // Setup 2 users with limited liquidity
        giveMeWMNT(alice, 9500 ether);
        giveMeStMNT(alice, 300 ether);
        giveMeWMNT(bob, 9300 ether);
        giveMeStMNT(bob, 200 ether);

        // Alice: Main LP
        uint256 aliceShares = depositInPool(alice, 400 ether, 250 ether);
        console.log("Alice shares:", aliceShares);

        // Bob: Small LP
        uint256 bobShares = depositInPool(bob, 200 ether, 150 ether);
        console.log("Bob shares:", bobShares);

        // Pool state after deposits
        uint256 poolWMNTInitial = pool.balances(0);
        uint256 poolStMNTInitial = pool.balances(1);
        console.log("Initial pool WMNT:", poolWMNTInitial);
        console.log("Initial pool stMNT:", poolStMNTInitial);

        // Lend to strategy (70% of WMNT)
        lendtoStrategyAction();

        uint256 totalLentInitial = pool.totalLentToStrategy();
        uint256 poolWMNTAfterLending = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyAssetsInitial = strategy.estimatedTotalAssets();

        console.log("=== AFTER LENDING TO STRATEGY ===");
        console.log("Total lent to strategy:", totalLentInitial);
        console.log("Pool liquid WMNT:", poolWMNTAfterLending);
        console.log("Strategy assets:", strategyAssetsInitial);

        // Generate some yield
        skip(5 days);
        harvestStrategyActionInVault();
        skip(6 hours);
        harvestStrategyAction();

        // Pool state before withdrawal
        uint256 poolWMNTBeforeWithdraw = pool.balances(0);
        uint256 totalLentBefore = pool.totalLentToStrategy();
        uint256 liquidWMNTBefore = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyAssetsBefore = strategy.estimatedTotalAssets();

        console.log("=== BEFORE WITHDRAWAL ===");
        console.log("Pool WMNT balance:", poolWMNTBeforeWithdraw);
        console.log("Total lent to strategy:", totalLentBefore);
        console.log("Liquid WMNT in pool:", liquidWMNTBefore);
        console.log("Strategy assets:", strategyAssetsBefore);

        // === FORCE STRATEGY RECALL ===
        // Bob withdraws ALL his shares as WMNT only
        // This should require more WMNT than available in pool
        console.log("=== BOB LARGE WITHDRAWAL (FORCE RECALL) ===");

        uint256 bobWithdrawShares = bobShares; // ALL shares
        console.log("Bob withdrawing all shares:", bobWithdrawShares);

        // Calculate expected withdrawal
        (uint256 expectedWMNT, uint256 expectedFee) = pool.calcWithdrawOneToken(
            bobWithdrawShares,
            0
        );
        console.log("Expected WMNT out:", expectedWMNT);
        console.log("Expected fee:", expectedFee);

        // Check if recall is needed
        bool recallNeeded = expectedWMNT > liquidWMNTBefore;
        uint256 recallAmount = recallNeeded
            ? expectedWMNT - liquidWMNTBefore
            : 0;

        console.log("=== RECALL ANALYSIS ===");
        console.log("Recall needed:", recallNeeded);
        console.log("Recall amount needed:", recallAmount);
        console.log("Liquid WMNT available:", liquidWMNTBefore);
        console.log("WMNT required:", expectedWMNT);

        // Record Bob's balance before
        uint256 bobWMNTBefore = WMNT.balanceOf(bob);

        // Perform withdrawal (should trigger strategy recall)
        uint256 actualWMNTReceived = withdrawOneToken(
            bob,
            bobWithdrawShares,
            0
        );

        // Pool state after withdrawal
        uint256 poolWMNTAfter = pool.balances(0);
        uint256 totalLentAfter = pool.totalLentToStrategy();
        uint256 liquidWMNTAfter = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyAssetsAfter = strategy.estimatedTotalAssets();
        uint256 bobWMNTAfter = WMNT.balanceOf(bob);

        console.log("=== AFTER WITHDRAWAL ===");
        console.log("Pool WMNT balance:", poolWMNTAfter);
        console.log("Total lent to strategy:", totalLentAfter);
        console.log("Liquid WMNT in pool:", liquidWMNTAfter);
        console.log("Strategy assets:", strategyAssetsAfter);
        console.log("Bob WMNT received:", actualWMNTReceived);
        console.log("Bob WMNT balance change:", bobWMNTAfter - bobWMNTBefore);

        // === STRATEGY RECALL VERIFICATION ===
        console.log("=== STRATEGY RECALL VERIFICATION ===");

        if (recallNeeded) {
            // Verify strategy was called and funds recalled
            uint256 actualRecalled = totalLentBefore - totalLentAfter;
            console.log("Expected recall:", recallAmount);
            console.log("Actual recalled:", actualRecalled);

            // Strategy should have reduced total lent
            assertLt(
                totalLentAfter,
                totalLentBefore,
                "Strategy debt should decrease after recall"
            );

            // Recalled amount should be reasonable
            assertGt(actualRecalled, 0, "Some funds should have been recalled");

            // Strategy assets should decrease
            assertLt(
                strategyAssetsAfter,
                strategyAssetsBefore,
                "Strategy assets should decrease"
            );

            console.log(" Strategy recall verified successfully");
        } else {
            console.log(" No recall was needed for this withdrawal");
        }

        // === BASIC FUNCTIONALITY CHECKS ===

        // 1. Bob should have received WMNT
        assertGt(actualWMNTReceived, 0, "Bob should receive WMNT");
        assertEq(
            bobWMNTAfter - bobWMNTBefore,
            actualWMNTReceived,
            "Balance change should match received amount"
        );

        // 2. Bob's shares should be burned
        assertEq(pool.balanceOf(bob), 0, "Bob should have no shares left");

        // 3. Pool should still function
        assertGt(pool.totalSupply(), 0, "Pool should still have shares");
        assertGt(poolWMNTAfter, 0, "Pool should still have WMNT");

        // 4. Alice (remaining LP) should be unaffected
        assertEq(
            pool.balanceOf(alice),
            aliceShares,
            "Alice shares should be unchanged"
        );

        console.log("=== FINAL STATE ===");
        console.log("Alice remaining shares:", pool.balanceOf(alice));
        console.log("Pool total supply:", pool.totalSupply());
        console.log("Pool WMNT:", poolWMNTAfter);
        console.log("Pool stMNT:", pool.balances(1));
        console.log("Strategy final assets:", strategyAssetsAfter);

        console.log("=== STRATEGY RECALL TEST COMPLETED ===");
    }

    


   
    function testStrategyRecallOnWithdrawal() public {
        setUpPoolAndStrategy();

        console.log("=== SIMPLE STRATEGY RECALL TEST ===");

        // Setup 2 users with limited liquidity
        giveMeWMNT(alice, 9500 ether);
        giveMeStMNT(alice, 300 ether);
        giveMeWMNT(bob, 9300 ether);
        giveMeStMNT(bob, 200 ether);

        // Alice: Main LP
        uint256 aliceShares = depositInPool(alice, 100 ether, 100 ether);
        console.log("Alice shares:", aliceShares);

        // Bob: Small LP
        uint256 bobShares = depositInPool(bob, 100 ether, 100 ether);
        console.log("Bob shares:", bobShares);

        lendtoStrategyAction();

      


        skip(5 days);
        harvestStrategyActionInVault();
        skip(6 hours);
        harvestStrategyAction();
        skip(6 hours);


        uint256 actualWMNTReceived = withdrawOneToken(
            bob,
            bobShares/2,
            0
        );

        console.log("=== AFTER WITHDRAWAL ===");
        console.log("Bob WMNT received:", actualWMNTReceived);

    }
}

