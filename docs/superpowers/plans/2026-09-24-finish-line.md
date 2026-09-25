# Finish line: 2026-09-24 → 2026-09-30

**Written 2026-09-24 (Thu evening).** A new plan, not a revision. It replaces
the "Open work" ordering in `docs/STATUS.md` for the six days to the hard stop.
The design docs stay authoritative on *what* each item is; this file is
authoritative on *when* and *who* until 2026-09-30 EOD.

Data behind every number here, measured 2026-09-24 with per-owner tokens:

| File | Contents |
| --- | --- |
| `2026-09-24-finish-line/triage.tsv` | All 163 open issues across the 18 dev-env repos: theme, bucket, priority, effort, human gate, evidence |
| `2026-09-24-finish-line/fleet-protection.tsv` | Required checks on the default branch of all 42 non-archived repos |
| `2026-09-24-finish-line/w3-readiness.tsv` | Last five `standards-check` runs on each of the 32 repos W3 still has to flip |

Re-measure before acting on a number. The fleet drifts.

## 1. Where the plan stood at the pause (2026-09-16 → 09-19)

- **Critical path:** W3 only — flip `standards-check` to required. 5 of 42.
- **Ranked ahead of W3:** credential rotation (`dev-env#148`, off-plan, urgent)
  and local-reviewer reliability (`dev-env#124`, the sole judgment gate since
  the 09-08 decision, five open correctness bugs).
- **After W3:** a retirement phase (remove `claude-review`, its callers,
  `nightowl-restore-blocking-review.sh`, the major tag, the template copy,
  review-only tokens). Rule: *never zero required checks*.
- **Parallel, independent:** I0, F2, L2–L5, #85, #90, #94.
- **Undecided:** 9/30 scope — full W3 or a pause-safe checkpoint.
- **Board:** decided (GitHub Project in `smartwatermelon`), never created.

## 2. What happened since (09-16 → 09-24)

**90 PRs merged across the 18 repos; zero direct pushes to a default branch.**
Almost none of it touched the plan.

| Area | What landed | Relation to plan |
| --- | --- | --- |
| Personify approval gate | `claude-config#544/#546/#572/#574/#584`, `dotfiles#354`, personify 2.0 (`personify#91`, `#99`) | Off-plan. Spawned 9+ defect issues, incl. `claude-config#547` (blocks all commits over SSH). Being suspended for this sprint (§4, Day 0). |
| Per-owner tokens | `claude-wrapper#123`, `#127` load `GH_TOKEN_SWM/NOS/TWM` at launch | **Advances** the STATUS "routing" gap. Fleet probes no longer need a manual token swap. |
| Secret redaction | `claude-config#535`, `#538` (PostToolUse redactor) | Off-plan follow-on to the secret-leak hook |
| standards-check | `github-workflows#171` (private-repo scoping), `#172` (canonical shellcheckrc); `standards-check-v1` → `a93fe43`, new tag `v1.1.0` | **Advances** W3 readiness. The retag is unrecorded in STATUS. |
| Local lint parity | `dotfiles#341/#344/#347/#353` | Advances L intent (local = CI). Spawned the 10 "delete repo-local zizmor.yml" issues. |
| Fleet CI plumbing | Floating reusable-workflow refs in 4 repos; `nightowlstudiollc/.github#17` fixed a `startup_failure` on a required check | Advances W2 hygiene |
| Agent UX | CLAUDE.md compression, ADHD default, handoff and morning/evening skills, `claude-incognito`, caffeinate | Off-plan |
| Fleet shape | `parmesan` created unprotected; `vpn-lan-bridge` moved NOS → SWM; `dumbify` archived | Unrecorded. `parmesan` contradicts W0. |

**No progress:** W3 (still the same 5 repos), credential rotation
(`kebab-tax#1258/#1264/#1265` open), digest App migration (`dev-env#149`).
The Dependabot digest has failed closed on **every run since 09-12 (17 of 17)**
and has never published.

**STATUS.md is wrong on these, all re-verified 09-24:**

1. Part D is **done** on TILSIT and MIMOLETTE (`hosts.yml` says
   `twistedmelonman` on both). STATUS still lists it as pending.
2. `dev-env#89` closed 09-11; STATUS lists it as open.
3. The five W3 repos **replaced** `claude-review`; they did not add
   `standards-check` alongside it. **0 repos require both.** The 09-16 "add
   alongside" definition has 0 done; the executed "replace" pattern has 5.
