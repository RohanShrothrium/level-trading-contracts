// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {Pool, Side} from "src/pool/Pool.sol";
import {PoolAsset, PositionView} from "src/lens/PoolLens.sol";
import {ILPToken} from "src/interfaces/ILPToken.sol";
import {PoolErrors} from "src/pool/PoolErrors.sol";
import {LPToken} from "src/tokens/LPToken.sol";
import {IPool} from "src/interfaces/IPool.sol";
import {OrderManager, UpdatePositionType, OrderType} from "src/orders/OrderManager.sol";
import {ETHUnwrapper} from "src/orders/ETHUnwrapper.sol";
import {PoolTestFixture} from "test/Fixture.sol";
import {TransparentUpgradeableProxy as Proxy} from "openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin/proxy/transparent/ProxyAdmin.sol";

contract OrderManagerTest is PoolTestFixture {
    address tranche;
    OrderManager orders;
    ETHUnwrapper unwrapper;
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
        unwrapper = new ETHUnwrapper(address(weth));
        orders = OrderManager(payable(address(proxy)));
        pool.setOrderManager(address(orders));
        pool.setPositionFee(0, 0);
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(weth), 1000e12);
        vm.stopPrank();
    }

    function init() internal {
        vm.startPrank(owner);
        orders.initialize(address(weth), address(oracle), 0, address(unwrapper));
        orders.setMinExecutionFee(0.01 ether, 0.01 ether);
        orders.setExecutor(alice);
        vm.stopPrank();
    }

    function addLiquidity() internal {
        vm.startPrank(owner);
        orders.setPool(address(pool));
        vm.stopPrank();

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

    function test_initialize() external {
        vm.startPrank(owner);
        vm.expectRevert("OrderManager:invalidWeth");
        orders.initialize(address(0), address(oracle), 1 ether / 100, address(unwrapper));
        vm.expectRevert("OrderManager:invalidOracle");
        orders.initialize(address(weth), address(0), 1 ether / 100, address(unwrapper));
        vm.expectRevert("OrderManager:minExecutionFeeTooHigh");
        orders.initialize(address(weth), address(oracle), 1 ether, address(unwrapper));
        vm.expectRevert("OrderManager:invalidEthUnwrapper");
        orders.initialize(address(weth), address(oracle), 1 ether / 100, address(0));
        orders.initialize(address(weth), address(oracle), 1 ether / 100, address(unwrapper));
        vm.stopPrank();
    }

    function test_place_order() external {
        init();
        addLiquidity();
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
        vm.expectRevert("OrderManager:invalidTokens");
        orders.placeOrder{value: 1e17}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            address(0),
            address(0),
            OrderType.MARKET,
            abi.encode(20_000e22, address(btc), 1e7, 2000e30, 1e7, bytes(""))
        );
        vm.expectRevert("OrderManager:invalidPurchaseAmount");
        orders.placeOrder{value: 1e17}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            address(btc),
            address(btc),
            OrderType.MARKET,
            abi.encode(20_000e22, address(0), 0, 2000e30, 1e7, bytes(""))
        );
        vm.expectRevert("OrderManager:invalidPurchaseToken");
        orders.placeOrder{value: 1e17}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            address(btc),
            address(btc),
            OrderType.MARKET,
            abi.encode(20_000e22, address(0), 1e7, 2000e30, 1e7, bytes(""))
        );
        (uint256[] memory orderIds, uint256 total) = orders.getOrders(alice, 0, 5);
        assertEq(total, 1);
        assertEq(btc.balanceOf(address(orders)), 1e7);
        vm.roll(2);
        orders.executeOrder(1, payable(bob));
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        //console.log("Position", position.size, position.collateralValue);
        //console.log("fee", lens.poolAssets(address(pool), address(btc)).feeReserve);

        uint256 deposited = balanceBefore - btc.balanceOf(alice);
        //console.log("Deposited", deposited);
        assertEq(deposited, 1e7);

        orders.placeOrder{value: 1e16}(
            UpdatePositionType.DECREASE,
            Side.LONG,
            address(btc),
            address(btc),
            OrderType.MARKET,
            abi.encode(20_000e22, btc, 2000e30, 0, bytes(""))
        );
        //console.log("decrease placed");
        vm.roll(3);
        balanceBefore = btc.balanceOf(alice);
        orders.executeOrder(2, payable(bob));
        uint256 received = btc.balanceOf(alice) - balanceBefore;
        //console.log("received", received);
        //console.log("fee", lens.poolAssets(address(pool), address(btc)).feeReserve);
        assertEq(received, 1e7);
        vm.stopPrank();
    }

    function test_place_order_eth() external {
        init();
        addLiquidity();
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
        //console.log("Position", position.size, position.collateralValue);
        //console.log("fee", lens.poolAssets(address(pool), address(weth)).feeReserve);

        uint256 deposited = balanceBefore - alice.balance;
        //console.log("Deposited", deposited);
        assertEq(deposited, 11e16);

        orders.placeOrder{value: 1e16}(
            UpdatePositionType.DECREASE,
            Side.LONG,
            address(weth),
            address(weth),
            OrderType.MARKET,
            abi.encode(1_000e12, ETH, 1000e30, 0, bytes(""))
        );
        //console.log("decrease placed");
        vm.roll(3);
        balanceBefore = alice.balance;
        orders.executeOrder(2, payable(bob));
        uint256 received = alice.balance - balanceBefore;
        //console.log("received", received);
        //console.log("fee", lens.poolAssets(address(pool), address(weth)).feeReserve);
        assertEq(received, 1e17);
        vm.stopPrank();
    }

    function test_swap_eth() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        uint256 ethBefore = alice.balance;
        uint256 usdcBefore = usdc.balanceOf(alice);
        orders.swap{value: 1e16}(ETH, address(usdc), 1e16, 0);
        //console.log("ETH in", ethBefore - alice.balance);
        //console.log("USDC out", usdc.balanceOf(alice) - usdcBefore);

        ethBefore = alice.balance;
        usdc.approve(address(orders), 1e7);
        orders.swap(address(usdc), ETH, 1e7, 0);
        //console.log("ETH out", alice.balance - ethBefore);
        vm.stopPrank();
    }

    function test_cancel_order() external {
        init();
        addLiquidity();
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
        assertEq(btc.balanceOf(address(alice)), balanceBefore - 1e7);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("OrderManager:unauthorizedCancellation");
        orders.cancelOrder(1);
        vm.stopPrank();

        vm.startPrank(alice);
        orders.cancelOrder(1);
        assertEq(btc.balanceOf(address(alice)), balanceBefore);
        assertEq(btc.balanceOf(address(orders)), 0);
    }

    function test_expire_order() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        btc.approve(address(orders), type(uint256).max);
        vm.roll(1);
        uint256 balanceBefore = btc.balanceOf(alice);
        vm.warp(0);
        orders.placeOrder{value: 1e17}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            address(btc),
            address(btc),
            OrderType.MARKET,
            abi.encode(20_000e22, address(btc), 1e7, 2000e30, 1e7, bytes(""))
        );
        assertEq(btc.balanceOf(address(orders)), 1e7);
        vm.expectRevert("OrderManager:blockNotPass");
        orders.executeOrder(1, payable(alice));
        vm.roll(2);
        assertEq(btc.balanceOf(address(alice)), balanceBefore - 1e7);

        vm.warp(10 days);
        vm.expectRevert("OrderManager:orderNotExists");
        orders.executeOrder(0, payable(alice));

        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert("OrderManager:onlyOwnerOrExecutor");
        orders.executeOrder(1, payable(bob));
        vm.stopPrank();
        vm.startPrank(alice);
        orders.executeOrder(1, payable(alice));
    }

    function test_owner_can_execute() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        btc.approve(address(orders), type(uint256).max);
        vm.roll(1);
        uint256 balanceBefore = btc.balanceOf(alice);
        vm.warp(0);
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
        assertEq(btc.balanceOf(address(alice)), balanceBefore - 1e7);

        vm.stopPrank();
        vm.startPrank(alice);
        orders.executeOrder(1, payable(alice));
    }

    function test_place_swap_order() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        btc.approve(address(orders), type(uint256).max);
        vm.expectRevert("OrderManager:executionFeeTooLow");
        orders.placeSwapOrder(address(btc), address(usdc), 1e7, 0, 20_000e22);
        vm.expectRevert("OrderManager:invalidTokens");
        orders.placeSwapOrder{value: 1e17}(address(0), address(usdc), 1e7, 0, 20_000e22);
        orders.placeSwapOrder{value: 1e17}(address(btc), address(usdc), 1e7, 0, 20_000e22);
        orders.placeSwapOrder{value: 1e17}(ETH, address(usdc), 1e7, 0, 1_600e22);
        (uint256[] memory orderIds, uint256 total) = orders.getSwapOrders(alice, 0, 5);
        assertEq(total, 2);
    }

    function test_execute_swap_order() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        uint256 balanceBefore = btc.balanceOf(alice);
        btc.approve(address(orders), type(uint256).max);
        orders.placeSwapOrder{value: 1e17}(address(btc), address(usdc), 1e7, 0, 20_000e22);

        orders.executeSwapOrder(1, payable(alice));
        assertEq(btc.balanceOf(address(orders)), 0);
    }

    function test_execute_swap_eth_order() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        uint256 balanceBefore = btc.balanceOf(alice);
        btc.approve(address(orders), type(uint256).max);
        orders.placeSwapOrder{value: 1e17}(address(btc), ETH, 1e7, 0, 20_000e22);

        orders.executeSwapOrder(1, payable(alice));
        assertEq(btc.balanceOf(address(orders)), 0);
    }

    function test_cancel_swap_order() external {
        init();
        addLiquidity();
        vm.startPrank(alice);
        uint256 balanceBefore = btc.balanceOf(alice);
        btc.approve(address(orders), type(uint256).max);
        orders.placeSwapOrder{value: 1e17}(address(btc), address(usdc), 1e7, 0, 20_000e22);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("OrderManager:unauthorizedCancellation");
        orders.cancelSwapOrder(1);
        vm.stopPrank();

        vm.startPrank(alice);
        orders.cancelSwapOrder(1);
        assertEq(btc.balanceOf(address(alice)), balanceBefore);
    }

    function test_set_oracle() external {
        init();
        vm.startPrank(owner);
        vm.expectRevert("OrderManager:invalidOracleAddress");
        orders.setOracle(address(0));
        orders.setOracle(address(oracle));
    }

    function test_set_pool() external {
        init();
        vm.startPrank(owner);
        vm.expectRevert("OrderManager:invalidPoolAddress");
        orders.setPool(address(0));
        orders.setPool(address(pool));
        vm.expectRevert("OrderManager:poolAlreadyAdded");
        orders.setPool(address(pool));
    }

    function test_set_order_hook() external {
        init();
        vm.startPrank(owner);
        orders.setOrderHook(address(0));
    }

    function test_set_executor() external {
        init();
        vm.startPrank(owner);
        vm.expectRevert("OrderManager:invalidAddress");
        orders.setExecutor(address(0));
        orders.setExecutor(alice);
    }

    function test_set_min_execution_fee() external {
        init();
        vm.startPrank(owner);
        vm.expectRevert("OrderManager:invalidFeeValue");
        orders.setMinExecutionFee(0, 0);
        vm.expectRevert("OrderManager:minExecutionFeeTooHigh");
        orders.setMinExecutionFee(1e18, 1e18);
        orders.setMinExecutionFee(1e7, 1e7);
    }

    function test_upgrade_version() external {
        init();
        vm.startPrank(owner);
        orders.reinit(address(oracle), alice);
    }

    function test_reinit_should_revert() external {
        vm.startPrank(owner);
        orders.initialize(address(weth), address(oracle), 1 ether / 100, address(unwrapper));
        vm.expectRevert();
        orders.initialize(address(weth), address(oracle), 1 ether / 100, address(unwrapper));
    }
}
