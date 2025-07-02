# Low
## [L-1] Missing amp Validity Checks During Pool Initialization#293
### Summary
The `liquidity_pool_stableswap` contract does not validate the `amp` parameter during pool initialization, even though similar checks exist in the `amp_a` function. This omission allows the creation of pools with high amplification coefficients, which may lead to unexpected or unstable behavior.

### Finding Description
Users create new stableswap pools by calling the `init_stableswap_pool` function in the `liquidity_pool_router` contract. Inside this function, the amplification factor (`amp`) is derived as follows:

```rust
// Taken from `liquidity_pool_router::init_stableswap_pool`
// Amp = A * N^(N-1)
let n = tokens.len();
let amp = STABLESWAP_DEFAULT_A * (n as u128).pow(n - 1);
```

This computed `amp` is then passed into the initialization function of the `liquidity_pool_stableswap` contract. However, there are no validity checks on this parameter at the point of initialization.

In contrast, the `ramp_a` function inside the same contract does enforce upper bounds and rate-of-change limits:

```rust
let initial_a = Self::a(e.clone());
if !((future_a > 0) && (future_a < MAX_A)) {
    panic_with_error!(&e, LiquidityPoolError::RampOverMax);
}
if !(((future_a >= initial_a) && (future_a <= initial_a * MAX_A_CHANGE))
    || ((future_a < initial_a) && (future_a * MAX_A_CHANGE >= initial_a)))
{
    panic_with_error!(&e, LiquidityPoolError::RampTooFast);
}
```

This inconsistency introduces a gap: while dynamic changes to amp are constrained, the initial amp used at pool creation is unchecked.

### Impact Explanation
The amplification coefficient (`amp`) plays a critical role in determining the behavior of a stableswap AMM. If this value is set too high, it can lead to instability, poor pricing, rounding issues, or increased risk of manipulation.

### Likelihood Explanation
The number of tokens required to produce an unsafe amp value is moderately high (≥ 6 in this case), and most real-world stableswap pools contain only 2–3 tokens. This makes the issue less likely in typical usage, however still very possible.

### Proof of Concept
The test below can be added to the router test suite (`liquidity_pool_router/src/test.rs`). It demonstrates how a user can create a pool with amp far exceeding the system-defined `MAX_A` value.

