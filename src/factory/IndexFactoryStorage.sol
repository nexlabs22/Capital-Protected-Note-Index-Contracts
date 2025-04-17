// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract IndexFactoryStorage is Initializable, OwnableUpgradeable {
    address public feeReceiver;
    uint256 public feeRate;
}
