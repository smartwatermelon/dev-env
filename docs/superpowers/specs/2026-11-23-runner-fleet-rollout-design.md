# Fleet rollout of the MIMOLETTE runners (draft)

**Status: draft, 2026-11-23. D1 (A+C), D2 (B), D3 (A), D4 (out of scope), D5 (A), D6 (A), D7 (A) and D8 (A, standing rule) decided. Part 1 plan: `docs/superpowers/plans/2026-11-23-runner-fleet-rollout-part1.md`.**

## Goal

Andrew's request (2026-11-23): roll the MIMOLETTE runners out broadly. That means
templates, defaults, and every non-fork, non-archived repo in `twistedmelonman`,
`smartwatermelon` and `nightowlstudiollc`. Also improve or design the features
the open GitHub issues name.

Prior work this builds on:

- `docs/superpowers/specs/2026-11-10-nos-self-hosted-runner-design.md` (NOS Linux runner, live)
- `docs/superpowers/specs/2026-11-17-swm-macos-tart-runner-design.md` (swm macOS runner, plan part 1 live)
- memory `project-self-hosted-everywhere`: the NOS spec's exclusions need fresh decisions.

## State, measured 2026-11-23

### Runners

| Runner | Owner | Label | Slots | Repos allowed | Selector | Fallback |
|---|---|---|---|---|---|---|
| NOS Linux (Apple `container` VMs) | nightowlstudiollc org | `mimolette` | 2 | private only (`allows_public_repositories=false`) | org var `NOS_RUNNER=mimolette`, visibility `private` | `nos-runner-watchdog` Worker |
| swm macOS (Tart VMs) | smartwatermelon org | `mimolette-macos` | 1 | any; fork guard in job-started hook | `SWM_MACOS_RUNNER` (planned) | none yet: plan part 2 not written |
| swm Linux | none | none | 0 | none | none | none |
| twistedmelonman | none | none | 0 | none | none | none |

### Workflows that target a runner today

- kebab-tax only: `ci.yml`, `release-gate.yml`, `release-notes-sync.yml`, one
  job of `deploy-workers.yml`. Two other `deploy-workers.yml` jobs and
  `publish-changelog.yml` stay on `ubuntu-latest`.
- github-workflows `standards-check.yml` has a `runner` input. No other
  reusable workflow has one.
- No workflow on any `main` targets `mimolette-macos`.

### Fleet inventory

39 repos listed (25 swm, 14 NOS). twistedmelonman could not be listed: the
agent has no App route there (see Permissions).

| Kind | Count | Notes |
|---|---|---|
| Callers of `standards-check.yml` | 39 | every repo |
| Callers of `dependabot-auto-merge.yml` | 39 | carries the merge App secrets |
| Callers of `semgrep-scan.yml` | 10 | |
| Callers of `netlify-site-checks.yml` | 7 | |
| Repo-local jobs on `ubuntu-latest` | about 45 | tests, lint, builds, deploys, Pages, monitors |
| Repo-local jobs on `macos-latest` | 4 | dotfiles `bash-tests`, homebrew-tap `test-casks`, mac-server-setup `bats`, stupid-github-app `ci` (one job) |

Raw data: scratchpad `inv.out` and `runs.out` for this session (not kept).
Re-measure before acting.

### Load, 2026-11-16 to 2026-11-23

2,097 workflow runs (not jobs). The largest: dev-env 892 (672 of them are the
15-minute site monitor), kebab-tax 346, claude-config 181, dotfiles 90,
kebab-tax-netlify 88, mac-server-setup 71. Every other repo had 60 or fewer.
Job counts and minutes are not measured yet; the capacity decision needs them.

## Job classes

Not every job is a test. Each class needs its own decision.

1. **Test, lint, build.** No secrets. This is the rollout's core.
2. **Gate jobs with secrets.** `dependabot-auto-merge` (merge App key) and
   standards-check (no secrets, but it is the required check).
3. **Deploys and releases.** kebab-tax worker deploys, spokane-snow Pages,
   archive-resolver release, Netlify checks. These carry production secrets.
4. **Monitors and digests.** dev-env site monitor and Dependabot digest. These
   must keep working when MIMOLETTE is down, since they report that.

## Prerequisites the rollout cannot skip

