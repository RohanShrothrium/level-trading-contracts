pragma solidity 0.8.15;

import "forge-std/Test.sol";
import "src/tokens/LPToken.sol";

contract LPTokenTest is Test {
    address owner = 0x9Cb2f2c0122a1A8C90f667D1a55E5B45AC8b6086;
    address alice = 0xfC067b2BE205F8e8C85aC653f64C52baa225aCa4;

    LPToken lp;

    function setUp() external {
        vm.startPrank(owner);
        lp = new LPToken('LP', 'LP', owner);
        vm.stopPrank();
    }

    function test_unauthorized_mint_revert() external {
        vm.prank(alice);
        vm.expectRevert();
        lp.mint(alice, 1 ether);
    }
    function test_mint_success() external {
        vm.prank(owner);
        lp.mint(alice, 1 ether);
        assertEq(lp.balanceOf(alice), 1 ether);
    }
}
