// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IndexFactoryStorage} from "../factory/IndexFactoryStorage.sol";

contract FeeVault is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IndexFactoryStorage factoryStorage;

    address factory;

    function initialize(address _indexFactoryStorage) external initializer {
        require(_indexFactoryStorage != address(0), "FeeVault: zero addr");
        factoryStorage = IndexFactoryStorage(_indexFactoryStorage);
        factory = address(factoryStorage.indexFactory());
        __Ownable_init(msg.sender);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function refund(address to, uint256 amount) external {
        require(msg.sender == factory, "FeeVault: !factory");
        require(to != address(0) && amount > 0, "FeeVault: bad params");
        factoryStorage.usdc().safeTransfer(to, amount);
    }

    function withdrawUsdc(address to, uint256 amount) external onlyOwner {
        require(to != address(0) && amount > 0, "FeeVault: bad params");
        factoryStorage.usdc().safeTransfer(to, amount);
    }

    function withdrawAllUsdc() external onlyOwner {
        uint256 balance = factoryStorage.usdc().balanceOf(address(this));
        factoryStorage.usdc().safeTransfer(owner(), balance);
    }
}
