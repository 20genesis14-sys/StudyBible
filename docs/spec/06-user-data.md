# 06. User data

**English** | [Русский](06-user-data.ru.md)

Status: implemented in `crates/studybible-store/src/userdata.rs` (MVP 5).
Decisions — ADR 0008 (data on device only), DECISIONS: "Synchronization".

## Database

A separate SQLite (`userdata.db` in the data root, `--db` overrides),
`journal_mode=WAL`, schema version in `meta` (`schema = 3`) — migrations
are added, not rewritten (1→3: `vrs`, `module_ver`, `canon_*`; 2→3: only
`canon_*`). `meta` also has `device` — a unique database id, generated
at creation.

## Table `entries`

```
id      TEXT PRIMARY KEY          — hex "milliseconds + counter"
module  TEXT                      — module meta.id (not the file path)
kind    TEXT                      — note | mark | hl
book, chapter, verse              — verse coordinate (always a fallback anchor)
text    TEXT                      — note text / bookmark label / highlight color
context TEXT                      — a text check fragment for re-anchoring
created, updated INTEGER          — unix milliseconds
deleted INTEGER                   — 0 = live; otherwise deletion time (tombstone)
device  TEXT                      — whose edit was last
rev     INTEGER                   — revision number, grows on edit
vrs     TEXT                      — module versification at write time (schema 2)
module_ver TEXT                   — module content_hash (else version), schema 2
canon_book, canon_c1, canon_v1,
canon_c2, canon_v2                — the verse's canonical range in the org grid
                                  (schema 3, stage A); canon_book='' — not written
```

## Re-anchoring (schema 2, question № 12, stage B)

When a record is created, the bridge (`entry_add`) and CLI (`user add`)
write `vrs`, `module_ver` and `context` (up to 40 chars of verse text)
from the installed module themselves; the Dart side does not need to
pass them. `UserData::relink` checks live records against installed
modules: meta matched — fresh; `vrs`/`module_ver` changed — look for
`context` in the anchor verse, then in ±2 verses of the same chapter
(found — the anchor moves with `rev+1`; not found — an orphan, the
record is untouched, its id in the report); records without context get
a fragment of the current verse and fresh meta.
Calls: `user relink`, a background run at app start, after a module
import. Stamping and moving also update the canonical range.
The run's orphan list goes to `meta.orphans` (a JSON array of ids, each
run overwrites; the schema does not change): the "Records" screen shows
them in a "Lost" section.

## Cross-translation records (schema 3, question № 12, stage A)

When a record is created and when re-anchored, the canonical range is
written — edge points `vrs.to_org(anchor)`; the range covers verse
splits and merges in one form. `UserData::entries_foreign(module,
org_keys, installed)` returns live records of other modules whose range
contains the requested verse's org keys; `installed` cuts off
uninstalled modules (by the decision — records for them are visible
only in the "Records" tab). Bridge: `entries_foreign_list`. Display: in
text — only own; foreign ones — a "Records in other translations"
button inside the note dialog; tapping a foreign one — navigates to its
verse in its translation + the record window; the "Records" tab groups
records by `module`.

## Export and import

A zip (uncompressed) with a single `userdata.json` file:
`{"format": "studybible-userdata", "version": "3", "entries": […]}` —
including tombstones; `"version": "1"` and `"2"` exports are also
accepted (new fields — serde default). Markdown export —
`user export-md` (1.0.1): export only, live records, grouped by
module → kind, a list with creation dates.

Merge: a record is applied if its `updated` is newer than the existing
one; a tombstone beats an old live record, a fresh edit beats an old
tombstone. A tie is resolved deterministically by equal `updated`. We
walk the import list: added / updated / skipped.

**v1 simplification:** a conflict of simultaneous edits of one note is
resolved as "newest wins" — the second version is not kept (the "keep
both versions" decision is postponed until real folder sync).

What the schema lacks: an intra-verse offset (a record is bound to a
whole verse) and a canonical range part for sub-verses — not needed.
