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

contract IndexFactory is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IndexToken indexToken;
    StagingCustodyAccount stagingCustodyAccount;
    IndexFactoryStorage indexFactoryStorage;
    FunctionsOracle public functionsOracle;
    IERC20 usdc;

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
        require(msg.sender == owner() || functionsOracle.isOperator(msg.sender), "Caller is not the owner or operator");
        _;
    }

    function initialize(
        address _indexToken,
        address _stagingCustodyAccount,
        address _functionsOracle,
        address _usdc,
        address _indexFactoryStorage
    ) external initializer {
        indexToken = IndexToken(_indexToken);
        functionsOracle = FunctionsOracle(_functionsOracle);
        stagingCustodyAccount = StagingCustodyAccount(_stagingCustodyAccount);
        indexFactoryStorage = IndexFactoryStorage(_indexFactoryStorage);

        usdc = IERC20(_usdc);

        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function issuanceIndexToken(uint256 _inputAmount) public nonReentrant whenNotPaused returns (uint256) {
        require(_inputAmount > 0, "Invalid input amount");
        uint256 feeAmount = (_inputAmount * indexFactoryStorage.feeRate()) / 10000;
        IERC20(usdc).safeTransferFrom(msg.sender, address(stagingCustodyAccount), _inputAmount); // should change to quantityIn
        IERC20(usdc).safeTransferFrom(msg.sender, indexFactoryStorage.feeReceiver(), feeAmount);

        issuanceNonce++;
        indexFactoryStorage.setIssuanceInputAmount(issuanceNonce, _inputAmount);
        indexFactoryStorage.setIssuanceRequesterByNonce(issuanceNonce, msg.sender);

        indexFactoryStorage.addIssuanceForCurrentRound(msg.sender, _inputAmount);

        emit RequestIssuance(issuanceNonce, msg.sender, address(usdc), _inputAmount, 0, block.timestamp);
        return issuanceNonce;
    }

    function cancelIssuance(uint256 nonce) external nonReentrant whenNotPaused {
        require(!indexFactoryStorage.issuanceIsCompleted(nonce), "Issuance is completed");
        address requester = indexFactoryStorage.issuanceRequesterByNonce(nonce);
        require(msg.sender == requester, "Only requester can cancel");

        uint256 amt = indexFactoryStorage.issuanceInputAmount(nonce);
        require(amt > 0, "nothing to refund");

        stagingCustodyAccount.refund(requester, amt);
        indexFactoryStorage.undoIssuance(requester, amt);
        indexFactoryStorage.setIssuanceCompleted(nonce, true);

        emit RequestCancelIssuance(nonce, requester, address(usdc), amt, 0, block.timestamp);
    }

    function redemption(uint256 amount) external returns (uint256 nonce) {
        require(amount > 0, "Invalid amount");
        indexToken.transferFrom(msg.sender, address(stagingCustodyAccount), amount);

        nonce = ++redemptionNonce;

        indexFactoryStorage.setRedemptionInputAmount(nonce, amount);
        indexFactoryStorage.setIssuanceRequesterByNonce(nonce, msg.sender);
        indexFactoryStorage.addRedemptionForCurrentRound(msg.sender, amount);
        emit RequestRedemption(nonce, msg.sender, address(usdc), amount, 0, block.timestamp);
    }

    // function redemption(uint256 amt) external nonReentrant whenNotPaused returns (uint256) {
    //     require(amt > 0, "Invalid amount");

    //     indexToken.transferFrom(msg.sender, address(stagingCustodyAccount), amt);

    //     redemptionNonce++;
    //     uint256 nonce = redemptionNonce;

    //     indexFactoryStorage.setRedemptionInputAmount(nonce, amt);
    //     indexFactoryStorage.setIssuanceRequesterByNonce(nonce, msg.sender);
    //     indexFactoryStorage.addRedemptionForCurrentRound(msg.sender, amt);

    //     emit RequestRedemption(nonce, msg.sender, address(usdc), amt, 0, block.timestamp);
    //     return nonce;
    // }

    function increaseCurrentRoundId() external onlyOwnerOrOperator {
        indexFactoryStorage.increaseCurrentRoundId();
    }
}
