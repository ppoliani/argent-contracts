pragma solidity ^0.5.4;
import "../../wallet/BaseWallet.sol";
import "../../exchange/ERC20.sol";
import "../../utils/SafeMath.sol";
import "../interfaces/SavingsAccount.sol";

interface UniswapFactory {
    function getExchange(address _token) external view returns(address);
}

/**
 * @title Uniswap
 * @dev Contract integrating with Uniswap.
 * @author Julien Niset - <julien@argent.im>
 */
contract Uniswap is SavingsAccount {

    address constant internal UNISWAP_FACTORY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant internal ETH_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    using SafeMath for uint256;

    function openSavingsAccount(BaseWallet _wallet, address[] calldata _tokens, uint256[] calldata _amounts, uint256 _period) external {
        require(_tokens.length == 2 && _amounts.length == 2, "Uniswap: You must invest a token pair.");
        if(_tokens[0] == ETH_TOKEN_ADDRESS) {
            addLiquidityToPool(_wallet, _tokens[1], _amounts[0], _amounts[1], true);
        }
        else {
            require(_tokens[1] == ETH_TOKEN_ADDRESS, "Uniswap: One token of the pair must be ETH");
            addLiquidityToPool(_wallet, _tokens[0], _amounts[1], _amounts[0], true);
        }
    }

    function closeSavingsAccount(BaseWallet _wallet, address[] calldata _tokens, uint256 _fraction) external {
        require(_tokens.length == 2, "Uniswap: You must invest a token pair.");
        require(_fraction <= 10000, "Uniswap: _fraction must be expressed in 1 per 10000");
        address token;
        if(_tokens[0] == ETH_TOKEN_ADDRESS) {
            token = _tokens[1];
        }
        else {
            require(_tokens[1] == ETH_TOKEN_ADDRESS, "Uniswap: One token of the pair must be ETH");
            token = _tokens[0];
        }
        address pool = UniswapFactory(UNISWAP_FACTORY).getExchange(token);
        uint256 shares = ERC20(pool).balanceOf(address(_wallet));
        removeLiquidityFromPool(_wallet, token, shares.mul(_fraction).div(10000));
    }

    function getSavingsAccount(BaseWallet _wallet, address _token) external view returns (uint256) {
        address pool = UniswapFactory(UNISWAP_FACTORY).getExchange(_token);
        return ERC20(pool).balanceOf(address(_wallet));
    }
 
    /**
     * @dev Adds liquidity to a Uniswap ETH-ERC20 pair.
     * @param _wallet The target wallet
     * @param _poolToken The address of the ERC20 token of the pair.
     * @param _ethAmount The amount of ETH available.
     * @param _tokenAmount The amount of ERC20 token available.
     */
    function addLiquidityToPool(
        BaseWallet _wallet, 
        address _poolToken, 
        uint256 _ethAmount, 
        uint256 _tokenAmount,
        bool _preventSwap
    )
        internal 
    {
        require(_ethAmount <= address(_wallet).balance, "Uniswap: not enough ETH");
        require(_tokenAmount <= ERC20(_poolToken).balanceOf(address(_wallet)), "Uniswap: not enough token");
        
        address pool = UniswapFactory(UNISWAP_FACTORY).getExchange(_poolToken);
        require(pool != address(0), "Uniswap: target token is not traded on Uniswap");

        uint256 ethPoolSize = address(pool).balance;
        uint256 tokenPoolSize = ERC20(_poolToken).balanceOf(pool);
        uint256 ethPool;
        uint256 tokenPool;

        if(_ethAmount >= _tokenAmount.mul(ethPoolSize).div(tokenPoolSize)) {
            if(_preventSwap) {
                tokenPool = _tokenAmount;
                ethPool = tokenPool.mul(ethPoolSize).div(tokenPoolSize);
            }
            else {
                // swap some eth for tokens
                uint256 ethSwap;
                (ethSwap, ethPool, tokenPool) = computePooledValue(ethPoolSize, tokenPoolSize, _ethAmount, _tokenAmount);
                if(ethSwap > 0) {
                    _wallet.invoke(pool, ethSwap, abi.encodeWithSignature("ethToTokenSwapInput(uint256,uint256)", 1, block.timestamp));
                }
            }
            _wallet.invoke(_poolToken, 0, abi.encodeWithSignature("approve(address,uint256)", pool, tokenPool));
        }
        else {
            if(_preventSwap) {
                ethPool = _ethAmount;
                tokenPool = _ethAmount.mul(tokenPoolSize).div(ethPoolSize);
                _wallet.invoke(_poolToken, 0, abi.encodeWithSignature("approve(address,uint256)", pool, tokenPool));
            }
            else {
                // swap some tokens for eth
                uint256 tokenSwap;
                (tokenSwap, tokenPool, ethPool) = computePooledValue(tokenPoolSize, ethPoolSize, _tokenAmount, _ethAmount);
                _wallet.invoke(_poolToken, 0, abi.encodeWithSignature("approve(address,uint256)", pool, tokenSwap + tokenPool));
                if(tokenSwap > 0) {
                    _wallet.invoke(pool, 0, abi.encodeWithSignature("tokenToEthSwapInput(uint256,uint256,uint256)", tokenSwap, 1, block.timestamp));
                }
            }   
        }
        // add liquidity
        _wallet.invoke(pool, ethPool - 1, abi.encodeWithSignature("addLiquidity(uint256,uint256,uint256)",1, tokenPool, block.timestamp + 1));
    }

    /**
     * @dev Removes liquidity from a Uniswap ETH-ERC20 pair.
     * @param _wallet The target wallet
     * @param _poolToken The address of the ERC20 token of the pair.
     * @param _amount The amount of pool shares to liquidate.
     */
    function removeLiquidityFromPool(    
        BaseWallet _wallet, 
        address _poolToken, 
        uint256 _amount
    )
        internal       
    {
        address pool = UniswapFactory(UNISWAP_FACTORY).getExchange(_poolToken);
        require(pool != address(0), "Uniswap: The target token is not traded on Uniswap");
        _wallet.invoke(pool, 0, abi.encodeWithSignature("removeLiquidity(uint256,uint256,uint256,uint256)",_amount, 1, 1, block.timestamp + 1));
    }

    /**
     * @dev Computes the amount of tokens to swap and then pool given an amount of "major" and "minor" tokens,
     * where there are more value of "major" tokens then "minor".
     * @param _majorPoolSize The size of the pool in major tokens
     * @param _minorPoolSize The size of the pool in minor tokens
     * @param _majorAmount The amount of major token provided
     * @param _minorAmount The amount of minor token provided
     * @return the amount of major tokens to first swap and the amount of major and minor tokens that can be added to the pool after.
     */
    function computePooledValue(
        uint256 _majorPoolSize,
        uint256 _minorPoolSize, 
        uint256 _majorAmount,
        uint256 _minorAmount
    ) 
        internal 
        view 
        returns(uint256 _majorSwap, uint256 _majorPool, uint256 _minorPool) 
    {
        uint256 _minorInMajor = _minorAmount.mul(_majorPoolSize).div(_minorPoolSize); 
        _majorSwap = (_majorAmount.sub(_minorInMajor)).mul(1000).div(1997);
        uint256 minorSwap = getInputToOutputPrice(_majorSwap, _majorPoolSize, _minorPoolSize);
        _majorPool = _majorAmount.sub(_majorSwap);
        _minorPool = _majorPool.mul(_minorPoolSize.sub(minorSwap)).div(_majorPoolSize.add(_majorSwap));
        uint256 minorPoolMax = _minorAmount.add(minorSwap);
        if(_minorPool > minorPoolMax) {
            _minorPool = minorPoolMax;
            _majorPool = (_minorPool).mul(_majorPoolSize.add(_majorSwap)).div(_minorPoolSize.sub(minorSwap));
        }
    }

    /**
     * @dev Computes the amount of output tokens that can be obtained by swapping the provided amoutn of input.
     * @param _inputAmount The amount of input token.
     * @param _inputPoolSize The size of the input pool.
     * @param _outputPoolSize The size of the output pool.
     */
    function getInputToOutputPrice(uint256 _inputAmount, uint256 _inputPoolSize, uint256 _outputPoolSize) internal view returns(uint256) {
        if(_inputAmount == 0) {
            return 0;
        }
        uint256 inputAfterFee = _inputAmount.mul(997);
        uint256 numerator = inputAfterFee.mul(_outputPoolSize);
        uint256 denominator = (_inputPoolSize.mul(1000)).add(inputAfterFee);
        return numerator.div(denominator);
    }
}