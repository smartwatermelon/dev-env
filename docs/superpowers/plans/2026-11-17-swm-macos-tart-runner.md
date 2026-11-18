# smartwatermelon macOS Tart Runner Implementation Plan (part 1: runner)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run smartwatermelon macOS CI jobs on MIMOLETTE, one Tart VM per job,
with a fork guard and a LAN block. The org variable stays unset, so every job
stays on GitHub-hosted runners until part 2 (the watchdog) is live.

**Architecture:** A launchd supervisor in `gui/501` keeps one slot. Each slot
mints a JIT runner config with the `swm-runner` App, clones a local runner image
built from a pinned base, boots it headless, hands the JIT config to the guest on
stdin, waits for the one job, and deletes the VM. The NOS root pf guard gains an
independent Tart anchor with its own ok files.

**Tech Stack:** bash (`/bin/bash` 3.2 on MIMOLETTE and in the guest), openssl,
curl, jq, Tart 2.42.0, launchd, pf.

**Spec:** `docs/superpowers/specs/2026-11-17-swm-macos-tart-runner-design.md`

**Part 2** (a separate plan, written after this one): the watchdog Worker
deployment, the `swm-runner-watchdog` App, the dotfiles pilot switch, and an
automatic re-run (at most once per job) of a job stopped by a runner restart
(Andrew, 2026-11-17). The watchdog finds those jobs from GitHub data alone;
how GitHub marks a job whose runner was stopped is not yet known and is
proven live in part 2.

## Decisions this plan makes

Each is open to veto at plan review.

1. **New code goes in `scripts/swm-macos-runner/`.** `scripts/nos-runner/`
   changes only where named (Tasks 1 and 3), so the NOS updater reinstalls
   only for those two tasks.
2. **The supervisor never writes `SWM_MACOS_RUNNER`.** `swm-runner` has no
   Variables permission. A failed self-check stops minting and alerts; the
   part 2 watchdog sees no online runner and switches. Nothing from the NOS
   `set_ubuntu` / `remote_failover` / `failover_idle` / planned-stop code is
   ported.
3. **SIGTERM stops the VM, including a busy one** (Andrew, 2026-11-17). A
   one-slot runner has no other slot to adopt it. The job fails and Andrew
   re-runs it.
4. **Updates are automatic** (Andrew, 2026-11-17), as for the NOS runner
   (Task 7). The updater waits while a job runs, so an update never stops
   a job.
5. **The image is built by the supervisor, under launchd**, because the TCC
   grant was proven only for launchd `tart`. `build-image.sh` is not run from
   ssh.
6. **`bounded()` is copied**, not shared with the NOS supervisor, so the live
   NOS supervisor does not change. It is 15 lines.
7. **Tests are plain bash `test-*.sh` with stub binaries**, the NOS pattern.
   The spec says "bats"; the repo does not use bats.
8. **Alerts reuse the NOS ntfy topic** (Andrew, 2026-11-17), read from
   `~/.config/nos-runner/env`. Messages start with `macOS runner:`.
9. **The pf guard runs every 60 s, not 300 s.** The supervisor waits for a
   fresh IPv6 ok file after the VM is up, so a slow guard is a slow job start.

## Global Constraints

- Org `smartwatermelon`. Runner label `mimolette-macos`. Runner group ID `1`
  (Default). Variable `SWM_MACOS_RUNNER`. Hold value `macos-26`.
- Workflow expression, verbatim: `runs-on: ${{ vars.SWM_MACOS_RUNNER || 'macos-latest' }}`.
- App `swm-runner`: App ID `5807971`, installation `183107042`. Key: login
  Keychain service `swm-runner-app-key`, account `smartwatermelon`,
  base64 text.
- JIT request: `POST /orgs/smartwatermelon/actions/runners/generate-jitconfig`,
  body `{"name":"<vm>","runner_group_id":1,"labels":["mimolette-macos"],"work_folder":"_work"}`.
- One slot. VM 4 CPUs, 6144 MB. VM and runner name `mimolette-macos-<epoch>`.
- `TART_HOME=/Volumes/extra-vieille/Caches/tart`. Free space there at least
  60 GB before each slot.
