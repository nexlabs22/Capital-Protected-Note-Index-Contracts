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
import {Vault} from "../vault/Vault.sol";
import {StagingCustodyAccount} from "../SCA/StagingCustodyAccount.sol";
import {IRiskAssetFactory} from "../interfaces/IRiskAssetFactory.sol";
import {FeeCalculation} from "../libraries/FeeCalculation.sol";

/// @custom:oz-upgrades-from IndexFactoryBalancerV3
contract IndexFactoryBalancerV4 is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct RebalanceBatch {
        bool firstDone;
        bool secondDone;
        uint256 totalUsdcObtained;
        mapping(address => uint256) tokenDelta;
    }

    struct Ctx {
        uint256 bondPrice;
        uint256 cryptoPrice;
        Vault vault;
        IERC20 usdc;
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

    uint256 public constant ONE_BPS_1e18 = 100e18;
    uint256 public rebalanceNonce;

    mapping(uint256 => RebalanceBatch) private _rebalanceBatches;

    event FirstRebalanceAction(
        uint256 indexed nonce, address[] tokensSold, uint256[] amountsSold, uint256 usdcExpected, uint256 time
    );
    event SecondRebalanceAction(uint256 batchId, uint256 time);
    event CompleteRebalanceActions(uint256 batchId, uint256 time);
    event IssuanceRiskAssetForRebalance(uint256 amount, uint256 timestamp);
    event RedemptionRiskAssetForRebalance(uint256 amount, uint256 timestamp);

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || factoryStorage.functionsOracle().isOperator(msg.sender)
                || msg.sender == factoryStorage.nexBot(),
            "balancer: only owner / operator / bot"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _storage, address _oracle) external initializer {
        require(_storage != address(0), "balancer: zero storage");
        require(_oracle != address(0), "balancer: zero oracle");

        factoryStorage = IndexFactoryStorage(_storage);
        functionsOracle = FunctionsOracle(_oracle);

        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    function firstRebalanceAction(
        uint256 bondPrice,
        uint256 cryptoPrice,
        address[] calldata tokenInPath,
        uint24[] calldata tokenInFees
    ) external payable nonReentrant whenNotPaused onlyOwnerOrOperator returns (uint256 nonce) {
        pauseIndexFactory();

        Ctx memory ctx = Ctx({
            bondPrice: bondPrice,
            cryptoPrice: cryptoPrice,
            vault: factoryStorage.vault(),
            usdc: factoryStorage.usdc(),
            path: tokenInPath,
            poolFees: tokenInFees
        });

        nonce = ++rebalanceNonce;
        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        require(!batch.firstDone, "rebalance: phase-1 done");

        uint256 listLen = functionsOracle.totalCurrentList();
        address[] memory soldToken = new address[](listLen);
        uint256[] memory soldQty = new uint256[](listLen);
        uint256 soldLen;
        uint256 totalEthFee;

        for (uint256 i; i < listLen; ++i) {
            address tok = functionsOracle.currentList(i);
            (bool sold, uint256 qty18) = _processToken(nonce, tok, ctx);

            if (sold) {
                soldToken[soldLen] = tok;
                soldQty[soldLen] = qty18;
                ++soldLen;

                if (functionsOracle.tokenAssetType(tok) == 1 && qty18 > 0) {
                    totalEthFee += factoryStorage.getRedemptionFee(qty18);
                }
            }
        }

        require(msg.value == totalEthFee, "balancer: wrong ETH");

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
        require(batch.firstDone && !batch.secondDone, "rebalance: bad phase");

        IERC20 usdc = factoryStorage.usdc();
        uint256 bal = usdc.balanceOf(address(this));
        require(bal > 0, "balancer: no USDC");

        address bond = factoryStorage.bond();
        // address riskAsset = address(factoryStorage.riskAssetTokenAddress());

        bool bondDeficit = false;
        bool riskDeficit = false;

        for (uint256 i; i < factoryStorage.functionsOracle().totalCurrentList(); ++i) {
            address token = factoryStorage.functionsOracle().currentList(i);
            uint256 current = factoryStorage.functionsOracle().tokenCurrentMarketShare(token);
            uint256 oracle = factoryStorage.functionsOracle().tokenOracleMarketShare(token);

            if (factoryStorage.functionsOracle().tokenAssetType(token) == 1) {
                riskDeficit = current < oracle;
                // riskDeficit = true;
            } else {
                bondDeficit = current < oracle;
                // bondDeficit = true;
            }
            // if (factoryStorage.functionsOracle().tokenAssetType(token) == 1 && current < oracle) {
            //     riskDeficit = true;
            // } else {
            //     bondDeficit = true;
            // }
        }

        // bool bondDeficit = functionsOracle.tokenCurrentMarketShare(bond) < functionsOracle.tokenOracleMarketShare(bond);

        // bool riskDeficit =
        //     functionsOracle.tokenCurrentMarketShare(riskAsset) < functionsOracle.tokenOracleMarketShare(riskAsset);

        if (bondDeficit) {
            usdc.safeTransfer(factoryStorage.nexBot(), bal);
            batch.tokenDelta[bond] = 0;
            require(msg.value == 0, "balancer: no ETH needed");
        } else if (riskDeficit) {
            uint256 fee = factoryStorage.getIssuanceFee(address(usdc), tokenInPath, tokenInFees, bal);
            require(msg.value == fee, "balancer: bad ETH");
            _mintCrypto5(bal, tokenInPath, tokenInFees, fee);
            // batch.tokenDelta[riskAsset] = 0;
        } else {
            require(msg.value == 0, "balancer: unexpected ETH");
            usdc.safeTransfer(address(factoryStorage.vault()), bal);
        }

        batch.secondDone = true;
        emit SecondRebalanceAction(batchId, block.timestamp);
    }

    function completeRebalanceActions(uint256 batchId) external nonReentrant onlyOwnerOrOperator {
        RebalanceBatch storage batch = _rebalanceBatches[batchId];
        require(batch.secondDone, "rebalance: phase-2 not done");

        Vault v = factoryStorage.vault();
        uint256 len = functionsOracle.totalCurrentList();
        for (uint256 i; i < len; ++i) {
            address tok = functionsOracle.currentList(i);
            uint256 bal = IERC20(tok).balanceOf(address(this));
            if (bal > 0) IERC20(tok).safeTransfer(address(v), bal);
        }

        factoryStorage.resetAllTokenPendingRebalanceAmount(batchId);
        functionsOracle.updateCurrentList();
        unpauseIndexFactory();
        emit CompleteRebalanceActions(batchId, block.timestamp);
    }

    function _processToken(uint256 nonce, address token, Ctx memory ctx)
        internal
        returns (bool sold, uint256 qty18Sold)
    {
        uint256 curShare18 = functionsOracle.tokenCurrentMarketShare(token);
        uint256 tgtShare18 = functionsOracle.tokenOracleMarketShare(token);

        if (curShare18 <= tgtShare18) return (false, 0);

        uint256 shareDiff18 = curShare18 - tgtShare18;

        if (functionsOracle.tokenAssetType(token) == 0) {
            qty18Sold = _sellBond(nonce, token, shareDiff18, ctx);
        } else {
            qty18Sold = _redeemRiskAsset(nonce, token, shareDiff18, ctx);
        }
        sold = qty18Sold > 0;
    }

    function _sellBond(uint256 nonce, address bondToken, uint256 shareDiff18, Ctx memory ctx)
        internal
        returns (uint256 soldQty18)
    {
        uint256 vaultBal = IERC20(bondToken).balanceOf(address(ctx.vault));
        soldQty18 = (vaultBal * shareDiff18) / ONE_BPS_1e18;
        if (soldQty18 == 0) return 0;

        factoryStorage.increaseTokenPendingRebalanceAmount(bondToken, nonce, soldQty18);

        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        batch.tokenDelta[bondToken] = soldQty18;
        batch.totalUsdcObtained += (soldQty18 * ctx.bondPrice) / 1e18;

        uint256 pulled = ctx.vault.withdrawFunds(bondToken, address(this), soldQty18);
        IERC20(bondToken).safeTransfer(factoryStorage.nexBot(), pulled);
    }

    function _redeemRiskAsset(uint256 nonce, address riskToken, uint256 shareDiff18, Ctx memory ctx)
        internal
        returns (uint256 soldQty18)
    {
        uint256 vaultBal = IERC20(riskToken).balanceOf(address(ctx.vault));
        soldQty18 = (vaultBal * shareDiff18) / ONE_BPS_1e18;
        if (soldQty18 == 0) return 0;

        factoryStorage.increaseTokenPendingRebalanceAmount(riskToken, nonce, soldQty18);

        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        batch.tokenDelta[riskToken] = soldQty18;
        batch.totalUsdcObtained += (soldQty18 * ctx.cryptoPrice) / 1e18;

        ctx.vault.withdrawFunds(riskToken, address(this), soldQty18);

        IERC20(riskToken).approve(factoryStorage.riskAssetFactoryAddress(), soldQty18);
        uint256 ethFee = factoryStorage.getRedemptionFee(soldQty18);
        this.redemptionRiskAsset{value: ethFee}(soldQty18, address(ctx.usdc), ctx.path, ctx.poolFees);
    }

    function _mintCrypto5(uint256 amountUsdc, address[] calldata path, uint24[] calldata fees, uint256 feeEth)
        internal
    {
        IERC20(factoryStorage.usdc()).safeTransfer(address(factoryStorage.sca()), amountUsdc);
        uint256 usdcFee = FeeCalculation.calculateFee(amountUsdc, factoryStorage.feeRate());
        this.issuanceRiskAsset{value: feeEth}(amountUsdc - usdcFee, path, fees);
    }

    function issuanceRiskAsset(uint256 usdcAmount, address[] calldata path, uint24[] calldata fees)
        public
        payable
        onlyOwnerOrOperator
    {
        require(msg.value > 0, "balancer: no ETH");
        IRiskAssetFactory(factoryStorage.riskAssetFactoryAddress()).issuanceIndexTokens{value: msg.value}(
            address(factoryStorage.usdc()), path, fees, usdcAmount
        );
        emit IssuanceRiskAssetForRebalance(usdcAmount, block.timestamp);
    }

    function redemptionRiskAsset(uint256 amountIn, address tokenOut, address[] memory path, uint24[] memory fees)
        public
        payable
        onlyOwnerOrOperator
    {
        require(msg.value > 0, "balancer: no ETH");
        IRiskAssetFactory(factoryStorage.riskAssetFactoryAddress()).redemption{value: msg.value}(
            amountIn, tokenOut, path, fees
        );
        emit RedemptionRiskAssetForRebalance(amountIn, block.timestamp);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function pauseIndexFactory() internal {
        if (!factoryStorage.indexFactory().paused()) factoryStorage.indexFactory().pause();
    }

    function unpauseIndexFactory() internal {
        if (factoryStorage.indexFactory().paused()) factoryStorage.indexFactory().unpause();
    }
}
