## Summary

## Vulnerability Details

## Impact

## Tools Used

## Recommendations

# High

## [H-#] Potential Rounding Down Issue When Calculating Fees and Rewards Throughout the Codebase   

## Vulnerability Details

There are a number of instances where there are calculations for fees and rewards. These calculations differ slightly but all have the same reasoning which is why these errors are all in this one finding. 

Rounding down (Precision Loss) errors occur because of the nature of Solidity. Solidity does not have fractional numbers (floats) capabilities, which means that any division in Solidity will end up in rounding down (=> 3 / 2 == 1). This is a problem if the numerator is greater than the denominator. This logic is applied in a number of places throughout the codebase:

<details><summary>Instances</summary>

StakingPool:387
```javascript
if (totalRewards > 0) {
    for (uint256 i = 0; i < fees.length; i++) {
@>       totalFees += (uint256(totalRewards) * fees[i].basisPoints) / 10000; <@
    }
}
```

StakingPool:560
```javascript
for (uint256 i = 0; i < fees.length; i++) {
    receivers[receivers.length - 1][i] = fees[i].receiver;
    feeAmounts[feeAmounts.length - 1][i] = (uint256(totalRewards) * fees[i].basisPoints) / 10000;
    totalFeeAmounts += feeAmounts[feeAmounts.length - 1][i];
}
```

</details>

## Impact

## Tools Used

## Recommendations

# Medium

# Low 
