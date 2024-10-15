
# High

# Medium

## [M-1] Missing Access Control In `OperatorVCS::queueVaultRemoval` & `OperatorVCS::removeVault` Can Lead to Unwanted Removal of Vaults

### Summary
The `OperatorVCS::queueVaultRemoval` function allows for vaults to be queued for removal. The `OperatorVCS::removeVault` function is the one that actually removes the vault from operation. However, in both of these functions there is no access control. No checks to see who is the address that is trying to queue or actually remove the vault.

### Vulnerability Details

<details><summary>queueVaultRemoval</summary>

```javascript
/**
     * @notice Queues a vault for removal
     * @dev a vault can only be queued for removal if the operator has been removed from the
     * Chainlink staking contract
     * @param _index index of vault
     */
    function queueVaultRemoval(uint256 _index) external {
        // @audit ?? Missing access control here? Anyone can queue to remove vault?
        address vault = address(vaults[_index]);

        if (!IVault(vault).isRemoved()) revert OperatorNotRemoved();
        for (uint256 i = 0; i < vaultsToRemove.length; ++i) {
            if (vaultsToRemove[i] == vault) revert VaultRemovalAlreadyQueued();
        }

        vaultsToRemove.push(address(vaults[_index]));

        // update group accounting if vault is part of a group
        if (_index < globalVaultState.depositIndex) {
            uint256 group = _index % globalVaultState.numVaultGroups;
            uint256[] memory groups = new uint256[](1);
            groups[0] = group;
            fundFlowController.updateOperatorVaultGroupAccounting(groups);

            // if possiible, remove vault right away
            if (vaults[_index].claimPeriodActive()) {
                removeVault(vaultsToRemove.length - 1);
            }
        }
    }
```

</details>

<details><summary>removeVault</summary>

```javascript
/**
     * @notice Queues a vault for removal
     * @dev a vault can only be queued for removal if the operator has been removed from the
     * Chainlink staking contract
     * @param _index index of vault
     */
    function queueVaultRemoval(uint256 _index) external {
        address vault = address(vaults[_index]);

        if (!IVault(vault).isRemoved()) revert OperatorNotRemoved();
        for (uint256 i = 0; i < vaultsToRemove.length; ++i) {
            if (vaultsToRemove[i] == vault) revert VaultRemovalAlreadyQueued();
        }

        vaultsToRemove.push(address(vaults[_index]));

        // update group accounting if vault is part of a group
        if (_index < globalVaultState.depositIndex) {
            uint256 group = _index % globalVaultState.numVaultGroups;
            uint256[] memory groups = new uint256[](1);
            groups[0] = group;
            fundFlowController.updateOperatorVaultGroupAccounting(groups);

            // if possiible, remove vault right away
            if (vaults[_index].claimPeriodActive()) {
                removeVault(vaultsToRemove.length - 1);
            }
        }
    }
```

</details>

<details><summary>removeVault</summary>

```javascript
/**
* @notice Removes a vault that has been queued for removal
* @param _queueIndex index of vault in removal queue
*/
function removeVault(uint256 _queueIndex) public {
        address vault = vaultsToRemove[_queueIndex];

        vaultsToRemove[_queueIndex] = vaultsToRemove[vaultsToRemove.length - 1];
        vaultsToRemove.pop();

        _updateStrategyRewards();
        (uint256 principalWithdrawn, uint256 rewardsWithdrawn) = IOperatorVault(vault).exitVault();

        totalDeposits -= principalWithdrawn + rewardsWithdrawn;
        totalPrincipalDeposits -= principalWithdrawn;

        uint256 numVaults = vaults.length;
        uint256 index;
        for (uint256 i = 0; i < numVaults; ++i) {
            if (address(vaults[i]) == vault) {
                index = i;
                break;
            }
        }
        for (uint256 i = index; i < numVaults - 1; ++i) {
            vaults[i] = vaults[i + 1];
        }
        vaults.pop();

        token.safeTransfer(address(stakingPool), token.balanceOf(address(this)));
    }
```

</details>

### Impact
This could potentially let any actor to choose to remove a vault from operation, however it will not cause any loss of funds. 

### Tools Used
Manual Review, Solodit Checklist

### Recommendations
Add access control modifiers or checks for `msg.sender`

# Low 

## [L-1] Incorrect Time Comparison in WithdrawalPool::checkUpKeep May Cause Delayed Execution

### Summary
The `checkUpKeep` function is responsible for determining whether withdrawals should be executed by checking two conditions: the availability of withdrawal space and whether enough time has passed since the last withdrawal. However, the current time check logic is flawed, which could lead to unnecessary delays in executing withdrawals.

<details><summary>Code Snippet</summary>

```javascript
/**
     * @notice Returns whether withdrawals should be executed based on available withdrawal space
     * @return true if withdrawal should be executed, false otherwise
     */
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        if (
            _getStakeByShares(totalQueuedShareWithdrawals) != 0 && priorityPool.canWithdraw(address(this), 0) != 0
@>              && block.timestamp > timeOfLastWithdrawal + minTimeBetweenWithdrawals          <@
        ) {
            return (true, "");
        }
        return (false, "");
    }
```

</details>

### Vulnerability Details
The issue lies in how the function checks if the required time interval between withdrawals has passed. The condition uses `block.timestamp > timeOfLastWithdrawal + minTimeBetweenWithdrawals`, which only allows the upkeep to trigger if the `timestamp` is strictly greater than the sum of the last withdrawal time and the minimum interval. This means that if the current `block.timestamp` equals the calculated threshold (i.e., exactly when the interval elapses), the condition will incorrectly return `false`, delaying the upkeep until a future block.

### Impact
This faulty comparison can result in a delayed execution of withdrawals, as the upkeep will not be triggered precisely when the minimum time requirement is met. While the function will eventually allow execution in subsequent blocks, this delay could affect user experience or system efficiency, particularly in time-sensitive scenarios.

### Tools Used
Manual Review, Solodit Checklist

### Recommendations
Update the comparison to use a `>=` check, ensuring that withdrawals are triggered as soon as the minimum time interval has elapsed:

```diff
/**
     * @notice Returns whether withdrawals should be executed based on available withdrawal space
     * @return true if withdrawal should be executed, false otherwise
     */
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        if (
            _getStakeByShares(totalQueuedShareWithdrawals) != 0 && priorityPool.canWithdraw(address(this), 0) != 0
-               && block.timestamp > timeOfLastWithdrawal + minTimeBetweenWithdrawals
+               && block.timestamp >= timeOfLastWithdrawal + minTimeBetweenWithdrawals          
        ) {
            return (true, "");
        }
        return (false, "");
    }
```