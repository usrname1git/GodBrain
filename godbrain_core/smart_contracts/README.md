# GodBrain Atlas atomic cycle boundary

This directory contains a review-oriented Foundry project for an Atlas solver and a solver-bound, typed two-router
cycle executor. It is **not production-ready, has no deployment script, and must not be deployed to mainnet or Polygon
without an independent security review**. Nothing in this directory signs, submits, broadcasts, funds, or deploys a
transaction, and no live router or token addresses are included.

The supported typed cycle is deliberately narrow:

```text
solver token A
  -> exact allowance to immutable-bound executor
  -> Router02-compatible exact-input A -> B
  -> Router02-compatible exact-input B -> A
  -> all returned A back to solver
  -> Atlas bid payment
  -> solver verifies the net A balance increase
```

There is no delegate call, arbitrary executor calldata, Permit2, multicall, flash loan, native forwarding, fee-on-
transfer selector, fallback, or route discovery surface.

## Pinned dependencies

All dependencies are Git submodules at immutable commits:

| Dependency | Commit |
| --- | --- |
| [FastLane Atlas](https://github.com/FastLane-Labs/atlas) | `083dccd05a2c92e0e9cae90ac404504f741bc493` |
| [Solady](https://github.com/Vectorized/solady) | `42af395e631fcc9d640eddf11c57c6f1ca3f9103` |
| [forge-std](https://github.com/foundry-rs/forge-std) | `bf909b22fa55e244796dfa920c9639fdffa1c545` |

The Router02-compatible semantics were reviewed against the official Uniswap V2 periphery source at immutable commit
[`ed24991304291297c3b4a52818d02f46a17aa9a2`](https://github.com/Uniswap/v2-periphery/tree/ed24991304291297c3b4a52818d02f46a17aa9a2).
`IUniswapV2Router01.swapExactTokensForTokens` pulls the exact input from its caller, applies the caller's minimum output
and deadline, sends output to the specified recipient, and returns one amount per path element. Router02 inherits that
method. The executor accepts only a two-address path, requires a 128-byte ABI return encoding for exactly two amounts,
and checks both returned amounts against actual balance changes. The fee-on-transfer variants are intentionally absent.

`SolverBase` and `ISolverContract` are imported directly from the pinned Atlas source. Polygon deployment addresses
come from Atlas
[`deployments.json`](https://github.com/FastLane-Labs/atlas/blob/083dccd05a2c92e0e9cae90ac404504f741bc493/deployments.json):

| Contract | Polygon address |
| --- | --- |
| Atlas | `0x4A394bD4Bc2f4309ac0b75c052b242ba3e0f32e0` |
| AtlasVerification | `0xf31cf8740Dc4438Bb89a56Ee2234Ba9d5595c0E9` |
| Simulator | `0x702b0b3690642B880dF6B018ead7F3C30ECe5c6b` |
| Sorter | `0x8f9960ce75DEFcdbA980bfCeDBB729F1329e629A` |
| FLOnline DAppControl | `0x498aC70345AD6b161eEf4AFBEA8F010401cfa780` |

`SolverBase.WETH_ADDRESS` means the chain's IWETH9-compatible wrapped-native token, not bridged Ethereum WETH. On
Polygon, the pinned FastLane
[`atlas-solver-example`](https://github.com/FastLane-Labs/atlas-solver-example/blob/f2c1d703b9c36b74d6c783c0bd256d689f546b45/script/deploy.s.sol)
identifies Polygon's wrapped-native contract at `0x0d500B1d8E8eF31e21C99d1Db9A6444d3ADf1270` (then named WMATIC;
the live contract now reports WPOL). The optional fork test verifies that both this wrapped-native address and the
pinned Atlas address contain deployed code.

## Build and test

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then from the repository root:

```powershell
git submodule update --init
Set-Location godbrain_core\smart_contracts
forge fmt --check
forge build
forge test
forge lint
```

Offline unit tests require no environment variables or RPC access.

For the optional Polygon deployment check, set only a read-only RPC URL:

```powershell
$env:POLYGON_RPC_URL = "https://your-polygon-rpc.example"
forge test --match-contract GodBrainMEVPolygonForkTest
```

`POLYGON_RPC_URL` is optional. No private key, mnemonic, signer, broadcast command, or transaction is used.

## Contracts and operation

Deployments, if ever independently approved, must explicitly supply `(wrappedNative, atlas, owner)` constructor
arguments. Atlas and owner are immutable. A `TwoRouterCycleExecutor` separately takes the deployed solver address and
stores it immutably; only that solver can execute a cycle or recover accidental residue.

The existing owner-allowlisted `execute(target, callData, outputToken, minimumNetOutputIncrease)` path remains for
reviewed targets. The new `executeCycle(executor, params, minimumNetOutputIncrease)` path accepts only the fixed
`CycleParams` tuple:

| Field | Meaning |
| --- | --- |
| `tokenA`, `tokenB` | Distinct ERC-20 contracts; the cycle must end in `tokenA` |
| `routerOne`, `routerTwo` | Distinct owner-allowlisted contracts with code |
| `amountIn` | Exact token A principal pulled from the solver |
| `minimumAmountOutFirst` | Minimum token B balance after the first leg |
| `minimumAmountOutSecond` | Minimum token A balance after the second leg |
| `minimumReturnedAmount` | Minimum principal plus gross profit returned to the solver |
| `deadline` | Router02-compatible block timestamp deadline |

Both selectors are accepted only through the official six-argument `atlasSolverCall`. Other selectors, malformed
encodings, and trailing data are rejected. The typed tuple is a fixed canonical 356-byte encoding. Total
`solverOpData` remains capped at 16 KiB before dynamic decode or hashing. The canonical synthetic vector in
`TwoRouterCycleExecutor.t.sol` uses only reserved test addresses and has Keccak-256 digest
`0x498aa10974c124c3bf48db1d0ea9eaa5108e2f962e652bc556c926469f255cf3`.

The six-argument `atlasSolverCall` applies the official inherited `safetyFirst` modifier outermost, executes only the
validated self-call, pays the bid through the official inherited `payBids` modifier, checks the resulting net output
token increase, and then lets `safetyFirst` reconcile Atlas shortfalls. A bid paid in the output token reduces the
measured net increase. When the output token is the wrapped-native token and a native bid requires an unwrap, that
unwrap also reduces the measured net increase. Native value is never forwarded to the execution target.

### Capital and allowance safety

For a typed cycle, the solver:

1. verifies the executor's code, allowlist entry, and immutable solver binding;
2. verifies both routers are still owner-allowlisted contracts;
3. clears any stale executor allowance, grants exactly `amountIn`, and verifies it;
4. invokes the fixed executor selector without native value;
5. clears and verifies the executor allowance; and
6. checks `solverAfter == solverBefore - amountIn + returnedAmount`.

The executor starts only when its token A and token B balances are zero. It pulls exactly `amountIn`, verifies the
solver's decrease and its own receipt, grants each router only that leg's exact input, and clears and verifies each
allowance immediately after the call. Each router must consume the entire input and return an ABI array matching the
actual output balance. The executor returns all token A and verifies that no token A or B residue remains. Any failure
reverts the entire Atlas operation, including approvals and the first leg. Tokens that require zero-first approval are
supported; fee-on-transfer, rebasing, malformed, or otherwise non-exact balance behavior is rejected. Accidental dust
blocks execution so it cannot be counted as cycle output; the solver owner may recover it only back to the solver.

### Profit accounting

The accounting terms are intentionally separate:

```text
returned principal = amountIn
gross cycle output = returnedAmount
gross profit        = returnedAmount - amountIn
Atlas bid           = paid by SolverBase after the cycle
net profit          = solver token A balance after bid - balance before cycle
```

Because the net snapshot is taken before the executor pulls principal and checked after `payBids`, returned principal
cannot be counted as profit and a bid paid in token A reduces the accepted net output. Events report principal, gross
output, gross profit, the returned-amount floor, and the required net profit separately.

This remains a token-balance invariant, not a profitability proof. It does not account for gas, token prices,
reconciliation liabilities, inclusion, reorgs, or opportunity decay. Atlas reconciliation still occurs outside the
net-output check, so no reconciliation-adjusted profit claim is made.

## Paper pipeline boundary

The architecture remains:

```text
Bor/Heimdall observer
  -> paper-only Polygon searcher/pipeline
  -> data-only Atlas simulation plan
  -> separately configured typed Solidity simulation boundary
```

The C++ `atlas_simulation_plan` is not ABI calldata and remains unable to sign, submit, broadcast, or execute. It
contains observed quotes and modeled limits, but it does not contain a deployed solver/executor binding or an approved
slippage policy that converts observations into `minimumAmountOutFirst`, `minimumAmountOutSecond`, and
`minimumReturnedAmount`. Its millisecond paper deadline also is not silently treated as a Solidity timestamp. A
cross-language executable fixture would therefore be misleading until those deployment and risk-policy inputs are
specified and reviewed; this change intentionally adds only the Solidity canonical encoding vector.
