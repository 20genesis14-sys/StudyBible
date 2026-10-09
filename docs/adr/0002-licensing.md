# 0002. Code MIT OR Apache-2.0, texts separate

**English** | [Русский](0002-licensing.ru.md)

Status: accepted.

## Context

Closed modules and third-party plugins are needed. We do not perform a
legal review of texts.

## Decision

Code — MIT OR Apache-2.0, copyright holder "StudyBible contributors".
Texts are distributed separately from the engine; a module carries its
own license and attribution in metadata, and the app shows them.
Dependency licenses are checked by `cargo deny` (`deny.toml`, copyleft
does not pass). There is no GPL in our code.
`unsafe` is allowed when justified, with a `// SAFETY:` comment.

## Consequences

GPL components (e.g. espeak-ng) — only separate from the core, optional.
Source texts and built modules are not committed to git: a separate
`STUDYBIBLE_DATA` directory, so that publishing the repository does not
publish translations.
