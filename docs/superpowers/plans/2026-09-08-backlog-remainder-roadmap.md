# Backlog Remainder: Roadmap and Housekeeping Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the status record back in line with live state, close the last
open migration task (the login alias), and fix the execution order for
everything that remains in the infrastructure backlog.

**Architecture:** Tasks 1–4 are small, fully specified, and executable now.
Section "Roadmap" sequences the rest of the backlog; each stage there gets its
own plan document when it starts, because W1 in particular needs a design pass
before its tasks can be written without placeholders.

**Tech Stack:** Markdown, bash 5, `gh`, the hermetic stub-`gh` test suite under
`scripts/org-migration/tests/`, dotfiles' `bash/tests/run-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md`
(the backlog) and `docs/superpowers/specs/2026-09-03-org-migration-design.md`
(Steps 6–7, Task 12 of its plan).

## Global Constraints

- Never commit on `main`; branch as `claude/<type>-<desc>-<session>`.
- `shellcheck -S info` clean on every shell file touched; no `# shellcheck disable`.
- Every behavior change has a test that was observed failing before the fix.
- Re-measure before acting on any number in a status document.
- Text files end with a newline.

## Decisions recorded 2026-09-08 (Andrew)

These answer the four questions in `smartwatermelon/github-workflows#154` and
the two open follow-ups from W0. They are inputs to the roadmap below.

| Question | Decision |
| --- | --- |
| #154 Q1+Q2: keep a judgment reviewer in CI? | **Remove entirely.** Local hooks are the only judgment pass. No advisory CI reviewer. |
| #154 Q3: `claude-assistant.yml` | Out of scope, keeps its token (as the issue states). |
| #154 Q4: `nightowl-restore-blocking-review.sh` | **Retire with W3**, same PR. |
| dev-env#89: which workflow-less repos get a review gate? | **`smartwatermelon/.github` only.** `claude-config-backup`, `superpowers`, `superpowers-marketplace` stay ungated; record that in #89 and close it when `.github` is done. |
| dev-env#85: `scripts` public | **Audit only, then ask.** Run the history scan and report; the rewrite and the visibility flip each need a separate yes. |

## Live state measured 2026-09-08

| Claim | Evidence |
| --- | --- |
| Runbook Part D done on TILSIT | `env -u GH_TOKEN gh api user --jq .login` over SSH → `twistedmelonman`; dotfiles at `37f9b6f` |
| Runbook Part D done on MIMOLETTE | same login; dotfiles was at `2ab0959` (2026-08-20), fast-forwarded to `37f9b6f` this session; missing `~/.config/git/hooks/lib-symlink-exclusions.sh` symlink added |
| Task 12 gate ("section D ran on all three machines") | **satisfied** |
| Migration Tasks 10, 11 done | org secret `CLAUDE_CODE_OAUTH_TOKEN` visibility `ALL`; `ralph-burndown` secret list empty; `claude-code-login` and `smartwatermelon.github.io` return 404; #85 filed; #54 CLOSED |
| Task 13 Step 3 not done | migration spec line 3 still reads `APPROVED IN CHAT 2026-09-03` |
| L1 done | `dotfiles/.git/config` carries no `uchg` flag; `core.hooksPath` = `~/.config/git/hooks`; starter-set Task 4 |
| N1a done | `~/.nvm/alias/default` = `lts/krypton`; `which node` → v24.19.0; `claude-code-workflows-agents#16` merged |
| F3 done | `dotfiles#302` MERGED (fail closed when `GH_TOKEN` overrides the resolved identity) |
| Support ticket 4729524 | closed by GitHub 2026-09-04 as self-service-only; reopened same day after the Team upgrade; status ping sent 2026-09-08. No staff reply. Assume denial. |
| Task 11 Step 5 loop flags `claude-config`, `huddle-transcribe` | both are retired paths; `twistedmelonman` is their correct remote. The move-list still says `smartwatermelon`, so the loop and `verify.sh` treat them as drift. |

---

### Task 1: Record the five retired paths in the move-list

**Files:**

- Modify: `scripts/org-migration/move-list.txt`
- Test: `scripts/org-migration/tests/run-tests.sh` (existing suite; no new test — the file is data, and the parser rejects malformed rows)

**Interfaces:**

