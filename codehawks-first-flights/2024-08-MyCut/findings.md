### [L-1] DoS attack in Constructor of Pot.sol

**Description:** In the Pot.sol constructor there are two arrays that are passed: `players` and `rewards`. They are copied into the state variables `i_players` and `i_rewards`. Assuming that the player array and the rewards array are equal, each of the players is assigned a sum of the rewards using the `playersToRewards` mapping. To do that the protocol uses a for loop to copy the data into the mapping. 

**Impact:** When using a list that can be potentially unlimited a DoS (Denial of Service) attack could be exploited. If an attacker decided to, they could enter the contents with a big number of different addresses and make the array enormous. This will cause the gas fees for the protocol to be unreasonably expensive, and render the protocol unusable.

**Recommended Mitigation:** Add a limit to the amount of players allowed to participate in each contest. 

# Info

### [I-1] Unused error in Pot.sol

**Description:** The error `error Pot__InsufficientFunds();` is declared in Pot.sol, however never used.

**Impact:** More complex code and costlier gas prices.

**Recommended Mitigation:** Remove from code.

### [I-2] Miss use of the naming conventions for different storage types

**Description:** In Solidity there is a naming convention which decides how a variable name should start:
- For a state variable it would be `s_name`;
- For a immutable variable it would be `i_name`. 
- For a constant it would be `NAME`.
However, in the Pot.sol there are variables that are miss named.

**Impact:** This can cause confusion to anyone who will read the contract.

**Found Instances:** 
```javascript 
address[] private i_players; // Should be s_players
uint256[] private i_rewards;  // Should be s_rewards
address[] private claimants; // Should be s_claimants
mapping(address => uint256) private playersToRewards; // Should be s_playersToRewards
uint256 private remainingRewards; // Should be s_remainingRewards
uint256 private constant managerCutPercent = 10; // Should be MANAGER_CUT_PERCENT
```

**Recommended Mitigation:** Name each variable correctly, by the convention.
