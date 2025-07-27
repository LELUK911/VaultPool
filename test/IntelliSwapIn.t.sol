// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseTest} from "./baseTest.t.sol";

contract IntelliSwapTestIn is BaseTest {
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
    // ✅ TEST CORRETTO - NON CHIAMARE setUpPoolAndStrategy DUE VOLTE!
    // =================================================================

    function testIntelliSwap() public {
        // ✅ Setup una sola volta
        setUpPoolAndStrategy();
        setUpIntelliSwap();

        // ✅ Esegui le operazioni (che NON chiamano più setUpPoolAndStrategy)
        opMultiUserOperations();

        // ✅ Debug lo stato finale prima del test

        address(pool.strategy());
        pool.balances(0);
        pool.balances(1);
        pool.totalLentToStrategy();
        pool.totalSupply();

        // Verifica che la pool abbia liquidità
        require(
            pool.balances(0) > 0 || pool.balances(1) > 0,
            "Pool has no liquidity"
        );
        require(pool.totalSupply() > 0, "Pool has no shares");

        // ✅ Test del preview con debug
        console.log("=== TESTING INTELLISWAP PREVIEW ===");
        giveMeWMNT(dave, 1_000_000 ether);
        giveMeStMNT(dave, 200_000 ether);

        vm.startPrank(dave);

        try intelliSwap.previewOptimizerSwapIn(6000 ether) returns (
            uint256 swapResult,
            uint256 stakeResult,
            uint256 hybridResult
        ) {
            console.log("Preview successful!");
            console.log("Pure swap result:", swapResult);
            console.log("Pure stake result:", stakeResult);
            console.log("Hybrid result:", hybridResult);

            testHybridExecution(
                6000 ether,
                swapResult,
                stakeResult,
                hybridResult
            );
        } catch Error(string memory reason) {
            console.log("Preview failed with reason:", reason);
            revert(reason);
        } catch (bytes memory) {
            console.log("Preview failed with panic");
            // Debug più approfondito
            debugPoolState();
            revert("Preview failed with panic");
        }

        vm.stopPrank();
    }

    // =================================================================
    // 🔍 FUNZIONE DI DEBUG APPROFONDITO
    // =================================================================

    function debugPoolState() internal view {
        console.log("=== DEEP POOL DEBUG ===");

        // Controlla il virtual price
        try pool.getVirtualPrice() returns (uint256 vPrice) {
            console.log("Virtual price:", vPrice);
        } catch {
            console.log(" Virtual price calculation failed");
        }

        // Controlla se _xpWithFreeFunds funziona
        console.log("Trying to debug _xpWithFreeFunds calculation...");
        uint256 totalMNT = pool.balances(0) + pool.totalLentToStrategy();
        console.log("Total MNT (balance + lent):", totalMNT);

        if (totalMNT == 0) {
            console.log(" CRITICAL: Total MNT is zero!");
        }

        // Prova un amount più piccolo
        console.log("Testing with smaller amount...");
        try pool.previewSwap(0, 1, 1 ether) returns (
            uint256 dy,
            uint256 fee,
            uint256 impact
        ) {
            console.log(" Small amount works - output:", dy);
        } catch {
            console.log(" Even small amount fails");
        }
    }

    // =================================================================
    // 🧪 TEST DELL'ESECUZIONE IBRIDA
    // =================================================================

    function testHybridExecution(
        uint256 inputAmount,
        uint256 swapResult,
        uint256 stakeResult,
        uint256 hybridResult
    ) internal {
        console.log("=== TESTING HYBRID EXECUTION ===");

        // Calcola i parametri ottimali
        (
            uint256 swapAmount,
            uint256 stakeAmount,
            uint256 swapOutput,
            uint256 stakeOutput,

        ) = intelliSwap._previewHybridIn(inputAmount);

        console.log("Optimal split:");
        console.log("  Swap amount:", swapAmount);
        console.log("  Stake amount:", stakeAmount);
        console.log("  Expected swap output:", swapOutput);
        console.log("  Expected stake output:", stakeOutput);

        // Verifica che Dave abbia abbastanza token
        uint256 daveBalance = WMNT.balanceOf(dave);
        if (daveBalance < inputAmount) {
            console.log("Dave doesn't have enough WMNT");
            console.log("Needs:", inputAmount);
            console.log("Has:", daveBalance);
            return;
        }

        // Esegui lo swap ibrido
        uint256 minOut = ((swapOutput + stakeOutput) * 95) / 100; // 5% slippage tolerance

        // Direct call since executeHybridSwapIn is internal and cannot use try/catch
        uint256 actualOutput = executeHybridSwapIn(
            dave,
            minOut,
            swapAmount,
            stakeAmount,
            swapOutput,
            stakeOutput
        );
        console.log("Hybrid execution successful!");
        console.log("Expected total:", swapOutput + stakeOutput);
        console.log("Actual output:", actualOutput);
        console.log("Fee collected:", intelliSwap.getBalanceFeeStMNT());

        assertGt(
            actualOutput,
            swapResult,
            "Hybrid output should be greater than pure swap output"
        );
        assertGt(
            actualOutput,
            stakeResult,
            "Hybrid output should be greater than pure stake output"
        );
    }
}
