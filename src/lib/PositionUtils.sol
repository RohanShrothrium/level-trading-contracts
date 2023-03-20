// SPDX-License-Identifier: UNLCIENSED

pragma solidity >=0.8.0;

import {Side} from "../interfaces/IPool.sol";
import {SignedInt, SignedIntOps} from "./SignedInt.sol";

library PositionUtils {
    using SignedIntOps for int256;

    function calcPnl(Side _side, uint256 _positionSize, uint256 _entryPrice, uint256 _indexPrice)
        internal
        pure
        returns (int256)
    {
        if (_positionSize == 0 || _entryPrice == 0) {
            return 0;
        }
        int256 entryPrice = int256(_entryPrice);
        if (_side == Side.LONG) {
            return (int256(_indexPrice) - entryPrice) * int256(_positionSize) / entryPrice;
        } else {
            return (entryPrice - int256(_indexPrice)) * int256(_positionSize) / entryPrice;
        }
    }

    /// @notice calculate new avg entry price when increase position
    /// @dev for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    ///      for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function calcAveragePrice(
        Side _side,
        uint256 _lastSize,
        uint256 _nextSize,
        uint256 _entryPrice,
        uint256 _nextPrice,
        int256 _realizedPnL
    ) internal pure returns (uint256) {
        if (_nextSize == 0) {
            return 0;
        }
        if (_lastSize == 0) {
            return _nextPrice;
        }
        int256 pnl = calcPnl(_side, _lastSize, _entryPrice, _nextPrice) - _realizedPnL;
        int256 nextSize = int256(_nextSize);
        int256 divisor = _side == Side.LONG ? nextSize + pnl : nextSize - pnl;
        // require(avgPrice > 0);
        return divisor < 0 ? 0 : uint256(nextSize * int256(_nextPrice) / divisor);
    }
}
