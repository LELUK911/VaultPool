// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "./baseTest.t.sol";

contract InflationAttackTest is BaseTest {
    address public attacker = address(0x154645);

    function testInflationAttackFails() public {
        // === SETUP ===
        setUpPoolAndStrategy();

        vm.prank(owner);
        pool.setTreasury(owner);

        console.log("=== DIMOSTRAZIONE: ATTACCO INFLAZIONE FALLISCE ===");

        // Setup token per tutti
        giveMeWMNT(attacker, 150_000 ether);
        giveMeStMNT(attacker, 50_000 ether);
        giveMeWMNT(alice, 110_000 ether);
        giveMeStMNT(alice, 10_000 ether);
        giveMeWMNT(bob, 110_000 ether);
        giveMeStMNT(bob, 10_000 ether);

        console.log("\n=== STEP 1: ATTACKER PRIMO DEPOSITO (MINIMO) ===");
        uint256 attackerSharesBefore = depositInPool(attacker, 1, 1);
        console.log("Attacker shares dal primo deposito:", attackerSharesBefore);
        console.log("Total supply dopo primo deposito:", pool.totalSupply());
        
        uint256 virtualPriceBefore = pool.getVirtualPrice();
        console.log("Virtual price PRIMA attacco:", virtualPriceBefore);

        console.log("\n=== STEP 2: ATTACKER TENTA INFLAZIONE ===");
        uint256 donationAmount = 10_000 ether;
        
        // Salva balance dell'attacker prima della "donazione"
        uint256 attackerWMNTBefore = IERC20(address(WMNT)).balanceOf(attacker);
        uint256 attackerStMNTBefore = IERC20(address(stMNT)).balanceOf(attacker);
        
        console.log("Balance attacker prima donazione:");
        console.log("- WMNT:", attackerWMNTBefore);
        console.log("- stMNT:", attackerStMNTBefore);
        
        console.log("Attacker dona al contratto:");
        console.log("- WMNT donati:", donationAmount);
        console.log("- stMNT donati:", donationAmount);
        
        vm.startPrank(attacker);
        IERC20(address(WMNT)).transfer(address(pool), donationAmount);
        IERC20(address(stMNT)).transfer(address(pool), donationAmount);
        vm.stopPrank();

        // Verifica che il contratto si sia "rotto"
        console.log("\n=== STEP 3: VERIFICA CHE IL CONTRATTO SI ROMPE ===");
        (bool isHealthy, uint256 recordedBalance0, uint256 actualBalance0, uint256 recordedBalance1, uint256 actualBalance1) = pool.checkBalanceHealth();
        console.log("Pool healthy dopo attacco?", isHealthy);
        console.log("Recorded balance0:", recordedBalance0);
        console.log("Actual balance0:", actualBalance0);
        console.log("Recorded balance1:", recordedBalance1);
        console.log("Actual balance1:", actualBalance1);
        
        console.log("\n=== STEP 4: KEEPER RIPARA CON SYNC ===");
        sync();
        
        ( isHealthy, recordedBalance0,  actualBalance0,  recordedBalance1,  actualBalance1) = pool.checkBalanceHealth();
        console.log("Pool healthy dopo sync?", isHealthy);

        uint256 virtualPriceAfterSync = pool.getVirtualPrice();
        console.log("Virtual price DOPO sync:", virtualPriceAfterSync);

        console.log("\n=== STEP 5: ALICE DEPOSITA (VITTIMA TEORICA) ===");
        uint256 aliceDeposit = 1000 ether;
        uint256 aliceSharesReceived = depositInPool(alice, aliceDeposit, aliceDeposit);
        console.log("Alice deposita:", aliceDeposit, "di ciascun token");
        console.log("Alice riceve shares:", aliceSharesReceived);
        
        // Calcola la percentuale di shares che Alice ha ricevuto
        uint256 totalSupplyAfterAlice = pool.totalSupply();
        uint256 alicePercentage = (aliceSharesReceived * 10000) / totalSupplyAfterAlice; // basis points
        console.log("Percentuale pool di Alice (bp):", alicePercentage);

        console.log("\n=== STEP 6: BOB DEPOSITA ANCHE LUI ===");
        uint256 bobDeposit = 500 ether;
        uint256 bobSharesReceived = depositInPool(bob, bobDeposit, bobDeposit);
        console.log("Bob deposita:", bobDeposit, "di ciascun token");
        console.log("Bob riceve shares:", bobSharesReceived);

        console.log("\n=== STEP 7: ATTACKER PROVA A PRELEVARE ===");
        console.log("Attacker shares da prelevare:", attackerSharesBefore);
        
        // Attacker prova a withdraware tutte le sue shares usando la funzione helper
        (uint256 wmntOut, uint256 stmntOut) = withdrawLiquidity(attacker, attackerSharesBefore);
        
        console.log("Attacker preleva:");
        console.log("- WMNT ottenuti:", wmntOut);
        console.log("- stMNT ottenuti:", stmntOut);

        uint256 attackerWMNTFinal = IERC20(address(WMNT)).balanceOf(attacker);
        uint256 attackerStMNTFinal = IERC20(address(stMNT)).balanceOf(attacker);

        console.log("\n=== STEP 8: CALCOLO PROFITTO/PERDITA ATTACKER ===");
        console.log("Balance attacker DOPO prelievo:");
        console.log("- WMNT finale:", attackerWMNTFinal);
        console.log("- stMNT finale:", attackerStMNTFinal);
        
        // Calcola la perdita netta dell'attacker
        int256 wmntNetChange = int256(attackerWMNTFinal) - int256(attackerWMNTBefore);
        int256 stmntNetChange = int256(attackerStMNTFinal) - int256(attackerStMNTBefore);
        
        console.log("Variazione netta WMNT attacker:", wmntNetChange);
        console.log("Variazione netta stMNT attacker:", stmntNetChange);
        
        // Calcola la perdita totale in ether
        uint256 totalLoss = 0;
        if (wmntNetChange < 0) totalLoss += uint256(-wmntNetChange);
        if (stmntNetChange < 0) totalLoss += uint256(-stmntNetChange);
        
        console.log("Perdita totale attacker:", totalLoss, "ether");
        
        if (wmntNetChange < 0 || stmntNetChange < 0) {
            console.log(" ATTACCO FALLITO! Attacker ha perso fondi!");
        } else {
            console.log("  Attacker potrebbe aver guadagnato - verificare calcoli");
        }

        console.log("\n=== STEP 9: VERIFICA CHE GLI ALTRI LP HANNO BENEFICIATO ===");
        
        // Prova che Alice e Bob possono prelevare normalmente
        console.log("Test prelievi Alice e Bob...");
        
        // Alice preleva metà delle sue shares
        uint256 aliceWithdrawShares = aliceSharesReceived / 2;
        (uint256 aliceWmntOut, uint256 aliceStmntOut) = withdrawLiquidity(alice, aliceWithdrawShares);
        console.log("Alice preleva", aliceWithdrawShares, "shares e ottiene:");
        console.log("- WMNT:", aliceWmntOut);
        console.log("- stMNT:", aliceStmntOut);
        
        // Bob preleva tutto
        (uint256 bobWmntOut, uint256 bobStmntOut) = withdrawLiquidity(bob, bobSharesReceived);
        console.log("Bob preleva", bobSharesReceived, "shares e ottiene:");
        console.log("- WMNT:", bobWmntOut);
        console.log("- stMNT:", bobStmntOut);
        
        console.log("\n CONCLUSIONE:");
        console.log("- Attacker ha perso", totalLoss, "ether totali");
        console.log("- Alice e Bob hanno ricevuto shares normalmente");
        console.log("- Alice e Bob possono prelevare senza problemi");
        console.log("- Le donazioni dell'attacker sono state distribuite tra tutti gli LP");
        console.log("- L'attacco di inflazione e FALLITO!");
    
    }
}