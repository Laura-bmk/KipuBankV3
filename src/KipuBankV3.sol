// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV3
 * @author Laura-bmk
 * @notice This is a DeFi bank that accepts any ERC20 token and automatically converts it to USDC using Uniswap V2
 * @dev This is an evolution of KipuBankV2 with Uniswap V2 integration. I've added:
 * - Support for ETH, USDC, and any ERC20 token that has liquidity on Uniswap V2
 * - Automatic token swaps to USDC when users deposit non-USDC tokens
 * - All the security features from KipuBankV2 are still here
 * - Smart routing system (direct pairs or through WETH)
 * - Same limits and protections as before
 */
contract KipuBankV3 is Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice I use address(0) to represent native ETH in my mappings
    /// @dev This helps me differentiate ETH from ERC20 tokens
    address private constant ETH_ADDRESS = address(0);

    /// @notice USDC has 6 decimals on most networks
    uint8 private constant USDC_DECIMALS = 6;
    
    /// @notice ETH always has 18 decimals (1 ETH = 10^18 wei)
    uint8 private constant ETH_DECIMALS = 18;
    
    /// @notice All Chainlink price feeds return prices with 8 decimals
    uint8 private constant ORACLE_DECIMALS = 8;
    
    /// @notice I'm using 6 decimals for all my internal USD calculations
    /// @dev This matches USDC's decimals which makes the math easier
    uint8 private constant TARGET_DECIMALS = 6;

    /// @notice My reentrancy lock starts and ends in this state
    uint8 private constant UNLOCKED = 1;
    
    /// @notice While a function is executing, the lock is in this state
    uint8 private constant LOCKED = 2;

    /// @notice Maximum slippage I allow by default is 3%
    /// @dev 300 basis points = 3%
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 300;

    /// @notice Base for all my percentage calculations
    /// @dev 10000 basis points = 100%
    uint256 private constant BPS_BASE = 10000;

    /// @notice Maximum time I accept for Chainlink prices (1 hour)
    /// @dev If the price is older than this, I reject it as stale
    uint256 private constant PRICE_TIMEOUT = 3600;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum amount allowed per transaction in USD (6 decimals)
    /// @dev Example: 1000 USD = 1000000000 (1000 * 10^6)
    uint256 public immutable limitPerTx;

    /// @notice Maximum total capacity my bank can hold in USD (6 decimals)
    /// @dev Example: 10000 USD = 10000000000 (10000 * 10^6)
    uint256 public immutable bankCap;

    /// @notice I store each user's balance per token in USD (6 decimals)
    /// @dev Mapping structure: user address => token address => balance in USD
    /// @dev For ETH I use address(0), for tokens I use their contract address
    mapping(address => mapping(address => uint256)) public balance;

    /// @notice Counter to track total number of deposits
    uint256 public totalDeposits;
    
    /// @notice Counter to track total number of withdrawals
    uint256 public totalWithdrawals;

    /// @notice My reentrancy protection flag
    /// @dev I alternate between UNLOCKED (1) and LOCKED (2)
    uint8 private flag = UNLOCKED;

    /// @notice The Chainlink oracle I use to get ETH/USD prices
    AggregatorV3Interface public dataFeed;

    /// @notice Reference to the USDC token contract
    IERC20 public immutable USDC;

    /// @notice The Uniswap V2 router I use to execute token swaps
    IUniswapV2Router02 public immutable uniswapRouter;

    /// @notice WETH address - I use it as an intermediary token in some swap routes
    address public immutable WETH;

    /// @notice How much slippage I tolerate in swaps (in basis points)
    /// @dev Starts at 300 (3%) but the owner can change it
    uint256 public slippageTolerance;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice I emit this when a user deposits tokens
    /// @param user Who made the deposit
    /// @param token Which token they deposited
    /// @param amount How much they deposited (in token's own units)
    /// @param amountInUSDC The value in USDC (6 decimals)
    event DepositPerformed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 amountInUSDC
    );

    /// @notice I emit this when a user withdraws tokens
    /// @param user Who made the withdrawal
    /// @param token Which token they withdrew
    /// @param amount How much they withdrew
    event WithdrawalPerformed(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice I emit this when the owner updates the oracle
    /// @param addr New oracle address
    /// @param time When the change happened
    event FeedSet(address indexed addr, uint256 time);

    /// @notice I emit this when a swap is executed successfully
    /// @param user User whose deposit triggered the swap
    /// @param tokenIn Token that was swapped
    /// @param tokenOut Token that was received (always USDC)
    /// @param amountIn Amount swapped
    /// @param amountOut Amount received
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice I emit this when slippage tolerance changes
    /// @param oldSlippage Previous value
    /// @param newSlippage New value
    event SlippageToleranceUpdated(uint256 oldSlippage, uint256 newSlippage);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice I throw this when someone tries to deposit/withdraw 0
    error InvalidAmount();
    
    /// @notice I throw this when a transaction exceeds the per-tx limit
    /// @param requested What they tried to deposit/withdraw
    /// @param limit What the maximum allowed is
    error ExceedsPerTxLimit(uint256 requested, uint256 limit);
    
    /// @notice I throw this when a user doesn't have enough balance
    /// @param balance What they actually have
    /// @param requested What they tried to withdraw
    error InsufficientBalance(uint256 balance, uint256 requested);
    
    /// @notice I throw this when an ETH transfer fails
    /// @param reason The error data returned
    error TransactionFailed(bytes reason);
    
    /// @notice I throw this when I detect a reentrancy attack
    error ReentrancyAttempt();
    
    /// @notice I throw this when a deposit would exceed the bank's total capacity
    /// @param requested What the total would be after the deposit
    /// @param available What the maximum capacity is
    error BankCapExceeded(uint256 requested, uint256 available);
    
    /// @notice I throw this when someone provides an invalid address (address(0))
    error InvalidContract();

    /// @notice I throw this when a Uniswap swap fails or returns 0
    error SwapFailed();

    /// @notice I throw this when there's no liquidity pair for a token
    /// @param token The token that doesn't have a pair
    error NoPairAvailable(address token);

    /// @notice I throw this when someone tries to set slippage > 10%
    /// @param slippage The invalid value they tried to set
    error InvalidSlippageTolerance(uint256 slippage);

    /// @notice I throw this when the Chainlink oracle fails or returns invalid data
    error OracleError();

    /// @notice I throw this when the price from Chainlink is too old
    /// @param timeSinceUpdate How long ago the price was updated (in seconds)
    error StalePrice(uint256 timeSinceUpdate);

    /// @notice I throw this when Chainlink returns a price that doesn't make sense
    /// @param price The invalid price returned
    error InvalidPrice(int256 price);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice I use this to protect my functions from reentrancy attacks
    /// @dev I switch my lock between 1 and 2 to detect if someone tries to call the function again while it's still running
    modifier reentrancyGuard() {
        if (flag == LOCKED) revert ReentrancyAttempt();
        flag = LOCKED;
        _;
        flag = UNLOCKED;
    }

    /// @notice I use this to make sure msg.value is not zero
    modifier validAmount() {
        if (msg.value == 0) revert InvalidAmount();
        _;
    }

    /// @notice I use this to validate that any amount parameter is not zero
    /// @param amount The amount I'm checking
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    /// @notice I validate that an amount in USD doesn't exceed the per-transaction limit
    /// @param amountInUSD Amount in USD (with 6 decimals)
    modifier withinTxLimit(uint256 amountInUSD) {
        if (amountInUSD > limitPerTx) {
            revert ExceedsPerTxLimit(amountInUSD, limitPerTx);
        }
        _;
    }

    /// @notice I check that a user has enough balance before they can withdraw
    /// @param user The user I'm checking
    /// @param token Which token to check
    /// @param requiredAmount How much they need (in USD with 6 decimals)
    modifier hasSufficientBalance(address user, address token, uint256 requiredAmount) {
        uint256 userBalance = balance[user][token];
        if (requiredAmount > userBalance) {
            revert InsufficientBalance(userBalance, requiredAmount);
        }
        _;
    }

    /// @notice I make sure deposits don't exceed my bank's maximum capacity
    /// @param depositAmountUSD Amount being deposited (in USD with 6 decimals)
    modifier withinBankCap(uint256 depositAmountUSD) {
        uint256 _totalBankUSD = _getTotalBankValueUSD() + depositAmountUSD;
        if (_totalBankUSD > bankCap) {
            revert BankCapExceeded(_totalBankUSD, bankCap);
        }
        _;
    }

    /// @notice I check that an address is valid (not the zero address)
    /// @param addr The address I'm validating
    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidContract();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I set up the bank with all the parameters and connections it needs
     * @param _limitPerTx Maximum amount per transaction in USD (with 6 decimals)
     * @param _bankCap Maximum total capacity in USD (with 6 decimals)
     * @param _oracle Chainlink oracle address that gives me ETH/USD prices
     * @param _usdc USDC token contract address
     * @param _uniswapRouter Uniswap V2 router address for doing swaps
     * @param _weth WETH token address
     * @dev I check all addresses to make sure none of them are address(0)
     */
    constructor(
        uint256 _limitPerTx,
        uint256 _bankCap,
        address _oracle,
        address _usdc,
        address _uniswapRouter,
        address _weth
    ) 
        Ownable(msg.sender)
        validAddress(_oracle)
        validAddress(_usdc)
        validAddress(_uniswapRouter)
        validAddress(_weth)
    {
        // Guardo los límites que son inmutables
        limitPerTx = _limitPerTx;
        bankCap = _bankCap;
        
        // Conecto con el oráculo de Chainlink
        dataFeed = AggregatorV3Interface(_oracle);
        
        // Guardo las referencias a los contratos que voy a usar
        USDC = IERC20(_usdc);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        WETH = _weth;
        
        // Configuro el slippage por defecto en 3%
        slippageTolerance = DEFAULT_SLIPPAGE_BPS;

        emit FeedSet(_oracle, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I accept ETH deposits and save the USD value to the user's balance
     * @dev I ask Chainlink for the current ETH price and then convert the amount
     */
    function deposit() public payable validAmount {
        // Primero obtengo el precio actual de ETH en USD
        int256 _latestAnswer = _getETHPrice();
        
        // Convierto el ETH que me mandaron a su equivalente en USD
        uint256 _depositedInUSDC = _convertToUSD(
            msg.value,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Valido que no se exceda el límite por transacción
        _validateTxLimit(_depositedInUSDC);

        // Valido que el banco no supere su capacidad máxima
        _validateBankCap(_depositedInUSDC);

        // Actualizo el balance del usuario
        balance[msg.sender][ETH_ADDRESS] += _depositedInUSDC;
        
        unchecked {
            totalDeposits++;
        }

        emit DepositPerformed(msg.sender, ETH_ADDRESS, msg.value, _depositedInUSDC);
    }

    /**
     * @notice I accept USDC deposits without any conversion
     * @param _usdcAmount Amount of USDC to deposit (with 6 decimals)
     * @dev Users must call USDC.approve() first before they can deposit
     */
    function depositUSDC(uint256 _usdcAmount) 
        external 
        nonZeroAmount(_usdcAmount)
        withinTxLimit(_usdcAmount)
        withinBankCap(_usdcAmount)
    {
        // Como es USDC, no necesito convertir
        balance[msg.sender][address(USDC)] += _usdcAmount;
        
        unchecked {
            totalDeposits++;
        }

        // Transfiero los USDC desde el usuario hacia acá
        USDC.safeTransferFrom(msg.sender, address(this), _usdcAmount);

        emit DepositPerformed(msg.sender, address(USDC), _usdcAmount, _usdcAmount);
    }

    /**
     * @notice I accept any ERC20 token that has liquidity on Uniswap V2
     * @param token Address of the token someone wants to deposit
     * @param amount How much of that token they want to deposit
     * @dev This is what happens step by step:
     *      1. I transfer the tokens from the user to my contract (they need to approve first)
     *      2. If it's USDC, I just save it directly
     *      3. If it's a different token, I swap it for USDC using Uniswap V2
     *      4. I check that the deposit doesn't make the bank too full
     *      5. I add the USDC amount to the user's balance
     */
    function depositArbitraryToken(address token, uint256 amount) 
        external 
        reentrancyGuard
        nonZeroAmount(amount)
        validAddress(token)
    {
        // Primero traigo los tokens del usuario hacia acá
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        uint256 usdcAmount;
        
        // Si es USDC, no necesito hacer swap
        if (token == address(USDC)) {
            usdcAmount = amount;
        } else {
            // Verifico que tenga liquidez en Uniswap
            if (!_hasLiquidityPath(token)) {
                revert NoPairAvailable(token);
            }

            // Hago el swap a USDC
            usdcAmount = _swapToUSDC(token, amount);
            
            // Me aseguro que el swap funcionó
            if (usdcAmount == 0) revert SwapFailed();
        }
        
        // Valido límites
        _validateTxLimit(usdcAmount);
        _validateBankCap(usdcAmount);
        
        // Actualizo el balance del usuario
        balance[msg.sender][address(USDC)] += usdcAmount;
        
        unchecked {
            totalDeposits++;
        }
        
        emit DepositPerformed(msg.sender, token, amount, usdcAmount);
    }

    /**
     * @notice I receive ETH when someone sends it directly to my contract
     */
    receive() external payable {
        deposit();
    }

    /**
     * @notice I treat any unknown function call as a deposit
     */
    fallback() external payable {
        deposit();
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I let users take out their ETH
     * @param amount How much ETH to withdraw (in wei)
     * @return data Information returned by the transfer
     * @dev I need to convert the ETH amount to USD first to check their balance
     */
    function withdraw(uint256 amount)
        external
        reentrancyGuard
        nonZeroAmount(amount)
        returns (bytes memory data)
    {
        // Obtengo el precio actual de ETH
        int256 _latestAnswer = _getETHPrice();
        uint256 _withdrawInUSDC = _convertToUSD(
            amount,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Valido límites y balance
        _validateTxLimit(_withdrawInUSDC);
        _validateSufficientBalance(msg.sender, ETH_ADDRESS, _withdrawInUSDC);

        // Descuento del balance (seguro usar unchecked porque ya validé el balance)
        unchecked {
            balance[msg.sender][ETH_ADDRESS] -= _withdrawInUSDC;
            totalWithdrawals++;
        }

        // Envío el ETH
        data = _transferEth(msg.sender, amount);

        emit WithdrawalPerformed(msg.sender, ETH_ADDRESS, amount);
        return data;
    }

    /**
     * @notice I let users take out their USDC
     * @param amount How much USDC to withdraw (with 6 decimals)
     */
    function withdrawUSDC(uint256 amount) 
        external 
        reentrancyGuard
        nonZeroAmount(amount)
        withinTxLimit(amount)
        hasSufficientBalance(msg.sender, address(USDC), amount)
    {
        // Descuento del balance (seguro usar unchecked porque ya validé el balance)
        unchecked {
            balance[msg.sender][address(USDC)] -= amount;
            totalWithdrawals++;
        }

        // Transfiero los USDC
        USDC.safeTransfer(msg.sender, amount);

        emit WithdrawalPerformed(msg.sender, address(USDC), amount);
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE FUNCTIONS - UNISWAP V2
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I swap any token for USDC using Uniswap V2
     * @param tokenIn The token I'm swapping
     * @param amountIn How much I'm swapping
     * @return amountOut How much USDC I got back
     * @dev My strategy for finding the best route:
     *      1. First I try going directly: Token → USDC
     *      2. If there's no direct pair, I go through WETH: Token → WETH → USDC
     */
    function _swapToUSDC(address tokenIn, uint256 amountIn)
    private
    returns (uint256 amountOut)
{
    // Le doy permiso al router para usar mis tokens
    // Uso forceApprove en lugar de safeApprove (deprecado)
    IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

    // Armo la ruta del swap
    address[] memory path = _buildSwapPath(tokenIn);

    // Calculo cuánto USDC espero recibir como mínimo
    uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amountIn, path);
    uint256 expectedOut = amountsOut[amountsOut.length - 1];
    uint256 minAmountOut = (expectedOut * (BPS_BASE - slippageTolerance)) / BPS_BASE;

    // Ejecuto el swap
    uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
        amountIn,
        minAmountOut,
        path,
        address(this),
        block.timestamp + 15 minutes
    );

    // La última posición tiene la cantidad de USDC que recibí
    amountOut = amounts[amounts.length - 1];

    emit SwapExecuted(msg.sender, tokenIn, address(USDC), amountIn, amountOut);

    return amountOut;
}

    /**
     * @notice I figure out the best route to swap a token to USDC
     * @param tokenIn The token I want to swap
     * @return path An array showing the route I'll take
     * @dev I check if there's a direct pair first, otherwise I go through WETH
     */
    function _buildSwapPath(address tokenIn) 
        private 
        view 
        returns (address[] memory path) 
    {
        // Verifico si existe un par directo
        if (_pairExists(tokenIn, address(USDC))) {
            // Puedo ir directo
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = address(USDC);
        } else {
            // Tengo que pasar por WETH
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = WETH;
            path[2] = address(USDC);
        }
        
        return path;
    }

    /**
     * @notice I check if two tokens have a liquidity pair on Uniswap V2
     * @param tokenA First token
     * @param tokenB Second token
     * @return exists True if the pair exists
     */
    function _pairExists(address tokenA, address tokenB) 
        private 
        view 
        returns (bool exists) 
    {
        // Le pregunto a la factory si existe el par
        address factory = uniswapRouter.factory();
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        
        return pair != address(0);
    }

    /**
     * @notice I check if there's a way to swap a token to USDC
     * @param token The token I'm checking
     * @return hasPath True if I can swap it (either directly or through WETH)
     */
    function _hasLiquidityPath(address token) 
        private 
        view 
        returns (bool hasPath) 
    {
        // Primero verifico par directo
        if (_pairExists(token, address(USDC))) {
            return true;
        }
        
        // Si no, verifico la ruta con WETH
        if (_pairExists(token, WETH) && _pairExists(WETH, address(USDC))) {
            return true;
        }
        
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I send ETH to someone using a low-level call
     * @param to Who gets the ETH
     * @param amount How much ETH to send (in wei)
     * @return Whatever data the call returns
     */
    function _transferEth(address to, uint256 amount)
        private
        returns (bytes memory)
    {
        (bool success, bytes memory data) = to.call{value: amount}("");
        if (!success) revert TransactionFailed(data);
        return data;
    }

    /**
     * @notice I ask Chainlink for the current ETH price and make sure it's valid
     * @return _latestAnswer ETH price in USD (with 8 decimals)
     * @dev I check that the price is recent (less than 1 hour old) and makes sense
     */
    function _getETHPrice() private view returns(int256 _latestAnswer) {
        // Intento obtener los datos del oráculo
        try dataFeed.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Valido que el precio sea positivo
            if (answer <= 0) {
                revert InvalidPrice(answer);
            }
            
            // Valido que el round esté completo
            if (updatedAt == 0) {
                revert OracleError();
            }
            
            // Verifico que no sea un precio obsoleto
            if (answeredInRound < roundId) {
                revert StalePrice(0);
            }
            
            // Verifico que no sea muy antiguo (máximo 1 hora)
            uint256 secondsSinceUpdate = block.timestamp - updatedAt;
            if (secondsSinceUpdate > PRICE_TIMEOUT) {
                revert StalePrice(secondsSinceUpdate);
            }
            
            return answer;
            
        } catch {
            // Si falla la llamada, revierto
            revert OracleError();
        }
    }

    /**
     * @notice I convert any token amount to its value in USD
     * @param _amount The original amount in the token's units
     * @param _decimals How many decimals the token has
     * @param _priceUSD The token's price in USD (with 8 decimals from Chainlink)
     * @return _valueUSD The value in USD (with 6 decimals)
     * @dev I do some math to adjust all the decimals so everything ends up with 6 decimals
     */
    function _convertToUSD(
        uint256 _amount,
        uint8 _decimals,
        uint256 _priceUSD
    ) private pure returns (uint256 _valueUSD) {
        uint256 numerator = _amount * _priceUSD;
        uint256 denominator = 10 ** (_decimals + ORACLE_DECIMALS - TARGET_DECIMALS);
        
        return numerator / denominator;
    }

    /**
     * @notice I calculate the total value my bank is holding right now
     * @return _totalUSD Total value in USD (with 6 decimals)
     * @dev I add up all the ETH (converted to USD) plus all the USDC
     */
    function _getTotalBankValueUSD() private view returns (uint256 _totalUSD) {
        // Calculo cuánto vale el ETH que tengo
        int256 _latestAnswer = _getETHPrice();
        uint256 totalETH = address(this).balance;
        uint256 ethValueUSD = _convertToUSD(
            totalETH,
            ETH_DECIMALS,
            uint256(_latestAnswer)
        );

        // Sumo el USDC que tengo
        uint256 totalUSDC = USDC.balanceOf(address(this));

        _totalUSD = ethValueUSD + totalUSDC;
    }

    /**
     * @notice I make sure a deposit won't make my bank too full
     * @param depositAmountUSD How much is being deposited (in USD with 6 decimals)
     */
    function _validateBankCap(uint256 depositAmountUSD) private view {
        uint256 _totalBankUSD = _getTotalBankValueUSD() + depositAmountUSD;
        if (_totalBankUSD > bankCap) {
            revert BankCapExceeded(_totalBankUSD, bankCap);
        }
    }

    /**
     * @notice I check that an amount doesn't go over the per-transaction limit
     * @param amountInUSD Amount in USD (with 6 decimals)
     */
    function _validateTxLimit(uint256 amountInUSD) private view {
        if (amountInUSD > limitPerTx) {
            revert ExceedsPerTxLimit(amountInUSD, limitPerTx);
        }
    }

    /**
     * @notice I check that a user has enough money to make a withdrawal
     * @param user The user's address
     * @param token Which token to check
     * @param requiredAmount How much they need (in USD with 6 decimals)
     */
    function _validateSufficientBalance(
        address user,
        address token,
        uint256 requiredAmount
    ) private view {
        uint256 userBalance = balance[user][token];
        if (requiredAmount > userBalance) {
            revert InsufficientBalance(userBalance, requiredAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I tell you how much ETH my contract is holding
     * @return ETH balance in wei
     */
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice I tell you how much of a specific token a user has
     * @param account The user's address
     * @param token Which token to check
     * @return The user's balance in USD (with 6 decimals)
     */
    function balanceOf(address account, address token) external view returns (uint256) {
        return balance[account][token];
    }

    /**
     * @notice I tell you the total amount a user has across all their tokens
     * @param account The user's address
     * @return Total balance in USD (with 6 decimals)
     */
    function totalBalance(address account) external view returns (uint256) {
        return balance[account][ETH_ADDRESS] + balance[account][address(USDC)];
    }

    /**
     * @notice I tell you the total value my bank is holding right now
     * @return Total value in USD (with 6 decimals)
     */
    function totalBankValueUSD() external view returns (uint256) {
        return _getTotalBankValueUSD();
    }

    /**
     * @notice I check if a token can be swapped to USDC on Uniswap V2
     * @param token The token address to check
     * @return hasPath True if I can swap it to USDC
     * @dev This is helpful for websites that want to check tokens before letting users deposit
     */
    function hasLiquidityPath(address token) external view returns (bool hasPath) {
        if (token == address(USDC)) return true;
        return _hasLiquidityPath(token);
    }

    /**
     * @notice I give you an estimate of how much USDC you'd get from swapping a token
     * @param token The token you want to swap
     * @param amount How much of that token
     * @return estimatedUSDC Estimated USDC you would receive
     * @dev This is helpful for websites to show estimates before users deposit
     * @dev Keep in mind: the real swap might be a bit different because of slippage
     */
    function getSwapEstimate(address token, uint256 amount) 
        external 
        view 
        returns (uint256 estimatedUSDC) 
    {
        // Si es USDC, devuelvo el mismo monto
        if (token == address(USDC)) return amount;
        
        // Si no tiene liquidez, devuelvo 0
        if (!_hasLiquidityPath(token)) return 0;
        
        // Obtengo la estimación de Uniswap
        address[] memory path = _buildSwapPath(token);
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amount, path);
        return amountsOut[amountsOut.length - 1];
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice I let the owner change which Chainlink oracle I use
     * @param _feed The new oracle address
     * @dev Only the owner can do this
     */
    function setFeeds(address _feed) 
        external 
        onlyOwner 
        validAddress(_feed)
    {
        dataFeed = AggregatorV3Interface(_feed);
        emit FeedSet(_feed, block.timestamp);
    }

    /**
     * @notice I let the owner change how much slippage is allowed in swaps
     * @param _newSlippage New tolerance in basis points (100 = 1%)
     * @dev Only the owner can do this. Maximum allowed is 1000 (10%)
     */
    function setSlippageTolerance(uint256 _newSlippage) 
        external 
        onlyOwner 
    {
        // No permito más del 10% porque sería muy arriesgado
        if (_newSlippage > 1000) revert InvalidSlippageTolerance(_newSlippage);
        
        uint256 oldSlippage = slippageTolerance;
        slippageTolerance = _newSlippage;
        
        emit SlippageToleranceUpdated(oldSlippage, _newSlippage);
    }
}

/*//////////////////////////////////////////////////////////////
                    UNISWAP V2 INTERFACES
//////////////////////////////////////////////////////////////*/

/// @notice This is the interface for Uniswap V2 Router
/// @dev I use it to do swaps and get price estimates
interface IUniswapV2Router02 {
    /// @notice Gives me the factory address
    function factory() external pure returns (address);
    
    /// @notice Gives me the WETH address
    function WETH() external pure returns (address);
    
    /// @notice Swaps an exact amount of one token for another
    /// @param amountIn Exactly how much I want to swap
    /// @param amountOutMin The minimum I'm willing to receive
    /// @param path The route for the swap [tokenIn, tokenOut] or [tokenIn, tokenMid, tokenOut]
    /// @param to Who gets the output tokens
    /// @param deadline Latest time the swap can happen
    /// @return amounts How much was swapped at each step
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /// @notice Tells me how much I'd get from a swap
    /// @param amountIn How much I'm putting in
    /// @param path The route I'm taking
    /// @return amounts Estimated amounts at each step
    function getAmountsOut(uint amountIn, address[] calldata path)
        external
        view
        returns (uint[] memory amounts);
}

/// @notice This is the interface for Uniswap V2 Factory
/// @dev I use it to check if liquidity pairs exist
interface IUniswapV2Factory {
    /// @notice Gets me the address of a pair between two tokens
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @return pair The pair address, or address(0) if it doesn't exist
    function getPair(address tokenA, address tokenB) 
        external 
        view 
        returns (address pair);
}
