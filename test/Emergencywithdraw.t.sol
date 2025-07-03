// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseTest} from "./baseTest.t.sol";

contract SecurityTest is BaseTest {
    function harvestingTime(uint24 _days) internal {
        skip(_days * 1 days);
        harvestStrategyActionInVault();
    }

    function testEmergencyWithdrawAll() public {
        setUpPoolAndStrategy();
        giveMeWMNT(alice, 1000 ether);
        giveMeStMNT(alice, 300 ether);
        uint256 shares = depositInPool(alice, 250 ether, 249 ether);
        lendtoStrategyAction();

        // === STATO PRIMA DELL'EMERGENCY ===
        uint256 poolBalance0Before = pool.balances(0);
        uint256 poolBalance1Before = pool.balances(1);
        uint256 totalLentBefore = pool.totalLentToStrategy();
        uint256 strategyAssetsBefore = strategy.estimatedTotalAssets();
        uint256 aliceSharesBefore = pool.balanceOf(alice);
        uint256 poolContractBalanceBefore = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyContractBalanceBefore = IERC20(address(WMNT)).balanceOf(
            address(strategy)
        );
        bool poolPausedBefore = pool.paused();
        bool strategyPausedBefore = strategy.paused();

        console.log("=== BEFORE EMERGENCY ===");
        console.log("Pool WMNT balance:", poolBalance0Before);
        console.log("Pool stMNT balance:", poolBalance1Before);
        console.log("Total lent to strategy:", totalLentBefore);
        console.log("Strategy total assets:", strategyAssetsBefore);
        console.log("Alice shares:", aliceSharesBefore);
        console.log("Pool contract WMNT:", poolContractBalanceBefore);
        console.log("Strategy contract WMNT:", strategyContractBalanceBefore);
        console.log("Pool paused:", poolPausedBefore);
        console.log("Strategy paused:", strategyPausedBefore);

        skip(6 hours);

        // === EXECUTE EMERGENCY ===
        emergencyCallStrAndPool(owner);

        // === STATO DOPO L'EMERGENCY ===
        uint256 poolBalance0After = pool.balances(0);
        uint256 poolBalance1After = pool.balances(1);
        uint256 totalLentAfter = pool.totalLentToStrategy();
        uint256 strategyAssetsAfter = strategy.estimatedTotalAssets();
        uint256 aliceSharesAfter = pool.balanceOf(alice);
        uint256 poolContractBalanceAfter = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyContractBalanceAfter = IERC20(address(WMNT)).balanceOf(
            address(strategy)
        );
        bool poolPausedAfter = pool.paused();
        bool strategyPausedAfter = strategy.paused();

        console.log("=== AFTER EMERGENCY ===");
        console.log("Pool WMNT balance:", poolBalance0After);
        console.log("Pool stMNT balance:", poolBalance1After);
        console.log("Total lent to strategy:", totalLentAfter);
        console.log("Strategy total assets:", strategyAssetsAfter);
        console.log("Alice shares:", aliceSharesAfter);
        console.log("Pool contract WMNT:", poolContractBalanceAfter);
        console.log("Strategy contract WMNT:", strategyContractBalanceAfter);
        console.log("Pool paused:", poolPausedAfter);
        console.log("Strategy paused:", strategyPausedAfter);

        // === VERIFICHE CRITICHE ===
        console.log("=== CRITICAL VERIFICATIONS ===");

        // 1. Entrambi i contratti devono essere in pausa
        assertTrue(poolPausedAfter, "Pool should be paused after emergency");
        assertTrue(
            strategyPausedAfter,
            "Strategy should be paused after emergency"
        );
        console.log("   Pause status verified");

        // 2. Debito strategy deve essere azzerato
        assertEq(totalLentAfter, 0, "Total lent to strategy should be zero");
        console.log("   Strategy debt reset verified");

        // 3. Strategy non deve avere fondi significativi
        assertLt(
            strategyContractBalanceAfter,
            1 ether,
            "Strategy should have minimal WMNT left"
        );
        assertLt(
            strategyAssetsAfter,
            1 ether,
            "Strategy should have minimal assets left"
        );
        console.log("   Strategy fund evacuation verified");

        // 4. Pool deve aver ricevuto i fondi
        assertGt(
            poolContractBalanceAfter,
            poolContractBalanceBefore,
            "Pool should have more WMNT after emergency"
        );
        console.log(
            "Pool WMNT increase:",
            poolContractBalanceAfter - poolContractBalanceBefore
        );

        // 5. Alice's shares devono essere intatte
        assertEq(
            aliceSharesAfter,
            aliceSharesBefore,
            "Alice shares should be unchanged"
        );
        console.log("   User shares preserved");

        // 6. Pool balance contabile dovrebbe riflettere la realtà
        uint256 expectedPoolBalance = poolContractBalanceAfter;
        uint256 tolerance = expectedPoolBalance / 1000; // 0.1% tolerance
        uint256 balanceDiff = poolBalance0After > expectedPoolBalance
            ? poolBalance0After - expectedPoolBalance
            : expectedPoolBalance - poolBalance0After;

        assertLt(
            balanceDiff,
            tolerance,
            "Pool accounting should match reality"
        );
        console.log("Pool balance0 (accounting):", poolBalance0After);
        console.log("Pool balance (actual):", poolContractBalanceAfter);
        console.log("Difference:", balanceDiff);
        console.log("   Pool accounting accuracy verified");

        // 7. stMNT balance dovrebbe essere invariato
        assertEq(
            poolBalance1After,
            poolBalance1Before,
            "stMNT balance should be unchanged"
        );
        console.log("   stMNT balance preserved");

        // === TEST OPERAZIONI BLOCCATE ===
        console.log("=== TESTING BLOCKED OPERATIONS ===");

        // 8. Tutte le operazioni principali devono fallire
        vm.startPrank(alice);

        // Test add liquidity - should fail
        vm.expectRevert(); // Accept any revert (paused)
        pool.addLiquidity([uint256(100 ether), uint256(100 ether)], 0);
        console.log("   Add liquidity correctly blocked");

        // Test remove liquidity - should fail
        vm.expectRevert(); // Accept any revert (paused)
        pool.removeLiquidity(shares / 2, [uint256(0), uint256(0)]);
        console.log("   Remove liquidity correctly blocked");

        // Test swap - should fail
        vm.expectRevert(); // Accept any revert (paused)
        pool.swap(0, 1, 10 ether, 0);
        console.log("   Swap correctly blocked");

        // Test remove one token - should fail
        vm.expectRevert(); // Accept any revert (paused)
        pool.removeLiquidityOneToken(shares / 4, 0, 0);
        console.log("   Remove one token correctly blocked");

        vm.stopPrank();

        // 9. Strategy operations should be handled differently
        // invest() returns silently when paused (by design)
        vm.prank(address(pool));
        strategy.invest(100 ether); // Should return silently, not revert
        console.log("   Strategy invest correctly handled (silent return)");

        // poolCallWithdraw returns 0 when paused (by design)
        vm.prank(address(pool));
        uint256 withdrawn = strategy.poolCallWithdraw(100 ether);
        assertEq(withdrawn, 0, "Should withdraw 0 when paused");
        console.log("   Strategy withdraw correctly handled (returns 0)");

        // === FUND CONSERVATION CHECK ===
        console.log("=== FUND CONSERVATION CHECK ===");

        //    CONFRONTA POOL BALANCE (CONTABILE) NON CONTRACT BALANCE
        uint256 poolAssetsBefore = poolBalance0Before; // 250 WMNT
        uint256 poolAssetsAfter = poolBalance0After; // 250 WMNT

        console.log("Pool assets (accounting) before:", poolAssetsBefore);
        console.log("Pool assets (accounting) after:", poolAssetsAfter);

        // In emergency senza perdite reali, pool balance dovrebbe essere conservato
        uint256 emergencyTolerance = poolAssetsBefore / 10000; // 0.01% tolerance for rounding
        balanceDiff = poolAssetsBefore > poolAssetsAfter
            ? poolAssetsBefore - poolAssetsAfter
            : poolAssetsAfter - poolAssetsBefore;

        console.log("Pool balance difference:", balanceDiff);
        console.log("Emergency tolerance:", emergencyTolerance);

        assertLt(
            balanceDiff,
            emergencyTolerance,
            "Pool balance should be nearly identical after emergency"
        );

        // Verifica che abbiamo recuperato quasi tutto (99.99%+)
        uint256 recoveredPercentage = (poolAssetsAfter * 10000) /
            poolAssetsBefore;
        console.log("Recovery percentage (bps):", recoveredPercentage);
        assertGt(recoveredPercentage, 9998, "Should recover 99.99%+ of funds");

        console.log(
            "   Emergency fund recovery verified - Perfect conservation!"
        );

        // === FINAL STATUS ===
        console.log("=== EMERGENCY PROCEDURE SUMMARY ===");
        console.log(" Both contracts successfully paused");
        console.log(" Strategy debt completely reset");
        console.log(" Funds evacuated from strategy to pool");
        console.log(" User shares preserved and protected");
        console.log(" All operations correctly blocked");
        console.log(" Fund conservation maintained");
        console.log(" Pool accounting updated to reality");

        console.log(" EMERGENCY PROCEDURE COMPLETED SUCCESSFULLY ");
    }
}
