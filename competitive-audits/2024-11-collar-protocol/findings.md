# Low
## [L-1] Incorrect Check for Expiration Time In `EscrowSupplierNFT::switchEscrow` & `LoansNFT::_conditionalCheckAndCancelEscrow`
### Summary
`EscrowSupplierNFT::switchEscrow` function lets users switch their chosen escrow offer only if the offer has not expired. The `LoansNFT::_conditionalCheckAndCancelEscrow` checks if canceling an Escrow as well as regular loan. However, the require check is incorrect in both scenarios and lets users switch or cancel escrow if the `block.timestamp == previousEscrow.expiration`

### Finding Description
The functions use a require statement to check of the timing of the switch matches with the expiration time:

`swithEscrow`:
```solidity
require(block.timestamp <= previousEscrow.expiration, "escrow: expired");
```
`_conditionalCheckAndCancelEscrow`:
```solidity
require(escrowReleased || block.timestamp <= _expiration(loanId), "loans: loan expired");
```
However, if the `block.timestamp` equals the expiration time then the offer has indeed expired.

### Impact
No loss of funds, or serious breaking of the contract. However, the design of the system has been wrongly implemented.

LOW

### Likelihood Explanation
Not likely for users to be exactly on time of the expiration time. However, a bad actor could wait until the expiration time and still cancel or switch if they want to

MEDIUM

### Recommendation
Consider changing the require statement to only check for less than expire time:
```diff
function switchEscrow(uint releaseEscrowId, uint offerId, uint newFee, uint newLoanId)
        .
        .
    {
        .
        . 

-       require(block.timestamp <= previousEscrow.expiration, "escrow: expired");
+       require(block.timestamp < previousEscrow.expiration, "escrow: expired");

        .
        .

```

# Info
## [I-1] Wrong Reference to A Function In the `LoansNFT::closeLoan` NatSpec
### Summary
The `closeLoan` function can be called by either the `loanId`'s NFT owner or by a keeper if the keeper was allowed using the `setKeeperApproved` function. However, in the NatSpec the function `setKeeperAllowed` is mentioned, even though it does not exist.

### Finding Description
The developers probably made a mistake in mentioning the wrong function that does not exist.

### Impact
Does not affect funds or usability, only reading docs. Therefore informational.

### Recommendation
Change it to the correct function: `setKeeperApproved`
