// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {Pool, TokenWeight, Side} from "../src/pool/Pool.sol";
import {PoolAsset, PositionView, PoolLens} from "src/pool/PoolLens.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ILPToken} from "../src/interfaces/ILPToken.sol";
import {PoolErrors} from "../src/pool/PoolErrors.sol";
import {LPToken} from "../src/tokens/LPToken.sol";
import {PoolTestFixture} from "./Fixture.sol";

contract PoolAmountFuzzTest is PoolTestFixture {
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
        vm.stopPrank();
        vm.startPrank(owner);
        pool.setPositionFee(1e7, 0);
        pool.setInterestRate(1e5, 1);
        pool.setDaoFee(2e9);
        vm.stopPrank();
    }

    function _beforeTestPosition() internal {
        vm.prank(owner);
        pool.setOrderManager(orderManager);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.startPrank(alice);
        btc.mint(10e8);
        usdc.mint(1_000_000e6);
        vm.deal(alice, 100e18);
        weth.deposit{value: 100e18}();
        usdc.approve(address(router), type(uint256).max);
        btc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 1_000_000e6, 0, alice);
        router.addLiquidity(tranche, address(btc), 10e8, 0, alice);
        router.addLiquidity(tranche, address(weth), 10e18, 0, alice);
        vm.stopPrank();
    }

    function testFuzzLongFee(uint256 collateralAmount, int256 priceChange) external {
        uint256 leverage = 10;
        vm.assume(collateralAmount > 0 && priceChange != 0 && collateralAmount < 1e8);
        vm.assume(priceChange < 5 && priceChange > -5);

        _beforeTestPosition();
        uint256 entryPrice = 20_000e22;
        oracle.setPrice(address(btc), entryPrice);

        uint256 size = collateralAmount * entryPrice * leverage;

        // increase position
        vm.startPrank(orderManager);
        btc.mint(collateralAmount);
        btc.transfer(address(pool), collateralAmount); // 0.01BTC
        pool.increasePosition(alice, address(btc), address(btc), size, Side.LONG);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "open: pool_amount + fee_reserve = pool_balance"
            );
        }

        uint256 markPrice = priceChange > 0
            ? entryPrice * (100 + uint256(priceChange)) / 100
            : entryPrice * (100 - uint256(-priceChange)) / 100;

        oracle.setPrice(address(btc), markPrice);
        // close full
        pool.decreasePosition(alice, address(btc), address(btc), type(uint256).max, type(uint256).max, Side.LONG, alice);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "close: pool_amount + fee_reserve = pool_balance"
            );
        }
    }

    function testFuzzShortFee(uint256 collateralAmount, int256 priceChange) external {
        uint256 leverage = 10;
        vm.assume(collateralAmount > 1e6 && priceChange != 0 && collateralAmount < 100_000e6);
        vm.assume(priceChange < 5 && priceChange > -5);

        _beforeTestPosition();
        uint256 entryPrice = 20_000e22;
        oracle.setPrice(address(btc), entryPrice);

        uint256 size = collateralAmount * 1e24 * leverage;

        // increase position
        vm.startPrank(orderManager);
        usdc.mint(collateralAmount);
        usdc.transfer(address(pool), collateralAmount); // 0.01BTC
        uint256 initPoolAmount;
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            initPoolAmount = asset.poolAmount;
        }
        pool.increasePosition(alice, address(btc), address(usdc), size, Side.SHORT);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            assertApproxEqAbs(
                asset.poolAmount,
                initPoolAmount + size * 1e7 * (1e10 - 2e9) / 1e10 / 1e24 / 1e10,
                5,
                "open: pool_amount += fee"
            );
        }

        uint256 markPrice = priceChange > 0
            ? entryPrice * (100 + uint256(priceChange)) / 100
            : entryPrice * (100 - uint256(-priceChange)) / 100;

        oracle.setPrice(address(btc), markPrice);
        // close full
        pool.decreasePosition(
            alice, address(btc), address(usdc), type(uint256).max, type(uint256).max, Side.SHORT, alice
        );
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                5,
                "close: pool_amount + fee_reserve = pool_balance"
            );
        }
    }
}
