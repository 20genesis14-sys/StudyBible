# 0001. Rust core, ports and adapters, replaceable UI

**English** | [Русский](0001-rust-core-ports-adapters.ru.md)

Status: accepted.

## Context

Six platforms, instant response, low resource consumption. The UI is not
chosen yet and may be rewritten.

## Decision

The domain lives only in Rust (`studybible-core`). The outside world is
reached through ports: module storage, user database, index cache,
speech; later — repositories and network. Adapters live outside the core.
The binding to the UI is single and thin, chosen together with the UI.
No JS and no webview on desktop and mobile.

## Consequences

The UI can be replaced without rewriting the core. `std::fs` and
`std::thread::sleep` are forbidden in the core
(`crates/studybible-core/clippy.toml`).
