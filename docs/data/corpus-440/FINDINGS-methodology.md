# Methodology findings — #440 / #441

Recorded 2026-08-27 while preparing the #440 measurement.

## 1. Every corpus finding is already fixed

All named known-lost findings are CLOSED. The current files are clean, so
running any prompt against today's HEAD measures nothing: a 0% re-find rate
would be the *correct* result and would read as catastrophic prompt failure.

The measurement must run against historical buggy file versions.

## 2. Anchor on the filing date, not the fixing commit

Tested on claude-config#166 (filed 2026-05-20, fixed 2026-07-29 in
f21ceb15). Line 705 in the fix's parent is unrelated code — the file drifted
over the two months between filing and fix.

Anchoring on the filing date recovers 80deb566, whose run-review.sh:705 is
exactly the described bug:

    if ! echo "${DIFF}" | grep -qE '^[+-][^+-]'; then

Method:

    c=$(git -C <repo> rev-list -1 --before="<issue createdAt>" main)
    git -C <repo> show "$c":<path>

Some issues close with `commit_id: null` (closed by hand), so the fixing
commit is not even available in those cases. The filing date always is.

## 3. `--mode=codebase` is diff-seeded, not a whole-repo scan

This contradicts the name and affects both open issues.

`run-review.sh:1438` reads `DIFF=$(cat)`; callers pipe `git diff main...HEAD`
(confirmed at :1627). Codebase mode reads that branch diff, then uses
Read/Grep/Glob to view **whole files touched by the diff** and follow
references one level out.

So the mode's actual coverage claim is narrower than "whole codebase": it
reads whole files, but only files the branch diff touched. A pre-existing
defect in an untouched file was never in scope.

### Consequences

- **For #440.** The corpus findings were surfaced *because a branch diff
  touched their file*. A measurement that hands the reviewer a bare file with
  no diff tests a different task than the one that originally found them. The
  measurement should reproduce the diff-seeded shape, or state plainly that
  it is measuring a different (weekly-sweep-shaped) invocation.
- **For #441.** A weekly fleet-wide sweep has no branch diff to seed from.
  It cannot reuse this code path as-is. Either it synthesises a seed (e.g.
  recently-changed files), or it needs a genuine whole-repo mode that does
  not exist yet. The design doc treats the sweep as a cadence change; it is
  also a capability change.

## 4. The current prompt hunts the wrong classes for this fleet

`CODEBASE_PROMPT` step 4 lists six patterns to look for: field/contract
violations, data-flow bugs, date/timezone inconsistencies, dead UI elements,
cache-key mismatches, platform iOS/Android/web divergence.

Those are application-code patterns. But 64% of genuine findings are shell,
and the largest lost class — silent-failure / false-OK guards — is not in
that list at all.

The narrowing in the design doc is therefore not only a scope reduction. It
corrects a mismatch between what the prompt is told to hunt and what this
fleet actually contains.

## 5. Auto-formatting hooks silently corrupted the corpus

Found while committing. The repo's shared pre-commit hooks reformat staged
source in place: `shfmt` (via `lint-shell.sh`) and `prettier`. On the first
commit attempt they rewrote six recovered corpus files.

That is not cosmetic here. The corpus indexes each defect **by line number**,
so reformatting shifts the line the evidence points at and the measurement
silently scores against the wrong line. The evidence round-trip dropped from
47/47 to 41/47 without any error being raised — the hooks reported success.

This is the same false-OK shape the corpus catalogues, arriving from the
tooling rather than the code under review.

Two consequences, both applied:

- The recovered files are stored as `files.tar.gz`, not as loose files. An
  archive is opaque to a formatter that selects work by file type. Unpack with
  `./unpack-corpus.sh`, which re-validates all 47 members on the way out and
  exits non-zero if any evidence no longer matches.
- `.prettierignore` and `.flake8` exclude the corpus directory, so the JSON
  result files and the recovered source are left alone.

A repo that stores code-as-data alongside code-as-source needs this
separation. Anything that must keep byte-exact line numbers cannot live where
an auto-formatter can reach it.
