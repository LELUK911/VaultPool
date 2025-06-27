// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Interfaccia per il contratto StrategyStMnt
 * @notice Definisce tutte le funzioni esterne e pubbliche della Strategy,
 * permettendo alla Pool e ad altri contratti di interagire con essa in modo type-safe.
 */
interface IStrategyStMnt {
    // =================================================================
    // GETTER PER LE VARIABILI DI STATO PUBBLICHE
    // =================================================================

    function poolCallWithdraw(uint256 _amount) external returns (uint256);

    /**
     * @notice L'indirizzo del token che la strategia vuole massimizzare (MNT).
     */
    function want() external view returns (address);

    /**
     * @notice L'indirizzo del Vault di staking (stMNT) in cui la strategia deposita i fondi.
     */
    function stVault() external view returns (address);

    /**
     * @notice L'indirizzo della Pool di liquidità a cui questa strategia è collegata.
     */
    function pool() external view returns (address);

    /**
     * @notice Traccia la quantità di 'want' token (MNT) che la Pool ha prestato a questa strategia.
     * @dev Questo rappresenta il "debito" della strategia verso la pool.
     */
    function balanceMNTTGivenPool() external view returns (uint256);

    // =================================================================
    // FUNZIONI PUBBLICHE E DI GESTIONE
    // =================================================================

    /**
     * @notice Restituisce il saldo di 'want' token (MNT) attualmente detenuto da questo contratto.
     */
    function balanceWmnt() external view returns (uint256);

    /**
     * @notice Restituisce il saldo di quote del vault (stMNT) detenute da questo contratto.
     */
    function balanceStMnt() external view returns (uint256);

    /**
     * @notice Approva o revoca l'allowance illimitato di 'want' token verso la Pool.
     * @dev Utile in scenari di migrazione o rimborso del debito.
     * @param _approve Se true, imposta l'allowance a MAX_UINT256, altrimenti a 0.
     */
    function updateUnlimitedSpendingPool(bool _approve) external;

    /**
     * @notice Approva o revoca l'allowance illimitato di 'want' token verso il Vault.
     * @param _approve Se true, imposta l'allowance a MAX_UINT256, altrimenti a 0.
     */
    function updateUnlimitedSpendingVault(bool _approve) external;

    /**
     * @notice Funzione principale chiamata da un keeper o dal governance per eseguire il ciclo di rendimento.
     * @dev Idealmente, questa funzione dovrebbe ricevere i fondi dalla pool, depositarli,
     * raccogliere le ricompense, e fare un report alla pool.
     * @return _profit Il profitto generato in questo ciclo di harvest.
     */
    function harvest() external returns (uint256 _profit);

    // =================================================================
    // FUNZIONI CHE LA POOL CHIAMERÀ SULLA STRATEGY (Pattern Push)
    // Queste funzioni andranno aggiunte al tuo contratto StrategyStMnt
    // =================================================================

    /**
     * @notice Riceve MNT dalla Pool e li investe nel Vault.
     * @dev Questa è la funzione che la Pool chiama per "spingere" i fondi alla strategy.
     * @param _amount La quantità di 'want' token (MNT) da investire.
     */
    function invest(uint256 _amount) external;

    /**
     * @notice Preleva MNT dal Vault e li restituisce alla Pool.
     * @dev Questa funzione viene chiamata dalla Pool quando ha bisogno di liquidità.
     * @param _amount La quantità di 'want' token (MNT) da prelevare.
     */
    function withdraw(uint256 _amount) external;

    /**
     * @notice Restituisce il valore totale degli asset gestiti dalla strategia.
     * @return Il valore totale in 'want' token (MNT).
     */
    function estimatedTotalAssets() external view returns (uint256);
}
