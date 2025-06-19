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
import {IRiskAssetFactory} from "../interfaces/IRiskAssetFactory.sol";
import {FeeVault} from "../vault/FeeVault.sol";

error ZeroAmount();

contract IndexFactory is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IndexFactoryStorage factoryStorage;
    FeeVault feeVault;

    uint256 public issuanceNonce;
    uint256 public redemptionNonce;

    event RequestIssuance(
        uint256 indexed roundId,
        uint256 indexed nonce,
        address indexed user,
        address inputToken,
        uint256 inputAmount,
        // uint256 outputAmount,
        uint256 feeAmount,
        uint256 time
    );

    event RequestRedemption(
        uint256 indexed roundId,
        uint256 indexed nonce,
        address indexed user,
        address outputToken,
        uint256 inputAmount,
        // uint256 outputAmount,
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
            msg.sender == owner() || factoryStorage.functionsOracle().isOperator(msg.sender)
                || msg.sender == address(factoryStorage.factoryBalancer()),
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

    function issuanceIndexToken(
        address _tokenIn,
        address[] memory _tokenInPath,
        uint24[] memory _tokenInFees,
        uint256 _inputAmount
    ) public payable whenNotPaused nonReentrant returns (uint256) {
        if (_inputAmount == 0) revert ZeroAmount();
        uint256 ethFee = factoryStorage.getIssuanceFee(_tokenIn, _tokenInPath, _tokenInFees, _inputAmount);
        require(msg.value == ethFee, "Wrong ETH fee");
        (bool success,) = factoryStorage.nexBot().call{value: ethFee}("");
        require(success, "ETH transfer failed!");

        uint256 usdcFee = FeeCalculation.calculateFee(_inputAmount, factoryStorage.feeRate());
        IERC20(factoryStorage.usdc()).safeTransferFrom(msg.sender, address(factoryStorage.sca()), _inputAmount);
        IERC20(factoryStorage.usdc()).safeTransferFrom(msg.sender, address(feeVault), usdcFee);

        //  issuanceNonce++;
        uint256 nonce = ++issuanceNonce;
        factoryStorage.setIssuanceInputAmount(nonce, _inputAmount);
        factoryStorage.setIssuanceFeeByNonce(nonce, usdcFee);
        factoryStorage.setIssuanceRequesterByNonce(nonce, msg.sender);
        factoryStorage.addIssuanceForCurrentRound(msg.sender, _inputAmount);
        factoryStorage.setIssuanceRoundToNonce(nonce, factoryStorage.issuanceRoundId());

        uint256 currentRound = factoryStorage.issuanceRoundId();
        factoryStorage.recordIssuanceNonce(currentRound, nonce);

        emit RequestIssuance(
            factoryStorage.issuanceRoundId(),
            nonce,
            msg.sender,
            address(factoryStorage.usdc()),
            _inputAmount,
            // 0,
            usdcFee,
            block.timestamp
        );
        return nonce;
    }

    function redemption(uint256 _amount) external payable whenNotPaused nonReentrant returns (uint256 nonce) {
        if (_amount == 0) revert ZeroAmount();
        uint256 ethFee = factoryStorage.getRedemptionFee(_amount);
        require(msg.value == ethFee, "Wrong ETH fee");
        (bool success,) = factoryStorage.nexBot().call{value: ethFee}("");
        require(success, "ETH transfer failed!");

        IERC20(factoryStorage.indexToken()).safeTransferFrom(msg.sender, address(factoryStorage.sca()), _amount);

        nonce = ++redemptionNonce;

        factoryStorage.setRedemptionInputAmount(nonce, _amount);
        factoryStorage.setRedemptionRequesterByNonce(nonce, msg.sender);
        factoryStorage.addRedemptionForCurrentRound(msg.sender, _amount);
        factoryStorage.setRedemptionRoundToNonce(nonce, factoryStorage.redemptionRoundId());

        uint256 currentRedemRound = factoryStorage.redemptionRoundId();
        factoryStorage.recordRedemptionNonce(currentRedemRound, nonce);

        emit RequestRedemption(
            factoryStorage.redemptionRoundId(),
            nonce,
            msg.sender,
            address(factoryStorage.usdc()),
            _amount,
            // 0,
            block.timestamp
        );
        return nonce;
    }

    function cancelIssuance(uint256 nonce) external whenNotPaused nonReentrant {
        require(!factoryStorage.issuanceRequestCancelled(nonce), "request already cancelled");
        // require(factoryStorage.issuanceInputAmount(nonce) > 0, "No amount for refund!");

        address requester = factoryStorage.issuanceRequesterByNonce(nonce);
        require(msg.sender == requester, "Only requester can cancel");

        uint256 amount = factoryStorage.issuanceInputAmount(nonce);
        uint256 fee = factoryStorage.issuanceFeeByNonce(nonce);
        require(amount > 0, "nothing to refund");

        // uint256 roundId = factoryStorage.issuanceRoundId();
        // require(factoryStorage.issuanceRoundActive(roundId), "round already processed");

        uint256 roundId = factoryStorage.nonceToIssuanceRound(nonce);
        require(factoryStorage.issuanceRoundActive(roundId), "round not active");

        require(
            IERC20(factoryStorage.usdc()).balanceOf(address(factoryStorage.sca())) >= amount, "USDC already deployed"
        );

        factoryStorage.undoIssuanceForRound(roundId, nonce, requester, amount);

        factoryStorage.removeIssuanceNonce(roundId, nonce);
        factoryStorage.setIssuanceCompleted(nonce, true);
        factoryStorage.setIssuanceRequestCancelled(nonce, true);
        factoryStorage.setIssuanceFeeByNonce(nonce, 0);
        factoryStorage.sca().refund(roundId, requester, amount);
        FeeVault(feeVault).refund(requester, fee);

        emit CancelIssuanceCompleted(nonce, requester, address(factoryStorage.usdc()), amount + fee, 0, block.timestamp);
    }

    function cancelRedemption(uint256 nonce) external whenNotPaused nonReentrant {
        require(!factoryStorage.redemptionRequestCancelled(nonce), "request already cancelled");
        // require(factoryStorage.redemptionInputAmount(nonce) > 0, "No amount for refund!");

        address requester = factoryStorage.redemptionRequesterByNonce(nonce);
        require(msg.sender == requester, "Only requester can cancel");

        uint256 amount = factoryStorage.redemptionInputAmount(nonce);
        require(amount > 0, "nothing to refund");

        uint256 roundId = factoryStorage.nonceToRedemptionRound(nonce);
        require(factoryStorage.redemptionRoundActive(roundId), "round not active");

        require(factoryStorage.indexToken().balanceOf(address(factoryStorage.sca())) >= amount, "IDX already deployed");

        factoryStorage.undoRedemptionForRound(roundId, nonce, requester, amount);

        factoryStorage.removeRedemptionNonce(roundId, nonce);
        factoryStorage.setRedemptionCompleted(nonce, true);
        factoryStorage.setRedemptionRequestCancelled(nonce, true);

        factoryStorage.sca().rescue(address(factoryStorage.indexToken()), requester, amount);

        emit CancelRedemptionCompleted(
            nonce, requester, address(factoryStorage.indexToken()), amount, 0, block.timestamp
        );
    }

    /**
     * @dev Pauses the contract.
     */
    function pause() external onlyOwnerOrOperator {
        _pause();
    }

    /**
     * @dev Unpauses the contract.
     */
    function unpause() external onlyOwnerOrOperator {
        _unpause();
    }

    function increaseCurrentRoundId() external onlyOwnerOrOperator {
        factoryStorage.increaseIssuanceRoundId();
    }
}