4. Fleet is 42: SWM 24, NOS 11, TWM 7 (was 24/12/6). 32 require
   `claude-review`, 5 require `standards-check`, 5 require nothing.

## 3. Issue triage (163 open)

| Bucket | Count | Meaning |
| --- | --- | --- |
| LAND | 44 | Do by 9/30 (3 P0, 14 P1, 16 P2, 11 P3) |
| PARK | 79 | Defer; each gets a resume note on the issue |
| CLOSE — certain | 22 | Already done, duplicate, or won't-do, with evidence |
| CLOSE — uncertain | 18 | Needs Andrew's call; evidence line in Appendix B |

No "won't do" item stays open: every CLOSE-WONTDO is on the close list.
Appendix A lists the LAND set by workstream. Appendices B and C list the close
candidates. PARK items stay in `triage.tsv`, grouped by theme.

## 4. Decisions Andrew owns (answer before Day 1 starts)

| # | Decision | Recommendation | Why |
| --- | --- | --- | --- |
| D1 | 9/30 scope | **Floor + Target.** Floor = pause-safe checkpoint (guaranteed). Target = W3 flipped on all 32. Stretch = P2/P3 LAND items. | W3 mechanics are ~32 API calls once the token can write. Readiness is green: recent PR runs pass on 29 of 32. |
| D2 | What W3 means | **Atomic replace**: one protection PUT per repo swaps `claude-review` for `standards-check`. | Matches the 5 pilots. Satisfies "never zero". The retirement phase (`github-workflows#154`) shrinks to callers, tag, template and tokens, and parks past 9/30. |
| D3 | Merge model | **Batched UI merges at fixed windows** (see calendar). | W2 was merged this way (2 locks typed in total). Expect 30+ PRs. |
| D4 | Weekend | Agents run Sat/Sun; PRs queue for Monday's window. Andrew's weekend time: optional. | Keeps the critical path moving without Andrew. |
| D5 | Close list | Approve Appendix B's 22 in one message; rule on Appendix C's 18. | Closes 40 of 163 on Day 1. |
| D6 | Digest (`dev-env#149`) | **Install the GitHub App** (plan: `docs/plans/2026-09-11-dependabot-digest-github-app.md`). If not by Mon, **disable the schedule** and PARK. | 17 red runs a day is noise either way. |
| D7 | Agent budget | Raise `BUDGET_SUBAGENT_TOKENS` for this sprint, **or** accept one repo per agent. | Every agent in tonight's analysis ran 1.5–3× over the 2.3M ceiling. |

**D1–D7 approved by Andrew, 2026-09-24**, with one amendment to D3: a UI
merge skips `pre-merge-review.sh` silently, which is the defect in
`dev-env#109`. So `dev-env#109` (mobile merge authorization) moves from PARK
to LAND, P1, target Sat 9/26, in WS5. Until it ships, merge windows use UI
merges plus a post-merge audit listing every merge that had no lock.

## 5. Blockers and tooling asks

| Blocker | Blocks | Owner | Fix |
| --- | --- | --- | --- |
| Personify gate armed | Every agent commit and PR | Andrew | Merge `claude-config#586`, then `dotfiles#363`; `echo 2026-09-30 > ~/.claude/gate-review/SUSPENDED` |
| Tokens are `Administration: Read-only` | W3 flips (WS3) | Andrew | Add `Administration: Read and write` to CCCLI_SWM, CCCLI_NOS, CCCLI_TWM. Fallback: Andrew flips 32 repos in the UI. |
| Board cross-owner add untested | Board population | Agent, Day 1 | Create the board with the SWM token; add one `twistedmelonman` issue. If it fails: Projects scope on CCCLI_TWM. |
| Fine-grained PATs cannot read Checks on private repos | W3 readiness on 8 private NOS repos | — | Accept PR-run evidence (listed in `w3-readiness.tsv`) or read in the UI |
| Credential mint/rotate | WS1 | Andrew only | 1Password + vendor dashboards |

## 6. Workstreams

Effort is agent time. "H" is Andrew's hands-on time.

### WS0 — Unblock (Day 0–1) · critical

