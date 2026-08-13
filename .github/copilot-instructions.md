# GodBrain Copilot instructions

Follow the repository-wide instructions in [`../AGENTS.md`](../AGENTS.md).
They are the source of truth for architecture, scoped setup and validation
commands, secrets, and security invariants.

In particular, the active privileged boundary is the Windows C++ kernel under
`godbrain_core/cpp_kernel/`; there is no active Python kernel. Do not bypass its
bearer-token authorization or sovereignty checks, and preserve the C++/Go
Alexandria protocol when changing either side.