- Base image `ghcr.io/cirruslabs/macos-tahoe-base`, pinned by digest (Task 4
  records it). Actions runner `2.338.2` osx-arm64, SHA-256
  `25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388`, and
  always the same `RUNNER_VERSION` as `scripts/nos-runner/image/Containerfile`.
- Guest hook path `/usr/local/libexec/runner-hooks/job-started.sh`,
  `root:wheel 0755`; `.env` line `ACTIONS_RUNNER_HOOK_JOB_STARTED=<that path>`.
- The JIT config and every token reach the guest on stdin only: never host
  argv, never a log, never a file outside a 0600 temp that is removed at once.
- Installed files: `~/.local/libexec/swm-macos-runner` (internal disk). Nothing
  the supervisor runs lives under `/Volumes`.
- Every `tart` call goes through `bounded SECS`. Limits: clone 600, run start
  30, ip 180, exec copy 60, stop 60, delete 120, list 60, build 2700.
- Destructive commands (`rm`, `tart delete/stop`, `launchctl`, `pfctl`,
  `install`, `mv`) go through `*_BIN` variables. Tests stub every one. The
  first (red) run of a new safety test runs in a Linux container, not on a
  host (Protocol 3).
- `shellcheck -S info` clean, no disable directives. Bash 3.2: no
  associative arrays, no `mapfile`, no `((x++))`.
- Every MIMOLETTE change needs Andrew's OK first. Changes run as andrewrich
  over `ssh mimolette.local`; read-only checks over `ssh mimolette-ro`.
- The full suites run in CI only. Locally run only the changed directory's
  tests.

## Review Focus

1. **Tart hangs on a TCC prompt** (for example after a `tart` upgrade): the
   slot times out before any runner is minted, the VM is deleted, one
   `tart-hung` alert is sent. Test in Task 5.
2. **A minted JIT whose exec fails** (guest crash, runner refuses the
   config): the registration is deleted, the VM is deleted, the fail count
   rises; three in a row alert once and back off. Test in Task 5.
3. **Supervisor restart with a VM still running** (crash, reboot, reinstall):
   every `mimolette-macos-*` VM and the recorded runner ID are cleaned up
   before the first new slot. Test in Task 5.
4. **IPv6 rules missing when the VM comes up** (`bridge101` did not exist at
   guard time): no JIT handoff until the v6 ok file is fresh; after 150 s the
   VM is deleted. Test in Task 5; live probe in Task 0.
5. **`df` on the external volume hangs or the volume is unmounted**: no slot
   starts, one `disk` alert. Test in Task 5; live check in Task 0.

---

### Task 0: Live go/no-go on MIMOLETTE (no code)

Andrew's OK first; his sudo for the pf steps. Record every result in the
spec's "Spike results" section in this task's commit.

- [ ] **Step 1:** Flush the spike anchor (Andrew):
  `sudo pfctl -a com.apple/tart-spike -F all` then
  `sudo pfctl -X "$(cat ~/.local/state/tart-spike/pf-token)"`.
  Expected: `sudo pfctl -a com.apple/tart-spike -s rules` prints nothing.
- [ ] **Step 2:** With no Tart VM running, Andrew loads both rule files (text
  in Task 3) into two probe anchors:
  `sudo pfctl -a com.apple/swm-tart-probe -f swm-tart.pf` and
  `sudo pfctl -a com.apple/swm-tart-probe-v6 -f swm-tart-v6.pf`.
  Record whether the v6 file loads while `bridge101` is absent
  (`ifconfig bridge101`). The v4 rules match by source address and have never
  run live; the spike used `on bridge101 ... from any`.
- [ ] **Step 3:** Add one IPv6 LAN probe to `probe.sh`: TCP 22 to MIMOLETTE's
  `fe80::` address on `bridge101` (not port 53). Clone `probe-1` from the base
  image on the external disk, boot it under a temporary LaunchAgent in
  `gui/501` (the spike plist with the VM name changed), and run `probe.sh`.
  Expected: DNS works; every IPv4 probe in the spec's step 3 table and the
  IPv6 probe are blocked. Delete `probe-1`, clone and boot `probe-2`, probe
  again. Expected: the same, which shows the v6 rules apply to the new
  `bridge101`.
