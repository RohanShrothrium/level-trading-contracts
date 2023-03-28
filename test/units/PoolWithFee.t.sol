pragma solidity 0.8.15;

import "forge-std/console.sol";
import {PoolTestFixture, SWAP_FEE, ADD_REMOVE_FEE, POSITION_FEE, PRECISION, DAO_FEE, ETH} from "test/Fixture.sol";
import {LPToken} from "src/tokens/LPToken.sol";
import {AssetInfo} from "src/pool/PoolStorage.sol";
import {PoolAsset, PositionView, PoolLens} from "src/lens/PoolLens.sol";
import {MathUtils} from "src/lib/MathUtils.sol";
import {Side} from "src/interfaces/IPool.sol";
import {Pool, TokenWeight} from "src/pool/Pool.sol";
import {SafeERC20, IERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract PoolWithFee is PoolTestFixture {
    using SafeERC20 for IERC20;

    LPToken tranche_70;
    LPToken tranche_20;
    LPToken tranche_10;

    uint256 constant LP_INITIAL_PRICE = 1e12; // fix to 1$

    function setUp() external {
        build();
        vm.startPrank(owner);

        //Set fee
        pool.setSwapFee(SWAP_FEE, 0, SWAP_FEE, 0);
        pool.setAddRemoveLiquidityFee(ADD_REMOVE_FEE);
        pool.setDaoFee(DAO_FEE);

        //Deploy tranche
        tranche_70 = new LPToken("LP70", "LP70", address(pool));
        tranche_20 = new LPToken("LP20", "LP20", address(pool));
        tranche_10 = new LPToken("LP10", "LP10", address(pool));

        //Add tranche to pool
        pool.addTranche(address(tranche_70));
        pool.addTranche(address(tranche_20));
        pool.addTranche(address(tranche_10));

        Pool.RiskConfig[] memory riskConfig = new Pool.RiskConfig[](3);

        riskConfig[0] = Pool.RiskConfig(address(tranche_70), 70);
        riskConfig[1] = Pool.RiskConfig(address(tranche_20), 20);
        riskConfig[2] = Pool.RiskConfig(address(tranche_10), 10);

        pool.setRiskFactor(address(btc), riskConfig);
        pool.setRiskFactor(address(weth), riskConfig);

        vm.stopPrank();

        vm.startPrank(alice);

        // Min token
        btc.mint(100000e8); // 100.000 BTC
        usdc.mint(100000e6); // 100.000 USDC
        vm.deal(alice, 100000e18); // 100.000 ETH

        // Approve
        btc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        vm.stopPrank();

        vm.startPrank(bob);
        btc.mint(100000e8); // 100.000 BTC
        usdc.mint(100000e6); // 100.000 USDC
        vm.deal(alice, 100000e18); // 100.000 ETH

        // Approve
        btc.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);

        vm.stopPrank();

        vm.startPrank(eve);
        btc.mint(100000e8); // 100.000 BTC
        usdc.mint(100000e6); // 100.000 USDC
        vm.deal(alice, 100000e18); // 100.000 ETH

        vm.stopPrank();
    }

    // =============== INTERNAL FUNCTIONS ===============

    function initFund() internal {
        vm.startPrank(bob);
        pool.addLiquidity(address(tranche_70), address(btc), 100e8, 0, alice);
        pool.addLiquidity(address(tranche_20), address(btc), 100e8, 0, alice);
        pool.addLiquidity(address(tranche_10), address(btc), 100e8, 0, alice);
        pool.addLiquidity(address(tranche_70), address(usdc), 30000e6, 0, alice);
        pool.addLiquidity(address(tranche_20), address(usdc), 30000e6, 0, alice);
        pool.addLiquidity(address(tranche_10), address(usdc), 30000e6, 0, alice);
        vm.stopPrank();
    }

    // =============== TRADING WITH FEE ===============

    /**
     * title: BTC $20k, Bob add 200 BTC to 3 tranche and Alice long BTC 10x.
     * expect: Not revert.
     * recommend: No.
     *
     */
    function test_open_long_position() external {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);

        initFund();

        vm.prank(bob);
        btc.transfer(address(pool), 1e8);

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(btc));

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(btc), 1e8 * 20_000e22 * 10, Side.LONG);

        (uint256 afterFeeReserve, uint256 afterPoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory afterPoolAsset = pool.getPoolAsset(address(btc));
        uint256 fee = 1e8 * 10 * POSITION_FEE / PRECISION;

        assertEq(beforePoolBalance + 1e8, afterPoolBalance);
        assertEq(beforeFeeReserve + (fee * DAO_FEE / PRECISION), afterFeeReserve);
        assertEq(afterPoolBalance, afterPoolAsset.poolAmount + afterFeeReserve);
    }

    /**
     * title: Bob add 200 BTC to 3 tranche and Alice long BTC 10x at $20k and close at $22k.
     * expect: Not revert.
     * recommend: No.
     *
     */
    function test_close_long_position() external {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);

        initFund();

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(btc));

        vm.prank(bob);
        btc.transfer(address(pool), 1e8);

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(btc), 1e8 * 20_000e22 * 10, Side.LONG);

        (uint256 afterFeeReserve, uint256 afterPoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory afterPoolAsset = pool.getPoolAsset(address(btc));
        uint256 increaseFee = 1e8 * 10 * POSITION_FEE / PRECISION;

        assertEq(beforePoolBalance + 1e8, afterPoolBalance);
        assertEq(beforeFeeReserve + (increaseFee * DAO_FEE / PRECISION), afterFeeReserve);
        assertEq(afterPoolBalance, afterPoolAsset.poolAmount + afterFeeReserve);

        vm.prank(orderManager);
        pool.decreasePosition(bob, address(btc), address(btc), type(uint256).max, type(uint256).max, Side.LONG, alice);

        (uint256 afterDecreaseFeeReserve, uint256 afterDecreasePoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory afterDecreasePoolAsset = pool.getPoolAsset(address(btc));
        uint256 decreaseFee = 1e8 * 10 * POSITION_FEE / PRECISION;

        assertEq(decreaseFee * DAO_FEE / PRECISION, afterDecreaseFeeReserve - afterFeeReserve);
        assertEq(
            afterDecreaseFeeReserve,
            (beforeFeeReserve + (increaseFee * DAO_FEE / PRECISION) + (decreaseFee * DAO_FEE / PRECISION))
        );
        assertEq(afterDecreasePoolBalance, afterDecreasePoolAsset.poolAmount + afterDecreaseFeeReserve);
    }

    /**
     * title: BTC $20k, Bob add 200 BTC to 3 tranche and Alice short BTC 10x.
     * expect: Not revert.
     * recommend: No.
     *
     */
    function test_open_short_position() external {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);

        initFund();

        vm.prank(bob);
        uint256 collateralAmount = 2_000e6;
        usdc.transfer(address(pool), collateralAmount);

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(usdc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(usdc));

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(usdc), collateralAmount * 1e24 * 10, Side.SHORT);

        (uint256 afterFeeReserve, uint256 afterPoolBalance,,,) = pool.poolTokens(address(usdc));
        AssetInfo memory afterPoolAsset = pool.getPoolAsset(address(usdc));
        uint256 fee = collateralAmount * 10 * POSITION_FEE / PRECISION;

        assertEq(beforePoolBalance + collateralAmount, afterPoolBalance);
        assertEq(beforeFeeReserve + (fee * DAO_FEE / PRECISION), afterFeeReserve);
        assertEq(afterPoolBalance, afterPoolAsset.poolAmount + (afterFeeReserve) + (collateralAmount - fee)); // fee include collateralAmount
    }

    /**
     * title: Bob add 200 BTC to 3 tranche and Alice short BTC 10x at $20k and close at $18k.
     * expect: Not revert.
     * recommend: No.
     *
     */
    function test_close_short_position() external {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);

        initFund();

        vm.prank(bob);
        uint256 collateralAmount = 2_000e6;
        usdc.transfer(address(pool), collateralAmount);

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(usdc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(usdc));

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(usdc), collateralAmount * 1e24 * 10, Side.SHORT);

        (uint256 afterFeeReserve, uint256 afterPoolBalance,,,) = pool.poolTokens(address(usdc));
        AssetInfo memory afterPoolAsset = pool.getPoolAsset(address(usdc));
        uint256 fee = collateralAmount * 10 * POSITION_FEE / PRECISION;

        assertEq(beforePoolBalance + collateralAmount, afterPoolBalance);
        assertEq(beforeFeeReserve + (fee * DAO_FEE / PRECISION), afterFeeReserve);
        assertEq(afterPoolBalance, afterPoolAsset.poolAmount + (afterFeeReserve) + (collateralAmount - fee)); // fee include collateralAmount
    }

    /**
     * title: BTC $20k, Bob add 200 BTC to 3 tranche and Alice long and short BTC 10x.
     * expect: Not revert.
     * recommend: No.
     *
     */
    function test_open_long_and_short_position() external {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);

        initFund();

        (uint256 beforeBtcFeeReserve, uint256 beforeBtcPoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory beforeBtcPoolAsset = pool.getPoolAsset(address(btc));

        (uint256 beforeUsdcFeeReserve, uint256 beforeUsdcPoolBalance,,,) = pool.poolTokens(address(usdc));
        AssetInfo memory beforeUsdcPoolAsset = pool.getPoolAsset(address(usdc));

        vm.prank(bob);
        btc.transfer(address(pool), 1e8);

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(btc), 1e8 * 20_000e22 * 10, Side.LONG);

        vm.prank(bob);
        usdc.transfer(address(pool), 2_000e6);

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(usdc), 2_000e6 * 1e24 * 10, Side.SHORT);

        uint256 longFee = 0;
        uint256 shortFee = 0;

        {
            (uint256 afterBtcFeeReserve, uint256 afterBtcPoolBalance,,,) = pool.poolTokens(address(btc));
            AssetInfo memory afterBtcPoolAsset = pool.getPoolAsset(address(btc));
            longFee = 1e8 * 10 * POSITION_FEE / PRECISION;

            assertEq(beforeBtcPoolBalance + 1e8, afterBtcPoolBalance);
            assertEq(beforeBtcFeeReserve + (longFee * DAO_FEE / PRECISION), afterBtcFeeReserve);
            assertEq(afterBtcPoolBalance, afterBtcPoolAsset.poolAmount + afterBtcFeeReserve);
        }

        {
            (uint256 afterUsdcFeeReserve, uint256 afterUsdcPoolBalance,,,) = pool.poolTokens(address(usdc));
            AssetInfo memory afterUsdcPoolAsset = pool.getPoolAsset(address(usdc));
            shortFee = 2_000e6 * 10 * POSITION_FEE / PRECISION;

            assertEq(beforeUsdcPoolBalance + 2_000e6, afterUsdcPoolBalance);
            assertEq(beforeUsdcFeeReserve + (shortFee * DAO_FEE / PRECISION), afterUsdcFeeReserve);
            assertEq(afterUsdcPoolBalance, afterUsdcPoolAsset.poolAmount + (afterUsdcFeeReserve) + (2_000e6 - shortFee)); // fee include collateralAmount
        }
    }

    function test_set_max_global_short_size() public {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);

        vm.startPrank(bob);
        btc.mint(30e8);
        pool.addLiquidity(address(tranche_70), address(usdc), 30000e6, 0, alice);
        pool.addLiquidity(address(tranche_20), address(usdc), 30000e6, 0, alice);
        pool.addLiquidity(address(tranche_10), address(usdc), 30000e6, 0, alice);
        pool.addLiquidity(address(tranche_70), address(btc), 10e8, 0, alice);
        pool.addLiquidity(address(tranche_20), address(btc), 10e8, 0, alice);
        pool.addLiquidity(address(tranche_10), address(btc), 10e8, 0, alice);
        vm.stopPrank();

        vm.prank(owner);
        pool.setMaxGlobalShortSize(address(btc), 10000e30);

        vm.prank(bob);
        uint256 collateralAmount = 2_000e6;
        usdc.transfer(address(pool), collateralAmount);

        vm.prank(orderManager);
        vm.expectRevert();
        pool.increasePosition(bob, address(btc), address(usdc), collateralAmount * 1e24 * 10, Side.SHORT);

        vm.prank(owner);
        pool.setMaxGlobalShortSize(address(btc), 1000000e30);

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(usdc), collateralAmount * 1e24 * 10, Side.SHORT);
    }

    function test_set_max_global_long_size() public {
        vm.prank(alice);
        oracle.setPrice(address(btc), 20_000e22);

        vm.startPrank(bob);
        pool.addLiquidity(address(tranche_70), address(btc), 10e8, 0, alice);
        pool.addLiquidity(address(tranche_20), address(btc), 10e8, 0, alice);
        pool.addLiquidity(address(tranche_10), address(btc), 10e8, 0, alice);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert();
        pool.setMaxGlobalLongSizeRatio(address(usdc), 5e9);

        vm.prank(owner);
        pool.setMaxGlobalLongSizeRatio(address(btc), 5e9); // 50%

        vm.prank(bob);
        btc.transfer(address(pool), 1e8);

        vm.prank(orderManager);
        vm.expectRevert();
        pool.increasePosition(bob, address(btc), address(btc), 1e8 * 20_000e22 * 20, Side.LONG);

        vm.prank(owner);
        pool.setMaxGlobalLongSizeRatio(address(btc), 1e10); // 100%

        vm.prank(orderManager);
        pool.increasePosition(bob, address(btc), address(btc), 1e8 * 20_000e22 * 10, Side.LONG);
    }

    // =============== CONTROL LIQUIDITY WITH FEE ===============

    /**
     * title: Alice add liquidity with zero price.
     * expect: Revert with message "Pool::addLiquidity: !zero price".
     * recommend: Validate token price.
     *
     */
    function test_revert_add_liquidity() external {
        vm.startPrank(alice);
        // Failed: ZeroPrice
        {
            // vm.expectRevert("Pool::addLiquidity: !zero price");
            pool.addLiquidity(address(tranche_70), address(btc), 1e8, 0, alice);
        }
        // AssetNotListed
        {
            vm.expectRevert();
            pool.addLiquidity(address(tranche_70), address(busd), 1e8, 0, alice);
        }
        // SlippageExceeded
        {
            vm.expectRevert();
            pool.addLiquidity(address(tranche_70), address(btc), 1e8, 100e18, alice);
        }

        vm.stopPrank();
    }

    /**
     * title: Alice add liquidity to Tranche70.
     * expect: Not revert.
     * recommend: event LiquidityAdded need emit fee and daoFee.
     *
     */
    function test_add_liquidity() external {
        vm.startPrank(alice);
        // Mock data
        uint256 addLiquidityAmount = 1e8;
        uint256 btcPrice = 20_000e22;
        oracle.setPrice(address(btc), btcPrice);

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(btc));

        // Add 1 BTC to tranche_70 earn 19_980 LP70
        pool.addLiquidity(address(tranche_70), address(btc), addLiquidityAmount, 0, alice);

        // Estimate fee and lp
        uint256 estFeeValue = addLiquidityAmount * btcPrice * ADD_REMOVE_FEE / LP_INITIAL_PRICE / PRECISION;
        uint256 estFeeAmount = addLiquidityAmount * ADD_REMOVE_FEE / PRECISION;
        uint256 estLpReceive = 20_000e18 - estFeeValue;

        // Validate lp balance and supply
        {
            assertEq(tranche_70.balanceOf(alice), estLpReceive);
            assertEq(tranche_70.totalSupply(), estLpReceive);
        }
        // Validate pool
        {
            (uint256 afterFeeReserve, uint256 afterPoolBalance,,,) = pool.poolTokens(address(btc));
            AssetInfo memory afterPoolAsset = pool.getPoolAsset(address(btc));

            assertEq(afterFeeReserve - beforeFeeReserve, estFeeAmount * DAO_FEE / PRECISION);
            assertEq(beforePoolBalance + addLiquidityAmount, afterPoolBalance);
            assertEq(
                (beforePoolAsset.poolAmount + addLiquidityAmount - (estFeeAmount * DAO_FEE / PRECISION)),
                afterPoolAsset.poolAmount
            );
            assertEq(afterPoolAsset.poolAmount + afterFeeReserve, afterPoolBalance);
        }
        // Validate tranche value and price
        {
            uint256 trancheValue = pool.getTrancheValue(address(tranche_70), true);
            assertEq(trancheValue, (addLiquidityAmount - (estFeeAmount * DAO_FEE / PRECISION)) * btcPrice);
            assertEq(
                trancheValue / tranche_70.totalSupply(),
                (addLiquidityAmount - (estFeeAmount * DAO_FEE / PRECISION)) * btcPrice / estLpReceive
            );
        }
        vm.stopPrank();
    }

    /**
     * title: Alice add BTC and USDC token to Tranche70.
     * expect: Not revert.
     * recommend: No.
     *
     */
    function test_multiple_add_liquidity() external {
        vm.startPrank(alice);
        // Mock data
        uint256 addBtcLiquidityAmount = 1e8;
        uint256 addUsdcLiquidityAmount = 1_000e6;
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(usdc), 1e24);

        // Add 1 BTC to tranche_70 earn 19_980 LP70
        pool.addLiquidity(address(tranche_70), address(btc), addBtcLiquidityAmount, 0, alice);
        uint256 trancheValueAfterAddBtc = pool.getTrancheValue(address(tranche_70), true);
        uint256 tranche70SupplyAfterAddBtc = tranche_70.totalSupply();
        // Add 1000 USDC to tranche_70 earn 999 LP70
        pool.addLiquidity(address(tranche_70), address(usdc), addUsdcLiquidityAmount, 0, alice);

        // Estimate fee and lp
        uint256 estBtcFeeAmount = addBtcLiquidityAmount * ADD_REMOVE_FEE / PRECISION;
        uint256 estUsdcFeeAmount = addUsdcLiquidityAmount * ADD_REMOVE_FEE / PRECISION;
        uint256 estLpReceiveByBTC =
            addBtcLiquidityAmount * (PRECISION - ADD_REMOVE_FEE) / PRECISION * 20_000e22 / LP_INITIAL_PRICE;
        uint256 estLpReceiveByUsdc = addUsdcLiquidityAmount * (PRECISION - ADD_REMOVE_FEE) * tranche70SupplyAfterAddBtc
            / PRECISION * 1e24 / trancheValueAfterAddBtc;

        // Validate lp balance and supply
        {
            assertEq(tranche_70.balanceOf(alice), estLpReceiveByBTC + estLpReceiveByUsdc);
            assertEq(tranche_70.totalSupply(), estLpReceiveByBTC + estLpReceiveByUsdc);
        }
        // Validate pool
        {
            (uint256 afterFeeReserve, uint256 afterPoolBalance,,,) = pool.poolTokens(address(btc));
            AssetInfo memory afterPoolAsset = pool.getPoolAsset(address(btc));

            assertEq(afterFeeReserve, (estBtcFeeAmount * DAO_FEE / PRECISION));
            assertEq(addBtcLiquidityAmount, afterPoolBalance);
            assertEq(addBtcLiquidityAmount - (estBtcFeeAmount * DAO_FEE / PRECISION), afterPoolAsset.poolAmount);
            assertEq(afterPoolAsset.poolAmount + afterFeeReserve, afterPoolBalance);
        }
        // Validate tranche value and price
        {
            uint256 trancheValue = pool.getTrancheValue(address(tranche_70), true);
            uint256 btcTrancheValue = (addBtcLiquidityAmount - (estBtcFeeAmount * DAO_FEE / PRECISION)) * 20_000e22;
            uint256 usdcTrancheValue = (addUsdcLiquidityAmount - (estUsdcFeeAmount * DAO_FEE / PRECISION)) * 1e24;
            uint256 estTotalTrancheValue = (addBtcLiquidityAmount - (estBtcFeeAmount * DAO_FEE / PRECISION)) * 20_000e22
                + (addUsdcLiquidityAmount - (estUsdcFeeAmount * DAO_FEE / PRECISION)) * 1e24;
            assertEq(trancheValue, btcTrancheValue + usdcTrancheValue);
            assertEq(
                trancheValue / tranche_70.totalSupply(),
                (estTotalTrancheValue / (estLpReceiveByBTC + estLpReceiveByUsdc))
            );
        }

        vm.stopPrank();
    }

    /**
     * title: Alice remove liquidity with in valid token.
     * expect: Revert with message "Pool::addLiquidity: !zero price".
     * recommend: Validate token price.
     *
     */
    function test_revert_remove_liquidity() external {
        vm.startPrank(alice);
        // InvalidTranche
        {
            vm.expectRevert();
            pool.removeLiquidity(address(0), address(btc), 1e8, 0, alice);
        }
        // UnknownToken
        {
            vm.expectRevert();
            pool.removeLiquidity(address(tranche_70), address(0), 1e8, 0, alice);
        }
        // Division or modulo by 0
        {
            vm.expectRevert();
            pool.removeLiquidity(address(tranche_70), address(btc), 1e8, 0, alice);
        }

        vm.stopPrank();
    }

    /**
     * title: Alice add liquidity to Tranche70 and remove after that.
     * expect: Not revert.
     * recommend: event LiquidityRemoved need emit fee and daoFee. If user remove all liquidity, a small amount of tokens cannot be withdrawn.
     *
     */
    function test_remove_liquidity() external {
        vm.startPrank(alice);
        // Mock data
        oracle.setPrice(address(btc), 20_000e22);

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(btc));

        // Alice 1 BTC to tranche_70 earn 19_980 LP70
        pool.addLiquidity(address(tranche_70), address(btc), 1e8, 0, alice);

        // Estimate fee and lp
        uint256 estAliceAddLiqFeeValue = 1e8 * 20_000e22 * ADD_REMOVE_FEE / LP_INITIAL_PRICE / PRECISION;
        uint256 estAliceAddLiqFeeAmount = 1e8 * ADD_REMOVE_FEE / PRECISION;
        uint256 estLpAliceReceive = 20_000e18 - estAliceAddLiqFeeValue;

        // Validate lp balance and supply
        {
            assertEq(tranche_70.balanceOf(alice), estLpAliceReceive);
            assertEq(tranche_70.totalSupply(), estLpAliceReceive);
        }

        // After add liquidity state
        (uint256 afterAliceAddLiqFeeReserve, uint256 afterAliceAddLiqPoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory afterAliceAddLiqPoolAsset = pool.getPoolAsset(address(btc));
        uint256 trancheValueAfterAliceAddLiq = pool.getTrancheValue(address(tranche_70), false);
        uint256 trancheSupplyAfterAliceAddLiq = tranche_70.totalSupply();

        // Remove liquidity
        IERC20(address(tranche_70)).safeIncreaseAllowance(address(pool), estLpAliceReceive);
        pool.calcRemoveLiquidity(address(tranche_70), address(btc), estLpAliceReceive);
        vm.expectRevert(); // SlippageExceeded
        pool.removeLiquidity(address(tranche_70), address(btc), estLpAliceReceive, 1000 ether, alice);
        pool.removeLiquidity(address(tranche_70), address(btc), estLpAliceReceive, 0, alice);

        // Validate lp balance and supply
        {
            assertEq(tranche_70.balanceOf(alice), 0);
            assertEq(tranche_70.totalSupply(), 0);
        }
        // After remove liquidity state
        {
            (uint256 afterRemoveLiqFeeReserve, uint256 afterRemoveLiqPoolBalance,,,) = pool.poolTokens(address(btc));
            AssetInfo memory afterRemoveLiqPoolAsset = pool.getPoolAsset(address(btc));
            uint256 estRemoveLiqFeeAmount = estLpAliceReceive * trancheValueAfterAliceAddLiq * ADD_REMOVE_FEE
                / PRECISION / trancheSupplyAfterAliceAddLiq / 20_000e22;

            assertEq(afterRemoveLiqFeeReserve, (estAliceAddLiqFeeAmount + estRemoveLiqFeeAmount) * DAO_FEE / PRECISION);
            assertEq(afterRemoveLiqPoolAsset.poolAmount, (estRemoveLiqFeeAmount) * DAO_FEE / PRECISION);
            assertEq(afterRemoveLiqPoolBalance, (estAliceAddLiqFeeAmount * DAO_FEE / PRECISION) + estRemoveLiqFeeAmount);
            assertEq(afterRemoveLiqPoolAsset.poolAmount + afterRemoveLiqFeeReserve, afterRemoveLiqPoolBalance);

            assertEq(
                btc.balanceOf(alice),
                100_000e8 - (estAliceAddLiqFeeAmount * DAO_FEE / PRECISION) - estRemoveLiqFeeAmount
            );
        }
        vm.stopPrank();
    }

    /**
     * title: Alice and Bob add liquidity to Tranche70 and alice remove after that.
     * expect: Not revert.
     * recommend: diff 15.
     *
     */
    function test_multiple_remove_liquidity() external {
        vm.startPrank(alice);
        // Mock data
        oracle.setPrice(address(btc), 20_000e22);

        (uint256 beforeFeeReserve, uint256 beforePoolBalance,,,) = pool.poolTokens(address(btc));
        AssetInfo memory beforePoolAsset = pool.getPoolAsset(address(btc));

        // Estimate Alice fee and LP
        uint256 estAliceAddLiqFeeAmount = 1e8 * ADD_REMOVE_FEE / PRECISION;
        uint256 estLpAliceReceive = 20_000e18 - (1e8 * 20_000e22 * ADD_REMOVE_FEE / LP_INITIAL_PRICE / PRECISION);

        // Alice add 1 BTC to tranche_70 earn 19_980 LP70
        pool.addLiquidity(address(tranche_70), address(btc), 1e8, 0, alice);
        vm.stopPrank();

        uint256 trancheValueAfterAliceAddLiq = pool.getTrancheValue(address(tranche_70), false);
        uint256 trancheSupplyAfterAliceAddLiq = tranche_70.totalSupply();

        vm.startPrank(bob);

        // Estimate Bob fee and LP
        uint256 estBobAddLiqFeeAmount = 1e8 * ADD_REMOVE_FEE / PRECISION;
        uint256 estLpBobReceive = 1e8 * (PRECISION - ADD_REMOVE_FEE) * trancheSupplyAfterAliceAddLiq / PRECISION
            * 20_000e22 / trancheValueAfterAliceAddLiq;

        // Bob add 1 BTC to tranche_70 earn 19_980 LP70
        pool.addLiquidity(address(tranche_70), address(btc), 1e8, 0, bob);
        vm.stopPrank();

        vm.startPrank(alice);

        // After bob add liquidity state
        uint256 trancheValueAfterBobAddLiq = pool.getTrancheValue(address(tranche_70), false);
        uint256 trancheSupplyAfterBobAddLiq = tranche_70.totalSupply();

        // Remove liquidity
        IERC20(address(tranche_70)).safeIncreaseAllowance(address(pool), estLpAliceReceive);
        pool.removeLiquidity(address(tranche_70), address(btc), estLpAliceReceive, 0, alice);

        // After remove liquidity state
        {
            (uint256 afterRemoveLiqFeeReserve, uint256 afterRemoveLiqPoolBalance,,,) = pool.poolTokens(address(btc));
            AssetInfo memory afterRemoveLiqPoolAsset = pool.getPoolAsset(address(btc));
            uint256 estRemoveLiqFeeAmount = estLpAliceReceive * trancheValueAfterBobAddLiq * ADD_REMOVE_FEE / PRECISION
                / trancheSupplyAfterBobAddLiq / 20_000e22;
            uint256 totalFee = estAliceAddLiqFeeAmount + estRemoveLiqFeeAmount + estBobAddLiqFeeAmount;
            uint256 estBobAddLiqDaoFeeAmount = estBobAddLiqFeeAmount * DAO_FEE / PRECISION;
            uint256 bobProfit = estBobAddLiqDaoFeeAmount * estLpBobReceive / (estLpAliceReceive + estLpBobReceive);

            assertApproxEqAbs(afterRemoveLiqFeeReserve, (totalFee) * DAO_FEE / PRECISION, 1);
            assertApproxEqAbs(
                afterRemoveLiqPoolAsset.poolAmount,
                (1e8 - estBobAddLiqDaoFeeAmount - bobProfit) + (estRemoveLiqFeeAmount) * DAO_FEE / PRECISION,
                15
            );
            assertEq(afterRemoveLiqPoolAsset.poolAmount + afterRemoveLiqFeeReserve, afterRemoveLiqPoolBalance);
        }
        vm.stopPrank();
    }

    // =============== ADMIN FUNCTIONS ===============

    /**
     * title: Owner control risk factor.
     * expect: Not revert.
     * recommend: No
     */
    function test_set_risk_factor() external {
        Pool.RiskConfig[] memory riskConfig = new Pool.RiskConfig[](3);
        riskConfig[0] = Pool.RiskConfig(address(tranche_70), 70);
        riskConfig[1] = Pool.RiskConfig(address(tranche_20), 20);
        riskConfig[2] = Pool.RiskConfig(address(tranche_10), 10);

        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setRiskFactor(address(usdc), riskConfig);
        }

        vm.startPrank(owner);
        // CannotSetRiskFactorForStableCoin
        {
            vm.expectRevert();
            pool.setRiskFactor(address(usdc), riskConfig);
        }
        // InvalidTranche
        {
            riskConfig[2] = Pool.RiskConfig(address(0), 10);
            vm.expectRevert();
            pool.setRiskFactor(address(btc), riskConfig);
        }
        // UnknownToken
        {
            riskConfig[2] = Pool.RiskConfig(address(0), 10);
            vm.expectRevert();
            pool.setRiskFactor(address(0), riskConfig);
        }
        // Success
        {
            riskConfig[2] = Pool.RiskConfig(address(tranche_10), 10);
            pool.setRiskFactor(address(btc), riskConfig);
        }
    }

    /**
     * title: Owner add new token.
     * expect: Not revert.
     * recommend: Validate MAX_ASSETS first and validate address(0)
     */
    function test_add_token() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.addToken(address(busd), true);
        }
        vm.startPrank(owner);
        // Failed: UnknownToken
        {
            // vm.expectRevert();
            pool.addToken(address(0), true);
        }
        // DuplicateToken
        {
            vm.expectRevert();
            pool.addToken(address(btc), true);
        }
        {
            uint256 totalWeight = pool.totalWeight();
            pool.addToken(address(busd), true);
            assertEq(pool.targetWeights(address(busd)), 0);
            assertEq(totalWeight, pool.totalWeight());
        }
    }

    /**
     * title: Owner delist token.
     * expect: Not revert.
     * recommend: No
     */
    function test_delist_token() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.delistToken(address(btc));
        }
        vm.startPrank(owner);
        // AssetNotListed
        {
            vm.expectRevert();
            pool.delistToken(address(busd));
        }
        // Success
        {
            uint256 totalWeight = pool.totalWeight();
            uint256 tokenTargetWeight = pool.targetWeights(address(btc));
            pool.delistToken(address(btc));
            assertEq(pool.isListed(address(btc)), false);
            assertEq(pool.targetWeights(address(btc)), 0);
            assertEq(totalWeight - tokenTargetWeight, pool.totalWeight());
        }
    }

    /**
     * title: Owner control max leverage.
     * expect: Not revert.
     * recommend: Validate max leverage
     */
    function test_set_max_leverage() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setMaxLeverage(0);
        }
        vm.startPrank(owner);
        // InvalidMaxLeverage
        {
            vm.expectRevert();
            pool.setMaxLeverage(0);
        }
        // Failed: InvalidMaxLeverage
        {
            // vm.expectRevert();
            pool.setMaxLeverage(type(uint256).max);
        }
        // Success
        {
            pool.setMaxLeverage(100);
            assertEq(pool.maxLeverage(), 100);
        }
    }

    /**
     * title: Owner control oracle.
     * expect: Not revert.
     * recommend: No.
     */
    function test_set_oracle() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setOracle(address(0));
        }
        vm.startPrank(owner);
        // ZeroAddress
        {
            vm.expectRevert();
            pool.setOracle(address(0));
        }
        // Success
        {
            pool.setOracle(address(oracle));
            assertEq(address(oracle), address(pool.oracle()));
        }
    }

    /**
     * title: Owner control swap fee.
     * expect: Not revert.
     * recommend: No.
     */
    function test_set_swap_fee() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setSwapFee(1e7, 0, 1e7, 0); // 0.1%
        }
        vm.startPrank(owner);
        // ValueTooHigh
        {
            vm.expectRevert();
            pool.setSwapFee(100e10, 0, 100e10, 0); // 100%
        }
        // Success
        {
            pool.setSwapFee(2e7, 0, 2e7, 0); // 0.2%
        }
    }

    /**
     * title: Owner control liquidity fee.
     * expect: Not revert.
     * recommend: Create MAX_ADD_REMOVE_FEE instead of MAX_BASE_SWAP_FEE.
     */
    function test_set_add_and_remove_fee() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setAddRemoveLiquidityFee(1e7); // 0.1%
        }
        vm.startPrank(owner);
        // ValueTooHigh
        {
            vm.expectRevert();
            pool.setAddRemoveLiquidityFee(100e10); // 100%
        }
        // Success
        {
            pool.setAddRemoveLiquidityFee(2e7); // 0.2%
            assertEq(pool.addRemoveLiquidityFee(), 2e7);
        }
    }

    /**
     * title: Owner control position and liquidation fee.
     * expect: Not revert.
     * recommend: Create MAX_ADD_REMOVE_FEE instead of MAX_BASE_SWAP_FEE.
     */
    function test_set_position_fee() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setPositionFee(1e8, 10e30); // 1%, $10
        }
        vm.startPrank(owner);
        // ValueTooHigh
        {
            vm.expectRevert();
            pool.setPositionFee(10e8, 20e30); // 1%, $10
        }
        // Success
        {
            pool.setPositionFee(1e8, 10e30); // 1%, $10
        }
    }

    /**
     * title: Owner control fee distributor.
     * expect: Not revert.
     * recommend: No.
     */
    function test_set_fee_distributor() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setFeeDistributor(address(0));
        }
        vm.startPrank(owner);
        // Invalid address
        {
            vm.expectRevert();
            pool.setFeeDistributor(address(0));
        }
        // Success
        {
            pool.setFeeDistributor(owner);
        }
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert();
        pool.withdrawFee(address(btc), alice);
        vm.stopPrank();
        vm.startPrank(owner);
        pool.withdrawFee(address(btc), owner);
    }

    /**
     * title: Owner control pool hook.
     * expect: Not revert.
     * recommend: No.
     */
    function test_set_pool_hook() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setPoolHook(address(0));
        }
        vm.startPrank(owner);
        // Success
        {
            pool.setPoolHook(alice);
        }
    }

    /**
     * title: Owner control target weight.
     * expect: Not revert.
     * recommend: No.
     */
    function test_set_target_weight() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setPoolHook(address(0));
        }
        vm.startPrank(owner);
        // RequireAllTokens
        {
            TokenWeight[] memory config = new TokenWeight[](2);
            config[0] = TokenWeight({token: address(btc), weight: 1000});
            config[1] = TokenWeight({token: address(weth), weight: 1000});
            vm.expectRevert();
            pool.setTargetWeight(config);
        }
        // Success
        {
            TokenWeight[] memory config = new TokenWeight[](3);
            config[0] = TokenWeight({token: address(btc), weight: 1000});
            config[1] = TokenWeight({token: address(weth), weight: 1000});
            config[2] = TokenWeight({token: address(usdc), weight: 2000});

            pool.setTargetWeight(config);
        }
    }

    /**
     * title: Owner control dao fee.
     * expect: Not revert.
     * recommend: No.
     */
    function test_set_dao_fee() external {
        // OnlyOwner
        {
            vm.expectRevert("Ownable: caller is not the owner");
            pool.setDaoFee(0);
        }
        vm.startPrank(owner);
        // Max Value
        {
            vm.expectRevert();
            pool.setDaoFee(PRECISION * 2);
        }
        // Success
        {
            pool.setDaoFee(DAO_FEE);
        }
    }
}
