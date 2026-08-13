# GodBrain Atlas solver skeleton

This directory contains a minimal, review-oriented Foundry project for an Atlas solver. It is **not production-ready,
has no deployment script, and must not be deployed to mainnet or Polygon without an independent security review**.
The contract does not claim to find profitable routes: it only executes an owner-allowlisted target call and verifies
that the configured ERC-20 balance increased by a caller-specified minimum after the Atlas bid is paid. This net-output
check does not account for gas, Atlas reconciliation liabilities, token prices, slippage outside the measured call, or
other costs, so it is not a profitability guarantee.

## Pinned dependencies

All dependencies are Git submodules at immutable commits:

| Dependency | Commit |
| --- | --- |
| [FastLane Atlas](https://github.com/FastLane-Labs/atlas) | `083dccd05a2c92e0e9cae90ac404504f741bc493` |
| [Solady](https://github.com/Vectorized/solady) | `42af395e631fcc9d640eddf11c57c6f1ca3f9103` |
| [forge-std](https://github.com/foundry-rs/forge-std) | `bf909b22fa55e244796dfa920c9639fdffa1c545` |

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
```

Offline unit tests require no environment variables or RPC access.

For the optional Polygon deployment check, set only a read-only RPC URL:

```powershell
$env:POLYGON_RPC_URL = "https://your-polygon-rpc.example"
forge test --match-contract GodBrainMEVPolygonForkTest
```

`POLYGON_RPC_URL` is optional. No private key, mnemonic, signer, broadcast command, or transaction is used.

## Constructor and operation

Deployments, if ever independently approved, must explicitly supply `(wrappedNative, atlas, owner)` constructor
arguments. Atlas is immutable. `solverOpData` must canonically encode `GodBrainMEV.execute(target, callData,
outputToken, minimumNetOutputIncrease)`; other selectors, malformed encodings, and trailing data are rejected.

The six-argument `atlasSolverCall` applies the official inherited `safetyFirst` modifier outermost, executes only the
validated self-call, pays the bid through the official inherited `payBids` modifier, checks the resulting net output
token increase, and then lets `safetyFirst` reconcile Atlas shortfalls. A bid paid in the output token reduces the
measured net increase. When the output token is the wrapped-native token and a native bid requires an unwrap, that
unwrap also reduces the measured net increase. Native value is never forwarded to the execution target.
