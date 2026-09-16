# Experimental Go RAG router (`:8082`)

Side quest. Not Heal, not Galaxy, not this quarter.

Same job as [`../rust_router`](../rust_router): a non-privileged loopback
chat door on `127.0.0.1:8082` that talks to canonical rag-service
(`:8084`) and the mouth on `:8000`. No `command_type` dispatcher. Cannot
run at the same time as the Rust router (same port).

Desk runtime is the C++ kernel on `:8083`. This tree exists so the old
root `main.go` is not sitting in the lobby next to Start/Heal.

```powershell
Push-Location godbrain_core\go_router
go test ./...
go build .
Pop-Location
```

Go **Alexandria rollback** is a different tree:
[`../memory_store`](../memory_store). Do not merge them. Do not delete
the rollback store.
