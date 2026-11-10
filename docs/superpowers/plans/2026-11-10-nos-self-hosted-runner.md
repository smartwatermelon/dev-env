# NOS Self-Hosted Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run NOS private Linux CI on MIMOLETTE in one-job Apple `container` VMs, with a Cloudflare Worker that moves CI back to GitHub-hosted runners when MIMOLETTE is down.

**Architecture:** A launchd supervisor on MIMOLETTE keeps 2 slots. Each slot mints a JIT runner config with the `nos-runner` App and starts `container run --rm` for one job. Workflows pick a runner with `runs-on: ${{ vars.NOS_RUNNER || 'ubuntu-latest' }}`. A Worker on a 10-minute cron reads runner and queue state from the GitHub API and owns the switch back to `mimolette`.

**Tech Stack:** bash (macOS `/bin/bash` 3.2 on MIMOLETTE), openssl, curl, jq, Apple `container` 1.7.1, launchd; Cloudflare Workers (ES modules, Web Crypto) with KV; `node --test` for Worker tests.

**Spec:** `docs/superpowers/specs/2026-11-10-nos-self-hosted-runner-design.md`

## Global Constraints

- Org: `nightowlstudiollc`. Runner label: `mimolette`. Variable: org variable `NOS_RUNNER`, values `mimolette` or `ubuntu-latest`.
- Workflow expression, verbatim: `runs-on: ${{ vars.NOS_RUNNER || 'ubuntu-latest' }}`.
- 2 slots; each job VM 4 CPUs, 4 GB RAM; image Ubuntu 24.04 arm64.
- Job VMs: no shared folders, no host mounts, no Keychain access; private LAN ranges blocked.
- Supervisor self-check: apiserver answers, image exists, free disk at least 20 GB, a slot started within its last 3 tries.
- Supervisor writes only `NOS_RUNNER=ubuntu-latest`. Only the Worker writes `NOS_RUNNER=mimolette`.
- Worker cron every 10 minutes; unhealthy = no `mimolette` runner online, or a `mimolette` job queued more than 20 minutes; switch after 2 checks in a row either way.
- One ntfy alert per state change, sent only by the writer that changed the variable. Topic: existing `NTFY_TOPIC` (`https://ntfy.sh`, as in `scripts/site-monitor/run-monitor.sh`).
- launchd scripts run under `/bin/bash` 3.2: no associative arrays, no `mapfile`, no `printf %(...)T` (see `scripts/site-monitor/dispatch-monitor.sh`).
- Installed files live on MIMOLETTE's internal disk (`~/.local/libexec/nos-runner`, deploy clone `~/.local/share/dev-env`), never on `/Volumes` (TCC removable-volume hang).
- App private keys never touch disk in plain text and never appear in argv. Keychain: back up and verify before any change, verify after.
- `shellcheck -S info` clean, no disable directives. Every destructive command (`rm`, `container rm/stop`, `launchctl`) goes through an injectable `*_BIN` variable; tests stub all of them.
- Every MIMOLETTE change needs Andrew's OK first. The full suites run in CI only.
- Tests follow the site-monitor pattern: plain bash `test-*.sh` with stub binaries on PATH, run by `tests/run-tests.sh`.

## Review Focus

1. **Queue backlog while healthy.** A Dependabot burst can queue a `mimolette` job for more than 20 minutes with both slots busy. Expected: this counts as unhealthy, CI falls back, and exactly one alert is sent. Test: Task 6 `queued_stale_with_runners_online_is_unhealthy`.
2. **`NOS_RUNNER` unset or empty.** Expected: the Worker treats it as `ubuntu-latest`, workflows run on GitHub, and the first healthy switch sends one "online" alert. Test: Task 6 `unset_var_treated_as_ubuntu`.
3. **Supervisor self-check fails while runners are still online.** Expected: the supervisor takes its runners offline, so the Worker does not switch back and the alerts do not flap. Test: Task 4 `selfcheck_failure_stops_slots_and_deregisters`.
4. **The variable changes behind the Worker's back** (supervisor or Andrew sets it). Expected: the Worker resets its counts and sends no alert for a change it did not make. Test: Task 6 `external_var_change_resets_counts_no_alert`.
5. **GitHub API error or rate limit during a Worker check.** Expected: no state change and no alert, because an API outage is not a MIMOLETTE outage. Test: Task 7 `api_error_skips_tick`.

