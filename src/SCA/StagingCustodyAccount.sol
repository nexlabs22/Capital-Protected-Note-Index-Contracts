// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
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
    address public bernx;

    event Rescue(address indexed token, address indexed to, uint256 amount, uint256 indexed timestamp);
    event WithdrawnForPurchase(uint256 indexed roundId, uint256 indexed amount, uint256 indexed timestamp);
    event TokensDistributed(
        uint256 indexed roundId, uint256 indexed indexTokenAmount, uint256 indexed usdcAmount, uint256 timestamp
    );
    event Refunded(address indexed to, uint256 indexed amount, uint256 timestamp);

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
        __Ownable_init(msg.sender);

        factoryStorage = IndexFactoryStorage(_indexFactroyStorageAddress);
        vault = Vault(factoryStorage.vault());
        indexToken = factoryStorage.indexToken();
        functionsOracle = factoryStorage.functionsOracle();
        factory = factoryStorage.indexFactory();
        usdc = factoryStorage.usdc();

        nexBot = factoryStorage.nexBot();
        crypto5FactoryAddress = factoryStorage.crypto5FactoryAddress();
        bernx = factoryStorage.bernx();

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
        require(factoryStorage.roundIdIsActive(roundId), "Round is not active");
        require(_allPreviousRoundsSettled(roundId), "A previous round is still unsettled");
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "USDC Balance is Zero!");
        uint256 amount20 = (balance * 20) / 100;
        uint256 amount80 = balance - amount20;
        issuanceCrypto5(amount20, _tokenInPath, _tokenInFees);
        withdrawForPurchase(roundId, amount80);
        factory.increaseCurrentRoundId();
    }

    function withdrawForPurchase(uint256 roundId, uint256 amount) public onlyOwnerOrOperator nonReentrant {
        require(factoryStorage.totalIssuanceByRound(roundId) > 0, "Nothing to withdraw");
        if (amount <= 0) revert ZeroAmount();
        // require(amount > 0, "zero amount");

        IERC20(usdc).safeTransfer(nexBot, amount);
        emit WithdrawnForPurchase(roundId, amount, block.timestamp);
    }

    function rescue(address token, address to, uint256 amount) external onlyOwnerOrOperator {
        IERC20(token).safeTransfer(to, amount);
        emit Rescue(token, to, amount, block.timestamp);
    }

    function refund(address to, uint256 amount) external onlyOwnerOrOperator {
        require(to != address(0) && amount > 0, "bad refund");
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
    }

    function redemptionCrypto5(
        uint256 amountIn,
        address _tokenOut,
        address[] memory _tokenOutPath,
        uint24[] memory _tokenOutFees
    ) public onlyOwnerOrOperator {
        ICrypto5Factory(crypto5FactoryAddress).redemption(amountIn, _tokenOut, _tokenOutPath, _tokenOutFees);
    }

    function distributeTokens(uint256 mintAmount, uint256 roundId) external onlyNexBot {
        require(roundId <= factoryStorage.currentRoundId(), "Invalid roundId");
        for (uint256 i; i < functionsOracle.totalCurrentList(); i++) {
            address tokenAddress = functionsOracle.currentList(i);
            uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
            IERC20(tokenAddress).safeTransfer(address(factoryStorage.vault()), balance);
        }

        address[] memory addrs = factoryStorage.addressesInRound(roundId);
        uint256 total = factoryStorage.totalIssuanceByRound(roundId);
        require(total > 0, "Nothing to distribute");

        indexToken.mint(address(this), mintAmount);

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

    function settleRedemption(uint256 roundId, uint256 usdcFromBernx, uint256 usdcFromCr5) external onlyNexBot {
        require(factoryStorage.totalRedemptionByRound(roundId) > 0, "nothing to settle");
        require(factoryStorage.redemptionRoundActive(roundId), "batch not started or already settled");

        if (usdcFromBernx > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), usdcFromBernx);
        }

        uint256 totalUSDC = usdcFromBernx + usdcFromCr5;
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
                indexToken.burn(address(this), idx);
                paid += owed;
            }
        }

        uint256 dust = totalUSDC - paid;
        if (dust > 0) usdc.safeTransfer(factoryStorage.feeReceiver(), dust);

        factoryStorage.settleRedemption(roundId);
    }

    function initiateRedemptionBatch(uint256 roundId, address[] calldata tokenOutPath, uint24[] calldata tokenOutFees)
        external
        onlyOwnerOrOperator
    {
        require(factoryStorage.totalRedemptionByRound(roundId) > 0, "redemption round empty");
        require(!factoryStorage.redemptionRoundActive(roundId), "batch already started");
        factoryStorage.setRedemptionRoundActive(roundId, true);

        uint256 pct1e18 = factoryStorage.totalRedemptionByRound(roundId) * 1e18 / indexToken.totalSupply();

        uint256 totalCurrentList = functionsOracle.totalCurrentList();
        for (uint256 i; i < totalCurrentList; ++i) {
            address comp = functionsOracle.currentList(i);
            uint256 balance = IERC20(comp).balanceOf(address(vault));
            if (balance == 0) continue;

            uint256 slice = balance * pct1e18 / 1e18;
            if (slice > 0) {
                vault.withdrawFunds(comp, address(this), slice);
            }
        }

        uint256 bernBalance = IERC20(bernx).balanceOf(address(vault));
        uint256 bernSlice = bernBalance * pct1e18 / 1e18;
        if (bernSlice > 0) {
            vault.withdrawFunds(bernx, nexBot, bernSlice);
        }

        uint256 cr5Amount = IERC20(address(indexToken)).balanceOf(address(this));
        if (cr5Amount > 0) {
            redemptionCrypto5(cr5Amount, address(usdc), tokenOutPath, tokenOutFees);
        }
    }

    function _allPreviousRoundsSettled(uint256 roundId) internal view returns (bool) {
        if (roundId <= 1) return true;
        for (uint256 i = 1; i < roundId; ++i) {
            if (factoryStorage.roundIdIsActive(i)) {
                return false;
            }
        }
        return true;
    }
}