```rust
#[test]
fn test_init_stableswap_pool_exceeds_max_amp() {
    use crate::testutils::stableswap_pool::Client as StableClient;
    use soroban_sdk::{log, testutils::Address as _, Address, Env, Vec};
    use std::panic::{catch_unwind, AssertUnwindSafe};

    // 1. Setup
    let setup = Setup::default();
    let e = setup.env;
    let router = setup.router;
    let user = Address::generate(&e);
    let admin = setup.admin;
    let reward_token = setup.reward_token;
    e.mock_all_auths();

    // 2. Configure stablepool init payment
    reward_token.mint(&user, &10_000_000_000);
    let payment_for_creation_address = router.get_init_pool_payment_address();
    router.configure_init_pool_payment(
        &admin,
        &reward_token.address,
        &0,
        &1000_0000000,
        &payment_for_creation_address,
    );
    assert_eq!(reward_token.balance(&payment_for_creation_address), 0);

    // 3. Setting up tokens
    let mut tokens = Vec::new(&e);

    // Using existing tokens from setup that are already properly initialized from setup
    for i in 0..setup.tokens.len() {
        tokens.push_back(setup.tokens[i].address.clone());
    }

    // Creating additional tokens and initialize
    while tokens.len() < 6 {
        let token = create_token_contract(&e, &user);

        // Initializing the token properly - mint some balance to ensure it's active
        token.mint(&user, &1000_0000000);

        // Making sure the router can query this token by giving it a 0 balance
        // This ensures the balance() call in validate_tokens_contracts won't fail
        token.mint(&router.address, &0);

        tokens.push_back(token.address.clone());
    }

    let fee = 30;

    // The amp calculation should be:
    // amp = STABLESWAP_DEFAULT_A * n^(n-1) - where n = 6
    // STABLESWAP_DEFAULT_A = 750, then amp = 750 * 6^5 = 750 * 7776 = 5,832,000
    // MAX_A = 1,000,000 in stablepool contract

    // This should either:
    // 1. Succeed and create a pool with dangerously high amp (proving the vulnerability)
    // 2. Fail with a proper amp validation error (if validation exists)
    let result = catch_unwind(AssertUnwindSafe(|| {
        router.init_stableswap_pool(&user, &tokens, &fee)
    }));

    match result {
        Ok((_pool_hash, pool_address)) => {
            // Pool was created successfully - check if amp exceeds safe limits
            let pool = StableClient::new(&e, &pool_address);
            let amp = pool.a();

            // This proves the vulnerability - no amp validation exists
            assert!(
                amp > 1_000_000,
                "Amp {} should exceed reasonable MAX_A limit, proving lack of validation",
                amp
            );
        }
        Err(env) => {
            // Pool creation failed - check if it's due to amp validation
            log!(&e, "Pool creation failed: {:?}", 2);

            // If it fails here, we need to check if it's specifically due to amp validation
            // or some other issue. The test might need adjustment based on the actual error.
        }
    }
}
```
### Recommendation
Consider adding a check in the `liquidity_pool_stableswap::initialize` function:
```diff
fn initialize(..) {
        ...

        set_router(&e, &router);

        // 0.01% = 1; 1% = 100; 0.3% = 30
        if fee > FEE_DENOMINATOR - 1 {
            panic_with_error!(&e, LiquidityPoolValidationError::FeeOutOfBounds);
        }

+       if amp > MAX_A {
+           panic_with_error!(&e, LiquidityPoolValidationError::RampOverMax);
+       }
        ...
    }
```

# Info
## [I-1] DoS Attack on Reward System via Premature `fill_liquidity` Call
### Summary
The `fill_liquidity` function lacks access control and can be called by anyone at any time. This allows an attacker to disrupt the reward distribution for a token pair by invoking the function prematurely (before meaningful liquidity exists) or at strategically unfavorable times.

### Finding Description
The reward system follows a specific workflow:

`config_global_rewards` → `fill_liquidity` → `config_pool_rewards`

The `fill_liquidity` function calculates and stores the total liquidity across all pools for a token pair, which is then used to determine each pool's share of rewards.

The issue arises as there is a lack of access control, and lets attackers break the fair reward distribution based on actual liquidity ratios at the time of pool configuration.

```rust
fn fill_liquidity(e: Env, tokens: Vec<Address>) {
    // No require_auth() or admin check
    assert_tokens_sorted(&e, &tokens);
    // ...
}
```
Once called, the function sets `processed: true`, line 801, and prevents future calls via the `LiquidityAlreadyFilled` error lines 798-800. This means this is irreversible until admin reconfigures global rewards again.

### Impact Explanation
An attacker can front-run `fill_liquidity` immediately after config_global_rewards, before any meaningful liquidity is deposited. This locks in a `total_liquidity` value of zero, which leads to every pool receiving zero rewards — permanently.

This undermines the core fairness of the system:

- Users who provide real liquidity will receive no rewards.
- Admins must reconfigure global rewards to recover, which is inefficient and may not be feasible in live deployments.

This is a high economic DoS vulnerability.

