# Slither Notes

INFO:Detectors:
TSwapPool.revertIfZero(uint256) (src/TSwapPool.sol#57-62) uses a dangerous strict equality:
        - amount == 0 (src/TSwapPool.sol#58) ?????
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#dangerous-strict-equalities

INFO:Detectors:
Reentrancy in TSwapPool._swap(IERC20,uint256,IERC20,uint256) (src/TSwapPool.sol#323-337):
        External calls:
        - outputToken.safeTransfer(msg.sender,1_000_000_000_000_000_000) (src/TSwapPool.sol#331)
        Event emitted after the call(s):
        - Swap(msg.sender,inputToken,inputAmount,outputToken,outputAmount) (src/TSwapPool.sol#333)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3

INFO:Detectors:
3 different versions of Solidity are used:
        - Version constraint >=0.6.2 is used by:
                - lib/forge-std/src/interfaces/IERC20.sol#2
        - Version constraint ^0.8.20 is used by:
                - lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol#3
                - lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol#4
                - lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#4
                - lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol#4
                - lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol#4
                - lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#4
                - lib/openzeppelin-contracts/contracts/utils/Address.sol#4
                - lib/openzeppelin-contracts/contracts/utils/Context.sol#4
        - Version constraint 0.8.20 is used by:
                - src/PoolFactory.sol#15
                - src/TSwapPool.sol#15
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#different-pragma-directives-are-used


INFO:Detectors:
The following unused import(s) in lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol should be removed: 
        -import {IERC20Permit} from "../extensions/IERC20Permit.sol"; (lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#7)
The following unused import(s) in src/PoolFactory.sol should be removed: 
        -import { IERC20 } from "forge-std/interfaces/IERC20.sol"; (src/PoolFactory.sol#18)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#unused-imports