# 0012. UI is chosen by a pilot screen

**English** | [Русский](0012-ui-by-pilot-screen.ru.md)

Status: accepted, choice not made (superseded by ADR 0013).

## Context

Candidates — Slint and Flutter. Slint has a license question for plugins
and an AccessKit risk without rich text; Flutter is heavier and adds a
second language.

## Decision

The choice is made by a pilot screen: a chapter with paragraphs, poetry,
a heading, a footnote and words of Jesus; mouse and keyboard selection;
mixed Hebrew and Russian; word tap; a virtualized book; two panes with
synchronized scrolling; a screen reader; OS font scale.
Criteria: measurable requirements, accessibility, bidi, localization,
license.
A letter to SixtyFPS — later, if Slint remains a candidate.

## Consequences

Until the choice is made, plugins do not draw their own UI.
