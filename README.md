# 🏦 KipuBankV3: DeFi Vault con Swap Automático

## 💡 Descripción General del Proyecto

**KipuBankV3** es una evolución del contrato bancario KipuBankV2, transformado en un *vault* descentralizado que integra el protocolo **Uniswap V2** para ofrecer depósitos generalizados. Este contrato permite a los usuarios depositar **cualquier token ERC20** con liquidez en Uniswap V2 (o su par WETH/ETH) y lo convierte automáticamente a **USDC**, acreditando el balance final al usuario.

El objetivo principal es mantener la seguridad y la funcionalidad de la versión anterior, mientras se adapta a un entorno DeFi real y se estandariza la contabilidad interna en una moneda estable (USDC).

* **Función Principal:** Aceptar ETH, USDC o cualquier token ERC20, swapear a USDC mediante Uniswap V2 y registrar el balance, respetando el `bankCap`.

---

## ✨ Características Clave y Mejoras

| Característica | Implementación | Notas para Auditor |
| :--- | :--- | :--- |
| **Depósitos Generalizados** | Soporte para `deposit() (ETH)`, `depositUSDC()`, y `depositERC20()`. | La función `depositERC20()` maneja el *swap* de *tokens* a USDC. |
| **Swap Automático a USDC** | Usa la interfaz `IUniswapV2Router02` para ejecutar `swapExactTokensForTokens()` en el *path* a USDC (directo o vía WETH). | Estandariza la contabilidad interna y mitiga la volatilidad para el sistema de límites (`bankCap`). |
| **Respeto al Bank Cap** | El límite (`bankCap`) se verifica usando la cantidad **estimada** de USDC a recibir (o el valor en USDC de ETH usando Chainlink), antes de ejecutar cualquier *swap* o actualizar el balance. | Si el valor del depósito excede el límite total, la transacción revierte. |
| **Protección de Slippage** | El *Owner* puede configurar una tolerancia máxima de *slippage* mediante `setSlippageTolerance(uint256)`. | Esto asegura que el *swap* revierte si se recibe menos de `amountOutMin`, protegiendo al depositante de grandes pérdidas. |

---

## 🛠️ Instrucciones de Desarrollo y Despliegue (Foundry)

El proyecto utiliza **Foundry** (Forge y Cast) para el desarrollo, testing y despliegue.

### 1. Requisitos Previos

* **Foundry:** Instalado y actualizado.
* **Variables de Entorno:** Archivo `.env` configurado con `SEPOLIA_RPC_URL` y `PRIVATE_KEY` para el despliegue.

### 2. Parámetros del Constructor (Sepolia Testnet)

El contrato se inicializa con las siguientes dependencias de la red **Sepolia**:

| Parámetro | Tipo | Dirección (Sepolia) | Descripción |
| :--- | :--- | :--- | :--- |
| `_limitPerTx` | `uint256` | Variable | Límite máximo de depósito/retiro por transacción. |
| `_bankCap` | `uint256` | Variable | Límite máximo de capital total que puede tener el banco. |
| `_chainlinkETHUSD` | `address` | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | Chainlink ETH/USD Price Feed. |
| `_usdc` | `address` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | Dirección del token USDC oficial. |
| `_router` | `address` | (Variable) | Dirección del Uniswap V2 Router. |
| `_weth` | `address` | (Variable) | Dirección del WETH. |

### 3. Compilación y Testing



```Bash
# Compilar el proyecto
forge build

# Ejecutar pruebas (requiere forkear mainnet para liquidez real)
# El objetivo es lograr una cobertura igual o superior al 50%
forge test -vv

```

### 4. Ejecución del Despliegue
El despliegue se realiza usando el script DeployKipuBankV3.sol: 

```bash
# Ejecutar el script de despliegue en Sepolia
# Los argumentos del constructor se pasan desde el script
forge script script/DeployKipuBankV3.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```
---

## 💻 Instrucciones de Interacción (Frontend)

Para el desarrollador frontend, estas son las funciones públicas clave y sus requisitos. Se incluye la **Natspec** para claridad de uso.

### 1. Depósito de Tokens ERC20 (con Swap)

Esta es la función principal para tokens de terceros que se convertirán a USDC.

* **⚠️ Pre-requisito:** El usuario debe ejecutar **`IERC20(tokenIn).approve(KipuBankV3, amountIn)`** previamente para que el banco pueda gastar el token depositado.
* **Función:** `depositERC20`

