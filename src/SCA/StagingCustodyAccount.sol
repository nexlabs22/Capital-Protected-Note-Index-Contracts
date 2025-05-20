// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ICrypto5Factory} from "../interfaces/ICrypto5Factory.sol";
import {IndexFactory} from "../factory/IndexFactory.sol";
import {IndexToken} from "../token/IndexToken.sol";
import {IndexFactoryStorage} from "../factory/IndexFactoryStorage.sol";
import {FunctionsOracle} from "../factory/FunctionsOracle.sol";
import {Vault} from "../vault/Vault.sol";

error ZeroAmount();
error ZeroAddress();
error RedemptionAmountIsZero();

contract StagingCustodyAccount is Initializable, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IndexToken indexToken;
    IndexFactoryStorage factoryStorage;
    FunctionsOracle public functionsOracle;
    IndexFactory factory;
    Vault public vault;
    IERC20 public usdc;
    address public crypto5FactoryAddress;
    address public indexFactoryAddress;
    address public nexBot;
    address public bond;

    event Rescue(address indexed token, address indexed to, uint256 amount, uint256 indexed timestamp);
    event WithdrawnForPurchase(uint256 indexed roundId, uint256 indexed amount, uint256 indexed timestamp);
    event TokensDistributed(
        uint256 indexed roundId, uint256 indexed indexTokenAmount, uint256 indexed usdcAmount, uint256 timestamp
    );
    event Refunded(address indexed to, uint256 indexed amount, uint256 timestamp);
    event IssuanceCrypto5(uint256 indexed amount, uint256 timestamp);
    event RedemptionCrpyto5(uint256 indexed amount, uint256 timestamp);
    event RedemptionSettled(uint256 indexed roundId, uint256 indexed amount, uint256 timestamp);

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || functionsOracle.isOperator(msg.sender) || msg.sender == nexBot,
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
        vault = Vault(factoryStorage.vault());
        indexToken = factoryStorage.indexToken();
        functionsOracle = factoryStorage.functionsOracle();
        factory = factoryStorage.indexFactory();
        usdc = factoryStorage.usdc();

        nexBot = factoryStorage.nexBot();
        crypto5FactoryAddress = factoryStorage.crypto5FactoryAddress();
        bond = factoryStorage.bond();

        // usdc = IERC20(_usdc);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function issuanceAndWithdrawForPurchase(
        uint256 roundId,
        address[] calldata _tokenInPath,
        uint24[] calldata _tokenInFees
    ) public onlyOwnerOrOperator {
        require(factoryStorage.issuanceRoundActive(roundId), "Round is not active");
        require(_allPreviousRoundsSettled(roundId), "A previous round is still unsettled");

        factoryStorage.setRedemptionRoundActive(roundId, false);
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "USDC Balance is Zero!");

        uint256 usdcAmountForBond;
        uint256 usdcAmountForCrypto5;

        for (uint256 i; i < functionsOracle.totalCurrentList(); ++i) {
            address token = functionsOracle.currentList(i);
            uint256 share = functionsOracle.tokenCurrentMarketShare(token);
            uint256 slice = (balance * share) / 100e18;

            if (functionsOracle.tokenAssetType(token) == 1) {
                usdcAmountForCrypto5 += slice;
            } else {
                usdcAmountForBond += slice;
            }
        }

        uint256 dust = balance - usdcAmountForCrypto5 - usdcAmountForBond;
        if (dust > 0) usdcAmountForBond += dust;

        if (usdcAmountForCrypto5 > 0) {
            issuanceCrypto5(usdcAmountForCrypto5, _tokenInPath, _tokenInFees);
        }

        if (usdcAmountForBond > 0) {
            withdrawForPurchase(roundId, usdcAmountForBond);
        }

        factory.increaseCurrentRoundId();
        factoryStorage.setRedemptionRoundActive(factoryStorage.issuanceRoundId(), true);
    }

    function withdrawForPurchase(uint256 roundId, uint256 amount) public onlyOwnerOrOperator nonReentrant {
        require(factoryStorage.totalIssuanceByRound(roundId) > 0, "Nothing to withdraw");
        if (amount == 0) revert ZeroAmount();

        IERC20(usdc).safeTransfer(nexBot, amount);
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

        usdc.safeTransfer(to, amount);
        emit Refunded(to, amount, block.timestamp);
    }

    function issuanceCrypto5(uint256 usdcAmount, address[] calldata _tokenInPath, uint24[] calldata _tokenInFees)
        public
        onlyOwnerOrOperator
    {
        ICrypto5Factory(crypto5FactoryAddress).issuanceIndexTokens(
            address(usdc), _tokenInPath, _tokenInFees, usdcAmount
        );
        emit IssuanceCrypto5(usdcAmount, block.timestamp);
    }

    function redemptionCrypto5(
        uint256 amountIn,
        address _tokenOut,
        address[] memory _tokenOutPath,
        uint24[] memory _tokenOutFees
    ) public onlyOwnerOrOperator {
        ICrypto5Factory(crypto5FactoryAddress).redemption(amountIn, _tokenOut, _tokenOutPath, _tokenOutFees);
        emit RedemptionCrpyto5(amountIn, block.timestamp);
    }

    function completeIssuance(uint256 roundId, uint256 bondPrice, uint256 crypto5Price) external onlyNexBot {
        require(roundId <= factoryStorage.issuanceRoundId(), "Invalid roundId");

        uint256 oldValue = getPortfolioValue(bondPrice, crypto5Price);

        for (uint256 i; i < functionsOracle.totalCurrentList(); i++) {
            address tokenAddress = functionsOracle.currentList(i);
            uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
            IERC20(tokenAddress).safeTransfer(address(factoryStorage.vault()), balance);
        }

        uint256 newValue = getPortfolioValue(bondPrice, crypto5Price);

        uint256 mintAmount = calculateMintAmount(oldValue, newValue);
        if (mintAmount > 0) indexToken.mint(address(this), mintAmount);

        address[] memory addrs = factoryStorage.addressesInRound(roundId);
        uint256 total = factoryStorage.totalIssuanceByRound(roundId);
        require(total > 0, "Nothing to distribute");

        uint256 distributed;
        for (uint256 i = 0; i < addrs.length; i++) {
            address user = addrs[i];
            uint256 owed = (mintAmount * factoryStorage.issuanceAmountByRoundUser(roundId, user)) / total;
            if (owed > 0) {
                indexToken.transfer(user, owed);
                distributed += owed;
            }
        }

        uint256 remainder = mintAmount - distributed;
        if (remainder > 0) {
            indexToken.transfer(factoryStorage.feeReceiver(), remainder);
        }

        factoryStorage.settleIssuance(roundId);

        emit TokensDistributed(roundId, mintAmount, distributed, block.timestamp);
    }

    function completeRedemption(uint256 roundId, uint256 usdcFromBond, uint256 usdcFromCr5) external onlyNexBot {
        if (factoryStorage.totalRedemptionByRound(roundId) == 0) {
            revert RedemptionAmountIsZero();
        }

        if (usdcFromBond > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), usdcFromBond);
        }

        uint256 totalUSDC = usdcFromBond + usdcFromCr5;
        require(totalUSDC > 0, "zero USDC received");

        address[] memory users = factoryStorage.addressesInRedemptionRound(roundId);

        uint256 totalIDX = factoryStorage.totalRedemptionByRound(roundId);
        uint256 paid;

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 idx = factoryStorage.redemptionAmountByRoundUser(roundId, user);
            uint256 owed = totalUSDC * idx / totalIDX;

            if (owed > 0) {
                usdc.safeTransfer(user, owed);
                paid += owed;
            }
        }

        uint256 dust = totalUSDC - paid;
        if (dust > 0) usdc.safeTransfer(factoryStorage.feeReceiver(), dust);

        factoryStorage.settleRedemption(roundId);

        emit RedemptionSettled(roundId, totalUSDC, block.timestamp);
    }

    function initiateRedemptionBatch(uint256 roundId, address[] calldata tokenOutPath, uint24[] calldata tokenOutFees)
        external
        nonReentrant
        onlyOwnerOrOperator
    {
        uint256 totalIdxThisRound = factoryStorage.totalRedemptionByRound(roundId);
        if (totalIdxThisRound == 0) revert RedemptionAmountIsZero();
        if (!factoryStorage.redemptionRoundActive(roundId)) {
            revert("batch not started");
        }
        // if (factoryStorage.redemptionRoundActive(roundId)) revert("batch already started");

        factoryStorage.setRedemptionRoundActive(roundId, false);

        uint256 supplyBefore = indexToken.totalSupply();
        uint256 pct1e18 = totalIdxThisRound * 1e18 / supplyBefore;

        // indexToken.burn(address(this), totalIdxThisRound);
        require(supplyBefore > totalIdxThisRound, "IDX supply is zero");

        uint256 nComps = functionsOracle.totalCurrentList();
        for (uint256 i; i < nComps; ++i) {
            address comp = functionsOracle.currentList(i);
            uint256 bal = IERC20(comp).balanceOf(address(vault));
            if (bal == 0) continue;

            uint256 slice = bal * pct1e18 / 1e18;
            if (slice > 0) {
                vault.withdrawFunds(comp, address(this), slice);
            }
        }

        uint256 bernBal = IERC20(bond).balanceOf(address(vault));
        uint256 bernSlice = bernBal * pct1e18 / 1e18;
        if (bernSlice > 0) {
            vault.withdrawFunds(bond, nexBot, bernSlice);
        }

        uint256 c5Amount = IERC20(address(indexToken)).balanceOf(address(this));
        if (c5Amount > 0) {
            redemptionCrypto5(c5Amount, address(usdc), tokenOutPath, tokenOutFees);
        }

        indexToken.burn(address(this), totalIdxThisRound);

        factoryStorage.increaseRedemptionRoundId();
        factoryStorage.setRedemptionRoundActive(factoryStorage.redemptionRoundId(), true);
    }

    function getPortfolioValue(uint256 bondPrice, uint256 crypto5Price) public view returns (uint256) {
        uint256 totalValue;

        uint256 bondBalance = IERC20(bond).balanceOf(address(vault));
        if (bondBalance > 0) {
            totalValue += (bondBalance * bondPrice) / 1e18;
        }

        uint256 totalToken = functionsOracle.totalCurrentList();
        if (totalToken > 1) {
            address Crypto5Token = functionsOracle.currentList(1);
            if (Crypto5Token != address(0)) {
                uint256 Crypto5Balance = IERC20(Crypto5Token).balanceOf(address(vault));
                if (Crypto5Balance != 0) {
                    totalValue += (Crypto5Balance * crypto5Price) / 1e18;
                }
            }
        }

        return totalValue;
    }

    function calculateMintAmount(uint256 oldValue, uint256 newValue) public view returns (uint256 mintAmount) {
        require(newValue > oldValue, "no NAV increase");

        uint256 supply = indexToken.totalSupply();

        if (supply == 0 || oldValue == 0) {
            return newValue;
        }

        uint256 deltaValue = newValue - oldValue;
        mintAmount = (supply * deltaValue) / oldValue;
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
