// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./uniswap_v2/v2-core/interfaces/IUniswapV2Callee.sol";
import "./uniswap_v2/v2-core/interfaces/IUniswapV2Pair.sol";
import "./uniswap_v2/v2-periphery/libraries/UniswapV2Library.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FlashSwapArbitrage is Ownable, IUniswapV2Callee {
    address factory_UNIV2;

    event ArbitrageConducted(
        address indexed factory_TargetDEX, address indexed earnedAsset, uint256 indexed earnedAmount, address pairedAsset
    );
    event FactoryUNIV2Changed(address previousAddr, address newAddr);

    constructor(address _factory_UNIV2) Ownable(msg.sender) {
        factory_UNIV2 = _factory_UNIV2;
    }

    receive() external payable {}

    /**
     * @notice When the price of a token of an external DEX is lower, this function will conduct the arbitrage to the advantage of the difference in token price
     *
     * @dev Assume that the inner-layer swap is also {swap} of another UniswapV2Pair contract(belongs to a quite different DEX which has forked UniswapV2).
     *
     * @param sender the actual operator conducting this flash swap
     * @param amount0Out the amount of token0 swapped out
     * @param amount1Out the amount of token1 swapped out
     * @param data the extra data contain necessary for the logic of this function
     */
    function uniswapV2Call(address sender, uint256 amount0Out, uint256 amount1Out, bytes memory data) external {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address[] memory path = new address[](2);
        
        // Guarantee that `msg.sender` is UniswapV2Pair contract which corresponding to `factory_UNIV2`
        require(msg.sender == UniswapV2Library.pairFor(factory_UNIV2, token0, token1), "Not valid UniswapV2Pair");
        require(amount0Out == 0 || amount1Out == 0, "Neither amountOut is zero");
        path[0] = amount0Out == 0 ? token0 : token1;
        path[1] = amount0Out == 0 ? token1 : token0;

        (address targetFactory, uint256 minArbitrage) = abi.decode(data, (address, uint256));
        address targetPair = UniswapV2Library.pairFor(targetFactory, token0, token1);

        uint256 amountIn_InnerSwap;

        if (amount0Out > 0) {
            amountIn_InnerSwap = amount0Out;
        } else {
            amountIn_InnerSwap = amount1Out;
        }

        // `amountIn_InnerSwap`(the asset swapped from the outer-layer swap) is totally invested into the inner-layer swap
        require(IERC20(path[1]).transfer(targetPair, amountIn_InnerSwap), "Fail to transfer token to inner-swap");

        (uint256 arbitrage, uint256 amountRequired_OuterSwap) = _executeInnerSwap(targetPair, targetFactory, path[1], amountIn_InnerSwap, minArbitrage, path);
            
        // Give back the required amount of `path[0]` back to the outer-swap(specifically, UniswapV2Pair of current DEX)
        require(IERC20(path[0]).transfer(msg.sender, amountRequired_OuterSwap), "Fail to return token to outer-swap");

        // The arbitrager(`sender`) keeps the rest of `path[0]`
        require(IERC20(path[0]).transfer(sender, arbitrage), "Fail to transfer arbitrage");
            
        // Emit event
        emit ArbitrageConducted(targetFactory, path[0], arbitrage, path[1]);
    }

    /**
     * @notice Conduct a flash-swap arbitrage
     *
     * @param _tokenA the address of one token in the trade pair
     * @param _tokenB the address of the other token in the trade pair
     * @param _amountAOut the amount of `_tokenA` swapped out
     * @param _amountBOut the amount of `_tokenB` swapped out
     * @param data the extra data contain necessary for the logic of this function
     */
    function arbitrageByFlashSwap(address _tokenA, address _tokenB, uint256 _amountAOut, uint256 _amountBOut, bytes memory data)
        public
        onlyOwner
    {
        // Input checks
        // Require that ether `_amountAOut` or `_amountBOut` is zero(one zero value and one non-zero value)
        require(_amountAOut * _amountBOut == 0 && _amountAOut != _amountBOut, "invalid amountOut");
        require(data.length > 0, "Empty data");

        // Get UniswapV2Pair contract address
        address pairAddr = UniswapV2Library.pairFor(factory_UNIV2, _tokenA, _tokenB);
        address token0 = IUniswapV2Pair(pairAddr).token0();

        // Match the swapped-out amount of token0 and token1
        uint256 amount0Out = _tokenA == token0 ? _amountAOut : _amountBOut;
        uint256 amount1Out = _tokenA == token0 ? _amountBOut : _amountAOut;

        // Execute {swap} function in the UniswapV2Pair contract
        IUniswapV2Pair(pairAddr).swap(amount0Out, amount1Out, address(this), data);
    }

    /**
	 * @notice The owner withdraws a specific amount of a specific token to a specific address.
     *
     * @param to the recipient address
     * @param tokenAddr the token address
     * @param amount the amount of the token transferred
	 */
    function withdrawArbitrage(address to, address tokenAddr, uint256 amount) external onlyOwner{
        // bytes4(keccak256(bytes('transfer(address,uint256)'))):
        (bool success, bytes memory data) = tokenAddr.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'Failed to transfer arbitrage');
    }

    /**
     * @notice Replace the factory address of the current DEX with a new one
     *
     * @param _newFactory_UNIV2 the new factory address
     */
    function updateFactory_UNIV2(address _newFactory_UNIV2) external onlyOwner {
        address previousAddr = factory_UNIV2;
        factory_UNIV2 = _newFactory_UNIV2;
        emit FactoryUNIV2Changed(previousAddr, _newFactory_UNIV2);
    }

    /**
     * @notice Get the swap-out amount of the last token in the path of the swap
     *
     * @param factory the address of the UniswapV2Factory contract
     * @param amountIn the amount of the token invested into this swap
     * @param path the array contains the address of the token in each step of the swap
     */
    function getLastAmountOut(address factory, uint256 amountIn, address[] memory path) public view returns (uint256) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path)[path.length - 1];
    }

    /**
     * @notice Get the swap-in amount of the first token in the path of the swap
     *
     * @param factory the address of the UniswapV2Factory contract
     * @param amountOut the expected amount of the token swapped out from the DEX
     * @param path the array contains the address of the token in each step of the swap
     */
    function getFirstAmountIn(address factory, uint256 amountOut, address[] memory path) public view returns (uint256) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path)[0];
    }

    /**
     * @dev Execute the inner-swap
     *
     * @param pair_Inner the address of the UniswapV2Pair of the external DEX which is used in the inner-swap
     * @param factory_Inner the address of the UniswapFactory of the external DEX which is used in the inner-swap
     * @param tokenIn_Inner the address of the token invested in the inner-swap
     * @param amountIn_Inner the amount of the token invested in the inner-swap
     * @param minArbitrage the minimum of the arbitrage
     * @param path the array contains the address of the token in each step of the outer-swap corresponding to this inner-swap
     * 
     * @return arbitrage the amount of the arbitrage finally earned
     * @return amountRequired_OuterSwap the amount of the token required to be invested into the outer-swap
     */
    function _executeInnerSwap(address pair_Inner, address factory_Inner, address tokenIn_Inner, uint256 amountIn_Inner, uint256 minArbitrage, address[] memory path) internal returns (uint256, uint256) {
        address tokenOut_Inner;
        bool isTokenOutEqualToToken0;
        // Get the address of the paired token in the inner swap
        if (tokenIn_Inner == IUniswapV2Pair(pair_Inner).token0()) {
            tokenOut_Inner = IUniswapV2Pair(pair_Inner).token1();
        } else {
            tokenOut_Inner = IUniswapV2Pair(pair_Inner).token0();
            isTokenOutEqualToToken0 = true;
        }

        // Declare the variables of the inner-swap(reverse of the direction of the path of the outer-layer swap)
        address[] memory path_InnerSwap = new address[](2);
        path_InnerSwap[0] = tokenIn_Inner;
        path_InnerSwap[1] = tokenOut_Inner;

        // Before the inner-swap starts, record the current `tokenOut_Inner` balance of `address(this)`
        uint256 balanceBefore = IERC20(tokenOut_Inner).balanceOf(address(this));

        // Conduct the inner-swap
        if (isTokenOutEqualToToken0) {
            IUniswapV2Pair(pair_Inner).swap(getLastAmountOut(factory_Inner, amountIn_Inner, path_InnerSwap), 0, address(this), new bytes(0));
        } else {
            IUniswapV2Pair(pair_Inner).swap(0, getLastAmountOut(factory_Inner, amountIn_Inner, path_InnerSwap), address(this), new bytes(0));
        }

        // Get the amount of `tokenOut_Inner` that `address(this)` has actually received
        uint256 amountReceived_InnerSwap = IERC20(tokenOut_Inner).balanceOf(address(this)) - balanceBefore;

        // Calculate the required amount of `tokenOut_Inner` which should be invested into the outer-swap
        uint256 amountRequired_OuterSwap = getFirstAmountIn(factory_UNIV2, amountIn_Inner, path);

        // Check if slippage is too big
        require(amountReceived_InnerSwap > amountRequired_OuterSwap, "Slippage is too big");

        // Get the amount of arbitrage
        uint256 arbitrage = amountReceived_InnerSwap - amountRequired_OuterSwap;

        // Check if there is enough arbitrage
        require(arbitrage > minArbitrage, "Insufficient arbitrage");

        return (arbitrage, amountRequired_OuterSwap);
    }
}
