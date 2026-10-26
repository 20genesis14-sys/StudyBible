- Id: 003-sbz-search
- Version: 1 (2026-10-18)
- Class: rust-core
- Base: e098ef155469d7631b4a55ca6ea64995ce01048d
- Reference: 4cc7860

## Setup

Worktree from Base (run-eval.ps1 -Setup); no extra environment needed
(cargo tests are self-contained).

## Task

On a packed `.sbz` module, search silently returns empty results:
full-text search, the glob `scan` query and search-in-notes-with-layer
all fail, and the bridge guard turns the error into empty lists. On
the same module unpacked as `.sb` everything works. Local development
missed it because the module scan skips an `.sbz` when a same-named
`.sb` sits next to it.

Find the cause and fix it so search works on packed modules without
changing the on-disk format. Add regression tests that pack a fixture
into a real SBZ1 container and assert non-empty results for embedded
fts, glob scan and notes search.

## Checks

- [ ] Workspace tests pass — `cargo test -p studybible-store` → exit 0
- [ ] Regression tests pack a real SBZ1 container and assert results
  for embedded fts + glob scan + notes search (manual)