- Consumes: `om_read_move_list` in `scripts/org-migration/lib.sh:13-25` — a row is `repo<TAB>target`; `#` lines are comments.
- Produces: a move-list whose target column is the *actual* end state for every repo, so `verify.sh` and the Task 11 Step 5 repoint loop stop reporting the retired five as drift.

- [ ] **Step 1: Edit the header comment and the five rows**

Replace the header comment block (lines 1–6) with:

```text
# repo<TAB>target-org — reviewed by hand in the PR that added it.
# Source of truth for transfer.sh; never derived at run time.
# Rows are alphabetical; order carries no meaning. github-workflows is
# transferred first and alone via `transfer.sh --only github-workflows`
# (design Step 3).
# cleanroom is the one repo that targets nightowlstudiollc.
# Five repos target twistedmelonman: their smartwatermelon/<name> paths are
# permanently retired by GitHub (popular-repository namespace retirement,
# HTTP 422 on transfer and on create). They stay on the user account with
# working redirects. Support ticket 4729524; assume denial. See
# docs/STATUS.md "Deferred by decision".
```

Change these five rows so the target reads `twistedmelonman` (keep the TAB):

```text
claude-config twistedmelonman
dotfiles twistedmelonman
huddle-transcribe twistedmelonman
personify twistedmelonman
projectinsomnia twistedmelonman
```

- [ ] **Step 2: Run the org-migration suite**

