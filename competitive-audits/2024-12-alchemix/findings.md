# Low

## [L-1] Cannot Set A New Router In `StrategyMainnet.sol` Can Lead To Stale Contract

### Summary
The `StrategyMainnet.sol` contract uses a router for using Curve. However, there is no way to set a new 
router in case of a need.
 
### Vulnerability Details
In the other contracts `StrategyArb.sol` and `StrategyOp.sol` there is the following function that lets 
the management set a new router in case there is a need to change the router:
```solidity
function setRouter(address _router) external onlyManagement {
        router = _router;
        underlying.safeApprove(router, type(uint256).max);
}
```
However, in the `StrategyMainnet.sol` there is no such function.

### Impact
This issue could potentially make the contract stale. Curve could release a new router, or potentially the current one might have an undiscovered exploit. Also, if the protocol would like to improve their protocol by updating features, this is one aspect that could halt improvement.

- Impact - HIGH
- Likelihood - LOW

Yes, if there is a situation where the protocol will need to set a new router but can't, could lead to loss of funds or a deployment of a new contract. However, it is very unlikely for that to happen, which is why this issue is a low severity.

### Tools Used

Manual Review

### Recommendations

Consider implementing a `setRouter` function similar to the other contracts:
```diff
+ function setRouter(address _router) external onlyManagement {
+       router = _router;
+       underlying.safeApprove(router, type(uint256).max);
+ }
```
