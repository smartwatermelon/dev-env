# smartwatermelon macOS runner on MIMOLETTE (Tart): design

Status: spike complete 2026-11-17 (results below); design awaiting Andrew's review.
Decisions marked **Open** are not settled by this document.

## Why

On 2026-11-17, GitHub-hosted macOS runners were slow to start or throttled. A
dotfiles `bash-tests` job waited 16 minutes in the queue before it started.
smartwatermelon repos are public, so the minutes are free; the problem is
availability, not cost.

Goal: run smartwatermelon macOS CI on MIMOLETTE, in one Tart VM per job, and
fall back to GitHub-hosted runners when MIMOLETTE is not available.

## Scope

In scope:

- macOS jobs in public smartwatermelon repos. Pilot: dotfiles `bash-tests.yml`.
- A fork guard: a job from a fork never runs on MIMOLETTE (Andrew, 2026-11-17:
  third-party PRs must never run on this server, even from a fork of his code).
- Fallback to `macos-latest` when MIMOLETTE is unavailable.

Out of scope:

- Linux jobs. The NOS Linux runner stays as it is
  (`2026-11-10-nos-self-hosted-runner-design.md`).
- NOS and twistedmelonman repos.
- Moving the Linux runner to the Intel NUC. Deferred by Andrew until this work
  is done.

## Decisions taken (2026-11-17, in chat)

- **Public repos may use the runner (Option A).** This reverses the NOS
  design's private-only rule, for smartwatermelon only, with the protections
  below.
- **Org-level runner**, not repo-level. On the Free plan, smartwatermelon has
  only the Default runner group, so every org repo can target the runner. The
  Default group has "Allow public repositories" on.
- **Fork PRs need approval.** The org fork-PR policy is "Require approval for
  all external contributors". Verified on all 24 public repos.
- **The fork guard is required**, in addition to the approval setting.
- **No exception to the agent GitHub hook.** During spike step 5, Andrew gave
  a one-time OK for the spike's runner calls with the `swm-runner` key only.
  That OK does not carry forward. The agent hook does not change, and every
  agent GitHub call still goes through `gh`. The production supervisor runs
  under launchd, not in an agent session, so the hook never sees its calls
  and needs no exception.

## Architecture

```text
GitHub ──(job queued, label mimolette-macos)──┐
                                              │ outbound HTTPS long-poll
   MIMOLETTE (gui/501)                        ▼
   supervisor (launchd) ── 1 slot: tart clone → tart run → runner --jit → 1 job → tart delete
        │                       job-started hook: deny unless same-repo
        └── pf anchor (root LaunchDaemon): Tart VMs reach the internet only
```

As with the NOS runner, nothing connects to MIMOLETTE from outside.

## Components

### 1. Runner image

- Base: `ghcr.io/cirruslabs/macos-tahoe-base` (macOS 26). GitHub's
  `macos-latest` is `macos-26-arm64` today, so results match. The 27 image
  also fits but is ahead of GitHub. The `macos-runner` image (246 GB
  download) does not fit.
- A local image, built from the base by a reviewed script: the Actions runner
  (osx-arm64, SHA-256 checked) and the fork-guard hook baked in. This removes
  a ~300 MB download from every job. A runner or base version bump is a
  reviewed change.
- VM size: 4 CPUs, 6 GB RAM (`tart set`). The default 8 GB, next to the two
  4 GB Linux slots, would claim all 16 GB.

### 2. Supervisor (MIMOLETTE)

- A launchd job in `gui/501`, the same pattern as the NOS supervisor. Tart
  must run from launchd, not from an ssh shell.
- One slot. Per slot: mint a JIT runner config with the `swm-runner` App, clone
  the image, boot it headless, start the runner with the JIT config (passed on
  stdin, never on argv or in a log), wait for exit, delete the VM.
- Self-checks before each slot: the pf anchor is loaded, the image exists, free
  disk is at least 60 GB on the Tart storage volume.
- Shared code: `github-app.sh` hard-codes the NOS Keychain item. It becomes
  parameterized (item, account) so both supervisors use it.

### 3. Fork guard (job-started hook)

- `ACTIONS_RUNNER_HOOK_JOB_STARTED`, set in the runner's `.env`. GitHub's docs:
  the hook runs after a job is assigned and before it starts, and on a
  non-zero exit "the job will not run and will be marked as failed".
- The script is root-owned and outside the runner directory, as the docs
  require. It reads GitHub's event payload (`GITHUB_EVENT_PATH`), which the PR
  cannot change.