Run: `bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/run-tests.sh`
Expected: all 38 tests pass (the suite uses its own fixture lists; this confirms nothing depends on the real file's contents).

- [ ] **Step 3: Confirm the repoint loop no longer flags the two clones**

Run the read-only form of the Task 11 Step 5 loop:

```bash
for d in "${HOME}"/Developer/*/.git; do
  dir="${d%/.git}"
  url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
  [[ "${url}" =~ github\.com[:/]twistedmelonman/ ]] || continue
  repo="${url##*/}"; repo="${repo%.git}"
  grep -qE "^${repo}[[:space:]]+smartwatermelon$" \
    /Users/andrewrich/Developer/dev-env/scripts/org-migration/move-list.txt \
    && echo "DRIFT: ${dir##*/} ${url}"
done
```

Expected: no output. (Before the edit it printed `claude-config` and `huddle-transcribe`.)

- [ ] **Step 4: Commit**

```bash
git -C /Users/andrewrich/Developer/dev-env add scripts/org-migration/move-list.txt
git -C /Users/andrewrich/Developer/dev-env commit -m "chore(org-migration): record the five retired paths as staying on twistedmelonman"
```

---

### Task 2: Migration spec status line (Task 13 Step 3, never done)

**Files:**

- Modify: `docs/superpowers/specs/2026-09-03-org-migration-design.md:3-6`

- [ ] **Step 1: Replace the status paragraph**

Replace lines 3–6 with:

```markdown
Status: EXECUTED 2026-09-04 as a rename-then-reclaim. 25 of 30 repos
transferred; five paths permanently retired (see `docs/STATUS.md`). Findings
and deviations are in dev-env#54's closing comment and dev-env#84. Executes
items I3 and F4 of `2026-09-01-infrastructure-backlog-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git -C /Users/andrewrich/Developer/dev-env add docs/superpowers/specs/2026-09-03-org-migration-design.md
git -C /Users/andrewrich/Developer/dev-env commit -m "docs(org-migration): mark the spec executed"
```

---

### Task 3: Refresh `docs/STATUS.md`

**Files:**

- Modify: `docs/STATUS.md`

- [ ] **Step 1: Update the header date**

Line 3: `**As of 2026-09-05.**` → `**As of 2026-09-08.**`

- [ ] **Step 2: Update the layer table**

Replace the table rows under "Where the project is" with:

```markdown
| Layer | State |
| --- | --- |
| Foundation (F) | F1, F3, F4 done. F2 open (latent hazard, not urgent). |
| Identity / billing (I) | I3 done. I0, I1, I2 open. |
| Fleet (W) | W0 done. W1, W2, W3 open — **critical path**. Design decisions taken 2026-09-08. |
| Local review (L) | L1 done. L2, L3, L4, L5 open. |
| Runtime EOL (N) | N1a done. N1b (product repos) open. |
```

- [ ] **Step 3: Add the three done items under "Done"**

Append after the W0 subsection (before "## Open work, in priority order"):

```markdown
### Starter set — L1, N1a, F3 (2026-09-02/03)

Executed per `docs/superpowers/plans/2026-09-02-infrastructure-backlog-starter-set.md`
and previously unrecorded here:

- **L1 — dotfiles config contamination.** Remediation (`git-env-isolation.sh`,
  9 fixture tests, a known-bad control) had already landed; the starter set
  removed the `uchg` tripwire on `dotfiles/.git/config`. Verified 2026-09-08:
  no flag, `core.hooksPath` intact. Follow-up `dotfiles#304` records why the
  flag is intentionally absent.
- **N1a — local nvm default and infra-repo CI pins.** `~/.nvm/alias/default`
  is `lts/krypton` (v24.19.0). `claude-code-workflows-agents#16` merged.
- **F3 — `GH_TOKEN` precedence guard, cheap tier.** `dotfiles#302` merged:
  the wrapper fails closed when `GH_TOKEN` resolves to a login other than the
  one the repo owner maps to. Follow-up `dotfiles#303` (cache the lookup).

### Migration cleanup (Steps 5–7) and the other two machines

Org secret set (visibility `ALL`), `ralph-burndown` secret removed,
`claude-code-login` and `smartwatermelon.github.io` deleted, #85 filed, #54
closed. Runbook Part D verified on TILSIT and MIMOLETTE 2026-09-08 (both
authenticate as `twistedmelonman`); MIMOLETTE's dotfiles clone was 15 commits
behind and was fast-forwarded. The temporary login alias is now removable
(migration plan Task 12).
```

- [ ] **Step 4: Rewrite "Open work, in priority order"**

Replace the whole section body (from `### Blocking nothing, but on the critical path` through the end of `### Filed this session`) with:

```markdown
### Critical path: W1 → W2 → W3

Decisions taken 2026-09-08 (Andrew) that unblock W1 — see
`docs/superpowers/plans/2026-09-08-backlog-remainder-roadmap.md`:

- **No judgment reviewer stays in CI.** `standards-check.yml` replaces
  `claude-blocking-review.yml` outright; local hooks are the only judgment
  pass. `claude-assistant.yml` is out of scope and keeps its token.
- **`nightowl-restore-blocking-review.sh` is retired with W3.**

W2 pilots, re-picked from repos with no enforcement today: `repo-template`,
`pr-review`, `claude-code-workflows-agents`, `nightowlstudiollc/.github`.
`scripts` is not a pilot (see #85).

### Runs in parallel with W

- **I0** — `CLAUDE_CONFIG_DIR` billing-verification script. Deliverable is a
  script Andrew runs on the company machine.
- **F2** — owner-aware `git-identity.sh`. Latent hazard only; do after I0.
- **N1b** — product-repo Node bumps (`tensegrity`, `kebab-tax`,
  `Gmail-MCP-Server`, `reliquarist`). Confirm each job reaches its Node
  step before and after.
- **L2 → L3, L4, L5** — deploy/edit separation, the false-OK pair
  (claude-config#439, #451), doc hygiene, small unfiled items.
- **#89** — add `claude-blocking-review.yml` + exemplar protection to
  `smartwatermelon/.github` only; the other three stay ungated by decision.
- **#90** — evaluate org rulesets on one test repo against a known-bad PR.
- **#85** — full-history secret audit of `scripts`, then stop and report.
- **#94** — Netlify publish verification for six sites (needs the Netlify
  dashboard as the inventory of record).

### Filed 2026-09-05

- **#84** — three conditions the org-migration design's failure table does
  not cover.
```

- [ ] **Step 5: Update "Deferred by decision"**

Replace the `Runbook Part D` row with:

```markdown
| Runbook Part D on TILSIT and MIMOLETTE | **Done 2026-09-08.** Alias removal (migration plan Task 12) is unblocked. |
```

Replace the `Five retired repo paths` row with:

```markdown
| Five retired repo paths | **Support ticket 4729524.** Closed by GitHub 2026-09-04 as self-service-only; reopened after the org's Team upgrade; status requested 2026-09-08, no staff reply. Assume denial. The move-list now records `twistedmelonman` as their end state. |
```

- [ ] **Step 6: Run markdown lint if configured, then commit**

Run: `ls /Users/andrewrich/Developer/dev-env/.markdownlint* 2>/dev/null && markdownlint /Users/andrewrich/Developer/dev-env/docs/STATUS.md || true`

```bash
git -C /Users/andrewrich/Developer/dev-env add docs/STATUS.md docs/superpowers/plans/2026-09-08-backlog-remainder-roadmap.md
git -C /Users/andrewrich/Developer/dev-env commit -m "docs(status): record L1/N1a/F3, migration cleanup, and the 2026-09-08 W1 decisions"
```

Then push the branch and open the PR (title: `docs: refresh status for 2026-09-08 and record the W1 decisions`). Surface repo, PR number, URL.

---

### Task 4: Remove the temporary login alias (dotfiles)

**Files:**

- Modify: `~/Developer/dotfiles/bash/gh-wrapper.sh` (alias block at lines 187–191 and `_gh_wrapper_logins_equal`; header comment)
- Modify: `~/Developer/dotfiles/bash/tests/test-gh-wrapper-identity.sh`, `~/Developer/dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh`

**Gate:** satisfied 2026-09-08 (see "Live state measured" above).

This task is fully specified as **Task 12** in
`docs/superpowers/plans/2026-09-03-org-migration.md` (lines 1947–1991):
tests first, observe the two new cases FAIL, remove the alias, observe PASS,
shellcheck, full dotfiles suite, branch
`claude/chore-gh-wrapper-drop-alias-<session>`, commit subject
`chore(gh-wrapper): remove the twistedmelonman=smartwatermelon alias`. Follow
it verbatim. Two additions:

- [ ] **Step A: Re-verify the gate from the executing machine before editing**

```bash
for h in tilsit.local mimolette.local; do
  printf '%s: ' "$h"
  ssh -o ConnectTimeout=6 -o BatchMode=yes "$h" 'env -u GH_TOKEN gh api user --jq .login'
done
env -u GH_TOKEN gh api user --jq .login
```

Expected: `twistedmelonman` three times. If any machine prints anything else or is unreachable, stop and report; do not remove the alias.

- [ ] **Step B: After the PR merges, pull dotfiles on all three machines**

```bash
git -C /Users/andrewrich/Developer/dotfiles pull --ff-only
for h in tilsit.local mimolette.local; do
  ssh -o ConnectTimeout=6 -o BatchMode=yes "$h" '/opt/homebrew/bin/bash -lc "git -C ~/Developer/dotfiles pull --ff-only && cd ~/Developer/dotfiles && gh pr list --limit 1 >/dev/null && echo ok"'
done
```

Expected: `ok` from both. Use `/opt/homebrew/bin/bash` explicitly: a bare `ssh host 'bash -lc'` resolves `/bin/bash` 3.2 and the wrapper's `${owner,,}` fails with "bad substitution".

---

## Roadmap for the rest of the backlog

Each stage below gets its own plan document when it starts. Stages within a
row run in parallel; rows run in order only where an arrow says so.

| Order | Stage | Needs from Andrew |
| --- | --- | --- |
| 1 | Tasks 1–4 above (two PRs: dev-env, dotfiles) | merge locks |
| 2 | **W1 plan + build** `standards-check.yml` in `github-workflows`. Reference: `personify`'s `validate` workflow; fold in `zizmor.yml` propagation and a Node-line assertion. | merge lock |
| 2 (parallel) | **I0** billing script; **#85** history audit (report only); **#89** `.github` gate; **N1b** product-repo Node bumps; **L4** doc hygiene; **L5** small items | I0: run it on the company machine. #85: yes/no on rewrite, then on flip. Merge locks. |
| 3 | **W2 pilots** (4 repos above), then fleet via `bulk-install-claude-review.sh` pattern; `repo-template` pin correction and self-linting in the same pass; `scripts` caller-stub conversion | merge locks; pilot verdict is measured (fast, quiet, catches a known-bad diff), not asked |
| 3 (parallel) | **#90** ruleset evaluation on one test repo; **L2 → L3**; **#94** Netlify | #94 may need the Netlify dashboard; **F2** after I0 |
| 4 | **W3** flip required checks per repo (add `standards-check`, then remove `claude-review / run-review`, never zero), retire the reviewer, cut the major, retire `nightowl-restore-blocking-review.sh`, update `repo-template`, drop review-only tokens | merge locks; a final go before the major tag |
| 5 | **I1 → I2** account-switching module, company-machine setup | I2 is manual on the company machine |

Interruptions are reduced to: merge locks, the four yes/no gates named in the
column above, and anything that turns out to need the Netlify or GitHub web
UI.
