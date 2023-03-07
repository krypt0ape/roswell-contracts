// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface TokenContractInterface {
    function calcDay() external view returns (uint256);

    function lobbyEntry(uint256 _day) external view returns (uint256);

    function balanceOf(address _owner) external view returns (uint256 balance);

    function transfer(address _to, uint256 _value)
        external
        returns (bool success);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool success);

    function dev_addr() external view returns (address);
}

contract RoswellStaking is Ownable, ReentrancyGuard {
    event NewStake(
        address indexed addr,
        uint256 timestamp,
        uint256 indexed stakeId,
        uint256 stakeAmount,
        uint256 stakeDuration
    );
    event StakeCollected(
        address indexed addr,
        uint256 timestamp,
        uint256 indexed stakeId,
        uint256 stakeAmount,
        uint256 divsReceived
    );
    event SellStakeRequest(
        address indexed addr,
        uint256 timestamp,
        uint256 indexed stakeId,
        uint256 price
    );
    event CancelStakeSellRequest(
        address indexed addr,
        uint256 timestamp,
        uint256 indexed stakeId
    );
    event StakeSold(
        address indexed from,
        address indexed to,
        uint256 timestamp,
        uint256 sellAmount,
        uint256 indexed stakeId
    );
    event NewLoanRequest(
        address indexed addr,
        uint256 timestamp,
        uint256 loanAmount,
        uint256 interestAmount,
        uint256 duration,
        uint256 indexed stakeId
    );
    event LoanRequestFilled(
        address indexed filledBy,
        uint256 timestamp,
        address indexed receivedBy,
        uint256 loanamount,
        uint256 indexed stakeId
    );
    event LoanRepaid(
        address indexed paidTo,
        uint256 timestamp,
        uint256 interestAmount,
        uint256 loanamount,
        uint256 indexed stakeId
    );
    event CancelLoanRequest(
        address indexed addr,
        uint256 timestamp,
        uint256 indexed stakeId
    );

    struct stake {
        address owner;
        uint256 tokensStaked;
        uint256 startDay;
        uint256 endDay;
        uint256 forSalePrice;
        uint256 loanRepayments; // loan repayments made on this stake (deduct from divs on withdrawal)
        bool hasCollected;
    }

    /* A map for each  stakeId => struct stake */
    mapping(uint256 => stake) public mapStakes;
    uint256 public lastStakeIndex;
    /* Address => stakeId for a users stakes */
    mapping(address => uint256[]) internal _userStakes;

    struct loan {
        address requestedBy;
        address filledBy;
        uint256 loanAmount;
        uint256 loanInterest;
        uint256 loanDuration;
        uint256 startDay;
        uint256 endDay;
    }
    /* A map for each loan loanId => struct loan */
    mapping(uint256 => loan) public mapLoans;
    /* Address => stakeId for a users loans (address is the person filling the loan not receiving it) */
    mapping(address => uint256[]) internal _userLends;

    /** Hold amount of eth owed to dev fees */
    uint256 public devFees;

    /** Total ETH in the dividend pool for each day */
    mapping(uint256 => uint256) public dayDividendPool;

    /** Total tokens that have been staked each day */
    mapping(uint256 => uint256) public tokensInActiveStake;

    /** TokenContract object  */
    TokenContractInterface public _tokenContract;

    /** Ensures that token contract can't be changed for securiy */
    bool public tokenContractAddressSet = false;

    /** The amount of days each days divs would be spread over */
    uint256 public maxDividendRewardDays = 20;

    /** The max amount of days user can stake */
    uint256 public maxStakeDays = 60;

    uint256 constant public devSellStakeFee = 10;
    uint256 constant public devLoanFeePercent = 2;

    address public deployer;

    uint256 private _daysToSplitRewardsOver = 1;

    constructor() {
        deployer = msg.sender;
    }

    receive() external payable {}

    /**
        @dev Set the contract address, must be run before any eth is posted
        to the contract
        @param _address the token contract address
    */
    function setTokenContractAddress(address _address) external {
        require(_address != address(0), "Address cannot be zero");
        require(tokenContractAddressSet == false, "Token contract address already set");
        require(msg.sender==deployer, "Only deployer can set this value");
        require(owner() != deployer, "Ownership must be transferred before contract start");
        tokenContractAddressSet = true;
        _tokenContract = TokenContractInterface(_address);
    }

    /**
        @dev runs when and eth is sent to the divs contract and distros
        it out across the total div days
    */
    function receiveDivs() external payable {
        // calcDay will return 2 when we're processing the divs from day 1
        uint256 _day =  _tokenContract.calcDay();
        require(_day > 1, "receive divs not yet enabled");
        // We process divs for previous day;
        _day--;

        require(msg.sender == address(_tokenContract), "Unauthorized");

        if(_day <= 4) {
          _daysToSplitRewardsOver++;
        }
        else if (_day <= 7) {
            _daysToSplitRewardsOver--;
        }else if (_daysToSplitRewardsOver < maxDividendRewardDays) {
            _daysToSplitRewardsOver++;
        }
        
        uint256 _totalDivsPerDay = msg.value / _daysToSplitRewardsOver ;
        
        for (uint256 i = 1; i <= _daysToSplitRewardsOver; ) {
            dayDividendPool[_day + i] += _totalDivsPerDay;
            unchecked {
                i++;
            }
        }
    }

    /**
        @dev update the max days dividends are spread over
        @param _newMaxRewardDays the max days
    */
    function updateMaxDividendRewardDays(uint256 _newMaxRewardDays) external onlyOwner {
        require((_newMaxRewardDays <= 60 && _newMaxRewardDays >= 10), "New value must be <= 60 & >= 10");
        maxDividendRewardDays = _newMaxRewardDays;
    }

    /**
     * @dev set the max staking days
     * @param _amount the number of days
     */
    function updateMaxStakeDays(uint256 _amount) external onlyOwner {
        require((_amount <= 300 && _amount > 5), "New value must be <= 300 and > 5");
        maxStakeDays = _amount;
    }

    /**
     * @dev User creates a new stake 
     * @param _amount total tokens to stake
     * @param _days must be less than max stake days. 
     * the more days the higher the gas fee
     */
    function newStake(uint256 _amount, uint256 _days) external nonReentrant {
        require(_days > 1, "Staking: Staking days < 1");
        require(
            _days <= maxStakeDays,
            "Staking: Staking days > max_stake_days"
        );

        uint256 _currentDay = _tokenContract.calcDay();
        require(_currentDay > 0, "Staking not enabled");

        bool success = _tokenContract.transferFrom(msg.sender, address(this), _amount);
        require(success, "Transfer failed");


        uint256 _stakeId = _getNextStakeId();

        uint256 _endDay =_currentDay + 1 + _days;
        uint256 _startDay = _currentDay + 1;
        mapStakes[_stakeId] = stake({
            owner: msg.sender,
            tokensStaked: _amount,
            startDay: _startDay,
            endDay: _endDay,
            forSalePrice: 0,
            hasCollected: false,
            loanRepayments: 0
        });

        for (uint256 i = _startDay; i < _endDay ;) {
            tokensInActiveStake[i] += _amount;

            unchecked{ i++; }
        }

        _userStakes[msg.sender].push(_stakeId);

        emit NewStake(msg.sender, block.timestamp, _stakeId, _amount, _days);
    }

    /** 
     * @dev Get the next stake id index 
     */
    function _getNextStakeId() internal returns (uint256) {
        lastStakeIndex++;
        return lastStakeIndex;
    }

    /**
     * @dev called by user to collect an outstading stake
     */
    function collectStake(uint256 _stakeId) external nonReentrant {
        stake storage _stake = mapStakes[_stakeId];
        uint256 currentDay = _tokenContract.calcDay();
        
        require(_stake.owner == msg.sender, "Unauthorised");
        require(_stake.hasCollected == false, "Already Collected");
        require( currentDay > _stake.endDay , "Stake hasn't ended");

        // Check for outstanding loans
        loan storage _loan = mapLoans[_stakeId];
        if(_loan.filledBy != address(0)){
            // Outstanding loan has not been paid off 
            // so do that now
            repayLoan(_stakeId);
        } else if (_loan.requestedBy != address(0)) {
            _clearLoan(_stakeId);   
        }

        // Get new instance of loan after potential updates
        _loan = mapLoans[_stakeId];

         // Get the loan from storage again 
         // and check its cleard before we move on
        require(_loan.filledBy == address(0), "Stake has unpaid loan");
        require(_loan.requestedBy == address(0), "Stake has outstanding loan request");
            
        uint256 profit = calcStakeCollecting(_stakeId);
        mapStakes[_stakeId].hasCollected = true;

        // Send user the stake back
        bool success = _tokenContract.transfer(
            msg.sender,
            _stake.tokensStaked
        );
        require(success, "Transfer failed");

        // Send the user divs
        Address.sendValue( payable(_stake.owner) , profit);

        emit StakeCollected(
            _stake.owner,
            block.timestamp,
            _stakeId,
            _stake.tokensStaked,
            profit
        );
    }

    /** 
     * Added an auth wrapper to the cancel loan request
     * so it cant be canceled by just anyone externally
     */
    function cancelLoanRequest(uint256 _stakeId) external {
        stake storage _stake = mapStakes[_stakeId];
        require(msg.sender == _stake.owner, "Unauthorised");
        _cancelLoanRequest(_stakeId);
    }

    function _cancelLoanRequest(uint256 _stakeId) internal {
        mapLoans[_stakeId] = loan({
            requestedBy: address(0),
            filledBy: address(0),
            loanAmount: 0,
            loanInterest: 0,
            loanDuration: 0,
            startDay: 0,
            endDay: 0
        });

        emit CancelLoanRequest(
            msg.sender,
            block.timestamp,
            _stakeId
        );
    }

    function _clearLoan(uint256 _stakeId) internal {
        loan storage _loan = mapLoans[_stakeId];
         if(_loan.filledBy == address(0)) {
                // Just an unfilled loan request so we can cancel it off
                _cancelLoanRequest(_stakeId);
            } else  {
                // Loan was filled so if its not been claimed yet we need to 
                // send the repayment back to the loaner
                repayLoan(_stakeId);
            }
    }

    /**
     * @dev Calculating a stakes ETH divs payout value by looping through each day of it
     * @param _stakeId Id of the target stake
     */
    function calcStakeCollecting(uint256 _stakeId)
        public
        view
        returns (uint256)
    {
        uint256 currentDay = _tokenContract.calcDay();
        uint256 userDivs;
        stake memory _stake = mapStakes[_stakeId];

        for (
            uint256 _day = _stake.startDay;
            _day < _stake.endDay && _day < currentDay;
        ) {
            userDivs +=
                (dayDividendPool[_day] * _stake.tokensStaked) /
                tokensInActiveStake[_day];

                unchecked {
                    _day++;
                }
        }

        delete currentDay;
        delete _stake;

        // remove any loans returned amount from the total
        return (userDivs - _stake.loanRepayments);
    }

    function listStakeForSale(uint256 _stakeId, uint256 _price) external {
        stake memory _stake = mapStakes[_stakeId];
        require(_stake.owner == msg.sender, "Unauthorised");
        require(_stake.hasCollected == false, "Already Collected");

        uint256 _currentDay = _tokenContract.calcDay();
        require(_stake.endDay >= _currentDay, "Stake has ended");

         // can't list a stake for sale whilst we have an outstanding loan against it
        loan storage _loan = mapLoans[_stakeId];
        require(_loan.requestedBy == address(0), "Stake has an outstanding loan request");

        mapStakes[_stakeId].forSalePrice = _price;

        emit SellStakeRequest(msg.sender, block.timestamp, _stakeId, _price);

        delete _currentDay;
        delete _stake;
    }

    function cancelStakeSellRequest(uint256 _stakeId) external {
        require(mapStakes[_stakeId].owner == msg.sender, "Unauthorised");
        require(mapStakes[_stakeId].forSalePrice > 0, "Stake is not for sale");
        mapStakes[_stakeId].forSalePrice = 0;

        emit CancelStakeSellRequest(
            msg.sender,
            block.timestamp,
            _stakeId
        );
    }

    function buyStake(uint256 _stakeId) external payable nonReentrant {
        stake memory _stake = mapStakes[_stakeId];
        require(_stake.forSalePrice > 0, "Stake not for sale");
        require(_stake.owner != msg.sender, "Can't buy own stakes");

        loan storage _loan = mapLoans[_stakeId];
        require(_loan.filledBy == address(0), "Can't buy stake with unpaid loan");

        uint256 _currentDay = _tokenContract.calcDay();
        require(
            _stake.endDay > _currentDay,
            "stake can't be brought after it has ended"
        );
        require(_stake.hasCollected == false, "Stake already collected");
        require(msg.value >= _stake.forSalePrice, "msg.value is < stake price");

        uint256 _devShare = (_stake.forSalePrice * devSellStakeFee) / 100;
        uint256 _sellAmount =  _stake.forSalePrice - _devShare;

        dayDividendPool[_currentDay] += _devShare / 2;
        devFees += _devShare / 2;

        _userStakes[msg.sender].push(_stakeId);

        mapStakes[_stakeId].owner = msg.sender;
        mapStakes[_stakeId].forSalePrice = 0;

        Address.sendValue(payable(_stake.owner), _sellAmount);

        emit StakeSold(
            _stake.owner,
            msg.sender,
            block.timestamp,
            _sellAmount,
            _stakeId
        );

        delete _stake;
    }

    /**
     * @dev send the devFees to the dev wallet
     */
    function flushDevTaxes() external nonReentrant{
        address _devWallet = _tokenContract.dev_addr();
        uint256 _devFees = devFees;
        devFees = 0;
        Address.sendValue(payable(_devWallet), _devFees);
    }

    function requestLoanOnStake(
        uint256 _stakeId,
        uint256 _loanAmount,
        uint256 _interestAmount,
        uint256 _duration
    ) external {

        stake storage _stake = mapStakes[_stakeId];
        require(_stake.owner == msg.sender, "Unauthorised");
        require(_stake.hasCollected == false, "Already Collected");

        uint256 _currentDay = _tokenContract.calcDay();
        require(_stake.endDay > (_currentDay + _duration), "Loan must expire before stake end day");

        loan storage _loan = mapLoans[_stakeId];
        require(_loan.filledBy == address(0), "Stake already has outstanding loan");

        uint256 userDivs = calcStakeCollecting(_stakeId);
        require(userDivs > ( _stake.loanRepayments + _loanAmount + _interestAmount), "Loan amount is > divs earned so far");


        mapLoans[_stakeId] = loan({
            requestedBy: msg.sender,
            filledBy: address(0),
            loanAmount: _loanAmount,
            loanInterest: _interestAmount,
            loanDuration: _duration,
            startDay: 0,
            endDay: 0
        });

        emit NewLoanRequest(
            msg.sender,
            block.timestamp,
            _loanAmount,
            _interestAmount,
            _duration,
            _stakeId
        );
    }

    function fillLoan(uint256 _stakeId) external payable nonReentrant {
        stake storage _stake = mapStakes[_stakeId];
        loan storage _loan = mapLoans[_stakeId];
        
        require(_loan.requestedBy != address(0), "No active loan on this stake");
        require(_stake.hasCollected == false, "Stake Collected");

        uint256 _currentDay = _tokenContract.calcDay();
        require(_stake.endDay > _currentDay, "Stake ended");

        require(_stake.endDay > (_currentDay + _loan.loanDuration), "Loan must expire before stake end day");
        
        require(_loan.filledBy == address(0), "Already filled");
        require(_loan.loanAmount <= msg.value, "Not enough eth");

        require(msg.sender != _stake.owner, "No lend on own stakes");

        if (_stake.forSalePrice > 0) {
            // Can't sell a stake with an outstanding loan so we remove from sale
            mapStakes[_stakeId].forSalePrice = 0;
        }

        mapLoans[_stakeId] = loan({
            requestedBy: _loan.requestedBy,
            filledBy: msg.sender,
            loanAmount: _loan.loanAmount,
            loanInterest: _loan.loanInterest,
            loanDuration: _loan.loanDuration,
            startDay: _currentDay + 1,
            endDay: _currentDay + 1 + _loan.loanDuration
        });

        // Deduct fees
        uint256 _devShare = (_loan.loanAmount * devLoanFeePercent) / 100;
        uint256 _loanAmount = _loan.loanAmount - _devShare; 

        dayDividendPool[_currentDay] += _devShare / 2;
        devFees += _devShare / 2;

        // Send the loan to the requester
        Address.sendValue(payable(_loan.requestedBy), _loanAmount);

        _userLends[msg.sender].push(_stakeId);

        emit LoanRequestFilled(
            msg.sender,
            block.timestamp,
            _stake.owner,
            _loanAmount,
            _stakeId
        );
    }

    /**
     * This function is public so any can call and it
     * will repay the loan to the loaner. Stakes can only
     * have 1 active loan at a time so if the staker wants
     * to take out a new loan they will have to call the 
     * repayLoan function first to pay the outstanding 
     * loan.
     * This avoids us having to use an array and loop
     * through loans to see which ones need paying back
     * @param _stakeId the stake to repay the loan from 
     */
    function repayLoan(uint256 _stakeId) public {
        loan memory _loan = mapLoans[_stakeId];
        require(_loan.requestedBy != address(0), "No loan on stake");
        require(_loan.filledBy != address(0), "Loan not filled");

        uint256 _currentDay = _tokenContract.calcDay();
        require(_loan.endDay <= _currentDay, "Loan duration not met");

        // Save the payment here so its deducted from the divs 
        // on withdrawal
        mapStakes[_stakeId].loanRepayments += (  _loan.loanAmount + _loan.loanInterest );

        _cancelLoanRequest(_stakeId);
        
        Address.sendValue(payable(_loan.filledBy), _loan.loanAmount + _loan.loanInterest);

        // address indexed paidTo,
        // uint256 timestamp,
        // address interestAmount,
        // uint256 loanamount,
        // uint256 stakeId
        emit LoanRepaid(
            _loan.filledBy,
            block.timestamp,
            _loan.loanInterest,
            _loan.loanAmount,
            _stakeId
        );
    }

    function totalDividendPool() external view returns (uint256) {
        uint256 _day = _tokenContract.calcDay();
        // Prevent start day going to -1 on day 0
        if(_day <= 0) {
            return 0;
        }
        uint256 _startDay = _day;
        uint256 _total;
        for (uint256 i = 0; i <= (_startDay +  maxDividendRewardDays) ; ) {
            _total += dayDividendPool[_startDay + i];
            unchecked {
                 i++;
            }
        }
    
        return _total;
    }

    function userStakes(address _address) external view returns(uint256[] memory){
        return _userStakes[_address];
    }

    function userLends(address _address) external view returns (uint256[] memory) {
        return _userLends[_address];
    }
}
