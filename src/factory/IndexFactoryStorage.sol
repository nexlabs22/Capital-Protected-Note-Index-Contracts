// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IndexFactory} from "../factory/IndexFactory.sol";
import {FunctionsOracle} from "../factory/FunctionsOracle.sol";

contract IndexFactoryStorage is Initializable, OwnableUpgradeable {
    IndexFactory indexFactory;
    FunctionsOracle public functionsOracle;

    address public feeReceiver;
    address public nexVault;
    uint256 public feeRate;
    uint256 public currentRoundId;
    bool public isMainnet;
    address nexBot;

    mapping(uint256 => bool) public issuanceIsCompleted;
    mapping(uint256 => address) public issuanceRequesterByNonce;
    mapping(uint256 => uint256) public issuanceInputAmount;
    mapping(uint256 => uint256) public redemptionInputAmount;
    mapping(uint256 => uint256) public burnedTokenAmountByNonce;
    mapping(uint256 => address[]) private roundIdToAddresses;
    // roundId → user → amount deposited in that round
    mapping(uint256 => mapping(address => uint256)) public issuanceAmountByRoundUser;
    // roundId → total amount deposited (denominator for share calculations)
    mapping(uint256 => uint256) public totalIssuanceByRound;

    event RoundSettled(uint256 indexed roundId);

    modifier onlyFactory() {
        // require(
        //     msg.sender == factoryAddress || msg.sender == factoryBalancerAddress, "Caller is not a factory contract"
        // );
        // _;
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
        address _indexFactory,
        address _functionsOracle,
        address _nexVault,
        bool _isMainnet,
        address _nexBot
    ) external initializer {
        require(_indexFactory != address(0), "invalid index factory address");
        require(_functionsOracle != address(0), "invalid functions oracle address");

        __Ownable_init(msg.sender);

        indexFactory = IndexFactory(_indexFactory);
        functionsOracle = FunctionsOracle(_functionsOracle);
        nexVault = _nexVault;
        isMainnet = _isMainnet;
        nexBot = _nexBot;

        currentRoundId = 1;
        feeRate = 10;
        feeReceiver = msg.sender;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function setFeeReceiver(address _feeReceiver) public onlyOwner {
        require(_feeReceiver != address(0), "invalid fee receiver address");
        feeReceiver = _feeReceiver;
    }

    function setIssuanceInputAmount(uint256 _issuanceNonce, uint256 _amount) external onlyFactory {
        require(_amount > 0, "Invalid issuance input amount");
        issuanceInputAmount[_issuanceNonce] = _amount;
    }

    function setRedemptionInputAmount(uint256 _redemptionNonce, uint256 _amount) external onlyFactory {
        require(_amount > 0, "Invalid redemption input amount");
        redemptionInputAmount[_redemptionNonce] = _amount;
    }

    function setBurnedTokenAmountByNonce(uint256 _redemptionNonce, uint256 _burnedAmount) external onlyFactory {
        require(_burnedAmount > 0, "Invalid burn amount");
        burnedTokenAmountByNonce[_redemptionNonce] = _burnedAmount;
    }

    function setRoundIdToAddresses(uint256 _roundId, address[] memory addresses) external onlyFactory {
        require(_roundId > 0, "Invalid roundId amount");
        roundIdToAddresses[_roundId] = addresses;
    }

    function increaseCurrentRoundId() external onlyFactory {
        currentRoundId++;
    }

    function addIssuanceForCurrentRound(address account, uint256 amount) external onlyFactory {
        // if (issuanceAmountByRoundUser[currentRoundId][account] == 0 && totalIssuanceByRound[currentRoundId] != 0) {
        //     roundIdToAddresses[currentRoundId].push(account);
        // }
        if (issuanceAmountByRoundUser[currentRoundId][account] == 0) {
            roundIdToAddresses[currentRoundId].push(account);
        }
        issuanceAmountByRoundUser[currentRoundId][account] += amount;
        totalIssuanceByRound[currentRoundId] += amount;
    }

    function addressesInRound(uint256 roundId) external view returns (address[] memory) {
        return roundIdToAddresses[roundId];
    }

    function setIssuanceRequesterByNonce(uint256 nonce, address requester) external onlyFactory {
        issuanceRequesterByNonce[nonce] = requester;
    }

    function settleRound(uint256 roundId) external onlyOwnerOrOperator {
        address[] storage list = roundIdToAddresses[roundId];
        for (uint256 i = 0; i < list.length; ++i) {
            delete issuanceAmountByRoundUser[roundId][list[i]];
        }
        delete roundIdToAddresses[roundId];

        delete totalIssuanceByRound[roundId];

        issuanceIsCompleted[roundId] = true;

        emit RoundSettled(roundId);

        currentRoundId = roundId + 1;
    }

    // function pushAddressToCurrentRound(address account) external onlyFactory {
    //     roundIdToAddresses[currentRoundId].push(account);
    // }

    uint256[45] private __gap;
}
