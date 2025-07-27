// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseTest} from "./baseTest.t.sol";

contract IntelliSwapTestUnstake is BaseTest {
    address public liqProvider = address(0x123456);

    function harvestingTime(uint24 _days) internal {
        skip(_days * 1 days);
        harvestStrategyActionInVault();
    }

    function opMultiUserOperations() internal {
        // Give tokens to all users
        giveMeWMNT(alice, 2000 ether);
        giveMeStMNT(alice, 1000 ether);
        giveMeWMNT(bob, 1500 ether);
        giveMeStMNT(bob, 800 ether);
        giveMeWMNT(carol, 1200 ether);
        giveMeStMNT(carol, 600 ether);
        giveMeWMNT(dave, 1000 ether);
        giveMeStMNT(dave, 500 ether);

        depositInPool(alice, 800 ether, 700 ether);
        uint256 bobShares = depositInPool(bob, 400 ether, 350 ether);
        lendtoStrategyAction();

        console.log("After initial deposits:");
        console.log("Pool balance[0]:", pool.balances(0));
        console.log("Pool balance[1]:", pool.balances(1));
        console.log("Total lent to strategy:", pool.totalLentToStrategy());

        harvestingTime(15);
        skip(8 hours);
        harvestStrategyAction();

        buyStMNt(carol, 50 ether);
        sellStMNt(carol, 25 ether);
        sellStMNt(dave, 80 ether);
        buyStMNt(dave, 60 ether);
        depositInPool(carol, 300 ether, 250 ether);

        harvestingTime(20);
        skip(6 hours);
        harvestStrategyAction();

        buyStMNt(bob, 200 ether);
        sellStMNt(alice, 150 ether);
        buyStMNt(dave, 30 ether);
        sellStMNt(dave, 40 ether);

        // Bob withdraws half his liquidity
        uint256 bobWithdrawShares = bobShares / 2;
        withdrawLiquidity(bob, bobWithdrawShares);

        harvestingTime(10);
        skip(8 hours);
        harvestStrategyAction();

        giveMeWMNT(liqProvider, 300_000 ether);
        giveMeStMNT(liqProvider, 100_000 ether);
        depositInPool(liqProvider, 100_00 ether, 100_00 ether);
    }

    // =================================================================
    //  TEST UNSTAKING (stMNT → MNT)
    // =================================================================

    function testIntelliSwapUnstake() public {
        //  Setup una sola volta
        setUpPoolAndStrategy();
        setUpIntelliSwap();

        //  Esegui le operazioni (che NON chiamano più setUpPoolAndStrategy)
        opMultiUserOperations();
        // Verifica che la pool abbia liquidità
        require(
            pool.balances(0) > 0 || pool.balances(1) > 0,
            "Pool has no liquidity"
        );
        require(pool.totalSupply() > 0, "Pool has no shares");

        console.log("=== TESTING INTELLISWAP UNSTAKE PREVIEW ===");
        
        // 🎯 SBILANCIAMENTO: Creiamo scarsità di MNT nella pool per rendere conveniente l'unstaking
        giveMeWMNT(liqProvider, 1_000_000 ether);
        giveMeStMNT(liqProvider, 500_000 ether);


        
        console.log("Pool state after draining MNT:");
        console.log("Pool balance[0] (MNT):", pool.balances(0));
        console.log("Pool balance[1] (stMNT):", pool.balances(1));

        // Dave ora vuole convertire stMNT → MNT
        giveMeWMNT(dave, 100_000 ether);
        giveMeStMNT(dave, 50_000 ether);



        buyStMNt(liqProvider, 10_000 ether);

        
        vm.startPrank(dave);


        try intelliSwap.previewOptimizerSwapOut(8000 ether) returns (
            uint256 swapResult,    // stMNT → MNT via swap
            uint256 unstakeResult, // stMNT → MNT via unstake
            uint256 hybridResult   // stMNT → MNT via hybrid
        ) {
            console.log("Unstake Preview successful!");
            console.log("Pure swap result (stMNT -> MNT):", swapResult);
            console.log("Pure unstake result:", unstakeResult);
            console.log("Hybrid result:", hybridResult);

            // Determina quale strategia è migliore
            uint256 bestSingle = swapResult > unstakeResult ? swapResult : unstakeResult;
            string memory bestStrategy = swapResult > unstakeResult ? "swap" : "unstake";
            
            console.log("Best single strategy:", bestStrategy);
            console.log("Best single output:", bestSingle);
            
            if (hybridResult > bestSingle) {
                uint256 advantage = hybridResult - bestSingle;
                console.log(" HYBRID ADVANTAGE FOUND!");
                console.log("Hybrid advantage:", advantage);
                console.log("Advantage %:", (advantage * 10000) / bestSingle); // basis points
                
                // Test esecuzione hybrid
                testHybridUnstakeExecution(
                    8000 ether,
                    swapResult,
                    unstakeResult,
                    hybridResult
                );
            } else {
                console.log(" No hybrid advantage, best single strategy wins");
                console.log("Hybrid vs Best:", hybridResult, "vs", bestSingle);
                
                // Proviamo con amount più alto
                console.log("Trying with larger amount...");
                
                try intelliSwap.previewOptimizerSwapOut(15000 ether) returns (
                    uint256 swapResult2,
                    uint256 unstakeResult2,
                    uint256 hybridResult2
                ) {
                    uint256 bestSingle2 = swapResult2 > unstakeResult2 ? swapResult2 : unstakeResult2;
                    
                    if (hybridResult2 > bestSingle2) {
                        console.log(" HYBRID WORKS WITH LARGER AMOUNT!");
                        console.log("Hybrid advantage:", hybridResult2 - bestSingle2);
                    }
                } catch {
                    console.log("Large amount failed");
                }
            }

        } catch Error(string memory reason) {
            console.log("Unstake preview failed with reason:", reason);
            revert(reason);
        } catch (bytes memory) {
            console.log("Unstake preview failed with panic");
            debugPoolState();
            revert("Unstake preview failed with panic");
        }

        vm.stopPrank();
        
    }

    // =================================================================
    // 🔍 FUNZIONE DI DEBUG APPROFONDITO
    // =================================================================

    function debugPoolState() internal view {
        console.log("=== DEEP POOL DEBUG FOR UNSTAKE ===");

        // Controlla il virtual price
        try pool.getVirtualPrice() returns (uint256 vPrice) {
            console.log("Virtual price:", vPrice);
        } catch {
            console.log("Virtual price calculation failed");
        }

        // Controlla balance ratio
        uint256 totalMNT = pool.balances(0) + pool.totalLentToStrategy();
        uint256 totalStMNT = pool.balances(1);
        console.log("Total MNT (balance + lent):", totalMNT);
        console.log("Total stMNT in pool:", totalStMNT);
        
        if (totalMNT > 0 && totalStMNT > 0) {
            console.log("MNT/stMNT ratio:", (totalMNT * 1000) / totalStMNT);
        }

        // Test piccolo unstake
        console.log("Testing small unstake...");
        try pool.previewSwap(1, 0, 1 ether) returns (
            uint256 dy,
            uint256 fee,
            uint256 impact
        ) {
            console.log("Small unstake works - output:", dy);
        } catch {
            console.log("Even small unstake fails");
        }
    }

    // =================================================================
    // 🧪 TEST DELL'ESECUZIONE IBRIDA UNSTAKE
    // =================================================================

    function testHybridUnstakeExecution(
        uint256 inputAmount,
        uint256 swapResult,
        uint256 unstakeResult,
        uint256 hybridResult
    ) internal {
        console.log("=== TESTING HYBRID UNSTAKE EXECUTION ===");

        // Calcola i parametri ottimali per unstake
        (
            uint256 swapAmount,
            uint256 unstakeAmount,
            uint256 swapOutput,
            uint256 unstakeOutput,
        ) = intelliSwap._previewHybridOut(inputAmount);

        console.log("Optimal unstake split:");
        console.log("  Swap amount (stMNT -> MNT):", swapAmount);
        console.log("  Unstake amount:", unstakeAmount);
        console.log("  Expected swap output:", swapOutput);
        console.log("  Expected unstake output:", unstakeOutput);

        // Verifica che Dave abbia abbastanza stMNT
        uint256 daveStMNTBalance = stMNT.balanceOf(dave);
        if (daveStMNTBalance < inputAmount) {
            console.log("Dave doesn't have enough stMNT");
            console.log("Needs:", inputAmount);
            console.log("Has:", daveStMNTBalance);
            return;
        }

        // Esegui lo swap ibrido unstake
        uint256 minOut = ((swapOutput + unstakeOutput) * 95) / 100; // 5% slippage tolerance

        uint256 actualOutput = executeHybridSwapOut(
            dave,
            minOut,
            swapAmount,
            unstakeAmount,
            swapOutput,
            unstakeOutput
        );
        
        console.log("Hybrid unstake execution successful!");
        console.log("Expected total MNT:", swapOutput + unstakeOutput);
        console.log("Actual MNT output:", actualOutput);
        console.log("Fee collected (WMNT):", intelliSwap.getBalanceFee());

        // Verifiche di successo
        assertGt(
            actualOutput,
            swapResult,
            "Hybrid output should be greater than pure swap output"
        );
        assertGt(
            actualOutput,
            unstakeResult,
            "Hybrid output should be greater than pure unstake output"
        );
        
        console.log(" All unstake assertions passed!");
    }

    // =================================================================
    // 🎯 TEST ALTERNATIVO: EXTREME UNSTAKE SCENARIO
    // =================================================================
    /*
    function testExtremeUnstakeScenario() public {
        setUpPoolAndStrategy();
        setUpIntelliSwap();
        
        // Setup pool con liquidità
        giveMeWMNT(alice, 50000 ether);
        giveMeStMNT(alice, 50000 ether);
        depositInPool(alice, 25000 ether, 25000 ether);
        
        // Whale per sbilanciamento estremo
        giveMeStMNT(liqProvider, 1000000 ether);
        
        vm.startPrank(liqProvider);
        stMNT.approve(address(pool), type(uint256).max);
        
        // Svuota quasi tutto l'MNT dalla pool
        uint256 initialMNT = pool.balances(0);
        uint256 targetMNTToBuy = (initialMNT * 90) / 100;
        
        // Stima quanto stMNT serve per comprare il 90% dell'MNT
        pool.swap(1, 0, 100000 ether, 0); // Massive stMNT → MNT swap
        
        vm.stopPrank();
        
        console.log("Extreme scenario - Pool state:");
        console.log("MNT balance:", pool.balances(0));
        console.log("stMNT balance:", pool.balances(1));
        
        // Test con Dave
        giveMeStMNT(dave, 20000 ether);
        
        vm.startPrank(dave);
        
        (uint256 swap, uint256 unstake, uint256 hybrid) = intelliSwap.previewOptimizerSwapOut(10000 ether);
        
        console.log("EXTREME UNSTAKE TEST:");
        console.log("Swap:", swap);
        console.log("Unstake:", unstake);
        console.log("Hybrid:", hybrid);
        
        uint256 best = swap > unstake ? swap : unstake;
        if (hybrid > best) {
            console.log(" EXTREME HYBRID UNSTAKE SUCCESS!");
            console.log("Advantage:", hybrid - best);
        }
        
        vm.stopPrank();
    }*/
}