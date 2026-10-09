# 0004. Coordinates instead of a single anchor

**English** | [Русский](0004-coordinates.ru.md)

Status: accepted (replaces "org verse + word range").

## Context

Versification defines the verse grid but not the word stream; word
boundaries differ between editions; alignment is many-to-many;
translations have no stable word ids.

## Decision

- verse — (versification, OSIS book, chapter, verse, optional segment);
- original word — stable token id in a named edition;
- alignment — links between ids;
- position in a translation — verse + character offset + check fragment;
- non-verse content — element id.

A user record stores the module id and version, the pointer type, and
always the verse coordinate.
On module update: id map → re-anchoring by fragment → fallback to the
verse.

## Consequences

Notes survive module updates; linguistics does not depend on translation
markup.
