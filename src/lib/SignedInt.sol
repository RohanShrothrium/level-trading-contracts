// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

uint256 constant POS = 1;
uint256 constant NEG = 0;

/// SignedInt is integer number with sign. It value range is -(2 ^ 256 - 1) to (2 ^ 256 - 1)
struct SignedInt {
    /// @dev sig = 1 -> positive, sig = 0 is negative
    /// using uint256 which take up full word to optimize gas and contract size
    uint256 sig;
    uint256 abs;
}

library SignedIntOps {
    function frac(int256 a, uint256 num, uint256 denom) internal pure returns (int256) {
        return a * int256(num) / int256(denom);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function asTuple(int256 x) internal pure returns (SignedInt memory) {
        return SignedInt({abs: abs(x), sig: x < 0 ? NEG : POS});
    }

    function toUint(int256 x) internal pure returns (uint256) {
        require(x >= 0, "SignedInt: below zero");
        return uint256(x);
    }
}