---

### Task 1: Spike (main thread, throwaway, needs Andrew's OK)

Run by the main session over SSH, not a subagent. Nothing built here is kept. Record each answer, with the evidence, in a new `## Spike results` section at the end of the spec, and commit that section.

- [ ] **Step 1: Andrew creates the `nos-runner` App.** Org permissions: Self-hosted runners read and write, Variables read and write. Installed on nightowlstudiollc. He backs up the MIMOLETTE login Keychain, then stores the PEM in it as generic password service `nos-runner-app-key`, account `nightowlstudiollc`. App ID and installation ID go in chat (not secrets).
- [ ] **Step 2: Q1, LAN blocking.** On MIMOLETTE, run a throwaway Ubuntu container. Record its address, gateway, DNS server and the host interface (`ifconfig` bridge). Try the blocking method in this order: a `container` network option, if one exists in 1.7.1; else a pf anchor on the vmnet bridge that blocks RFC 1918, 169.254/16 and fc00::/7, and passes the container gateway's DNS. Pass: from the container, `curl https://api.github.com` works, and `curl --max-time 5 http://romano.local` and a ping to the LAN router both fail.
- [ ] **Step 3: Q2, runner in an arm64 VM.** Build a throwaway image with the Actions runner (linux-arm64). Mint a JIT config by hand with the App, and run one container with label `mimolette`. On a draft kebab-tax PR, point only `test-mobile` at `mimolette` with a temporary `runs-on: mimolette`. Pass: the job passes, and record its duration next to the GitHub-hosted duration. Close the draft PR without merging.
- [ ] **Step 4: Q3, re-run reads the new variable.** In a draft dev-env PR (public, so free): a job with `runs-on: ${{ vars.SPIKE_RUNNER || 'ubuntu-latest' }}`, with repo variable `SPIKE_RUNNER=no-such-label`. The job queues. Set `SPIKE_RUNNER=ubuntu-latest`, cancel the run, and call `rerun-failed-jobs`. Pass: the re-run job runs on `ubuntu-latest`. Delete the variable and close the PR.
- [ ] **Step 5: Q4, Worker free-plan limits.** From Cloudflare docs (`mcp__cloudflare__docs`), record the limits for cron triggers, subrequests per invocation, CPU time, and KV writes per day. Pass: about 15 subrequests per check, 144 checks a day, and at most a few KV writes a check all fit.
- [ ] **Step 6: Decide.** If Q1 or Q2 fails, stop and report to Andrew. If Q3 fails, change Task 7 so the Worker re-runs stuck jobs only after it has changed the variable and the cancel has finished, then re-check. Commit the spike results.

### Task 2: GitHub App helper

**Files:**

- Create: `scripts/nos-runner/github-app.sh`
- Test: `scripts/nos-runner/tests/test-github-app.sh`, `scripts/nos-runner/tests/run-tests.sh` (copy of the site-monitor runner)

**Interfaces:**

- Produces, sourced by Task 4:
  - `app_jwt APP_ID` prints an RS256 JWT, with `iat` = now − 60 and `exp` = now + 540. It reads the key with `${SECURITY_BIN:-security} find-generic-password -s nos-runner-app-key -a nightowlstudiollc -w`, which goes into `${OPENSSL_BIN:-openssl} dgst -sha256 -sign` through a pipe or process substitution, never a file.
  - `app_token APP_ID INSTALLATION_ID` prints an installation token.
  - `gh_api METHOD PATH [JSON_BODY]` uses `$NOS_TOKEN`, sends the header on stdin as in `dispatch-monitor.sh`, prints the body, and returns 1 on non-2xx.
  - `GITHUB_API_URL` overrides `https://api.github.com`.

- [ ] **Step 1: Write the failing tests.** Use stub `security`, `openssl` and `curl` that log their argv and stdin.
  - `jwt_has_three_parts_and_rs256_header`
  - `jwt_claims_iss_iat_exp` (fixed stub `date`: `iat` = T−60, `exp` = T+540)
  - `key_never_in_argv` (no logged argv contains the stub key text)
  - `token_request_posts_to_installation_access_tokens`
  - `gh_api_returns_1_on_404`
  - `auth_header_not_in_argv`
