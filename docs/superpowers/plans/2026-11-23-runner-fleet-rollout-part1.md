# Runner fleet rollout, part 1: harden the existing pools

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before the fleet adds load, fix the gaps in the live pools that an outage on 2026-11-20 exposed. Fixes: a NOS slot that waits forever for a job (dev-env#297), no fast path back after a manual fix (dev-env#298), and the still-valid minor findings from macOS plan part 1 (dev-env#294).

**Architecture:** The NOS supervisor (`scripts/nos-runner/supervisor.sh`, bash 3.2, launchd) gets one new pass step, `restart_stale_slots`. It deletes and replaces a runner that GitHub reports idle after it has waited longer than `NOS_IDLE_MAX_S`. The runbook gets a manual-recovery section, and the watchdog's existing `external` reset is the mechanism. The macOS supervisor gets small, separate fixes.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), stubbed test harnesses in `scripts/*/tests/`, shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-23-runner-fleet-rollout-design.md` (phase 1). Issues: dev-env#297, dev-env#298, dev-env#294.

## Global Constraints

- Every shell change: `shellcheck -S info <script>` clean, no `# shellcheck disable`.
- Never `((var++))` under `set -e`; use `((var += 1))`.
- Every destructive command goes through an injected `*_BIN` variable, and the tests stub it (Protocol 3). Tests never reach a real `container`, `tart`, `curl` or `rm`.
- Tests: `bash scripts/nos-runner/tests/run-tests.sh` after any change under `scripts/nos-runner/`; `bash scripts/swm-macos-runner/tests/run-tests.sh` after any change under `scripts/swm-macos-runner/`. Never the full suite locally.
- Nothing is installed on MIMOLETTE by this plan. The updater pulls `main` after merge; any step on MIMOLETTE needs Andrew's OK.
- One PR per task, `Advances #N` unless the task closes the whole issue.

## Decisions this plan takes (review these)

The spec does not settle these. They are stated here so Andrew can overrule them before execution:

1. **`NOS_IDLE_MAX_S` default 3600 (1 hour).** A restart of an idle VM costs one JIT mint and one VM boot, so a short limit is cheap. On a quiet night each slot restarts about once an hour. The 2026-11-20 hang (51 h) would have ended within an hour.
2. **Delete the runner before stopping its VM.** Once GitHub has deleted the runner, it cannot hand that runner a job, so the stop cannot kill a job. The remaining race is a job assigned between the `busy=false` read and the DELETE. It is not proven whether GitHub refuses to DELETE a busy runner.
3. **No ntfy alert for idle restarts.** They are routine on quiet nights, so an alert would be noise. Restarts are logged. The watchdog still alerts on a real outage.
4. **dev-env#298 takes option 2 (manual recovery, runbook only).** It adds no URL to the Worker, keeping `workers_dev = false`. `decide()` already resets its counters when the variable changes from outside.
5. **dev-env#294: fix 5 items, defer the rest** (list in Task 3).

## Review Focus

1. A slot whose runner is busy past `NOS_IDLE_MAX_S` (a long real job) must never be restarted. Test: `idle_restart_skips_busy`.
2. A failed or unreadable busy check (HTTP 500, no token) counts as busy and does not restart. Test: `idle_restart_skips_unknown`.
3. A DELETE that fails must leave the VM running and the slot unchanged, to retry on the next pass. Test: `idle_restart_delete_fails_keeps_vm`.
4. A stop that fails after a good DELETE must not start a third VM. The `dropped-N` marker makes a later pass stop it. Test: `idle_restart_stop_fails_marks_dropped`.
5. A restart must not count as a failed start, since a count of 3 fails the pool over. Test: `idle_restart_not_a_fail`.

---

### Task 1: NOS supervisor restarts a slot idle past `NOS_IDLE_MAX_S` (dev-env#297)

**Files:**

- Modify: `scripts/nos-runner/config.sh` (add the default)
- Modify: `scripts/nos-runner/supervisor.sh` (new function; call in `cmd_once`)
- Modify: `scripts/nos-runner/tests/test-supervisor.sh` (curl stub flag + cases)
- Modify: `docs/runbooks/nos-runner.md` section 9 (log line)

**Interfaces:**

- Consumes: `slot_load`/`slot_put`, `runner_idle ID`, `delete_runner ID`, `stop_slot N`, `now`, `log`, the `dropped-N` marker and `reconcile`'s handling of it (all in `supervisor.sh`).
- Produces: `restart_stale_slots` (no args, returns 0); config `NOS_IDLE_MAX_S` (seconds, default 3600; `0` disables). Log line: `slot N: runner ID idle for S s (limit L s); restarting`.

- [ ] **Step 1: Add a stub flag.** In the curl stub's `"GET "*/actions/runners/*` branch, reply `'{"message":"boom"}' 500` when `STUB_RUNNER_GET_FAIL` is set.

- [ ] **Step 2: Write the failing tests** in `test-supervisor.sh`, after the existing busy cases. Each starts with `reset; sup once` (2 slots, runners 101 and 102). It then ages slot 1 by rewriting its `started=` to `$(( $(date +%s) - 7200 ))` in `${S}/state/slot-1`, and runs `NOS_IDLE_MAX_S=3600 sup once`.
  - `idle_restart_replaces_old_idle_slot`: `DELETE .../runners/101` appears in `order.log` before `stop mimolette-1-`; `sup.err` contains `slot 1: runner 101 idle for`; after a third `sup once`, `runs` is 3 (one new VM).
  - `idle_restart_skips_young_slot`: slot 1 not aged → no `DELETE .../101`, no `stop mimolette-1-`.
  - `idle_restart_skips_busy`: aged, `echo 101 >"${S}/busy"` → no DELETE of 101, no stop of slot 1.
  - `idle_restart_skips_unknown`: aged, `STUB_RUNNER_GET_FAIL=1` → no DELETE of 101.
  - `idle_restart_delete_fails_keeps_vm`: aged, `STUB_DELETE_FAIL=1` → no `stop mimolette-1-`; `slot-1` still has `name=mimolette-1-`.
  - `idle_restart_stop_fails_marks_dropped`: aged; make the container stub's `stop` fail (add `STUB_STOP_FAIL` if the stub lacks one) → `${S}/state/dropped-1` exists; `runs` stays 2 after the pass.
  - `idle_restart_not_a_fail`: after a restart, `slot-1` has `fails=0`.
  - `idle_restart_disabled_at_zero`: aged, `NOS_IDLE_MAX_S=0` → no DELETE of 101.

- [ ] **Step 3: Run the tests and confirm they fail.**
  Run: `bash scripts/nos-runner/tests/test-supervisor.sh 2>&1 | grep -E 'FAIL: idle_restart'`
  Expected: one `FAIL` line per `idle_restart_*` assertion that needs the new code. The `skips_*` and `disabled` cases may already pass.

- [ ] **Step 4: Implement.** In `config.sh`, add `: "${NOS_IDLE_MAX_S:=3600}"`. In `supervisor.sh`, add `restart_stale_slots`. For each slot with `SL_NAME` and `SL_ID` set and `NOS_IDLE_MAX_S > 0`, where `now - SL_STARTED >= NOS_IDLE_MAX_S` and `runner_idle "${SL_ID}"` holds:
  1. `delete_runner`. If that fails, log and continue.
  2. Touch `dropped-N`, log the line above, then `stop_slot N`.
  3. Leave `id=` and `fails=` as they are: `deregister_pending` clears `id=` on a later pass, and a 404 is fine there.

  Call it in `cmd_once` right after `deregister_pending` (line 528) and before `slots_ok`. Comment the race named in decision 2.

- [ ] **Step 5: Run the tests and confirm they pass.**
  Run: `bash scripts/nos-runner/tests/run-tests.sh`
  Expected: no `FAIL` lines, exit 0. Then `shellcheck -S info scripts/nos-runner/supervisor.sh scripts/nos-runner/config.sh scripts/nos-runner/tests/test-supervisor.sh` prints nothing.

- [ ] **Step 6: Runbook.** In `docs/runbooks/nos-runner.md` section 9, add the log line and its meaning. In section 5 or 8, add one sentence: a quiet night restarts each slot about hourly, and that is normal.

- [ ] **Step 7: Commit** (message `fix(nos-runner): restart a slot whose runner waits too long for a job`, body `Closes #297`).

### Task 2: Runbook: recover at once after a manual fix (dev-env#298)

**Files:**

- Modify: `docs/runbooks/nos-runner.md` (new subsection in section 6)
- Modify: `workers/nos-runner-watchdog/test/decide.test.js` (one pinning test)

**Interfaces:**

- Consumes: `decide(prev, observed)` in `workers/nos-runner-watchdog/src/decide.js`: `external = prev.lastVar !== null && current !== prev.lastVar` resets `misses` and `goods`.
- Produces: runbook subsection "After a manual fix".

- [ ] **Step 1: Write a pinning test** `manual flip to mimolette with healthy runners stays mimolette`. `prev = {lastVar: "ubuntu-latest", misses: 0, goods: 1, flaps: 2}`, `observed = {varValue: "mimolette", runners: [{name: "a", busy: false}, {name: "b", busy: false}], oldestQueuedMinutes: null}`. Assert `setVar === null` and `next.lastVar === "mimolette"`. Add a second case: the same `prev` with `runners: []` gives `next.misses === 1` and `setVar === null`. It must take a second miss to fail over again.

- [ ] **Step 2: Run it.** `npm --prefix workers/nos-runner-watchdog test`. Expected: pass. This pins existing behaviour, so a pass on first run is correct. If it fails, stop and report: the runbook step would be wrong.

- [ ] **Step 3: Write the subsection.** Steps for Andrew:
  1. Confirm both slots are up: `tail` of the supervisor log shows `started mimolette-N-…` for each slot, or the org runners page lists 2 idle `mimolette` runners.
  2. Run `gh variable set NOS_RUNNER --org nightowlstudiollc --body mimolette` in his own terminal (agents cannot write org variables).
  3. Expect no "recovered" alert. If the runners are unhealthy, the watchdog fails over again after 2 bad ticks (about 20 minutes).

  Replace the line-106 sentence "To end it sooner, set `NOS_RUNNER` back to `mimolette` by hand." with a pointer to this subsection.

- [ ] **Step 4: Commit** (`docs(nos-runner): recover at once after a manual fix`, body `Closes #298`). In the PR body, say that option 1 (an on-demand URL) was not taken, and why.

### Task 3: macOS supervisor: the still-valid findings from part 1 (dev-env#294)

**Files:**

- Modify: `scripts/swm-macos-runner/supervisor.sh` (`slot_load`, line 70), `scripts/swm-macos-runner/lib.sh` (the `kill -9` paths, lines 49-80), `scripts/swm-macos-runner/image/build-image.sh`, `scripts/swm-macos-runner/config.sh`, `scripts/nos-runner/net/pf-guard.sh` (`warn_swm_v6`, line 40)
- Test: `scripts/swm-macos-runner/tests/test-supervisor.sh`, `test-build-image.sh`, `scripts/nos-runner/tests/test-pf-guard.sh`

**Interfaces:**

- Consumes: `slot_load` (sets `SL_ID`), `delete_runner`, the build's SIGTERM path.
- Produces: no new names.

Check each item against `main` first; #289 to #293 may have fixed some. Skip any that are already fixed, and say so in the PR body.

- [ ] **Step 1: Slot id validation (Task 5 finding).** Test `slot_id_not_numeric_is_not_sent`: a state file with `id=../x` gives no request whose URL contains `../x`, and the log names the bad id. Implement: in `slot_load`, clear `SL_ID` unless it matches `^[0-9]+$`, and log.
- [ ] **Step 2: TERM before KILL for the build (Task 5 finding).** Test in `test-build-image.sh` or `test-supervisor.sh`: on SIGTERM during a build, the stub build first receives TERM, and KILL only after a grace period. Implement in `lib.sh`'s bounded kill (send `"${KILL_BIN}" -TERM`, wait a few seconds, then `-9`), so the build's EXIT trap can delete `swm-build-tmp`. This changes every bounded command, not only the build; the tests for bounded timeouts must still pass.
- [ ] **Step 3: v6 warning rate (Task 3 finding).** In `pf-guard.sh` `warn_swm_v6`, log only when the v6 state changes, not every 60 s. Test in `test-pf-guard.sh`: two runs with the same failed v6 load give one warning line. This also changes `scripts/nos-runner/`, so run its suite too.
- [ ] **Step 4: Comments only.** Fix the stale `build-image.sh:81` "not bounded" comment. Add a pointer comment on `_swm_image_hash` saying it copies `_nos_image_hash`. Document in `config.sh` that the IP bound (`SWM_IP_LIMIT_S + 10 = 190`) exceeds 180 on purpose.
- [ ] **Step 5: Run** `bash scripts/swm-macos-runner/tests/run-tests.sh` and `bash scripts/nos-runner/tests/run-tests.sh` (expected exit 0, no `FAIL`) and `shellcheck -S info` on each changed script (expected no output).
- [ ] **Step 6: Commit** (`fix(swm-macos-runner): part 1 review follow-ups`, body `Advances #294`). Comment on #294 listing what was fixed, what was already fixed, and what is deferred: test-label naming, stdout vs stderr, the missing-head test cases, the `pf_fail` placement, the okseen probe, the delete-limit reuse, the `ip --wait` race, the readiness-probe overshoot and the shared pf dedupe.

---

## Later parts (one plan each, written after part 1 ships)

| Part | Spec phase | Content |
|---|---|---|
| 2 | 2 + D5 | Generalize `nos-runner-watchdog` to all pools (per-pool state, label, fallback, App key). Then macOS plan part 2: `swm-runner-watchdog` App, re-runs, dotfiles pilot, then homebrew-tap, mac-server-setup |
| 3 | 3 | github-workflows: `runner` input on dependabot-auto-merge, semgrep-scan, netlify-site-checks; canary first |
| 4 | 4 + D7 | NOS: the fork guard in the NOS image (`ALLOWED_OWNERS=nightowlstudiollc`), group allows public repos, `NOS_RUNNER` visible to the 4 public repos, fork drill; then switch class-1 jobs repo by repo; move the kebab-tax deploy job back to hosted |
| 5 | 5 + D1 | swm Linux pool (`SWM_RUNNER`) with the fork guard, on MIMOLETTE's existing RAM budget; fork drill; switch swm repos |
| 6 | 6 + D6 | Templates, NOS bootstrap (dev-env#264), standards-check drift warning |

Every part routes `runs-on` the same way: a fork PR or `dependabot[bot]` gets the hosted label, and otherwise the pool's variable is used, falling back to the hosted label.
