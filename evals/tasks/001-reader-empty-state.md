- Id: 001-reader-empty-state
- Version: 1 (2026-10-18)
- Class: flutter-bugfix
- Base: 1004ff7f0e9f1bf912e54a8b22add22664bb9876
- Reference: 22acce2

## Setup

Worktree from Base (run-eval.ps1 -Setup); `STUDYBIBLE_DATA` is set
machine-wide; to see the states by hand, run the app and open a book
absent from the installed module.

## Task

The reading screen still shows the prototype-era placeholder
«Эта глава не выгружена в прототип» where a chapter is missing, and
shows nothing at all while a chapter is loading. Make the reader
honest about both states: a loading indicator while the chapter
loads, and a proper empty-state message — with a hint about what to
do — when the book or chapter does not exist in the module.

## Checks

- [ ] The prototype placeholder is gone —
  `git grep -n "выгружена в прототип" -- apps/studybible-flutter/lib` → exit != 0
- [ ] A loading state renders while a chapter is loading (manual)
- [ ] An empty-state message with a hint for an absent book/chapter
  (manual)