- Fail closed. It allows only:
  - `pull_request` / `pull_request_target` whose head repo equals the base repo;
  - `workflow_run` whose head repo equals the repo;
  - `push`, `workflow_dispatch`, `schedule`, `merge_group`;
  - repos owned by `smartwatermelon`.
  Everything else is denied: forks, a deleted head repo, unknown events,
  `issue_comment`, a missing or unreadable payload, no `jq`.
- It uses the VM's `/usr/bin/jq` (macOS ships jq 1.7.1).
- Tests: 20 cases with crafted payloads; an allow-all stub fails 15 of them.

### 4. LAN block

- Tart VMs use `bridge101`, `192.168.65.0/24`, not the container bridge
  (`bridge100`, `192.168.64.0/24`), so the NOS rules do not cover them.
- The VM's DNS resolver is the host's IPv6 link-local address on the bridge,
  so the Linux rules' `fe80::/10` block would break DNS. The Tart rules pass
  port 53 to the bridge's own addresses first.
- Spike rules (anchor `com.apple/tart-spike`):

  ```text
  table <tart_private> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }
  pass in quick on bridge101 proto { udp tcp } from any to (bridge101) port 53
  block drop in quick on bridge101 inet from any to <tart_private>
  block drop in quick on bridge101 inet6 from any to { fc00::/7, fe80::/10 }
  ```

- The build extends the NOS root pf guard (`scripts/nos-runner/net/`) to load
  a Tart anchor at boot and every 300 s. The NOS rules avoid naming the
  interface because `bridge100` may not exist before the first container; the
  same applies to `bridge101`, so the plan rewrites these rules by source
  address where it can. The IPv6 DNS pass needs a test.

### 5. Storage

- Both disks work. The internal disk has 94 GB free after one image (33 GB).
  The external disk has 1.7 TB free.
- External disk needs:
  - Path `/Volumes/extra-vieille/Caches/tart`. The volume root is
    `root:wheel 775`, so only root can make top-level folders.
  - A one-time **Allow** for `tart` on the removable-volume TCC prompt. Until
    that click, the launchd job hangs with no log (seen in the spike).
  - The grant is keyed to tart's designated requirement (bundle
    `com.github.cirruslabs.tart`, Developer ID team `9M2P8L4D89`), so it
    should survive upgrades. Not proven until a real upgrade.
- **Decided (Andrew, 2026-11-17): the external disk.** `TART_HOME` is
  `/Volumes/extra-vieille/Caches/tart`. The supervisor's self-check must
  catch a TCC hang (a slot that does not start within a time limit) and
  alert. The image copy on the internal disk (33 GB) is no longer needed;
  removing it needs Andrew's OK.
- If the external disk gets too small, both NAS units have a lot of free
  space. Whether Tart can keep its images or VMs on a network share is not
  tested.

### 6. Workflow selection and fallback

- A workflow opts in with
  `runs-on: ${{ vars.SWM_MACOS_RUNNER || 'macos-latest' }}`. Unset means
  GitHub-hosted, so the fail-safe is the default. Org variables reach public
  repos.
- **Decided (Andrew, 2026-11-17): automatic fallback.** The NOS watchdog
  Worker is extended to watch the `mimolette-macos` runner and set
  `SWM_MACOS_RUNNER` when it is down. This needs a smartwatermelon App with
  org Variables write; `swm-runner` has only Self-hosted runners write. The
  plan settles which App that is.

## Credentials

| App | Permissions | Key lives in |
|---|---|---|
| `swm-runner` (App ID 5807971, installation 183107042) | org: Self-hosted runners write | MIMOLETTE login Keychain, item `swm-runner-app-key`, account `smartwatermelon`; also 1Password `Automation/swm-runner` |

The Keychain item was added on 2026-11-17 after a verified backup (65 items in
the backup and the live keychain; 66 after).

## Security

- **Fork PRs.** Three layers, each verified live:
  1. Org approval for all external contributors (24 of 24 repos).
  2. The job-started hook denies fork events before checkout.
  3. A PR opened inside a fork never reaches the org runner (its job stays
     queued).
- **One VM per job.** Nothing carries from one job to the next.
- **LAN.** The VM reaches the internet only (spike step 3).
- **Remaining risk.** A same-repo branch runs on MIMOLETTE without approval.
  Only people with write access can push one, and the same is true on
  GitHub-hosted runners.

