# Infrastructure project status

**As of 2026-09-08.** Point-in-time snapshot of the infrastructure backlog
(`docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md`). The
design doc is authoritative on *what* each item is and why; this file records
*where things stand* and what to pick up next.

Re-measure before acting on any number here. Every count below came from a
live query on the date shown, and the fleet drifts.

## Where the project is

The identity and migration layers are done. The fleet layer has one item
left, W3. Runtime EOL is done. Local review has not started beyond L1.

| Layer | State |
| --- | --- |
| Foundation (F) | F1, F3, F4 done. F2 open (latent hazard, not urgent). |
| Identity / billing (I) | I3 done. I0, I1, I2 open. |
| Fleet (W) | W0, W1, W2 done. W3 open — **critical path**. |
| Local review (L) | L1 done. L2, L3, L4, L5 open. |
| Runtime EOL (N) | N1a, N1b done. |

**Critical path: W1 → W2 → W3.** I3, W0, W1, W2 have left it. Only W3
remains. Runtime EOL (N) is fully done. Everything in L runs in parallel and
depends on nothing.

## Done

### I3 — Org migration (dev-env#54, closed)

Executed 2026-09-04 as a **rename-then-reclaim**, not the six-phase transfer
the design sketched: the personal account `smartwatermelon` was renamed to
`twistedmelonman`, then `smartwatermelon` was re-created as an organization
and repos transferred in.

**25 of 30 repos moved. Five are blocked pending a support ticket.** `dotfiles`, `claude-config`,
`personify`, `huddle-transcribe`, `projectinsomnia` are blocked by GitHub's
**popular repository namespace retirement** — a path is retired
when the repo saw >100 clones or >100 Actions runs in the week before a
rename, or shipped a Marketplace action. Retirement binds the *string*, not
the account, so the new org inherited the old user account's retired paths.
It blocks transfer (HTTP 422) and creation alike. A support ticket is in
flight (4729524), reopened after the org's Team upgrade; Andrew is pursuing it.

Three platform behaviors found the hard way, all now documented:

- **Actions does not follow owner redirects** for reusable-workflow
  references — the literal `owner/repo` must exist. The REST API *does*
  follow them, so every `gh api` check read healthy while CI died at 0s with
  no jobs and no logs.
- **GitHub App installations do not follow repo transfers.**
  `anthropics/claude-code-action@v1` (a downloaded Action) is distinct from
  the Claude GitHub App (`github.com/apps/claude`, an account-level install).
  The action cannot install the app; only an account owner can.
- **Org secrets do not reach private repos on GitHub Free.** Both orgs
  currently read `plan=team`, but that plan was bought to file a support
  ticket and will be dropped. Every private repo running a Claude workflow
  keeps its own repo-level copy.

### F4 — Token scope resolution

Closed via a narrow escape hatch in `gh-wrapper.sh`, not the token router the
design proposed. The finding that made it cheap: `GH_TOKEN` was never the
*wrong identity*, only a *too-narrow scope* on the right one. The wrapper now
detects GitHub's own `needs the "admin:org" scope` on stderr and prints an
`env -u GH_TOKEN` re-run.

### W0 — Fleet brought to the exemplar settings

**33 of 37 non-archived repos enforce `claude-review / run-review`, up from
25.** Applied per-repo to 9 repos on 2026-09-05, matching
`twistedmelonman/dotfiles` and `twistedmelonman/claude-config` (byte-identical
to each other, which made the template unambiguous):

- required check `claude-review / run-review`, `strict: true`
- `required_conversation_resolution: true`, 0 approving reviews
- `enforce_admins: false`, force-pushes and deletions off
- `allow_auto_merge: true`, `delete_branch_on_merge: true`

W0 was filed on a wrong premise, corrected in #91. The design claimed
`cleanroom` was protected by a `nightowlstudiollc` "Claude blocking review"
org ruleset and that creating an equivalent was the missing work. **That
ruleset is `enforcement: disabled` and enforces nothing** —
`repos/nightowlstudiollc/cleanroom/rules/branches/main` returns `[]`. All
protection in both orgs is classic per-repo branch protection. The gap was
also smaller than reported: the transferred repos mostly carried their
required check through intact.

