# #440 — Validating the narrowed `--mode=codebase` prompt

Measured 2026-08-27. Raw data: `RESULTS.json`, `results/<variant>/*.json`.

## Answer

**Do not adopt the narrowing as specified. Keep the unscoped prompt.**

The design doc's decision rule was: *"A narrowing that loses most of the 38 is
worse than the unscoped prompt it replaces. High re-find rate -> adopt. Low
re-find rate -> keep the unscoped prompt."*

The narrowing does not lose most of the corpus. It also does not beat the
incumbent: 27 vs 29 of 47, a gap of two members that the data cannot
distinguish from noise. Absent a demonstrated gain, the change does not earn
itself — but the reason is *not* that the narrowing failed. It is that the
narrowing trades one set of classes for another at roughly par. See
[What the narrowing actually did](#what-the-narrowing-actually-did), which is
the more useful result than the headline.

## Results

| Variant  | Re-find | Findings emitted |
|----------|---------|------------------|
| baseline (production, unnarrowed) | **29/47 (62%)** | 168 |
| narrowed | **27/47 (57%)** | 158 |
| control (deliberately blind) | **1/47 (2%)** | 2 |

The control is the reason the other two numbers mean anything. A prompt told
to look only at indentation finds 1 of 47 — so the harness does not
manufacture hits, and a 57-62% result is real signal rather than an artifact
of generous scoring.

### The two prompts are statistically indistinguishable

| | count | classes |
|---|---|---|
| both | 22 | — |
| only narrowed | 5 | 3 bypassable-guard, 1 resource-leak, 1 silent-failure |
| only baseline | 7 | 4 silent-failure, 2 injection, 1 other |
| neither | 13 | 10 silent-failure, 2 resource-leak, 1 bypassable |

**McNemar exact test on the discordant pairs (7 vs 5): p = 0.774.** The
difference is not significant at n=47. I cannot claim baseline is better; I
can only claim the narrowing shows no measurable benefit, which is what the
decision needs.

Run-to-run variance is roughly +/- 1-2 members: a five-member replication
reproduced 4 of 5 misses and flipped one, and `claude-config#131` moved from
baseline-only to neither between runs. Treat the headline numbers as 57% +/- 4
and 62% +/- 4, not as exact values. A two-member gap is inside that band.

### What the narrowing actually did

This is the real finding, and it is invisible in the headline. The narrowing
**worked on the classes it targeted** and **lost ground everywhere else**:

| Category | narrowed | baseline | corpus |
|---|---|---|---|
| bypassable-guard | **6/7 (85%)** | 3/7 (42%) | 7 |
| resource-leak | **4/6 (66%)** | 3/6 (50%) | 6 |
| silent-failure-guard | 14/28 (50%) | **17/28 (60%)** | 28 |
| injection-old-shell | 3/5 (60%) | **5/5 (100%)** | 5 |
| other | 0/1 | **1/1** | 1 |

By language the split is just as sharp:

| | narrowed | baseline |
|---|---|---|
| shell | **24/37 (65%)** | 22/37 (59%) |
| non-shell | 3/10 (30%) | **7/10 (70%)** |

So the narrowing is a genuine trade, not a failure. It doubles the
bypassable-guard rate — the class with the largest blast radius, since a
bypassable guard means an enforcement layer silently does nothing — and it
beats baseline on shell, where 79% of the corpus lives. It pays for that by
dropping injection findings from 5/5 to 3/5 and halving non-shell coverage.

Two things keep it from being adopted anyway:

1. **The largest class did not improve.** Silent-failure guards are 28 of 47
   members (60% of the corpus). The narrowing names the class explicitly and
   gives it five concrete shapes, and still finds *fewer* than the unscoped
   prompt (14 vs 17). Naming the class did not help the reviewer find it.

2. **Losing injection 5/5 -> 3/5 is a bad trade at any scale.** Command
   injection in shell is the highest-severity class in the corpus, and the
   incumbent catches all of it.

### It does not reduce noise either

158 findings vs 168 — a 6% difference, inside the noise. Part of the
narrowing's rationale was cutting output volume. It does not. It changes
*what* is reported without changing *how much*.

## Why the ceiling is not prompt-shaped

The 13 that *neither* variant finds are the informative group: 10 of them are
silent-failure guards, the class the narrowing names most explicitly and with
the most concrete examples. Both prompts read the whole file, and both are told
to hunt defects.

Reading a 1200-line shell script and noticing that one guard reports success
when its dependency is absent is a hard reasoning task, not a matter of being
told to look. No amount of prompt instruction closed that gap.

## Recommendations

1. **Keep the unscoped prompt.** Close #440 with this measurement. The
   narrowing as specified is not adopted.

2. **Do not treat 62% as the mode's coverage.** That is its rate on whole files
   handed to it directly, with a known defect present. It is an optimistic
   upper bound for a real sweep, which must also decide *which* files to read.

3. **The union is 34/47 (72%) against an overlap of only 22.** Each prompt
   finds members the other misses, and the complementarity is categorical
   rather than random — narrowed owns bypassable guards, baseline owns
   injection. If coverage matters more than cost for a weekly sweep, running
   both hunt lists is measurably better than either alone. Worth testing before
   #441 settles on one prompt.

4. **Consider narrowing by file, not by instruction.** The reviewer is good at
   bypassable guards (85% under the right prompt) and mediocre at
   silent-failure guards (50-60% under either). A sweep that prioritises
   enforcement/guard code — highest hit rate, largest blast radius — would use
   the reviewer where it is strong. This is the most promising direction the
   measurement surfaced.

## Caveats, stated rather than smoothed

- **n=47, single run per variant** (plus one 5-member replication). The
  headline gap is not significant. Do not read 57 vs 62 as a ranking.
- **One baseline run was initially scored as a phantom hit.** `claude-wrapper#96`
  errored (empty CLI output), left only a `.err` sidecar, and was recorded as a
  baseline-only FOUND with no underlying data — reporting baseline as 30/47. It
  was re-run on 2026-08-27 against the identical pre-fix prompt and is a MISS.
  Baseline is 29/47. This is why the harness now excludes errored runs from the
  denominator rather than scoring them.
- **The prompt files were edited after measurement.** Both variants contained a
  dangling literal `${DIFF_TMPFILE}` reference (a harness artifact — the
  reviewer was pointed at a diff file that does not exist in this setup). It was
  removed from `prompt-baseline-step4.txt` and `prompt-narrowed.txt` after the
  runs completed, and **the measurement was not re-run against the corrected
  text.** The defect was identical in both variants, so it biased them equally
  and does not affect the comparison; both still returned findings on 42/47 and
  41/47 runs respectively. But the absolute rates were measured under the
  flawed text. The `claude-wrapper#96` re-run above deliberately used the
  restored pre-fix prompt to stay comparable with the other 46.
- **Scoring is location-based**, +/- 25 lines on the right file. A finding that
  describes the right defect but names a distant line scores as a miss. Spot
  checks did not show this to be common, but it was not exhaustively audited.
- **Pooled scoring.** Several members share an identical recovered file
  (#126, #127, #131 all live in run-review.sh at 789d77ae). Per-member scoring
  credited only the member indexed to that run and called the rest misses.
  Pooled scoring credits any corpus defect found in the file under review.
- **This measures a different task than production.** `--mode=codebase` is
  diff-seeded (`DIFF=$(cat)` at run-review.sh:1438, fed `git diff main...HEAD`).
  The harness hands the reviewer a bare file with no diff. That is the
  *weekly-sweep* shape, which is what #441 needs — but it is not what the
  mode does today. See `FINDINGS-methodology.md`.
- **The corpus is 47, not 38.** Rebuilt from 13 repos and 582 candidates
  because the original per-finding list was never written down. Two of the
  design doc's fifteen named examples (`scripts#45`, `dotfiles#205`) are not
  defects; both are documented in `REBUILD.md`.
