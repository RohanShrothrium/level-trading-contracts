pragma solidity 0.8.15;

import {Side} from "./IPool.sol";

interface IReferralController {
    function updatePoint(address _trader, uint256 _value) external;
}
