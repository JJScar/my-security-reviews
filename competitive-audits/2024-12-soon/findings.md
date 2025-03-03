# Low
## [L-1] ERC20 Tokens That Do Not Implement the decimals() Function Cannot Be Bridged Using the StandardBridge.sol Contract#34

### Summary
SOON plans to support all possible `ERC20` tokens, except for some criteria but will not be able to support tokens that do not implement 
the `decimals()` function.

### Finding Description
As per the docs, the protocol plans to work with all ERC20 tokens apart of these criteria:
```
NOTE: ...not intended to support all variations of ERC20 tokens. Examples of some token types that may not be properly supported by this
contract include, but are not limited to: tokens with transfer fees, rebasing tokens, and tokens with blocklists.
```
The issue occurs as the EIP-20 standard states that the decimals() function MUST NOT be implemented, it is in fact OPTIONAL:

From the EIP-20 docs:
```
OPTIONAL - This method can be used to improve usability, but interfaces and other contracts MUST NOT expect these values to be present.
```

However, in the `StandardBridge::_initiateBridgeERC20` and `StandardBridge::finalizeBridgeERC20` functions incorrectly assumes that the `_localToken` 
will be using this function:
```solidity
function _initiateBridgeERC20(){
.
.
uint256 dustRemovedAmount;
uint256 amountRD;
    {
@>      uint8 localDecimals = IERC20Metadata(_localToken).decimals();    <@
        uint8 shareDecimals = ERC20SharedDecimals();
        dustRemovedAmount = _amount.removeDust(localDecimals, shareDecimals);
        amountRD = _amount.convertDecimals(localDecimals, shareDecimals);
    }
require(dustRemovedAmount != 0, "StandardBridge: invalid token amount");
}
.
.

function finalizeBridgeERC20() {
.
.
@>  uint8 localDecimals = IERC20Metadata(_localToken).decimals();  <@
    uint8 shareDecimals = ERC20SharedDecimals();
    uint256 amountLD = _amount.convertDecimals(shareDecimals, localDecimals);
}
```

### Impact Explanation
Users that want to bridge tokens like [cloutContracts](https://etherscan.io/address/0x1da4858ad385cc377165a298cc2ce3fce0c5fd31#readContract) and 
others will not be able to do so. Therefore, imapct is HIGH as funds cannot be bridged.

### Likelihood Explanation
Likelihood is LOW as these tokens are rare in use and most likely users will use tokens that do implement the `decimals()` function.

### Proof of Concept
Read more [here](https://eips.ethereum.org/EIPS/eip-20) in the docs for the EIP-20 standard.

### Recommendation
Usde a tryCatch block to query the decimals. If it fails, hardcode it to 18 for scaling:

```diff
.
.
uint256 dustRemovedAmount;
uint256 amountRD;
    {
-       uint8 localDecimals = IERC20Metadata(_localToken).decimals();   
+       uint8 localDecimals;
+       try IERC20Metadata(_localToken).decimals() returns (uint8 decimals) {
+       localDecimals = decimals;
+       } catch {
+           localDecimals = 18; // Default to 18 decimals if function doesn't exist
+       }
        uint8 shareDecimals = ERC20SharedDecimals();
        dustRemovedAmount = _amount.removeDust(localDecimals, shareDecimals);
        amountRD = _amount.convertDecimals(localDecimals, shareDecimals);
    }
require(dustRemovedAmount != 0, "StandardBridge: invalid token amount"); 
.
.

function finalizeBridgeERC20() {
.
.
-   uint8 localDecimals = IERC20Metadata(_localToken).decimals();  
+   uint8 localDecimals;
+   try IERC20Metadata(_localToken).decimals() returns (uint8 decimals) {
+       localDecimals = decimals;
+       } catch {
+           localDecimals = 18; // Default to 18 decimals if function doesn't exist
+       }
    uint8 shareDecimals = ERC20SharedDecimals();
    uint256 amountLD = _amount.convertDecimals(shareDecimals, localDecimals);
}
```
