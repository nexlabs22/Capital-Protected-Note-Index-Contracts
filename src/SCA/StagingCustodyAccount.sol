// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IRiskAssetFactory} from "../interfaces/IRiskAssetFactory.sol";
import {IndexFactory} from "../factory/IndexFactory.sol";
import {IndexToken} from "../token/IndexToken.sol";
import {IndexFactoryStorage} from "../factory/IndexFactoryStorage.sol";
import {FunctionsOracle} from "../factory/FunctionsOracle.sol";
import {FeeCalculation} from "../libraries/FeeCalculation.sol";
import {Vault} from "../vault/Vault.sol";

error ZeroAmount();
error ZeroAddress();
error RedemptionAmountIsZero();

contract StagingCustodyAccount is Initializable, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IndexFactoryStorage factoryStorage;

    address public riskAssetFactoryAddress;
    address public indexFactoryAddress;
    address public nexBot;
    address public bond;

    event Rescue(address indexed token, address indexed to, uint256 amount, uint256 indexed timestamp);
    event WithdrawnForPurchase(uint256 indexed roundId, uint256 indexed amount, uint256 indexed timestamp);
    event Refunded(address indexed to, uint256 indexed amount, uint256 timestamp);
    event IssuanceRiskAsset(uint256 indexed amount, uint256 timestamp);
    event RedemptionRiskAsset(uint256 indexed amount, uint256 timestamp);
    event RedemptionSettled(uint256 indexed roundId, uint256 indexed amount, uint256 timestamp);
    event IssuanceSettled(
        uint256 indexed roundId,
        uint256 indexed indexTokenAmount,
        uint256 indexTokenDistributed,
        uint256 indexed usdcAmount,
        uint256 timestamp
    );
    event RedemptionRequested(uint256 indexed totalIdx, uint256 timestamp);
    event IssuanceRequested(uint256 indexed usdcForBond, uint256 indexed usdcForRiskAsset, uint256 timestamp);

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || factoryStorage.functionsOracle().isOperator(msg.sender) || msg.sender == nexBot,
            "Caller is not the owner or operator"
        );
        _;
    }

    modifier onlyNexBot() {
        require(msg.sender == nexBot, "Caller is not the NEX bot");
        _;
    }

    function initialize(address _indexFactroyStorageAddress) external initializer {
        require(_indexFactroyStorageAddress != address(0), "Invalid address for _indexFactroyStorageAddress");

        __Ownable_init(msg.sender);

        factoryStorage = IndexFactoryStorage(_indexFactroyStorageAddress);

        nexBot = factoryStorage.nexBot();
        riskAssetFactoryAddress = factoryStorage.riskAssetFactoryAddress();
        bond = factoryStorage.bond();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function withdrawForPurchase(uint256 roundId, uint256 amount) public onlyOwnerOrOperator nonReentrant {
        require(factoryStorage.totalIssuanceByRound(roundId) > 0, "Nothing to withdraw");
        if (amount == 0) revert ZeroAmount();

        IERC20(factoryStorage.usdc()).safeTransfer(nexBot, amount);
        emit WithdrawnForPurchase(roundId, amount, block.timestamp);
    }

    function rescue(address token, address to, uint256 amount) external onlyOwnerOrOperator {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);
        emit Rescue(token, to, amount, block.timestamp);
    }

    function refund(address to, uint256 amount) external onlyOwnerOrOperator {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // require(to != address(0) && amount > 0, "bad refund");

        factoryStorage.usdc().safeTransfer(to, amount);
        emit Refunded(to, amount, block.timestamp);
    }

    function issuanceRiskAsset(uint256 usdcAmount, address[] calldata _tokenInPath, uint24[] calldata _tokenInFees)
        public
        payable
        onlyOwnerOrOperator
    {
        require(msg.value > 0, "SCA: no ETH attached");
        IRiskAssetFactory(riskAssetFactoryAddress).issuanceIndexTokens{value: msg.value}(
            address(factoryStorage.usdc()), _tokenInPath, _tokenInFees, usdcAmount
        );
        emit IssuanceRiskAsset(usdcAmount, block.timestamp);
    }

    function redemptionRiskAsset(
        uint256 amountIn,
        address _tokenOut,
        address[] memory _tokenOutPath,
        uint24[] memory _tokenOutFees
    ) public payable onlyOwnerOrOperator {
        require(msg.value > 0, "SCA: no ETH");

        IRiskAssetFactory(riskAssetFactoryAddress).redemption{value: msg.value}(
            amountIn, _tokenOut, _tokenOutPath, _tokenOutFees
        );
        emit RedemptionRiskAsset(amountIn, block.timestamp);
    }

    function requestIssuance(uint256 roundId, address[] calldata _tokenInPath, uint24[] calldata _tokenInFees)
        public
        payable
        onlyOwnerOrOperator
    {
        require(roundId >= 1 && roundId <= factoryStorage.issuanceRoundId(), "Invalid roundId");
        uint256 prev = roundId - 1;
        if (roundId > 1) {
            require(!factoryStorage.issuanceRoundActive(prev), "Prev round still active");
            require(factoryStorage.issuanceIsCompleted(prev), "Prev round not completed");
        }
        require(factoryStorage.issuanceRoundActive(roundId), "Round is not active");
        require(!factoryStorage.issuanceIsCompleted(roundId), "Round already completed");
        // require(_allPreviousRoundsSettled(roundId), "A previous round is still unsettled");

        factoryStorage.setIssuancenRoundActive(roundId, false);
        uint256 balance = factoryStorage.usdc().balanceOf(address(this));
        require(balance > 0, "USDC Balance is Zero!");

        uint256 usdcAmountForBond;
        uint256 usdcAmountForRiskAsset;

        for (uint256 i; i < factoryStorage.functionsOracle().totalCurrentList(); ++i) {
            address token = factoryStorage.functionsOracle().currentList(i);
            uint256 share = factoryStorage.functionsOracle().tokenCurrentMarketShare(token);
            uint256 slice = (balance * share) / 100e18;

            if (factoryStorage.functionsOracle().tokenAssetType(token) == 1) {
                usdcAmountForRiskAsset += slice;
            } else {
                usdcAmountForBond += slice;
            }
        }

        uint256 dust = balance - usdcAmountForRiskAsset - usdcAmountForBond;
        if (dust > 0) usdcAmountForBond += dust;

        if (usdcAmountForRiskAsset > 0) {
            uint256 fee = factoryStorage.getIssuanceFee(
                address(factoryStorage.usdc()), _tokenInPath, _tokenInFees, usdcAmountForRiskAsset
            );
            require(msg.value == fee, "SCA: wrong ETH fee");
            issuanceRiskAsset(usdcAmountForRiskAsset, _tokenInPath, _tokenInFees);
        } else {
            require(msg.value == 0, "SCA: unexpected ETH");
        }

        if (usdcAmountForBond > 0) {
            withdrawForPurchase(roundId, usdcAmountForBond);
        }

        factoryStorage.indexFactory().increaseCurrentRoundId();
        factoryStorage.setRedemptionRoundActive(factoryStorage.issuanceRoundId(), true);

        emit IssuanceRequested(usdcAmountForBond, usdcAmountForRiskAsset, block.timestamp);
    }

    function completeIssuance(uint256 roundId, uint256 bondPrice, uint256 riskAssetPrice) external onlyNexBot {
        require(roundId <= factoryStorage.issuanceRoundId(), "Invalid roundId");
        require(roundId >= 1 && roundId <= factoryStorage.issuanceRoundId(), "Invalid roundId");
        uint256 prev = roundId - 1;
        if (roundId > 1) {
            require(!factoryStorage.issuanceRoundActive(prev), "Prev round still active");
            require(factoryStorage.issuanceIsCompleted(prev), "Prev round not completed");
        }
        require(!factoryStorage.issuanceRoundActive(roundId), "Round is active");
        require(!factoryStorage.issuanceIsCompleted(roundId), "Round already completed");

        uint256 oldValue = factoryStorage.getPortfolioValue(bondPrice, riskAssetPrice);

        for (uint256 i; i < factoryStorage.functionsOracle().totalCurrentList(); i++) {
            address tokenAddress = factoryStorage.functionsOracle().currentList(i);
            uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
            IERC20(tokenAddress).safeTransfer(address(factoryStorage.vault()), balance);
        }

        uint256 newValue = factoryStorage.getPortfolioValue(bondPrice, riskAssetPrice);

        uint256 mintAmount = factoryStorage.calculateMintAmount(oldValue, newValue);
        if (mintAmount > 0) factoryStorage.indexToken().mint(address(this), mintAmount);

        address[] memory addrs = factoryStorage.addressesInIssuanceRound(roundId);
        uint256 total = factoryStorage.totalIssuanceByRound(roundId);
        require(total > 0, "Nothing to distribute");

        uint256 distributed;
        for (uint256 i = 0; i < addrs.length; i++) {
            address user = addrs[i];
            uint256 owed = (mintAmount * factoryStorage.issuanceAmountByRoundUser(roundId, user)) / total;
            if (owed > 0) {
                factoryStorage.indexToken().transfer(user, owed);
                distributed += owed;
            }
        }

        uint256 remainder = mintAmount - distributed;
        if (remainder > 0) {
            factoryStorage.indexToken().transfer(factoryStorage.feeReceiver(), remainder);
        }

        factoryStorage.settleIssuance(roundId);

        emit IssuanceSettled(roundId, mintAmount, distributed, total, block.timestamp);
    }

    function completeRedemption(uint256 roundId, uint256 usdcFromBond, uint256 usdcFromRiskAsset) external onlyNexBot {
        require(roundId >= 1 && roundId <= factoryStorage.redemptionRoundId(), "Invalid roundId");
        uint256 prev = roundId - 1;
        if (roundId > 1) {
            require(!factoryStorage.redemptionRoundActive(prev), "Prev redemption round active");
            require(factoryStorage.redemptionIsCompleted(prev), "Prev redemption not completed");
        }
        require(!factoryStorage.redemptionRoundActive(roundId), "Round still active");
        require(!factoryStorage.redemptionIsCompleted(roundId), "Round already completed");

        if (factoryStorage.totalRedemptionByRound(roundId) == 0) {
            revert RedemptionAmountIsZero();
        }

        if (usdcFromBond > 0) {
            factoryStorage.usdc().safeTransferFrom(msg.sender, address(this), usdcFromBond);
        }

        uint256 totalUSDC = usdcFromBond + usdcFromRiskAsset;
        require(totalUSDC > 0, "zero USDC received");
        uint256 feeAmount = FeeCalculation.calculateFee(totalUSDC, factoryStorage.feeRate());
        uint256 usdcForDistribute = totalUSDC - feeAmount;

        address[] memory users = factoryStorage.addressesInRedemptionRound(roundId);

        uint256 totalIDX = factoryStorage.totalRedemptionByRound(roundId);
        uint256 paid;

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 idx = factoryStorage.redemptionAmountByRoundUser(roundId, user);
            uint256 owed = usdcForDistribute * idx / totalIDX;

            if (owed > 0) {
                factoryStorage.usdc().safeTransfer(user, owed);
                paid += owed;
            }
        }

        uint256 dust = usdcForDistribute - paid;
        if (dust > 0) factoryStorage.usdc().safeTransfer(factoryStorage.feeReceiver(), dust);
        factoryStorage.usdc().safeTransfer(factoryStorage.feeReceiver(), feeAmount);

        factoryStorage.settleRedemption(roundId);

        emit RedemptionSettled(roundId, usdcForDistribute, block.timestamp);
    }

    function requestRedemption(uint256 roundId, address[] calldata tokenOutPath, uint24[] calldata tokenOutFees)
        external
        payable
        nonReentrant
        onlyOwnerOrOperator
    {
        require(roundId >= 1 && roundId <= factoryStorage.redemptionRoundId(), "Invalid roundId");
        uint256 prev = roundId - 1;
        if (roundId > 1) {
            require(!factoryStorage.redemptionRoundActive(prev), "Prev redemption round active");
            require(factoryStorage.redemptionIsCompleted(prev), "Prev redemption not completed");
        }
        require(factoryStorage.redemptionRoundActive(roundId), "Round not active");
        require(!factoryStorage.redemptionIsCompleted(roundId), "Round already completed");

        uint256 totalIdxThisRound = factoryStorage.totalRedemptionByRound(roundId);
        if (totalIdxThisRound == 0) revert RedemptionAmountIsZero();
        if (!factoryStorage.redemptionRoundActive(roundId)) {
            revert("batch not started");
        }

        factoryStorage.setRedemptionRoundActive(roundId, false);

        uint256 supplyBefore = factoryStorage.indexToken().totalSupply();
        uint256 pct1e18 = totalIdxThisRound * 1e18 / supplyBefore;

        require(supplyBefore > totalIdxThisRound, "IDX supply is zero");

        uint256 nComps = factoryStorage.functionsOracle().totalCurrentList();
        for (uint256 i; i < nComps; ++i) {
            address comp = factoryStorage.functionsOracle().currentList(i);
            uint256 bal = IERC20(comp).balanceOf(address(factoryStorage.vault()));
            if (bal == 0) continue;

            uint256 slice = bal * pct1e18 / 1e18;
            if (slice > 0) {
                factoryStorage.vault().withdrawFunds(comp, address(this), slice);
            }
        }

        uint256 bernBal = IERC20(bond).balanceOf(address(factoryStorage.vault()));
        uint256 bernSlice = bernBal * pct1e18 / 1e18;
        if (bernSlice > 0) {
            factoryStorage.vault().withdrawFunds(bond, nexBot, bernSlice);
        }

        uint256 c5Amount = IERC20(address(factoryStorage.indexToken())).balanceOf(address(this));
        if (c5Amount > 0) {
            uint256 fee = factoryStorage.getRedemptionFee(c5Amount);
            require(msg.value == fee, "SCA: wrong ETH fee");
            redemptionRiskAsset(c5Amount, address(factoryStorage.usdc()), tokenOutPath, tokenOutFees);
        }

        factoryStorage.indexToken().burn(address(this), totalIdxThisRound);

        factoryStorage.increaseRedemptionRoundId();
        factoryStorage.setRedemptionRoundActive(factoryStorage.redemptionRoundId(), true);

        emit RedemptionRequested(totalIdxThisRound, block.timestamp);
    }

    function _allPreviousRoundsSettled(uint256 roundId) internal view returns (bool) {
        if (roundId <= 1) return true;
        for (uint256 i = 1; i < roundId; ++i) {
            if (factoryStorage.issuanceRoundActive(i)) {
                return false;
            }
        }
        return true;
    }
}
