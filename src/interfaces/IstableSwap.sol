// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Interfaccia per il contratto StableSwap
/// @notice Definisce tutte le funzioni esterne e pubbliche del contratto StableSwap,
///         consentendo ad altri contratti di interagire con esso in modo type-safe.
/// @dev Poiché il contratto StableSwap è anche un token ERC20, questa interfaccia
///      eredita da IERC20 per includere tutte le funzioni standard del token.
interface IStableSwap is IERC20 {
    // =================================================================
    // GETTER PER LE VARIABILI DI STATO PUBBLICHE
    // =================================================================

    /**
     * @notice Restituisce l'indirizzo del token a un dato indice (0 o 1).
     * @param index L'indice del token nell'array.
     * @return L'indirizzo del token ERC20.
     */
    function tokens(uint256 index) external view returns (address);

    /**
     * @notice Restituisce il saldo di un token all'interno della pool.
     * @param index L'indice del token nell'array.
     * @return Il saldo del token.
     */
    function balances(uint256 index) external view returns (uint256);

    function balanceInStrategy(uint256 index) external view returns (uint256);

    // =================================================================
    // FUNZIONI PRINCIPALI DELLA POOL
    // =================================================================

    /**
     * @notice Calcola il "prezzo virtuale" di una singola quota (share) della pool,
     * espresso nel valore combinato dei token sottostanti.
     * @return Il prezzo virtuale per quota.
     */
    function getVirtualPrice() external view returns (uint256);

    /**
     * @notice Scambia una quantità `dx` di token `i` per ottenere token `j`.
     * @param i L'indice del token che si sta inviando (0 o 1).
     * @param j L'indice del token che si vuole ricevere (0 o 1).
     * @param dx La quantità di token `i` da scambiare.
     * @param minDy La quantità minima di token `j` che si è disposti a ricevere.
     * @return dy La quantità di token `j` ricevuta.
     */
    function swap(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy
    ) external returns (uint256 dy);

    /**
     * @notice Aggiunge liquidità alla pool.
     * @param amounts Un array con le quantità dei due token da depositare.
     * @param minShares La quantità minima di quote (token LP) che si è disposti a ricevere.
     * @return shares La quantità di quote (token LP) mintate.
     */
    function addLiquidity(
        uint256[2] calldata amounts,
        uint256 minShares
    ) external returns (uint256 shares);

    /**
     * @notice Rimuove liquidità dalla pool in cambio di entrambi i token sottostanti.
     * @param shares La quantità di quote (token LP) da bruciare.
     * @param minAmountsOut Un array con le quantità minime dei due token che si è disposti a ricevere.
     * @return amountsOut Un array con le quantità dei due token effettivamente ricevute.
     */
    function removeLiquidity(
        uint256 shares,
        uint256[2] calldata minAmountsOut
    ) external returns (uint256[2] memory amountsOut);

    /**
     * @notice Calcola quanto del token `i` si riceverebbe bruciando una certa quantità di quote,
     * inclusa la commissione di sbilanciamento.
     * @param shares La quantità di quote da bruciare.
     * @param i L'indice del token che si vuole prelevare.
     * @return dy La quantità di token `i` che si riceverebbe.
     * @return fee La commissione pagata per il prelievo sbilanciato.
     */
    function calcWithdrawOneToken(
        uint256 shares,
        uint256 i
    ) external view returns (uint256 dy, uint256 fee);

    /**
     * @notice Rimuove liquidità dalla pool e la preleva sotto forma di un solo token.
     * @param shares La quantità di quote (token LP) da bruciare.
     * @param i L'indice del token che si vuole prelevare (0 o 1).
     * @param minAmountOut La quantità minima del token `i` che si è disposti a ricevere.
     * @return amountOut La quantità di token `i` effettivamente ricevuta.
     */
    function removeLiquidityOneToken(
        uint256 shares,
        uint256 i,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);

    function report(
        uint256 _profit,
        uint256 _loss,
        uint256 _newTotalDebt
    ) external;

    function callEmergencyCall() external;
}
