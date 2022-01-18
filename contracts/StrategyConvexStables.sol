// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/utils/EnumerableSetUpgradeable.sol";
import "interfaces/uniswap/IUniswapRouterV2.sol";
import "interfaces/badger/IBadgerGeyser.sol";

import "interfaces/uniswap/IUniswapPair.sol";

import "interfaces/badger/IController.sol";

import "interfaces/badger/ISettV4.sol";

import "interfaces/convex/IBooster.sol";
import "interfaces/convex/CrvDepositor.sol";
import "interfaces/convex/IBaseRewardsPool.sol";
import "interfaces/convex/ICvxRewardsPool.sol";

import "deps/BaseStrategySwapper.sol";

import "deps/libraries/CurveSwapper.sol";
import "deps/libraries/UniswapSwapper.sol";
import "deps/libraries/TokenSwapPathRegistry.sol";

/*
    === Deposit ===
    Deposit & Stake underlying asset into appropriate convex vault (deposit + stake is atomic)

    === Tend ===
    1. Harvest gains from positions
    2. Convert CRV -> cvxCRV
    3. Stake all cvxCRV
    4. Stake all CVX

    === Harvest ===
    1. Withdraw accrued rewards from staking positions (claim unclaimed positions as well)
    2. Convert 3CRV -> CRV via USDC
    3. Swap CRV -> cvxCRV
    4. Process fees on cvxCRV harvested + swapped
    5. Deposit remaining cvxCRV into helper vault and distribute
    6. Process fees on CVX, swap CVX for bveCVX and distribute

*/
contract StrategyConvexStables is
    BaseStrategy,
    CurveSwapper,
    UniswapSwapper,
    TokenSwapPathRegistry
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    // ===== Token Registry =====
    address public constant wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant cvx = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address public constant cvxCrv = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant threeCrv =
        0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;

    IERC20Upgradeable public constant wbtcToken =
        IERC20Upgradeable(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20Upgradeable public constant crvToken =
        IERC20Upgradeable(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20Upgradeable public constant cvxToken =
        IERC20Upgradeable(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20Upgradeable public constant cvxCrvToken =
        IERC20Upgradeable(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);
    IERC20Upgradeable public constant usdcToken =
        IERC20Upgradeable(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Upgradeable public constant threeCrvToken =
        IERC20Upgradeable(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
    IERC20Upgradeable public constant bveCVX =
        IERC20Upgradeable(0xfd05D3C7fe2924020620A8bE4961bBaA747e6305);

    // ===== Convex Registry =====
    CrvDepositor public constant crvDepositor =
        CrvDepositor(0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae); // Convert CRV -> cvxCRV
    IBooster public constant booster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IBaseRewardsPool public baseRewardsPool;
    IBaseRewardsPool public constant cvxCrvRewardsPool =
        IBaseRewardsPool(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    ICvxRewardsPool public constant cvxRewardsPool =
        ICvxRewardsPool(0xCF50b810E57Ac33B91dCF525C6ddd9881B139332);
    address public constant threeCrvSwap =
        0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    uint256 public constant MAX_UINT_256 = uint256(-1);

    uint256 public pid;
    address public badgerTree;
    ISettV4 public cvxCrvHelperVault;

    /**
    === Harvest Config ===
    - stableSwapSlippageTolerance: Sets the slippage tolerance for the CRV -> cvxCRV swap and the CVX -> bveCVX swap
    - minThreeCrvHarvest: Minimum amount of 3Crv that must be harvestd (or previously harvested) for it to be processed
     */

    uint256 public stableSwapSlippageTolerance;
    uint256 public constant crvCvxCrvPoolIndex = 2;
    // Minimum 3Crv harvested to perform a profitable swap on it
    uint256 public minThreeCrvHarvest;

    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    event PerformanceFeeGovernance(
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    event PerformanceFeeStrategist(
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    event WithdrawState(
        uint256 toWithdraw,
        uint256 preWant,
        uint256 postWant,
        uint256 withdrawn
    );

    struct TendData {
        uint256 crvTended;
        uint256 cvxTended;
        uint256 cvxCrvTended;
    }

    event TendState(uint256 crvTended, uint256 cvxTended, uint256 cvxCrvTended);

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256 _pid,
        uint256[3] memory _feeConfig
    ) public initializer whenNotPaused {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        want = _wantConfig[0];
        badgerTree = _wantConfig[1];

        cvxCrvHelperVault = ISettV4(_wantConfig[2]);

        pid = _pid; // Core staking pool ID

        IBooster.PoolInfo memory poolInfo = booster.poolInfo(pid);
        baseRewardsPool = IBaseRewardsPool(poolInfo.crvRewards);

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // Approvals: Staking Pools
        IERC20Upgradeable(want).approve(address(booster), MAX_UINT_256);
        cvxToken.approve(address(cvxRewardsPool), MAX_UINT_256);
        cvxCrvToken.approve(address(cvxCrvRewardsPool), MAX_UINT_256);

        // Approvals: CRV -> cvxCRV converter
        crvToken.approve(address(crvDepositor), MAX_UINT_256);

        // Set Swap Paths
        address[] memory path = new address[](3);
        path[0] = usdc;
        path[1] = weth;
        path[2] = crv;
        _setTokenSwapPath(usdc, crv, path);

        _initializeApprovals();

        // Set default values
        stableSwapSlippageTolerance = 500;
        minThreeCrvHarvest = 1000e18;
    }

    /// ===== Permissioned Functions =====
    function setPid(uint256 _pid) external {
        _onlyGovernance();
        pid = _pid; // LP token pool ID
    }

    function initializeApprovals() external {
        _onlyGovernance();
        _initializeApprovals();
    }

    function setstableSwapSlippageTolerance(uint256 _sl) external {
        _onlyGovernance();
        stableSwapSlippageTolerance = _sl;
    }

    function setMinThreeCrvHarvest(uint256 _minThreeCrvHarvest) external {
        _onlyGovernance();
        minThreeCrvHarvest = _minThreeCrvHarvest;
    }

    function _initializeApprovals() internal {
        cvxCrvToken.approve(address(cvxCrvHelperVault), MAX_UINT_256);
    }

    /// ===== View Functions =====
    function version() external pure returns (string memory) {
        return "1.0";
    }

    function getName() external pure override returns (string memory) {
        return "StrategyConvexStables";
    }

    function balanceOfPool() public view override returns (uint256) {
        return baseRewardsPool.balanceOf(address(this));
    }

    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](4);
        protectedTokens[0] = want;
        protectedTokens[1] = crv;
        protectedTokens[2] = cvx;
        protectedTokens[3] = cvxCrv;
        return protectedTokens;
    }

    function isTendable() public view override returns (bool) {
        return true;
    }

    /// ===== Internal Core Implementations =====
    function _onlyNotProtectedTokens(address _asset) internal override {
        require(address(want) != _asset, "want");
        require(address(crv) != _asset, "crv");
        require(address(cvx) != _asset, "cvx");
        require(address(cvxCrv) != _asset, "cvxCrv");
    }

    /// @dev Deposit Badger into the staking contract
    function _deposit(uint256 _want) internal override {
        // Deposit all want in core staking pool
        booster.deposit(pid, _want, true);
    }

    /// @dev Unroll from all strategy positions, and transfer non-core tokens to controller rewards
    function _withdrawAll() internal override {
        baseRewardsPool.withdrawAndUnwrap(balanceOfPool(), false);
        // Note: All want is automatically withdrawn outside this "inner hook" in base strategy function
    }

    /// @dev Withdraw want from staking rewards, using earnings first
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        // Get idle want in the strategy
        uint256 _preWant = IERC20Upgradeable(want).balanceOf(address(this));

        // If we lack sufficient idle want, withdraw the difference from the strategy position
        if (_preWant < _amount) {
            uint256 _toWithdraw = _amount.sub(_preWant);
            baseRewardsPool.withdrawAndUnwrap(_toWithdraw, false);
        }

        // Confirm how much want we actually end up with
        uint256 _postWant = IERC20Upgradeable(want).balanceOf(address(this));

        // Return the actual amount withdrawn if less than requested
        uint256 _withdrawn = MathUpgradeable.min(_postWant, _amount);
        emit WithdrawState(_amount, _preWant, _postWant, _withdrawn);

        return _withdrawn;
    }

    function _tendGainsFromPositions() internal {
        // Harvest CRV, CVX, cvxCRV, 3CRV, and extra rewards tokens from staking positions
        // Note: Always claim extras
        baseRewardsPool.getReward(address(this), true);

        if (cvxCrvRewardsPool.earned(address(this)) > 0) {
            cvxCrvRewardsPool.getReward(address(this), true);
        }

        if (cvxRewardsPool.earned(address(this)) > 0) {
            cvxRewardsPool.getReward(false);
        }
    }

    /// @notice The more frequent the tend, the higher returns will be
    function tend() external whenNotPaused returns (TendData memory) {
        _onlyAuthorizedActors();

        TendData memory tendData;

        // 1. Harvest gains from positions
        _tendGainsFromPositions();

        // Track harvested coins, before conversion
        tendData.crvTended = crvToken.balanceOf(address(this));

        // 2. Convert CRV -> cvxCRV
        if (tendData.crvTended > 0) {
            uint256 minCvxCrvOut =
                tendData
                    .crvTended
                    .mul(MAX_FEE.sub(stableSwapSlippageTolerance))
                    .div(MAX_FEE);
            _exchange(
                crv,
                cvxCrv,
                tendData.crvTended,
                minCvxCrvOut,
                crvCvxCrvPoolIndex,
                true
            );
        }

        // Track harvested + converted coins
        tendData.cvxCrvTended = cvxCrvToken.balanceOf(address(this));
        tendData.cvxTended = cvxToken.balanceOf(address(this));

        // 3. Stake all cvxCRV
        if (tendData.cvxCrvTended > 0) {
            cvxCrvRewardsPool.stake(tendData.cvxCrvTended);
        }

        // 4. Stake all CVX
        if (tendData.cvxTended > 0) {
            cvxRewardsPool.stake(cvxToken.balanceOf(address(this)));
        }

        emit Tend(0);
        emit TendState(
            tendData.crvTended,
            tendData.cvxTended,
            tendData.cvxCrvTended
        );
        return tendData;
    }

    // No-op until we optimize harvesting strategy. Auto-compouding is key.
    function harvest() external whenNotPaused returns (uint256) {
        _onlyAuthorizedActors();

        uint256 totalWantBefore = balanceOf();

        // 1. Withdraw accrued rewards from staking positions (claim unclaimed positions as well)
        baseRewardsPool.getReward(address(this), true);

        uint256 cvxCrvRewardsPoolBalance =
            cvxCrvRewardsPool.balanceOf(address(this));
        if (cvxCrvRewardsPoolBalance > 0) {
            cvxCrvRewardsPool.withdraw(cvxCrvRewardsPoolBalance, true);
        }

        uint256 cvxRewardsPoolBalance = cvxRewardsPool.balanceOf(address(this));
        if (cvxRewardsPoolBalance > 0) {
            cvxRewardsPool.withdraw(cvxRewardsPoolBalance, true);
        }

        // 2. Convert 3CRV -> CRV via USDC
        uint256 threeCrvBalance = threeCrvToken.balanceOf(address(this));
        if (threeCrvBalance > minThreeCrvHarvest) {
            _remove_liquidity_one_coin(threeCrvSwap, threeCrvBalance, 1, 0);
            uint256 usdcBalance = usdcToken.balanceOf(address(this));
            if (usdcBalance > 0) {
                _swapExactTokensForTokens(
                    sushiswap,
                    usdc,
                    usdcBalance,
                    getTokenSwapPath(usdc, crv)
                );
            }
        }

        // 3. Swap CRV -> cvxCRV
        uint256 crvBalance = crvToken.balanceOf(address(this));
        if (crvBalance > 0) {
            uint256 minCvxCrvOut =
                crvBalance.mul(MAX_FEE.sub(stableSwapSlippageTolerance)).div(
                    MAX_FEE
                );
            _exchange(
                crv,
                cvxCrv,
                crvBalance,
                minCvxCrvOut,
                crvCvxCrvPoolIndex,
                true
            );
        }

        // 4. Process fees on cvxCRV harvested + swapped
        uint256 cvxCrvBalance = cvxCrvToken.balanceOf(address(this));
        if (cvxCrvBalance > 0) {
            // Process performance fees on CRV
            if (performanceFeeGovernance > 0) {
                uint256 cvxCrvToGovernance =
                    cvxCrvBalance.mul(performanceFeeGovernance).div(MAX_FEE);
                cvxCrvToken.safeTransfer(
                    IController(controller).rewards(),
                    cvxCrvToGovernance
                );
                emit PerformanceFeeGovernance(
                    IController(controller).rewards(),
                    cvxCrv,
                    cvxCrvToGovernance,
                    block.number,
                    block.timestamp
                );
            }

            if (performanceFeeStrategist > 0) {
                uint256 cvxCrvToStrategist =
                    cvxCrvBalance.mul(performanceFeeStrategist).div(MAX_FEE);
                cvxCrvToken.safeTransfer(strategist, cvxCrvToStrategist);
                emit PerformanceFeeStrategist(
                    strategist,
                    cvxCrv,
                    cvxCrvToStrategist,
                    block.number,
                    block.timestamp
                );
            }

            // 5. Deposit remaining cvxCRV into helper vault and distribute
            uint256 cvxCrvToTree = cvxCrvToken.balanceOf(address(this));
            // TODO: [Optimization] Allow contract to circumvent blockLock to dedup deposit operations

            uint256 treeHelperVaultBefore =
                cvxCrvHelperVault.balanceOf(badgerTree);

            // Deposit remaining to tree
            cvxCrvHelperVault.depositFor(badgerTree, cvxCrvToTree);

            uint256 treeHelperVaultAfter =
                cvxCrvHelperVault.balanceOf(badgerTree);
            uint256 treeVaultPositionGained =
                treeHelperVaultAfter.sub(treeHelperVaultBefore);

            emit TreeDistribution(
                address(cvxCrvHelperVault),
                treeVaultPositionGained,
                block.number,
                block.timestamp
            );
        }

        // 6. Process fees on CVX, swap CVX for bveCVX and distribute
        uint256 cvxBalance = cvxToken.balanceOf(address(this));
        if (cvxBalance > 0) {
            // Process performance fees on CVX
            if (performanceFeeGovernance > 0) {
                uint256 cvxToGovernance =
                    cvxBalance.mul(performanceFeeGovernance).div(MAX_FEE);
                cvxToken.safeTransfer(
                    IController(controller).rewards(),
                    cvxToGovernance
                );
                emit PerformanceFeeGovernance(
                    IController(controller).rewards(),
                    cvx,
                    cvxToGovernance,
                    block.number,
                    block.timestamp
                );
            }

            if (performanceFeeStrategist > 0) {
                uint256 cvxToStrategist =
                    cvxBalance.mul(performanceFeeStrategist).div(MAX_FEE);
                cvxToken.safeTransfer(strategist, cvxToStrategist);
                emit PerformanceFeeStrategist(
                    strategist,
                    cvx,
                    cvxToStrategist,
                    block.number,
                    block.timestamp
                );
            }

            // Exchange remaining CVX for bveCVX
            uint256 cvxToDistribute = cvxToken.balanceOf(address(this));

            uint256 minbveCVXOut =
                cvxToDistribute
                    .mul(MAX_FEE.sub(stableSwapSlippageTolerance))
                    .div(MAX_FEE);
            // Get the bveCVX here
            _exchange(
                address(cvxToken),
                address(bveCVX),
                cvxToDistribute,
                minbveCVXOut,
                0,
                true
            );

            uint256 treeHelperVaultBefore = bveCVX.balanceOf(badgerTree);

            // Deposit remaining to tree.
            uint256 bveCvxToTree = bveCVX.balanceOf(address(this));
            bveCVX.safeTransfer(badgerTree, bveCvxToTree);

            uint256 treeHelperVaultAfter = bveCVX.balanceOf(badgerTree);
            uint256 treeVaultPositionGained =
                treeHelperVaultAfter.sub(treeHelperVaultBefore);

            emit TreeDistribution(
                address(bveCVX),
                treeVaultPositionGained,
                block.number,
                block.timestamp
            );
        }

        uint256 totalWantAfter = balanceOf();
        require(totalWantAfter >= totalWantBefore, "want-decreased");
        // Expected to be 0 since there is no auto compounding
        uint256 wantGained = totalWantAfter - totalWantBefore;

        emit Harvest(wantGained, block.number);
        return wantGained;
    }
}
