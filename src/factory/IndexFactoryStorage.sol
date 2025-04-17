// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IndexFactory} from "../factory/IndexFactory.sol";

contract IndexFactoryStorage is Initializable, OwnableUpgradeable {
    IndexFactory indexFactory;

    address public feeReceiver;
    uint256 public feeRate;

    mapping(uint256 => bool) public issuanceIsCompleted;
    mapping(uint256 => address) public issuanceRequesterByNonce;
    mapping(uint256 => uint256) public issuanceInputAmount;

    modifier onlyFactory() {
        // require(
        //     msg.sender == factoryAddress || msg.sender == factoryBalancerAddress, "Caller is not a factory contract"
        // );
        // _;
        require(msg.sender == address(indexFactory), "Caller is not a factory contract");
        _;
    }

    function initialize(address _indexFactory, bool _isMainnet) external initializer {
        require(_indexFactory != address(0), "invalid index factory address");

        feeRate = 10;
        feeReceiver = msg.sender;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function setIssuanceInputAmount(uint256 _issuanceNonce, uint256 _amount) external onlyFactory {
        require(_amount > 0, "Invalid issuance input amount");
        issuanceInputAmount[_issuanceNonce] = _amount;
    }
}