### W1, W2 — `standards-check.yml` built and rolled out fleet-wide

Plan: `docs/superpowers/plans/2026-09-08-w2-fleet-rollout.md` (execution
record and corrections folded in). `standards-check.yml` (deterministic
linters, no judgment reviewer) is installed as a **non-required** check on
every non-archived, non-ignored fleet repo. Waves 1 (node-floor) and 2
(zizmor pins) are merged everywhere they applied; wave 3 (shellcheck/
markdownlint/yamllint) is scoped and **in progress as of 2026-09-09** — see
the Critical path section below. W3 (flip to required, per repo) is next.

**N1b — done, with a correction.** The live node-floor set was
`kebab-tax`, `reliquarist`, `gmail-newsletter-filter`, not the plan's
original four: `smartwatermelon/headroom` and `Gmail-MCP-Server` both
return 404 under either org and do not exist; `tensegrity` has no
sub-floor Node pin and passed node-floor cleanly without a fix (its
zizmor/markdownlint debt is unrelated and rides wave 3). All three real
node-floor repos are merged and green on node-floor.

Also noted during the wave-2 scan: `smartwatermelon/gmail-newsletter-filter`
carries its own root `zizmor.yml`, a strict prefix of the canonical
policy file (same `unpinned-uses`/`excessive-permissions` rules, missing
three later ignore blocks). It passes zizmor regardless, so no action is
needed now, but it is config drift from the canonical file worth fixing
eventually.

### 2026-09-09 — merge gate, secret-leak hook, wave-3 start

- **#106 — `pre-merge-review.sh` blocked on non-required checks.** Fixed in
  `twistedmelonman/claude-config#487` (merge `4a109d3`), closed 2026-09-09.
  The hook fed the whole `statusCheckRollup` to the analysis prompt with no
  required/non-required distinction, so any red check read as blocking —
  stricter than GitHub itself. It now fetches the base branch's required
  contexts and splits the sections, blocking only on required checks.

  Fails closed: 404 (unprotected), 403 (token without `Administration:read`),
  or any other failure treats every check as required. The mode is logged
  each run and 403 is distinguished from 404 — **if a rotated PAT loses that
  permission this silently reverts to the old behavior while looking fixed,**
  and the log line is how it gets noticed.

  Two traps, both caught against live API data: the rollup has two node
  shapes (`CheckRun` `.name`/`.conclusion` vs `StatusContext`
  `.context`/`.state` — Netlify deploys are the latter and rendered as null
  before), and membership must be an equality scan, since jq `index` does
  substring matching and would classify `claude-review-haiku` as required
  wherever `claude-review` was.

  This was a **prerequisite for wave 3**, not merely adjacent to it.

- **Secret-leak PreToolUse hook** — shipped as `claude-config#484` (merge
  `4348f1b`). Blocks commands that would print a live secret into the
  transcript. Runs first in `hook-block-all.sh` so a secret-carrying command
  cannot be logged in full by a sibling hook. Details:
  `reference_secret_leak_hook_design`. Not yet deployed to
  TILSIT/MIMOLETTE/ASIAGO — `~/.claude/scripts` uses per-file symlinks and
  the dispatcher skips a missing hook **silently**, so `install.sh` must run
  on each.

- **`870728f` "add AGENTS.md" was pushed directly to `dev-env` main** and is
  not otherwise recorded here. Per dev-env#104 the file is agent context, not
  project content: `AGENTS.md` is now in `.git/info/exclude` across all 45
  repos under `~/Developer`, and untracked in the two repos with open PRs
  (`kebab-tax-netlify#279`, `projectinsomnia#161`). It remains tracked in 12
  others pending a later batch, by decision. One deliberate exception:
  `claude-code-workflows-agents`, where `AGENTS.md` is the canonical project
  doc and `CLAUDE.md` is a symlink to it — excluded but left tracked.

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
closed. Runbook Part D was wrongly recorded as done on TILSIT and MIMOLETTE
on 2026-09-08 (`gh api user` reports the renamed login even before re-login;
`hosts.yml` on both still says `smartwatermelon`). MIMOLETTE's dotfiles clone
was 35 commits behind and was fast-forwarded. The temporary login alias was
removed anyway (`dotfiles#310`), so the wrapper fails closed on both machines
for org-owned repos until Andrew re-runs Part D there.

