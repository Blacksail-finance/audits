// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./BlackSail_Interface.sol";

contract Blacksail_Vault is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    mapping (address => AccountInfo) public accountData;
    // The last proposed strategy to switch to.
    UpgradedStrategy public stratCandidate;
    // The strategy currently in use by the vault.
    ISailStrategy public strategy;
    // The minimum time it has to pass before a strat candidate can be approved, set to 24 hours
    uint256 constant public approvalDelay = 86400;

    struct AccountInfo {
        uint256 actionTime;
        uint256 amount;
        string lastAction;
        bool staked;
    }

    event ProposedStrategyUpgrade(address implementation);
    event UpgradeStrat(address implementation);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    /**
    * @dev Initializes the vault contract.
    * Sets the strategy, vault token name, and symbol.
    * 
    * @param _strategy Address of the strategy contract associated with this vault.
    * @param _name Name of the vault token (e.g., "Vault Token").
    * @param _symbol Symbol of the vault token (e.g., "VT").
    * 
    * Inherits:
    * - ERC20: For managing the vault's token shares.
    * - Ownable: Assigns ownership to the deployer for administrative control. */
    constructor (
        ISailStrategy _strategy,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        strategy = _strategy;
    }

    function want() public view returns (IERC20) {
        return IERC20(strategy.staking_token());
    }

    /** @dev Calculates the total value of {token} held in the system, including:
        * Vault balance
        * Strategy contract balance
        * Balances deployed in external contracts. */
    function balance() public view returns (uint) {
        return want().balanceOf(address(this)) + (ISailStrategy(strategy).balanceOf());
    }

    /** @dev Determines how much of the vault's tokens can be borrowed. */
    function available() public view returns (uint256) {
        return want().balanceOf(address(this));
    }

    /** @dev Provides the value of one vault share in terms of the underlying asset, with 18 decimals, for UI display. */
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply() == 0 ? 1e18 : balance() * 1e18 / totalSupply();
    }

    /** @dev Calls deposit() with the sender's entire balance. */
    function depositAll() external {
        deposit(want().balanceOf(msg.sender));
    }

    /**
    * @dev Handles user deposits into the vault.
    * Transfers the specified `_amount` of tokens from the user to the vault, updates the strategy via `earn()`,
    * and mints corresponding shares to the user. Shares represent the user's proportional ownership of the vault.
    * Includes safeguards for deflationary tokens.
    * 
    * Requirements:
    * - `_amount` must be greater than zero.
    * - Caller must approve the vault to transfer their tokens.*/
    function deposit(uint _amount) public nonReentrant {
        require(_amount > 0, "Invalid amount");
        strategy.beforeDeposit();

        uint256 _pool = balance();
        want().safeTransferFrom(msg.sender, address(this), _amount);
        earn();
        uint256 _after = balance();
        _amount = _after - _pool; // Additional check for deflationary tokens
        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalSupply()) / _pool;
        }

        emit Deposit(msg.sender, _amount);
        accountData[msg.sender].lastAction = "Deposit";
        updateDeposit(msg.sender, shares);
        _mint(msg.sender, shares);
    }

    /**
    * @dev Transfers available funds from the vault to the strategy for yield optimization.
    * Moves the vault's idle balance to the strategy contract and triggers the strategy's deposit function. */
    function earn() internal {
        uint _bal = available();
        want().safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    /** @dev Helper to withdraw all funds for the sender. */
    function withdrawAll() external {
        withdraw(balanceOf(msg.sender));
    }

    /**
    * @dev Allows a user to withdraw their share of funds from the vault.
    * Burns the user's vault tokens, calculates the proportional amount of underlying tokens, and transfers them back to the user.
    * If there are insufficient funds in the vault, it withdraws the required amount from the strategy.
    * Updates the user's deposit record and ensures safe transfer of tokens.
    * @param _shares The number of vault tokens to redeem for underlying assets. */
    function withdraw(uint256 _shares) public nonReentrant {
        uint256 r = (balance() * _shares) / totalSupply();
        _burn(msg.sender, _shares);

        uint b = want().balanceOf(address(this));
        if (b < r) {
            uint _withdraw = r - b;
            strategy.withdraw(_withdraw);
            uint _after = want().balanceOf(address(this));
            uint _diff = _after - b;
            if (_diff < _withdraw) {
                r = b + _diff;
            }
        }

        emit Withdraw(msg.sender, r);
        accountData[msg.sender].lastAction = "Withdraw";
        updateDeposit(msg.sender, _shares);
        want().safeTransfer(msg.sender, r);
    }

    /** 
    * @dev Updates deposit information for an account. 
    * This function tracks user deposit/withdrawal actions, timestamps, 
    * and staking status for UI display purposes.
    * @param _account The address of the user account.
    * @param _shares The number of shares involved in the deposit/withdrawal. */
    function updateDeposit(address _account, uint256 _shares) internal {
        accountData[_account].actionTime = block.timestamp;

        // not staked
        if (!accountData[_account].staked) {

            accountData[_account].amount = _shares * balance();
            accountData[_account].lastAction = "Deposit";
            accountData[_account].staked = true;

        // fully withdrawn
        } else if (accountData[_account].staked && IERC20(address(this)).balanceOf(_account) == 0) {

            accountData[_account].amount = 0;
            accountData[_account].lastAction = "Withdraw";
            accountData[_account].staked = false;

        // modified staking
        } else {
            
            uint256 currentShare = IERC20(address(this)).balanceOf(_account) / totalSupply() * balance();

            if (accountData[_account].amount > currentShare) {
                // deposit
                accountData[_account].lastAction = "Deposit";
            } else {
                // withdraw
                accountData[_account].lastAction = "Withdraw";
            }

            accountData[_account].amount = currentShare;
        }
    }

    /**
    * @dev Retrieves account information for UI display.
    * Returns the last action time, action type (Deposit/Withdraw), 
    * and the difference in shares since the last action.
    * If no meaningful data exists, it returns 0 and "n/a".
    * @param _account The address of the user account.
    * @return actionTime The timestamp of the last action.
    * @return action The last action performed ("Deposit" or "Withdraw").
    * @return difference The difference in shares since the last recorded action.*/
    function earned(address _account) public view returns (uint256 actionTime, string memory action, uint256 difference) {
        
        uint256 currentShare = 0;

        if (IERC20(address(this)).balanceOf(_account) > 0 && totalSupply() > 0) {
            currentShare = IERC20(address(this)).balanceOf(_account) / totalSupply() * balance();
        }
        
        if (currentShare >= accountData[_account].amount) {
            return(accountData[_account].actionTime, accountData[_account].lastAction,  (currentShare - accountData[_account].amount));
        } else {
            return(0,"n/a",0);
        }
    }

    /**
    * @dev Proposes an upgrade to a new strategy for the vault.
    * Only callable by the owner. Verifies that the new strategy is valid for this vault.
    * The proposed strategy and the current timestamp are stored for later approval.
    * Emits a `ProposedStrategyUpgrade` event.
    * @param _implementation The address of the proposed new strategy.*/
    function proposeStrategyUpgrade(address _implementation) public onlyOwner {
        require(address(this) == ISailStrategy(_implementation).vault(), "Proposal not valid for this Vault");
        stratCandidate = UpgradedStrategy({
            implementation: _implementation,
            proposedTime: block.timestamp
         });

        emit ProposedStrategyUpgrade(_implementation);
    }

    /**
    * @dev Upgrades the vault to the proposed strategy after the approval delay has passed.
    * Only callable by the owner. Ensures a valid candidate strategy exists and the required delay is met.
    * Retires the current strategy and sets the new strategy as active.
    * Resets the candidate strategy details for safety and calls `earn()` to deploy funds to the new strategy.
    * Emits an `UpgradeStrat` event. */
    function upgradeStrat() public onlyOwner {
        require(stratCandidate.implementation != address(0), "There is no candidate");
        require(stratCandidate.proposedTime + approvalDelay < block.timestamp, "Delay has not passed");

        emit UpgradeStrat(stratCandidate.implementation);

        strategy.retireStrat();
        strategy = ISailStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;

        earn();
    }

    function getAccountInfo(address _account) public view returns (uint256, uint256, string memory, bool) {
        AccountInfo storage info = accountData[_account];
        return (info.actionTime, info.amount, info.lastAction, info.staked);
    }
}