| Task | Effort | H | Done when |
| --- | --- | --- | --- |
| Merge `claude-config#586` → pull → merge `dotfiles#363` → pull | — | 5 min | Both merged; `~/.claude/scripts/gate-review.sh suspended` exits 0 after the file exists |
| Write `SUSPENDED` (`2026-09-30`) | — | 1 min | A gated commit prints `[personify-gate] SUSPENDED until 2026-09-30` |
| Token write scope (D-blocker) | — | 10 min | A dry protection read + one PUT on a test repo succeeds |
| Create the board; test a cross-owner add | 30 min | — | Board exists; one `twistedmelonman` issue added |
| Execute approved close list | 30 min | — | 40 issues closed, each with an evidence comment |

### WS1 — Credential rotation (`dev-env#148`) · P0 · human-gated

`kebab-tax#1258` (expiring `CHANGELOG_PUBLISHER_PAT`), `#1264` (RevenueCat),
`#1265` (Brevo). Agent writes the step list and verifies each secret after;
Andrew mints and rotates. **H: ~45 min. Deadline: Fri 9/25.**

### WS2 — Local-reviewer reliability (`dev-env#124`) · P0/P1

All in `claude-config`, mostly `run-review.sh` and the agent prompts. Two
agents at most, on disjoint files, each in its own worktree.

| Lane | Issues | Effort |
| --- | --- | --- |
| A — false blocks | `#455` (+ `#555` as its evidence), `#488`, `#489` | M + M + M |
| B — false passes | `#451`, `#558`, `#481` | S + S + S |
| C — hygiene | `#439` (L3), `#475`, `#496` | S each |

Done when each fix is validated against a known-bad case, not only unit tests.

### WS3 — W3 flip (`dev-env#147`) · P1 · Target

1. Day 1: pilot on 3 low-traffic SWM repos (atomic replace); watch one real PR each.
2. Day 3: flip the remaining ~26 in batches of ~8, re-reading protection after each.
3. Handle apart: `crazy-larry` and `x-thread-reader` (never ran) and
   `networth-agent` (no workflow; `IGNORED` by decision — leave on `claude-review`).
4. Protect `parmesan` to the exemplar (W0 gap).

Effort: M. Rollback per repo: PUT the previous contexts back from
`fleet-protection.tsv`.

### WS4 — Fleet sweep · P2/P3 · parallel, one agent per repo

One PR per repo, bundling what applies there:

- Delete repo-local `zizmor.yml` (10 issues; canonical config now resolves).
- Untrack `AGENTS.md` (`dev-env#155`, 8 repos).
- Node 20 pins (`dev-env#78`), where present.

Without a vehicle PR, those 10 zizmor issues would otherwise park forever;
bundling makes them ~15 PRs total, merged in the Monday window.

### WS5 — Tooling and config · P1/P2

| Issue | What | Effort | Gate |
| --- | --- | --- | --- |
| `dev-env#109` | Mobile merge authorization: a GitHub comment by Andrew creates the lock (absorbs `claude-config#509`, `dev-env#153`). Known-bad test: a comment by anyone else creates nothing. | M | Target Sat 9/26; security-model change, so Andrew reviews before merge |
| `claude-config#548` | Three text surfaces the gate misses | M | Before the gate re-arms 10/01 |
| `claude-config#585` | Morning/evening briefs publish personal data | M | Andrew: accept public history? pick profile path |
| `dev-env#156` | Secret redaction misses non-gitleaks vendors | M | — |
| `claude-wrapper#126` | Per-session token selection breaks cross-owner work | S | — |
| `dev-env#113` | standards-check should say *what* failed | S | — |
| rest of Appendix A (P2/P3) | small fixes | S each | Stretch |

### WS6 — Pause-safe record · Floor · guaranteed

| Task | Effort | Due |
| --- | --- | --- |
| Board populated with all LAND + PARK items, fields set | 1 h | Fri |
| Resume note on each of the 80 PARK issues (what, where it stopped, first step) | 2 h | Tue |
| `docs/STATUS.md` rewritten as-of 9/30, fixing the four errors in §2 | 1 h | Wed noon |
| Every open PR either merged or described in STATUS | — | Wed EOD |

## 7. Calendar

