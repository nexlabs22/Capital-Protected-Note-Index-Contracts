// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StagingCustodyAccount is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    IERC20 public immutable quoteToken;
    uint256 public depositCounter;
    uint256 public withdrawCounter;

    struct Deposit {
        address requester;
        uint256 amount;
        uint40 timestamp;
        bool processed;
    }

    struct Withdraw {
        address requester;
        uint256 amount;
        uint40 timestamp;
        bool processed;
    }

    mapping(uint256 id => Deposit) public deposits;
    mapping(uint256 id => Withdraw) public withdraws;

    event DepositRecorded(uint256 indexed id, address indexed requester, uint256 amount);
    event WithdrawRecorded(uint256 indexed id, address indexed requester, uint256 amount);
    event FundsWithdrawn(uint256 indexed id, address indexed to, uint256 amount);
    event Rescue(address indexed token, address indexed to, uint256 amount);

    constructor(IERC20 _quoteToken, address _admin, address _bot, address _factory) {
        quoteToken = _quoteToken;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
        _grantRole(BOT_ROLE, _bot);
        _grantRole(FACTORY_ROLE, _factory);
    }

    function recordDeposit(address requester, uint256 amount) external onlyRole(FACTORY_ROLE) nonReentrant {
        require(amount > 0, "SCA: zero amount");
        uint256 id = ++depositCounter;
        deposits[id] =
            Deposit({requester: requester, amount: amount, timestamp: uint40(block.timestamp), processed: false});
        emit DepositRecorded(id, requester, amount);
    }

    function recordWithdraw(address requester, uint256 amount) external onlyRole(FACTORY_ROLE) nonReentrant {
        require(amount > 0, "SCA: zero amount");
        uint256 id = ++withdrawCounter;
        withdraws[id] =
            Withdraw({requester: requester, amount: amount, timestamp: uint40(block.timestamp), processed: false});
        emit WithdrawRecorded(id, requester, amount);
    }

    function withdrawForPurchase(uint256 id, address to) external onlyRole(BOT_ROLE) nonReentrant {
        Deposit storage dep = deposits[id];
        require(!dep.processed, "SCA: already processed");
        dep.processed = true;
        quoteToken.safeTransfer(to, dep.amount);
        emit FundsWithdrawn(id, to, dep.amount);
    }

    function rescue(address token, address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        IERC20(token).safeTransfer(to, amount);
        emit Rescue(token, to, amount);
    }
}
