# colibrì desktop

Tauri v2 shell for the shared React interface in `../web`.

This directory intentionally contains no second frontend. During development,
Tauri starts the Vite server from `web/`; release builds package `web/dist`.

## Development

The shared web UI landed in PR #23 and is already part of `main`. From the
repository root, install its dependencies and start the desktop shell:

```sh
cd web
npm ci
cd ../desktop
cargo install tauri-cli --version "^2.0.0" --locked
cargo tauri dev
```

The application connects to an OpenAI-compatible server configured in the UI.
Bundling the inference engine or managing its process is intentionally deferred:
the model is hundreds of gigabytes and must remain an external, user-selected
resource rather than an opaque application sidecar.

Because the endpoint is user-configurable, it may be loopback (`127.0.0.1`),
another machine on the LAN, or a remote HTTPS server. The window's CSP
`connect-src` therefore allows any `http:`/`https:` destination in addition to
Tauri's own `ipc:`/`asset:` origins, while `default-src`, `style-src`, and
`img-src` remain restricted to the bundled UI. This does not affect what the
*page* may load (still `'self'`-only), only which network endpoints `fetch`/
`XHR` calls from the UI may reach.

This first desktop increment only packages the existing UI in a native window.
It does not change the web application, start the inference engine, download
models, or add native filesystem and process permissions.

## Validation

```sh
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo check --manifest-path src-tauri/Cargo.toml
```
