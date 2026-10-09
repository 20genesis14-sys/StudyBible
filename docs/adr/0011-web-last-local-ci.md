# 0011. Web last, web-ready foundation, local CI

**English** | [Русский](0011-web-last-local-ci.ru.md)

Status: accepted.

## Context

The web brings the least benefit relative to cost, but wasm32
constraints shape the core's ports. The code repository is local for
now.

## Decision

The web is finalized and tested at the very end. For now — only the
foundation: the core without `std::fs` and blocking, a compile check of
the core for `wasm32-unknown-unknown`. CI — the local script
`scripts/ci.ps1` (fmt, clippy, test, wasm32 check, cargo-deny). Android
and iOS builds are added at Beta.

## Consequences

When moved to a Git host, the script becomes a CI pipeline without
changing the steps.
