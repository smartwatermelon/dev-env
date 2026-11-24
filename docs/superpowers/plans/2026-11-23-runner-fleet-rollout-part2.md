# Runner fleet rollout, part 2: one watchdog for every pool, then the macOS pilots

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize `nos-runner-watchdog` so one Worker watches every runner pool (D5). Then add the smartwatermelon macOS pool (`SWM_MACOS_RUNNER`, label `mimolette-macos`, fallback `macos-latest`), including an automatic re-run, at most once, of a job that a runner restart stopped. After it is live, switch dotfiles `bash-tests`, then homebrew-tap `test-casks`, then mac-server-setup `bats` to the routing `runs-on`. This closes dev-env#252.

**Architecture:**

- The Worker gets a pool table (`src/pools.js`). Each pool names its org, variable, self-hosted label, fallback label, variable visibility, App secret names, KV key prefix and alert texts.
- Each pool has its own cron expression. `scheduled()` picks the pool from `event.cron`, so each pool keeps its own 40-subrequest budget and 10 ms CPU per invocation.
- `decide()` and every `github.js` function take the pool as a trailing parameter whose default is the NOS pool. The live NOS behaviour, KV keys and secret names do not change, and the existing tests pin them unedited.
- The macOS supervisor gets an idle-restart bound (D5 applies the dev-env#297 fix to every pool).

**Tech Stack:** Cloudflare Workers (module syntax, cron triggers, KV), Node `node --test`, wrangler 4 (Andrew only), bash 3.2, GitHub Actions expressions.

**Spec:** `docs/superpowers/specs/2026-11-23-runner-fleet-rollout-design.md` (phase 2, D1, D2, D5). Still binding for the macOS parts: `docs/superpowers/specs/2026-11-17-swm-macos-tart-runner-design.md` and `docs/superpowers/plans/2026-11-17-swm-macos-tart-runner.md` ("Part 2" paragraph). Issues: dev-env#252 (closed by this part), dev-env#297, dev-env#298 (D5: apply to every pool).

**Depends on:** part 1, merged 2026-11-23 (dev-env#303, #304, #305). Cite `docs/runbooks/nos-runner.md` and `test/decide.test.js` by section or test name, not line number.

## Global Constraints

- **NOS is pinned.** No existing `workers/nos-runner-watchdog/test/*.test.js` file is edited by Tasks 1 to 3. Check in each PR: `git diff --stat origin/main -- 'workers/nos-runner-watchdog/test/*.test.js'` lists only new files. New helpers go in new files (`test/pool-world.js`). `world.js` and `fakes.js` stay unchanged.
- **The NOS pool keeps its names.**
  - KV keys stay unprefixed: `state`, `pendingReruns`, `skips`, `token`, `drill`, `drill-result`.
  - Secrets stay `APP_ID`, `INSTALLATION_ID`, `APP_KEY_PKCS8`, plus the shared `NTFY_TOPIC` and `NTFY_TOKEN`.
  - Cron stays `*/10 * * * *`. Every alert text stays byte-identical.
  - Do not rename the Worker, its directory, the `STATE` binding or the KV namespace: a new name deploys a second Worker beside the live one.
- **The macOS pool:**

  | Field | Value |
  |---|---|
  | Org | `smartwatermelon` |
  | Variable | `SWM_MACOS_RUNNER` |
  | Self-hosted label | `mimolette-macos` |
  | Fallback label | `macos-latest` |
  | Visibility | `all` (as `docs/runbooks/swm-macos-runner.md` §6) |
  | KV prefix | `swm-macos:` |
  | Secrets | `SWM_APP_ID`, `SWM_INSTALLATION_ID`, `SWM_APP_KEY_PKCS8` |
  | Cron | `5,15,25,35,45,55 * * * *` |
  | Alerts | start with `macOS runner:` (macOS plan decision 8) |
  | Hold value | `macos-26`. Any value other than the label, the fallback or unset is a hold |

- **Pool config and App config are separate objects.** Part 5's `SWM_RUNNER` pool reuses the swm App (`app: "swm"`) with its own variable, label, prefix and cron.
- **Visibility is a pool field.** Part 4 (D7) changes NOS's value in one place. This part keeps NOS at `private`.
- **Routing `runs-on`, verbatim, for every pilot switch** (D1 layer C, D2). Forks and Dependabot go to hosted; otherwise the pool variable is used, then hosted:

  ```yaml
  runs-on: ${{ (((github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository) || github.actor == 'dependabot[bot]' || github.event.pull_request.user.login == 'dependabot[bot]') && 'macos-latest') || vars.SWM_MACOS_RUNNER || 'macos-latest' }}
  ```

  - The event-name guard keeps a `push` (no PR head) from reading as a fork.
  - A deleted fork head (`head.repo` null) compares unequal and goes hosted: fail-safe.
  - `github.actor` is kept on re-runs, so a re-run of a Dependabot run stays hosted.
  - No pilot workflow uses `pull_request_target` or `workflow_run`. A workflow that does must not use this expression unchanged.
- **Tests:**
  - `npm --prefix workers/nos-runner-watchdog test` after any Worker change.
  - `bash scripts/swm-macos-runner/tests/run-tests.sh` after any change under `scripts/swm-macos-runner/`.
  - `shellcheck -S info` clean on changed shell, no disable directives. Bash 3.2: no `((x++))`.
  - Never the full suite locally.
- **Agents never** create or install Apps, set secrets, deploy or `wrangler` anything, write org variables, change MIMOLETTE (the updater pulls `main`), or move tags. All of that is in **Andrew's batch**, once.
- **Live evidence must be agent-readable.** The agent cannot read swm org variables (403), so proofs use job `runner_name`, labels, run attempts and Andrew's report of the alerts. They do not use `gh variable get`.
- One PR per task, `Advances #N`. The last pilot task's proof closes #252.

## Decisions this plan takes (review these)

Decisions marked **(Andrew, 2026-11-23)** were confirmed by Andrew before execution.

1. **One cron per pool, dispatched on `event.cron`.**
   - Free-plan limits apply per invocation (50 subrequests, 10 ms CPU).
   - One tick for both pools would either cut NOS's scan budget or break `CAP`. Alternating pools on one cron would double NOS's failover time.
   - Missing `event.cron` (the existing `scheduled_entry_*` test) means NOS. An unknown cron logs `unknown cron` and does nothing.
   - Cost: one more of the account's 5 Cron Triggers (Andrew checks the count in the batch).
2. **NOS KV keys are not migrated or prefixed. New pools are.** That needs no migration and no reset. Each pool has its own `token` key, because a shared one would hand the NOS installation token to smartwatermelon calls.
3. **A pool whose three App secrets are not all set is disabled silently.** It logs `pool swm-macos not configured`, makes no KV write and no alert, and does not count a skip. So the code can merge and deploy in any order, and `secret put` before `deploy` is safe.
4. **`decide()` takes `labels = {selfHosted, fallback}` as a third parameter, default NOS.** Thresholds (`HUNG_TICKS`, `QUEUE_LIMIT_MINUTES`, two misses, `STABLE_TICKS`) stay shared and unchanged for the one-slot macOS pool. See decision 5 and Review Focus 5.
5. **One-slot gaps. (Andrew, 2026-11-23: accept the alert pair)** The macOS runner is offline between jobs (teardown, clone, boot, IP, v6 wait: usually a few minutes, worst case about 10). It is also offline during an image build (about 15 min) and an update wait (up to 900 s). Two zero-runner ticks 10 minutes apart therefore fail over only on a gap longer than about 10 minutes, which in practice means an image rebuild. This plan accepts a `down` / `recovered` alert pair on image rebuilds and documents it. A per-pool `missesToFail: 3` was rejected.
6. **The macOS alert texts:**
   - `macOS runner: down. SWM_MACOS_RUNNER set to macos-latest; stuck runs cancelled for re-run.`
   - `macOS runner: recovered. SWM_MACOS_RUNNER set to mimolette-macos.`
   - `macOS runner: online. SWM_MACOS_RUNNER was unset, now mimolette-macos.`
   - `macOS runner: held. SWM_MACOS_RUNNER=<v>; the watchdog leaves it alone.`
   - `macOS runner: watchdog skipping: <class>`
   - `macOS runner: watchdog ok: ticks are running again.`
   - `macOS runner: drill of the watchdog alert path. No action needed.`
7. **The watchdog creates `SWM_MACOS_RUNNER`. (Andrew, 2026-11-23: no hold first)**
   - Unset counts as the fallback, so about 20 minutes after deploy the watchdog creates `SWM_MACOS_RUNNER=mimolette-macos` (alert `online`). That is safe: no workflow on any `main` reads the variable before Task 8.
8. **Restart re-run (lost runner): macOS pool only, as a pure predicate.** `pool.rerunLost` is `true` for macOS and absent (`false`) for NOS, so NOS behaviour is unchanged. A wrong predicate costs at most one extra re-run of one job: `run_attempt >= 2` is never re-run. Andrew asked for at most once.
   - **No real runner-lost job exists yet** (searched 2026-11-23: every failed or cancelled dotfiles run on a `mimolette-macos-*` runner from 2026-11-15 to 2026-11-24). The two cancelled ones were cancelled by `smartwatermelon-agent[bot]` (annotation "The run was canceled by …"), not by a runner restart. So the positive fixture is a hypothesis, and the batch's restart drill (step F) is the first proof. If it fails, Task 7 fixes the predicate and Andrew redeploys once.
9. **Re-runs of lost runs send no ntfy alert.** They are logged. They are routine after a restart, and the restart itself is already visible.
10. **The `swm-runner-watchdog` App gets the NOS watchdog's permission set. (Andrew, 2026-11-23)** Org Self-hosted runners read, org Variables write, repository Actions write, installed on **All repositories** of smartwatermelon. Not Checks read: the predicate uses the jobs API only. If Task 3 shows the jobs API cannot tell a lost runner from a real failure, stop and ask before adding Checks read.
11. **macOS idle restart (dev-env#297 for every pool, D5).** The supervisor ends an idle JIT runner after `SWM_IDLE_MAX_S` (default 3600, `0` disables). It reuses the existing `bounded_check` DELETE path (422 while busy means keep waiting). Today the only bound is `SWM_JOB_MAX_S` (6 h), and a stuck single slot would flap the watchdog. The macOS pool has one slot, so the NOS "never restart while another slot is down" rule has nothing to guard there.
12. **dev-env#298 for macOS is a runbook subsection plus one pinning test,** the same as NOS option 2. The Worker gets no URL.
13. **Dependabot routing checks both `github.actor` and `pull_request.user.login`.** The latter is the prior art in `github-workflows/.github/workflows/dependabot-auto-merge.yml`. Each catches a case the other misses: Andrew pushing to a Dependabot branch, or a re-run.
14. **Order of the pilots: dotfiles, then homebrew-tap, then mac-server-setup, with no 3-day gate between them. (Andrew, 2026-11-23)** Each is its own PR with its own live proof.
15. **Closing #252.** The issue lives in dev-env and the closing PR is in another repo. The agent closes it by hand with the proofs quoted, after Task 9's proof, because #252 names dotfiles and homebrew-tap. mac-server-setup follows it.

## Review Focus

1. **NOS unchanged.** No existing `*.test.js` edited. `scheduled({scheduledTime})` with no `cron`, and with `cron: "*/10 * * * *"`, runs the NOS pool with unprefixed keys and the old secrets. Tests: `pool_nos_cron_uses_unprefixed_keys`, `pool_missing_cron_is_nos`.
2. **Pool isolation.** A macOS tick never reads or writes an unprefixed key, never sends a NOS token, never calls `/orgs/nightowlstudiollc`. A NOS tick never touches a `swm-macos:` key. Tests: `pool_macos_keys_all_prefixed`, `pool_macos_never_calls_nos_org`, `pool_tokens_not_shared`.
3. **An unconfigured pool is inert.** Missing `SWM_*` secrets give zero fetches and zero KV ops. Test: `pool_macos_unconfigured_does_nothing`.
4. **Visibility per pool.** macOS `setVar` sends `visibility: "all"` on PATCH and on the POST fallback; NOS still sends `private`. Test: `pool_macos_set_var_visibility_all`.
5. **One-slot false failover.** One tick with zero macOS runners does not switch; two do. A busy single runner with a queue that changes busy name each tick is healthy. Tests: `pool_macos_single_gap_no_switch`, `pool_macos_new_busy_name_is_progress`.
6. **The lost-run predicate never re-runs:** a fork run; a job denied by the fork guard; a job with a failed step (a real test failure); a user-cancelled run; `run_attempt >= 2`; a job on another label. Tests are listed in Task 3.
7. **lostChecked is written before the rerun POST,** so a crash cannot re-run twice. Test: `lost_checked_written_before_rerun`.
8. **The macOS idle restart never ends a busy runner** (DELETE 422 keeps the VM). Test: `idle_max_delete_422_keeps_vm`.

---

### Task 1: Pool table and `decide()` per pool (pure; no behaviour change)

**Files:**

- Create: `workers/nos-runner-watchdog/src/pools.js`
- Modify: `workers/nos-runner-watchdog/src/decide.js`
- Create: `workers/nos-runner-watchdog/test/pools.test.js`, `test/decide-pool.test.js`

**Interfaces:**

- Produces `src/pools.js`:
  - `APPS`:
    - `nos`: `{idKey: "APP_ID", installKey: "INSTALLATION_ID", keyKey: "APP_KEY_PKCS8"}`
    - `swm`: `{idKey: "SWM_APP_ID", installKey: "SWM_INSTALLATION_ID", keyKey: "SWM_APP_KEY_PKCS8"}`
  - `POOLS.nos`: `{id: "nos", app: "nos", org: "nightowlstudiollc", variable: "NOS_RUNNER", label: "mimolette", fallback: "ubuntu-latest", visibility: "private", prefix: "", cron: "*/10 * * * *", rerunLost: false, messages: {...}}`. The messages are moved verbatim from `index.js` `MESSAGES` plus the skip, ok and drill texts.
  - `POOLS.swmMacos`: `{id: "swm-macos", app: "swm", org: "smartwatermelon", variable: "SWM_MACOS_RUNNER", label: "mimolette-macos", fallback: "macos-latest", visibility: "all", prefix: "swm-macos:", cron: "5,15,25,35,45,55 * * * *", rerunLost: true, messages: {...}}` (decision 6).
  - `poolForCron(cron)`: missing or `*/10 * * * *` gives `POOLS.nos`; an unknown cron gives `null`.
  - `appEnv(env, pool)`: `{APP_ID, INSTALLATION_ID, APP_KEY_PKCS8}` read from the pool's App keys, or `null` unless all three are non-empty.
- Changes `decide(prev, observed, labels = {selfHosted: "mimolette", fallback: "ubuntu-latest"})`. Its internals read `labels` instead of the two constants.

Steps:

- [ ] **Step 1: Write the failing tests.**
  - `pools.test.js`:
    - `pool_missing_cron_is_nos`: `poolForCron(undefined) === POOLS.nos`.
    - `pool_nos_cron_is_nos`.
    - `pool_macos_cron_is_macos`.
    - `pool_unknown_cron_is_null`.
    - `pool_crons_unique`.
    - `pool_nos_messages_unchanged`: each NOS text is asserted equal to the literal string in today's `index.js`.
    - `pool_macos_messages_prefixed`: every macOS text starts with `macOS runner:`.
    - `app_env_nos_reads_old_secret_names`.
    - `app_env_swm_null_when_any_missing`: three cases, one per missing key.
    - `pool_wrangler_crons_match`: read `wrangler.toml` as text. Its `crons` array equals the pools' crons. (This test fails until Task 2 adds the second cron; in Task 1 assert only that every `wrangler.toml` cron maps to a pool, and Task 2 tightens it to equality.)
  - `decide-pool.test.js`, with `L = {selfHosted: "mimolette-macos", fallback: "macos-latest"}`:
    - `pool_macos_healthy_stays`.
    - `pool_macos_two_misses_switch_to_macos_latest`: `setVar === "macos-latest"`, `notify === "down"`, `rerunStuck`.
    - `pool_macos_unset_goes_online`: after 2 goods, `setVar === "mimolette-macos"` and `notify === "online"`.
    - `pool_macos_macos26_is_hold`.
    - `pool_macos_mimolette_value_is_hold`: the NOS label is a hold in the macOS pool.
    - `pool_macos_single_gap_no_switch`.
    - `pool_macos_new_busy_name_is_progress`: one runner, busy, queue over 20 min, a different name each tick, 4 ticks, so `setVar === null`.
    - `pool_macos_manual_flip_back_stays`: the #298 pin for macOS, the same shape as the NOS test `manual flip to mimolette with healthy runners stays mimolette`.
- [ ] **Step 2: Run them and confirm they fail.** Run `npm --prefix workers/nos-runner-watchdog test`. Expected: the new tests fail (`pools.js` is missing); every existing test passes.
- [ ] **Step 3: Implement.** Keep `FALLBACK` and `SELF_HOSTED` as the default argument. Do not change any threshold.
- [ ] **Step 4: Run** the suite. Expected: all pass. Then `git diff --stat origin/main -- workers/nos-runner-watchdog/test/` lists only the two new files.
- [ ] **Step 5: Commit** `refactor(nos-runner-watchdog): add the pool table; decide() takes the pool labels` (body `Advances #252`).

### Task 2: Pool-aware GitHub calls, tick and cron dispatch

**Files:**

- Modify: `workers/nos-runner-watchdog/src/github.js`, `src/index.js`, `wrangler.toml`, `package.json` only if needed (no new dependencies)
- Create: `test/pool-world.js` (a `worldFor(pool, opts)` that mirrors `world()` for any org, variable or label), `test/pool-index.test.js`

**Interfaces:**

- `github.js`: every function that names the org, variable or label takes a trailing `pool = POOLS.nos`. These are `getRunners`, `getVar`, `setVar` (body `{name: pool.variable, value, visibility: pool.visibility}`), `scanQueue`, `scanRepo` and `mimoletteJobs` (`labels.includes(pool.label)`). The `User-Agent` stays `nos-runner-watchdog`.
- `index.js`:
  - `runTick(env, {fetch, now, pool = POOLS.nos})`.
  - The KV wrapper prefixes every key with `pool.prefix`.
  - `FALLBACK` becomes `pool.fallback`, and messages come from `pool.messages`.
  - The token is minted with `appEnv(env, pool)`.
  - If `appEnv` is `null`, the tick returns at once with one log line and no KV or fetch.
  - `scheduled(event, env)` calls `poolForCron(event?.cron)`; `null` gives the log line `unknown cron` and returns.
- `wrangler.toml`: `crons = ["*/10 * * * *", "5,15,25,35,45,55 * * * *"]`. Update the comment to list the secrets per pool.

Steps:

- [ ] **Step 1: Write the failing tests** in `pool-index.test.js`, using `worldFor(POOLS.swmMacos, ...)` and an env with both App sets:
  - `pool_nos_cron_uses_unprefixed_keys`: `worker.scheduled({cron: "*/10 * * * *", scheduledTime: NOW}, env)`. KV ops name only `state`, `token`, `pendingReruns`, `skips` and `drill`.
  - `pool_macos_keys_all_prefixed`: a macOS tick. Every `store.ops` entry has a key starting `swm-macos:`.
  - `pool_macos_never_calls_nos_org`: no call URL contains `nightowlstudiollc`.
  - `pool_tokens_not_shared`: `token` = `ghs_nos` and `swm-macos:token` = `ghs_swm`. Every macOS call sends `Bearer ghs_swm`; a NOS tick sends `Bearer ghs_nos`.
  - `pool_macos_unconfigured_does_nothing`: env without `SWM_APP_KEY_PKCS8`. `f.calls.length === 0` and `store.ops.length === 0`, including no `skips` write.
  - `pool_macos_down_switches_and_alerts`: `state` `misses: 1`, zero runners. `PATCH .../orgs/smartwatermelon/actions/variables/SWM_MACOS_RUNNER` with value `macos-latest`. The ntfy body equals the macOS `down` text. Queued `mimolette-macos` jobs are cancelled and land in `swm-macos:pendingReruns`.
  - `pool_macos_set_var_visibility_all`: PATCH 404, then the POST body is `{name: "SWM_MACOS_RUNNER", value: "mimolette-macos", visibility: "all"}`.
  - `pool_macos_ignores_mimolette_jobs`: a queued job labelled `mimolette` (NOS label) in an swm repo is not counted and not cancelled.
  - `pool_macos_subrequests_at_most_40`: the worst-case world from `subrequests_per_tick_at_most_40`, built with `worldFor`.
  - `pool_macos_drill_prefixed`: `swm-macos:drill` sends the macOS drill text and writes `swm-macos:drill-result`. A plain `drill` key is untouched.
  - `pool_unknown_cron_does_nothing`: zero calls.
  - `pool_scheduled_logs_no_secrets`: the macOS copy of `scheduled_entry_uses_global_fetch_and_never_logs_secrets` with the `SWM_*` key and token.
  - Tighten `pool_wrangler_crons_match` (Task 1) to equality.
- [ ] **Step 2: Run** the suite. Expected: the new tests fail; all old ones pass.
- [ ] **Step 3: Implement.** Thread `pool` through, change no NOS literal, and keep the `RESERVE_*` and `OPTIONAL_SHARE` constants.
- [ ] **Step 4: Run** the suite. Expected: all pass; `git diff --stat origin/main -- 'workers/nos-runner-watchdog/test/*.test.js'` lists only new files.
- [ ] **Step 5: Commit** `feat(nos-runner-watchdog): watch the smartwatermelon macOS pool from the same Worker` (body `Advances #252`). The PR body says that merging deploys nothing: Andrew deploys, in the batch.

### Task 3: Re-run a job that a runner restart stopped (macOS pool)

**Files:**

- Create: `workers/nos-runner-watchdog/src/lost.js` (the pure predicate), `test/lost.test.js`, `test/fixtures/` (job JSON, trimmed to the fields used)
- Modify: `src/github.js` (`listFailedRuns(token, repo, sinceIso, fetchFn)`: `GET /repos/{repo}/actions/runs?status=failure&created=>=<since>&per_page=20&exclude_pull_requests=true`), `src/index.js` (optional phase, only when `pool.rerunLost`)

**Interfaces:**

- `lostRunner(run, jobs, pool)` returns `true` only when all of these hold:
  - `run.run_attempt === 1`;
  - `run.conclusion === "failure"`;
  - `run.head_repository?.full_name === run.repository?.full_name`;
  - `run.actor?.login !== "dependabot[bot]"`;
  - at least one job has `labels` including `pool.label`, `conclusion === "failure"`, and no step with `conclusion === "failure"`.
- KV `<prefix>lostChecked`: `{"<repo>#<runId>": epochMs}`, pruned after 6 h.
- Optional phase, after the pending loop, for each scanned repo while budget allows:
  1. `listFailedRuns` since `now - 6h`.
  2. For runs not in `lostChecked`, `getJobs`.
  3. If the predicate holds, write `lostChecked` first, then `rerunFailed`.
  4. Mark every probed run checked, so it is probed once.

  The phase stays inside `optional()` with `RESERVE_FINAL`.

Steps:

- [ ] **Step 1: Capture the negative fixtures (read-only `gh api`).**
  - **(a) A fork-guard denial.** The dotfiles#511 runs: `gh api repos/smartwatermelon/dotfiles/actions/runs/<id>/jobs`.
  - **(b) A real test failure on `mimolette-macos`:** dotfiles run 44443375980 (`bash-tests`, a failed step).
  - **(c) A user-cancelled run:** dotfiles run 44395263750 (cancelled by `smartwatermelon-agent[bot]`).
  - Save each, redacted to `{status, conclusion, labels, runner_name, steps[].{name,conclusion}}` and the run's `{run_attempt, conclusion, head_repository.full_name, repository.full_name, actor.login, event}`.
  - The positive fixture is written from the hypothesis and named `hypothesis-runner-lost.json` (decision 8). The batch's restart drill (step F) replaces it.
- [ ] **Step 2: Write the failing tests** (`lost.test.js`):
  - `lost_runner_job_is_rerun` (hypothesis fixture).
  - `lost_fork_guard_denial_not_rerun` (fixture a).
  - `lost_real_failure_not_rerun` (fixture b).
  - `lost_cancelled_run_not_rerun` (fixture c).
  - `lost_fork_run_not_rerun`: the head repo differs.
  - `lost_dependabot_run_not_rerun`.
  - `lost_attempt_2_not_rerun`.
  - `lost_other_label_not_rerun`: the job is labelled `macos-latest`.
  - `lost_nos_pool_never_scans`: a NOS tick makes no `status=failure` call.
  - `lost_checked_written_before_rerun`: in `seq`, `kv put swm-macos:lostChecked` comes before `POST .../rerun-failed-jobs`.
  - `lost_run_probed_once`: two ticks give one `getJobs` per run.
  - `lost_checked_pruned_after_6h`.
  - `lost_budget_never_breaks_cap`: subrequests at most 40 with 25 repos and 5 failed runs each.
- [ ] **Step 3: Run** the suite. Expected: the new tests fail; the old ones pass.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run** the suite. Expected: all pass, and no existing `*.test.js` changed.
- [ ] **Step 6: Commit** `feat(nos-runner-watchdog): re-run once a macOS job a runner restart stopped` (body `Advances #252`). The PR body states that the positive fixture is a hypothesis, and why.

### Task 4: macOS supervisor ends a runner idle past `SWM_IDLE_MAX_S` (dev-env#297 for every pool)

**Files:**

- Modify: `scripts/swm-macos-runner/config.sh` (`: "${SWM_IDLE_MAX_S:=3600}"`), `scripts/swm-macos-runner/supervisor.sh` (`bounded_check`), `scripts/swm-macos-runner/install.sh` only if the env-file knob list needs it (it accepts `SWM_<NAME>_S`, so likely not)
- Test: `scripts/swm-macos-runner/tests/test-supervisor.sh`

**Interfaces:**

- `bounded_check` today runs only with `update-pending`. It now also runs when the runner has been handed its JIT config for at least `SWM_IDLE_MAX_S` (`0` disables).
- The same DELETE: a 2xx ends the VM, neutral (not a fail). A 422 or 404 keeps waiting.
- Log: `runner N idle for S s (limit L s); ending VM <vm>`. Reuse the `IDLE_ENDED` flow.

Steps:

- [ ] **Step 1: Write the failing tests:**
  - `idle_max_ends_idle_runner`: the DELETE is 2xx, and the VM is stopped and deleted.
  - `idle_max_delete_422_keeps_vm`.
  - `idle_max_404_keeps_vm`.
  - `idle_max_not_a_fail`: the fail count is unchanged.
  - `idle_max_disabled_at_zero`.
  - `idle_max_young_runner_untouched`.
  - `idle_max_update_path_unchanged`: the existing update-pending cases still pass unedited.
- [ ] **Step 2:** Run `bash scripts/swm-macos-runner/tests/run-tests.sh`. Expected: the new cases `FAIL`.
- [ ] **Step 3: Implement.** First add up the worst-case shutdown time: it is unchanged, since no new tart call is added.
- [ ] **Step 4: Run** the tests (expected exit 0, no `FAIL`) and `shellcheck -S info` on the changed scripts (no output).
- [ ] **Step 5: Runbook:** a line in `docs/runbooks/swm-macos-runner.md` §7 for the new log line.
- [ ] **Step 6: Commit** `fix(swm-macos-runner): end a runner that waits too long for a job` (body `Advances #297`). The updater installs it on MIMOLETTE. Live proof: Task 7.

### Task 5: Runbooks for the multi-pool watchdog and the new App

**Files:**

- Modify `docs/runbooks/nos-runner.md`:
  - §1: the App table gains a pointer to the swm App.
  - §3: the key conversion for both Apps.
  - §7: deploy covers both pools; secret lists per pool; both crons; `kv key list` shows `state` and `swm-macos:state`; never `kv key get swm-macos:token`; per-pool full stop by cron; the cron count.
  - §8: drill keys per pool.
- Modify `docs/runbooks/swm-macos-runner.md`:
  - Replace "The supervisor never writes … You set it by hand" with "The watchdog Worker writes it".
  - The table: unset and `macos-latest` are not holds once the watchdog runs.
  - §6: replace "There is no watchdog for this runner yet …". Full stop now also needs the hold. A new "After a manual fix" subsection (the #298 pattern) with `gh variable set SWM_MACOS_RUNNER --org smartwatermelon --visibility all --body mimolette-macos`.
  - A new section "Routing": the verbatim `runs-on` expression and why each clause is there.
  - §7: the watchdog's alerts, the image-rebuild `down`/`recovered` pair (decision 5), and lost-run re-runs (decision 9).
- Modify: `CLAUDE.md` runbook line, only if it describes the watchdog as NOS-only.

Steps:

- [ ] **Step 1:** Write the sections. Every command matches the batch below exactly.
- [ ] **Step 2:** markdownlint (the repo hook) clean.
- [ ] **Step 3: Commit** `docs(runners): one watchdog for both pools; macOS routing and recovery` (body `Advances #252, Advances #298`).

### Task 6: Stage the drills (agent, just before the pause)

**Files:** none in dev-env. One draft dotfiles PR (never merged).

- [ ] **Step 1:** Open a draft PR on `smartwatermelon/dotfiles` from branch `drill/watchdog-macos`. It adds `.github/workflows/watchdog-drill.yml` with two jobs:
  - **`restart-drill`:** `runs-on: mimolette-macos`, `timeout-minutes: 40`, step `sleep 1500`. Trigger `pull_request: types: [reopened]` only, so opening the PR runs nothing.
  - **`route-probe`:** the verbatim routing expression, and a step that prints `$RUNNER_NAME`.

  The draft PR stays open. Closing and reopening gives a fresh `run_attempt` 1, which the at-most-once rule needs.
- [ ] **Step 2:** Confirm Tasks 1 to 5 are merged and `main` CI is green. Record the PR number in the batch text and hand the batch to Andrew.

---

## ANDREW'S BATCH (execution pauses here)

Everything below needs Andrew's hands. Run it in order, in one sitting (about 90 minutes, mostly waiting). Report the marked outputs back.

**A. Pre-checks (read-only):**

```bash
npx wrangler@4 whoami                                   # nightowlstudio account
# Cloudflare dashboard → Workers & Pages → count Cron Triggers across the account; must be ≤ 4 before deploy (Free limit 5).
gh variable list --org smartwatermelon | grep SWM_MACOS_RUNNER || echo unset   # REPORT the value
```

The watchdog creates `SWM_MACOS_RUNNER=mimolette-macos` about 20 minutes after deploy, with an `online` alert (decision 7). No workflow on `main` reads it yet.

**B. Create the `swm-runner-watchdog` App** (GitHub UI, smartwatermelon org → Settings → Developer settings → GitHub Apps → New):

1. Name `swm-runner-watchdog`. Webhook off.
2. Permissions: Organization **Self-hosted runners: Read**, Organization **Variables: Read and write**, Repository **Actions: Read and write** (Metadata read is automatic). Nothing else.
3. "Only on this account". Create. **REPORT the App ID.**
4. Install on smartwatermelon, **All repositories**. **REPORT the installation ID** (from the installation URL).
5. Generate a private key, then:

```bash
openssl pkcs8 -topk8 -nocrypt -in swm-runner-watchdog.*.pem -out swm-runner-watchdog.pkcs8.pem
op document create swm-runner-watchdog.pkcs8.pem --title swm-runner-watchdog-pkcs8 --vault Automation
```

Keep the PEM until step C works, then delete both files.

**C. Worker secrets** (from `~/Developer/dev-env/workers/nos-runner-watchdog`, after `git pull`). These go before deploy, so the old code ignores them:

```bash
printf '%s' <app-id> | npx wrangler@4 secret put SWM_APP_ID
printf '%s' <installation-id> | npx wrangler@4 secret put SWM_INSTALLATION_ID
op document get swm-runner-watchdog-pkcs8 --vault Automation | npx wrangler@4 secret put SWM_APP_KEY_PKCS8
```

**D. Deploy:**

```bash
npm test && npx wrangler@4 deploy        # REPORT: the triggers line lists both crons
```

**E. Check both pools (wait 20 minutes):**

```bash
npx wrangler@4 kv key list --binding STATE --remote   # REPORT: shows state AND swm-macos:state
npx wrangler@4 kv key put swm-macos:drill 1 --binding STATE --remote
# wait ~12 min
npx wrangler@4 kv key get swm-macos:drill-result --binding STATE --remote   # REPORT
```

Expected: the ntfy alert "macOS runner: drill of the watchdog alert path". The NOS runner shows no new alerts. If unset, also expect `macOS runner: online …`.

**F. Restart drill** (proves the lost-run re-run):

```bash
gh pr close <N> --repo smartwatermelon/dotfiles && gh pr reopen <N> --repo smartwatermelon/dotfiles
gh run list --repo smartwatermelon/dotfiles --workflow watchdog-drill.yml --limit 1   # wait until in_progress
```

Then, on MIMOLETTE in the GUI session, once `restart-drill` has run for 2 minutes:

```bash
launchctl kickstart -k gui/$(id -u)/com.smartwatermelon.swm-macos-runner
```

Expected:

- The job fails.
- Within about 2 macOS ticks after it is marked failed, attempt 2 appears and runs on a new `mimolette-macos-*` runner.
- No alert.

Report nothing; the agent reads the run.

**G. Failover drill** (proves #252's fallback). On MIMOLETTE:

```bash
launchctl bootout gui/$(id -u)/com.smartwatermelon.swm-macos-runner
```

1. Wait for `macOS runner: down. SWM_MACOS_RUNNER set to macos-latest …` (20 to 30 min). **REPORT the time.**
2. Run `gh pr close <N> --repo smartwatermelon/dotfiles && gh pr reopen <N> --repo smartwatermelon/dotfiles`. The `route-probe` job now runs hosted.
3. Run `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.smartwatermelon.swm-macos-runner.plist`.
4. Wait for `macOS runner: recovered …` (about 20 min). **REPORT the time.**
5. Close and reopen the PR once more. `route-probe` runs on `mimolette-macos-*`.

**H.** Tell the agent "batch done", with the REPORT values. Nothing else on MIMOLETTE changes. Task 4 arrives through the updater.

---

### Task 7: Read the batch evidence (agent)

- [ ] **Step 1:** From the draft PR's runs (`gh api .../runs/<id>/jobs` per attempt), record:
  - **F:** attempt 1's job JSON (the real runner-lost signature), and whether attempt 2 exists, when it started and its `runner_name`.
  - **G:** `route-probe` `runner_name` while down (hosted, `GitHub Actions …`) and after recovery (`mimolette-macos-…`).
- [ ] **Step 2:**
  - **If F re-ran:** replace `hypothesis-runner-lost.json` with the real fixture in a small PR (`test(nos-runner-watchdog): real runner-lost fixture`). That PR needs no deploy if the predicate is unchanged.
  - **If F did not re-run:** fix the predicate in a PR with the real fixture. It needs one Andrew redeploy (`npx wrangler@4 deploy`). Report this to Andrew as the one known follow-up; do not fold it silently.
- [ ] **Step 3: Task 4 proof.** After the first idle hour, read `~/Library/Logs/swm-macos-runner.log` through `agentro` (`docs/runbooks/agent-ro.md`). Expected: `runner N idle for … ending VM`, then a new runner online. Quote it on #297.
- [ ] **Step 4:** Close the draft PR and delete the drill branch.

### Task 8: dotfiles pilot: `bash-tests` uses the routing `runs-on`

**Files:** `smartwatermelon/dotfiles` `.github/workflows/bash-tests.yml` (re-read it on `origin/main` first; the local clone may be stale).

- [ ] **Step 1:** Replace `runs-on: macos-latest` with the verbatim expression. Extend the existing comment: macOS is still load-bearing. Add one line on why forks and Dependabot go hosted (D1, D2), pointing to the dev-env runbook "Routing" section.
- [ ] **Step 2:** The PR's own `bash-tests` run is a same-repo PR. Expected: `runner_name` `mimolette-macos-*` (or hosted if `SWM_MACOS_RUNNER` is held), and the log shows `job-started hook: allowed pull_request`.
- [ ] **Step 3: Fork drill** (memory `reference-fork-drill-fork`):
  - Push a branch to `nightowlstudiollc/dotfiles` as `nightowlstudiollc-agent`.
  - Open the PR into smartwatermelon/dotfiles as `smartwatermelon-agent` with `--no-maintainer-edit`.
  - Expected: `bash-tests` runs hosted (`runner_name` not `mimolette-macos-*`).
  - Close it.
- [ ] **Step 4:** Dependabot. The next Dependabot PR's `bash-tests` runs hosted. If none arrives within the measure window, record that as not yet proven, in the PR comment and on #252.
- [ ] **Step 5: Commit** `ci(bash-tests): run on MIMOLETTE through SWM_MACOS_RUNNER` (body `Advances smartwatermelon/dev-env#252`). Merge per dotfiles policy.

### Task 9: homebrew-tap `test-casks`

**Files:** `smartwatermelon/homebrew-tap` `.github/workflows/test-casks.yml`.

- [ ] **Step 1:** The same switch and comment. The job installs casks for real; in a disposable Tart VM that is the Protocol 3 case (#252).
- [ ] **Step 2: Proof:**
  - The PR run and the following `push` to `main` both run on `mimolette-macos-*`.
  - The push run proves the event-name guard: no false fork.
  - Every cask step passes.
  - If a cask needs a GUI or TCC grant the VM lacks, stop and report. Do not add sudo or TCC changes.
- [ ] **Step 3: Commit** `ci(test-casks): run on MIMOLETTE through SWM_MACOS_RUNNER` (body `Advances smartwatermelon/dev-env#252`).
- [ ] **Step 4:** Close dev-env#252 with the proofs from Tasks 7 to 9 quoted (decision 15).

### Task 10: mac-server-setup `bats`

**Files:** `smartwatermelon/mac-server-setup` `.github/workflows/bats.yml`, the `bats` job only (`docs.yml` stays `ubuntu-latest`: a deploy and link check, class 3 and 4 under D3).

- [ ] **Step 1:** The same switch. Keep `timeout-minutes: 15` and the concurrency group. `cancel-in-progress` cancels on our runner too. That is fine: it is a user-side cancel, never re-run by the watchdog.
- [ ] **Step 2: Proof:** a PR run and a push run on `mimolette-macos-*`, passing.
- [ ] **Step 3: Commit** `ci(bats): run on MIMOLETTE through SWM_MACOS_RUNNER`. Fold the STATUS.md line for phase 2 into this PR or the dev-env runbook PR (spec phase 8: no standalone PR).

---

## Later parts (unchanged from part 1's table)

Parts 3 to 6 as listed in `2026-11-23-runner-fleet-rollout-part1.md`. Part 4 changes `POOLS.nos.visibility` (one field) plus `supervisor.sh` `VAR_BODY`. Part 5 adds `POOLS.swmLinux` with `app: "swm"`, its own prefix and its own cron (the account then holds 3 of 5 Cron Triggers).

## Questions the sources do not answer

1. **How GitHub marks a job whose runner was stopped:** conclusion `failure` or `cancelled`, the step conclusions, whether a runner-lost annotation is needed. No recorded instance exists (decision 8). The batch's step F settles it, possibly at the cost of one more redeploy.
2. **The account's current Cron Trigger count** on the nightowlstudio Cloudflare account (Free limit 5). It is not recorded anywhere.
3. ~~Pilot gate~~: settled by Andrew 2026-11-23, no 3-day gate (decision 14).
4. **The current value of `SWM_MACOS_RUNNER`.** The agent cannot read swm org variables (403). The runbook suggests it is unset.
5. **Dependabot on self-hosted runners** (fleet spec "To verify"): whether GitHub treats a Dependabot PR's jobs like other PRs on self-hosted labels. The routing sends them hosted anyway, but Task 8 Step 4 may not get a Dependabot PR to prove it in time.
6. **Long macOS jobs vs `HUNG_TICKS`.** A single busy runner whose busy name stays the same for 3 ticks, with another job queued, fails over after about 30 minutes. No duration for homebrew-tap `test-casks` was measured. mac-server-setup `bats` is capped at 15 minutes. If `test-casks` can run over about 25 minutes, the shared threshold needs a per-pool override. Measure before Task 9.
7. **Fork-PR approval did not gate dotfiles#511.** Memory `reference-fork-drill-fork` records that the fork-drill runs started with no approval step, even though dotfiles' policy is `all_external_contributors`. Layer 3 of D1 ("fork-PR approval, live") may not hold for a fork owned by an org account. This does not change the plan, since routing and the guard still apply, but the spec's layer-3 claim should be re-checked.
8. **Where the swm App key lives.** The NOS watchdog key's 1Password name (`nos-runner-watchdog-pkcs8`) is documented. The batch assumes the same pattern (`swm-runner-watchdog-pkcs8`, vault Automation).
