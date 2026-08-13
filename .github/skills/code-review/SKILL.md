---
name: code-review
description: Review GodBrain changes that touch privileged command dispatch, native process execution, HTTP trust boundaries, Alexandria C++/Go ingestion, MongoDB state or idempotency, or bounded market/chain components. Use only for repository-specific code reviews in these areas; do not trigger for general prose, formatting, or unrelated Colibri UI changes.
---

# GodBrain security-boundary review

Report only high-confidence defects introduced by the change. Trace changed
inputs through the real source/configuration before claiming an exploit or data
integrity failure. Do not request broad rewrites when a narrow fix preserves the
existing boundary.

## Privileged kernel and HTTP

- Confirm every `command_type` request still fails closed unless
  `GODBRAIN_API_TOKEN` is configured and the bearer token matches.
- Confirm new or renamed side-effecting commands cannot avoid an explicit
  sovereignty-policy decision. Treat `reasoning` as an intent check, never as
  authorization.
- Flag widened bind addresses, wildcard/reflected unvalidated CORS, tokens in
  logs/responses, or ordinary chat/model/database content reaching execution
  without a separate authenticated dispatch request.
- Trace command strings and executable paths into `CreateProcess`, `_popen`, or
  PowerShell. Check quoting, mutable Win32 command-line storage, handle
  inheritance/closure, bounded output, timeouts, and exact-child reaping. Reject
  process-name-wide kills.

## Alexandria protocol and MongoDB

- Compare C++ producer and Go consumer changes together: JSON field names and
  types, exactly-one-document framing, stdout-only receipt/error JSON, stderr
  logging, input limits, exit codes, and legacy Keccak-256 source hashes must
  remain compatible.
- Require strict input validation before writes: raw transcript hash, candidate
  trust tier, source/extractor/schema identity, evidence bounds where relevant,
  and unknown/trailing JSON rejection.
- Check the legal run transitions and lease predicates. A write or transition
  must not succeed for a stale lease, wrong state, different source, or
  concurrent attempt.
- Check idempotency under retries and duplicate-key races. The active-run key is
  source hash plus extractor identity/version plus schema version; failed runs
  may retry without creating a second active run.
- Preserve immutable sources/nodes and append-only `source_observations` and
  `run_node_links`. Flag code that overwrites shared node provenance, exposes
  uncommitted nodes, or promotes a skill without a verified committed origin and
  matching version/hash.
- Ensure partial failures either fail the run or compensate attempt-owned links;
  do not return a success-shaped receipt before writes and state transitions are
  confirmed.

## Bounded market and chain components

- Compare changes against the subtree README and public interfaces. Flag newly
  reachable signing, wallet/account access, private keys, transaction
  submission/broadcasting, pending-pool inspection, state mutation, or automatic
  risk-limit increases.
- Preserve endpoint/method/host allowlists, chain/block/hash/receipt validation,
  confirmation and freshness checks, deterministic integer accounting,
  idempotent persistence, and fail-closed restart/reconciliation behavior.
- Tests and fixtures must stay synthetic/offline unless an integration test is
  explicitly opt-in and read-only.

## Review output

For each finding, identify the changed line, the concrete reachable scenario,
and the violated invariant. Do not report speculative hardening, style,
pre-existing issues, or model-generated claims that cannot be verified from the
repository.