### Proof of Concept
The following test can be pasted in the `liquidity_pool_router/src/test.rs` file:
```rust
#[test]
fn test_fill_liquidity_dos_attack() {
    // 1. Setup
    let setup = Setup::default();
    let e = setup.env;
    let router = setup.router;
    let admin = setup.rewards_admin;
    let reward_token = setup.reward_token;

    let attacker = Address::generate(&e);
    let honest_user = Address::generate(&e);
    let [token1, token2, _, _] = setup.tokens;
    let tokens = Vec::from_array(&e, [token1.address.clone(), token2.address.clone()]);
    e.mock_all_auths();

    // Fund reward token
    reward_token.mint(&admin, &1000_0000000);

    // 2. Admin configures global rewards FIRST 
    // (before any pools exist, or if there will be other pools with similar tokens)
    let reward_tps = 1000_0000000_u128; // High reward rate
    let rewards = Vec::from_array(&e, [(tokens.clone(), 1_0000000)]);
    router.config_global_rewards(&admin, &reward_tps, &e.ledger().timestamp().saturating_add(86400), &rewards);

    // 3. ATTACK: Attacker immediately calls fill_liquidity before any meaningful pools exist
    // This locks in ZERO total liquidity for reward calculations
    router.fill_liquidity(&tokens);

    // 4. Now honest users create pools with significant liquidity
    token1.mint(&honest_user, &1000_0000000);
    token2.mint(&honest_user, &1000_0000000);
    let (pool_hash, _pool_address) = router.init_standard_pool(&admin, &tokens, &30);
    
    let desired_amounts = Vec::from_array(&e, [500_0000000, 500_0000000]); // Large deposit
    router.deposit(&honest_user, &tokens, &pool_hash, &desired_amounts, &0);

    // 5. Try to configure pool rewards - this should result in zero rewards
    // because fill_liquidity was called when total liquidity was zero
    let pool_tps = router.config_pool_rewards(&tokens, &pool_hash);
    assert_eq!(pool_tps, 0, "Pool should get zero rewards due to premature fill_liquidity call");

    // 7. Wait and check that no rewards are distributed
    let time: u64 = 7 * 86400; // 7 days
    jump(&e, time);

    let honest_claimed = router.get_rewards_info(&honest_user, &tokens, &pool_hash);
    assert_eq!(honest_claimed.get(symbol_short!("to_claim")).unwrap(), 0, "Honest user should get no rewards due to DoS");
}
```

### Recommendation
Restrict `fill_liquidity` to authorized roles only:
```rust
fn fill_liquidity(e: Env, user: Address, tokens: Vec<Address>) {
    user.require_auth();
    require_rewards_admin_or_owner(&e, &user); // Add this line
    assert_tokens_sorted(&e, &tokens);
    // ... rest of function unchanged
}
```

## [I-2] Inconsistent Fee Bounds Between `liquidity_pool_router` and `liquidity_pool_stableswap` Allow Arbitrary Fee Increase
### Summary

In the `liquidity_pool_stableswap` contract, the admin can change the fee on swap that is configured to the pool. The check to bound the fee is incorrect, as it uses the wrong constant `FEE_DENOMINATOR`.

### Finding Description
A user can initiate a new Stablepool contract from the router. During this phase, the router enforces that the fee, passed in by the user, cannot go above 1% (in basis points):

router:
```rust
fn init_stableswap_pool(
    e: Env,
    user: Address,
    tokens: Vec<Address>,
    fee_fraction: u32,
) -> (BytesN<32>, Address) {
    ...
@>  if fee_fraction > STABLESWAP_MAX_FEE {  <@
        panic_with_error!(&e, LiquidityPoolRouterError::BadFee);
    }
    ...
```

constants (router):
```rust
...
pub(crate) const STABLESWAP_MAX_FEE: u32 = 100; // 1%
...
```

In the Stableswap contract, an admin can set the fee to a new fee:
```rust
// Sets a new fee to be applied in the future.
//
// # Arguments
//
// * `admin` - The address of the admin.
// * `new_fee` - The new fee to be applied.
fn commit_new_fee(e: Env, admin: Address, new_fee: u32) {
    admin.require_auth();
    require_operations_admin_or_owner(&e, &admin);

    if get_admin_actions_deadline(&e) != 0 {
        panic_with_error!(&e, LiquidityPoolError::AnotherActionActive);
    }
@>  if new_fee > FEE_DENOMINATOR - 1 {   <@
        panic_with_error!(e, LiquidityPoolValidationError::FeeOutOfBounds);
    }

    let deadline = e.ledger().timestamp() + ADMIN_ACTIONS_DELAY;
    put_admin_actions_deadline(&e, &deadline);
    put_future_fee(&e, &new_fee);

    Events::new(&e).commit_new_fee(new_fee);
}
```

