// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IndexFactoryStorage} from "./IndexFactoryStorage.sol";
import {FunctionsOracle} from "./FunctionsOracle.sol";
import {IndexFactory} from "./IndexFactory.sol";
import {IndexToken} from "../token/IndexToken.sol";

contract IndexFactoryBalancer is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public rebalanceNonce;

    IndexFactoryStorage public factoryStorage;
    FunctionsOracle public functionsOracle;

    event FirstRebalanceAction(uint256 nonce, uint256 time);
    event SecondRebalanceAction(uint256 nonce, uint256 time);
    event CompleteRebalanceActions(uint256 nonce, uint256 time);

    // modifier onlyOwnerOrOperator() {
    //     require(
    //         msg.sender == owner() || functionsOracle.isOperator(msg.sender),
    //         "Only owner or operator can call this function"
    //     );
    //     _;
    // }

    function initialize(address _factoryStorage, address _functionsOracle) external initializer {
        require(_factoryStorage != address(0), "invalid token address");
        require(_functionsOracle != address(0), "invalid functions oracle address");
        factoryStorage = IndexFactoryStorage(_factoryStorage);
        functionsOracle = FunctionsOracle(_functionsOracle);
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function setIndexFactoryStorage(address _indexFactoryStorage) public onlyOwner returns (bool) {
        factoryStorage = IndexFactoryStorage(_indexFactoryStorage);
        return true;
    }

    function setFunctionsOracle(address _functionsOracle) public onlyOwner returns (bool) {
        functionsOracle = FunctionsOracle(_functionsOracle);
        return true;
    }

    function firstRebalanceAction() public nonReentrant /*onlyOwnerOrOperator*/ returns (uint256) {
        pauseIndexFactory();
        rebalanceNonce += 1;

        emit FirstRebalanceAction(rebalanceNonce, block.timestamp);
        return rebalanceNonce;
    }

    function secondRebalanceAction(uint256 _rebalanceNonce) public nonReentrant /*onlyOwnerOrOperator*/ {
        emit SecondRebalanceAction(_rebalanceNonce, block.timestamp);
    }

    function completeRebalanceActions(uint256 _rebalanceNonce) public nonReentrant /*onlyOwnerOrOperator*/ {
        unpauseIndexFactory();
        emit CompleteRebalanceActions(_rebalanceNonce, block.timestamp);
    }

    function checkFirstRebalanceOrdersStatus(uint256 _rebalanceNonce) public view returns (bool) {
        require(_rebalanceNonce <= rebalanceNonce, "Wrong rebalance nonce!");

        return true;
    }

    function checkSecondRebalanceOrdersStatus(uint256 _rebalanceNonce) public view returns (bool) {
        require(_rebalanceNonce <= rebalanceNonce, "Wrong rebalance nonce!");

        return true;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // pause index factory when rebalance happens
    function pauseIndexFactory() internal {
        address indexFactoryAddress = address(factoryStorage.indexFactory());
        IndexFactory indexFactory = IndexFactory(payable(indexFactoryAddress));
        if (!indexFactory.paused()) {
            indexFactory.pause();
        }
    }

    // unpause index factory when rebalance is done
    function unpauseIndexFactory() internal {
        address indexFactoryAddress = address(factoryStorage.indexFactory());
        IndexFactory indexFactory = IndexFactory(payable(indexFactoryAddress));
        if (indexFactory.paused()) {
            indexFactory.unpause();
        }
    }
}