## Concurrency and RAM

- Since 2026-11-12, 2 of 7 dotfiles `bash-tests` runs overlapped a kebab-tax CI
  run (queue time widens that count).
- Measured with a 6 GB VM, both Linux slots live and a 2 GB `buildkit` VM:
  - free RAM never below 30%;
  - memory pressure never critical;
  - swap up to 7.6 GB.
- One macOS slot. Apple's licence limit of two macOS VMs per host (not
  verified) does not apply to one slot.
- Moving Linux to the NUC (deferred) would free RAM for a second macOS slot.

## Testing

- Supervisor: bats, with `tart`, `security`, `launchctl` and `curl` stubbed.
  Fully stubbed, so it runs locally.
- Fork guard: the payload tests, plus an allow-all control.
- Live proofs before go-live: a same-repo job passes and logs "allowed"; a fork
  PR is denied at "Set up runner"; a TCC hang is detected and alerted.

## Rollout

1. Build the image, supervisor, hook and pf guard changes, and the watchdog
   fallback.
2. dotfiles `bash-tests.yml` uses `vars.SWM_MACOS_RUNNER`.
3. Measure for 3 days.
4. Other smartwatermelon repos with macOS jobs.

## Undo

Set `SWM_MACOS_RUNNER=macos-latest`, or delete the variable. Every job is back
on GitHub-hosted runners at once.

## Spike results (2026-11-17)

Scratch files: `~andrewrich/.local/state/tart-spike/` on MIMOLETTE.

### Step 1: pull — PASS

`macos-tahoe-base` (macOS 26.6.2, Homebrew 7.0.12): 27 GB download, 33 GB on
disk, sparse 50 GB VM disk. Tart 2.41.1; licence FSL-1.1-ALv2 (read from the
copy on MIMOLETTE), which permits internal use with no size limit.

### Step 2: boot under launchd — PASS

A temporary LaunchAgent in `gui/501` runs `tart run spike-1 --no-graphics`.
The VM has an IP within 2 minutes; `tart exec` runs commands with no ssh.
Lesson: `tart exec -i ... sh -s` with `brew` inside reads the rest of the
script from stdin; copy scripts into the VM first.

### Step 3: LAN block — PASS

| Probe from the VM | No rules | With rules |
|---|---|---|
| https api.github.com, registry.npmjs.org | open | open |
| DNS through the VM resolver, new names | open | open |
| router `10.0.15.1:80` | open | blocked |
| DNS `192.168.0.1` UDP and TCP | open | blocked |
| MIMOLETTE ssh `10.0.15.63:22` | open | blocked |
| host `192.168.65.1:22`, container bridge `192.168.64.1:22` | open / blocked | blocked |

ICMP from the VM fails even with no rules, so the probes use TCP and UDP. The
anchor is still loaded at the time of writing; flushing it needs sudo.

### Step 4: RAM, idle workload — PARTIAL

Min free 34%, swap 4.9 to 6.6 GB, no critical pressure. The suite did not run:
`run-tests.sh` refuses the full suite to agents. Step 5 measured the real job.

### Step 5: JIT runner and a real job — PASS

- JIT config from `POST /orgs/smartwatermelon/actions/runners/generate-jitconfig`,
  `runner_group_id` 1, label `tart-spike`.
- dotfiles draft PR #505 (closed, never merged): `bash-tests` passed in 214 s.
  GitHub-hosted median: 281 s (19 recent runs, range 177 to 347 s).
- Same-repo re-run with the hook: passed; log shows
  `job-started hook: allowed pull_request in smartwatermelon/dotfiles`.
- Fork PR #506 from `twistedmelonman/dotfiles`: failed at "Set up runner" with
  `DENIED: pull_request: head 'twistedmelonman/dotfiles' is not 'smartwatermelon/dotfiles' (fork PR)`;
  checkout and every later step skipped.

### Step 6: external disk — PASS after one Allow

- launchd `tart pull` with `TART_HOME` on the external disk logged
  `AUTHREQ_PROMPTING ... kTCCServiceSystemPolicyRemovableVolumes` and hung
  until Andrew clicked Allow on MIMOLETTE's screen.
- It then failed to create `/Volumes/extra-vieille/tart` (volume root is
  `root:wheel 775`). With `/Volumes/extra-vieille/Caches/tart`, pull, clone
  and run all worked under launchd with no further prompt.
- The image is now on both disks (33 GB internal, 30 GB external); the plan
  removes the copy it does not use.
