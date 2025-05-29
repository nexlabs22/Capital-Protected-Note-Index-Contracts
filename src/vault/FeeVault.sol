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

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || factoryStorage.functionsOracle().isOperator(msg.sender)
                || msg.sender == factoryStorage.nexBot() || msg.sender == address(factoryStorage.indexFactory()),
            "Caller is not the owner or operator"
        );
        _;
    }

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

    function refund(address to, uint256 amount) external onlyOwnerOrOperator {
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

    function withdrawEth(address to, uint256 amount) external onlyOwnerOrOperator {
        uint256 balance = address(this).balance;
        require(amount <= balance, "Invalid amount");
        (bool success,) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
