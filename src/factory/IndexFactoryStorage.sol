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
import {IRiskAssetFactory} from "../interfaces/IRiskAssetFactory.sol";
import {FeeVault} from "../vault/FeeVault.sol";
import {IndexFactoryBalancer} from "./IndexFactoryBalancer.sol";

error InvalidAddress();
error ZeroAmount();
error UnsettledRound(uint256 previousRoundId);

contract IndexFactoryStorage is Initializable, OwnableUpgradeable {
    IndexToken public indexToken;
    Vault public vault;
    IndexFactory public indexFactory;
    FunctionsOracle public functionsOracle;
    StagingCustodyAccount public sca;
    FeeVault public feeVault;
    IndexFactoryBalancer public factoryBalancer;
    IERC20 public usdc;

    address public bond;
    address public riskAssetFactoryAddress;
    address public feeReceiver;
    uint8 public feeRate;
    uint256 public issuanceRoundId;
    uint256 public redemptionRoundId;
    address public nexBot;
    bool public isMainnet;
    uint256 public latestFeeUpdate;

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
    mapping(uint256 => uint256) public roundIdToRiskAssetAmount;
    mapping(uint256 => uint256[]) public issuanceRoundIdToNonces;
    mapping(uint256 => uint256[]) public redemptionRoundIdToNonces;
    mapping(uint256 => uint256) public nonceToIssuanceRound;
    mapping(uint256 => uint256) public nonceToRedemptionRound;
    mapping(uint256 => uint256) public issuanceFeeByNonce;
    mapping(address => uint256) public tokenPendingRebalanceAmount;
    mapping(address => mapping(uint256 => uint256)) public tokenPendingRebalanceAmountByNonce;

    event IssuanceSettled(uint256 indexed roundId);
    event RedemptionSettled(uint256 indexed roundId);
    event IssuanceNonceRecorded(uint256 indexed roundId, uint256 indexed nonce); // NEW
    event RedemptionNonceRecorded(uint256 indexed roundId, uint256 indexed nonce);

    modifier onlyFactory() {
        require(
            msg.sender == address(indexFactory) || msg.sender == nexBot || msg.sender == address(sca)
                || msg.sender == address(factoryBalancer),
            "Caller is not a factory contract"
        );
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || functionsOracle.isOperator(msg.sender) || msg.sender == nexBot
                || msg.sender == address(factoryBalancer),
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
        address _riskAssetFactoryAddress,
        address _usdc,
        address _bond,
        address _feeVault,
        address _indexFactoryBalancer
    ) external initializer {
        // if (_indexToken != address(0)) revert InvalidAddress();
        // require(_indexToken != address(0), "Invalid _indexToken address");
        require(_indexFactory != address(0), "Invalid _indexFactory address");
        require(_functionsOracle != address(0), "Invalid _functionsOracle address");
        require(_stagingCustodyAccount != address(0), "Invalid _stagingCustodyAccount address");
        require(_vault != address(0), "Invalid _vault address");
        require(_nexBot != address(0), "Invalid _nexBot address");
        require(_riskAssetFactoryAddress != address(0), "Invalid _riskAssetFactoryAddress address");
        require(_usdc != address(0), "Invalid _usdc address");
        require(_bond != address(0), "Invalid _bond address");

        __Ownable_init(msg.sender);

        indexToken = IndexToken(_indexToken);
        indexFactory = IndexFactory(_indexFactory);
        functionsOracle = FunctionsOracle(_functionsOracle);
        sca = StagingCustodyAccount(_stagingCustodyAccount);
        vault = Vault(_vault);
        feeVault = FeeVault(_feeVault);
        usdc = IERC20(_usdc);
        bond = _bond;

        factoryBalancer = IndexFactoryBalancer(_indexFactoryBalancer);

        riskAssetFactoryAddress = _riskAssetFactoryAddress;
        nexBot = _nexBot;
        // isMainnet = _isMainnet;
        issuanceRoundId = 1;
        redemptionRoundId = 1;
        feeRate = 10;
        feeReceiver = msg.sender;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function setFeeRate(uint8 _newFee) public onlyOwner {
        uint256 distance = block.timestamp - latestFeeUpdate;
        require(distance / 60 / 60 >= 12, "You should wait at least 12 hours after the latest update");
        require(_newFee <= 10000 && _newFee >= 1, "The newFee should be between 1 and 100 (0.01% - 1%)");
        feeRate = _newFee;
        latestFeeUpdate = block.timestamp;
    }

    function setNexBotAddress(address _newNexBotAddress) public onlyOwner {
        if (_newNexBotAddress == address(0)) revert InvalidAddress();
        nexBot = _newNexBotAddress;
    }

    function setSCA(address _sca) external onlyOwner {
        if (_sca == address(0)) revert InvalidAddress();
        sca = StagingCustodyAccount(_sca);
    }

    function setFeeReceiver(address _feeReceiver) public onlyOwner {
        if (_feeReceiver == address(0)) revert InvalidAddress();
        feeReceiver = _feeReceiver;
    }

    function setIssuanceInputAmount(uint256 _issuanceNonce, uint256 _amount) external onlyFactory {
        if (_amount == 0) revert ZeroAmount();
        issuanceInputAmount[_issuanceNonce] = _amount;
    }

    function setRedemptionInputAmount(uint256 _redemptionNonce, uint256 _amount) external onlyFactory {
        if (_amount == 0) revert ZeroAmount();
        redemptionInputAmount[_redemptionNonce] = _amount;
    }

    function setIssuanceFeeByNonce(uint256 nonce, uint256 fee) external onlyFactory {
        issuanceFeeByNonce[nonce] = fee;
    }

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

    function setIssuanceRoundActive(uint256 roundId, bool flag) external onlyFactory {
        issuanceRoundActive[roundId] = flag;
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

    function getIssuanceRoundIdToNonces(uint256 roundId) external view returns (uint256[] memory) {
        return issuanceRoundIdToNonces[roundId];
    }

    function getRedemptionRoundIdToNonces(uint256 roundId) external view returns (uint256[] memory) {
        return redemptionRoundIdToNonces[roundId];
    }

    function setIssuanceRequesterByNonce(uint256 nonce, address requester) external onlyFactory {
        issuanceRequesterByNonce[nonce] = requester;
    }

    function setRedemptionRequesterByNonce(uint256 nonce, address requester) external onlyFactory {
        redemptionRequesterByNonce[nonce] = requester;
    }

    function increaseTokenPendingRebalanceAmount(address _token, uint256 _nonce, uint256 _amount)
        external
        onlyFactory
    {
        require(_token != address(0), "invalid token address");
        require(_amount > 0, "Invalid amount");
        tokenPendingRebalanceAmount[_token] += _amount;
        tokenPendingRebalanceAmountByNonce[_token][_nonce] += _amount;
    }

    function decreaseTokenPendingRebalanceAmount(address _token, uint256 _nonce, uint256 _amount)
        external
        onlyFactory
    {
        require(_token != address(0), "invalid token address");
        require(_amount > 0, "Invalid amount");
        require(tokenPendingRebalanceAmount[_token] >= _amount, "Insufficient pending rebalance amount");
        tokenPendingRebalanceAmount[_token] -= _amount;
        tokenPendingRebalanceAmountByNonce[_token][_nonce] -= _amount;
    }

    function resetTokenPendingRebalanceAmount(address _token, uint256 _nonce) public onlyOwnerOrOperator {
        require(_token != address(0), "invalid token address");
        tokenPendingRebalanceAmount[_token] = 0;
        tokenPendingRebalanceAmountByNonce[_token][_nonce] = 0;
    }

    function resetAllTokenPendingRebalanceAmount(uint256 _nonce) public onlyOwnerOrOperator {
        for (uint256 i; i < functionsOracle.totalCurrentList(); i++) {
            address tokenAddress = functionsOracle.currentList(i);
            resetTokenPendingRebalanceAmount(tokenAddress, _nonce);
        }
    }

    function recordIssuanceNonce(uint256 roundId, uint256 nonce) external onlyFactory {
        issuanceRoundIdToNonces[roundId].push(nonce);
        nonceToIssuanceRound[nonce] = roundId;
        emit IssuanceNonceRecorded(roundId, nonce);
    }

    /// @dev Record redemption nonce in both round->nonces and nonce->round
    function recordRedemptionNonce(uint256 roundId, uint256 nonce) external onlyFactory {
        redemptionRoundIdToNonces[roundId].push(nonce);
        nonceToRedemptionRound[nonce] = roundId;
        emit RedemptionNonceRecorded(roundId, nonce);
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

    /**
     * @dev First issuance round that can call `issuanceAndWithdrawForPurchase`.
     */
    function nextIssuanceRoundForRequestIssuance() external view returns (uint256 roundId) {
        uint256 last = issuanceRoundId;
        for (uint256 id = 1; id <= last; ++id) {
            bool ok = issuanceRoundActive[id] && !issuanceIsCompleted[id];
            if (ok && _prevIssuanceSettled(id)) return id;
        }
        return 0;
    }

    /**
     * @dev First issuance round that can call `completeIssuance`.
     */
    function nextIssuanceRoundForCompleteIssuance() external view returns (uint256 roundId) {
        uint256 last = issuanceRoundId;
        for (uint256 id = 1; id <= last; ++id) {
            bool ok = !issuanceRoundActive[id] && !issuanceIsCompleted[id];
            if (ok && _prevIssuanceSettled(id)) return id;
        }
        return 0;
    }

    /**
     * @dev First redemption round that can call `initiateRedemptionBatch`.
     */
    function nextRedemptionRoundForRequestRedemption() external view returns (uint256 roundId) {
        uint256 last = redemptionRoundId;
        for (uint256 id = 1; id <= last; ++id) {
            bool ok = redemptionRoundActive[id] && !redemptionIsCompleted[id];
            if (ok && _prevRedemptionSettled(id)) return id;
        }
        return 0;
    }

    /**
     * @dev First redemption round that can call `completeRedemption`.
     */
    function nextRedemptionRoundForCompleteRedemption() external view returns (uint256 roundId) {
        uint256 last = redemptionRoundId;
        for (uint256 id = 1; id <= last; ++id) {
            bool ok = !redemptionRoundActive[id] && !redemptionIsCompleted[id];
            if (ok && _prevRedemptionSettled(id)) return id;
        }
        return 0;
    }

    function _prevIssuanceSettled(uint256 id) internal view returns (bool) {
        if (id == 1) return true;
        uint256 p = id - 1;
        return !issuanceRoundActive[p] && issuanceIsCompleted[p];
    }

    function _prevRedemptionSettled(uint256 id) internal view returns (bool) {
        if (id == 1) return true;
        uint256 p = id - 1;
        return !redemptionRoundActive[p] && redemptionIsCompleted[p];
    }

    function getPortfolioValue(uint256 bondPrice, uint256 riskAssetPrice) public view returns (uint256 totalValue) {
        uint256 tokens = functionsOracle.totalCurrentList();

        for (uint256 i; i < tokens; ++i) {
            address token = functionsOracle.currentList(i);
            // uint256 balance = IERC20(token).balanceOf(address(vault));
            uint256 balance = IERC20(token).balanceOf(address(vault)) + tokenPendingRebalanceAmount[token];
            if (balance == 0) continue;

            uint8 assetType = functionsOracle.tokenAssetType(token);

            if (assetType == 0) {
                totalValue += (balance * bondPrice) / 1e18;
            } else if (assetType == 1) {
                totalValue += (balance * riskAssetPrice) / 1e18;
            }
        }

        return totalValue;
    }

    function calculateMintAmount(uint256 oldValue, uint256 newValue) public view returns (uint256 mintAmount) {
        require(newValue > oldValue, "no NAV increase");

        uint256 supply = indexToken.totalSupply();

        if (supply == 0 || oldValue == 0) {
            return newValue / 100;
        }

        mintAmount = supply * (newValue - oldValue) / oldValue;
    }

    function getIssuanceFee(
        address _tokenIn,
        address[] memory _tokenInPath,
        uint24[] memory _tokenInFees,
        uint256 _inputAmount
    ) public view returns (uint256) {
        uint256 ethFee = IRiskAssetFactory(riskAssetFactoryAddress).getIssuanceFee(
            _tokenIn, _tokenInPath, _tokenInFees, _inputAmount
        );
        return ethFee;
    }

    function getRedemptionFee(uint256 _amount) public view returns (uint256) {
        uint256 ethFee = IRiskAssetFactory(riskAssetFactoryAddress).getRedemptionFee(_amount);
        return ethFee;
    }

    function getIndexTokenPrice(uint256 bondPrice, uint256 riskAssetPrice) public view returns (uint256) {
        uint256 totalSupply = indexToken.totalSupply();
        // uint256 portfolioValue = getPortfolioValue(bondPrice, riskAssetPrice);
        uint256 portfolioValue = getPortfolioValue(bondPrice, riskAssetPrice);
        if (totalSupply == 0) {
            return 0;
        }
        return portfolioValue * 1e18 / totalSupply;
    }

    uint256[50] private __gap;
}
