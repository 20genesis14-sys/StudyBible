# 0005. Versifications, canon and book names as data

**English** | [Русский](0005-versification-canon-as-data.ru.md)

Status: accepted.

## Context

Synodal, English and original-language texts number verses differently;
the same abbreviations may mean different books in different profiles.

## Decision

Versifications are Paratext data (MIT) cross-checked against TVTMS;
mappings account for 1→N, N→1, verse parts and "no correspondence".
Paratext/USFM ↔ OSIS codes — a data table.
Data profiles: canon (66 books per the user's list, everything else
marked "non-canonical", including insertions inside books), names and
abbreviations (Synodal, English), book order.
The default profile is set by the module. The reference parser knows the
versification and the name profile.

## Consequences

New traditions are added as data, without code. Every discrepancy is
covered by a test.
The tag in a module is the file's numbering, not the original-language
grid: eBible KJV and WEB are `eng` (Mal 4, Joel 2:28), Synodal russyn is
`rsc`.