- [ ] **Step 2: Run them.** Command: `bash scripts/nos-runner/tests/run-tests.sh`. Expected: FAIL, because the script is missing.
- [ ] **Step 3: Implement the three functions.** Base64url encoding: `openssl base64 -A | tr '+/' '-_' | tr -d '='`.
- [ ] **Step 4: Run them again.** Expected: PASS. Also run `shellcheck -S info scripts/nos-runner/*.sh scripts/nos-runner/tests/*.sh`, which must be clean.
- [ ] **Step 5: Commit.** Message: `feat(nos-runner): add GitHub App token helper`.

### Task 3: Runner image and LAN block

**Files:**

- Create: `scripts/nos-runner/image/Containerfile`
- Create: `scripts/nos-runner/image/entrypoint.sh`
- Create: the LAN-block artifact that Task 1 Q1 chose, either `scripts/nos-runner/net/` container network setup or `scripts/nos-runner/net/nos-runner.pf` plus the anchor load line
- Create: `scripts/nos-runner/smoke.sh`, run on MIMOLETTE only and never in CI
- Test: `scripts/nos-runner/tests/test-entrypoint.sh`

**Interfaces:**

- Produces:
  - The image tag `nos-runner:<runner-version>`, with the runner version pinned in the Containerfile as `ARG RUNNER_VERSION`.
  - The entrypoint reads the JIT config from file `/run/nos-runner/jit` (passed by `--env-file` or a read-only one-file mount that Task 1 found to work), deletes the file, then `exec ./run.sh --jitconfig "$jit"`.
  - It runs as a non-root `runner` user with passwordless `sudo`, so workflows that `apt-get install` (kebab-tax's bats and jq step) still work.

- [ ] **Step 1: Write the failing test.** The test runs `entrypoint.sh` against a stub `run.sh` and checks:
  - `entrypoint_passes_jitconfig_and_removes_file`
  - `entrypoint_fails_when_jit_missing` (exit 2 with a message)
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write `entrypoint.sh` and the Containerfile.** Packages: git, curl, jq, unzip, ca-certificates, build-essential, sudo. The runner tarball checksum must be checked against GitHub's published SHA-256.
- [ ] **Step 4: Write `smoke.sh`.** It builds the image, runs it with the LAN block on, and repeats the pass checks from Task 1 Q1. It prints `SMOKE PASS` or names the failed check.
- [ ] **Step 5: Run the unit test, then the smoke test.** Unit test: expected PASS. Smoke test (with Andrew's OK): `ssh mimolette.local '/bin/bash ~/.local/share/dev-env/scripts/nos-runner/smoke.sh'` must print `SMOKE PASS`.
- [ ] **Step 6: Commit.** Message: `feat(nos-runner): add runner image and LAN block`.

### Task 4: Supervisor

**Files:**

- Create: `scripts/nos-runner/supervisor.sh`
- Create: `scripts/nos-runner/config.sh`, holding these defaults:
  - `NOS_ORG=nightowlstudiollc`
  - `NOS_SLOTS=2`
  - `NOS_CPUS=4`
  - `NOS_MEMORY=4g`
  - `NOS_MIN_FREE_GB=20`
  - `NOS_LABEL=mimolette`
  - `NOS_APP_ID` and `NOS_INSTALLATION_ID`, filled from Task 1
- Test: `scripts/nos-runner/tests/test-supervisor.sh`

**Interfaces:**

- Consumes: `app_token` and `gh_api` (Task 2), the image tag and the JIT file contract (Task 3).
- Produces:
  - `supervisor.sh run` is the launchd entry point and loops until it receives SIGTERM.
  - `supervisor.sh once` runs one loop pass, for the tests.
  - Each slot's runner is named `mimolette-<slot>-<epoch>`.
  - JIT configs come from `POST /orgs/$NOS_ORG/actions/runners/generate-jitconfig`, with body `{name, runner_group_id: 1, labels: ["mimolette"], work_folder: "_work"}`.
  - The variable is written with `PATCH /orgs/$NOS_ORG/actions/variables/NOS_RUNNER`, with body `{"name":"NOS_RUNNER","value":"ubuntu-latest","visibility":"private"}`. If that returns 404, it uses `POST /orgs/$NOS_ORG/actions/variables`.
  - Alerts are sent with `curl -d <msg> https://ntfy.sh/$NTFY_TOPIC`.

- [ ] **Step 1: Write the failing tests.** Stub `container`, `curl`, `df`, `security`, `openssl` and `launchctl`, and log their calls.
  - `starts_two_slots_when_healthy`
  - `restarts_slot_after_container_exits`
  - `container_run_has_no_mount_or_volume_flags`
  - `jit_not_in_argv`
  - `selfcheck_failure_stops_slots_and_deregisters` (Review Focus 3): disk at 19 GB means the variable is set to `ubuntu-latest`, one ntfy is sent, the slot containers are stopped, and their runners are deleted through `DELETE /orgs/.../actions/runners/{id}`
  - `no_alert_when_var_already_ubuntu`
  - `sigterm_sets_ubuntu_then_exits`
  - `never_writes_mimolette` (grep the logged bodies)
  - `three_failed_slot_starts_is_selfcheck_failure`
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement `supervisor.sh`.** Slot state goes in one file per slot under `${NOS_STATE_DIR:-$HOME/.local/state/nos-runner}`, which suits bash 3.2. The JIT file is mode 0600 under that directory, and it is removed with `$RM_BIN` after the container starts. Before setting the variable, read it with `GET .../variables/NOS_RUNNER` to decide whether to alert. Use `trap` on TERM.
- [ ] **Step 4: Run the tests again.** Expected: PASS. Shellcheck must be clean.
- [ ] **Step 5: Commit.** Message: `feat(nos-runner): add supervisor`.

### Task 5: Install, update and launchd

**Files:**

- Create: `scripts/nos-runner/install.sh`
- Create: `scripts/nos-runner/update.sh`
- Create: `scripts/nos-runner/launchd/com.nightowlstudio.nos-runner.plist`
- Create: `scripts/nos-runner/launchd/com.nightowlstudio.nos-runner-update.plist`
- Test: `scripts/nos-runner/tests/test-install.sh`

**Interfaces:**

- Consumes: `supervisor.sh run`.
- Produces:
  - `install.sh` copies the scripts to `$HOME/.local/libexec/nos-runner`, renders both plists into `$HOME/Library/LaunchAgents` with `/bin/bash` as the program, and runs `launchctl bootstrap gui/$(id -u)` for both. It is idempotent, and it uses `bootout` before re-bootstrap only when the plist changed.
  - `update.sh` runs every 600 s. It runs `git -C $HOME/.local/share/dev-env pull --ff-only`, then `install.sh` only if `scripts/nos-runner/` changed.
  - The first-install command for Andrew is `git clone https://github.com/smartwatermelon/dev-env ~/.local/share/dev-env && /bin/bash ~/.local/share/dev-env/scripts/nos-runner/install.sh`.

- [ ] **Step 1: Write the failing tests.** Use a fake HOME under `$TMPDIR` and stub `launchctl`, `git` and `cp`.
  - `install_copies_to_libexec_not_volumes`
  - `plists_use_bin_bash`
  - `install_is_idempotent` (a second run bootstraps nothing)
  - `update_skips_install_when_no_change`
  - `update_runs_install_on_change`
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement both scripts and both plists.** The supervisor plist uses `KeepAlive` true, `RunAtLoad` true, `ExitTimeOut` 30 (time for the SIGTERM switch), and logs to `$HOME/Library/Logs/nos-runner.log`.
- [ ] **Step 4: Run the tests again.** Expected: PASS. Shellcheck must be clean.
- [ ] **Step 5: Commit.** Message: `feat(nos-runner): add install, update and launchd jobs`.

### Task 6: Worker decision logic

**Files:**

- Create: `workers/nos-runner-watchdog/src/decide.js`
- Create: `workers/nos-runner-watchdog/package.json` (`"type":"module"`, script `"test": "node --test"`, no dependencies)
- Test: `workers/nos-runner-watchdog/test/decide.test.js`

**Interfaces:**

- Produces: `decide(prev, observed)`, a pure function.
  - `prev`: `{ lastVar: string|null, misses: number, goods: number }`. When KV is empty, use `{lastVar:null, misses:0, goods:0}`.
  - `observed`: `{ varValue: string|null, runnerOnline: boolean, oldestQueuedMinutes: number|null }`.
  - Returns `{ next: {lastVar, misses, goods}, setVar: 'mimolette'|'ubuntu-latest'|null, notify: 'down'|'recovered'|'online'|null, rerunStuck: boolean }`.
  - Healthy means `runnerOnline && (oldestQueuedMinutes === null || oldestQueuedMinutes <= 20)`.
  - An unset or empty `varValue` counts as `ubuntu-latest`.
  - If `varValue !== prev.lastVar` and `prev.lastVar !== null`, reset `misses` and `goods` to 0 before counting.
  - Unhealthy with `misses >= 2` while the effective var is `mimolette` gives `setVar 'ubuntu-latest'`, `notify 'down'`, `rerunStuck true`.
  - Healthy with `goods >= 2` while the effective var is `ubuntu-latest` gives `setVar 'mimolette'` and `notify 'recovered'`. The notify is `'online'` instead when `varValue` was unset or empty.

- [ ] **Step 1: Write the failing tests.**
  - `healthy_stays_mimolette_no_alert`
  - `one_miss_no_switch`
  - `two_misses_switch_down_once` (a third miss gives no second alert)
  - `queued_stale_with_runners_online_is_unhealthy` (Review Focus 1)
  - `unset_var_treated_as_ubuntu` (Review Focus 2: two healthy checks give `mimolette` and `online`)
  - `external_var_change_resets_counts_no_alert` (Review Focus 4)
  - `two_goods_recover_once`
  - `queued_exactly_20_is_healthy`
- [ ] **Step 2: Run them.** Command: `npm --prefix workers/nos-runner-watchdog test`. Expected: FAIL.
- [ ] **Step 3: Implement `decide`.**
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(nos-runner): add watchdog decision logic`.

### Task 7: Worker GitHub, KV and ntfy wiring

**Files:**

- Create: `workers/nos-runner-watchdog/src/index.js`
- Create: `workers/nos-runner-watchdog/src/github.js`
- Test: `workers/nos-runner-watchdog/test/index.test.js`

**Interfaces:**

- Consumes: `decide` (Task 6).
- Produces:
  - `export default { scheduled(event, env, ctx) }`.
  - Bindings: KV `STATE` (key `state`, plus key `pendingReruns`, a JSON array of `{repo, runId}`), and secrets `APP_ID`, `INSTALLATION_ID`, `APP_KEY_PKCS8`, `NTFY_TOPIC`.
  - `github.js` exports `appToken(env, fetchFn)` (RS256 through `crypto.subtle`, PKCS8), `getRunnerOnline(token, fetchFn)` (any runner with label `mimolette` and status `online`), `oldestQueuedMinutes(token, now, fetchFn)` (installation repos, then `actions/runs?status=queued`, then jobs whose `labels` include `mimolette`), `setVar(token, value, fetchFn)`, `cancelRun(token, repo, id, fetchFn)` and `rerunFailed(token, repo, id, fetchFn)`.
  - Stuck runs are cancelled in the tick that switches down. They are re-run in a later tick, once their status is `completed`.

- [ ] **Step 1: Write the failing tests.** Use a fake `fetch` keyed by URL, a fake KV and a fixed clock.
  - `healthy_tick_makes_no_writes`
  - `down_tick_sets_var_cancels_and_alerts_once`
  - `next_tick_reruns_completed_pending`
  - `api_error_skips_tick` (Review Focus 5: a 502 on runners leaves KV unchanged and sends no ntfy)
  - `rate_limited_403_skips_tick`
  - `subrequests_per_tick_at_most_limit`, which counts fetch calls against the Q4 limit from Task 1
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement `github.js` and `index.js`.**
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(nos-runner): add watchdog Worker`.

### Task 8: CI and docs

**Files:**

- Modify: `.github/workflows/tests.yml`. Add the steps `Run nos-runner tests` (`bash scripts/nos-runner/tests/run-tests.sh`) and `Run watchdog tests` (`npm --prefix workers/nos-runner-watchdog test`). `ubuntu-latest` ships Node, so no extra setup is needed.
- Modify: `CLAUDE.md`. Add both test commands to the Tests list, and add `scripts/nos-runner/` and `workers/nos-runner-watchdog/` to Repository Structure.
- Create: `docs/runbooks/nos-runner.md`, covering:
  - Both Apps: permissions, installation, and where each key lives.
  - The Keychain backup, store and verify steps.
  - Converting the PEM to PKCS8 for the Worker: `openssl pkcs8 -topk8 -nocrypt`.
  - The first-install command.
  - How to read the logs.
  - That after a reboot, a GUI login is needed before `container` runs. Until then, the Worker falls back to GitHub.
  - Undo: set `NOS_RUNNER=ubuntu-latest`.

- [ ] **Step 1: Make the edits.** Then run `markdownlint-cli2` on the changed Markdown and `actionlint` on `tests.yml` if it is installed.
- [ ] **Step 2: Commit.** Message: `docs(nos-runner): add runbook and CI steps`.
- [ ] **Step 3: Push and open a PR.** CI must be green, then merge with `gh pr merge <N> --squash --delete-branch`.

### Task 9: Deploy (main thread, needs Andrew at each gate)

- [ ] **Step 1: Andrew creates `nos-runner-watchdog`.** Org permissions: Self-hosted runners read, Variables read and write. Repository permission: Actions read and write, on all NOS private repos. He gives the key to the agent through 1Password, converted to PKCS8. Beware: `op read` flattens PEMs, so rebuild the line breaks first.
- [ ] **Step 2: Deploy the Worker through the Cloudflare API.** Create KV `nos-runner-watchdog-state`, upload both modules with the KV binding, set the 4 secrets, and set cron `*/10 * * * *`. Verify: `GET .../workers/scripts` lists it, and the schedules read back `*/10 * * * *`.
- [ ] **Step 3: Andrew runs the first-install command on MIMOLETTE.** Verify: `GET /orgs/nightowlstudiollc/actions/runners` shows 2 `mimolette` runners online.
- [ ] **Step 4: Wait 2 Worker ticks, about 20 minutes.** Verify: `NOS_RUNNER=mimolette`, and exactly one "online" ntfy was sent.

### Task 10: Fault drill (needs Andrew's OK)

- [ ] **Step 1: Supervisor path.** Run `container system stop` on MIMOLETTE. Expected within one supervisor loop: the supervisor sets `NOS_RUNNER=ubuntu-latest`, sends exactly one "down" alert, and takes its runners offline. The Worker sends no second alert. Then run `container system start`. Expected within about 20 minutes: the Worker sets `NOS_RUNNER=mimolette` and sends one "recovered" alert.
- [ ] **Step 2: Worker path (the crash case).** Andrew unplugs MIMOLETTE's network for 30 minutes, so nothing on it can switch the variable. Expected within about 20 minutes: the Worker sets `NOS_RUNNER=ubuntu-latest`, sends exactly one "down" alert, and cancels any stuck runs, which a later tick re-runs. After the network is plugged back in, expect one "recovered" alert within about 20 minutes.
- [ ] **Step 3: Record the timings in the runbook.** Commit them in the next in-flight PR.

### Task 11: kebab-tax pilot

**Files:**

- Modify (kebab-tax repo): `.github/workflows/ci.yml`. Change `runs-on` for `changes` (line 20), `test-mobile` (line 63), `test-workers` (line 153) and `ci-gate` (line 207) to the Global Constraints expression.

- [ ] **Step 1: Make the change in a kebab-tax worktree.** Open a PR. Its CI runs on MIMOLETTE: check each job's `runner_name` starts with `mimolette-`.
- [ ] **Step 2: Merge through the normal gate.**
- [ ] **Step 3: Measure for 3 days.** Compare kebab-tax billed minutes and job durations against Nov 1–10. Success means close to 0 GitHub-hosted minutes for `ci.yml`, and durations within 1.5x.
- [ ] **Step 4: Report the numbers to Andrew.** The follow-up work goes in its own plan: the other kebab-tax workflows except `deploy-workers.yml`, the `runner` input on the github-workflows reusable workflows, and the other NOS private repos.
