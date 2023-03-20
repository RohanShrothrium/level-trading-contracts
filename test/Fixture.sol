pragma solidity 0.8.15;

import "forge-std/Test.sol";

import {Pool, TokenWeight, Side, PoolTokenInfo, AssetInfo, LP_INITIAL_PRICE} from "src/pool/Pool.sol";
import {PoolLens, PoolAsset} from "src/lens/PoolLens.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {WETH9} from "./mocks/WETH.sol";
import {ILPToken} from "src/interfaces/ILPToken.sol";
import {PoolErrors} from "src/pool/PoolErrors.sol";
import {LiquidityRouter} from "src/pool/LiquidityRouter.sol";
import {TransparentUpgradeableProxy as Proxy} from "openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin/proxy/transparent/ProxyAdmin.sol";

address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
uint256 constant PRECISION = 1e10; // 50%
uint256 constant MAX_TRANCHES = 3;
uint256 constant SWAP_FEE = 2e7; // 0.2%
uint256 constant ADD_REMOVE_FEE = 1e7; // 0.1%
uint256 constant POSITION_FEE = 1e7; // 0.1%
uint256 constant DAO_FEE = 5e9; // 50%

contract TestPool is Pool {
    constructor() {}
    function initialize(
        uint256 _maxLeverage,
        uint256 _positionFee,
        uint256 _liquidationFee,
        uint256 _interestRate,
        uint256 _accrualInterval,
        uint256 _maintenanceMargin
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        _setMaxLeverage(_maxLeverage);
        _setPositionFee(_positionFee, _liquidationFee);
        _setInterestRate(_interestRate, _accrualInterval);
        _setMaintenanceMargin(_maintenanceMargin);
        fee.daoFee = 1e10;
    }

    function getTrancheAsset(address tranche, address token) external view returns (AssetInfo memory) {
        return trancheAssets[tranche][token];
    }

    function tranchePoolBalance(address token, address tranche) external view returns (uint256) {
        return trancheAssets[tranche][token].poolAmount;
    }

    function getPoolTokenInfo(address token) external view returns (PoolTokenInfo memory) {
        return poolTokens[token];
    }

    function getLpPrice(address _tranche) external view returns (uint256) {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }

        uint256 lpSupply = ILPToken(_tranche).totalSupply();
        return lpSupply == 0 ? LP_INITIAL_PRICE : _getTrancheValue(_tranche, true) / lpSupply;
    }

    function addTranche(address _tranche) external onlyOwner {
        if (allTranches.length >= MAX_TRANCHES) {
            revert PoolErrors.MaxNumberOfTranchesReached();
        }
        _requireAddress(_tranche);
        if (isTranche[_tranche]) {
            revert PoolErrors.TrancheAlreadyAdded(_tranche);
        }
        isTranche[_tranche] = true;
        allTranches.push(_tranche);
        emit TrancheAdded(_tranche);
    }
}

abstract contract Fixture is Test {
    address public owner = 0x2E20CFb2f7f98Eb5c9FD31Df41620872C0aef524;
    address public orderManager = 0x69D4aDe841175fE72642D03D82417215D4f47790;
    address public alice = 0xfC067b2BE205F8e8C85aC653f64C52baa225aCa4;
    address public bob = 0x90FbB788b18241a4bBAb4cd5eb839a42FF59D235;
    address public eve = 0x462beDFDAFD8681827bf8E91Ce27914cb00CcF83;
    WETH9 public weth;

    MockERC20 public btc;
    MockERC20 public usdc;
    MockERC20 public busd;
    MockOracle oracle;
    PoolLens lens;

    function build() internal virtual {
        vm.startPrank(owner);
        btc = new MockERC20("WBTC", "WBTC", 8);
        usdc = new MockERC20("USDC", "USDC", 6);
        busd = new MockERC20("BUSD", "BUSD", 18);
        oracle = new MockOracle();
        lens = new PoolLens();
        vm.stopPrank();
        weth = new WETH9();
    }
}

abstract contract PoolTestFixture is Fixture {
    TestPool public pool;
    LiquidityRouter public router;

    function build() internal override {
        Fixture.build();

        vm.startPrank(owner);
        TestPool poolImpl = new TestPool();
        ProxyAdmin admin = new ProxyAdmin();
        Proxy proxy = new Proxy(address(poolImpl), address(admin), new bytes(0));
        pool = TestPool(address(proxy));
        pool.initialize(
            20, // max leverage | 20x
            POSITION_FEE, // portion fee | 0.1%
            5e30, // liquidation fee value | 5$
            1e6, // interest rate (funding rate) | 0.01%
            100, // interest accrual interval
            1e8 // maintenance margin
        );
        pool.setOrderManager(orderManager);
        pool.setOracle(address(oracle));
        pool.addToken(address(weth), false);
        pool.addToken(address(btc), false);
        pool.addToken(address(usdc), true);
        TokenWeight[] memory config = new TokenWeight[](3);
        config[0] = TokenWeight({token: address(btc), weight: 1000});
        config[1] = TokenWeight({token: address(weth), weight: 1000});
        config[2] = TokenWeight({token: address(usdc), weight: 2000});

        pool.setTargetWeight(config);
        router = new LiquidityRouter(address(pool), address(weth));
        vm.stopPrank();
    }

    function _checkInvariant(address _token) internal {
        PoolAsset memory asset = lens.poolAssets(address(pool), _token);
        assertApproxEqAbs(asset.poolAmount + asset.feeReserve, asset.poolBalance, 1, "invariant: poolAmount + feeReserve ~ poolBalance");
    }
}
