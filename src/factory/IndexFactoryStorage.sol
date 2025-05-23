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

    address public bond;
    address public crypto5FactoryAddress;
    address public feeReceiver;
    uint8 public feeRate;
    uint256 public issuanceRoundId;
    uint256 public redemptionRoundId;
    address public nexBot;
    bool public isMainnet;

    mapping(uint256 => bool) public issuanceIsCompleted;
    mapping(uint256 => bool) public redemptionIsCompleted;
    mapping(uint256 => address) public issuanceRequesterByNonce;
    mapping(uint256 => address) public redemptionRequesterByNonce;
    mapping(uint256 => uint256) public issuanceInputAmount;
    mapping(uint256 => uint256) public redemptionInputAmount;
    mapping(uint256 => uint256) public burnedTokenAmountByNonce;
    mapping(uint256 => address[]) public issuanceRoundIdToAddresses;
    mapping(uint256 => address[]) public redemptionRoundIdToAddresses;
    mapping(uint256 => mapping(address => uint256)) public issuanceAmountByRoundUser;
    mapping(uint256 => mapping(address => uint256)) public redemptionAmountByRoundUser;
    mapping(uint256 => uint256) public totalIssuanceByRound;
    mapping(uint256 => uint256) public totalRedemptionByRound;
    mapping(uint256 => bool) public issuanceRoundActive;
    mapping(uint256 => bool) public redemptionRoundActive;
    mapping(uint256 => uint256) public roundIdToBondAmount;
    mapping(uint256 => uint256) public roundIdToCrypto5Amount;
    mapping(uint256 => uint256[]) public issuanceRoundIdToNonces;
    mapping(uint256 => uint256[]) public redemptionRoundIdToNonces;

    event IssuanceSettled(uint256 indexed roundId);
    event RedemptionSettled(uint256 indexed roundId);

    modifier onlyFactory() {
        require(
            msg.sender == address(indexFactory) || msg.sender == nexBot || msg.sender == address(sca),
            "Caller is not a factory contract"
        );
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
        address _bond,
        bool _isMainnet
    ) external initializer {
        require(_indexToken != address(0), "Invalid _indexToken address");
        require(_indexFactory != address(0), "Invalid _indexFactory address");
        require(_functionsOracle != address(0), "Invalid _functionsOracle address");
        require(_stagingCustodyAccount != address(0), "Invalid _stagingCustodyAccount address");
        require(_vault != address(0), "Invalid _vault address");
        require(_nexBot != address(0), "Invalid _nexBot address");
        require(_crypto5FactoryAddress != address(0), "Invalid _crypto5FactoryAddress address");
        require(_usdc != address(0), "Invalid _usdc address");
        require(_bond != address(0), "Invalid _bond address");

        __Ownable_init(msg.sender);

        indexToken = IndexToken(_indexToken);
        indexFactory = IndexFactory(_indexFactory);
        functionsOracle = FunctionsOracle(_functionsOracle);
        sca = StagingCustodyAccount(_stagingCustodyAccount);
        vault = Vault(_vault);
        usdc = IERC20(_usdc);
        bond = _bond;

        crypto5FactoryAddress = _crypto5FactoryAddress;
        nexBot = _nexBot;
        isMainnet = _isMainnet;
        issuanceRoundId = 1;
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
        nexBot = _newNexBotAddress;
    }

    function setSCA(address _sca) external onlyOwner {
        if (_sca == address(0)) revert InvalidAddress();
        require(_sca != address(0), "zero");
        sca = StagingCustodyAccount(_sca);
    }

    function setFeeReceiver(address _feeReceiver) public onlyOwner {
        if (_feeReceiver == address(0)) revert InvalidAddress();
        feeReceiver = _feeReceiver;
    }

    // function setBondAmountByRoundId(uint256 _roundId, uint256 _amount) external onlyFactory {
    //     if (_amount == 0) revert ZeroAmount();
    //     roundIdToBondAmount[_roundId] = _amount;
    // }

    // function setCrypto5AmountByRoundId(uint256 _roundId, uint256 _amount) external onlyFactory {
    //     if (_amount == 0) revert ZeroAmount();
    //     roundIdToCrypto5Amount[_roundId] = _amount;
    // }

    function setIssuanceInputAmount(uint256 _issuanceNonce, uint256 _amount) external onlyFactory {
        if (_amount == 0) revert ZeroAmount();
        issuanceInputAmount[_issuanceNonce] = _amount;
    }

    function setRedemptionInputAmount(uint256 _redemptionNonce, uint256 _amount) external onlyFactory {
        if (_amount == 0) revert ZeroAmount();
        redemptionInputAmount[_redemptionNonce] = _amount;
    }

    // function setBurnedTokenAmountByNonce(uint256 _redemptionNonce, uint256 _burnedAmount) external onlyFactory {
    //     if (_burnedAmount == 0) revert ZeroAmount();
    //     burnedTokenAmountByNonce[_redemptionNonce] = _burnedAmount;
    // }

    function setIssuanceRoundIdToAddresses(uint256 _roundId, address[] memory addresses) external onlyFactory {
        require(_roundId > 0, "Invalid roundId amount");
        issuanceRoundIdToAddresses[_roundId] = addresses;
    }

    function setIssuanceCompleted(uint256 nonce, bool flag) external onlyFactory {
        issuanceIsCompleted[nonce] = flag;
    }

    function setRedemptionCompleted(uint256 nonce, bool flag) external onlyFactory {
        redemptionIsCompleted[nonce] = flag;
    }

    function increaseIssuanceRoundId() external onlyFactory {
        issuanceRoundId++;
    }

    function increaseRedemptionRoundId() external onlyFactory {
        redemptionRoundId++;
    }

    function setRedemptionRoundActive(uint256 roundId, bool flag) external onlyFactory {
        redemptionRoundActive[roundId] = flag;
    }

    function addIssuanceForCurrentRound(address account, uint256 amount) external onlyFactory {
        if (!issuanceRoundActive[issuanceRoundId]) {
            issuanceRoundActive[issuanceRoundId] = true;
        }

        if (issuanceAmountByRoundUser[issuanceRoundId][account] == 0) {
            issuanceRoundIdToAddresses[issuanceRoundId].push(account);
        }
        issuanceAmountByRoundUser[issuanceRoundId][account] += amount;
        totalIssuanceByRound[issuanceRoundId] += amount;
    }

    function addRedemptionForCurrentRound(address user, uint256 amount) external onlyFactory {
        uint256 roundId = redemptionRoundId;

        if (!redemptionRoundActive[roundId]) redemptionRoundActive[roundId] = true;

        if (redemptionAmountByRoundUser[roundId][user] == 0) {
            redemptionRoundIdToAddresses[roundId].push(user);
        }

        redemptionAmountByRoundUser[roundId][user] += amount;
        totalRedemptionByRound[roundId] += amount;
    }

    function addressesInRedemptionRound(uint256 roundId) external view returns (address[] memory) {
        return redemptionRoundIdToAddresses[roundId];
    }

    function addressesInIssuanceRound(uint256 roundId) external view returns (address[] memory) {
        return issuanceRoundIdToAddresses[roundId];
    }

    function getRedemptionRoundActive(uint256 roundId) external view returns (bool) {
        return redemptionRoundActive[roundId];
    }

    function setIssuanceRequesterByNonce(uint256 nonce, address requester) external onlyFactory {
        issuanceRequesterByNonce[nonce] = requester;
    }

    function setRedemptionRequesterByNonce(uint256 nonce, address requester) external onlyFactory {
        redemptionRequesterByNonce[nonce] = requester;
    }

    function undoIssuance(address account, uint256 amount) external onlyFactory {
        uint256 round = issuanceRoundId;

        uint256 before = issuanceAmountByRoundUser[round][account];
        require(before >= amount && amount > 0, "bad amount");

        issuanceAmountByRoundUser[round][account] = before - amount;
        totalIssuanceByRound[round] -= amount;

        if (issuanceAmountByRoundUser[round][account] == 0) {
            address[] storage arr = issuanceRoundIdToAddresses[round];
            for (uint256 i; i < arr.length; ++i) {
                if (arr[i] == account) {
                    arr[i] = arr[arr.length - 1];
                    arr.pop();
                    break;
                }
            }
            if (arr.length == 0) {
                issuanceRoundActive[round] = false;
            }
        }
    }

    function undoRedemption(address user, uint256 amount) external onlyFactory {
        uint256 roundId = redemptionRoundId;
        uint256 before = redemptionAmountByRoundUser[roundId][user];
        require(amount > 0 && before >= amount, "bad amount");

        redemptionAmountByRoundUser[roundId][user] = before - amount;
        totalRedemptionByRound[roundId] -= amount;

        if (redemptionAmountByRoundUser[roundId][user] == 0) {
            address[] storage arr = redemptionRoundIdToAddresses[roundId];
            for (uint256 i; i < arr.length; ++i) {
                if (arr[i] == user) {
                    arr[i] = arr[arr.length - 1];
                    arr.pop();
                    break;
                }
            }
            if (arr.length == 0) {
                redemptionRoundActive[roundId] = false;
            }
        }
    }

    function settleIssuance(uint256 roundId) external onlyOwnerOrOperator {
        address[] storage list = issuanceRoundIdToAddresses[roundId];
        for (uint256 i = 0; i < list.length; ++i) {
            delete issuanceAmountByRoundUser[roundId][list[i]];
        }
        delete issuanceRoundIdToAddresses[roundId];

        delete totalIssuanceByRound[roundId];

        issuanceIsCompleted[roundId] = true;
        issuanceRoundActive[roundId] = false;

        emit IssuanceSettled(roundId);
    }

    function settleRedemption(uint256 roundId) external onlyOwnerOrOperator {
        address[] storage list = redemptionRoundIdToAddresses[roundId];
        for (uint256 i = 0; i < list.length; ++i) {
            delete redemptionAmountByRoundUser[roundId][list[i]];
        }
        delete redemptionRoundIdToAddresses[roundId];
        delete totalRedemptionByRound[roundId];

        redemptionIsCompleted[roundId] = true;
        redemptionRoundActive[roundId] = false;

        emit RedemptionSettled(roundId);
    }

    function _pruneAddress(uint256 round, address user) internal {
        address[] storage arr = issuanceRoundIdToAddresses[round];
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == user) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
        if (arr.length == 0) issuanceRoundActive[round] = false;
    }

    function nextProcessableRoundIdForIssuance() external view returns (uint256) {
        uint256 id = issuanceRoundId;
        for (uint256 i = 1; i < id; ++i) {
            if (issuanceRoundActive[i]) {
                revert UnsettledRound(i);
            }
        }
        return id;
    }

    function nextProcessableRoundIdForRedemption() external view returns (uint256) {
        uint256 id = redemptionRoundId;
        for (uint256 i = 1; i < id; ++i) {
            if (redemptionRoundActive[i]) {
                revert UnsettledRound(i);
            }
        }
        return id;
    }

    function currentIssuanceRoundWithStatus() external view returns (bool allSettled, uint256 roundId) {
        for (uint256 i = 1; i < issuanceRoundId; ++i) {
            if (issuanceRoundActive[i]) {
                return (false, i);
            }
        }
        return (true, issuanceRoundId);
    }

    function currentRedemptionRoundWithStatus() external view returns (bool allSettled, uint256 roundId) {
        for (uint256 i = 1; i < redemptionRoundId; ++i) {
            if (redemptionRoundActive[i]) {
                return (false, i);
            }
        }
        return (true, redemptionRoundId);
    }

    uint256[50] private __gap;
}
