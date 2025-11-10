// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

/**
 * @title DeployKipuBankV3
 * @author Laura-bmk
 * @notice Script para deployar KipuBankV3 en Sepolia Testnet
 * @dev Usa las direcciones oficiales de Sepolia para Chainlink, USDC, Uniswap V2 y WETH
 */
contract DeployKipuBankV3 is Script {
    
    // Chainlink ETH/USD Price Feed en Sepolia
    // Fuente: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet
    address constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    // USDC en Sepolia (Circle oficial)
    // Fuente: https://developers.circle.com/stablecoins/docs/usdc-on-test-networks
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    
    // Uniswap V2 Router en Sepolia
    // Fuente: Documentación de Uniswap V2 en Sepolia
    address constant UNISWAP_V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    
    // WETH en Sepolia (Wrapped ETH oficial)
    // Fuente: https://sepolia.etherscan.io/
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    
    // Límite por transacción: 1000 USD (en formato de 6 decimales)
    uint256 constant LIMIT_PER_TX = 1000 * 1e6; // 1000 USDC
    
    // Capacidad máxima del banco: 10000 USD (en formato de 6 decimales)
    uint256 constant BANK_CAP = 10000 * 1e6; // 10000 USDC
    
    function run() external returns (KipuBankV3) {
        // Obtenemos la private key del archivo .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Comenzamos el broadcast para enviar transacciones
        vm.startBroadcast(deployerPrivateKey);
        
        // Deployamos el contrato KipuBankV3
        KipuBankV3 bank = new KipuBankV3(
            LIMIT_PER_TX,
            BANK_CAP,
            CHAINLINK_ETH_USD,
            USDC,
            UNISWAP_V2_ROUTER,
            WETH
        );
        
        vm.stopBroadcast();
        
        // Mostramos información del deploy
        console.log("===========================================");
        console.log("KipuBankV3 deployed successfully!");
        console.log("===========================================");
        console.log("Contract address:", address(bank));
        console.log("Network: Sepolia Testnet");
        console.log("");
        console.log("Configuration:");
        console.log("- Limit per TX:", LIMIT_PER_TX / 1e6, "USD");
        console.log("- Bank Cap:", BANK_CAP / 1e6, "USD");
        console.log("");
        console.log("External Contracts:");
        console.log("- Chainlink ETH/USD:", CHAINLINK_ETH_USD);
        console.log("- USDC:", USDC);
        console.log("- Uniswap V2 Router:", UNISWAP_V2_ROUTER);
        console.log("- WETH:", WETH);
        console.log("===========================================");
        
        return bank;
    }
}

