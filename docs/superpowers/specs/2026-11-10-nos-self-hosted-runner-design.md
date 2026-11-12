# NOS self-hosted runner on MIMOLETTE: design

Status: design approved in chat 2026-11-10; spec awaiting Andrew's review.

## Why

nightowlstudiollc (NOS) is on GitHub Team, with about 3,000 included Actions
minutes a month. Private repos on GitHub-hosted runners bill against that
quota. Public repos are free and stay where they are.

From 2026-11-01 to 2026-11-10, NOS private repos used 3,275 minutes. About
2,920 of them counted against the quota (Dependabot update jobs do not). The
projection, after the 2026-11-10 savings (kebab-tax#1542, kebab-tax-netlify#382,
kebab-tax#1544), is still about 8,700 minutes a month: about 3x quota.
kebab-tax alone used 2,097 minutes (64%). Per-job rounding (every job bills at
least 1 minute) was 38% of kebab-tax's billed minutes.

Goal: move NOS private Linux CI onto MIMOLETTE, so billed minutes drop well
under quota, with CI no less reliable than today.

## Scope

In scope:

- Linux jobs in NOS private repos. Pilot: kebab-tax `ci.yml`.
- A watchdog that moves CI back to GitHub-hosted runners when MIMOLETTE is
  unavailable.
- A `runner` input on the shared reusable workflows in
  `smartwatermelon/github-workflows`.

Out of scope:

- Public repos (free on GitHub-hosted runners).
- macOS jobs. Possible later work: macOS runners in Tart VMs on MIMOLETTE.
- Production deploy jobs (for example kebab-tax `deploy-workers.yml`). They
  stay on GitHub-hosted runners, where their secrets have always lived.

## MIMOLETTE facts (read-only survey, 2026-11-10)

- Apple M4, 10 cores, 16 GB RAM, macOS 27.2.1. Load about 1.2.
- 155 GB free on the internal disk; 1.7 TB free on `/Volumes/extra-vieille`.
- Apple `container` 1.7.1, installed by Homebrew (`sh.brew.container`). The
  apiserver runs in the `gui/501` launchd domain. Over SSH,
  `container system status` reports "not running" while `container ls` works,
  so the supervisor must run in the GUI login's launchd domain.
- Default container: 4 CPUs, 1 GB RAM. Job VMs need more RAM (see below).
- Podman 6.1.4 and Tart 2.41.1 are also installed; not used by this design.

## Architecture

```text
GitHub ──(job queued, label mimolette)──┐
   ▲                                    │ outbound HTTPS long-poll
   │                                    │
   │   MIMOLETTE (gui/501)              ▼
   │   supervisor (launchd) ── slot 1: container run --rm  → runner --jit → 1 job → exit
   │        │                └ slot 2: container run --rm  → runner --jit → 1 job → exit
   │        └── self-check fails / shutdown → NOS_RUNNER=ubuntu-latest + 1 ntfy
   │
   └── Cloudflare Worker (cron, every 10 min): reads runners + queued jobs,
       sets NOS_RUNNER, re-runs stuck jobs, 1 ntfy per state change
```

Nothing connects to MIMOLETTE from outside. The runner opens outbound HTTPS to
GitHub. The Worker talks only to the GitHub API. ntfy alerts go outbound. The
design opens no inbound ports, port forwards or tunnels. ASIAGO is not needed
at runtime.

## Components

### 1. Runner image

- Ubuntu 24.04, arm64, with the GitHub Actions runner, git, curl, jq, unzip,
  ca-certificates and build-essential. Built on MIMOLETTE with
  `container build`.
- Apple `container` runs arm64 Linux. GitHub's `ubuntu-latest` is x86_64.
  Node and Jest work on arm64; any native npm package without an arm64 build
  is a pilot failure to fix or to keep on GitHub-hosted runners.
- The image is rebuilt from the definition in this repo; a runner version
  bump is a reviewed change.

### 2. Supervisor (MIMOLETTE)

- A launchd job in `gui/501` keeps 2 slots. Two concurrent jobs fit 16 GB
  with headroom; each job VM gets 4 CPUs and 4 GB RAM (tunable).
- For each slot: mint a just-in-time (JIT) runner config with the `nos-runner`
  App, then `container run --rm` the image with that config. The runner takes
  exactly one job, exits, and the VM is deleted. Then the slot starts again.
- Job VMs get no shared folders, no host mounts and no Keychain access. Code
  enters by `actions/checkout` only.
- Runner label: `mimolette`. Runner group: must not allow public repos
  (verified, not assumed).
- Self-checks each loop: `container` apiserver answers, the image exists,
  free disk is at least 20 GB, and a slot started within its last 3 tries.
  On failure: set `NOS_RUNNER=ubuntu-latest` and send one ntfy alert, only if
  the variable was not already `ubuntu-latest`.
- On a clean shutdown (SIGTERM to the launchd job), set
  `NOS_RUNNER=ubuntu-latest` before exiting.
- The supervisor only ever switches the fleet to GitHub. It never sets
  `NOS_RUNNER=mimolette`.

### 3. Watchdog (Cloudflare Worker)

- Cron trigger every 10 minutes. Cost is prioritized over fast switching.
- Busy is not down. GitHub queues `mimolette` jobs until a slot is free (up
  to 24 hours, unbilled), so a long queue alone never triggers fallback.
  Unhealthy means any one of:
  - no `mimolette` runner is online;
  - a job has waited for a `mimolette` runner for more than 20 minutes
    while a `mimolette` runner is online and idle (a runner that takes no
    work);
  - jobs are queued, every runner is busy, and the set of busy runner names
    has not changed for 3 checks (about 30 minutes; config value). Each job
    gets a new runner name, so an unchanged set means the slots are hung.
- During a burst, CI waits on MIMOLETTE instead of moving to paid minutes.
  The trade is time: 20 PRs x 3 jobs x about 5 minutes on 2 slots is about
  2.5 hours of queue. Slots stay at 2 for now.
- Unhealthy for 2 checks in a row (about 20 minutes): set
  `NOS_RUNNER=ubuntu-latest`, cancel the stuck jobs and re-run them, and send
  one ntfy alert, only if the Worker changed the variable.
- Healthy for 2 checks in a row while `NOS_RUNNER=ubuntu-latest`: set
  `NOS_RUNNER=mimolette` and send one "recovered" ntfy alert.
- The Worker is the only writer of `NOS_RUNNER=mimolette`. With the supervisor
  only writing `ubuntu-latest`, the two never fight.
- Consecutive-check state lives in Workers KV or in the variable value itself
  (decided in the plan; whichever the free plan allows most simply).
- Each outage produces exactly one "down" alert and one "recovered" alert.

### 4. Workflow selection

- Every Linux job in a NOS private repo uses
  `runs-on: ${{ vars.NOS_RUNNER || 'ubuntu-latest' }}`. Unset or empty means
  GitHub-hosted: the fail-safe is the default.
- Reusable workflows (`standards-check`, `dependabot-auto-merge`, `semgrep`)
  get a `runner` input, default `ubuntu-latest`. NOS private callers pass
  `${{ vars.NOS_RUNNER }}`; public callers pass nothing and do not change.
- Exceptions stay on `ubuntu-latest` or macOS: macOS jobs and production
  deploys.

## Credentials

Two GitHub Apps, one key each, each key in one place. Andrew creates both in
the GitHub UI and installs them on nightowlstudiollc only.

| App | Permissions | Key lives in |
|---|---|---|
| `nos-runner` | org: Self-hosted runners write, Variables write | MIMOLETTE login Keychain |
| `nos-runner-watchdog` | org: Self-hosted runners read, Variables write; repos: Actions write | Worker secret |

- Keychain rule: back up and verify the MIMOLETTE login Keychain before
  adding the key, and verify after.
- A leaked key reaches only that App's permissions.

## Security

- Private repos only. A public repo on this runner would let a fork PR run
  code on MIMOLETTE.
- One VM per job: no state, files or processes carry from one job to the
  next.
- LAN exposure is the one new risk. Dependabot PRs run third-party
  `npm install` scripts. On MIMOLETTE that code could reach the LAN, including
  ROMANO (VPN, DNS). Job VMs must block private address ranges (RFC 1918,
  link-local, and the LAN's IPv6 ranges) and allow only internet egress. It
  is not yet verified that Apple `container` networking can enforce this.
  **The runner does not go live until it does.**

## Deployment

- Code lives in dev-env:
  - `scripts/nos-runner/`: supervisor, image definition, launchd plist,
    install script.
  - `workers/nos-runner-watchdog/`: the Worker.
- Updates arrive by merge: a launchd job on MIMOLETTE pulls dev-env `main`
  every 10 minutes and installs from it (the claude-config deploy pattern).
  No SSH is needed for updates.
- First install: one command Andrew runs on MIMOLETTE.
- The Worker, its cron trigger and its secret are deployed through the
  Cloudflare API by the agent. Andrew does not use the Cloudflare UI.
- Build-phase SSH: the spike runs over SSH from ASIAGO. Every change on
  MIMOLETTE needs Andrew's OK first.

## Spike (throwaway; before any build)

1. Can Apple `container` block job VMs from private LAN addresses?
2. Does the Actions runner work in an Apple `container` arm64 VM, and does
   kebab-tax `ci.yml` pass there?
3. Does a re-run of a cancelled job read the new value of `NOS_RUNNER`?
4. Do the free Workers plan's limits (cron, subrequests per run, KV) cover
   about 15 GitHub API calls every 10 minutes?

A "no" on 1 or 2 stops the design and comes back to Andrew.

## Testing

- Supervisor: bats, with `container`, `gh`, `security` and `launchctl` all
  stubbed. Fully stubbed, so it runs locally inside the sandbox.
- Worker: unit tests with a stubbed `fetch` and clock: healthy, one miss,
  two misses, recovery, already switched (no second alert), stuck-job
  re-run.
- Full suites run in CI as required checks.

## Rollout

1. Spike.
2. Build the image, supervisor and Worker.
3. kebab-tax PR: `ci.yml` jobs use `vars.NOS_RUNNER`.
4. Measure for 3 days.
5. Other kebab-tax workflows, then the reusable workflows' `runner` input,
   then the other NOS private repos.

## Success

- kebab-tax CI bills close to 0 GitHub-hosted minutes.
- Its jobs take no more than about 1.5x as long as on GitHub-hosted runners.
- A MIMOLETTE outage moves CI to GitHub on its own and sends exactly one
  alert.

## Undo

Set `NOS_RUNNER=ubuntu-24.04` (a manual hold). Every job is back on
GitHub-hosted runners at once. `ubuntu-latest` or an unset variable is
not a lasting undo: the watchdog moves either back to `mimolette`. See
the runbook, section 6.

## Spike results

### Q1: LAN blocking — PASS (2026-11-10)

- `container` 1.7.1 has no egress filter; `network create --internal` is host-only (no internet). pf is the method.
- Job VM: `192.168.64.2/24` on host `bridge100` (`192.168.64.1`), default route and DNS via `192.168.64.1`.
- MIMOLETTE LAN `10.0.12.0/22` (router `10.0.15.1`); host DNS `192.168.0.1`, `149.112.112.112`. pf was already enabled.
- Baseline (no rules): the VM reached the router (HTTP and ping) and `192.168.0.1` (ping).
- Rules, loaded as anchor `com.apple/nos-runner-spike` (evaluated through `anchor "com.apple/*"` in `/etc/pf.conf`, no edit needed):

  ```text
  table <nos_private> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }
  pass in quick on bridge100 proto { udp tcp } from 192.168.64.0/24 to 192.168.64.1 port 53
  block drop in quick on bridge100 inet from 192.168.64.0/24 to <nos_private>
  block drop in quick on bridge100 inet6 from any to { fc00::/7, fe80::/10 }
  ```

- With rules: `https://api.github.com` and `https://registry.npmjs.org` OK; DNS through the gateway resolves; router HTTP/ping, `192.168.0.1` ping and DNS (UDP and TCP), host `10.0.15.63:22` all blocked. Host SSH unaffected.
- Probe lesson: `dig +short | grep -q .` matches dig's own error text; check for an address (`grep -qE '^[0-9]'`).
- Anchor rules do not survive a reboot. The build needs a root LaunchDaemon (installed once by Andrew with sudo) that loads the anchor at boot, and the supervisor's self-check must confirm the anchor is loaded before starting any slot.
- Teardown done: anchor flushed, pf enable token released, container removed.

### Q2: runner in an arm64 Apple container VM — PASS (2026-11-10)

- Image: Ubuntu 24.04 arm64, Actions runner v2.338.2 (linux-arm64 tarball, SHA-256 `670adb2f…de945` checked), packages git, curl, jq, unzip, ca-certificates, build-essential, sudo, libicu74, **python3**, **gnupg**. Runs as user `runner` with passwordless sudo.
- JIT config minted with the `nos-runner` App (`POST /orgs/nightowlstudiollc/actions/runners/generate-jitconfig`, group 1, label `mimolette`). Runner group 1 "Default": `allows_public_repositories=false`.
- Run with `container run -d --rm -c 4 -m 4g <image> --jitconfig <jit>`, pf LAN block loaded. The runner connected, took one job, exited; `--rm` removed the VM.
- kebab-tax draft PR #1545 (closed unmerged), `test-mobile` on `runs-on: mimolette`:
  1. Failed in `npm ci`: `better-sqlite3` has no linux-arm64 prebuild for Node 26, so node-gyp builds it and needs `python3`. Fixed in the image.
  2. All test steps passed; `codecov-action` failed for missing `gpg`. Fixed in the image (`gnupg`).
  3. Green. Steps took 101 s (job 116 s including runner cleanup), against a GitHub-hosted median of 200 s (p90 237 s, 162 runs since Oct 25).
- Lesson: each tool GitHub's image ships that a job uses must be in our image; expect more of these as other workflows move (Task 11 follow-up).
- Teardown done: PR closed and branch deleted, pf anchor flushed and token released, spike image removed. The `buildkit` builder VM (2 CPUs, 2 GB) is still running.

### Q3: re-run reads the new variable value — PASS (2026-11-10)

- Org variable `SPIKE_RUNNER` (visibility private) set by the `nos-runner` App: create HTTP 201, update HTTP 204, delete HTTP 204. The App's org Variables permission is enough.
- reliquarist draft PR #128 (closed unmerged), job `runs-on: ${{ vars.SPIKE_RUNNER || 'ubuntu-latest' }}`, with `SPIKE_RUNNER=no-such-label`: the job stayed queued.
- Set `SPIKE_RUNNER=ubuntu-latest`, cancelled the run (completed/cancelled within about 10 s), then `rerun-failed-jobs`: attempt 2 ran on a GitHub-hosted runner (`GitHub Actions 1000014253`, image `ubuntu-26.04`) and passed.
- So the Worker's cancel, then re-run, moves stuck jobs to GitHub. The cancel completes fast enough that the re-run can be in the same tick after a short poll; the plan's "re-run on a later tick" also works.
- The agent App cannot set variables on smartwatermelon/dev-env (HTTP 403), so the test used the real mechanism instead.

### Q4: Workers free plan limits — PASS with constraints (2026-11-10)

From developers.cloudflare.com (Workers limits and KV pricing pages, read 2026-11-10):

- 50 external subrequests per invocation; 10 ms CPU per Cron Trigger run; 5 Cron Triggers per account; 100,000 requests a day.
- KV: 100,000 reads a day, 1,000 writes a day, 1 write per second to the same key.
- Fit: 144 runs a day. One `state` KV write per run (144 a day) plus the token cache fits 1,000.
- Constraints for Task 7:
  - Budget at most 40 subrequests per run (headroom under 50).
  - Fetch jobs only for the oldest queued run in each repo.
  - Cache the installation token in KV (`expirationTtl` 3000 s; tokens last 1 hour), so most runs skip the RS256 signing and stay under 10 ms CPU.
