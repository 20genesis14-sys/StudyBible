# 0008. User data on device only

**English** | [Русский](0008-user-data-local.ru.md)

Status: accepted.

## Context

Notes are the user's personal data. The project has no server and none is
planned.

## Decision

Data is stored on the device only, no telemetry. Transfer — zip export
and import: JSON is the source of truth with a schema version, Markdown
is export-only. A record has uuid, updated_at, device_id, revision
number; deletion is a tombstone; ties are deterministic; a note-edit
conflict keeps both versions. After 1.0 — sync through a folder chosen
by the user.

## Consequences

No separate server-side personal-data processing needed.

## Addendum 2026-10-08 (question № 12, stage B)

Userdata schema raised to 2: a record has `vrs` (module versification at
the time of writing), `module_ver` (`meta.content_hash`, else `version`)
and a filled `context` (up to 40 chars of verse text). Migration 1→2 is
`ALTER TABLE`; `version: "1"` exports are accepted. `UserData::relink`
re-anchors records to updated modules by context (anchor verse, then
±2); a move — with `rev+1`, a mismatch — an orphan in the report, the
record untouched. Cross-translation records (stage A: canonical
coordinate in `org`) postponed until feedback on stage B.

## Addendum 2026-10-08 (question № 12, stage A)

Schema 3: canonical org range (`canon_book`, `canon_c1`, `canon_v1`,
`canon_c2`, `canon_v2`) — verse splits and merges in one form; edge
points `to_org(anchor)`, filled by migration and relink. Display (user
decision): in text — only own records; foreign ones — a "Records in
other translations" button in the own note window and only for installed
modules (uninstalled — only in the "Records" tab); tapping a foreign
record — navigates to its verse in its translation + the record window;
the "Records" tab groups by `module`. One mechanism for
notes/bookmarks/highlights; "foreign" = different `meta.id`.
