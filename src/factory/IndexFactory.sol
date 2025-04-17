// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StagingCustodyAccount} from "../SCA/StagingCustodyAccount.sol";
import {IndexFactoryStorage} from "../factory/IndexFactoryStorage.sol";

contract IndexFactory is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 usdc;
    StagingCustodyAccount stagingCustodyAccount;
    IndexFactoryStorage indexFactoryStorage;

    function initialize(address _stagingCustodyAccount, address _usdc) external initializer {
        stagingCustodyAccount = StagingCustodyAccount(_stagingCustodyAccount);
        usdc = IERC20(_usdc);

        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function issuanceIndexToken(uint256 _inputAmount) public {
        uint256 feeAmount = (_inputAmount * indexFactoryStorage.feeRate()) / 10000;
        IERC20(usdc).safeTransferFrom(msg.sender, address(stagingCustodyAccount), _inputAmount); // should change to quantityIn
        IERC20(usdc).safeTransferFrom(msg.sender, indexFactoryStorage.feeReceiver(), feeAmount);
    }
}
