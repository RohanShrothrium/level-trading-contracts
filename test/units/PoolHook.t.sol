pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import "src/hooks/PoolHook.sol";
import "src/interfaces/IReferralController.sol";
import "src/interfaces/IMintableErc20.sol";
import "test/mocks/Address.sol";
import "src/pool/PoolStorage.sol";
import {Side} from "src/interfaces/IPool.sol";

contract PoolHookTest is Test {
    address admin = 0x9Cb2f2c0122a1A8C90f667D1a55E5B45AC8b6086;
    address public alice = 0xfC067b2BE205F8e8C85aC653f64C52baa225aCa4;

    uint256 constant MAX_MULTIPLIER = 500;

    PoolHook poolHook;
    address oracle;
    address lyLevel;
    address pool;
    address referralController;

    MockERC20 btc;

    function setUp() external {
        vm.startPrank(admin);

        btc = new MockERC20("BTC", "BTC", 18);

        referralController = address(new Address());
        lyLevel = address(new Address());
        oracle = address(new Address());
        pool = address(new Address());
        // pool.setOracle(address(oracle));

        // oracle.setPrice(address(btc), 20_000e12);

        poolHook = new PoolHook(address(lyLevel), address(pool));
        poolHook.setReferralController(address(referralController));
        vm.stopPrank();
    }

    function test_set_referral_controller() external {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        poolHook.setReferralController(address(0));

        vm.startPrank(address(admin));
        vm.expectRevert("PoolHook: _referralController invalid");
        poolHook.setReferralController(address(0));
        poolHook.setReferralController(address(referralController));
    }

    function test_set_multiplier_should_validate() external {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        poolHook.setMultipliers(MAX_MULTIPLIER, MAX_MULTIPLIER, MAX_MULTIPLIER);

        vm.startPrank(address(admin));
        vm.expectRevert("Multiplier too high");
        poolHook.setMultipliers(MAX_MULTIPLIER * 2, MAX_MULTIPLIER, MAX_MULTIPLIER);
        vm.expectRevert("Multiplier too high");
        poolHook.setMultipliers(MAX_MULTIPLIER, MAX_MULTIPLIER * 2, MAX_MULTIPLIER);
        vm.expectRevert("Multiplier too high");
        poolHook.setMultipliers(MAX_MULTIPLIER, MAX_MULTIPLIER, MAX_MULTIPLIER * 2);
        poolHook.setMultipliers(MAX_MULTIPLIER, MAX_MULTIPLIER, MAX_MULTIPLIER);
    }

    modifier setReferralController() {
        vm.prank(address(admin));
        poolHook.setReferralController(address(referralController));
        _;
    }

    function test_increase_position_should_update_referral_point() external setReferralController {
        vm.prank(alice);
        vm.expectRevert("PoolHook:!pool");
        poolHook.postIncreasePosition(alice, address(btc), address(btc), Side.LONG, new bytes(0));

        vm.startPrank(address(pool));
        vm.mockCall(
            referralController, abi.encodeWithSelector(IReferralController.updatePoint.selector, alice, 0), new bytes(0)
        );
        poolHook.postIncreasePosition(alice, address(btc), address(btc), Side.LONG, abi.encode(0, 0, 0));
        vm.clearMockedCalls();
    }

    function test_decrease_position_should_mint_lyLVL() external setReferralController {
        vm.prank(alice);
        vm.expectRevert("PoolHook:!pool");
        poolHook.postDecreasePosition(alice, address(btc), address(btc), Side.LONG, new bytes(0));

        vm.mockCall(lyLevel, abi.encodeWithSelector(IMintableErc20.mint.selector, alice, 1 ether), new bytes(0));
        vm.mockCall(
            referralController, abi.encodeWithSelector(IReferralController.updatePoint.selector, alice, 0), new bytes(0)
        );
        vm.startPrank(address(pool));
        poolHook.postDecreasePosition(alice, address(btc), address(btc), Side.LONG, abi.encode(1e30, 0, 0));
        vm.clearMockedCalls();

        vm.mockCall(
            referralController, abi.encodeWithSelector(IReferralController.updatePoint.selector, alice, 0), new bytes(0)
        );
        poolHook.postDecreasePosition(alice, address(btc), address(btc), Side.LONG, abi.encode(0, 0, 0));
        vm.clearMockedCalls();
    }

    function test_liquidate_position() external setReferralController {
        vm.prank(alice);
        vm.expectRevert("PoolHook:!pool");
        poolHook.postLiquidatePosition(alice, address(btc), address(btc), Side.LONG, new bytes(0));

        // vm.mockCall(
        //     lyLevel, abi.encodeWithSelector(IMintableErc20.mint.selector, alice, 0), new bytes(0)
        // );
        vm.mockCall(
            referralController, abi.encodeWithSelector(IReferralController.updatePoint.selector, alice, 0), new bytes(0)
        );
        vm.startPrank(address(pool));
        poolHook.postLiquidatePosition(alice, address(btc), address(btc), Side.LONG, abi.encode(0, 0));
        vm.clearMockedCalls();
    }

    function test_swap() external {
        vm.prank(alice);
        vm.expectRevert("PoolHook:!pool");
        poolHook.postSwap(alice, address(btc), address(btc), new bytes(0));

        vm.mockCall(pool, abi.encodeWithSignature("oracle()"), abi.encode(oracle));
        vm.mockCall(pool, abi.encodeWithSignature("isStableCoin(address)", address(btc)), abi.encode(false));
        vm.mockCall(
            oracle, abi.encodeWithSignature("getPrice(address,bool)", address(btc), false), abi.encode(20_000e12)
        );

        vm.startPrank(address(pool));
        vm.mockCall(lyLevel, abi.encodeWithSelector(IMintableErc20.mint.selector, alice, 20_000 ether), new bytes(0));
        vm.mockCall(
            referralController, abi.encodeWithSelector(IReferralController.updatePoint.selector, alice, 0), new bytes(0)
        );
        poolHook.postSwap(alice, address(btc), address(btc), abi.encode(1 ether, 0, 0, abi.encode(alice)));
        poolHook.postSwap(alice, address(btc), address(btc), abi.encode(0, 0, 0, abi.encode(alice)));
        poolHook.postSwap(alice, address(btc), address(btc), abi.encode(1 ether, 0, 0, new bytes(0)));
        vm.clearMockedCalls();
    }
}
