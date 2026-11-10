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
- Healthy means both:
  - at least one `mimolette` runner is online (idle or busy), and
  - no job has waited for a `mimolette` runner for more than 20 minutes.
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

Set `NOS_RUNNER=ubuntu-latest`, or delete it. Every job is back on
GitHub-hosted runners at once.
