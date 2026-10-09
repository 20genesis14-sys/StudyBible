# 0010. Voice and accessibility

**English** | [Русский](0010-voice-accessibility.ru.md)

Status: accepted.

## Context

Accessibility bolted on afterwards requires reworking the text widget.
Users want to listen to the text.

## Decision

Screen-reader support is a requirement for the very first text widget
(Alpha 1) and a UI selection criterion: a verse is a node with number
and language, keyboard navigation.
Read-aloud — Russian and English only, through the "Speech" port and
system synthesizers (`tts` crate, MIT); third-party voices — via the OS.
The core prepares the text: what to read, numbers and references as
words, stress marks, per-verse fragments. Ancient languages are not
voiced.
After 1.0 — offline neural synthesis as a separate component and audio
Bibles.

## Consequences

In the MVP — console voicing to verify text preparation: `say`
(interrupting the current), `speaking`, `stop` and `speakable()`.
Pauses, speeds, voices, fragment events and reading numbers as words are
not in this port yet.
