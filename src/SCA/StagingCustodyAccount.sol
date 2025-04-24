// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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
        address _indexFactoryAddress,
        address _indexFactroyStorageAddress,
        address _nexBotAddress,
        address _functionsOracle
    ) external initializer {
        __Ownable_init(msg.sender);

        crypto5FactoryAddress = _crypto5FactoryAddress;
        indexFactoryAddress = _indexFactoryAddress;
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

    function withdrawForPurchase(uint256 roundId) external onlyOwnerOrOperator nonReentrant {
        uint256 total = indexFactoryStorage.totalIssuanceByRound(roundId);
        require(total > 0, "Nothing to withdraw");
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        require(balance > 0, "USDC Balance is Zero!");
        IERC20(usdc).safeTransfer(nexBot, balance);
        emit WithdrawnForPurchase(roundId, balance, block.timestamp);
    }

    function rescue(address token, address to, uint256 amount) external onlyOwnerOrOperator {
        IERC20(token).safeTransfer(to, amount);
        emit Rescue(token, to, amount, block.timestamp);
    }

    function issuanceCrypto5(uint256 usdcAmount, address[] memory _tokenInPath, uint24[] memory _tokenInFees)
        public
        onlyOwnerOrOperator
    {
        ICrypto5Factory(crypto5FactoryAddress).issuanceIndexTokens(
            address(usdc), _tokenInPath, _tokenInFees, usdcAmount
        );
        // IndexFactory(indexFactoryAddress).increaseCurrentRoundId();
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

        // indexFactoryStorage.increaseCurrentRoundId();

        indexFactoryStorage.settleRound(roundId);

        emit TokensDistributed(roundId, mintAmount, distributed, block.timestamp);
    }
}
