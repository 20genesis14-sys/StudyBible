# 0031. Agent harness improvement loop

**English** | [Русский](0031-agent-harness-improvement-loop.ru.md)

Status: accepted (2026-10-18).

## Context

Rules for coding agents (`AGENTS.md`), memory entries and skills are
adopted after incidents: a bug slips through, a rule is written, and
nothing ever verifies that the rule changes agent behavior. The
navigation rule is a typical example — it exists because bare
`Navigator.pop` calls were written and silently swallowed by
`PopScope(canPop: false)`.

Two references show how to close that gap:

- in-repo precedent: the Strong's track (ADR 0025) freezes
  prompts/skills before measurement, collects per-run receipts and
  gates on held-out corpora;
- the general pattern: Google Research's Harness² (arXiv:2610.14224)
  improves the *harness around a fixed model* via
  Propose–Probe–Compose, using behavioral contrasts between runs
  instead of ground truth.

## Decision

1. Adopt the four-step loop — propose, probe, compare, compose — for
   all changes to the agent harness. Owner document:
   [AGENT-HARNESS.md](../AGENT-HARNESS.md).
2. [BUGS.md](../BUGS.md) entries the agent could have caught or
   prevented carry a `harness-gap:` line naming the missing
   rule/check/skill; it is the feed for step 1.
3. Mechanical layer: `scripts/check-agent-rules.ps1` runs as a
   `ci.ps1` step. First rule NAV-1: reading-screen route exits only
   via `_popRoute`/`_stackBack`/`_hierarchyBack` — bare
   `maybePop`/`pushReplacement` are violations in all five reader
   files, `Navigator…pop(` in `reading_screen.dart` (in part files
   `.pop()` closes dialogs — other routes, out of scope); a `// nav:`
   line comment is an explicit reviewable exemption. New rules must
   be born from `harness-gap:` entries, never speculative.
4. Behavioral layer: `evals/` frozen task cards replay real solved
   tasks on their original base commits (the known fix = weak ground
   truth); `scripts/run-eval.ps1` sets up a worktree and judges
   (ci.ps1, flutter analyze, agent-rules, the card's checks); results
   are recorded in `evals/results/`.
5. Out of scope for now: launching agents headless and automated
   proposing/judging. The probe is an interactive agent session;
   automation may follow once the manual loop proves useful.

## Consequences

- `ci.ps1` fails on navigation-contract violations in the reader.
- Three eval cards freeze replayable history: the reader empty state,
  C11 «Все вхождения», and the `.sbz` search fix — each at its base
  commit, reproducible indefinitely.
- A probe costs a real agent session; probes run on demand when a
  candidate lands, not on a schedule.
- Adopted and rejected candidates both leave traces (DECISIONS.md,
  `evals/results/`); the rejected-with-reason record is the lesson
  store for future proposals.
