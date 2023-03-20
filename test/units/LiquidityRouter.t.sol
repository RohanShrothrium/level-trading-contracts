// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {Pool} from "src/pool/Pool.sol";
import {ILPToken} from "src/interfaces/ILPToken.sol";
import {LPToken} from "src/tokens/LPToken.sol";
import {ETHUnwrapper} from "src/orders/ETHUnwrapper.sol";
import {PoolTestFixture} from "../Fixture.sol";

contract LiquidityRouterTest is PoolTestFixture {
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address tranche;

    function setUp() external {
        build();
        vm.startPrank(owner);
        tranche = address(new LPToken("LLP", "LLP", address(pool)));
        pool.addTranche(tranche);
        Pool.RiskConfig[] memory config = new Pool.RiskConfig[](1);
        config[0] = Pool.RiskConfig(tranche, 1000);
        pool.setRiskFactor(address(btc), config);
        pool.setRiskFactor(address(weth), config);
        ETHUnwrapper unwrapper = new ETHUnwrapper(address(weth));
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.stopPrank();
    }

    function test_add_liquidity() external {
        vm.startPrank(alice);
        btc.mint(10e8);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tranche), address(btc), 1e8, 0, alice);
        assertEq(btc.balanceOf(address(alice)), 9e8);
    }

    function test_add_liquidity_eth() external {
        vm.startPrank(alice);
        vm.deal(alice, 100e18);
        router.addLiquidityETH{value: 20e18}(address(tranche), 0, alice);
        assertEq(alice.balance, 80e18);
    }

    function test_remove_liquidity() external {
        vm.startPrank(alice);
        btc.mint(10e8);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tranche), address(btc), 1e8, 0, alice);
        assertEq(btc.balanceOf(address(alice)), 9e8);

        ILPToken(tranche).approve(address(router), type(uint256).max);
        router.removeLiquidity(tranche, address(btc), ILPToken(tranche).balanceOf(alice), 0, alice);
        assertEq(btc.balanceOf(address(alice)), 10e8);
    }

    function test_remove_liquidity_eth() external {
        vm.startPrank(alice);
        vm.deal(alice, 100e18);
        router.addLiquidityETH{value: 20e18}(address(tranche), 0, alice);
        assertEq(alice.balance, 80e18);

        ILPToken(tranche).approve(address(router), type(uint256).max);
        router.removeLiquidityETH(tranche, ILPToken(tranche).balanceOf(alice), 0, payable(alice));
        assertEq(alice.balance, 100e18);
    }
}
