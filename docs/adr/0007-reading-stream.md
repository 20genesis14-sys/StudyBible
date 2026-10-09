# 0007. Reading stream in the module format

**English** | [Русский](0007-reading-stream.ru.md)

Status: accepted.

## Context

Without paragraphs, poetry and character styles a module does not
preserve USFM, and reading turns into a flat verse feed.

## Decision

A chapter is a sequence of blocks (paragraph, poetry with levels, section
heading) and inline spans (verse marker, added words, words of Jesus,
God's name, footnote callout, reference). The listed USFM subset survives
a round-trip conversion. The markup layer is separate from the token
layer. Format freeze in 1.0 = no breaking existing fields; new — only
optional tables.

## Consequences

The converter is verified by a round-trip test USFM → module → USFM.