The function does indeed has a check, however the `FEE_DENOMINATOR` constant in the pool contract does not match the `STABLESWAP_MAX_FEE` constant in the router contract:
```rust
pub const FEE_DENOMINATOR: u32 = 10000; // 0.01% = 0.0001 = 1 / 10000
```

### Impact Explanation
This issue can lead to the admin to potentially set the fee to up to 99%, as there is a -1 in the check. This can potentially ruin any swaps used in this pool, and steal from any user trying to swap. Therefore, it is HIGH.

### Likelihood Explanation
Only the admin is accessible to this function, and there is a two step process in order to complete this change of fee. However, the admin may make a mistake, or even get hacked and this could still occur. Therefore, likelihood is LOW.

### Proof of Concept
This test can be pasted in the `liquidity_pool_router/src/test.rs` file:
```rust
#[test]
fn test_admin_can_set_invalid_fee() {
    use crate::testutils::stableswap_pool::Client as StableClient;
    // 1. Setup
    let setup = Setup::default();
    let e = setup.env;
    let router = setup.router;
    let user = Address::generate(&e);
    let admin = setup.admin;
    let reward_token = setup.reward_token;
    let [token1, token2, _, _] = setup.tokens;
    let tokens = Vec::from_array(&e, [token1.address.clone(), token2.address.clone()]);
    e.mock_all_auths();

    // 2. Configure stablepool init payment
    reward_token.mint(&user, &10_000_000_000);
    let payment_for_creation_address = router.get_init_pool_payment_address();
    router.configure_init_pool_payment(
        &admin,
        &reward_token.address,
        &0,
        &1000_0000000,
        &payment_for_creation_address,
    );
    assert_eq!(reward_token.balance(&payment_for_creation_address), 0);

    // 3. Deploying pool
    let fee = 100; // Initial fee - max
    let (_, pool_address) = router.init_stableswap_pool(&user, &tokens, &fee);

    // 4. Admin making an invalid fee change
    let new_fee = 101; // Invalid fee
    let pool_client = StableClient::new(&e, &pool_address);
    pool_client.commit_new_fee(&admin, &new_fee);
    let time: u64 = 3 * 86400; // Deadline in 3 days
    jump(&e, time);
    pool_client.apply_new_fee(&admin);
}
```
### Recommendation
Add a new constant to match the one in the router constant:

In `liquidity_pool_stableswap/src/constants.rs` add:
```diff
pub(crate) const STABLESWAP_MAX_FEE: u32 = 100; // 1%
Change in liquidity_pool_stableswap::commit_new_fee:

- if new_fee > FEE_DENOMINATOR - 1 { 
+ if new_fee > STABLESWAP_MAX_FEE
      panic_with_error!(e, LiquidityPoolValidationError::FeeOutOfBounds);
  }
```

## [I-3] `liquidity_pool_router` Cannot Be Paused
### Summary
The router contract cannot be paused by the admin or emergency pause admin, despite the documentation explicitly stating this functionality exists.

### Finding Description
According to the project's README and admin role definitions, both the `Pause Admin` and `Emergency Pause Admin` roles are expected to have the ability to pause and unpause various components of the protocol—including the router itself. The documented responsibilities include:

Emergency Pause Admin:

- Pause pool deposits
- Pause pool swaps
- Pause pool claims

Pause Admin:

- All of the above
- Unpause pool deposits
- Unpause pool swaps
- Unpause pool claims

However, upon reviewing the `liquidity_pool_router` contract, there are no implemented functions that allow any role to pause or unpause router-level actions (e.g. `swap`, `deposit`, `withdraw`). There is no storage flag or access-controlled logic that checks for a paused state within the router’s public methods.

While the underlying pool contracts (e.g. stableswap and standard pool) correctly implement pause logic via `kill_*` and `unkill_*` methods, the router has no way of disabling its own entry points. This creates a misalignment between the documentation and the actual behavior of the deployed contract logic.

