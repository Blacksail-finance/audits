// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import './BlackSail_Interface.sol';

interface IIchiDepositHelper {
    function forwardDepositToICHIVault(
        address _vault,
        address _deployer,
        address _token,
        uint256 _amount,
        uint256 _minAmountOut,
        address _to
    ) external;
}

interface IUniswapRouterV3 {

 struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);
}

contract Blacksail_StrategyV3 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public immutable MAX = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    // Tokens
    address public native_token;
    address public reward_token;
    address public staking_token;
    address public deposit_token;

    // Fee structure
    uint256 public WITHDRAWAL_MAX = 100000;
    uint256 public WITHDRAW_FEE = 100;     
    uint256 public DIVISOR = 1000;
    uint256 public CALL_FEE = 100;          
    uint256 public FEE_BATCH = 900;       
    uint256 public PLATFORM_FEE = 45;      

    // Third Party Addresses
    address public rewardPool;
    address public ichi;
    address public vaultDeployer;
    address public unirouter;
    address public v3router;

    // Information
    uint256 public lastHarvest;
    bool public harvestOnDeposit;

    // Platform Addresses
    address public vault;
    address public treasury;

    // Routes
    ISolidlyRouter.Routes[] public rewardToNative;
    address[] public rewards;
    uint256 public slippageTolerance;

    event Deposit(uint256 amount);
    event Withdraw(uint256 amount);
    event Harvest(address indexed harvester);
    event ChargeFees(uint256 callFee, uint256 protocolFee);
    event SetVault(address indexed newVault);
    event SetWithdrawalFee(uint256 newFee);
    event SetSlippageTolerance(uint256 newTolerance);

    IUniswapRouterV3.ExactInputParams params;

    /**
    * @dev Constructor to initialize the strategy contract.
    * @param _staking_token The token to be staked in the third-party farm.
    * @param _rewardPool The address of the reward pool where staking and rewards occur.
    * @param _deposit_token The token to be used for deposits and reinvestments.
    * @param _ichi The address of the Ichi deposit helper contract.
    * @param _vaultDeployer The address authorized to deploy new vaults.
    * @param _unirouter The address of the Uniswap V2/V3 router for token swaps.
    * @param _v3router The address of the Uniswap V3 router for advanced swaps.
    * @param _harvestOnDeposit Boolean to enable or disable reward harvesting during deposits.
    * @param _rewardToNative The path for swapping rewards to the native token, using ISolidlyRouter routes.
    *
    * This constructor:
    * - Sets up the core token and contract addresses for staking, rewards, and routing.
    * - Enables or disables harvest-on-deposit, with a default withdrawal fee of 0 if enabled.
    * - Defines the reward-to-native token conversion path for liquidity and fee operations.
    * - Grants initial token allowances to external contracts. */

    constructor (
        address _staking_token,
        address _rewardPool,
        address _deposit_token,
        address _ichi,
        address _vaultDeployer,
        address _unirouter,
        address _v3router,
        bool _harvestOnDeposit,
        address _treasury,
        ISolidlyRouter.Routes[] memory _rewardToNative
    ) Ownable(msg.sender) {

        staking_token = _staking_token;
        rewardPool = _rewardPool;
        ichi = _ichi;
        vaultDeployer = _vaultDeployer;
        unirouter = _unirouter;
        v3router = _v3router;
        treasury = _treasury;

        harvestOnDeposit = _harvestOnDeposit;
        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        }

        for (uint i; i < _rewardToNative.length; i++) {
            rewardToNative.push(_rewardToNative[i]);
        }

        reward_token = rewardToNative[0].from;
        native_token = rewardToNative[rewardToNative.length - 1].to;
        deposit_token = _deposit_token;

        rewards.push(reward_token);
        _giveAllowances();
    }

    /** @dev Sets the vault connected to this strategy */
    function setVault(address _vault) external onlyOwner {
        require(isContract(_vault), "Vault must be a contract");
        vault = _vault;
        emit SetVault(_vault);
    }

    /** @dev Function to synchronize balances before new user deposit. Can be overridden in the strategy. */
    function beforeDeposit() external virtual {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "Vault deposit only");
            _harvest(address(this));
        }
    }

    /** @dev Deposits funds into third party farm */
    function deposit() public onlyAuthorized whenNotPaused {

        uint256 staking_balance = IERC20(staking_token).balanceOf(address(this));

        if (staking_balance > 0) {
           IEqualizerPool(rewardPool).deposit(staking_balance);
        } 
    }

    /**
    * @dev Withdraws a specified amount of staking tokens to the vault. 
    * Handles balance retrieval from the reward pool if needed and deducts withdrawal fees if applicable.
    * 
    * @param _amount The amount of staking tokens to withdraw.
    *
    * Requirements:
    * - Can only be called by the vault.
    * - If not the owner and contract is not paused, a withdrawal fee is deducted unless `harvestOnDeposit` is enabled.
    *
    * Emits a {Withdraw} event with the updated strategy balance. */

    function withdraw(uint256 _amount) external nonReentrant {
        require(msg.sender == vault, "!vault");

        uint256 stakingBal = IERC20(staking_token).balanceOf(address(this));

        if (stakingBal < _amount) {
            IEqualizerPool(rewardPool).withdraw(_amount - stakingBal);
            stakingBal = IERC20(staking_token).balanceOf(address(this));
        }           
 
        if (stakingBal > _amount) {
            stakingBal = _amount;
        }

        uint256 wFee = (stakingBal * WITHDRAW_FEE) / WITHDRAWAL_MAX;

        if (!paused() && !harvestOnDeposit) {
            stakingBal = stakingBal - wFee;
        }

        IERC20(staking_token).safeTransfer(vault, stakingBal);

        emit Withdraw(balanceOf());
    }

    /**
    * @dev Triggers the harvest process to compound earnings.
    * Internally calls `_harvest` to collect rewards, charge fees, add liquidity, and reinvest. */

    function harvest() external {
        require(!isContract(msg.sender) || msg.sender == vault, "!auth Contract Harvest");
        _harvest(msg.sender);
    }

    /** @dev Compounds the strategy's earnings and charges fees */
    function _harvest(address caller) internal whenNotPaused {
        
        IEqualizerPool(rewardPool).getReward(address(this), rewards);
        uint256 rewardAmt = IERC20(reward_token).balanceOf(address(this));

        if (rewardAmt > 0){
            chargeFees(caller);
            addLiquidity();
            deposit();
        }

        lastHarvest = block.timestamp;
        emit Harvest(msg.sender);
    }

    /** @dev This function converts all funds to WFTM, charges fees, and sends fees to respective accounts */
    function chargeFees(address caller) internal {                  
        uint256 toNative = IERC20(reward_token).balanceOf(address(this));
        require(toNative > 0, "Insufficient reward token balance");

        uint256 allowance = IERC20(reward_token).allowance(address(this), unirouter);
        require(allowance >= toNative, "Insufficient reward token allowance");

        ISolidlyRouter(unirouter).swapExactTokensForTokens(toNative, 0, rewardToNative, address(this), block.timestamp);
        
        uint256 nativeBal = IERC20(native_token).balanceOf(address(this));
        require(nativeBal > 0, "Insufficient native token balance");

        uint256 platformFee = (nativeBal * PLATFORM_FEE) / DIVISOR;
        uint256 callFeeAmount = (platformFee * CALL_FEE) / DIVISOR;
        uint256 treasuryFee = platformFee - callFeeAmount;

        if (caller != address(this)) {
            IERC20(native_token).safeTransfer(caller, callFeeAmount);
        }
        
        IERC20(native_token).safeTransfer(treasury, treasuryFee);

        emit ChargeFees(callFeeAmount, platformFee);
    }

    /**
    * @dev Adds liquidity by converting native tokens to the deposit token and forwarding them to the ICHI Vault.
    * 
    * - Checks for sufficient native token balance.
    * - Converts native tokens to the deposit token using the Uniswap V3 router if required.
    * - Approves the necessary allowances for the Uniswap V3 router.
    * - Forwards the converted deposit tokens to the ICHI Vault for staking.
    *
    * Requirements:
    * - The contract must have a positive balance of the native token. */

    function addLiquidity() internal {
        uint256 nativeBalance = IERC20(native_token).balanceOf(address(this));
        require(nativeBalance > 0, "No native token balance");
        
        params.path = abi.encodePacked(native_token, uint24(3000), deposit_token);

        uint256 estimatedAmountOut = IUniswapRouterV3(v3router).quoteExactInput(params.path, nativeBalance);

        require(estimatedAmountOut > 0, "Invalid quote from router");

        uint256 minimumAmountOut = (estimatedAmountOut * (10000 - slippageTolerance)) / 10000;

        params.amountIn = nativeBalance;
        params.recipient = address(this);
        params.amountOutMinimum = minimumAmountOut;

        IERC20(native_token).approve(v3router, nativeBalance);

        if (native_token != deposit_token) {
            try IUniswapRouterV3(v3router).exactInput(params) returns (uint256 amountOut) {
                // Success
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Swap failed: ", reason)));
            } catch (bytes memory lowLevelData) {
                revert(string(abi.encodePacked("Swap failed with low-level data: ", lowLevelData)));
            }
        }

        uint256 depositTokenBal = IERC20(deposit_token).balanceOf(address(this));

        if (depositTokenBal > 0) {
            try IIchiDepositHelper(ichi).forwardDepositToICHIVault(
            staking_token,
            vaultDeployer,
            deposit_token,
            depositTokenBal,
            0,
            address(this)
            ) {
               
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Deposit to ICHI Vault failed: ", reason)));
            } catch (bytes memory lowLevelData) {
                revert(string(abi.encodePacked("Deposit to ICHI Vault failed with low-level data: ", lowLevelData)));
            }
        }
    }

    /** @dev Determines the amount of reward in WFTM upon calling the harvest function */
    function harvestCallReward() public view returns (uint256) {
        uint256 rewardBal = rewardsAvailable();
        uint256 nativeOut;
        if (rewardBal > 0) {
            (nativeOut, ) = ISolidlyRouter(unirouter).getAmountOut(rewardBal, reward_token, native_token);
        }

        return (((nativeOut * PLATFORM_FEE) / DIVISOR) * CALL_FEE) / DIVISOR;
    }

    /** @dev Sets harvest on deposit to @param _harvestOnDeposit */
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyOwner {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    /** @dev Returns the amount of rewards that are pending */
    function rewardsAvailable() public view returns (uint256) {
        return IEqualizerPool(rewardPool).earned(reward_token, address(this));
    }

    /** @dev calculate the total underlaying staking tokens held by the strat */
    function balanceOf() public view returns (uint256) {
        return balanceOfStakingToken() + balanceOfPool();
    }

    /** @dev it calculates how many staking tokens this contract holds */
    function balanceOfStakingToken() public view returns (uint256) {
        return IERC20(staking_token).balanceOf(address(this));
    }

    /** @dev it calculates how many staking tokens the strategy has working in the farm */
    function balanceOfPool() public view returns (uint256) {
        return IEqualizerPool(rewardPool).balanceOf(address(this));
        // return _amount;
    }

    /** @dev called as part of strat migration. Sends all the available funds back to the vault */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");
        IEqualizerPool(rewardPool).withdraw(balanceOfPool());
        uint256 stakingBal = IERC20(staking_token).balanceOf(address(this));
        IERC20(staking_token).transfer(vault, stakingBal);
    }

    /** @dev Pauses the strategy contract and executes the emergency withdraw function */
    function panic() public onlyOwner {
        pause();
        IEqualizerPool(rewardPool).withdraw(balanceOfPool());
    }

    /** @dev Pauses the strategy contract */
    function pause() public onlyOwner {
        _pause();
        _removeAllowances();
    }

    /** @dev Unpauses the strategy contract */
    function unpause() external onlyOwner {
        _unpause();
        _giveAllowances();
        deposit();
    }

    /** @dev Gives allowances to spenders */
    function _giveAllowances() internal {
        IERC20(staking_token).approve(rewardPool, MAX);
        IERC20(reward_token).approve(unirouter, MAX);
        IERC20(native_token).approve(v3router, MAX);
        IERC20(deposit_token).approve(ichi, MAX);
    }

    /** @dev Removes allowances to spenders */
    function _removeAllowances() internal {
        IERC20(staking_token).approve(rewardPool, 0);
        IERC20(reward_token).approve(unirouter, 0);
        IERC20(native_token).approve(v3router, 0);
        IERC20(deposit_token).approve(ichi, 0);
    }

    /**
    * @dev Sets the withdrawal fee for the strategy.
    *
    * - Ensures that the fee does not exceed 100 (representing 1%).
    * - Updates the `WITHDRAW_FEE` variable with the new fee value.
    *
    * Requirements:
    * - `fee` must be less than or equal to 100.
    *
    * @param fee The new withdrawal fee (scaled by 100,000 for precision). */

    function setWithdrawalFee(uint256 fee) internal {
        require(fee <= 100, "Fee too high");

        WITHDRAW_FEE = fee;
        emit SetWithdrawalFee(fee);
    }

    /**
    * @dev Allows the contract owner to set the slippage tolerance for token swaps.
    * This value is used to calculate the minimum acceptable output amount in swaps,
    * helping to mitigate the risks of slippage and unfavorable price changes.
    * 
    * Requirements:
    * - The caller must be the contract owner.
    * - The provided tolerance must be less than or equal to 1500 (representing a maximum of 15% slippage).
    * 
    * Emits:
    * - A {SetSlippageTolerance} event indicating the updated slippage tolerance.
    * 
    * @param _tolerance The new slippage tolerance value, scaled by 10,000 (e.g., 1500 = 15%).
    */
    function setSlippageTolerance(uint256 _tolerance) external onlyOwner {
        require(_tolerance <= 1500, "Invalid tolerance"); // Max 15%

        slippageTolerance = _tolerance;
        emit SetSlippageTolerance(slippageTolerance);
    }

    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    modifier onlyAuthorized() {
        require(msg.sender == vault || msg.sender == address(this), "Not authorized, only Vault or Strategy");
        _;
    }
}