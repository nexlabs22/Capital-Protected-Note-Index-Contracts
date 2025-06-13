// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IndexFactoryStorage} from "./IndexFactoryStorage.sol";
import {FunctionsOracle} from "./FunctionsOracle.sol";
import {IndexFactory} from "./IndexFactory.sol";
import {IndexToken} from "../token/IndexToken.sol";
import {Vault} from "../vault/Vault.sol";
import {StagingCustodyAccount} from "../SCA/StagingCustodyAccount.sol";
import {IRiskAssetFactory} from "../interfaces/IRiskAssetFactory.sol";

contract IndexFactoryBalancer is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct RebalanceBatch {
        bool firstDone;
        bool secondDone;
        uint256 totalUsdcObtained;
        mapping(address => uint256) tokenDelta;
    }

    struct Ctx {
        uint256 bondPrice18;
        uint256 cryptoPrice18;
        Vault vault;
        StagingCustodyAccount sca;
        IERC20 usdc;
        address curToken;
        address[] path;
        uint24[] poolFees;
    }

    struct Vars {
        uint256 usdcBalance;
        bool bondDeficit;
        bool riskAssetDeficit;
    }

    IndexFactoryStorage public factoryStorage;
    FunctionsOracle public functionsOracle;
    uint256 constant ONE_BPS_1e18 = 100e18;
    uint256 public rebalanceNonce;

    mapping(uint256 => RebalanceBatch) private _rebalanceBatches;

    event FirstRebalanceAction(
        uint256 indexed nonce, address[] tokensSold, uint256[] amountsSold, uint256 usdcExpected, uint256 time
    );
    event SecondRebalanceAction(uint256 nonce, uint256 time);
    event CompleteRebalanceActions(uint256 nonce, uint256 time);
    event IssuanceRiskAssetForRebalance(uint256 indexed amount, uint256 timestamp);
    event RedemptionRiskAssetForRebalance(uint256 indexed amount, uint256 timestamp);

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || factoryStorage.functionsOracle().isOperator(msg.sender)
                || msg.sender == address(factoryStorage.factoryBalancer()) || msg.sender == factoryStorage.nexBot(),
            "Caller is not the owner or operator"
        );
        _;
    }

    modifier onlyNexBot() {
        require(msg.sender == factoryStorage.nexBot(), "Caller is not the NEX bot");
        _;
    }

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

    function withdrawBondForNexBot(uint256 amount) public onlyOwnerOrOperator {
        uint256 bondBalance = IERC20(factoryStorage.bond()).balanceOf(address(this));
        require(bondBalance >= amount, "Invalid amount");
        IERC20(factoryStorage.bond()).safeTransfer(address(factoryStorage.nexBot()), amount);
    }

    function firstRebalanceAction(
        uint256 bondPrice18,
        uint256 cryptoPrice18,
        address[] calldata tokenInPath,
        uint24[] calldata tokenInFees
    ) external payable nonReentrant whenNotPaused onlyOwnerOrOperator returns (uint256 nonce) {
        pauseIndexFactory();

        Ctx memory ctx = Ctx({
            bondPrice18: bondPrice18,
            cryptoPrice18: cryptoPrice18,
            vault: factoryStorage.vault(),
            sca: factoryStorage.sca(),
            usdc: factoryStorage.usdc(),
            curToken: address(0),
            path: tokenInPath,
            poolFees: tokenInFees
        });

        nonce = ++rebalanceNonce;
        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        require(!batch.firstDone, "rebalance: phase-1 done");

        uint256 portfolioValue = factoryStorage.getPortfolioValue(bondPrice18, cryptoPrice18);

        uint256 currentList = functionsOracle.totalCurrentList();
        address[] memory soldToken = new address[](currentList);
        uint256[] memory soldQty = new uint256[](currentList);
        uint256 soldLen;

        // uint256 totalRedemptionFee = factoryStorage.getRedemptionFee(qty18);
        uint256 totalRedemptionFee;

        for (uint256 i; i < currentList; ++i) {
            address token = functionsOracle.currentList(i);

            (bool didSell, uint256 qty18) = _processToken(nonce, token, portfolioValue, ctx);
            // if (didSell && functionsOracle.tokenAssetType(token) == 1) {
            //     totalRedemptionFee += factoryStorage.getRedemptionFee(qty18);
            // }
            // if (!didSell) continue;

            if (didSell) {
                soldToken[soldLen] = token;
                soldQty[soldLen] = qty18;
                ++soldLen;
            }

            if (functionsOracle.tokenAssetType(token) == 1 && qty18 > 0) {
                totalRedemptionFee += factoryStorage.getRedemptionFee(qty18);
            }

            // if (functionsOracle.tokenAssetType(token) == 1) {
            //     totalRedemptionFee += factoryStorage.getRedemptionFee(qty18);
            //     require(msg.value == totalRedemptionFee, "balancer: wrong ETH fee");
            // }
        }
        require(msg.value == totalRedemptionFee, "balancer: wrong ETH fee");

        batch.firstDone = true;

        assembly {
            mstore(soldToken, soldLen)
            mstore(soldQty, soldLen)
        }

        emit FirstRebalanceAction(nonce, soldToken, soldQty, batch.totalUsdcObtained, block.timestamp);
    }

    function secondRebalanceAction(uint256 batchId, address[] calldata tokenInPath, uint24[] calldata tokenInFees)
        external
        payable
        nonReentrant
        onlyOwnerOrOperator
    {
        RebalanceBatch storage batch = _rebalanceBatches[batchId];
        require(batch.firstDone, "rebalance: phase-1 not done");
        require(!batch.secondDone, "rebalance: phase-2 already done");

        IERC20 usdc = factoryStorage.usdc();
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) revert("no USDC to deploy");

        Vars memory vars;
        vars.usdcBalance = balance;

        address bondToken = factoryStorage.bond();
        address riskAssetToken = address(factoryStorage.indexToken());

        vars.bondDeficit =
            functionsOracle.tokenCurrentMarketShare(bondToken) < functionsOracle.tokenOracleMarketShare(bondToken);

        vars.riskAssetDeficit = functionsOracle.tokenCurrentMarketShare(riskAssetToken)
            < functionsOracle.tokenOracleMarketShare(riskAssetToken);

        if (vars.bondDeficit) {
            usdc.safeTransfer(factoryStorage.nexBot(), vars.usdcBalance);
            batch.tokenDelta[bondToken] = 0;
        } else if (vars.riskAssetDeficit) {
            uint256 fee = factoryStorage.getIssuanceFee(
                address(factoryStorage.usdc()), tokenInPath, tokenInFees, vars.usdcBalance
            );
            require(msg.value == fee, "unexpected ETH fee");
            _mintCrypto5(vars.usdcBalance, tokenInPath, tokenInFees, msg.value);
            batch.tokenDelta[riskAssetToken] = 0;
        } else {
            require(msg.value == 0, "unexpected ETH fee");
            usdc.safeTransfer(address(factoryStorage.vault()), vars.usdcBalance);
        }

        batch.secondDone = true;
        emit SecondRebalanceAction(batchId, block.timestamp);
    }

    function completeRebalanceActions(uint256 batchId) external nonReentrant onlyOwnerOrOperator {
        RebalanceBatch storage batch = _rebalanceBatches[batchId];
        require(batch.secondDone, "rebalance: phase-2 not done");

        Vault vault = factoryStorage.vault();
        uint256 currentlist = functionsOracle.totalCurrentList();

        for (uint256 i; i < currentlist; ++i) {
            address token = functionsOracle.currentList(i);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) IERC20(token).safeTransfer(address(vault), balance);
        }

        factoryStorage.resetAllTokenPendingRebalanceAmount(batchId);

        functionsOracle.updateCurrentList();

        unpauseIndexFactory();

        emit CompleteRebalanceActions(batchId, block.timestamp);
    }

    function issuanceRiskAsset(uint256 usdcAmount, address[] calldata _tokenInPath, uint24[] calldata _tokenInFees)
        public
        payable
        onlyOwnerOrOperator
    {
        require(msg.value > 0, "BALANCER: no ETH attached");
        IRiskAssetFactory(factoryStorage.riskAssetFactoryAddress()).issuanceIndexTokens{value: msg.value}(
            address(factoryStorage.usdc()), _tokenInPath, _tokenInFees, usdcAmount
        );
        emit IssuanceRiskAssetForRebalance(usdcAmount, block.timestamp);
    }

    function redemptionRiskAsset(
        uint256 amountIn,
        address _tokenOut,
        address[] memory _tokenOutPath,
        uint24[] memory _tokenOutFees
    ) public payable onlyOwnerOrOperator {
        require(msg.value > 0, "BALANCER: no ETH");

        IRiskAssetFactory(factoryStorage.riskAssetFactoryAddress()).redemption{value: msg.value}(
            amountIn, _tokenOut, _tokenOutPath, _tokenOutFees
        );
        emit RedemptionRiskAssetForRebalance(amountIn, block.timestamp);
    }

    function _redeemRiskAsset(uint256 nonce, address riskAssetToken, uint256 usdCut18, Ctx memory ctx)
        internal
        returns (uint256 qty18)
    {
        qty18 = (usdCut18 * 1e18) / ctx.cryptoPrice18;

        factoryStorage.increaseTokenPendingRebalanceAmount(riskAssetToken, nonce, qty18);

        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        batch.tokenDelta[riskAssetToken] = qty18;
        batch.totalUsdcObtained += usdCut18;

        ctx.vault.withdrawFunds(riskAssetToken, address(this), qty18);

        IERC20(riskAssetToken).approve(factoryStorage.riskAssetFactoryAddress(), qty18);

        uint256 ethFee = factoryStorage.getRedemptionFee(qty18);

        this.redemptionRiskAsset{value: ethFee}(qty18, address(ctx.usdc), ctx.path, ctx.poolFees);
    }

    function _processToken(uint256 nonce, address token, uint256 nav18, Ctx memory ctx)
        internal
        returns (bool sold, uint256 qty18Sold)
    {
        uint256 currentMarketShare = functionsOracle.tokenCurrentMarketShare(token);
        uint256 targetMarketShare = functionsOracle.tokenOracleMarketShare(token);
        if (currentMarketShare <= targetMarketShare) return (false, 0);

        uint256 usdCut18 = (nav18 * (currentMarketShare - targetMarketShare)) / ONE_BPS_1e18;

        if (functionsOracle.tokenAssetType(token) == 0) {
            qty18Sold = _sellBond(nonce, token, usdCut18, ctx);
        } else {
            qty18Sold = _redeemRiskAsset(nonce, token, usdCut18, ctx);
        }
        sold = true;
    }

    function _sellBond(uint256 nonce, address bondToken, uint256 usdCut18, Ctx memory ctx)
        internal
        returns (uint256 qty18)
    {
        qty18 = (usdCut18 * 1e18) / ctx.bondPrice18;

        factoryStorage.increaseTokenPendingRebalanceAmount(bondToken, nonce, qty18);

        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        batch.tokenDelta[bondToken] = qty18;
        batch.totalUsdcObtained += usdCut18;
        uint256 amount = ctx.vault.withdrawFunds(bondToken, address(this), qty18);
        // ctx.vault.withdrawFunds(bondToken, factoryStorage.nexBot(), amount);
        // withdrawBondForNexBot(amount);
        IERC20(bondToken).safeTransfer(factoryStorage.nexBot(), amount);
    }

    function _mintCrypto5(uint256 amountUsdc, address[] calldata path, uint24[] calldata fees, uint256 msgValue)
        internal
    {
        StagingCustodyAccount sca = factoryStorage.sca();

        IERC20 usdc = factoryStorage.usdc();
        usdc.safeTransfer(address(sca), amountUsdc);

        uint256 feeEth = factoryStorage.getIssuanceFee(address(usdc), path, fees, amountUsdc);
        require(msgValue == feeEth, "wrong ETH fee");

        this.issuanceRiskAsset{value: feeEth}(amountUsdc, path, fees);
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

    function pauseIndexFactory() internal {
        if (!factoryStorage.indexFactory().paused()) {
            factoryStorage.indexFactory().pause();
        }
    }

    function unpauseIndexFactory() internal {
        if (factoryStorage.indexFactory().paused()) {
            factoryStorage.indexFactory().unpause();
        }
    }
}