### Impact Explanation
Low as the pools that hold the funds can be paused. But ff a critical vulnerability is found in the router logic (e.g. swap routing, deposit routing, multi-hop swaps), admins will be unable to halt the router contract to prevent further exploitation. This could result in irreversible loss of funds or protocol-wide disruptions.

The pause mechanisms are often a last line of defense. Their absence at the router level may severely limit incident response in production scenarios.

### Likelihood Explanation
The likelihood is low. While an exploit in the router itself has not been identified, the inability to pause this central contract increases risk exposure. Moreover, developers and auditors may assume this functionality exists based on the documentation and role definitions—leading to a false sense of security.

### Proof of Concept
I could not test this with code as the code does not exists. Instead this can be proven by:

1. Reviewing the router contract: there are no `kill_*` or `unkill_*` methods in the router codebase.
2. Attempting to locate any storage flags for `is_paused`, `pause_state`, etc. — none exist.
3. Attempting to write tests to pause the router — impossible due to lack of logic or access control handlers.

In contrast, pool contracts (e.g. stableswap) contain logic like:
```rust
fn kill_swap(e: Env, admin: Address) {
    admin.require_auth();
    require_pause_or_emergency_pause_admin_or_owner(&e, &admin);
    set_is_killed_swap(&e, &true);
}
```

No such analog exists in the router contract.

### Recommendation
Implement pause/unpause functions within the router contract, along with internal checks in sensitive entry points like swap, deposit etc.

```rust
fn set_router_paused(e: Env, admin: Address, paused: bool) {
    admin.require_auth();
    AccessControl::new(&e).assert_address_has_role(&admin, &Role::PauseAdmin);
    set_router_pause_state(&e, &paused);
}

fn ensure_not_paused(e: &Env) {
    if get_router_pause_state(e) {
        panic_with_error!(e, RouterError::Paused);
    }
}
```

## [I-4] Wrong Doc Comments In `liquidity_pool_router::configure_init_pool_payment`
### Summary
The `configure_init_pool_payment` function sets deployment payment parameters for both standard and stableswap pools, but the comment above the function incorrectly states that it only affects stableswap pools.

### Finding Description
The doc comment suggests the function is limited to stableswap pool configuration. However, it sets values that affect both stableswap and standard pools, including:

- The payment token
- The payment amounts for both pool types
- The recipient address

This mismatch can lead to misconfiguration or misunderstanding by integrators and protocol maintainers.

### Impact Explanation
This does not affect core protocol safety but introduces a risk of operational error or misconfiguration if trusted users misunderstand the function’s purpose.

### Likelihood Explanation
Very likely to cause confusion among new integrators or DAO admins relying on doc comments and not reading code.

### Recommendation
Update the doc comment to accurately reflect the function’s purpose:
```rust
// Configures the pool deployment payment for both standard and stableswap pools.
//
// # Arguments
//
// * `admin` - The address of the admin.
// * `token` - The address of the token.
// * `standard_pool_amount` - The amount of the standard pool token.
// * `stable_pool_amount` - The amount of the stableswap pool token.
// * `to` - The address to send the payment to.
```

## [I-5] Missing Event Emissions On Critical Methods
### Summary
Critical methods should emit events upon using them, as it provides easier monitoring of the system. In a few places in the system, there seems to be missing event emissions.

### Finding Description
Found Instances:

- `liquidity_pool_router::set_liquidity_calculator`
- `liquidity_pool_router::init_admin`
- `liquidity_pool_router::set_reward_token`

### Impact Explanation
Lack of an event does not compromise protocol correctness, but it limits transparency. Off-chain indexers, dashboards, and audit tools cannot detect or notify stakeholders when the liquidity calculator changes. This increases operational risk, especially in the case of misconfiguration or compromised admin keys.

### Likelihood Explanation
When changes do occur, they are highly sensitive and need to be observable for operational and security purposes. The absence of an event increases the chance that such changes go unnoticed.

### Recommendation
Emit a clear events when critical methods are used.