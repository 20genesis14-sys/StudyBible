# ADR 0028: rusb-strongs — consensus arbitration between Aquifer reseat and russyn

## Status

Accepted (2026-10-16).

## Context

ADR 0027 shipped a reseated Aquifer layer at 96.4–96.6 % agreement with
`russyn-strongs` on identical verses. Raising accuracy toward 99 %
required understanding the remaining ~6,300 disjoint positions.
Diagnostic (`(claimed_hit, aquifer_how, russyn_support)`):

- ~2,000 disjoints were **russyn errors fixed by Aquifer**
  (`стал`→H1961 not H0216; `Бог`→H0430G; `не`→H3808) — agreement with
  the baseline understates layer accuracy.
- ~2,300 were `lex/lex` ambiguity — both sides lexically plausible.
- ~800 were positions where the reseat had kept Aquifer's original
  (corrupt) claim.

Monotonic-DP assignment (94.95 %), full `corpus-ru` form priors (92.7 %,
noisy tails) and bootstrap self-training (−3.7 п.п.) were all tried and
**rejected** — recorded here so they are not retried.

## Decision

`adjudicate_rusb.py` builds the deployed layer as a **consensus** of the
two independent alignments on identical verses (92 % of all verses;
token-for-token identical after `norm_ru`):

- agree/intersect → union of dStrong codes, `conf 10`, `consensus`;
- disjoint → **arbitration** picks one side by weighted evidence:
  prior support (lex/stem/none), POS compatibility between the code's
  `lex.pos` class and a Russian POS guess (aux list, verb/adjective
  suffix heuristics), `FUNC_RU_TO_CODES` agreement, a small penalty for
  "Aquifer's claim kept un-moved", prior-frequency tie-break.
  Outcome: A wins 2,948 / R wins 1,754 / TIE 1,005 (TIE → A's dStrong,
  which is always a real source mid of the verse, `conf 8`).
- only-russyn → `russyn-fill` (conf min(russyn_conf, 9));
  only-Aquifer → `aq-only` (conf by how);
- non-identical verses → pure reseated Aquifer.

Two stem-match guards were added: **aux words never stem-match**
(`пред` collided with `предал`→H5414).

Result: 543,114 links (union+fill coverage ≈ russyn), agreement vs
russyn on identical verses **99.25 %**; the residual 3,953 disjoints are
positions where the layer deliberately takes the Aquifer/TIE side —
manual spot-checks show most of them correct russyn errors.

## Consequences

- The deployed `rusb-strongs.sbz` is a hybrid layer, not a pure Aquifer
  derivative; `source='consensus'`, flags record the decision class
  (`consensus`/`arb-a`/`arb-r`/`arb-tie`/`russyn-fill`/`aq-only`).
- Manual review of ~70 arbitrated cases estimates arbiter precision
  ≈ 90 % on conflicts → layer accuracy ≈ 99 % against an independent
  estimate, not merely against russyn.
- Known limit: TIE rows are coin flips between two real verse codes —
  they stay conf 8 and are the first candidates for `strongs-review`
  pass.
- `corpus-ru` is still not fed: an `rusb`/`russyn` edition label is a
  prerequisite.
