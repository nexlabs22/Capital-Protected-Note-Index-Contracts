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
    uint256 public feeRate;
    uint256 public currentRoundId;
    bool public isMainnet;

    mapping(uint256 => bool) public issuanceIsCompleted;
    mapping(uint256 => address) public issuanceRequesterByNonce;
    mapping(uint256 => uint256) public issuanceInputAmount;
    mapping(uint256 => uint256) public redemptionInputAmount;
    mapping(uint256 => uint256) public burnedTokenAmountByNonce;
    // mapping(uint256 => address[]) roundIdToAddresses;
    mapping(uint256 => address[]) private roundIdToAddresses;

    modifier onlyFactory() {
        // require(
        //     msg.sender == factoryAddress || msg.sender == factoryBalancerAddress, "Caller is not a factory contract"
        // );
        // _;
        require(msg.sender == address(indexFactory), "Caller is not a factory contract");
        _;
    }

    function initialize(address _indexFactory, address _functionsOracle, bool _isMainnet) external initializer {
        require(_indexFactory != address(0), "invalid index factory address");
        require(_functionsOracle != address(0), "invalid functions oracle address");

        indexFactory = IndexFactory(_indexFactory);
        functionsOracle = FunctionsOracle(_functionsOracle);
        isMainnet = _isMainnet;

        feeRate = 10;
        feeReceiver = msg.sender;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
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

    function pushAddressToCurrentRound(address account) external onlyFactory {
        roundIdToAddresses[currentRoundId].push(account);
    }

    /// view helper so bots / frontends can fetch the list
    function addressesInRound(uint256 roundId) external view returns (address[] memory) {
        return roundIdToAddresses[roundId];
    }
}
