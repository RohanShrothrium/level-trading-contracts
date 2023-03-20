pragma solidity 0.8.15;

import "forge-std/Test.sol";
import "src/oracle/LevelOracle.sol";
import "src/interfaces/AggregatorV3Interface.sol";
import "test/mocks/Address.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LevelOracleTest is Test {
    address admin = 0x9Cb2f2c0122a1A8C90f667D1a55E5B45AC8b6086;
    address public alice = 0xfC067b2BE205F8e8C85aC653f64C52baa225aCa4;

    uint256 public constant PRICE_FEED_ERROR = 1 hours;
    uint256 public constant PRICE_FEED_INACTIVE = 5 minutes;
    uint256 public constant PRICE_FEED_ERROR_SPREAD = 5e4; // 5%
    uint256 public constant PRICE_FEED_INACTIVE_SPREAD = 2e3; // 0.2%

    MockERC20 btc;
    address chainlinkPriceFeed;
    LevelOracle oracle;

    function setUp() external {
        vm.startPrank(admin);

        btc = new MockERC20("BTC", "BTC", 18);
        chainlinkPriceFeed = address(new Address());
        oracle = new LevelOracle();

        vm.stopPrank();
    }

    function test_add_reporter() external {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.addReporter(admin);

        vm.startPrank(admin);
        oracle.addReporter(admin);
        vm.expectRevert("PriceFeed:reporterAlreadyAdded");
        oracle.addReporter(admin);
    }

    function test_remove_reporter() external {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.removeReporter(admin);

        vm.startPrank(admin);
        vm.expectRevert("PriceFeed:reporterNotExists");
        oracle.removeReporter(admin);
        vm.expectRevert("PriceFeed:invalidAddress");
        oracle.removeReporter(address(0));
        oracle.addReporter(admin);
        oracle.removeReporter(admin);
    }

    function test_config_token() external {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.configToken(address(btc), 18, address(chainlinkPriceFeed), 8, 10 minutes, 1000);

        vm.startPrank(admin);
        vm.expectRevert("PriceFeed:invalidPriceFeed");
        oracle.configToken(address(0), 18, address(0), 8, 10 minutes, 1000);
        vm.expectRevert("PriceFeed:invalidDecimals");
        oracle.configToken(address(btc), 18, address(chainlinkPriceFeed), 0, 10 minutes, 1000);
        vm.expectRevert("PriceFeed:invalidTimeout");
        oracle.configToken(address(btc), 18, address(chainlinkPriceFeed), 8, 0, 0);
        vm.expectRevert("PriceFeed:invalidChainlinkDeviation");
        oracle.configToken(address(btc), 18, address(chainlinkPriceFeed), 8, 10 minutes, 0);
        oracle.configToken(address(btc), 18, address(chainlinkPriceFeed), 8, 10 minutes, 1000);
    }

    function test_unauthorized_user_cannot_post_prices() external {
        vm.prank(alice);
        vm.expectRevert("PriceFeed:unauthorized");
        oracle.postPrices(new address[](1), new uint256[](1));
    }

    function test_post_invalid_tokens_revert() external {
        // precondition: admin allowed to post price
        vm.prank(admin);
        oracle.addReporter(admin);

        address[] memory tokens = new address[](1);
        tokens[0] = address(btc);

        vm.prank(admin);
        vm.expectRevert("PriceFeed:lengthMissMatch");
        oracle.postPrices(tokens, new uint256[](0));

        uint256[] memory prices = new uint256[](1);
        prices[0] = 20_000e8;

        vm.prank(admin);
        vm.expectRevert("PriceFeed:tokenNotConfigured");
        oracle.postPrices(tokens, prices);
    }

    function test_post_price_success() public {
        // precondition: admin allowed to post price
        vm.startPrank(admin);
        oracle.addReporter(admin);
        oracle.configToken(address(btc), 18, address(chainlinkPriceFeed), 8, 2 days, 1000);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(btc);
        uint256[] memory prices = new uint256[](1);
        prices[0] = 20_000e8;

        vm.prank(admin);
        oracle.postPrices(tokens, prices);

        assertEq(oracle.getLastPrice(address(btc)), 20_000e12);
    }

    modifier postPrice() {
        test_post_price_success();
        _;
    }

    function setChainlinkAnswer(
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) internal {
        vm.mockCall(
            chainlinkPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(_roundId, _answer, _startedAt, _updatedAt, _answeredInRound)
        );
    }

    function test_get_price_return_posted_price() external postPrice {
        setChainlinkAnswer(0, 20_000e8, block.timestamp, block.timestamp + 1 minutes, 0);
        uint256 btcPrice = oracle.getPrice(address(btc), true);
        uint256 btcLastPrice = oracle.getLastPrice(address(btc));
        address[] memory tokens = new address[](1);
        tokens[0] = address(btc);

        uint256[] memory allPrices = oracle.getMultiplePrices(tokens, true);
        assertEq(allPrices.length, 1);
        assertEq(allPrices[0], btcPrice);
        assertEq(btcPrice, 20_000e12);
        assertEq(btcLastPrice, 20_000e12);
    }

    function test_get_price_when_keeper_delayed() external postPrice {
        setChainlinkAnswer(0, 30_000e8, block.timestamp, block.timestamp + 1 minutes, 0);
        uint256 btcPrice;

        vm.warp(block.timestamp + 6 minutes);
        btcPrice = oracle.getPrice(address(btc), true);
        assertEq(btcPrice, 30_060e12);

        vm.warp(block.timestamp + 6 minutes + PRICE_FEED_ERROR);
        btcPrice = oracle.getPrice(address(btc), true);
        assertEq(btcPrice, 31500e12);

        vm.warp(block.timestamp + 2 minutes + PRICE_FEED_INACTIVE);
        btcPrice = oracle.getPrice(address(btc), true);
        assertEq(btcPrice, 31500e12);
    }

    function test_get_price_when_chainlink_stopped_should_revert() external postPrice {
        setChainlinkAnswer(0, 30_000e8, block.timestamp, block.timestamp + 1 minutes, 0);
        vm.warp(block.timestamp + 100 days);
        vm.expectRevert("PriceFeed:chainlinkStaled");
        oracle.getPrice(address(btc), true);
    }

    function test_get_price_when_posted_price_higher_than_chainlink() external postPrice {
        setChainlinkAnswer(0, 10_000e8, block.timestamp, block.timestamp + 1 minutes, 0);
        uint256 btcPrice;

        btcPrice = oracle.getPrice(address(btc), true);
        assertEq(btcPrice, 10_030e12);
        btcPrice = oracle.getPrice(address(btc), false);
        assertEq(btcPrice, 10_000e12);
    }

    function test_get_price_when_posted_price_lower_than_chainlink() external postPrice {
        setChainlinkAnswer(0, 30_000e8, block.timestamp, block.timestamp + 1 minutes, 0);
        uint256 btcPrice = oracle.getPrice(address(btc), true);
        assertEq(btcPrice, 30_000e12);
        btcPrice = oracle.getPrice(address(btc), false);
        assertEq(btcPrice, 29_910e12);
    }
}
