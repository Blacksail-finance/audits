// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface ISailFactory {
    function treasury() external view returns (address);
    function paused() external view returns (bool);
}

interface ISailCurve {
    function mustStaySAIL(address account) external view returns (uint256);
}

interface IxSAIL {
    function balanceOf(address account) external view returns (uint256);
}

interface ISailWhalePrevention {
    function timelockRemaining() external view returns (bool active, uint256 timeleft);
}

interface ISailStrategy { 
    function vault() external view returns (address);
    function staking_token() external view returns (address);
    function beforeDeposit() external;
    function deposit() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
    function lastHarvest() external view returns (uint256);
    function harvest() external;
    function retireStrat() external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

interface ISailVault {
    function want() external view returns (IERC20);
    function strategy() external view returns (ISailStrategy);
    function balance() external view returns (uint);
    function available() external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256);
    function earned(address account) external view returns (uint256, string memory, uint256);
}

struct UpgradedStrategy {
    address implementation;
    uint proposedTime;
}

interface IRewardPool {

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address user, address[] memory rewards) external;
    function earned(address token, address user) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stake() external view returns (address);
}

interface ISolidlyRouter {
    
    struct Routes {
        address from;
        address to;
        bool stable;
    }

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        bool stable,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokensSimple(
        uint amountIn,
        uint amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Routes[] memory route,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] memory route,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function getAmountOut(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint amount, bool stable);
    function getAmountsOut(uint amountIn, Routes[] memory routes) external view returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, Route[] memory routes) external view returns (uint[] memory amounts);
    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired
    ) external view returns (uint amountA, uint amountB, uint liquidity);
    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory,
        uint amountADesired,
        uint amountBDesired
    ) external view returns (uint amountA, uint amountB, uint liquidity);
    function defaultFactory() external view returns (address);
}

interface IEqualizerPool {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address user, address[] memory rewards) external;
    function earned(address token, address user) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stake() external view returns (address);
}