1. **swm macOS plan part 2.** It covers the watchdog Worker, the
   `swm-runner-watchdog` App, re-runs after a restart, and the dotfiles pilot
   switch. Without a fallback, a required macOS check waits forever when
   MIMOLETTE is off (dev-env#252).
2. **A Linux runner for public repos (swm, and NOS public).** It does not
   exist. The NOS runner group refuses public repos on purpose: a fork PR
   would run code on MIMOLETTE. A public Linux runner needs the swm fork
   guard (job-started hook, fail-closed) in the Linux image, plus its own
   watchdog. Alternatively, public Linux jobs stay hosted (D1).
3. **The stuck-slot gap (dev-env#297).** At fleet scale, one slot that stops
   getting jobs halves Linux capacity until a human sees it. Fix it before
   adding load.
4. **A `runner` input on every reusable workflow** in github-workflows that a
   class-1 caller uses. After D2 and D3 that is semgrep-scan only
   (standards-check has one). dependabot-auto-merge stays hosted (D2) and
   netlify-site-checks is class 3 (D3). Released canary first.
5. ~~twistedmelonman access~~: dropped by D4.

## Decisions for Andrew

**D1. Public Linux jobs (smartwatermelon and NOS public repos). DECIDED
2026-11-23: A+C.**

Andrew's goal: every job he, his agent Apps or Dependabot triggers runs on
MIMOLETTE, Linux and macOS, because GitHub-hosted PR runs are slow. No one
else's code runs on his infrastructure. Three layers:

1. **Routing (C).** Workflows select MIMOLETTE for pushes and same-repo PRs.
   Fork PRs select a GitHub-hosted runner. Same-repo PRs come from people
   with write access. **Correction (measured 2026-11-23):** that is only
   Andrew in 37 of 39 repos, but `nightowlstudiollc/amelia-boone` also has
   `arboone` and `nightowlstudiollc/tnjcleaning` has `tandjscleaningpf`
   (client accounts, push access). See D8.
2. **Runner guard (A).** A Linux runner pool for public repos, with the macOS
   runner's job-started fork guard (fail-closed) in its image. Routing alone
   is not enough: a fork PR can edit the workflow to name the self-hosted
   label.
3. **Fork-PR approval (live).** Every external contributor's run needs
   Andrew's approval (24/24 public swm repos, 2026-11-17). The NOS public
   repos are to be checked.

Consequence: Dependabot runs locally too, which makes D2 more pressing.

Options as offered:

- A. Build a Linux runner for public repos with the macOS runner's fork
  guard. Most jobs move, but it is new work and a new attack surface.
- B. Keep public Linux jobs on GitHub-hosted runners. They are free. Only
  private NOS and macOS jobs move. This is a small rollout.
- C. Run public Linux jobs on MIMOLETTE only for push to `main` and for PRs
  from branches in the same repo. Fork PRs go to hosted runners, chosen in the
  workflow. The workflow-level selection is less proven than a hook.

**D2. Capacity. DECIDED 2026-11-23: B now, C later.** Workflows route
`dependabot[bot]` runs to GitHub-hosted runners; nobody waits on them, since
they auto-merge. Andrew's and his agents' runs get the local slots. Later
("later-ish"): an Intel NUC7i5BNH as the Linux host. Its RAM and whether its
internal storage is an SSD are unknown; check before designing that step.
This also means the `dependabot-auto-merge` gate (class 2, merge App secret)
stays hosted, since it runs on Dependabot PRs.

Original framing: 2 Linux slots and 1 macOS slot share 16 GB. The NOS spec
computed 2.5 hours of queue for one kebab-tax Dependabot burst. Fleet-wide
Dependabot bursts arrive together each morning. Options: accept queueing,
keep Dependabot runs hosted, or bring the Intel NUC in as a Linux host (the
NUC was deferred "until this work is done").

**D3. Which job classes move. DECIDED 2026-11-23: A.** Only class 1 (tests,
lint, build, standards-check) moves. Deploys, releases, monitors and
digests stay GitHub-hosted. The kebab-tax `deploy-workers.yml` job that uses
`NOS_RUNNER` today moves back to hosted (Andrew did not ask to keep it;
confirm in that PR).

Original framing: Class 1 is assumed yes. Class 2: the merge
App secret would sit on a runner shared with other jobs. Class 3: production
secrets on MIMOLETTE. Class 4: should stay hosted, so it still reports when
MIMOLETTE is down.

**D4. twistedmelonman. DECIDED 2026-11-23: out of scope.** Andrew: "There is
nothing applicable there." No App install, no route, no runner. Prerequisite
5, phase 7 and adjustment 1 below are dropped.

Original framing: Is it in scope, which repos, and does it get an
agent App installation? GitHub lets a personal account register runners per
repo only, with no account-level runner or variable (to be verified). The
one-variable switch does not carry over there.

**D5. One selector or many. DECIDED 2026-11-23: A.** One variable per pool
(`NOS_RUNNER`, `SWM_MACOS_RUNNER`, new `SWM_RUNNER`), and one watchdog Worker
for all pools: `nos-runner-watchdog` generalized, with separate state per
pool and each org's App key (the `swm-runner-watchdog` App from the macOS
spec is still needed). Fixes for dev-env#297 and dev-env#298 apply to every
pool. Each `runs-on` checks fork and Dependabot first (D1, D2), then reads
its pool's variable, then falls back to the hosted label.

Original framing: Today each pool has its own variable
(`NOS_RUNNER`, planned `SWM_MACOS_RUNNER`). A Linux swm pool adds a third.
Keep one per pool with one watchdog each, or have one watchdog Worker
manage all pools.

**D6. Templates and defaults. DECIDED 2026-11-23: A.**

1. smartwatermelon `repo-template`, `new-smartwatermelon-repo.sh` and both
   orgs' `workflow-templates` emit the routing `runs-on` by default.
2. A NOS template or bootstrap script (dev-env#264) is in this project.
3. standards-check warns (does not fail) on a job that names
   `ubuntu-latest` or `macos-latest` directly without an exemption comment.
   Deploys and monitors (D3) carry that comment.

Original framing: For new repos: does repo-template, the org
`workflow-templates` and `new-smartwatermelon-repo.sh` emit
`runs-on: ${{ vars.<POOL> || '<hosted>' }}` by default? NOS has no template
at all (dev-env#264); is building one part of this project?

**D7. The 4 public NOS repos. DECIDED 2026-11-23: A.** The existing NOS pool
serves them. The fork guard (`scripts/swm-macos-runner/guest/job-started.sh`)
goes into the NOS image with `ALLOWED_OWNERS=nightowlstudiollc`, the runner
group allows public repos, and `NOS_RUNNER` becomes visible to those repos.

**Why a fork cannot remove the guard** (Andrew asked, 2026-11-23): the hook
is in the VM image, not the repo. `install-runner.sh` writes
`ACTIONS_RUNNER_HOOK_JOB_STARTED` into the runner's own `.env`, and the runner
runs it before the first step. A fork PR controls its workflow file and
code, so it can name the self-hosted label. It cannot change the runner's
environment or skip the hook. The guard reads the event payload, which comes
from GitHub, not from the fork. The drill (dotfiles#511) proved a denied hook
stops the job.

The risk that remains is a bug in the guard's own logic. It fails closed: an
unknown event, a missing field or a missing `jq` all deny. Fork-PR approval
(layer 3) is a second barrier in front of it. The plan must add the guard's
tests for each pool that uses it, and repeat the fork drill on each pool.

**D7 implementation note.** Both writers of `NOS_RUNNER` send
`"visibility":"private"`: the supervisor's `VAR_BODY` (`supervisor.sh:25`)
and the watchdog (`workers/nos-runner-watchdog/src/github.js:122`). Each
write would hide the variable from the public repos again, which would then
silently run hosted. Part 4 must change both writers, and any runbook
`gh variable set` command, to the new visibility.

**D8. Outside writers. DECIDED 2026-11-23: A, as a standing rule.** Two
public NOS client repos give a client account push access. A same-repo
branch from that account passes the fork guard and would run on MIMOLETTE.

- amelia-boone and tnjcleaning stay on GitHub-hosted runners.
- Standing rule (Andrew): assume the same for every client site, now and
  in the future. Any repo where an account other than `twistedmelonman`
  has push access stays hosted.
- Re-measure collaborators before parts 4 and 5.
- Part 6 makes it checkable: client-site templates default to hosted, and
  the standards-check drift warning does not flag them. The digest flags
  any repo that targets a pool while an outside account has push access.

## Draft phases (after D1 to D7)

1. Fix the existing pools: dev-env#297 (stuck slot), dev-env#298 (check now
   after a manual fix), the still-valid items of dev-env#294.
2. swm macOS plan part 2: the watchdog and the dotfiles pilot. Then
   homebrew-tap and mac-server-setup.
3. github-workflows: a `runner` input on semgrep-scan (see prerequisite 4),
   released canary first.
4. NOS private repos: switch the class-1 jobs repo by repo. These repos
   already reach `NOS_RUNNER`.
5. Per D1: the public Linux pool, or nothing.
6. Templates and defaults (D6), including the NOS template (dev-env#264).
7. ~~twistedmelonman~~: dropped by D4.
8. STATUS.md update, folded into a phase PR rather than a standalone one.

Each repo switch is one PR per repo. Andrew said he was satisfied with the
trial, so no pilot gate is planned before phase 4. The digest should then
report which repos target a runner, so drift is visible.

## Related open issues

| Issue | Fit |
|---|---|
| dev-env#297 stuck NOS slot | phase 1, prerequisite |
| dev-env#298 watchdog check-now | phase 1 |
| dev-env#294 macOS part 1 minor findings | phase 1 or 2 |
| dev-env#252 macOS jobs to a VM | closed by phase 2 |
| dev-env#264 NOS repo template | phase 6 |
| dev-env#277 sandbox escapes | affects how agents reach MIMOLETTE; see below |
| dev-env#236 autoMode overlay check | passive; denials during rollout are its data |

## Permissions: what the rollout's actions need

These are observed facts only. "Untested" means no call has been seen.
Nothing below predicts the auto-mode classifier.

| Action | Acting identity | Evidence | Status |
|---|---|---|---|
| List or read twistedmelonman repos | agent App | gh wrapper: "no gh-app-routes.conf line matches" | **blocked**: needs an App install + route (D4) |
| Read smartwatermelon org Actions variables | smartwatermelon-agent App | `GET orgs/smartwatermelon/actions/variables` returned 403 | **blocked**: grant Variables read, or Andrew sets/reads them |
| Read nightowlstudiollc org variables | nightowlstudiollc-agent App | returned `NOS_RUNNER` | allowed |
| Edit `.github/workflows/*` and open PRs | agent Apps | earlier rollout PRs merged (kebab-tax#1555); runbook notes the agent Apps hold Workflows write | allowed |
| `git worktree add` per repo (about 40 repos) | sandbox | `.git/worktrees` is read-only in the sandbox; each add runs unsandboxed after a prompt | **prompts each time**; dev-env#277 step 6 would turn these prompts into failures |
| Change files on MIMOLETTE over ssh | Andrew's admin login | denial "Remote Shell Writes" (2026-10-26, TILSIT); every MIMOLETTE change needs Andrew's OK (memory) | Andrew runs it, or an allow rule naming the supervisor install |
| Read MIMOLETTE state over ssh | `agentro` | dev-env#281 built for this | allowed (read-only) |
| Move a release tag (github-workflows canary) | agent | denials "Git Destructive" on 2026-10-30 and 2026-11-03 | **denied before**; Andrew runs it, or a narrow allow rule |
| Loops of `gh` calls across the fleet | agent | denials "Command Network Lists" (2026-11-02) | **denied before** for some loops; this session's read-only loops ran with no denial |
| Deploy a watchdog Worker | Cloudflare API | runbook: deploy by hand | Andrew, per runbook |
| `gh secret set`, `security add-generic-password`, `launchctl bootstrap`, `sudo` | agent | `ask` rules in `machine-settings/base.json` | prompts; Andrew batches sudo (memory) |
| Write a secret to 1Password or ntfy setup | agent | denial "Secret-Store Writes" (2026-11-12) | **denied before** |

Candidate adjustments, for Andrew to choose:

1. ~~Install an agent App on twistedmelonman~~: dropped by D4.
2. Give `smartwatermelon-agent` org Variables **read** (not write); the
   watchdog App holds the write.
3. Add one autoMode `allow` rule for `git worktree add/remove` under
   `~/Developer/*/.claude/worktrees/`. Alternatively, add the path to the
   sandbox `allowWrite` if a narrow form is possible: only this session's
   worktrees are writable today. Do this before dev-env#277 step 6 lands.
4. Leave tag moves, MIMOLETTE writes, secret writes and Worker deploys with
   Andrew. Group them into one command block per phase.

## To verify before the plan

- That personal accounts support repo-level runners only, with no
  account-level variables (GitHub docs).
- Job counts and minutes per repo, for D2.
- Whether GitHub runs a Dependabot PR's `pull_request` jobs on self-hosted
  runners the same as other PRs.
- How many of the 4 `macos-latest` jobs need macOS, and how many are on
  macOS by habit (stupid-github-app's matrix).
