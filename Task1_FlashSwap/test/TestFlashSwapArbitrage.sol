// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "../src/FlashSwapArbitrage.sol";
import {UniswapV2Router02} from "../src/uniswap_v2/v2-periphery/UniswapV2Router02.sol";
import "../src/uniswap_v2/v2-periphery/WETH9.sol";
import {UniswapV2Factory} from "../src/uniswap_v2/v2-core/UniswapV2Factory.sol";
import {UniswapV2Pair} from "../src/uniswap_v2/v2-core/UniswapV2Pair.sol";
import {DAIToken} from "../src/DAIToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestFlashSwapArbitrage is Test {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    WETH9 public wethContract;
    UniswapV2Factory public factory_Outer;
    UniswapV2Factory public factory_Inner;
    UniswapV2Router02 public router_Outer;
    UniswapV2Router02 public router_Inner;
    DAIToken public DAITContract;
    FlashSwapArbitrage public entryContract;

    address public wethAddr;
    address public factoryAddr_Outer;
    address public factoryAddr_Inner;
    address public routerAddr_Outer;
    address public routerAddr_Inner;
    address public DAITAddr;
    address public entryAddr;

    

    function setUp() public {
        vm.startPrank(alice);
        // initialization: deploying contracts
        wethContract = new WETH9();
        wethAddr = address(wethContract);
        factory_Outer = new UniswapV2Factory(alice);
        factoryAddr_Outer = address(factory_Outer);
        factory_Inner = new UniswapV2Factory(alice);
        factoryAddr_Inner = address(factory_Inner);
        router_Outer = new UniswapV2Router02(factoryAddr_Outer, wethAddr);
        routerAddr_Outer = address(router_Outer);
        router_Inner = new UniswapV2Router02(factoryAddr_Inner, wethAddr);
        routerAddr_Inner = address(router_Inner);
        DAITContract = new DAIToken();
        DAITAddr = address(DAITContract);
        entryContract = new FlashSwapArbitrage(factoryAddr_Outer);
        entryAddr = address(entryContract);
        
        // ETH balance assignment
        deal(alice, 200000 ether);

        // Token mint
        DAITContract.mint(alice, 200000 ether);

        // The current DEX pool initialization for outer-swap
        DAITContract.approve(routerAddr_Outer, 100000 ether);
        router_Outer.addLiquidityETH{value: 100000 ether}(DAITAddr, 80000 ether, 1, 1, alice, block.timestamp + 300);
        
        // The external DEX pool initialization for inter-swap
        DAITContract.approve(routerAddr_Inner, 100000 ether);
        router_Inner.addLiquidityETH{value: 100000 ether}(DAITAddr, 90000 ether, 1, 1, alice, block.timestamp + 300);

        vm.stopPrank();
    }

    function test_ArbitrageByFlashSwap() public {
        vm.startPrank(alice);
        address targetFactory = factoryAddr_Inner;
        uint256 minArbitrage = 1;
        bytes memory data = abi.encode(targetFactory, minArbitrage);

        entryContract.arbitrageByFlashSwap(DAITAddr, wethAddr, 0, 3000 ether, data);
        uint256 balanceOfEntry = DAITContract.balanceOf(entryAddr);
        entryContract.withdrawArbitrage(bob, DAITAddr, balanceOfEntry);
        uint256 BalanceOfBob_DAIT = DAITContract.balanceOf(bob);
        console.log("BalanceOfBob_DAIT: ", BalanceOfBob_DAIT);
        vm.stopPrank();
        assertTrue(BalanceOfBob_DAIT > 0);
    }

}
