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
        stagingCustodyAccount.recordDeposit(msg.sender, _inputAmount); // should change to quantityIn

        issuanceNonce++;
        indexFactoryStorage.setIssuanceInputAmount(issuanceNonce, _inputAmount);
        indexFactoryStorage.pushAddressToCurrentRound(msg.sender);

        emit RequestIssuance(issuanceNonce, msg.sender, address(usdc), _inputAmount, 0, block.timestamp);
        return issuanceNonce;
    }

    function cancelIssuance(uint256 _issuanceNonce) public whenNotPaused nonReentrant {
        require(!indexFactoryStorage.issuanceIsCompleted(_issuanceNonce), "Issuance is completed");
        address requester = indexFactoryStorage.issuanceRequesterByNonce(_issuanceNonce);
        require(msg.sender == requester, "Only requester can cancel the issuance");

        emit RequestCancelIssuance(
            _issuanceNonce,
            requester,
            address(usdc),
            indexFactoryStorage.issuanceInputAmount(_issuanceNonce),
            0,
            block.timestamp
        );
    }

    function redemption(uint256 _inputAmount) public nonReentrant whenNotPaused returns (uint256) {
        require(_inputAmount > 0, "Invalid input amount");
        redemptionNonce++;
        indexFactoryStorage.setRedemptionInputAmount(redemptionNonce, _inputAmount);
        // uint256 tokenBurnPercent = _inputAmount * 1e18 / indexToken.totalSupply();
        indexToken.burn(msg.sender, _inputAmount);
        indexFactoryStorage.setBurnedTokenAmountByNonce(redemptionNonce, _inputAmount);

        emit RequestRedemption(redemptionNonce, msg.sender, address(usdc), _inputAmount, 0, block.timestamp);
        return redemptionNonce;
    }

    function increaseCurrentRoundId() external {
        indexFactoryStorage.increaseCurrentRoundId();
    }
}