| Day | Agents | Andrew (H) | Checkpoint |
| --- | --- | --- | --- |
| **Thu 9/24** (tonight) | Gate PRs merged; gate suspended | D1–D7 answered | Done |
| **Fri 9/25** | WS0 board + closes; WS2 lanes A+B start; WS3 pilot (3 repos); WS4 fan-out starts; WS6 board | Token scope, WS1 rotation (~1 h) | **CP1 (EOD):** gate lifted, tokens writable, credentials rotated, board live, 40 issues closed |
| **Sat 9/26** | WS2 continues; WS4 PRs; WS5 (`dev-env#109` first) | Optional: review `dev-env#109` | — |
| **Sun 9/27** | WS2 lane C; WS5; WS6 resume notes | Optional | — |
| **Mon 9/28** | Fix review/CI findings | **Merge window AM** (~1 h): WS2, WS4, WS5 PRs; D6 digest fallback | **CP2:** reviewer fixes merged; fleet sweep merged |
| **Tue 9/29** | WS3 remaining flips; WS6 notes finished | Merge window PM (~30 min) | **CP3:** W3 32 of 32 (or named exceptions) |
| **Wed 9/30** | STATUS rewrite; final board state | Final merge window (~30 min); read STATUS | **CP4 (noon):** Floor complete. **EOD:** stop. |

**Slip rule.** If CP1 misses token scope, WS3 moves to Andrew's UI flips on
Tue. If CP2 misses, WS5 drops to PARK and WS6 starts Mon. The Floor (WS6) never
moves.

## 8. Out of scope past 9/30 (parked, with owners)

- Reviewer retirement phase — `github-workflows#154`.
- Five retired repo paths — support ticket 4746770 (deferred by decision).
- Team → Free downgrade — sequence after the ticket resolves.
- Strategy issues `dev-env#159`, `#160`, and the principle notes folded into them.
- Re-arm check: the gate re-arms itself on 10/01; `claude-config#547` (SSH)
  must be fixed before relying on it remotely.

## Appendix A — LAND (44)

