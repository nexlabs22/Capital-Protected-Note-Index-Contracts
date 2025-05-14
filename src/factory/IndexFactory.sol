// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StagingCustodyAccount} from "../SCA/StagingCustodyAccount.sol";
import {IndexFactoryStorage} from "../factory/IndexFactoryStorage.sol";
import {FunctionsOracle} from "../factory/FunctionsOracle.sol";
import {IndexToken} from "../token/IndexToken.sol";

error ZeroAmount();

contract IndexFactory is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IndexFactoryStorage factoryStorage;
    StagingCustodyAccount sca;

    address public indexToken;
    address public usdc;
    uint256 public issuanceNonce;
    uint256 public redemptionNonce;

    event RequestIssuance(
        uint256 indexed nonce,
        address indexed user,
        address inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 time
    );

    event RequestCancelIssuance(
        uint256 indexed nonce,
        address indexed user,
        address inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 time
    );

    event RequestRedemption(
        uint256 indexed nonce,
        address indexed user,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 time
    );

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || factoryStorage.functionsOracle().isOperator(msg.sender),
            "Caller is not the owner or operator"
        );
        _;
    }

    function initialize(address _indexFactoryStorage) external initializer {
        factoryStorage = IndexFactoryStorage(_indexFactoryStorage);
        indexToken = address(factoryStorage.indexToken());
        sca = factoryStorage.sca();
        usdc = address(factoryStorage.usdc());

        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function issuanceIndexToken(uint256 _inputAmount) public nonReentrant returns (uint256) {
        if (_inputAmount == 0) revert ZeroAmount();
        uint256 feeAmount = (_inputAmount * factoryStorage.feeRate()) / 10000;
        IERC20(usdc).safeTransferFrom(msg.sender, address(sca), _inputAmount); // should change to quantityIn
        IERC20(usdc).safeTransferFrom(msg.sender, factoryStorage.feeReceiver(), feeAmount);

        issuanceNonce++;
        factoryStorage.setIssuanceInputAmount(issuanceNonce, _inputAmount);
        factoryStorage.setIssuanceRequesterByNonce(issuanceNonce, msg.sender);

        factoryStorage.addIssuanceForCurrentRound(msg.sender, _inputAmount);

        emit RequestIssuance(issuanceNonce, msg.sender, address(usdc), _inputAmount, 0, block.timestamp);
        return issuanceNonce;
    }

    function cancelIssuance(uint256 nonce) external nonReentrant {
        require(!factoryStorage.issuanceIsCompleted(nonce), "Issuance is completed");
        address requester = factoryStorage.issuanceRequesterByNonce(nonce);
        require(msg.sender == requester, "Only requester can cancel");

        uint256 amt = factoryStorage.issuanceInputAmount(nonce);
        require(amt > 0, "nothing to refund");

        sca.refund(requester, amt);
        factoryStorage.undoIssuance(requester, amt);
        factoryStorage.setIssuanceCompleted(nonce, true);

        emit RequestCancelIssuance(nonce, requester, address(usdc), amt, 0, block.timestamp);
    }

    function redemption(uint256 amount) external returns (uint256 nonce) {
        if (amount == 0) revert ZeroAmount();
        // require(amount > 0, "Invalid amount");
        factoryStorage.indexToken().transferFrom(msg.sender, address(sca), amount);

        nonce = ++redemptionNonce;

        factoryStorage.setRedemptionInputAmount(nonce, amount);
        factoryStorage.setIssuanceRequesterByNonce(nonce, msg.sender);
        factoryStorage.addRedemptionForCurrentRound(msg.sender, amount);
        emit RequestRedemption(nonce, msg.sender, address(usdc), amount, 0, block.timestamp);
    }

    function increaseCurrentRoundId() external onlyOwnerOrOperator {
        factoryStorage.increaseCurrentRoundId();
    }
}
