# Experimental Rust RAG router (`:8082`)

Side quest. Not Heal, not Galaxy, not this quarter.

Same job as [`../go_router`](../go_router): loopback chat on
`127.0.0.1:8082` via canonical rag-service. Search-only; `/api/graph` and
`/api/node` still `410`. Cannot run with the Go router (same port).

```powershell
Push-Location godbrain_core\rust_router
cargo test --locked
cargo build --locked
Pop-Location
```
