# Agent harness: the improvement loop

**English** | [Русский](AGENT-HARNESS.ru.md)

The "harness" is everything that shapes how a coding agent works on
this repository: the rules in `AGENTS.md`, persistent memory, skills,
check scripts, the docs-first protocol. This document defines the loop
that makes changes to the harness evidence-driven instead of
anecdotal: a rule is proposed, probed, compared against the baseline,
and only then composed into the live setup.

Adapted from the recursive-harness-improvement pattern of Google
Research's Harness² (arXiv:2610.14224). This document generalizes
the frozen-skills → agent-runs → held-out-gate discipline into the
whole development loop.

## Harness components (map)

| Component | Where it lives here |
|---|---|
| System prompt | `AGENTS.md` (+ `AGENTS-ru.md`) |
| Memory / lessons | ZCode persistent memory; `docs/DECISIONS.md` |
| Skills | `.devin/skills/` |
| Tool interface | `scripts/*.ps1`, `tools/` |
| Guardrails | `crates/studybible-core/clippy.toml`, `analysis_options.yaml`, `scripts/check-agent-rules.ps1` |
| Subagents | working preference: parallel subagents on non-overlapping files, reports in ASD-STE100-style Russian |
| Tool guidance | `AGENTS.md` "Verification" |
| Plugins | none yet (no `.zcode/` directory) |

## The loop

1. **Propose.** Trigger: a [BUGS.md](BUGS.md) entry the agent could
   have caught or prevented (marked with a `harness-gap:` line), or a
   milestone retrospective. The artifact is a candidate harness edit:
   one line each for the symptom, the proposed rule/check/skill, the
   expected behavior change, and how it will be probed.
2. **Probe.** Mechanical candidates: the check runs in CI
   (`scripts/check-agent-rules.ps1`, wired into `ci.ps1`). Behavioral
   candidates: a frozen task from `evals/tasks/` runs on a clean
   branch from the card's base commit, with the candidate applied.
3. **Compare.** Contrast the runs — CI pass/fail, agent-rule
   violations, manual corrections, review remarks. No ground truth is
   required: the *difference between runs* is the signal (the same
   trick Harness² uses). Where the card has a known reference fix,
   it serves as a weak ground truth.
4. **Compose.** Adopted edits land in `AGENTS.md` / memory / a skill /
   the check script, with a DECISIONS.md entry. Rejected candidates
   are recorded too, with the reason — the rejection is the lesson.
   The harness version is the git history of those files.

## Mechanical layer

`scripts/check-agent-rules.ps1` turns AGENTS.md rules into pass/fail
(exit 1 on violation). Current rules:

| Id | Rule | Scope |
|---|---|---|
| NAV-1 | Route exits in the reading screen only via the named semantics `_popRoute`/`_stackBack`/`_hierarchyBack`: bare `maybePop`/`pushReplacement` are violations in all five reader files, `Navigator…pop(` in `reading_screen.dart` (in part files `.pop()` closes dialogs — other routes, out of scope). A `// nav:` line comment is an explicit, reviewable exemption (same house style as `// SAFETY:`). | `screens/reading_screen.dart` + 4 `reader/` part files |

Adding a rule: extend the table here and the rules list in the script
in the same commit. A rule must be born from a real `harness-gap:`
entry in BUGS.md, not from speculation.

## Eval task suite

`evals/` holds frozen task cards — real, already-solved tasks from
this repository, replayed on their original base commit; the known
reference fix gives the compare step a weak ground truth. Format,
freeze rules and the run protocol: [evals/README.md](../evals/README.md).
`scripts/run-eval.ps1` sets up the run (worktree, branch) and judges
it (ci.ps1, flutter analyze, agent-rules, the card's checks).

## Run log

One line per probe run; raw records live in `evals/results/`.

| Date | Harness variant | Task | Result | Verdict |
|---|---|---|---|---|
