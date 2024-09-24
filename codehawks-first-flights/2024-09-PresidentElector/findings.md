## High

### [H-1] Wrong definition of the `TYPEHASH` leads to the vote with signatures functionality to be unusable

**Description:** In the protocol's docs, it states that a big part of the protocol's functionality is that voters can let others spend gas for they're votes by using signatures. The following function is in charge of doing so:

```javascript
function rankCandidatesBySig(address[] memory orderedCandidates, bytes memory signature) external {
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, orderedCandidates));
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, signature); // @audit ?? maybe come back, couldnt find a problem. yeytttt
        _rankCandidates(orderedCandidates, signer);
}
```

The function uses a variable called `TYPEHASH` that contains the function's signature and is encoded to create the hash eventually. However, in the `TYPEHASH` declaration the function's signature is wrong. 

```javascript
                                                              :\/
bytes32 public constant TYPEHASH = keccak256("rankCandidates(uint256[])");
```

The function takes an array of addresses not uint256!

**Impact:** In the `rankCandidatesBySig` function the `hash` will be encoded with the wrong input parameters for the function, which will revert every transaction made with the signatures. Which means that an important capability in the protocol will not work!

**Proof of Concept:** Here is a step by step of a situation of a voter trying to vote with some other user to pay the gas for them:

1. A voter will make an order list of they're candidates.
2. That voter will make a signature constructed with the function signature and the actual list they made.
3. The gas payer will now pass on the actual list and the signature.
4. The `rankCandidatesBySig` will create the hash using the wrong TYPEHASH.
5. The ECDSA contract will revert

**Recommended Mitigation:** Fix the TYPEHASH to the correct input parameters:

```diff
+ bytes32 public constant TYPEHASH = keccak256("rankCandidates(address[])");
- bytes32 public constant TYPEHASH = keccak256("rankCandidates(uint256[])");
```

## Low

### [I-1] No checks for address(0) in `rankCandidates` could potentially lead to no one winning the election

**Description:** Voters can call the `rankCandidates` `external` function, or the `rankCandidatesBySig` function, that calls an internal function to rank the candidates (`_rankCandidates`). The voter passes through an ordered candidate list, with their ranking.

However, there is no checks for an `address(0)` in `rankCandidates` or `_rankCandidates`. In the case of `rankCandidatesBySig`, the `ECDSA.recover` function calls an internal function in the `ECDSA` contract that does check for an `address(0)`, so this does not apply.


```javascript

function rankCandidates(address[] memory orderedCandidates) external {
        _rankCandidates(orderedCandidates, msg.sender);
    }

function _rankCandidates(address[] memory orderedCandidates, address voter) internal {
        // Checks
        if (orderedCandidates.length > MAX_CANDIDATES) {
            revert RankedChoice__InvalidInput();
        }
        if (!_isInArray(VOTERS, voter)) {
            revert RankedChoice__InvalidVoter();
        }

        // Internal Effects
        s_rankings[voter][s_voteNumber] = orderedCandidates;
    }
```

**Likelihood:** 

**Impact:** LOW. This is because the likelihood of voters actually voting for an `address(0)` is very low. However, This could mean that, potentially, an empty address could win the election, and therefore no one is the actual president!

**Proof of Concept:** In this little test I prove that a voter can pass through an `address(0)` to the `s_rankings` mapping:

(I also added the attacker address to the setUp to be added to VOTERS).

```javascript
function testToAddAddress0ToCandidateList() public {
        address[] memory myOrder = new address[](1);
        myOrder[0] = address(0);
        vm.startPrank(attacker);
        rankedChoice.rankCandidates(myOrder);
    }
```

**Recommended Mitigation:** Have a for loop that checks for address(0) in the `_rankCandidates`:

```diff

+ error RankedChoice__CandidateCannotBeAddress0;

function _rankCandidates(address[] memory orderedCandidates, address voter) internal {
        // Checks
        if (orderedCandidates.length > MAX_CANDIDATES) {
            revert RankedChoice__InvalidInput();
        }
        if (!_isInArray(VOTERS, voter)) {
            revert RankedChoice__InvalidVoter();
        }

+       for (uint256 i=0; i<orderedCandidates.length; i++){
+           if(orderedCandidates[i] == address(0)){
+               revert RankedChoice__CandidateCannotBeAddress0();
+           }
+       }

        // Internal Effects
        s_rankings[voter][s_voteNumber] = orderedCandidates;
    }

```