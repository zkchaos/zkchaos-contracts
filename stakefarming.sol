//SPDX-License-Identifier: Unlicense
/*
流动性挖矿需求：抵押lp，挖token；

1.按期进行，每期可以设置开始高度，持续高度，以及每个高度奖励多少token；

2.设置新的期数时，开始时间不能早于上一期的结束时间。设置时，需要同时转足量的token。

3.按块高度进行结算。记录每一期的每一份lp累积奖励值。

4.记录用户已经结算的期数，结算时从最后期数开始结算。

5. 只支持一个矿池，开发团队启动矿池

6. 不同期里，用户在抵押的情况下，可以领取历史期内的收益

7. 用户可以随时取消抵押
*/
pragma solidity ^0.5.0;

// import "hardhat/console.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
// import "@openzeppelin/contracts/token/ERC20/IRC20.sol";

library SafeMath {
    function add(uint a, uint b) public pure returns (uint c) {
        c = a + b;
        require(c >= a);
    }
    
    function sub(uint a, uint b) public pure returns (uint c) {
        require(b <= a); 
        c = a - b; 
    }
    
    function mul(uint a, uint b) public pure returns (uint c) {
        c = a * b; 
        require(a == 0 || c / a == b); 
    } 
    
    function div(uint a, uint b) public pure returns (uint c) { 
        require(b > 0);
        c = a / b;
    }
}

contract Ownable {
    address public owner;

    constructor () public {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender == owner)
            _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner != address(0)) owner = newOwner;
    }
}

contract ReentrancyGuard {

  /// @dev counter to allow mutex lock with only one SSTORE operation
  uint256 private _guardCounter = 1;

  /**
   * @dev Prevents a contract from calling itself, directly or indirectly.
   * If you mark a function `nonReentrant`, you should also
   * mark it `external`. Calling one `nonReentrant` function from
   * another is not supported. Instead, you can implement a
   * `private` function doing the actual work, and an `external`
   * wrapper marked as `nonReentrant`.
   */
  modifier nonReentrant() {
    _guardCounter += 1;
    uint256 localCounter = _guardCounter;
    _;
    require(localCounter == _guardCounter);
  }
}