```solidity
/**
 * @notice Permite el depósito de cualquier token ERC20 con liquidez en Uniswap V2, swapeándolo a USDC.
 * @dev El valor en USDC recibido se usa para la comprobación del bankCap y para actualizar el balance del usuario.
 * @param tokenIn Dirección del token ERC20 a depositar (ej. DAI).
 * @param amountIn Cantidad exacta del token a depositar.
 * @param amountOutMin Cantidad mínima de USDC que el usuario está dispuesto a recibir (protección de slippage).
 */
function depositERC20(
    address tokenIn,
    uint256 amountIn,
    uint256 amountOutMin
) external

```

### 2. Depósito de ETH (Token Nativo)
Convierte el valor de ETH a USDC (usando Chainlink) para la evaluación del bankCap y lo registra como USDC en el balance.

* **Función:** `deposit`

```Solidity

/**
 * @notice Permite el depósito de Ether (token nativo).
 * @dev El valor se convierte a USDC (usando Chainlink) para la comprobación del bankCap y el balance.
 * @dev Se requiere que msg.value sea superior a cero.
 */
function deposit() external payable
```

### 3. Depósito Directo de USDC
Para cuando el usuario ya tiene USDC.

* **⚠️ Pre-requisito:** El usuario debe aprobar el gasto de USDC al contrato KipuBankV3.

* **Función:** `depositUSDC`

```Solidity

/**
 * @notice Permite el depósito directo de USDC.
 * @param amount Cantidad de USDC a depositar.
 */
function depositUSDC(uint256 amount) external
```

### 4. Retiro
Permite al usuario retirar su balance en USDC (la moneda interna del banco).

* **Función:** `withdraw`

```Solidity

/**
 * @notice Permite al usuario retirar USDC de su balance.
 * @param amount Cantidad de USDC a retirar.
 */
function withdraw(uint256 amount) external
```
---

## 🛡️ Informe de Análisis de Amenazas y Seguridad

### Decisiones de Diseño Clave

| Área de Seguridad | Implementación en KipuBankV3 |
| :--- | :--- |
| **Control de Acceso** | El contrato hereda de `Ownable`. Solo el *Owner* puede establecer el `bankCap`, el `limitPerTx`, y la `slippageTolerance`. |
| **Evaluación de Valor** | Uso del **Chainlink ETH/USD Price Feed** para evaluar el valor de los depósitos de ETH y realizar la comprobación del `bankCap` de manera segura. |
| **Protección contra Reentrancy** | Las pruebas unitarias validan que la lógica de `withdraw` no es vulnerable a ataques de reentrada. |
| **Protección de Slippage** | El *Owner* puede configurar la tolerancia, limitada a un máximo de 10% (1000). |

### Debilidades y Pasos Faltantes (Madurez del Protocolo)

| Amenaza/Debilidad | Impacto | Pasos Faltantes para la Madurez |
| :--- | :--- | :--- |
| **Slippage y Liquidez** | El contrato depende del precio de mercado en el *pool* de Uniswap V2, susceptible a volatilidad y manipulación de precio, a pesar del `amountOutMin`. | **Integrar un Oráculo externo (ej. Chainlink)** para validar la cantidad recibida contra un precio de referencia y no solo confiar en la liquidez del *pool*. |
| **Gas Costos** | Las transacciones de *swap* (`depositERC20`) son más costosas debido a la interacción con el Router V2 y las transferencias de token. | Explorar la optimización de las llamadas de `swapExactTokensForTokens` y considerar *Routers* más eficientes en gas. |
| **Riesgo de Aprobación Excesiva** | Si el frontend permite aprobar una cantidad ilimitada, representa un riesgo de seguridad en caso de compromiso del contrato. | El frontend debe implementar el patrón de **Aprobación Just-in-Time** (JIT) o **Aprobación Limitada** para mitigar este riesgo. |

## 🧪 Pruebas y Cobertura

### Métodos de Prueba

Se crearon pruebas unitarias en **Foundry** (`KipuBankV3Test.t.sol`) que corren en un **mainnet fork** para acceder a direcciones y liquidez reales. Las pruebas cubren:

1.  **Lógica del Bank Cap y Límites:** Verificación de que el depósito revierte si el valor en USDC excede los límites por transacción o totales.
2.  **Owner Control:** Pruebas de acceso negativo para funciones sensibles (`setBankCap`, `setSlippageTolerance`).
3.  **Seguridad:** Pruebas de no reentrada (`test_Withdraw_NoReentrancy`).
4.  **Integración de Swap:** Pruebas que simulan el swap de tokens de terceros a USDC y verifican la actualización de balance.

---

## 🌐 Área personal 

*Como abogada incursionando en Solidity... puedo decir que perdí el "juicio" -y en todas las instancias- intentando entender cómo funcionan los smart contracts…*

<img src="https://i.postimg.cc/kXszMC4C/manicomiosinfondojpg.jpg" alt="Locura Total" width="450"/>


```
// return 01001001 00100000 01010001 01010101 01001001 01010100 00100001 00001010
```




