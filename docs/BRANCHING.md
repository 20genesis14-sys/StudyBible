# Working with branches — cheat sheet

**English** | [Русский](BRANCHING.ru.md)

Two permanent branches + temporary feature branches + feature flags for
long work.

```
main ────●─────────────●───   releases + tags only (v1.0.1, v1.1…)
          \           ↑
dev  ──────●──●──●──●─┘       all current work
              ↑    ↑
feature/… ───┘    └── short branches per task (days, not months)
```

## Rules

- **main** — only verified code. Merged from `dev` at release + tag `vX.Y.Z`.
- **dev** — the working branch: fixes, features, 1.0.x/1.1.
- **feature/…** or **fix/…** — a room for one task. Dies after merge.
- **hotfix** — a branch off `main`, merged into `main` AND `dev` (so it is
  not lost).
- No permanent "experimental": long work lands in `dev` in pieces behind
  a flag.

## Commands by heart

```powershell
git switch dev                       # stand on the working branch
git switch -c feature/task-name      # create a room
# …code, commits…
git switch dev && git merge feature/task-name   # merge it
git branch -d feature/task-name      # tear down the room
```

Release:
```powershell
git switch main && git merge dev
git tag -a vX.Y.Z -m 'Release X.Y.Z' && git push --tags
```

## Feature flag = "a switch in code"

```dart
const bool kColumnCompareEnabled = false;   // unfinished is hidden
if (kColumnCompareEnabled) { /* button/screen */ }
```

Lets you merge big work into `dev` in pieces — the code is there,
the user does not see it. Ready → `false` becomes `true`.
After stabilization the `if` and dead code are removed (the flag is
temporary).

## What goes where

| Task | Where |
|---|---|
| Fix, text, button | straight into `dev` |
| Days of work / risk | `feature/…` |
| Weeks+ (format v2, studybible-text) | `feature/…` in pieces + flag in `dev` |
| Urgent bug in a released version | `hotfix/…` off `main` |
