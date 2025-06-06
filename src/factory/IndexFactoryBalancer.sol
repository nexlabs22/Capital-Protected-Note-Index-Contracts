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
import {Vault} from "../vault/Vault.sol";
import {StagingCustodyAccount} from "../SCA/StagingCustodyAccount.sol";

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
        address[] path;
        uint24[] poolFees;
    }

    struct Vars {
        uint256 usdcBal;
        bool bondDeficit;
        bool cr5Deficit;
    }

    uint256 constant ONE_BPS_1e18 = 1e18;

    mapping(uint256 => RebalanceBatch) private _rebalanceBatches;

    uint256 public rebalanceNonce;

    IndexFactoryStorage public factoryStorage;
    FunctionsOracle public functionsOracle;

    // event FirstRebalanceAction(uint256 nonce, uint256 time);
    event FirstRebalanceAction( // token decimals
        // 18-dec
    uint256 indexed nonce, address[] tokensSold, uint256[] amountsSold, uint256 usdcExpected, uint256 time);
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

    function _processToken(uint256 nonce, address token, uint256 nav18, Ctx memory ctx)
        internal
        returns (bool sold, uint256 qty18Sold)
    {
        uint256 cur = functionsOracle.tokenCurrentMarketShare(token);
        uint256 tgt = functionsOracle.tokenOracleMarketShare(token);
        if (cur <= tgt) return (false, 0);

        uint256 usdCut18 = (nav18 * (cur - tgt)) / ONE_BPS_1e18;

        if (functionsOracle.tokenAssetType(token) == 0) {
            qty18Sold = _sellBond(nonce, token, usdCut18, ctx);
        } else {
            qty18Sold = _redeemCR5(nonce, token, usdCut18, ctx);
        }
        sold = true;
    }

    function _sellBond(uint256 nonce, address bondToken, uint256 usdCut18, Ctx memory ctx)
        internal
        returns (uint256 qty18)
    {
        qty18 = (usdCut18 * 1e18) / ctx.bondPrice18;
        RebalanceBatch storage b = _rebalanceBatches[nonce];
        b.tokenDelta[bondToken] = qty18;
        b.totalUsdcObtained += usdCut18;
        ctx.vault.withdrawFunds(bondToken, address(this), qty18);
    }

    function _redeemCR5(uint256 nonce, address cr5Token, uint256 usdCut18, Ctx memory ctx)
        internal
        returns (uint256 qty18)
    {
        qty18 = (usdCut18 * 1e18) / ctx.cryptoPrice18;
        RebalanceBatch storage b = _rebalanceBatches[nonce];
        b.tokenDelta[cr5Token] = qty18;
        b.totalUsdcObtained += usdCut18;

        ctx.vault.withdrawFunds(cr5Token, address(ctx.sca), qty18);

        uint256 ethFee = factoryStorage.getRedemptionFee(qty18);
        ctx.sca.redemptionCrypto5{value: ethFee}(qty18, address(ctx.usdc), ctx.path, ctx.poolFees);
    }

    function firstRebalanceAction(
        uint256 bondPrice18,
        uint256 cryptoPrice18,
        address[] calldata tokenInPath,
        uint24[] calldata tokenInFees
    ) external nonReentrant whenNotPaused returns (uint256 nonce) {
        pauseIndexFactory();

        Ctx memory ctx = Ctx({
            bondPrice18: bondPrice18,
            cryptoPrice18: cryptoPrice18,
            vault: factoryStorage.vault(),
            sca: factoryStorage.sca(),
            usdc: factoryStorage.usdc(),
            path: tokenInPath,
            poolFees: tokenInFees
        });

        nonce = ++rebalanceNonce;
        RebalanceBatch storage batch = _rebalanceBatches[nonce];
        require(!batch.firstDone, "rebalance: phase-1 done");

        uint256 nav18 = factoryStorage.getPortfolioValue(bondPrice18, cryptoPrice18);

        uint256 compCnt = functionsOracle.totalCurrentList();
        address[] memory soldTok = new address[](compCnt);
        uint256[] memory soldQty = new uint256[](compCnt);
        uint256 soldLen;

        for (uint256 i; i < compCnt; ++i) {
            address token = functionsOracle.currentList(i);
            (bool didSell, uint256 qty18) = _processToken(nonce, token, nav18, ctx);
            if (didSell) {
                soldTok[soldLen] = token;
                soldQty[soldLen] = qty18;
                ++soldLen;
            }
        }

        batch.firstDone = true;

        assembly {
            mstore(soldTok, soldLen)
            mstore(soldQty, soldLen)
        }

        emit FirstRebalanceAction(nonce, soldTok, soldQty, batch.totalUsdcObtained, block.timestamp);
    }

    function _mintCrypto5(uint256 amountUsdc, address[] calldata path, uint24[] calldata fees, uint256 msgValue)
        internal
    {
        StagingCustodyAccount sca = factoryStorage.sca();

        IERC20 usdc = factoryStorage.usdc();
        usdc.safeTransfer(address(sca), amountUsdc);

        uint256 feeEth = factoryStorage.getIssuanceFee(address(usdc), path, fees, amountUsdc);
        require(msgValue == feeEth, "wrong ETH fee");

        sca.issuanceCrypto5{value: feeEth}(amountUsdc, path, fees);
    }

    function secondRebalanceAction(uint256 batchId, address[] calldata tokenInPath, uint24[] calldata tokenInFees)
        external
        payable
        nonReentrant /*onlyOwnerOrOperator*/
    {
        RebalanceBatch storage batch = _rebalanceBatches[batchId];
        require(batch.firstDone, "rebalance: phase-1 not done");
        require(!batch.secondDone, "rebalance: phase-2 already done");

        IERC20 usdc = factoryStorage.usdc();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) revert("no USDC to deploy");

        Vars memory v;
        v.usdcBal = bal;

        address bondTok = factoryStorage.bond();
        address cr5Tok = address(factoryStorage.indexToken());

        v.bondDeficit =
            functionsOracle.tokenCurrentMarketShare(bondTok) < functionsOracle.tokenOracleMarketShare(bondTok);

        v.cr5Deficit = functionsOracle.tokenCurrentMarketShare(cr5Tok) < functionsOracle.tokenOracleMarketShare(cr5Tok);

        if (v.bondDeficit) {
            require(msg.value == 0, "unexpected ETH fee");
            usdc.safeTransfer(factoryStorage.nexBot(), v.usdcBal);
            batch.tokenDelta[bondTok] = 0;
        } else if (v.cr5Deficit) {
            _mintCrypto5(v.usdcBal, tokenInPath, tokenInFees, msg.value);
            batch.tokenDelta[cr5Tok] = 0;
        } else {
            require(msg.value == 0, "unexpected ETH fee");
            usdc.safeTransfer(address(factoryStorage.vault()), v.usdcBal);
        }

        batch.secondDone = true;
        emit SecondRebalanceAction(batchId, block.timestamp);
    }

    // function secondRebalanceAction(uint256 _rebalanceNonce) public nonReentrant /*onlyOwnerOrOperator*/ {
    //     RebalanceBatch storage batch = _rebalanceBatches[_rebalanceNonce];
    //     require(batch.firstDone, "phase-1 not done");
    //     require(!batch.secondDone, "already done");

    //     emit SecondRebalanceAction(_rebalanceNonce, block.timestamp);
    // }

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
        // address indexFactoryAddress = address(factoryStorage.indexFactory());
        // IndexFactory indexFactory = IndexFactory(payable(indexFactoryAddress));
        if (!factoryStorage.indexFactory().paused()) {
            factoryStorage.indexFactory().pause();
        }
    }

    function unpauseIndexFactory() internal {
        // address indexFactoryAddress = address(factoryStorage.indexFactory());
        // IndexFactory indexFactory = IndexFactory(payable(indexFactoryAddress));
        if (factoryStorage.indexFactory().paused()) {
            factoryStorage.indexFactory().unpause();
        }
    }
}
