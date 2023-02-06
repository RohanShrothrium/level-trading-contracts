// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {Pool, TokenWeight, Side} from "../src/pool/Pool.sol";
import {PoolAsset, PositionView, PoolLens} from "../src/pool/PoolLens.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ILPToken} from "../src/interfaces/ILPToken.sol";
import {PoolErrors} from "../src/pool/PoolErrors.sol";
import {LPToken} from "../src/tokens/LPToken.sol";
import {OrderManager, UpdatePositionType, OrderType} from "../src/orders/OrderManager.sol";
import {ETHUnwrapper} from "src/orders/ETHUnwrapper.sol";
import {PoolTestFixture} from "./Fixture.sol";
import {TransparentUpgradeableProxy as Proxy} from "openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin/proxy/transparent/ProxyAdmin.sol";

contract OrderManagerTest is PoolTestFixture {
    address tranche;
    OrderManager orders;
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() external {
        build();
        vm.startPrank(owner);
        tranche = address(new LPToken("LLP", "LLP", address(pool)));
        pool.addTranche(tranche);
        Pool.RiskConfig[] memory config = new Pool.RiskConfig[](1);
        config[0] = Pool.RiskConfig(tranche, 1000);
        pool.setRiskFactor(address(btc), config);
        pool.setRiskFactor(address(weth), config);
        OrderManager impl = new OrderManager();
        ProxyAdmin admin = new ProxyAdmin();
        Proxy proxy = new Proxy(address(impl), address(admin), bytes(""));
        ETHUnwrapper unwrapper = new ETHUnwrapper(address(weth));
        orders = OrderManager(payable(address(proxy)));
        orders.initialize(address(weth), address(oracle), 1 ether / 100, address(unwrapper));
        orders.setPool(address(pool));
        pool.setOrderManager(address(orders));
        pool.setPositionFee(0, 0);
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(weth), 1000e12);
        orders.setExecutor(alice);
        vm.stopPrank();
    }

    function _prepareLiquidity() internal {
        vm.startPrank(alice);
        btc.mint(10e8);
        usdc.mint(1_000_000e6);
        vm.deal(alice, 100e18);
        btc.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        // add some init liquidity
        router.addLiquidity(address(tranche), address(btc), 1e8, 0, alice);
        router.addLiquidityETH{value: 20e18}(address(tranche), 0, alice);
        router.addLiquidity(address(tranche), address(usdc), 40_000e6, 0, alice);
        vm.stopPrank();
    }

    function testPlaceOrder() external {
        _prepareLiquidity();
        vm.startPrank(alice);
        btc.approve(address(orders), type(uint256).max);
        vm.roll(1);
        uint256 balanceBefore = btc.balanceOf(alice);
        orders.placeOrder{value: 1e17}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            address(btc),
            address(btc),
            OrderType.MARKET,
            abi.encode(20_000e22, address(btc), 1e7, 2000e30, 1e7, bytes(""))
        );
        assertEq(btc.balanceOf(address(orders)), 1e7);
        vm.roll(2);
        orders.executeOrder(1, payable(bob));
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        console.log("Position", position.size, position.collateralValue);
        console.log("fee", lens.poolAssets(address(pool), address(btc)).feeReserve);

        uint256 deposited = balanceBefore - btc.balanceOf(alice);
        console.log("Deposited", deposited);
        assertEq(deposited, 1e7);

        orders.placeOrder{value: 1e16}(
            UpdatePositionType.DECREASE,
            Side.LONG,
            address(btc),
            address(btc),
            OrderType.MARKET,
            abi.encode(20_000e22, btc, 2000e30, 0, bytes(""))
        );
        console.log("decrease placed");
        vm.roll(3);
        balanceBefore = btc.balanceOf(alice);
        orders.executeOrder(2, payable(bob));
        uint256 received = btc.balanceOf(alice) - balanceBefore;
        console.log("received", received);
        console.log("fee", lens.poolAssets(address(pool), address(btc)).feeReserve);
        assertEq(received, 1e7);
        vm.stopPrank();
    }

    function testPlaceOrderETH() external {
        _prepareLiquidity();
        vm.startPrank(alice);
        vm.roll(1);
        uint256 balanceBefore = alice.balance;
        orders.placeOrder{value: 11e16}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            address(weth),
            address(weth),
            OrderType.MARKET,
            abi.encode(1_000e12, ETH, 1e17, 1000e30, 1e17, bytes(""))
        );
        assertEq(weth.balanceOf(address(orders)), 1e17);
        vm.roll(2);

        orders.executeOrder(1, payable(bob));
        PositionView memory position = lens.getPosition(address(pool), alice, address(weth), address(weth), Side.LONG);
        console.log("Position", position.size, position.collateralValue);
        console.log("fee", lens.poolAssets(address(pool), address(weth)).feeReserve);

        uint256 deposited = balanceBefore - alice.balance;
        console.log("Deposited", deposited);
        assertEq(deposited, 11e16);

        orders.placeOrder{value: 1e16}(
            UpdatePositionType.DECREASE,
            Side.LONG,
            address(weth),
            address(weth),
            OrderType.MARKET,
            abi.encode(1_000e12, ETH, 1000e30, 0, bytes(""))
        );
        console.log("decrease placed");
        vm.roll(3);
        balanceBefore = alice.balance;
        orders.executeOrder(2, payable(bob));
        uint256 received = alice.balance - balanceBefore;
        console.log("received", received);
        console.log("fee", lens.poolAssets(address(pool), address(weth)).feeReserve);
        assertEq(received, 1e17);
        vm.stopPrank();
    }

    function testSwapETH() external {
        _prepareLiquidity();
        vm.startPrank(alice);
        uint256 ethBefore = alice.balance;
        uint256 usdcBefore = usdc.balanceOf(alice);
        orders.swap{value: 1e16}(ETH, address(usdc), 1e16, 0);
        console.log("ETH in", ethBefore - alice.balance);
        console.log("USDC out", usdc.balanceOf(alice) - usdcBefore);

        ethBefore = alice.balance;
        usdc.approve(address(orders), 1e7);
        orders.swap(address(usdc), ETH, 1e7, 0);
        console.log("ETH out", alice.balance - ethBefore);
        vm.stopPrank();
    }
}
