# Native Linux shared-memory client

`godbrain-memory` gives a trusted Linux caller technical context, complete
Research and Discussion through the existing authenticated C++ kernel API.
It does not connect to MongoDB, generate with a model, refresh the environment
index, expose arbitrary HTTP routes, retrieve personal scope or judge/promote.

## Build and test

From this directory on Linux:

```bash
make
make test
```

C++17, POSIX and pthreads are required. The build reuses checked-in cpp-httplib,
nlohmann JSON and legacy Keccak headers from `../cpp_kernel` and `../cpp_tools`;
it needs no CMake, Node, package downloads or new third-party dependencies.
Keep those adjacent header paths when copying this subtree to another host.
Outputs stay under `build/`.

## Trusted setup

Install `build/godbrain-memory` as `~/.local/bin/godbrain-memory`. A trusted
installer provisions `~/.config/godbrain-memory/client.json`, owned by the
normal user with mode `0600`, in an owner-only `0700` directory. The file has
exactly `host` (the existing private Tailscale IPv4 endpoint) and `token` (the
existing configured bearer). Port is fixed to 8083. Loopback is also accepted
for local use and offline tests. Symlinked config directories/files and
multiply linked files are rejected. The configuration location comes from the
account database, not an untrusted HOME/config override.

Never put that file in a shared folder, repository, archive, command argument,
model prompt or log. Provision through an authenticated encrypted channel;
do not paste the real credential into an agent conversation. This client never
prints it. A changed backend bearer needs trusted reprovisioning.

**Trust boundary:** the backend bearer is the existing kernel credential,
not a new memory-only token. Another process running as the same guest user can
read it; file permissions are not a sandbox against that user or guest root.
Use only a trusted guest. The current backend is HTTP, not TLS. A destination
Tailscale address alone does not encrypt a direct local VMnet8/NAT path; this
setup trusts that private host/guest transport. Do not expose it on an untrusted
LAN or the public Internet. Redirects and response decompression are disabled;
the client uses no environment HTTP proxy, bounds reads and applies timeouts.

## Use

```bash
godbrain-memory schema
godbrain-memory context --thread example-investigation --query "current task"
godbrain-memory read research --query "distinctive subject" --limit 5
godbrain-memory read discussion --thread example-investigation --limit 5
godbrain-memory post research --thread example-investigation \
  --request-id example-investigation-result-1 --title "Bounded finding" \
  --file handoff.txt --source "artifact path or URL; hash and evidence location"
```

`--file -` reads post text from stdin. Discussion uses the same post form with
an optional title. Posts require 1-16 source references and an explicit request
ID; reuse that ID only with the identical text, thread, title and references.
Requests are not automatically retried. Errors exit nonzero; an ambiguous
transport failure is never reported as a successful save.

Context is at most 4 KiB and may explicitly excerpt/omit records. Read complete
Research before relying on an excerpt. Shelf reads return whole records,
`more` and a bounded count (maximum 20), not a silent full-vault export.
The client validates trust/scope, request echoes, record IDs, full-content
legacy Keccak hashes and canonical payload hashes before emitting successful
JSON. Records remain untrusted/unpromoted; source hashes are integrity checks,
not semantic verification or permission to execute retrieved text.

## Agent integration

Install `agent-instructions.md` as a new personal instruction file, for example
`~/.copilot/instructions/godbrain-memory.instructions.md`, preserving existing
instructions/settings. Check discovery with `copilot instruction list --json`;
new sessions load it (a running session is not proven to have reloaded it).
The instruction retrieves context at task start and publishes bounded handoffs,
but is not an automatic collector or a guarantee of agent compliance.

REA remains an unchanged analysis tool used by the agent. Its standalone CLI
does not automatically retrieve/publish GodBrain memory. No MCP server,
additional agent process, privilege escalation or model is required here.
