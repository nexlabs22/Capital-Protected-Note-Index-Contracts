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

contract StagingCustodyAccount is Initializable, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IndexToken indexToken;
    IndexFactoryStorage indexFactoryStorage;
    FunctionsOracle public functionsOracle;
    IndexFactory factory;
    IERC20 public usdc;
    uint256 public depositCounter;
    uint256 public withdrawCounter;
    address public crypto5FactoryAddress;
    address public indexFactoryAddress;
    address public nexBot;

    event Rescue(address indexed token, address indexed to, uint256 amount, uint256 indexed timestamp);
    event WithdrawnForPurchase(uint256 indexed roundId, uint256 indexed amount, uint256 indexed timestamp);
    event TokensDistributed(
        uint256 indexed roundId, uint256 indexed indexTokenAmount, uint256 indexed usdcAmount, uint256 timestamp
    );

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

    function initialize(
        address _indexToken,
        address _factory,
        address _crypto5FactoryAddress,
        address _usdc,
        address _indexFactroyStorageAddress,
        address _nexBotAddress,
        address _functionsOracle
    ) external initializer {
        __Ownable_init(msg.sender);

        crypto5FactoryAddress = _crypto5FactoryAddress;
        nexBot = _nexBotAddress;
        factory = IndexFactory(_factory);
        indexFactoryStorage = IndexFactoryStorage(_indexFactroyStorageAddress);
        functionsOracle = FunctionsOracle(_functionsOracle);
        indexToken = IndexToken(_indexToken);
        usdc = IERC20(_usdc);
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
        require(indexFactoryStorage.roundIdIsActive(roundId), "Round is not active");
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
        require(indexFactoryStorage.totalIssuanceByRound(roundId) > 0, "Nothing to withdraw");
        require(amount > 0, "zero amount");

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
        require(roundId <= indexFactoryStorage.currentRoundId(), "Invalid roundId");
        for (uint256 i; i < functionsOracle.totalCurrentList(); i++) {
            address tokenAddress = functionsOracle.currentList(i);
            uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
            IERC20(tokenAddress).safeTransfer(indexFactoryStorage.nexVault(), balance);
        }

        address[] memory addrs = indexFactoryStorage.addressesInRound(roundId);
        uint256 total = indexFactoryStorage.totalIssuanceByRound(roundId);
        require(total > 0, "Nothing to distribute");

        indexToken.mint(address(this), mintAmount);

        uint256 distributed;
        for (uint256 i = 0; i < addrs.length; i++) {
            address user = addrs[i];
            uint256 owed = (mintAmount * indexFactoryStorage.issuanceAmountByRoundUser(roundId, user)) / total;
            if (owed > 0) {
                indexToken.transfer(user, owed);
                distributed += owed;
            }
        }

        uint256 remainder = mintAmount - distributed;
        if (remainder > 0) {
            indexToken.transfer(indexFactoryStorage.feeReceiver(), remainder);
        }

        indexFactoryStorage.settleIssuance(roundId);

        emit TokensDistributed(roundId, mintAmount, distributed, block.timestamp);
    }

    function settleRedemption(uint256 roundId, uint256 usdcReceived) external onlyNexBot {
        require(indexFactoryStorage.totalRedemptionByRound(roundId) > 0, "nothing to settle");

        usdc.safeTransferFrom(msg.sender, address(this), usdcReceived);

        address[] memory users = indexFactoryStorage.addressesInRound(roundId);
        uint256 total = indexFactoryStorage.totalRedemptionByRound(roundId);
        uint256 distributed;

        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            uint256 share = indexFactoryStorage.redemptionAmountByRoundUser(roundId, user);
            uint256 owed = usdcReceived * share / total;
            if (owed > 0) {
                usdc.safeTransfer(user, owed);
                indexToken.burn(address(this), share);
                distributed += owed;
            }
        }

        indexFactoryStorage.settleRedemption(roundId);
    }

    function _allPreviousRoundsSettled(uint256 roundId) internal view returns (bool) {
        if (roundId <= 1) return true;
        for (uint256 i = 1; i < roundId; ++i) {
            if (indexFactoryStorage.roundIdIsActive(i)) {
                return false;
            }
        }
        return true;
    }
}
