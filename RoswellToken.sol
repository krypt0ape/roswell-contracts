// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface BiggestBuyInterface {
    function checkForWinner() external;
    function newBuy(uint256 _amount, address _address) external;
}

contract RoswellToken is ERC20, ReentrancyGuard, Ownable {
    event UserEnterAuction(
        address indexed addr,
        uint256 timestamp,
        uint256 entryAmountEth,
        uint256 day
    );
    event UserCollectAuctionTokens(
        address indexed addr,
        uint256 timestamp,
        uint256 day,
        uint256 tokenAmount,
        uint256 referreeBonus
    );
    event RefferrerBonusPaid(
        address indexed referrerAddress,
        address indexed reffereeAddress,
        uint256 timestamp,
        uint256 referrerBonus,
        uint256 referreeBonus
    );
    event DailyAuctionEnd(
        uint256 timestamp,
        uint256 day,
        uint256 ethTotal,
        uint256 tokenTotal
    );
    event AuctionStarted(
        uint256 timestamp
    );

    uint256 constant public FEE_DENOMINATOR = 1000;

    /** Taxes */
    address public dev_addr = 0xe951a168a8f796dd644061C6708598F7C0E139D7;
    address public marketing_addr = 0x3669ea64EBf033fc906371A39B815266E35655A4;
    address public buyback_addr = 0x3fDA78cf86ACD2F094a78F7c151B5eb8104B39D2;
    address public rewards_addr = 0x960C840aF4FA3F84FD7250FD4aa6ed8Ec0f3c970;
    uint256 public dev_percentage = 2;
    uint256 public marketing_percentage = 1;
    uint256 public buyback_percentage = 1;
    uint256 public rewards_percentage = 1;
    uint256 public biggestBuy_percent = 1;

    /* last amount of auction pool that are minted daily to be distributed between lobby participants which starts from 3 mil */
    uint256 public lastAuctionTokens = 3000000 * 1e18;

    /* Ref bonuses, referrer is the person who refered referre is person who got referred, includes 1 decimal so 25 = 2.5%  */
    uint256 public referrer_bonus = 50;
    uint256 public referree_bonus = 10;

    /* Record the current day of the programme */
    uint256 public currentDay;

    /* lobby memebrs data */
    struct userAuctionEntry {
        uint256 totalDeposits;
        uint256 day;
        bool hasCollected;
        address referrer;
    }

    /* new map for every entry (users are allowed to enter multiple times a day) */
    mapping(address => mapping(uint256 => userAuctionEntry))
    public mapUserAuctionEntry;

    /** Total ETH deposited for the day */
    mapping(uint256 => uint256) public auctionDeposits;

    /** Total tokens minted for the day */
    mapping(uint256 => uint256) public auctionTokens;

    /** The percent to reduce the total tokens by each day 30 = 3% */
    uint256 public dailyTokenReductionPercent = 30;

    // Record the contract launch time & current day
    uint256 public launchTime;

    /** External Contracts */
    BiggestBuyInterface private _biggestBuyContract;
    address public _stakingContract;

    address public deployer;

    constructor() ERC20("Roswell", "RSWL") {
        deployer = msg.sender;
    }

    receive() external payable {}

    /** 
        @dev is called when we're ready to start the auction
        @param _biggestBuyAddr address of the lottery contract
        @param _stakingCa address of the staking contract

    */
    function startAuction(address _biggestBuyAddr, address _stakingCa)
        external {
        require(launchTime == 0, "Launch already started");
        require(_biggestBuyAddr != address(0), "Biggest buy address cannot be zero");
        require(_stakingCa != address(0), "Staking contract address cannot be zero");
        require(msg.sender == deployer, "Only deployer can start the auction");
        require(owner() != deployer, "Ownership must be transferred to timelock before you can start auction");

        _mint(deployer, lastAuctionTokens);
        launchTime = block.timestamp;
        _biggestBuyContract = BiggestBuyInterface(_biggestBuyAddr);
        _stakingContract = _stakingCa;
        currentDay = calcDay();
        emit AuctionStarted(block.timestamp);
    }

    /**
        @dev update the bonus paid out to affiliates. 20 = 2%
        @param _referrer the percent going to the referrer
        @param _referree the percentage going to the referee
    */
    function updateReferrerBonus(uint256 _referrer, uint256 _referree)
        external
        onlyOwner
    {
        require((_referrer <= 50 && _referree <= 50), "Over max values");
        require((_referrer != 0 && _referree != 0), "Cant be zero");
        referrer_bonus = _referrer;
        referree_bonus = _referree;
    }

    /**
        @dev Calculate the current day based off the auction start time 
    */
    function calcDay() public view returns (uint256) {
        if(launchTime == 0) return 0; 
        return (block.timestamp - launchTime) / 1 days;
    }

    /**
        @dev Called daily, can be done manually in etherscan but will be automated with a script
        this prevent the first user transaction of the day having to pay all the gas to run this 
        function. For security all tokens are kept in the token contract, divs are sent to the 
        div contract for div rewards and taxs are sent to the tax contract.
    */
    function doDailyUpdate() public nonReentrant {
        uint256 _nextDay = calcDay();
        uint256 _currentDay = currentDay;

        // this is true once a day
        if (_currentDay != _nextDay) {
            uint256 _taxShare;
            uint256 _divsShare;

            if(_nextDay > 1) {
                _taxShare = (address(this).balance * tax()) / 100;
                _divsShare = address(this).balance - _taxShare;
                (bool success, ) = _stakingContract.call{value: _divsShare}(
                    abi.encodeWithSignature("receiveDivs()")
                );
                require(success, "Div transfer failed");
            }

            if (_taxShare > 0) {
                _flushTaxes(_taxShare);
            }

             (bool success2, ) = _stakingContract.call(
                    abi.encodeWithSignature("flushDevTaxes()")
                );
                require(success2, "Flush dev taxs failed");

            // Only mint new tokens when we have deposits for that day
            if(auctionDeposits[currentDay] > 0){
                _mintDailyAuctionTokens(_currentDay);
            }
        
            if(biggestBuy_percent > 0) {
                _biggestBuyContract.checkForWinner();
            }

            emit DailyAuctionEnd(
                block.timestamp,
                currentDay,
                auctionDeposits[currentDay],
                auctionTokens[currentDay]
            );

            currentDay = _nextDay;

            delete _nextDay;
            delete _currentDay;
            delete _taxShare;
            delete _divsShare;
        }
    }

    /**
        @dev The total of all the taxs
    */
    function tax() public view returns (uint256) {
        return
            biggestBuy_percent +
            dev_percentage +
            marketing_percentage +
            buyback_percentage +
            rewards_percentage;
    }

    /**
        @dev Send all the taxs to the correct wallets
        @param _amount total eth to distro
    */
    function _flushTaxes(uint256 _amount) internal {
        uint256 _totalTax = tax();
        uint256 _marketingTax = _amount * marketing_percentage / _totalTax;
        uint256 _rewardsTax = _amount * rewards_percentage / _totalTax;
        uint256 _buybackTax = _amount * buyback_percentage / _totalTax;
        uint256 _buyCompTax = (biggestBuy_percent > 0) ?  _amount * biggestBuy_percent / _totalTax : 0;
        uint256 _devTax = _amount -
            (_marketingTax + _rewardsTax + _buybackTax + _buyCompTax);
                
        Address.sendValue(payable(dev_addr), _devTax);
        Address.sendValue(payable(marketing_addr), _marketingTax);
        Address.sendValue(payable(rewards_addr), _rewardsTax);
        Address.sendValue(payable(buyback_addr), _buybackTax);

        if (_buyCompTax > 0) {
            Address.sendValue(payable(address(_biggestBuyContract)), _buyCompTax);
        }


        delete _totalTax;
        delete _buyCompTax;
        delete _marketingTax;
        delete _rewardsTax;
        delete _buybackTax;
        delete _devTax;
    }

    /**
        @dev UPdate  the taxs, can't be greater than current taxs
        @param _dev the dev tax
        @param _marketing the marketing tax
        @param _buyback the buyback tax
        @param _rewards the rewards tax
        @param _biggestBuy biggest buy comp tax
    */
    function updateTaxes(
        uint256 _dev,
        uint256 _marketing,
        uint256 _buyback,
        uint256 _rewards,
        uint256 _biggestBuy
    ) external onlyOwner {
        uint256 _newTotal = _dev + _marketing + _buyback + _rewards + _biggestBuy;
        require(_newTotal <= 10, "Max tax is 10%");
        dev_percentage = _dev;
        marketing_percentage = _marketing;
        buyback_percentage = _buyback;
        rewards_percentage = _rewards;
        biggestBuy_percent = _biggestBuy;
    }

    /**
        @dev Update the marketing wallet address
    */
    function updateMarketingAddress(address adr) external onlyOwner {
        require(adr != address(0), "Can't set to 0 address");
        marketing_addr = adr;
    }

    /**
        @dev Update the dev wallet address
    */
    function updateDevAddress(address adr) external onlyOwner {
        require(adr != address(0), "Can't set to 0 address");
        dev_addr = adr;
    }

    /**
        @dev update the buyback wallet address
    */
    function updateBuybackAddress(address adr) external onlyOwner {
        require(adr != address(0), "Can't set to 0 address");
        buyback_addr = adr;
    }

    /**
        @dev update the rewards wallet address
    */
    function updateRewardsAddress(address adr) external onlyOwner {
        require(adr != address(0), "Can't set to 0 address");
        rewards_addr = adr;
    }

    /**
        @dev Mint the auction tokens for the day 
        @param _day the day to mint the tokens for
    */
    function _mintDailyAuctionTokens(uint256 _day) internal {
        uint256 _nextAuctionTokens = todayAuctionTokens(); // decrease by 3%

        // Mint the tokens for the day so they're ready for the users to withdraw when they remove stakes.
        // This saves gas for the users as we cover the mint costs on our end and the user can do a cheaper
        // transfer function
        _mint(address(this), _nextAuctionTokens);

        auctionTokens[_day] = _nextAuctionTokens;
        lastAuctionTokens = _nextAuctionTokens;

        delete _nextAuctionTokens;
    }

    function todayAuctionTokens() public view returns (uint256){
        return lastAuctionTokens -
            ((lastAuctionTokens * dailyTokenReductionPercent) / FEE_DENOMINATOR); 
    }

    /**
     * @dev entering the auction lobby for the current day
     * @param referrerAddr address of referring user (optional; 0x0 for no referrer)
     */
    function enterAuction(address referrerAddr) external payable {
        require((launchTime > 0), "Project not launched");
        require( msg.value > 0, "msg value is 0 ");
        doDailyUpdate();

        uint256 _currentDay = currentDay;
        _biggestBuyContract.newBuy(msg.value, msg.sender);

        auctionDeposits[_currentDay] += msg.value;

        mapUserAuctionEntry[msg.sender][_currentDay] = userAuctionEntry({
            totalDeposits: mapUserAuctionEntry[msg.sender][_currentDay]
                .totalDeposits + msg.value,
            day: _currentDay,
            hasCollected: false,
            referrer: (referrerAddr != msg.sender) ? referrerAddr : address(0)
        });

        emit UserEnterAuction(msg.sender, block.timestamp, msg.value, _currentDay );
     
        if (_currentDay == 0) {
            // Move this staight out on day 0 so we have
            // the marketing funds availabe instantly
            // to promote the project
            Address.sendValue(payable(dev_addr), msg.value);
        }

        delete _currentDay;
    }

    /**
     * @dev External function for leaving the lobby / collecting the tokens
     * @param targetDay Target day of lobby to collect
     */
    function collectAuctionTokens(uint256 targetDay) external nonReentrant {
        require(
            mapUserAuctionEntry[msg.sender][targetDay].hasCollected == false,
            "Tokens already collected for day"
        );
        require(targetDay < currentDay, "cant collect tokens for current active day");

        uint256 _tokensToPay = calcTokenValue(msg.sender, targetDay);

        mapUserAuctionEntry[msg.sender][targetDay].hasCollected = true;
        _transfer(address(this), msg.sender, _tokensToPay);

        address _referrerAddress = mapUserAuctionEntry[msg.sender][targetDay]
            .referrer;
        uint256 _referreeBonus;

        if (_referrerAddress != address(0)) {
            /* there is a referrer, pay their % ref bonus of tokens */
            uint256 _reffererBonus = (_tokensToPay * referrer_bonus) / FEE_DENOMINATOR;
            _referreeBonus = (_tokensToPay * referree_bonus) / FEE_DENOMINATOR;

            _mint(_referrerAddress, _reffererBonus);
            _mint(msg.sender, _referreeBonus);

            emit RefferrerBonusPaid(
                _referrerAddress,
                msg.sender,
                block.timestamp,
                _reffererBonus,
                _referreeBonus
            );

            delete _referrerAddress;
            delete _reffererBonus;
        }

        emit UserCollectAuctionTokens(
            msg.sender,
            block.timestamp,
            targetDay,
            _tokensToPay,
            _referreeBonus
        );

        delete _referreeBonus;
    }

    /**
     * @dev Calculating user's share from lobby based on their & of deposits for the day
     * @param _Day The lobby day
     */
    function calcTokenValue(address _address, uint256 _Day)
        public
        view
        returns (uint256)
    {
        require(_Day < calcDay(), "day must have ended");
        uint256 _tokenValue;
        uint256 _entryDay = mapUserAuctionEntry[_address][_Day].day;

        if(auctionTokens[_entryDay] == 0){
            // No token minted for that day ( this happens when no deposits for the day)
            return 0;
        }

        if (_entryDay < currentDay) {
            _tokenValue =
                (auctionTokens[_entryDay] *
                    mapUserAuctionEntry[_address][_Day].totalDeposits) / auctionDeposits[_entryDay];
        } else {
            _tokenValue = 0;
        }

        return _tokenValue;
    }

    /**
        @dev change the % reduction of the daily tokens minted
        @param _newPercent the new percent val 3% = 30
    */
    function updateDailyReductionPercent(uint256 _newPercent) external onlyOwner {
        // must be >= 1% and <= 6%
        require((_newPercent >= 10 && _newPercent <= 60));
        dailyTokenReductionPercent = _newPercent;
    }
}
