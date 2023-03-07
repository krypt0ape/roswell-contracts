// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface TokenContractInterface {
    function dev_addr() external returns (address);
    function rewards_addr() external returns (address);
}

contract RoswellBiggestBuy is Ownable, ReentrancyGuard {
    event BiggestBuyCompWinner(
        address indexed addr,
        uint256 timestamp,
        uint256 rawAmount,
        uint256 topBuy
    );
    event BuyCompStarted(
        uint256 timestamp
    );
    event NewTopBuyToday(
        address indexed addr,
        uint256 indexed value
    );

    /* top lottery buyer of the day (so far) */
    uint256 public topBuyTodayAmount;
    address public topBuyTodayAddress;

    /* latest top lottery bought amount (reduced each day we have no winner) */
    uint256 public topBuy;

    /* tax splits for when we have a lottery winner */
    uint256 public rewardsPercentage = 30;
    uint256 public winnerPercentage = 30;
    uint256 public devPercentage = 10;

    uint256 constant public FEE_DENOMINATOR = 1000;

    /* @dev Some addresses should be excluded from lottery such as the buyback address  */
    mapping(address => bool) public excludeFromComp;

    TokenContractInterface private _tokenContract;

    /* @dev amount we will reduce the top buy by each day, includes one decimal so 25  === 2.5% */
    uint256 public dailyTopBuyReductionPercentage = 50;

    /** when false the contract will accumulate funds but not record max buys or payout */
    bool public startLottery;

    address public deployer;

    constructor(){
        deployer = msg.sender;
    }

    receive() external payable {}

    /**
        @dev Start the lottery recording max buys
        @param _tokenAddress the address of the roswell token
    */
    function doStartComp(address _tokenAddress) external  {
        require(_tokenAddress != address(0), "Token contract address cannot be zero");
        require(deployer == msg.sender, "Only deployer can start the lottery");
        require(deployer != owner(), "Ownership must be transferred before the lottery can be started");
        _tokenContract = TokenContractInterface(_tokenAddress);   
        startLottery = true;
        emit BuyCompStarted(block.timestamp);
    }

    /**
        @dev update the distribution %'s of the lottery winnings
        @param _dev % sent to the dev wallet
        @param _rewards % sent to the rewards wallet
        @param _winner % sent to the winner
    */
    function updatePercentages(uint256 _dev, uint256 _rewards, uint256 _winner) external onlyOwner {
        require(_dev + _rewards + _winner <= 100, "Rewards split cant be more than 100%");
        rewardsPercentage  = _rewards;
        devPercentage = _dev;
        winnerPercentage = _winner;
    }

    /**
        @dev we reduce the top buy each day so if there's one huge buy 
        over time there's still a chance for others to win the max buy
        @param _newTopBuyReductionPercentage 100 = 10%
     */
    function updateDailyTopBuyReductionPercentage(uint256 _newTopBuyReductionPercentage) external onlyOwner {
        require(_newTopBuyReductionPercentage <= 990, "Percent cant be more than 99%");
        dailyTopBuyReductionPercentage = _newTopBuyReductionPercentage;
    }

    /**
        @dev allows us to exclude wallets from the max buy record. The buyback 
        wallet for example so it doesn't always get max buys
    */
    function excludeAddressFromLottery(address _address, bool _shouldExclude) external onlyOwner {
        require(! startLottery, "Addresses can't be excluded once the lottery has started");
        excludeFromComp[_address] = _shouldExclude;
    }

    /**
        @dev Can only be trigger by the token contract to record a new buy  
        @param _amount the buy amount
        @param _address the buyer address
    */
    function newBuy(uint256 _amount, address _address) external  {
        if(msg.sender != address(_tokenContract)) return;
        if( excludeFromComp[_address] ) return;
        if(! startLottery) return;
        if(_amount > topBuyTodayAmount){
            topBuyTodayAmount = _amount;
            topBuyTodayAddress = _address;
            emit NewTopBuyToday(_address, _amount);
        }
    }

    /** 
        @dev Runs once a day and checks for lottry winner  
    */
    function checkForWinner() external nonReentrant {        
        if(msg.sender != address(_tokenContract)) return;
        if(! startLottery) return;
        if(address(this).balance == 0) return;

        if (topBuyTodayAmount > topBuy) {
            _processWin();
        } else {
            // no winner, reducing the record by dailyTopBuyReductionPercentage
            topBuy -= topBuy * dailyTopBuyReductionPercentage / FEE_DENOMINATOR;
        }
    
        // Reset the top buys
        topBuyTodayAmount = 0;
        topBuyTodayAddress = address(0);
    }

    function _processWin() internal  {
        // Set the new top amount for the next lottery
        topBuy = topBuyTodayAmount;

        // We use the full contract balance as the lottery pool
        uint256 poolBalance = address(this).balance;

        uint256 _winnerAmount = poolBalance * winnerPercentage / 100;
        uint256 _devAmount = poolBalance * devPercentage / 100;
        uint256 _rewardsAmount = poolBalance * rewardsPercentage / 100;

        if(topBuyTodayAddress != address(0)){
            Address.sendValue( payable(topBuyTodayAddress) , _winnerAmount);
        }
        
        Address.sendValue(payable(_tokenContract.dev_addr()), _devAmount);
        Address.sendValue(payable(_tokenContract.rewards_addr()), _rewardsAmount);

        emit BiggestBuyCompWinner(
            topBuyTodayAddress,
            block.timestamp,
            _winnerAmount,
            topBuy
        );
    }
}