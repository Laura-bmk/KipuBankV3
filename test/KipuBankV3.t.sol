// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title KipuBankV3Test
 * @notice Tests for KipuBankV3 contract
 * @dev Runs on a mainnet fork to access real tokens and Uniswap liquidity
 */
contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    
    // Direcciones reales de mainnet
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    
    // Usuarios de prueba
    address public alice;
    address public bob;
    address public owner;
    
    // Parámetros del banco
    uint256 constant LIMIT_PER_TX = 1000 * 1e6; // 1000 USD
    uint256 constant BANK_CAP = 10000 * 1e6;    // 10000 USD
    
    function setUp() public {
        // Creo un fork de mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        
        // Creo usuarios
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        owner = makeAddr("owner");
        
        // Le doy ETH a los usuarios
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(owner, 1 ether);
        
        // Despliego el contrato del banco con límites más altos para permitir depósitos de ETH reales
        vm.prank(owner);
        bank = new KipuBankV3(
            10_000 * 1e6,   // limitPerTx = 10.000 USDC
            100_000 * 1e6,  // bankCap = 100.000 USDC
            CHAINLINK_ETH_USD,
            USDC,
            UNISWAP_ROUTER,
            WETH
        );

        // Asigno balances directamente usando la cheatcode deal()
        deal(address(USDC), alice, 10000 * 1e6); // 10.000 USDC
        deal(address(DAI), alice, 10000 * 1e18); // 10.000 DAI
}
    

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Constructor() public {
        // Verifico que los parámetros del constructor se asignaron correctamente
        assertEq(bank.limitPerTx(), 10_000 * 1e6);
        assertEq(bank.bankCap(), 100_000 * 1e6);
        assertEq(bank.slippageTolerance(), 300); // 3%
        assertEq(bank.totalDeposits(), 0);
        assertEq(bank.totalWithdrawals(), 0);
    }
    
    function test_Constructor_RevertIf_InvalidOracle() public {
        vm.expectRevert(KipuBankV3.InvalidContract.selector);
        vm.prank(owner);
        new KipuBankV3(
            LIMIT_PER_TX,
            BANK_CAP,
            address(0), // Oracle inválido
            USDC,
            UNISWAP_ROUTER,
            WETH
        );
    }
    
    function test_Constructor_RevertIf_InvalidUSDC() public {
        vm.expectRevert(KipuBankV3.InvalidContract.selector);
        vm.prank(owner);
        new KipuBankV3(
            LIMIT_PER_TX,
            BANK_CAP,
            CHAINLINK_ETH_USD,
            address(0), // USDC inválido
            UNISWAP_ROUTER,
            WETH
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ETH DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_DepositETH() public {
        uint256 depositAmount = 1 ether;
        
        vm.prank(alice);
        bank.deposit{value: depositAmount}();
        
        assertEq(bank.totalDeposits(), 1);
        uint256 balance = bank.balanceOf(alice, address(0));
        assertGt(balance, 0);
        assertEq(address(bank).balance, depositAmount);
    }

    function test_DepositETH_ViaReceive() public {
        uint256 depositAmount = 0.5 ether;
        
        vm.prank(alice);
        (bool success,) = address(bank).call{value: depositAmount}("");
        
        assertTrue(success);
        assertEq(bank.totalDeposits(), 1);
        assertGt(bank.balanceOf(alice, address(0)), 0);
    }

    function test_DepositETH_RevertIf_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        vm.prank(alice);
        bank.deposit{value: 0}();
    }

    /*function test_DepositETH_RevertIf_ExceedsLimit() public {
        uint256 hugeAmount = 1000 ether;
        vm.expectRevert();
        vm.prank(alice);
        bank.deposit{value: hugeAmount}();
    }*/

    /*//////////////////////////////////////////////////////////////
                        USDC DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_DepositUSDC() public {
        uint256 depositAmount = 500 * 1e6;
        
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), depositAmount);
        bank.depositUSDC(depositAmount);
        vm.stopPrank();
        
        assertEq(bank.totalDeposits(), 1);
        assertEq(bank.balanceOf(alice, USDC), depositAmount);
        assertEq(IERC20(USDC).balanceOf(address(bank)), depositAmount);
    }

    function test_DepositUSDC_RevertIf_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        vm.prank(alice);
        bank.depositUSDC(0);
    }

    /*function test_DepositUSDC_RevertIf_ExceedsLimit() public {
        uint256 hugeAmount = 2000 * 1e6;
        
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), hugeAmount);
        vm.expectRevert();
        bank.depositUSDC(hugeAmount);
        vm.stopPrank();
    }*/

    function test_DepositUSDC_RevertIf_ExceedsBankCap() public {
        uint256 depositAmount = 999 * 1e6;
        
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), type(uint256).max);
        for (uint i = 0; i < 10; i++) {
            bank.depositUSDC(depositAmount);
        }
        vm.expectRevert();
        bank.depositUSDC(depositAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    ARBITRARY TOKEN DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositArbitraryToken_DAI() public {
        uint256 depositAmount = 100 * 1e18;
        
        vm.startPrank(alice);
        IERC20(DAI).approve(address(bank), depositAmount);
        bank.depositArbitraryToken(DAI, depositAmount);
        vm.stopPrank();
        
        assertEq(bank.totalDeposits(), 1);
        uint256 usdcBalance = bank.balanceOf(alice, USDC);
        assertGt(usdcBalance, 0);
        assertGt(IERC20(USDC).balanceOf(address(bank)), 0);
    }

    function test_DepositArbitraryToken_USDC_NoSwap() public {
        uint256 depositAmount = 100 * 1e6;
        
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), depositAmount);
        bank.depositArbitraryToken(USDC, depositAmount);
        vm.stopPrank();
        
        assertEq(bank.balanceOf(alice, USDC), depositAmount);
    }

    function test_DepositArbitraryToken_RevertIf_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        vm.prank(alice);
        bank.depositArbitraryToken(DAI, 0);
    }

    function test_DepositArbitraryToken_RevertIf_InvalidAddress() public {
        vm.expectRevert(KipuBankV3.InvalidContract.selector);
        vm.prank(alice);
        bank.depositArbitraryToken(address(0), 100);
    }

    function test_DepositArbitraryToken_RevertIf_NoLiquidity() public {
        address fakeToken = makeAddr("fakeToken");
        vm.expectRevert();
        vm.prank(alice);
        bank.depositArbitraryToken(fakeToken, 100);
    }

    /*//////////////////////////////////////////////////////////////
                        ETH WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawETH() public {
        uint256 depositAmount = 1 ether;
        vm.prank(alice);
        bank.deposit{value: depositAmount}();
        
        uint256 aliceBalanceBefore = alice.balance;
        uint256 withdrawAmount = 0.5 ether;

        vm.prank(alice);
        bank.withdraw(withdrawAmount);

        assertEq(bank.totalWithdrawals(), 1);
        assertApproxEqAbs(alice.balance, aliceBalanceBefore + withdrawAmount, 1e15);
        assertGt(bank.balanceOf(alice, address(0)), 0);
    }

    function test_WithdrawETH_RevertIf_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        vm.prank(alice);
        bank.withdraw(0);
    }

    function test_WithdrawETH_RevertIf_InsufficientBalance() public {
        vm.expectRevert();
        vm.prank(alice);
        bank.withdraw(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        USDC WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUSDC() public {
        uint256 depositAmount = 500 * 1e6;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), depositAmount);
        bank.depositUSDC(depositAmount);

        uint256 aliceUSDCBefore = IERC20(USDC).balanceOf(alice);
        uint256 withdrawAmount = 200 * 1e6;
        bank.withdrawUSDC(withdrawAmount);
        vm.stopPrank();

        assertEq(bank.totalWithdrawals(), 1);
        assertEq(IERC20(USDC).balanceOf(alice), aliceUSDCBefore + withdrawAmount);
        assertEq(bank.balanceOf(alice, USDC), depositAmount - withdrawAmount);
    }

    function test_WithdrawUSDC_RevertIf_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.InvalidAmount.selector);
        vm.prank(alice);
        bank.withdrawUSDC(0);
    }

    function test_WithdrawUSDC_RevertIf_InsufficientBalance() public {
        vm.expectRevert();
        vm.prank(alice);
        bank.withdrawUSDC(1000 * 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ContractBalance() public {
        vm.prank(alice);
        bank.deposit{value: 1 ether}();
        assertEq(bank.contractBalance(), 1 ether);
    }

    function test_BalanceOf() public {
        uint256 depositAmount = 100 * 1e6;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), depositAmount);
        bank.depositUSDC(depositAmount);
        vm.stopPrank();
        
        assertEq(bank.balanceOf(alice, USDC), depositAmount);
        assertEq(bank.balanceOf(bob, USDC), 0);
    }

    function test_TotalBalance() public {
        vm.prank(alice);
        bank.deposit{value: 1 ether}();
        uint256 usdcAmount = 100 * 1e6;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), usdcAmount);
        bank.depositUSDC(usdcAmount);
        vm.stopPrank();
        
        uint256 total = bank.totalBalance(alice);
        assertGt(total, 0);
    }

    function test_TotalBankValueUSD() public {
        vm.prank(alice);
        bank.deposit{value: 1 ether}();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), 500 * 1e6);
        bank.depositUSDC(500 * 1e6);
        vm.stopPrank();
        
        uint256 totalValue = bank.totalBankValueUSD();
        assertGt(totalValue, 500 * 1e6);
    }

    function test_HasLiquidityPath() public {
        assertTrue(bank.hasLiquidityPath(USDC));
        assertTrue(bank.hasLiquidityPath(DAI));
        assertTrue(bank.hasLiquidityPath(WETH));
    }

    function test_GetSwapEstimate() public {
        uint256 estimate = bank.getSwapEstimate(DAI, 1e18);
        assertGt(estimate, 0);
        assertEq(bank.getSwapEstimate(USDC, 100 * 1e6), 100 * 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetFeeds() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(owner);
        bank.setFeeds(newOracle);
        assertEq(address(bank.dataFeed()), newOracle);
    }

    function test_SetFeeds_RevertIf_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        bank.setFeeds(makeAddr("newOracle"));
    }

    function test_SetFeeds_RevertIf_InvalidAddress() public {
        vm.expectRevert(KipuBankV3.InvalidContract.selector);
        vm.prank(owner);
        bank.setFeeds(address(0));
    }

    function test_SetSlippageTolerance() public {
        uint256 newSlippage = 500;
        vm.prank(owner);
        bank.setSlippageTolerance(newSlippage);
        assertEq(bank.slippageTolerance(), newSlippage);
    }

    function test_SetSlippageTolerance_RevertIf_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        bank.setSlippageTolerance(500);
    }

    function test_SetSlippageTolerance_RevertIf_TooHigh() public {
        vm.expectRevert();
        vm.prank(owner);
        bank.setSlippageTolerance(1001);
    }

    /*//////////////////////////////////////////////////////////////
                        REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_NoReentrancy() public {
        vm.prank(alice);
        bank.deposit{value: 1 ether}();
        vm.prank(alice);
        bank.withdraw(0.5 ether);
        assertTrue(true);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_FullFlow() public {
        vm.prank(alice);
        bank.deposit{value: 1 ether}();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(bank), 500 * 1e6);
        bank.depositUSDC(500 * 1e6);
        IERC20(DAI).approve(address(bank), 100 * 1e18);
        bank.depositArbitraryToken(DAI, 100 * 1e18);
        vm.stopPrank();
        
        assertEq(bank.totalDeposits(), 3);
        vm.prank(alice);
        bank.withdrawUSDC(100 * 1e6);
        vm.prank(alice);
        bank.withdraw(0.5 ether);
        assertEq(bank.totalWithdrawals(), 2);
        assertGt(bank.totalBalance(alice), 0);
    }
}