| Pri | Issue | Effort | Theme | Human gate | Title |
| --- | --- | --- | --- | --- | --- |
| P0 | `claude-config#455` | M | reviewer-reliability | — | Code reviewer blocks documented Netlify `%{submissionId}` token as "undocumented |
| P0 | `dev-env#124` | L | local-review | none for corpus; Andrew decides #489 context-vs-mandate question | \[infra\]\[L\] Local-reviewer reliability is critical-path and unowned |
| P0 | `dev-env#148` | S | credentials | Andrew mints new CHANGELOG_PUBLISHER_PAT; rotates RevenueCat + Brevo k | \[off-plan\]\[urgent\] Credential rotation — expiring/plaintext keys in nightowlst |
| P1 | `claude-config#439` | S | install-deploy | — | install.sh cannot detect orphaned symlinks, and --repair reports "healthy" while |
| P1 | `claude-config#451` | S | review-false-ok | — | Chunked review silently skips the only files that matter, and reports PASS |
| P1 | `claude-config#475` | S | claude-md-instructions | — | Protocol 4 hook-log check uses a relative --git-dir and can read another repo's  |
| P1 | `claude-config#481` | S | reviewer-reliability | — | run-review.sh: skip AI review for artifact-only commits (logs, tsv, scan/) |
| P1 | `claude-config#488` | M | reviewer-reliability | — | code-reviewer fabricated a blocking security finding against a file that does no |
| P1 | `claude-config#489` | M | reviewer-reliability | — | full-diff pre-push review has no access to the commit message / PR intent |
| P1 | `claude-config#548` | M | approval-gate | — | Three text surfaces the approval gate does not cover |
| P1 | `claude-config#558` | S | review-false-ok | — | Chunked commit review never runs adversarial-reviewer, and does not say so |
| P1 | `claude-config#585` | M | daily-brief-skills | Andrew: accept that history stays public; pick profile path | morning-andrew and evening-andrew publish personal and workplace details; split  |
| P1 | `claude-wrapper#126` | S | gh-identity-routing | — | Per-session token selection breaks cross-owner work, and selected the wrong toke |
| P1 | `dev-env#109` | M | merge-gate | Andrew reviews the security-model change | \[infra\] Merge authorization is laptop-only, so mobile forces a silent gate bypass (promoted from PARK 09-24) |
| P1 | `dev-env#147` | L | W3-fleet | Andrew picks scope (full 37 vs pause-safe checkpoint) per STATUS | \[infra\]\[W3\] Flip standards-check to required, fleet-wide (5 of 42 done) |
| P1 | `dev-env#149` | S | dependabot-digest | Andrew creates the App and installs it on all 3 owners | \[infra\] Dependabot digest: migrate to GitHub App auth (blocked on human install  |
| P1 | `dev-env#156` | M | secret-hygiene | none (code lives in claude-config; consider transferring issue) | Secret redaction misses vendors gitleaks has no rule for; add a command-keyed pr |
| P2 | `claude-config#496` | S | claude-md-instructions | — | stop talking about chesterton's fence. apply it, don't advertise it. |
| P2 | `claude-config#504` | S | lint-parity | — | Local review cannot catch CI findings that depend on checkout layout (PR #503 SC |
| P2 | `claude-config#523` | S | claude-md-instructions | — | Protocol 1: default branches to $USER/branchname instead of claude/`<type>`-`<desc>` |
| P2 | `claude-config#551` | S | daily-brief-skills | — | morning-andrew: huddle is transcribed locally, not unrecorded |
| P2 | `claude-config#559` | S | approval-gate | — | gate-review: accept near-miss spellings of APPROVED and ABORT |
| P2 | `claude-config#562` | S | merge-lock | — | merge-lock improvements |
| P2 | `claude-config#567` | M | handoff-skills | — | handoff skills assume a Google Drive mount and only discover its absence at use  |
| P2 | `dev-env#113` | S | ci-feedback | — | standards check must describe actual failure rather than just pass or fail |
| P2 | `dev-env#126` | S | context-cost | Andrew chooses option A (durable guard) or B (uninstall) | \[infra\] Re-evaluate superpowers: defeat the auto-injection durably, or stop usin |
| P2 | `dev-env#155` | S | agents-md | 8 merge-locks + personify approvals; carve-out decision for claude-cod | Stop tracking AGENTS.md across owned repos |
| P2 | `dev-env#78` | S | runtime-eol | — | Node 20 is past EOL (2026-04-30) and pinned fleet-wide — audit and migrate off |
| P2 | `dev-env#94` | M | netlify | Netlify dashboard or connector session; trigger publishes | Post-migration: verify a complete Netlify publish run for all six Netlify sites |
| P2 | `dotfiles#312` | S | brew-cask-upgrade | Andrew confirms option 1 (exclude chrome/iterm2 casks) vs 2/3 | brew cask upgrade breaks running network-accessing apps until relaunch |
| P2 | `dotfiles#321` | S | precommit-hooks | — | prettier pre-commit hook fails in repos with nested package node_modules (cwd-re |
| P2 | `dotfiles#356` | S | template-deploy | Run install.sh --sync on TILSIT/MIMOLETTE after merge | Template .claude/README.md never deploys: */README.md symlink exclusion matches  |
| P2 | `repo-template#9` | S | zizmor-copy-cleanup | — | Delete repo-local zizmor.yml — canonical config now resolves from github-workf |
| P3 | `claude-config#351` | S | worktree-policy | Andrew picks option 1/2/3 (lift, keep, tighten) | Revisit worktree restrictions after ~4 weeks — consider lifting entirely (revi |
| P3 | `claude-config#534` | S | lint-parity | — | shellcheck: ~/.shellcheckrc makes local runs disagree with CI, and $HOME discove |
| P3 | `claude-config#539` | S | lint-parity | — | Delete repo-local zizmor.yml — canonical config now resolves from github-workf |
| P3 | `claude-config#542` | S | claude-md-instructions | — | Non-blocking review findings from PR #541 (1) |
| P3 | `claude-config#553` | S | approval-gate | — | gate-review: already-consumed items are re-approved by a later batch |
| P3 | `claude-config#570` | S | merge-lock | — | merge-lock tui: multi-select exists but nothing on screen says so |
| P3 | `dotfiles#304` | S | test-isolation | — | Record why .git/config's uchg tripwire is intentionally absent, so it is not re- |
| P3 | `dotfiles#326` | S | org-migration-cleanup | "FLAG: Deferred-by-decision ""Five retired repo paths"" (ticket 474677 | README clone URLs still point at pre-migration smartwatermelon/dotfiles |
| P3 | `dotfiles#355` | S | personify-gate | — | Approval gate does not inspect gh pr create --fill |
| P3 | `smartwatermelon-marketplace#29` | S | stale-hook-scaffold | — | Non-blocking review findings from PR #28 (1) |
| P3 | `smartwatermelon-marketplace#30` | S | plugin-version-drift | — | code-critic version drift: marketplace.json says 1.3.0, plugin.json says 1.4.0 |

## Appendix B — close list, certain (22)

Approve as a block. Each close gets a comment quoting the evidence.

| Issue | Reason | Evidence |
| --- | --- | --- |
| `claude-config#495` | DONE | #498 (63dbce5) dropped the submodule; no .gitmodules on origin/main; update-tools.sh has no submodule call; CLAUDE.md "This repo tracks no submodules" |
| `claude-config#514` | DONE | Fixed by #521 (eeedf54, 134/134) and #524 (a72b9ff); issue's own last comment: "What remains: Nothing for this issue" |
| `claude-config#531` | DONE | twistedmelonman/dotfiles#344 (1913081) lint-zizmor.sh resolves config like CI; issue's own comment: remaining scope is twistedmelonman/dotfiles#345 |
| `claude-config#532` | DONE | twistedmelonman/dotfiles#347 (ce00971) "resolve yamllint config the way CI does"; config.yaml:101 now calls lint-yamllint.sh |
| `claude-config#533` | DONE | twistedmelonman/dotfiles#341 (47052f0) "merge canonical and repo configs instead of choosing one"; twistedmelonman/dotfiles#308 CLOSED |
| `claude-config#545` | DUP | Item 1 (SSH fails closed) is #547/#509; item 2 (matcher regression suite) done in #546 (2c5d851, "50-case matcher suite ... claude-config#545, second item") |
| `claude-config#549` | DONE | Item 2 (approved/ unbounded) fixed by #574 (a9d3e9b, APPROVAL_TTL gate-review.sh:43); item 1 is an accepted, in-code documented design limitation |
| `claude-config#554` | DUP | Same defect as #559 (gate-review.sh:240 `_die "unrecognized status"`); #559 is the fuller spec incl. keep-waiting + tests |
| `claude-config#565` | DONE | #574 (a9d3e9b) adds APPROVAL_TTL (1800s default, GATE_REVIEW_APPROVAL_TTL override) and _prune_expired on check/stage; TTL chosen 30 min not the 24h proposed |
| `claude-config#569` | DUP | Same defect as #567; carry its $XDG_STATE_HOME/claude-handoff location suggestion onto #567 |
| `dev-env#104` | DUP | dev-env's AGENTS.md is one of the 8 repos in #155, which removes the file rather than repairs it (still tracked, Codex paths present 09-24) |
| `dev-env#136` | DUP | Its one item (token strategy undecided) was decided 09-11 (GitHub App), plan merged in dev-env#135, execution tracked in #149 |
| `dev-env#67` | DONE | 67.1 fixed in dev-env#73 (banner present in handoff doc). 67.2 items 1-3 done per 08-30 comment; item 4 (keep uchg) reversed by decision, tracked in twistedmelo |
| `dev-env#60` | DUP | Decision taken 09-08 and built (W1/W2); the plan it spawned is smartwatermelon/github-workflows#154 (open); what remains is W3 #147 + retirement phase |
| `dotfiles#296` | WONTDO | Both items are deliberate tradeoffs already explained in finicky.js comments (uninstalled-PWA handler drops URL; out-of-scope subdomains); nothing to do |
| `dotfiles#317` | DONE | "Fixed by dotfiles#320 (d9bb4f9): waits for pidfile before SIGTERM, separates ""stub never started""; 20/20 under load. #320 closed duplicate dotfiles#319, not  |
| `huddle-transcribe#16` | DUP | Only item is the green-SKIP on workflow-touching PRs = dev-env#116 (also github-workflows#173) |
| `personify#80` | WONTDO | Fix location obsolete: 2.0 (#91, 88aec1b) removed the two-arm harness and groups V/W/Z. The provenance concern survives; re-express it as a VOICE.md work-regist |
| `github-workflows#168` | DONE | Fixed by github-workflows#172 (a93fe43, standards/shellcheckrc external-sources+source-path=SCRIPTDIR), deployed: standards-check-v1 -> a93fe43. Repro: bare=SC1 |
| `github-workflows#173` | DUP | Same defect as dev-env#116 (filed earlier, 09-10); body claims no existing issue but searched only claude-config numbers. Still present: claude-blocking-review. |
| `claude-code-workflows-agents#22` | WONTDO | No call sites to migrate: no import anthropic / from anthropic anywhere in plugins/plugin-eval (only declared in pyproject.toml:19) |
| `vpn-lan-bridge#20` | DONE | "Close condition met: github-workflows README:168 ""@v3 Recommended for all callers""; zizmor policy ref-pins first-party; all vpn-lan-bridge callers float" |

## Appendix C — close list, needs Andrew's call (18)

| Issue | Proposed | Evidence and open question |
| --- | --- | --- |
| `claude-config#477` | DONE | Fixes 1+3 in #524 (a72b9ff), merge-lock half in #521 (eeedf54), fix 2 in #575 (76f6ae0, "suite is 562 of 562 locally"); optional fix 4 (CI minimal env) not done — re-run suite before closing |
| `claude-config#493` | WONTDO | Stale advisory standards-check red on a docs-only PR (run 34545224180, log NOT read); adjacent run 34548182880 was the markdownlint opt-out fixed by #497 (1eb7452) per dev-env STATUS.md:253-263; stand |
| `claude-config#525` | DONE | #575 (76f6ae0) sources gh-wrapper.sh, keeps FATAL guard, 562/562; "neuter and confirm fail" validation from done-when not evidenced in PR body |
| `claude-config#537` | DONE | Built as #538 (d53c5bc) PostToolUse redactor, gitleaks + exact-value, Bash and Read; residual from 2026-09-23 comment (path-keyed prong, 16-char app-password shape) overlaps smartwatermelon/dev-env#15 |
| `claude-config#552` | DONE | Mechanism already guarded: _refuse_if_open runs before batch.txt is written (gate-review.sh:178 vs :186) since #544 (a51989e); likely sequence was the 300s Bash timeout killing poller 1, call 2 passin |
| `claude-config#555` | DUP | Same class and same fix as #455 (unverifiable external claim -> BLOCKING, forced --no-verify); keep as evidence on #455, or keep #555 as the generalized keeper — one of the two |
| `dev-env#153` | DUP | Same problem as #109 (approval from phone). Fold in as another alternative under #109's "Alternatives considered" |
| `dev-env#111` | DUP | Per-test time cap is a sub-rule of #140's per-repo time/count budget; fold into #140 |
| `dev-env#122` | DUP | Empty body; it is the agent-guidance half of #93's third "Done when" bullet |
| `dev-env#77` | DONE | Live gap fixed: twistedmelonman/dotfiles#344 (merged 09-17) makes lint-zizmor.sh fall back to the canonical config like CI; per-repo zizmor.yml deletion issues open in 8+ repos. Leftovers (plan doc st |
| `dev-env#119` | DUP | Empty body; twistedmelonman/claude-config#354 "Make the reviewer engine pluggable" (open) covers it if "pluggable" means engines, not steps |
| `dotfiles#247` | WONTDO | 2026-08-30 triage: 6 fixed, 2 non-findings; item .1 (SHA-pin) superseded by ref-pin policy for first-party refs in github-workflows/zizmor.yml; .6/.8/.11 latent by own admission; carry .2 (tolerate_up |
| `dotfiles#301` | DONE | "dotfiles#351 (a8789fa, ""Advances #301""): file 197s->20.6s, suite 234s->60.7s with known-bad gates; question answered. Remaining epic work lives in dev-env#140/#141/#111; hook defect split to #350.  |
| `dotfiles#303` | DUP | Not built (gh-wrapper.sh:316 still calls gh api user); dotfiles#336 per-invocation owner-keyed token selection removes the lookup entirely and names #303 as subsumed |
| `dotfiles#307` | DUP | Author reframed as Chrome instance of #312 on 2026-09-09; same fix covers both; kept open only as the Chrome example |
| `dotfiles#327` | WONTDO | "Body: ""Impact on this repo: None to the code""; Finicky/template/generator exonerated; fault 1 fixed by reinstall; fault 2 is upstream Chrome. Research record, no repo action" |
| `huddle-transcribe#29` | DUP | Item 1 = dev-env#116; item 2 moot: canonical zizmor.yml policy ref-pins smartwatermelon/github-workflows/* and standards-check is green on last 3 runs |
| `smartwatermelon-marketplace#25` | WONTDO | Generic platform vision (ratings, revenue, SSO, mobile) far beyond a personal plugin marketplace; no concrete deliverable |
