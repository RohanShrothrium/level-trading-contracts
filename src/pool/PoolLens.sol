// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import {PoolStorage, AssetInfo, PoolTokenInfo, Position, MAX_TRANCHES} from "./PoolStorage.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {SignedInt, SignedIntOps} from "../lib/SignedInt.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {ILevelOracle} from "../interfaces/ILevelOracle.sol";

struct PositionView {
    bytes32 key;
    uint256 size;
    uint256 collateralValue;
    uint256 entryPrice;
    uint256 pnl;
    uint256 reserveAmount;
    bool hasProfit;
    address collateralToken;
    uint256 borrowIndex;
}

struct PoolAsset {
    uint256 poolAmount;
    uint256 reservedAmount;
    uint256 feeReserve;
    uint256 guaranteedValue;
    uint256 totalShortSize;
    uint256 averageShortPrice;
    uint256 poolBalance;
    uint256 lastAccrualTimestamp;
    uint256 borrowIndex;
}

interface IPoolForLens is IPool {
    function getPoolAsset(address _token) external view returns (AssetInfo memory);
    function trancheAssets(address _tranche, address _token) external view returns (AssetInfo memory);
    function getAllTranchesLength() external view returns (uint256);
    function allTranches(uint256) external view returns (address);
    function poolTokens(address) external view returns (PoolTokenInfo memory);
    function positions(bytes32) external view returns (Position memory);
    function oracle() external view returns (ILevelOracle);
    function getPoolValue(bool _max) external view returns (uint256);
    function getTrancheValue(address _tranche, bool _max) external view returns (uint256 sum);
    function averageShortPrices(address _tranche, address _token) external view returns (uint256);
}

contract PoolLens {
    using SignedIntOps for SignedInt;

    function poolAssets(address _pool, address _token) external view returns (PoolAsset memory poolAsset) {
        IPoolForLens self = IPoolForLens(_pool);
        AssetInfo memory asset = self.getPoolAsset(_token);
        PoolTokenInfo memory tokenInfo = self.poolTokens(_token);
        uint256 avgShortPrice;
        uint256 nTranches = self.getAllTranchesLength();
        for (uint256 i = 0; i < nTranches;) {
            address tranche = self.allTranches(i);
            uint256 shortSize = self.trancheAssets(tranche, _token).totalShortSize;
            avgShortPrice += shortSize * self.averageShortPrices(tranche, _token);
            unchecked {
                ++i;
            }
        }
        poolAsset.poolAmount = asset.poolAmount;
        poolAsset.reservedAmount = asset.reservedAmount;
        poolAsset.guaranteedValue = asset.guaranteedValue;
        poolAsset.totalShortSize = asset.totalShortSize;
        poolAsset.feeReserve = tokenInfo.feeReserve;
        poolAsset.averageShortPrice = asset.totalShortSize == 0 ? 0 : avgShortPrice / asset.totalShortSize;
        poolAsset.poolBalance = tokenInfo.poolBalance;
        poolAsset.lastAccrualTimestamp = tokenInfo.lastAccrualTimestamp;
        poolAsset.borrowIndex = tokenInfo.borrowIndex;
    }

    function getPosition(address _pool, address _owner, address _indexToken, address _collateralToken, Side _side)
        external
        view
        returns (PositionView memory result)
    {
        IPoolForLens self = IPoolForLens(_pool);
        ILevelOracle oracle = self.oracle();
        bytes32 positionKey = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = self.positions(positionKey);
        uint256 indexPrice =
            _side == Side.LONG ? oracle.getPrice(_indexToken, false) : oracle.getPrice(_indexToken, true);
        SignedInt memory pnl = PositionUtils.calcPnl(_side, position.size, position.entryPrice, indexPrice);

        result.key = positionKey;
        result.size = position.size;
        result.collateralValue = position.collateralValue;
        result.pnl = pnl.abs;
        result.hasProfit = pnl.isPos();
        result.entryPrice = position.entryPrice;
        result.borrowIndex = position.borrowIndex;
        result.reserveAmount = position.reserveAmount;
        result.collateralToken = _collateralToken;
    }

    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    function getTrancheValue(IPoolForLens _pool, address _tranche) external view returns (uint256) {
        return (_pool.getTrancheValue(_tranche, true) + _pool.getTrancheValue(_tranche, false)) / 2;
    }

    function getPoolValue(IPoolForLens _pool) external view returns (uint256) {
        return (_pool.getPoolValue(true) + _pool.getPoolValue(false)) / 2;
    }

    struct PoolInfo {
        uint256 minValue;
        uint256 maxValue;
        uint256[MAX_TRANCHES] tranchesMinValue;
        uint256[MAX_TRANCHES] tranchesMaxValue;
    }

    function getPoolInfo(IPoolForLens _pool) external view returns (PoolInfo memory info) {
        info.minValue = _pool.getPoolValue(false);
        info.maxValue = _pool.getPoolValue(true);
        uint256 nTranches = _pool.getAllTranchesLength();
        for (uint256 i = 0; i < nTranches;) {
            address tranche = _pool.allTranches(i);
            info.tranchesMinValue[i] = _pool.getTrancheValue(tranche, false);
            info.tranchesMaxValue[i] = _pool.getTrancheValue(tranche, true);
            unchecked {
                ++i;
            }
        }
    }
}