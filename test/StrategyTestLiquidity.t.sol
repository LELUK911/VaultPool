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

contract StrategyTest is Test {
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

        assertEq(
            amountReceived,
            actualReceived,
            "Returned amount should match balance change"
        );

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

    function testDepositToStrategy() public {
        setUpPoolAndStrategy();
        giveMeWMNT(alice, 1000 ether);
        giveMeStMNT(alice, 300 ether);
        uint256 shares = depositInPool(alice, 250 ether, 249 ether);

        // Verifica stato PRIMA del lending
        uint256 poolMntBalanceBefore = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyMntBalanceBefore = IERC20(address(WMNT)).balanceOf(
            address(strategy)
        );
        uint256 strategyStMntBalanceBefore = strategy.balanceStMnt();
        uint256 totalLentBefore = pool.totalLentToStrategy();

        console.log("=== BEFORE LENDING ===");
        console.log("Pool MNT balance:", poolMntBalanceBefore);
        console.log("Strategy MNT balance:", strategyMntBalanceBefore);
        console.log("Strategy stMNT balance:", strategyStMntBalanceBefore);
        console.log("Total lent to strategy:", totalLentBefore);

        lendtoStrategyAction();

        // Verifica stato DOPO il lending
        uint256 poolMntBalanceAfter = IERC20(address(WMNT)).balanceOf(
            address(pool)
        );
        uint256 strategyMntBalanceAfter = IERC20(address(WMNT)).balanceOf(
            address(strategy)
        );
        uint256 strategyStMntBalanceAfter = strategy.balanceStMnt();
        uint256 totalLentAfter = pool.totalLentToStrategy();

        console.log("=== AFTER LENDING ===");
        console.log("Pool MNT balance:", poolMntBalanceAfter);
        console.log("Strategy MNT balance:", strategyMntBalanceAfter);
        console.log("Strategy stMNT balance:", strategyStMntBalanceAfter);
        console.log("Total lent to strategy:", totalLentAfter);

        // Calcola quanto dovrebbe essere stato prestato (70% del saldo MNT della pool)
        uint256 bufferAmount = (poolMntBalanceBefore * 30) / 100;
        uint256 expectedLentAmount = poolMntBalanceBefore - bufferAmount;

        console.log("Expected lent amount:", expectedLentAmount);
        console.log("Buffer amount (30%):", bufferAmount);

        // VERIFICHE PRINCIPALI

        // 1. La pool deve aver mantenuto il 30% come buffer
        assertEq(
            poolMntBalanceAfter,
            bufferAmount,
            "Pool should keep 30% as buffer"
        );

        // 2. Il totalLentToStrategy deve essere aggiornato correttamente
        assertEq(
            totalLentAfter,
            expectedLentAmount,
            "totalLentToStrategy should match expected amount"
        );

        // 3. La strategy NON deve avere MNT liquidi (dovrebbero essere tutti investiti)
        assertEq(
            strategyMntBalanceAfter,
            0,
            "Strategy should have no liquid MNT after investment"
        );

        // 4. La strategy deve aver ricevuto shares stMNT dal vault
        assertGt(
            strategyStMntBalanceAfter,
            0,
            "Strategy should have stMNT shares from vault"
        );

        // 5. Verifica che il totale sia conservato (pool buffer + strategy assets)
        uint256 strategyTotalAssets = strategy.estimatedTotalAssets();
        uint256 totalSystemAssets = poolMntBalanceAfter + strategyTotalAssets;

        console.log("Strategy total assets:", strategyTotalAssets);
        console.log("Total system assets:", totalSystemAssets);
        console.log("Initial pool balance was:", poolMntBalanceBefore);

        // Il totale del sistema dovrebbe essere almeno uguale al saldo iniziale
        assertGe(
            totalSystemAssets,
            (poolMntBalanceBefore * 9999) / 10000, // Allowing for minor rounding errors
            "Total system assets should be preserved"
        );
    }

    function testHarvestInStrategy() public {
        setUpPoolAndStrategy();
        giveMeWMNT(alice, 1000 ether);
        giveMeStMNT(alice, 300 ether);
        uint256 shares = depositInPool(alice, 250 ether, 249 ether);
        lendtoStrategyAction();

        // ===== STATO INIZIALE =====
        uint256 initialPoolBalance0 = pool.balances(0);
        uint256 initialStrategyAssets = strategy.estimatedTotalAssets();
        uint256 initialLockedProfit = pool.getCurrentLockedProfit();

        console.log("=== INITIAL STATE ===");
        console.log("Pool MNT balance:", initialPoolBalance0);
        console.log("Strategy total assets:", initialStrategyAssets);
        console.log("Initial locked profit:", initialLockedProfit);
        console.log("Initial virtual price:", pool.getVirtualPrice());

        // ===== PRIMO CICLO: HARVEST + DEGRADAZIONE =====
        skip(10 days);

        uint256 priceBeforeHarvest = stVault.pricePerShare();
        console.log("\n=== BEFORE FIRST HARVEST ===");
        console.log("Vault price per share:", priceBeforeHarvest);

        harvestStrategyActionInVault(); // Genera profitti in stMNT

        uint256 priceAfterHarvest = stVault.pricePerShare();
        console.log("\n=== AFTER VAULT HARVEST ===");
        console.log("Vault price per share:", priceAfterHarvest);
        console.log("Price increase:", priceAfterHarvest - priceBeforeHarvest);

        // Verifica che il prezzo sia aumentato
        assertGt(
            priceAfterHarvest,
            priceBeforeHarvest,
            "Vault price should increase after harvest"
        );

        skip(8 hours);

        uint256 strategyAssetsBeforeReport = strategy.estimatedTotalAssets();
        uint256 poolBalanceBeforeReport = pool.balances(0);

        console.log("\n=== BEFORE STRATEGY HARVEST ===");
        console.log(
            "Strategy assets before report:",
            strategyAssetsBeforeReport
        );
        console.log("Pool balance before report:", poolBalanceBeforeReport);

        harvestStrategyAction(); // Fa il report del profit alla pool

        uint256 strategyAssetsAfterReport = strategy.estimatedTotalAssets();
        uint256 poolBalanceAfterReport = pool.balances(0);
        uint256 lockedProfitAfterReport = pool.getCurrentLockedProfit();
        uint256 virtualPriceAfterReport = pool.getVirtualPrice();

        console.log("\n=== AFTER STRATEGY HARVEST ===");
        console.log("Strategy assets after report:", strategyAssetsAfterReport);
        console.log("Pool balance after report:", poolBalanceAfterReport);
        console.log("Locked profit after report:", lockedProfitAfterReport);
        console.log("Virtual price after report:", virtualPriceAfterReport);

        // Verifiche primo harvest
        uint256 firstProfit = poolBalanceAfterReport - poolBalanceBeforeReport;
        console.log("First harvest profit:", firstProfit);

        assertGt(
            poolBalanceAfterReport,
            poolBalanceBeforeReport,
            "Pool balance should increase after harvest"
        );
        assertGt(
            lockedProfitAfterReport,
            0,
            "Should have locked profit after harvest"
        );
        //!assertGt(
        //!    virtualPriceAfterReport,
        //!    pool.getVirtualPrice(),
        //!    "Virtual price should increase"
        //!);

        // ===== SECONDO CICLO: PIÙ HARVEST =====
        skip(10 days);

        harvestStrategyActionInVault(); // Secondo harvest del stVault

        uint256 priceAfterSecondHarvest = stVault.pricePerShare();
        console.log("\n=== AFTER SECOND VAULT HARVEST ===");
        console.log("Vault price per share:", priceAfterSecondHarvest);

        skip(8 hours);

        uint256 lockedProfitBeforeSecondReport = pool.getCurrentLockedProfit();
        console.log("\n=== BEFORE SECOND STRATEGY HARVEST ===");
        console.log(
            "Locked profit before second harvest:",
            lockedProfitBeforeSecondReport
        );
        console.log("Time since last report:", uint256(8 hours));

        harvestStrategyAction(); // Secondo report

        uint256 lockedProfitAfterSecondReport = pool.getCurrentLockedProfit();
        uint256 poolBalanceAfterSecondReport = pool.balances(0);

        console.log("\n=== AFTER SECOND STRATEGY HARVEST ===");
        console.log(
            "Locked profit after second harvest:",
            lockedProfitAfterSecondReport
        );
        console.log(
            "Pool balance after second harvest:",
            poolBalanceAfterSecondReport
        );

        // Verifiche secondo harvest
        uint256 secondProfit = poolBalanceAfterSecondReport -
            poolBalanceAfterReport;
        console.log("Second harvest profit:", secondProfit);

        assertGt(
            poolBalanceAfterSecondReport,
            poolBalanceAfterReport,
            "Pool should have more profit after second harvest"
        );

        // ===== TEST DEGRADAZIONE COMPLETA =====
        skip(8 hours); // Totale 6+ ore dalla seconda harvest, dovrebbe degradare completamente

        uint256 lockedProfitAfterDegradation = pool.getCurrentLockedProfit();
        uint256 freeFundsAfterDegradation = pool.getFreeFunds();

        console.log("\n=== AFTER DEGRADATION PERIOD ===");
        console.log(
            "Locked profit after degradation:",
            lockedProfitAfterDegradation
        );
        console.log("Free funds after degradation:", freeFundsAfterDegradation);

        // Verifica degradazione (dovrebbe essere molto bassa o zero dopo 6+ ore)
        assertLt(
            lockedProfitAfterDegradation,
            lockedProfitAfterSecondReport / 2,
            "Locked profit should degrade significantly"
        );

        // ===== VERIFICHE FINALI =====
        uint256 finalTotalAssets = strategy.estimatedTotalAssets() +
            pool.balances(0);
        uint256 totalProfitGenerated = poolBalanceAfterSecondReport -
            initialPoolBalance0;

        console.log("\n=== FINAL SUMMARY ===");
        console.log(
            "Initial system assets:",
            initialPoolBalance0 + initialStrategyAssets
        );
        console.log("Final system assets:", finalTotalAssets);
        console.log("Total profit generated:", totalProfitGenerated);
        console.log("Final virtual price:", pool.getVirtualPrice());

        // Verifiche finali
        assertGt(
            finalTotalAssets,
            initialPoolBalance0 + initialStrategyAssets,
            "Total system assets should increase"
        );
        assertGt(totalProfitGenerated, 0, "Should have generated profit");
        assertGt(
            pool.getVirtualPrice(),
            virtualPriceAfterReport,
            "Virtual price should continue to increase"
        );
    }

    function testRemoveLiquidity() public {
        setUpPoolAndStrategy();
        giveMeWMNT(alice, 1000 ether);
        giveMeStMNT(alice, 300 ether);

        uint256 wmntDeposit = 250 ether;
        uint256 stMntDeposit = 249 ether;

        console.log("=== INITIAL DEPOSIT ===");
        console.log("Initial WMNT deposit:", wmntDeposit);
        console.log("Initial stMNT deposit:", stMntDeposit);

        // Saldi iniziali di Alice
        uint256 aliceWmntBefore = IERC20(address(WMNT)).balanceOf(alice);
        uint256 aliceStMntBefore = IERC20(stMNT).balanceOf(alice);

        console.log("Alice WMNT balance before:", aliceWmntBefore);
        console.log("Alice stMNT balance before:", aliceStMntBefore);

        uint256 shares = depositInPool(alice, wmntDeposit, stMntDeposit);
        console.log("Shares received:", shares);

        lendtoStrategyAction();

        // Stato dopo lending
        uint256 poolBalance0AfterLending = pool.balances(0);
        uint256 poolBalance1AfterLending = pool.balances(1);
        uint256 totalLentAfterLending = pool.totalLentToStrategy();

        console.log("\n=== AFTER LENDING ===");
        console.log("Pool WMNT balance:", poolBalance0AfterLending);
        console.log("Pool stMNT balance:", poolBalance1AfterLending);
        console.log("Total lent to strategy:", totalLentAfterLending);

        // Genera profitti
        skip(10 days);
        harvestStrategyActionInVault();
        skip(8 hours);
        harvestStrategyAction();
        skip(10 days);
        harvestStrategyActionInVault();
        skip(8 hours);
        harvestStrategyAction();
        skip(8 hours); // Degradazione completa

        // Stato prima del withdrawal
        uint256 poolBalance0BeforeWithdraw = pool.balances(0);
        uint256 poolBalance1BeforeWithdraw = pool.balances(1);
        uint256 totalLentBeforeWithdraw = pool.totalLentToStrategy();
        uint256 totalSupplyBeforeWithdraw = pool.totalSupply();
        uint256 strategyAssetsBeforeWithdraw = strategy.estimatedTotalAssets();

        console.log("\n=== BEFORE WITHDRAWAL ===");
        console.log("Pool WMNT balance:", poolBalance0BeforeWithdraw);
        console.log("Pool stMNT balance:", poolBalance1BeforeWithdraw);
        console.log("Total lent to strategy:", totalLentBeforeWithdraw);
        console.log("Total supply:", totalSupplyBeforeWithdraw);
        console.log("Strategy total assets:", strategyAssetsBeforeWithdraw);
        console.log("Virtual price:", pool.getVirtualPrice());

        // Calcola quanto Alice dovrebbe ricevere teoricamente
        uint256 expectedWmnt = (poolBalance0BeforeWithdraw * shares) /
            totalSupplyBeforeWithdraw;
        uint256 expectedStMnt = (poolBalance1BeforeWithdraw * shares) /
            totalSupplyBeforeWithdraw;

        console.log("\n=== EXPECTED AMOUNTS ===");
        console.log("Expected WMNT:", expectedWmnt);
        console.log("Expected stMNT:", expectedStMnt);

        // Esegui withdrawal
        (uint256 wmntReceived, uint256 stMntReceived) = withdrawLiquidity(
            alice,
            shares
        );

        console.log("\n=== ACTUAL AMOUNTS RECEIVED ===");
        console.log("WMNT received:", wmntReceived);
        console.log("stMNT received:", stMntReceived);

        // Saldi finali di Alice
        uint256 aliceWmntAfter = IERC20(address(WMNT)).balanceOf(alice);
        uint256 aliceStMntAfter = IERC20(stMNT).balanceOf(alice);

        console.log("\n=== ALICE FINAL BALANCES ===");
        console.log("Alice WMNT balance after:", aliceWmntAfter);
        console.log("Alice stMNT balance after:", aliceStMntAfter);

        // Calcola il guadagno/perdita di Alice
        uint256 wmntNetChange = aliceWmntAfter > aliceWmntBefore - wmntDeposit
            ? aliceWmntAfter - (aliceWmntBefore - wmntDeposit)
            : 0;
        uint256 stMntNetChange = aliceStMntAfter >
            aliceStMntBefore - stMntDeposit
            ? aliceStMntAfter - (aliceStMntBefore - stMntDeposit)
            : 0;

        console.log("\n=== NET PROFIT/LOSS ANALYSIS ===");
        console.log("WMNT net change:", wmntNetChange);
        console.log("stMNT net change:", stMntNetChange);

        // Stato finale della pool
        uint256 poolBalance0After = pool.balances(0);
        uint256 poolBalance1After = pool.balances(1);
        uint256 totalSupplyAfter = pool.totalSupply();
        uint256 strategyAssetsAfter = strategy.estimatedTotalAssets();

        console.log("\n=== FINAL POOL STATE ===");
        console.log("Pool WMNT balance after:", poolBalance0After);
        console.log("Pool stMNT balance after:", poolBalance1After);
        console.log("Total supply after:", totalSupplyAfter);
        console.log("Strategy assets after:", strategyAssetsAfter);

        // ✅ CONTROLLA SE TOTAL SUPPLY > 0 PRIMA DI CHIAMARE getVirtualPrice
        if (totalSupplyAfter > 0) {
            console.log("Final virtual price:", pool.getVirtualPrice());
        } else {
            console.log("Final virtual price: N/A (no shares remaining)");
        }

        // ===================== VERIFICHE =====================

        // 1. Alice deve aver ricevuto i suoi token
        assertGt(wmntReceived, 0, "Should receive WMNT");
        assertGt(stMntReceived, 0, "Should receive stMNT");

        // 2. Le shares devono essere state bruciate
        assertEq(pool.balanceOf(alice), 0, "Alice should have no shares left");

        // 3. stMNT dovrebbe essere esatto (nessuna strategia su stMNT)
        assertEq(stMntReceived, expectedStMnt, "stMNT should be exact");

        // 4. WMNT dovrebbe essere molto vicino al previsto (tolleranza 0.1%)
        if (expectedWmnt > 0) {
            uint256 wmntDifference = expectedWmnt > wmntReceived
                ? expectedWmnt - wmntReceived
                : wmntReceived - expectedWmnt;
            uint256 wmntTolerance = expectedWmnt / 1000; // 0.1% tolerance

            assertLt(
                wmntDifference,
                wmntTolerance,
                "WMNT difference should be within tolerance"
            );
        }

        // 5. Alice dovrebbe aver guadagnato qualcosa (o almeno non perso molto)
        uint256 totalDeposited = wmntDeposit + stMntDeposit;
        uint256 totalReceived = wmntReceived + stMntReceived;

        console.log("\n=== PERFORMANCE SUMMARY ===");
        console.log("Total deposited:", totalDeposited);
        console.log("Total received:", totalReceived);

        if (totalReceived > totalDeposited) {
            uint256 profit = totalReceived - totalDeposited;
            console.log("Profit:", profit);
            if (totalDeposited > 0) {
                uint256 profitBps = (profit * 10000) / totalDeposited;
                console.log("Profit (bps):", profitBps);
            }
            assertGt(profit, 0, "Should have generated profit");
        } else if (totalDeposited > 0) {
            uint256 loss = totalDeposited - totalReceived;
            uint256 lossBps = (loss * 10000) / totalDeposited;
            console.log("Loss:", loss);
            console.log("Loss (bps):", lossBps);
            // Perdita massima accettabile: 0.1% (10 bps)
            assertLt(lossBps, 10, "Loss should be minimal");
        }

        // 6. Il sistema dovrebbe conservare la maggior parte dei fondi
        uint256 systemAssetsBefore = poolBalance0BeforeWithdraw +
            strategyAssetsBeforeWithdraw;
        uint256 systemAssetsAfter = poolBalance0After + strategyAssetsAfter;
        uint256 totalWithdrawn = wmntReceived + stMntReceived;

        console.log("\n=== SYSTEM CONSERVATION ===");
        console.log("System assets before:", systemAssetsBefore);
        console.log("System assets after:", systemAssetsAfter);
        console.log("Total withdrawn by Alice:", totalWithdrawn);
        console.log(
            "Expected system after withdrawal:",
            systemAssetsBefore - totalWithdrawn
        );

        //! DA CONTROLLARE BENE LA QUESTIONE DELLE BOOST FEE PER LA VERIFICA DEI CALCOLI

        console.log("\n=== TEST COMPLETED SUCCESSFULLY ===");
    }
}