## Open work, in priority order

### Critical path: W1 → W2 → W3

W1 and W2 are done; W3 (flip `standards-check` to required per repo) is the
remaining critical-path item. Plan and execution record:
`docs/superpowers/plans/2026-09-08-w2-fleet-rollout.md`.

Decisions taken 2026-09-08 (Andrew) that unblocked W1 — see
`docs/superpowers/plans/2026-09-08-backlog-remainder-roadmap.md`:

- **No judgment reviewer stays in CI.** `standards-check.yml` replaces
  `claude-blocking-review.yml` outright; local hooks are the only judgment
  pass. `claude-assistant.yml` is out of scope and keeps its token.
- **`nightowl-restore-blocking-review.sh` is retired with W3.**

W2 pilots (done): `repo-template`, `pr-review`, `claude-code-workflows-agents`,
`nightowlstudiollc/.github`. `scripts` was not a pilot (see #85). The stub
was installed on all 40 fleet repos on 2026-09-08 via direct push
(`bulk-install-standards-check.sh`, `github-workflows#164`); `github-workflows`
itself classifies `DIFFERS` by design (that path holds the reusable workflow,
not a caller stub); `nightowlstudiollc/networth-agent` is `IGNORED`; 3 repos
are archived.

**Merge locks actually typed by Andrew: 2** (dev-env#99, github-workflows#164).
Every other W2 merge was done from the GitHub UI; dev-env#101 tracks a
merge-lock TUI improvement to make that the normal path.

**W3 readiness** (latest `standards-check` PR run per repo, measured
2026-09-08; a repo with no PR since install shows `never-ran` and needs a
no-op PR in W3 to get a first run): **green 9 of 41, red 15, never-ran 17.**
All 15 red repos fail only on wave-3 linters (shellcheck/markdownlint/
yamllint) — zizmor and node-floor are clean everywhere a check has run,
confirming waves 1–2 landed cleanly. Full table:
`docs/superpowers/plans/2026-09-08-w2-fleet-rollout/w3-readiness.tsv`.

**Wave 3 (combined shellcheck/markdownlint/yamllint, ~26 repos) — cleared to
proceed by Andrew 2026-09-09.** It is the main path to moving repos out of
`never-ran`/red before W3 flips checks to required.

Progress as of 2026-09-09:

- **Green:** `dev-env`, `scripts`, `archive-resolver`, `claude-config`
  (claude-config cleared 90 findings in `#483`, merge `97e44ba`).
- **`nightowlstudiollc/kebab-tax-netlify#279`** — npm advisories 9 → 0,
  lockfile only. This is what made its `validate-audit` job red; that check
  now passes.
- **`twistedmelonman/projectinsomnia#161`** — 60 markdownlint findings → 0.
  58 were MD001 in `src/content/`, a uniform artifact of the Medium
  scrape → Markdown → Astro pipeline, grandfathered via a repo-local
  `.markdownlint-cli2.jsonc`; the 2 real findings fixed by hand. Its `build`
  and `standards-check` remain red on **pre-existing, unrelated** debt (npm
  advisories, already failing on `main` at `7bbdbde`; and shellcheck findings
  in `.claude/hooks/extensions/example.sh.disabled`).

**The "must go fully green in one PR" constraint is lifted.** It came from
`pre-merge-review.sh` blocking on non-required checks (dev-env#106), which is
fixed — a wave-3 PR that clears one linter no longer blocks itself on the
others.

### Runs in parallel with W

- **I0** — `CLAUDE_CONFIG_DIR` billing-verification script. Deliverable is a
  script Andrew runs on the company machine.
- **F2** — owner-aware `git-identity.sh`. Latent hazard only; do after I0.
- **L2 → L3, L4, L5** — deploy/edit separation, the false-OK pair
  (claude-config#439, #451), doc hygiene, small unfiled items.
- **#89** — add `claude-blocking-review.yml` + exemplar protection to
  `smartwatermelon/.github` only; the other three stay ungated by decision.
- **#90** — evaluate org rulesets on one test repo against a known-bad PR.
- **#85** — full-history secret audit of `scripts`, then stop and report.
- **#94** — Netlify publish verification for six sites (needs the Netlify
  dashboard as the inventory of record).
- ~~`nightowlstudiollc/kebab-tax-netlify`'s `validate-audit` job fails on new
  npm advisories.~~ **Fixed in `#279`** (2026-09-09). The "7" here counted
  advisories *outside the accepted baseline*, which is what
  `check-audit-baseline.sh` fails on; `npm audit` reported **9** in total.
  Both numbers were right about different things.
  `npm audit fix --package-lock-only` took it to 0, lockfile only. The one
  accepted advisory (`GHSA-jmr9-qjv8-65gv`, extract-zip) retired by *removal*,
  not by patch — there is still no upstream fix, but the `netlify-cli`
  27.4.0 → 27.5.2 bump dropped the dependency path that reached it.

### Filed 2026-09-05

- **#84** — three conditions the org-migration design's failure table does
  not cover.

## Deferred by decision

These are not oversights. Do not "fix" them without asking.

| Item | Decision |
| --- | --- |
| Runbook Part D on TILSIT and MIMOLETTE | **Still pending on both** as of 2026-09-08; wrongly marked done earlier that day. Manual re-login by Andrew; verify with `grep user: ~/.config/gh/hosts.yml`. |
| Splitting and rotating the shared token | **Deferred.** One token is installed in five places; a single rotation covers all of them. See `docs/token-rotation.md`. |
| `dev-env` visibility | **Stays public.** Considered and rejected: gitleaks over 67 commits found nothing, there are 0 forks, and going private would spend Actions minutes against the private budget while breaking the calendar event's `blob/main` link. |
| `photo-game-poc` token copy | **Parked.** Its secret predates the 2026-06-29 mint, so it holds an older token with no recorded expiry. The repo is archived and runs nothing. |
| Five retired repo paths | **Support ticket 4729524.** Closed by GitHub 2026-09-04 as self-service-only; reopened after the org's Team upgrade; status requested 2026-09-08, no staff reply. **Not given up on.** The move-list records `twistedmelonman` as an interim shim; flip back and re-run `transfer.sh` if the paths are released. |

## Standing methodology

Two disciplines this project has paid for repeatedly, both worth re-reading
before any audit:

**Resolve the thing; don't match its label.** A name, tag, comment, or count
is a claim about state, not state. This session alone: a ruleset named "Claude
blocking review" that was `enforcement: disabled`; a green 8s CI check that
was a doc-only short-circuit (benign, but only confirmable by reading
per-step conclusions); a code search returning zeros because it never covered
the org where the repos actually lived.

**Validate every fix against a known-bad case.** The design catalogs six
infrastructure defects that report success while doing nothing. A clean
result from an unvalidated check proves nothing — that is precisely how those
six accumulated.

## Key references

| Document | Contents |
| --- | --- |
| `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md` | The backlog itself: every item, the dependency graph, the false-OK catalog |
| `docs/superpowers/specs/2026-09-03-org-migration-design.md` | Org migration design and runbook |
| `docs/token-rotation.md` | Where each `CLAUDE_CODE_OAUTH_TOKEN` copy lives; expiry 2027-06-29. Never contains a token |
| `docs/runbooks/org-migration-rename.md` | Manual UI steps; Part D still pending on two machines |
| `docs/WORKFLOW-DEEP-DIVE.md` | Enforcement layers: hooks, wrappers, CI/CD |
| `scripts/org-migration/` | Snapshot/transfer/verify tooling; 38-test hermetic stub-`gh` suite |
