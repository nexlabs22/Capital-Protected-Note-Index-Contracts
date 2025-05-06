// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IndexFactory} from "../factory/IndexFactory.sol";
import {FunctionsOracle} from "../factory/FunctionsOracle.sol";
import {IndexToken} from "../token/IndexToken.sol";
import {Vault} from "../vault/Vault.sol";
import {StagingCustodyAccount} from "../SCA/StagingCustodyAccount.sol";

error InvalidAddress();
error ZeroAmount();
error UnsettledRound(uint256 previousRoundId);

contract IndexFactoryStorage is Initializable, OwnableUpgradeable {
    IndexToken public indexToken;
    Vault public vault;
    IndexFactory public indexFactory;
    FunctionsOracle public functionsOracle;
    StagingCustodyAccount public sca;
    IERC20 public usdc;

    address public bernx;
    address public crypto5FactoryAddress;
    address public feeReceiver;
    uint256 public feeRate;
    uint256 public currentRoundId;
    uint256 public redemptionRoundId;
    address public nexBot;
    bool public isMainnet;

    mapping(uint256 => bool) public issuanceIsCompleted;
    mapping(uint256 => address) public issuanceRequesterByNonce;
    mapping(uint256 => uint256) public issuanceInputAmount;
    mapping(uint256 => uint256) public redemptionInputAmount;
    mapping(uint256 => uint256) public burnedTokenAmountByNonce;
    mapping(uint256 => address[]) private roundIdToAddresses;
    mapping(uint256 => mapping(address => uint256)) public issuanceAmountByRoundUser;
    mapping(uint256 => uint256) public totalIssuanceByRound;
    mapping(uint256 => bool) public roundIdIsActive;
    mapping(uint256 => mapping(address => uint256)) public redemptionAmountByRoundUser;
    mapping(uint256 => uint256) public totalRedemptionByRound;
    mapping(uint256 => bool) public redemptionRoundActive;
    mapping(uint256 => bool) public redemptionRoundCompleted;
    mapping(uint256 => address[]) public redemptionAddrs;

    event IssuanceSettled(uint256 indexed roundId);
    event RedemptionSettled(uint256 indexed roundId);

    modifier onlyFactory() {
        require(msg.sender == address(indexFactory) || msg.sender == nexBot, "Caller is not a factory contract");
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || functionsOracle.isOperator(msg.sender) || msg.sender == nexBot,
            "Caller is not the owner or operator"
        );
        _;
    }

    function initialize(
        address _indexToken,
        address _indexFactory,
        address _functionsOracle,
        address _stagingCustodyAccount,
        address _vault,
        address _nexBot,
        address _crypto5FactoryAddress,
        address _usdc,
        bool _isMainnet
    ) external initializer {
        require(_indexToken != address(0), "Invalid IndexToken address");
        require(_indexFactory != address(0), "Invalid IndexFactory address");
        require(_functionsOracle != address(0), "Invalid FunctionsOracle address");
        require(_stagingCustodyAccount != address(0), "Invalid StagingCustodyAccount address");
        require(_vault != address(0), "Invalid Vault address");
        require(_nexBot != address(0), "Invalid NexBot address");

        __Ownable_init(msg.sender);

        indexToken = IndexToken(_indexToken);
        indexFactory = IndexFactory(_indexFactory);
        functionsOracle = FunctionsOracle(_functionsOracle);
        sca = StagingCustodyAccount(_stagingCustodyAccount);
        vault = Vault(_vault);
        usdc = IERC20(_usdc);

        crypto5FactoryAddress = _crypto5FactoryAddress;
        nexBot = _nexBot;
        isMainnet = _isMainnet;
        currentRoundId = 1;
        redemptionRoundId = 1;
        feeRate = 10;
        feeReceiver = msg.sender;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function setNexBotAddress(address _newNexBotAddress) public onlyOwner {
        if (_newNexBotAddress == address(0)) revert InvalidAddress();
        // require(_newNexBotAddress != address(0), "invalid Nex Bot address");
        nexBot = _newNexBotAddress;
    }

    function setSCA(address _sca) external onlyOwner {
        if (_sca == address(0)) revert InvalidAddress();
        // require(address(sca) == address(0), "SCA already set");
        require(_sca != address(0), "zero");
        sca = StagingCustodyAccount(_sca);
    }

    function setFeeReceiver(address _feeReceiver) public onlyOwner {
        if (_feeReceiver == address(0)) revert InvalidAddress();
        // require(_feeReceiver != address(0), "invalid fee receiver address");
        feeReceiver = _feeReceiver;
    }

    function setIssuanceInputAmount(uint256 _issuanceNonce, uint256 _amount) external onlyFactory {
        if (_amount == 0) revert ZeroAmount();
        // require(_amount > 0, "Invalid issuance input amount");
        issuanceInputAmount[_issuanceNonce] = _amount;
    }

    function setRedemptionInputAmount(uint256 _redemptionNonce, uint256 _amount) external onlyFactory {
        if (_amount == 0) revert ZeroAmount();
        // require(_amount > 0, "Invalid redemption input amount");
        redemptionInputAmount[_redemptionNonce] = _amount;
    }

    function setBurnedTokenAmountByNonce(uint256 _redemptionNonce, uint256 _burnedAmount) external onlyFactory {
        if (_burnedAmount == 0) revert ZeroAmount();
        // require(_burnedAmount > 0, "Invalid burn amount");
        burnedTokenAmountByNonce[_redemptionNonce] = _burnedAmount;
    }

    function setRoundIdToAddresses(uint256 _roundId, address[] memory addresses) external onlyFactory {
        require(_roundId > 0, "Invalid roundId amount");
        roundIdToAddresses[_roundId] = addresses;
    }

    function setIssuanceCompleted(uint256 nonce, bool flag) external onlyFactory {
        issuanceIsCompleted[nonce] = flag;
    }

    function increaseCurrentRoundId() external onlyFactory {
        currentRoundId++;
    }

    function setRedemptionRoundActive(uint256 roundId, bool flag) external onlyFactory {
        redemptionRoundActive[roundId] = flag;
    }

    function addIssuanceForCurrentRound(address account, uint256 amount) external onlyFactory {
        if (!roundIdIsActive[currentRoundId]) {
            roundIdIsActive[currentRoundId] = true;
        }

        if (issuanceAmountByRoundUser[currentRoundId][account] == 0) {
            roundIdToAddresses[currentRoundId].push(account);
        }
        issuanceAmountByRoundUser[currentRoundId][account] += amount;
        totalIssuanceByRound[currentRoundId] += amount;
    }

    function addRedemptionForCurrentRound(address user, uint256 amount) external onlyFactory {
        uint256 roundId = redemptionRoundId;

        if (!roundIdIsActive[roundId]) roundIdIsActive[roundId] = true;

        if (redemptionAmountByRoundUser[roundId][user] == 0) {
            redemptionAddrs[roundId].push(user);
        }

        redemptionAmountByRoundUser[roundId][user] += amount;
        totalRedemptionByRound[roundId] += amount;
    }

    function addressesInRedemptionRound(uint256 roundId) external view returns (address[] memory) {
        return redemptionAddrs[roundId];
    }

    function addressesInRound(uint256 roundId) external view returns (address[] memory) {
        return roundIdToAddresses[roundId];
    }

    function getRedemptionRoundActive(uint256 roundId) external view returns (bool) {
        return redemptionRoundActive[roundId];
    }

    function setIssuanceRequesterByNonce(uint256 nonce, address requester) external onlyFactory {
        issuanceRequesterByNonce[nonce] = requester;
    }

    function undoIssuance(address account, uint256 amount) external onlyFactory {
        uint256 round = currentRoundId;

        uint256 before = issuanceAmountByRoundUser[round][account];
        require(before >= amount && amount > 0, "bad amount");

        issuanceAmountByRoundUser[round][account] = before - amount;
        totalIssuanceByRound[round] -= amount;

        if (issuanceAmountByRoundUser[round][account] == 0) {
            address[] storage arr = roundIdToAddresses[round];
            for (uint256 i; i < arr.length; ++i) {
                if (arr[i] == account) {
                    arr[i] = arr[arr.length - 1];
                    arr.pop();
                    break;
                }
            }
            if (arr.length == 0) {
                roundIdIsActive[round] = false;
            }
        }
    }

    function undoRedemption(address user, uint256 amount) external onlyFactory {
        uint256 roundId = currentRoundId;
        uint256 before = redemptionAmountByRoundUser[roundId][user];
        require(amount > 0 && before >= amount, "bad amount");

        redemptionAmountByRoundUser[roundId][user] = before - amount;
        totalRedemptionByRound[roundId] -= amount;

        if (redemptionAmountByRoundUser[roundId][user] == 0) {
            _pruneAddress(roundId, user);
        }
    }

    function settleIssuance(uint256 roundId) external onlyOwnerOrOperator {
        address[] storage list = roundIdToAddresses[roundId];
        for (uint256 i = 0; i < list.length; ++i) {
            delete issuanceAmountByRoundUser[roundId][list[i]];
        }
        delete roundIdToAddresses[roundId];

        delete totalIssuanceByRound[roundId];

        issuanceIsCompleted[roundId] = true;
        roundIdIsActive[roundId] = false;

        emit IssuanceSettled(roundId);
    }

    function settleRedemption(uint256 roundId) external onlyOwnerOrOperator {
        address[] storage list = redemptionAddrs[roundId];
        for (uint256 i = 0; i < list.length; ++i) {
            delete redemptionAmountByRoundUser[roundId][list[i]];
        }
        delete redemptionAddrs[roundId];
        delete totalRedemptionByRound[roundId];

        redemptionRoundCompleted[roundId] = true;
        redemptionRoundActive[roundId] = false;
        emit RedemptionSettled(roundId);

        ++redemptionRoundId;
    }

    function _pruneAddress(uint256 round, address user) internal {
        address[] storage arr = roundIdToAddresses[round];
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == user) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
        if (arr.length == 0) roundIdIsActive[round] = false;
    }

    function nextProcessableRoundId() external view returns (uint256) {
        uint256 id = currentRoundId;
        for (uint256 i = 1; i < id; ++i) {
            if (roundIdIsActive[i]) {
                revert UnsettledRound(i);
            }
        }
        return id;
    }

    uint256[45] private __gap;
}
