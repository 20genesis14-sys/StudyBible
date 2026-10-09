# 0003. Module = untrusted SQLite, FTS in cache

**English** | [Русский](0003-sqlite-module-fts-cache.ru.md)

Status: accepted.

## Context

An FTS index inside the module freezes the tokenizer together with the
format, and the text can be recovered from the index. Modules come from
untrusted sources.

## Decision

A module is our own SQLite format: text, markup, tokens, metadata; no
index inside. FTS5 lives in a local cache; the key is the module content
hash + tokenizer version.
A module is opened read-only, with `SQLITE_DBCONFIG_DEFENSIVE`,
`trusted_schema=OFF`, and a schema/format-version check.

## Consequences

The tokenizer and normalization can change after 1.0 without reissuing
modules.
