# evals — frozen task cards for harness probes

Part of the agent-harness improvement loop
([docs/AGENT-HARNESS.md](../docs/AGENT-HARNESS.md), ADR 0031).

A card is a real, already-solved task from this repository, replayed
on its original base commit. The known reference fix serves as a weak
ground truth for the compare step: a probe run does not have to
reproduce it line-for-line, but its checks must pass, and the review
compares behavior, not diffs.

## Layout

- `tasks/` — frozen cards;
- `results/` — run records, one file per probe run.

## Card format

```
- Id: <kebab-id>
- Version: <n> (<date>)
- Class: flutter-bugfix | docs-first-feature | rust-core
- Base: <commit sha>       # the probe branch starts here
- Reference: <commit sha>  # the historical fix (weak ground truth)

## Setup
(what the agent needs before starting)

## Task
(the requirement, as a bug report / feature request — no fix hints)

## Checks
- [ ] <description> — `<command>` → <expectation>
- [ ] <manual item>
```

Card commands run from the worktree root; they are repo-owned and
frozen (trusted input for `scripts/run-eval.ps1`). Expectations:
`exit 0`, `exit != 0`. The standing judge steps — ci.ps1,
flutter analyze, check-agent-rules.ps1 — are run by `run-eval.ps1`
itself and are not repeated in cards.

## Freeze rule

Task text, base commit and checks are frozen. Any change bumps
`Version` with the date — the same discipline as the Strong's
rules-hash (`docs/strongs/HANDOFF.md` §6). Never compare runs across
card versions.

## Running a probe

```
# 1. setup: worktree + branch from the card's Base
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run-eval.ps1 `
  -Task evals\tasks\001-reader-empty-state.md -Label baseline -Setup

# 2. the agent session: open the worktree folder in the agent, give it
#    the Task section of the card, let it work (with the candidate
#    harness variant applied for labels other than "baseline")

# 3. judge: standing checks + card checks + result record
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run-eval.ps1 `
  -Task evals\tasks\001-reader-empty-state.md -Label baseline -Judge
```

`baseline` is the harness as it is on `dev` at probe time; any other
label is the harness with the proposed edit applied. Compare runs
through the records in `results/` (AGENT-HARNESS.md, step 3).
