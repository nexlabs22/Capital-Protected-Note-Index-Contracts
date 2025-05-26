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
import {FeeCalculation} from "../libraries/FeeCalculation.sol";
import {ICrypto5Factory} from "../interfaces/ICrypto5Factory.sol";
import {FeeVault} from "../vault/FeeVault.sol";

error ZeroAmount();

contract IndexFactory is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IndexFactoryStorage factoryStorage;
    FeeVault feeVault;

    // address feeVault;
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

    event CancelIssuanceCompleted(
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

    event CancelRedemptionCompleted(
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

    function initialize(address _indexFactoryStorage, address _feeVault) external initializer {
        require(_indexFactoryStorage != address(0), "Invalid Address");
        require(_feeVault != address(0), "Invalid FeeVault");

        factoryStorage = IndexFactoryStorage(_indexFactoryStorage);
        feeVault = FeeVault(_feeVault);

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
        uint256 feeAmount = FeeCalculation.calculateFee(_inputAmount, factoryStorage.feeRate());
        // uint256 issuanceFee = ICrypto5Factory(factoryStorage.crypto5FactoryAddress()).getIssuanceFee();
        // (, bool success) = factoryStorage.feeReceiver().call{values: issuanceFee}();
        // require(success, "ETH transfer failed!");

        IERC20(factoryStorage.usdc()).safeTransferFrom(msg.sender, address(factoryStorage.sca()), _inputAmount);
        IERC20(factoryStorage.usdc()).safeTransferFrom(msg.sender, address(feeVault), feeAmount);

        issuanceNonce++;
        factoryStorage.setIssuanceInputAmount(issuanceNonce, _inputAmount);
        factoryStorage.setIssuanceFeeByNonce(issuanceNonce, feeAmount);
        factoryStorage.setIssuanceRequesterByNonce(issuanceNonce, msg.sender);
        factoryStorage.addIssuanceForCurrentRound(msg.sender, _inputAmount);

        emit RequestIssuance(
            issuanceNonce, msg.sender, address(factoryStorage.usdc()), _inputAmount, 0, block.timestamp
        );
        return issuanceNonce;
    }

    function redemption(uint256 _amount) external nonReentrant returns (uint256 nonce) {
        if (_amount == 0) revert ZeroAmount();
        // uint256 redemptionFee = ICrypto5Factory(factoryStorage.crypto5FactoryAddress()).getRedemptionFee(_amount);
        // (bool success,) = factoryStorage.feeReceiver().call{value: issuanceFee}("");
        // require(success, "ETH transfer failed!");

        factoryStorage.indexToken().transferFrom(msg.sender, address(factoryStorage.sca()), _amount);

        nonce = ++redemptionNonce;

        factoryStorage.setRedemptionInputAmount(nonce, _amount);
        factoryStorage.addRedemptionForCurrentRound(msg.sender, _amount);
        emit RequestRedemption(nonce, msg.sender, address(factoryStorage.usdc()), _amount, 0, block.timestamp);
    }

    function cancelIssuance( /*uint256 roundId,*/ uint256 nonce) external nonReentrant {
        require(!factoryStorage.issuanceIsCompleted(nonce), "Issuance is completed");
        address requester = factoryStorage.issuanceRequesterByNonce(nonce);
        require(msg.sender == requester, "Only requester can cancel");

        uint256 amount = factoryStorage.issuanceInputAmount(nonce);
        uint256 fee = factoryStorage.issuanceFeeByNonce(nonce);
        require(amount > 0, "nothing to refund");

        uint256 roundId = factoryStorage.issuanceRoundId();
        require(factoryStorage.issuanceRoundActive(roundId), "round already processed");

        require(
            IERC20(factoryStorage.usdc()).balanceOf(address(factoryStorage.sca())) >= amount, "USDC already deployed"
        );

        factoryStorage.undoIssuance(requester, amount);
        factoryStorage.setIssuanceCompleted(nonce, true);
        factoryStorage.setIssuanceFeeByNonce(nonce, 0);
        factoryStorage.sca().refund(requester, amount);
        FeeVault(feeVault).refund(requester, fee);

        // IERC20(factoryStorage.usdc()).safeTransferFrom(factoryStorage.feeReceiver(), msg.sender, fee); // should transfer to fee vault

        emit CancelIssuanceCompleted(nonce, requester, address(factoryStorage.usdc()), amount + fee, 0, block.timestamp);
    }

    function cancelRedemption(uint256 nonce) external nonReentrant {
        require(!factoryStorage.redemptionIsCompleted(nonce), "Redemption is completed");

        address requester = factoryStorage.redemptionRequesterByNonce(nonce);
        require(msg.sender == requester, "Only requester can cancel");

        uint256 amount = factoryStorage.redemptionInputAmount(nonce);
        require(amount > 0, "nothing to refund");

        uint256 roundId = factoryStorage.redemptionRoundId();
        require(factoryStorage.redemptionRoundActive(roundId), "round already processed");

        require(factoryStorage.indexToken().balanceOf(address(factoryStorage.sca())) >= amount, "IDX already deployed");

        factoryStorage.undoRedemption(requester, amount);
        factoryStorage.setRedemptionCompleted(nonce, true);

        factoryStorage.sca().rescue(address(factoryStorage.indexToken()), requester, amount);

        emit CancelRedemptionCompleted(
            nonce, requester, address(factoryStorage.indexToken()), amount, 0, block.timestamp
        );
    }

    function increaseCurrentRoundId() external onlyOwnerOrOperator {
        factoryStorage.increaseIssuanceRoundId();
    }
}