- [ ] **Step 4:** In a temporary LaunchAgent running `/bin/bash`, run
  `df -Pk /Volumes/extra-vieille/Caches/tart`. Expected: it prints within 5 s.
  If it hangs, stop and report: Task 5's disk check then needs a new design.
- [ ] **Step 5:** Record facts: `tart --version` (2.42.0, installed 11:59
  2026-11-17, before the TCC Allow, so the spec's "2.41.1" was wrong), the
  base image digest from `tart list` as andrewrich, and the spike LaunchAgents
  unloaded (`launchctl print gui/501 | grep tart-` empty). Fix the spec's Undo
  section: unset and `macos-latest` are not holds once the watchdog runs; the
  hold value is `macos-26`.
- [ ] **Step 6:** Remove the probe anchor (Andrew):
  `sudo pfctl -a com.apple/swm-tart-probe -F all` and
  `sudo pfctl -a com.apple/swm-tart-probe-v6 -F all`. Delete `probe-2` and
  unload its LaunchAgent.

Go: Steps 3 and 4 pass. No-go: stop and report to Andrew.

### Task 1: Parameterize the App key item in `github-app.sh`

**Files:**

- Modify: `scripts/nos-runner/github-app.sh` (`app_jwt`)
- Test: `scripts/nos-runner/tests/test-github-app.sh`

**Interfaces:**

- Produces: `app_jwt APP_ID` reads `${GH_APP_KEY_SERVICE:-nos-runner-app-key}`
  and `${GH_APP_KEY_ACCOUNT:-nightowlstudiollc}`. `app_token`, `_api_call`
  unchanged.

- [ ] **Step 1: Failing test** `key item override`: with
  `GH_APP_KEY_SERVICE=swm-runner-app-key GH_APP_KEY_ACCOUNT=smartwatermelon`,
  `security.argv` holds `find-generic-password -s swm-runner-app-key -a smartwatermelon -w`.
  Keep the existing default test: with both unset, the argv names
  `nos-runner-app-key` / `nightowlstudiollc`.
- [ ] **Step 2:** `bash scripts/nos-runner/tests/test-github-app.sh` → the
  new case FAILs.
- [ ] **Step 3:** Use the two variables in `app_jwt`.
- [ ] **Step 4:** `bash scripts/nos-runner/tests/run-tests.sh` → all PASS
  (this touches `scripts/nos-runner/`, so run that directory's suite).
- [ ] **Step 5:** Commit `feat(nos-runner): let github-app.sh read any Keychain key item`.
- [ ] **Step 6 (after merge):** The NOS updater installs the new
  `github-app.sh` within 600 s and restarts the supervisor by SIGHUP (a
  runtime-file change; no failover). Check over `ssh mimolette-ro`:
  `~/Library/Logs/nos-runner.log` shows a clean restart and no auth error, and
  `gh variable get NOS_RUNNER --org nightowlstudiollc` is unchanged.

### Task 2: Fork guard in the repo

**Files:**

- Create: `scripts/swm-macos-runner/guest/job-started.sh` (from MIMOLETTE
  `~/.local/state/tart-spike/job-started.sh`, unchanged logic)
- Create: `scripts/swm-macos-runner/tests/test-job-started.sh`,
  `scripts/swm-macos-runner/tests/hook-allow-all.sh`,
  `scripts/swm-macos-runner/tests/run-tests.sh` (copy of the NOS runner)
- Modify: `.github/workflows/tests.yml` (step
  `bash scripts/swm-macos-runner/tests/run-tests.sh`), `CLAUDE.md` (Purpose
  test line, Repository Structure entry)

**Interfaces:**

- Produces: hook exit 0 = allow, 1 = deny; stderr line
  `job-started hook: allowed <event> in <repo>` or `job-started hook: DENIED: <reason>`.
  Env: `GITHUB_EVENT_PATH`, `GITHUB_EVENT_NAME`, optional `GITHUB_REPOSITORY`,
  `JQ_BIN` (default `/usr/bin/jq`), `ALLOWED_OWNERS` (default `smartwatermelon`).

- [ ] **Step 1: Tests.** Port the 20 spike cases. Add: `schedule` allowed,
  `merge_group` allowed, `schedule payload carrying a pull_request` denied.
  `HOOK` selects the script (default the real one). The control case in
  `test-job-started.sh`: run the whole case list against `hook-allow-all.sh`
  and require exactly 16 failures (the deny cases).
- [ ] **Step 2:** Run before the hook exists → every case FAILs (exit 127).
  No destructive command is involved, so this runs locally.
- [ ] **Step 3:** Add `job-started.sh`. Bash 3.2 clean.
- [ ] **Step 4:** `bash scripts/swm-macos-runner/tests/run-tests.sh` → 23
  PASS, control PASS. `shellcheck -S info` on all three scripts → clean.
- [ ] **Step 5:** Commit `feat(swm-macos-runner): add the fork-guard job-started hook`.

### Task 3: Tart anchor in the root pf guard

**Files:**

- Create: `scripts/nos-runner/net/swm-tart.pf`, `scripts/nos-runner/net/swm-tart-v6.pf`
- Modify: `scripts/nos-runner/net/pf-guard.sh`,
  `scripts/nos-runner/net/install-pf.sh`,
  `scripts/nos-runner/net/com.nightowlstudio.nos-runner-pf.plist`
  (`StartInterval` 60)
- Test: `scripts/nos-runner/tests/test-pf-guard.sh`, `test-install-pf.sh`

**Interfaces:**

- Produces: anchors `com.apple/swm-tart` and `com.apple/swm-tart-v6`; ok files
  `/var/run/swm-tart-pf.ok` (v4) and `/var/run/swm-tart-pf-v6.ok` (v6), env
  overrides `SWM_PF_RULES`, `SWM_PF_RULES_V6`, `SWM_PF_OK_FILE`,
  `SWM_PF_OK_FILE_V6`. NOS anchors, ok file and counts unchanged.

Rules (`swm-tart.pf`, no interface named):

```text
table <swm_private> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }
pass in quick inet proto { udp tcp } from 192.168.65.0/24 to 192.168.65.1 port 53
block drop in quick inet from 192.168.65.0/24 to <swm_private>
```

`swm-tart-v6.pf` (names `bridge101`; Task 0 proved it loads while the
interface is absent and still applies to a new `bridge101`). No IPv6 DNS
pass: Task 0 showed a port-53 pass to the bridge's link-local address does
not match, and DNS works through `192.168.65.1`, which the v4 file passes.

```text
block drop in quick on bridge101 inet6 from any to { fc00::/7, fe80::/10 }
```

- [ ] **Step 1: Failing tests** (stub `pfctl`, `rm`, `mv`):
  `tart v4 load fails → NOS ok file kept, swm ok file removed, exit 1`;
  `NOS load fails → swm ok files still written when swm loads`;
  `swm v4 anchor lists 2 pass + 1 block → swm ok written`;
  `swm v6 lists 0 pass + 2 block (the destination list expands) → v6 ok written`;
  `swm v6 load fails → v6 ok removed, v4 ok kept, warning on stderr`;
  `existing NOS cases unchanged`. `install-pf` installs both new rule files
  `root:wheel 0644`.
- [ ] **Step 2:** Run in a Linux container (red phase, safety test):
  `bash scripts/nos-runner/tests/test-pf-guard.sh` → new cases FAIL.
- [ ] **Step 3:** Split `pf-guard.sh` into `check_nos` and `check_swm`
  functions, each with its own `fail_<set>` that removes only that set's ok
  files and returns 1. The pf-enable block runs once, before both. Exit 1 if
  either check failed.
- [ ] **Step 4:** `bash scripts/nos-runner/tests/run-tests.sh` → all PASS.
- [ ] **Step 5:** Commit `feat(nos-runner): load the Tart LAN-block anchor in the pf guard`.

Andrew re-runs `sudo bash scripts/nos-runner/net/install-pf.sh` after merge
(Task 8).

### Task 4: Runner image build

**Files:**

- Create: `scripts/swm-macos-runner/config.sh`,
  `scripts/swm-macos-runner/lib.sh` (`bounded`, `log`, `notify`),
  `scripts/swm-macos-runner/image/build-image.sh`,
  `scripts/swm-macos-runner/guest/install-runner.sh`,
  `scripts/swm-macos-runner/guest/run-job.sh`
- Test: `scripts/swm-macos-runner/tests/test-build-image.sh`,
  `scripts/swm-macos-runner/tests/test-config.sh`

**Interfaces:**

- Produces (`config.sh`): `SWM_BASE_IMAGE` (`ghcr.io/cirruslabs/macos-tahoe-base@sha256:65c3133a633fda8753cf1f71f2d55727792d534a2125b0032466563dcc8e58fd`),
  `SWM_RUNNER_VERSION=2.338.2`, `SWM_RUNNER_SHA256`, `SWM_IMAGE`
  (`swm-macos-runner-<version>-<12 hex>`, hash over `guest/` files plus the
  base digest, same method as NOS `_nos_image_hash`), `SWM_CPUS=4`,
  `SWM_MEMORY_MB=6144`, `SWM_LABEL=mimolette-macos`, `TART_HOME`,
  `SWM_MIN_FREE_GB=60`, `SWM_STATE_DIR=~/.local/state/swm-macos-runner`, and
  the limits from Global Constraints as `SWM_CLONE_LIMIT_S`, `SWM_RUN_LIMIT_S`,
  `SWM_IP_LIMIT_S`, `SWM_EXEC_LIMIT_S`, `SWM_STOP_LIMIT_S`,
  `SWM_DELETE_LIMIT_S`, `SWM_LIST_LIMIT_S`, `SWM_BUILD_LIMIT_S`, each
  overridable from the environment.
- Produces: `build-image.sh` exit 0 when `SWM_IMAGE` exists as a stopped
  local VM; it deletes only VMs matching `^swm-macos-runner-` other than
  `SWM_IMAGE`, and `swm-build-tmp`.
- Produces: guest paths (the base image user is `admin`):
  `/usr/local/libexec/swm-runner/run-job.sh` (`root:wheel 0755`), runner
  directory `/Users/admin/actions-runner`, hook as in Global Constraints.
  `run-job.sh` reads the JIT config from stdin, refuses an empty one (exit 2),
  and `exec`s `./run.sh --jitconfig "$jit"` in the runner directory (as the
  NOS entrypoint does).

- [ ] **Step 1: Failing tests.** `test-config.sh`: `SWM_RUNNER_VERSION`
  equals `ARG RUNNER_VERSION` in `scripts/nos-runner/image/Containerfile`;
  `SWM_BASE_IMAGE` matches `@sha256:[0-9a-f]{64}$`; `SWM_IMAGE` changes when a
  `guest/` file changes. `test-build-image.sh` (stub `tart`, records argv):
  call order clone → set `--cpu 4 --memory 6144` → run → ip → exec copies →
  exec install → stop → rename to `SWM_IMAGE`; a failed install deletes
  `swm-build-tmp` and exits 1; old `swm-macos-runner-*` deleted only after a
  good rename; a VM named `other-vm` is never deleted; a `tart` stub that
  sleeps past the limit → exit 1 with `timed out` logged.
- [ ] **Step 2:** Run in a Linux container → FAIL.
- [ ] **Step 3:** Implement. `install-runner.sh` is the spike's
  `runner-guest.sh` minus the JIT and run lines: download, SHA-256 check,
  unpack to `/Users/admin/actions-runner`, install the hook and `run-job.sh`
  root-owned, write `.env`, check the `.env` line.
- [ ] **Step 4:** `bash scripts/swm-macos-runner/tests/run-tests.sh` → PASS;
  shellcheck clean.
- [ ] **Step 5:** Commit `feat(swm-macos-runner): build a local runner image from the pinned base`.

### Task 5: Supervisor

**Files:**

- Create: `scripts/swm-macos-runner/supervisor.sh`
- Test: `scripts/swm-macos-runner/tests/test-supervisor.sh`

**Interfaces:**

- Consumes: `app_token` (Task 1, with `GH_APP_KEY_SERVICE=swm-runner-app-key`,
  `GH_APP_KEY_ACCOUNT=smartwatermelon`), `gh_api` with `NOS_TOKEN` set to the
  swm token, `config.sh`/`lib.sh`/`build-image.sh` (Task 4), ok files (Task 3).
- Produces: `supervisor.sh run | once | test-alert`. State file
  `${SWM_STATE_DIR}/slot`: `name=`, `id=`, `fails=`, `alert=`, `job=` (1
  from the JIT handoff until the exec returns; Task 7 reads it).

One pass (`once`):

1. Sweep: delete every `mimolette-macos-*` VM; DELETE the recorded runner ID
   (2xx or 404 clears it).
2. Self-checks, in order, each failing with a `KIND`: `pf` (v4 ok file under
   10 min old), `disk` (bounded `df` ≥ `SWM_MIN_FREE_GB`), `image`
   (`SWM_IMAGE` listed; if not, run `build-image.sh`; a failed build is
   `build`).
3. Record `name=`, clone, start `tart run --no-graphics` in the background,
   wait for an IP.
4. Readiness: retry `tart exec <vm> /usr/bin/true` every 5 s, up to
   `SWM_READY_LIMIT_S=90` (the spike needed about 20 s after the IP).
5. Wait up to 150 s for the v6 ok file to be newer than the VM's start.
6. Mint the token, POST the JIT request, record `id=`. Minting last means a
   VM that never boots leaves no registration behind.
7. Pipe the JIT to
   `tart exec -i <vm> /bin/bash /usr/local/libexec/swm-runner/run-job.sh`,
   bounded by `SWM_JOB_MAX_S=21600`.
8. Stop, delete, DELETE the runner, clear the slot.

Any step failing: delete the VM, DELETE the runner if `id=` is set,
`fails += 1`. Alert once
per change of `KIND` (`pf`, `disk`, `build`, `tart-hung`, `start` after 3
fails, `recovered`). After 3 fails, sleep `SWM_BACKOFF_S=600` between passes.

- [ ] **Step 1: Failing tests** (stub `tart`, `curl`, `security`, `openssl`,
  `df`, `rm`; `NTFY_BASE` to a stub): `happy path order`; `JIT string absent
  from tart argv log and supervisor log`; `orphan VM and recorded id swept
  first`; `pf ok stale → no mint, one pf alert`; `df hang → disk alert, no
  mint`; `image missing → build runs; build fails → build alert`; `clone
  hangs → tart-hung alert, no JIT request`; `no IP within limit → VM deleted,
  no JIT request, fails=1`; `exec not ready in 90 s → VM deleted, no JIT
  request`; `v6 ok not fresh in 150 s → VM deleted, no JIT request`;
  `exec fails after mint → runner DELETEd, VM deleted, fails=1`;
  `3 fails → one start alert, backoff`; `success after fails → recovered
  alert, fails=0`; `SIGTERM mid-job → VM stopped and deleted, runner
  DELETEd`; `never deletes a VM outside mimolette-macos-*`.
- [ ] **Step 2:** Run in a Linux container → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `bash scripts/swm-macos-runner/tests/run-tests.sh` → PASS;
  shellcheck clean.
- [ ] **Step 5:** Commit `feat(swm-macos-runner): add the one-slot Tart supervisor`.

### Task 6: Installer, LaunchAgent and runbook

**Files:**

- Create: `scripts/swm-macos-runner/install.sh`,
  `scripts/swm-macos-runner/launchd/com.smartwatermelon.swm-macos-runner.plist`,
  `docs/runbooks/swm-macos-runner.md`
- Modify: `CLAUDE.md` (runbook line), `docs/runbooks/nos-runner.md` (the
  ntfy topic now also carries macOS runner alerts; the pf guard runs every
  60 s and loads the Tart anchors)
- Test: `scripts/swm-macos-runner/tests/test-install.sh`

**Interfaces:**

- Produces: `install.sh` copies `supervisor.sh`, `config.sh`, `lib.sh`,
  `image/`, `guest/` and `../nos-runner/github-app.sh` into
  `~/.local/libexec/swm-macos-runner`; renders the plist (`@LIBEXEC@`,
  `@HOME@`, `@TART_HOME@`, `@NTFY_ENV@` from `~/.config/nos-runner/env`);
  `launchctl bootout` then `bootstrap gui/<uid>`. Plist: `RunAtLoad`,
  `KeepAlive`, `ExitTimeOut` 300 (stop 60 + delete 120 + runner DELETE 30 + ntfy 20 =
  230 s, plus margin), log `~/Library/Logs/swm-macos-runner.log`.

- [ ] **Step 1: Failing tests** (`HOME` in a temp dir, stub `launchctl`,
  `install`): files land in libexec with mode 0755/0644; plist placeholders
  all filled; a topic with characters outside `A-Za-z0-9_.-` is refused;
  nothing written under `/Volumes`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** PASS,
  shellcheck clean.
- [ ] **Step 5:** Runbook sections: credentials (swm-runner, already in the
  Keychain); pf install (sudo); install; first build (about 15 min); the TCC
  Allow and how a hang shows up; hold (`SWM_MACOS_RUNNER=macos-26`) and
  release; full stop; cleanup of the spike files and the internal image copy.
- [ ] **Step 6:** Commit `feat(swm-macos-runner): add the installer, LaunchAgent and runbook`.

### Task 7: Automatic updates

**Files:**

- Create: `scripts/swm-macos-runner/update.sh`,
  `scripts/swm-macos-runner/launchd/com.smartwatermelon.swm-macos-runner-update.plist`
- Modify: `scripts/swm-macos-runner/install.sh` (installs and loads the
  updater too), `docs/runbooks/swm-macos-runner.md`
- Test: `scripts/swm-macos-runner/tests/test-update.sh`

**Interfaces:**

- Consumes: `job=` in the slot state file (Task 5), `install.sh` (Task 6).
- Produces: `update.sh`, run every 600 s, always exits 0. The NOS
  `update.sh` is the pattern: `git pull --ff-only` in
  `~/.local/share/dev-env` (a failed pull, for example the NOS updater's
  lock, is logged and retried next run); the version is the last commit
  touching `scripts/swm-macos-runner/` or `scripts/nos-runner/github-app.sh`;
  mark file `${SWM_STATE_DIR}/installed`.

- [ ] **Step 1: Failing tests** (stub `git`, `install.sh`): `no change → no
  install`; `new commit, job=0 → install runs, mark updated`; `new commit,
  job=1 → no install, mark unchanged, logged as waiting`; `pull fails → no
  install, exit 0`; `install fails → mark unchanged, exit 0`; `github-app.sh
  change counts as a new version`.
- [ ] **Step 2:** Run in a Linux container → FAIL. **Step 3:** Implement.
  **Step 4:** PASS, shellcheck clean.
- [ ] **Step 5:** Commit `feat(swm-macos-runner): install new runner code automatically`.

### Task 8: Install and prove on MIMOLETTE

Andrew's OK before each step. No org variable changes in this task.

- [ ] **Step 1:** Andrew: `sudo bash ~/.local/share/dev-env/scripts/nos-runner/net/install-pf.sh`.
  Expected within 60 s: both swm ok files exist; the NOS ok file is still
  fresh; the NOS runner keeps running.
- [ ] **Step 2:** `bash ~/.local/share/dev-env/scripts/swm-macos-runner/install.sh`.
  Expected: the log shows a build, then an idle `mimolette-macos-*` runner
  online in the org runner list.
- [ ] **Step 3:** Draft dotfiles PR (closed after, never merged) with
  `runs-on: mimolette-macos` on `bash-tests` plus a step that runs the LAN
  probes and fails if any LAN target answers. Expected: tests pass, the log
  shows `job-started hook: allowed pull_request`, the probes are blocked.
- [ ] **Step 4:** Andrew opens a PR from his `twistedmelonman` fork against
  the draft branch. Expected: the job fails at "Set up runner" with
  `DENIED ... (fork PR)`.
- [ ] **Step 5:** Hang drill: reinstall with `SWM_CLONE_LIMIT_S=1` in the env
  file. Expected: one `macOS runner: tart-hung` alert, no leftover runner.
  This proves the alert path, not a real TCC prompt. Reinstall without it.
- [ ] **Step 6:** After Andrew's OK, delete the internal-disk image copy
  (`TART_HOME=~/.tart tart delete ghcr.io/cirruslabs/macos-tahoe-base:latest`)
  and the spike files.

Part 1 is done when Steps 1–5 pass. Part 2 then adds the watchdog and switches
the dotfiles pilot.
