# Polygon pipeline

This directory is a focused C++20, paper-only bridge from the local Polygon
observer to the Polygon searcher. It supports chain ID 137 only. It ships no
token, venue, router, or wrapped-native addresses; operators must supply a
reviewed, immutable-evidence configuration.

## Build and test

```powershell
cmake -S godbrain_core\polygon_pipeline -B godbrain_core\polygon_pipeline\build -DBUILD_TESTING=ON
cmake --build godbrain_core\polygon_pipeline\build --config Debug
ctest --test-dir godbrain_core\polygon_pipeline\build -C Debug --output-on-failure
```

The standalone CMake project adds the sibling observer and searcher only when
their targets do not already exist. All pipeline targets use `/W4 /WX
/permissive-` on MSVC and `-Wall -Wextra -Wpedantic -Werror` elsewhere.

## Commands

```text
godbrain-polygon-pipeline validate-config CONFIG.json
godbrain-polygon-pipeline replay CONFIG.json SANITIZED.json OUTPUT_PREFIX
godbrain-polygon-pipeline status CONFIG.json STATE.json
godbrain-polygon-pipeline scan-once CONFIG.json STATE.json
```

- `validate-config` is offline.
- `replay` is offline and writes deterministic `OUTPUT_PREFIX.json` and
  `OUTPUT_PREFIX.csv`; the prefix must be a filename in the current directory.
  Checked-in sanitized fixtures under `tests/fixtures` exercise this command in
  CTest, and unit coverage compares independently written reports byte for byte.
  Inputs and outputs are labeled test evidence, not market evidence.
- `status` accesses only explicit loopback Bor and Heimdall endpoints.
- `scan-once` performs one read-only scan, persists only paper audit state, and
  emits decisions, the selected paper plan/result, and a data-only Atlas
  simulation envelope.

State JSON has exactly these fields:

```json
{
  "schema_version": 1,
  "rpc_endpoint": "http://127.0.0.1:8545/",
  "heimdall_endpoint": "http://127.0.0.1:26657/status",
  "amount_in": 100000,
  "audit_directory": "C:\\absolute\\normalized\\paper-audit"
}
```

The audit parent must already be a real local directory. Traversal, root,
relative, symlink-target, and non-directory paths are rejected.

## Reviewed configuration

Configuration is strict: unknown fields fail. It requires schema 1, chain 137,
an immutable HTTPS evidence URL without query or fragment, lowercase SHA-256
source and evidence revisions, canonical lowercase addresses, token decimals
at most 18, and venue kind exactly `uniswap_v2_get_amounts_out`.

`tokens`, `venues`, `routes`, and `cycles` are explicit arrays. A cycle names
two distinct routes that close over two tokens and use two distinct venues.
The gas conversion object contains only `wrapped_native`, `input_token`, and a
reviewed `route_id`; that route must map wrapped native to the input token.
Duplicate IDs, addresses, routes, cycles, same-venue cycles, and malformed
paths fail closed. Numeric quote, calldata, confirmation, age, and gas ceilings
are mandatory and bounded.

No example live addresses are provided. The authoritative fixed interface
review source is:

- Uniswap V2 router interface, immutable commit:
  <https://github.com/Uniswap/v2-periphery/tree/ed24991304291297c3b4a52818d02f46a17aa9a2/contracts/interfaces>
- Bor v2.10.0, immutable commit already reviewed by the observer:
  <https://github.com/0xPolygon/bor/tree/82d3b610d48468462a504245b5839de66dc86272>

## Block and quote semantics

The block provider health-gates on the observer, selects
`head - confirmation_depth`, and fetches that exact block number. Every V2
quote checks the number/hash before and after, verifies router code at that
number, and uses `eth_call` with an explicit canonical number tag. The gas
conversion is another exact-input V2 quote at the same block for
`gas_units_ceiling * baseFeePerGas`.

This uses number-tag calls plus before/after hash rechecks; it does **not**
claim EIP-1898 hash-pinned calls. A residual reorg window remains after the
final check. Consumers must treat every output as an observation, not a
settlement guarantee.

## Safety and evidence limits

The ABI surface is fixed to selector `d06ca61f` and exactly two-token paths.
There is no arbitrary selector entry point. Atlas output contains constraints,
modeled limits, evidence hashes, and deadlines only. It contains no execution
calldata, wallet, nonce, signature, fee bid, relay, mutation, submission, or
deployment surface. The only executor is a deterministic in-process paper
result model; there is no live executor.

Nothing here proves live liquidity, realizable profit, inclusion, atomicity, or
post-check canonicality. The separate smart-contract project now has an
offline-tested, typed two-router Atlas simulation boundary, but it is not
integrated with this pipeline. This envelope is not ABI calldata and deliberately
omits deployed solver/executor bindings and the reviewed slippage policy needed
to derive per-leg and final execution minima. Observed quote outputs must not be
silently treated as executable minima.

The end-to-end boundary is therefore Bor/Heimdall observation -> paper search
and pipeline -> data-only simulation plan -> separately configured typed
Solidity simulation. No layer here deploys, signs, submits, broadcasts, funds,
or includes live router/token addresses.