contract ERC20Interface {
    function totalSupply() public view returns (uint);
    function balanceOf(address tokenOwner) public view returns (uint balance);
    function allowance(address tokenOwner, address spender) public view returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

contract StakeFarming is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    uint256 public cur_period;
    ERC20Interface public bonus_token;
    ERC20Interface public stake_token;

    uint256 public start_block;
    uint256 public end_block;
    uint256 public bonus_per_block;
    uint256 public last_update;                 // last update block
    uint256 public accumulate_bonus_per_stake;  // accumulate bonus per stake until last update
    uint256 public total_bonus;
    uint256 public remain_bonus;
    uint256 public total_stake;

    struct StakingInfo {
        uint256 staked_amount;
        uint256 unclaimed_bonus;
        uint256 cached_bonus;
        uint256 claimed_bonus;
    }

    mapping(address => StakingInfo) public stakers; // user -> stake_info

    constructor(ERC20Interface _staking_token, ERC20Interface _bonus_token) public {
        stake_token = _staking_token;
        bonus_token = _bonus_token;
        cur_period = 0;
    }

    event Staked(address staker, uint256 amount);
    event Unstaked(address staker, uint256 amount);
    event Claimed(address staker, uint256 amount);

    function _calculateAccumulate() private view returns (uint256) {
        if (cur_period == 0) {
            return 0;
        }

        uint256 from = 0;
        if (last_update > start_block) {
            from = last_update;
        } else {
            from = start_block;
        }

        uint256 to = 0;
        if (block.number < end_block) {
            to = block.number;
        } else {
            to = end_block;
        }

        if (to > from) {
            if (total_stake != 0) {
                uint256 duration = to.sub(from);
                uint256 bonus_duration = duration.mul(bonus_per_block);
                uint256 extra_acc_bonus_per_block_lp = bonus_duration.div(total_stake);
                return accumulate_bonus_per_stake.add(extra_acc_bonus_per_block_lp);
            }
        }

        return accumulate_bonus_per_stake;
    }

    function _updateAccumulate() private {
        accumulate_bonus_per_stake = _calculateAccumulate();
        last_update = block.number;
    }

    function openPool(uint256 _start, uint256 _end, uint256 _bonus_per_block, uint256 _amount) public onlyOwner {
        require(_start < _end, "start height must be smaller than end height");
        require(_start > block.number, "start height must be greater than current block");
        if (cur_period != 0) {
            // already launched period, need to check last period to see if it ended
            require(_start > end_block, "new start height must be greater than previous end height");
            require(block.number > end_block, "previous period is still active");
        }

        uint256 duration = _end.sub(_start);
        require(duration.mul(_bonus_per_block) <= _amount, "amount must match bonus configuration");
        require(bonus_token.transferFrom(msg.sender, address(this), _amount), "bonus token required!");

        _updateAccumulate();

        cur_period = cur_period.add(1);
        start_block = _start;
        end_block = _end;
        bonus_per_block = _bonus_per_block;
        total_bonus = total_bonus.add(_amount);
        remain_bonus = remain_bonus.add(_amount);
        last_update = _start;
    }

    function unclaimedBonus(address _staker) view public returns (uint256) {
        uint256 acc_unit = _calculateAccumulate();
        uint256 tmp_acc_bonus = stakers[_staker].staked_amount.mul(acc_unit);
        tmp_acc_bonus = tmp_acc_bonus.sub(stakers[_staker].cached_bonus);
        return stakers[_staker].unclaimed_bonus.add(tmp_acc_bonus);
    }

    function stake(uint256 _amount) public nonReentrant {
        require(stake_token.transferFrom(msg.sender, address(this), _amount), "stake token required!");

        _updateAccumulate();
        total_stake = total_stake.add(_amount);

        uint256 unclaimed = unclaimedBonus(msg.sender);
        stakers[msg.sender].unclaimed_bonus = unclaimed;
        stakers[msg.sender].staked_amount = stakers[msg.sender].staked_amount.add(_amount);
        stakers[msg.sender].cached_bonus = accumulate_bonus_per_stake.mul(stakers[msg.sender].staked_amount);

        emit Staked(msg.sender, _amount);
    }

    function unstake(uint256 _amount) public nonReentrant {
        require(stakers[msg.sender].staked_amount >= _amount, "not enough staked amount");

        _updateAccumulate();
        total_stake = total_stake.sub(_amount);

        uint256 unclaimed = unclaimedBonus(msg.sender);
        stakers[msg.sender].unclaimed_bonus = unclaimed;
        stakers[msg.sender].staked_amount = stakers[msg.sender].staked_amount.sub(_amount);
        stakers[msg.sender].cached_bonus = accumulate_bonus_per_stake.mul(stakers[msg.sender].staked_amount);

        require(stake_token.transfer(msg.sender, _amount), "unstake token failed!");
        emit Unstaked(msg.sender, _amount);
    }

    function claim() public nonReentrant {
        _updateAccumulate();

        uint256 unclaimed = unclaimedBonus(msg.sender);
        require(remain_bonus >= unclaimed, "unknown error, remain bonus is not enough");
        remain_bonus = remain_bonus.sub(unclaimed);

        stakers[msg.sender].cached_bonus = accumulate_bonus_per_stake.mul(stakers[msg.sender].staked_amount);
        stakers[msg.sender].unclaimed_bonus = 0;
        stakers[msg.sender].claimed_bonus = stakers[msg.sender].claimed_bonus.add(unclaimed);

        require(bonus_token.transfer(msg.sender, unclaimed), "claim failed");
        emit Claimed(msg.sender, unclaimed);
    }
}