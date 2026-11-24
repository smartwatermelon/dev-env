# smartwatermelon macOS runner: install, operate, undo

smartwatermelon macOS CI jobs run on MIMOLETTE, in one Tart VM per job, one job at a time.
A workflow opts in with the routing `runs-on` expression (section 9). It sends fork and Dependabot runs to GitHub-hosted runners.
The `SWM_MACOS_RUNNER` org variable picks the runner label:

| Value | Where jobs run |
|---|---|
| unset | GitHub-hosted `macos-latest`. The watchdog sets it to `mimolette-macos` when the runner is healthy, so unset is not a hold |
| `macos-latest` | GitHub-hosted. This is the watchdog's failover value. The watchdog moves it back to `mimolette-macos` when the runner is healthy, so it is not a hold |
| `mimolette-macos` | This runner |
| `macos-26` | GitHub-hosted `macos-26`. This is the hold value (section 6) |

The watchdog Worker writes `SWM_MACOS_RUNNER`. The supervisor never does. Any value other than the three above, `macos-latest` or unset counts as a hold.
The watchdog is the same Worker as the NOS one: `docs/runbooks/nos-runner.md`, section 7. It checks every 10 minutes
(cron `5,15,25,35,45,55 * * * *`), moves the variable to `macos-latest` after two checks with no healthy runner,
and back to `mimolette-macos` after healthy checks. You can still set the variable by hand (section 6).
Design: `docs/superpowers/specs/2026-11-17-swm-macos-tart-runner-design.md`.

Run every step in a terminal on MIMOLETTE, in a GUI login session.
launchd starts the supervisor in `gui/<uid>`, so Tart runs there too, never through ssh.

## 1. Credentials

- The GitHub App is `swm-runner`: App ID 5807971, installation 183107042.
  It is already installed on smartwatermelon.
- Its key is in the MIMOLETTE login Keychain: service `swm-runner-app-key`, account `smartwatermelon`.
  The item holds the PEM as base64 text on one line.
- The watchdog has its own App, `swm-runner-watchdog` (section 10). It is not the App above.
- Check the key. This prints nothing when it is a valid private key:

  ```bash
  security find-generic-password -s swm-runner-app-key -a smartwatermelon -w | base64 -d | openssl pkey -noout
  ```

- Alerts reuse the NOS ntfy topic from `~/.config/nos-runner/env` (`NTFY_TOPIC=...`, mode 0600).
  Every message starts with `macOS runner:`. The topic is a secret. Never commit it.

## 2. Install the pf guard (sudo)

The pf guard blocks job VMs from the LAN. The supervisor starts no VM until it sees the guard's ok files.
The NOS installer also loads the Tart anchors, and the guard checks them every 60 s:

```bash
sudo /bin/bash ~/.local/share/dev-env/scripts/nos-runner/net/install-pf.sh
```

Run it again after any change to a `.pf` file or the guard.
See `docs/runbooks/nos-runner.md` for the guard.

## 3. Install

Clone dev-env to `~/.local/share/dev-env` if it is not there yet (section 4 of the NOS runbook). Then, as the login user, not root:

```bash
/bin/bash ~/.local/share/dev-env/scripts/swm-macos-runner/install.sh
```

`install.sh` copies the supervisor, `config.sh`, `lib.sh`, `image/`, `guest/` and `github-app.sh`
to `~/.local/libexec/swm-macos-runner` on the internal disk. `guest/` must be there: `config.sh` hashes it into the image name,
and the name is empty without it. Nothing the supervisor runs lives under `/Volumes`.
It then renders `~/Library/LaunchAgents/com.smartwatermelon.swm-macos-runner.plist`, runs `launchctl bootout`, waits, and runs `bootstrap gui/<uid>`.

- The plist sets `TART_HOME=/Volumes/extra-vieille/Caches/tart`, `RunAtLoad`, `KeepAlive` and `ExitTimeOut` 300.
  A stop takes at most about 230 s (stop 60, delete 120, runner DELETE 30, ntfy 20), so 300 leaves margin.
- `install.sh` refuses a topic with characters outside `A-Za-z0-9_.-`. It warns, and sends no alerts, when there is no topic.
- The updater (section 3a) installs a change under `scripts/swm-macos-runner/` by itself. Run `install.sh` by hand only when the change touches the updater's own plist.
  The log is `~/Library/Logs/swm-macos-runner.log`.
- Optional env-file lines `SWM_<NAME>_S=<seconds>` (for example `SWM_CLONE_LIMIT_S=1` for the hang drill) go into the supervisor plist on the next `install.sh` run.
  `install.sh` refuses any other `SWM_` line, and a knob set twice, before it installs anything.

`install.sh` also installs `update.sh` and loads a second job, `com.smartwatermelon.swm-macos-runner-update` (section 3a).

Drill the alert path (touches no VM):

```bash
/bin/bash ~/.local/libexec/swm-macos-runner/supervisor.sh test-alert
```

## 3a. The updater

The updater job runs `update.sh` at load and every 600 s. It always exits 0.

- It runs `git fetch --no-write-fetch-head origin` and `git merge --ff-only origin/main` in `~/.local/share/dev-env`. A failure (network down, or a lost race with the NOS updater) is logged as `git update failed; will retry` and tried again on the next run.
- Not `git pull`: launchd starts this job and the NOS updater in the same second. Two pulls then both fail with `Cannot rebase onto multiple branches`, because each fetch appends to the shared `FETCH_HEAD`. That stalled both updaters on every pass on 2026-11-18.
- The version is the last commit that touched `scripts/swm-macos-runner/` or `scripts/nos-runner/github-app.sh`.
  The installed version is in `~/.local/state/swm-macos-runner/installed`.
- A hand run of `install.sh` records the version it installs, so the updater's first run does not restart the supervisor a second time.
- On a new version it runs `install.sh`, which restarts the supervisor. It waits while the slot file `~/.local/state/swm-macos-runner/slot` says `job=1`, so a running job is never cut short.
  `job=1` means the JIT config was handed over: the runner may be idle or busy. An idle JIT runner holds `job=1` for up to `SWM_JOB_MAX_S` (6 h).
  The updater logs `a job is running; waiting`, writes `~/.local/state/swm-macos-runner/update-pending` and tries again in 600 s.
- The supervisor looks for `update-pending` at the start of each pass, before it clones a VM. While the file exists it waits (at most `SWM_UPDATE_WAIT_S`, 900 s) for the updater to install.
  The updater removes the file after a good install, or when there is no new version.
  So an update installs within one cycle: at most `SWM_JOB_MAX_S` + 600 s after the merge, and sooner when a job ends.
- **An idle runner gives way to an update.** While the supervisor waits on a runner, it looks for `update-pending` every `SWM_UPDATE_IDLE_CHECK_S` (300 s).
  When it finds the file, it deletes the runner registration through the API. GitHub refuses (HTTP 422) to delete a runner that runs a job.
  On a 2xx it logs `update pending and runner N idle ...`, ends the VM, and the next pass waits for the install.
  On a refusal it logs `update pending but runner N not deleted (HTTP 422 ...); waiting for the job` and tries again later.
  A 404 also keeps the wait: GitHub answers 404 for a missing permission too, so it does not prove the runner is idle.
  `SWM_UPDATE_IDLE_CHECK_S=0` turns the check off.
  It does not end runners in a pass whose `update_wait` gave up, so an update that keeps failing to install does not end every runner.
- **A long-pending update alerts.** `update-pending` holds the epoch when it was first written. When it is older than `SWM_UPDATE_PENDING_ALERT_S` (21600 s, 6 h),
  the updater sends one `macOS runner: an update has been pending for ...` alert and writes `update-pending-alerted`. That marker goes when `update-pending` goes.
  `SWM_UPDATE_PENDING_ALERT_S` is the one env-file knob that `install.sh` also writes into the updater plist.
- If `install.sh` fails, the version stays unmarked and the next run tries again.
- The updater never reloads itself. When a change touches its own plist, run `install.sh` by hand.
- **Failed updates alert.** A pass fails when the git fetch or fast-forward fails, the revision cannot be read, or `install.sh` fails.
  A pass that only waits for a running job is not a failure and does not change the count.
  The updater counts consecutive failed passes in `~/.local/state/swm-macos-runner/update-fails`.
  At 6 (one hour) it sends one `macOS runner: the updater has failed 6 passes in a row. Last failure: ...` alert and writes `update-alerted`; later failures stay quiet.
  The first good pass after that sends `macOS runner: the updater works again.` and clears both files.
  `SWM_UPDATE_ALERT_AFTER` overrides the threshold, but `install.sh` does not carry it into the plist: a hand edit of the plist lasts only until the next `install.sh`. A failed ntfy delivery is retried on the next failed or good pass.
  The updater needs `NTFY_TOPIC` in its plist, which `install.sh` now writes from the env file (the topic and `SWM_UPDATE_PENDING_ALERT_S`, not the supervisor knobs).
  The updater cannot reload its own plist, so one hand run of `install.sh` is needed to turn the alert on.
  Until then the updater logs `NTFY_TOPIC is unset` and sends nothing.
- The log is `~/Library/Logs/swm-macos-runner-update.log`.

Stop the updater (the supervisor keeps running):

```bash
launchctl bootout gui/$(id -u)/com.smartwatermelon.swm-macos-runner-update
```

With the updater stopped, delete `~/.local/state/swm-macos-runner/update-pending` if it exists, or each supervisor pass waits 900 s.

`install.sh` loads it again. To remove it for good, delete `~/Library/LaunchAgents/com.smartwatermelon.swm-macos-runner-update.plist` after the bootout.

## 4. First build (about 15 min)

The first start builds a local runner image from the pinned base image, so jobs have no image to pull.
It needs 60 GB free on the Tart volume. Watch it:

```bash
tail -f ~/Library/Logs/swm-macos-runner.log
```

`image ... is missing; building it` starts the build. The limit is 2700 s.
A build that fails sends `macOS runner: image build failed: ...`. Fix the cause and wait: the next pass tries again.

## 5. The TCC Allow, and how a hang shows up

Tart reads and writes `/Volumes/extra-vieille/Caches/tart`. macOS asks once whether `tart` may use that removable volume.
Until someone clicks **Allow**, a launchd job hangs with no log line. The prompt shows on the GUI session only.

- Click **Allow** on the prompt when it shows.
  The grant is keyed to tart's code signature, so it should survive upgrades (not proven until a real upgrade).
- A hang shows up as a start that does not finish in its time limit. The supervisor then sends
  `macOS runner: tart is hung (...). The removable-volume TCC prompt may need Allow.`
- If the prompt is gone: System Settings, Privacy and Security, Files and Folders (or Full Disk Access), and turn `tart` on. Then restart the job:

  ```bash
  launchctl kickstart -k gui/$(id -u)/com.smartwatermelon.swm-macos-runner
  ```

## 6. Hold, release and full stop

**Hold.** Send new jobs to GitHub-hosted runners without touching the supervisor:

```bash
gh variable set SWM_MACOS_RUNNER --org smartwatermelon --visibility all --body macos-26
```

The watchdog sends one `held` alert and then leaves the variable alone. A hold is the only value it never changes.

**Release.** Send jobs to this runner:

```bash
gh variable set SWM_MACOS_RUNNER --org smartwatermelon --visibility all --body mimolette-macos
```

Or set it to `macos-latest`, and the watchdog moves it to `mimolette-macos` after healthy checks.
Unsetting the variable no longer sends jobs to `macos-latest` for long: the watchdog creates it again as `mimolette-macos`
(an `online` alert) about 20 minutes later. To keep jobs hosted, hold.

**After a manual fix.** After you repair the runner by hand, do not wait for the watchdog to recover. Do this:

1. Confirm the runner is up. The supervisor log shows `runner ... handed its JIT config`,
   or the org runners page lists an idle `mimolette-macos` runner.
2. Run this in your own terminal. Agents cannot write org variables:

   ```bash
   gh variable set SWM_MACOS_RUNNER --org smartwatermelon --visibility all --body mimolette-macos
   ```

3. Expect no "recovered" alert, because the watchdog sees a change it did not make and resets its miss and good counts.
   If the runner is unhealthy, the watchdog fails over again after 2 bad checks (about 20 minutes).

**Full stop.** Hold first, so no job waits for a runner that is gone, and so the watchdog does not start a failover or move it back.
Set `SWM_MACOS_RUNNER=macos-26` (the Hold command above). Then stop the job:

```bash
launchctl bootout gui/$(id -u)/com.smartwatermelon.swm-macos-runner
```

A running job finishes its teardown first (up to about 230 s; dev-env#312 is open on a worst case of about 330 s, over the plist's `ExitTimeOut` of 300 s). The plist stays, so a login or `install.sh` starts it again.
To remove it for good, delete `~/Library/LaunchAgents/com.smartwatermelon.swm-macos-runner.plist` after the bootout.
Stop the updater too (section 3a): the next time it installs new code, `install.sh` loads the supervisor again.

If the supervisor is down while the variable says `mimolette-macos`, jobs wait until the watchdog sees two checks with no runner
(about 20 to 30 minutes) and sets `macos-latest`. A hold avoids that wait. The watchdog also moves the variable back to
`mimolette-macos` once the runner is healthy again, so a hold is the only lasting way to keep jobs hosted. To stop the watchdog
for this pool, see "To stop one pool" in `docs/runbooks/nos-runner.md`, section 7.

## 7. Alerts and logs

All alerts go to the NOS ntfy topic and start with `macOS runner:`:

- `pf LAN block not confirmed: ...`. No VM runs until the guard's ok files confirm the block. Check `/var/log/nos-runner-pf.log`.
- `disk check failed: ...`. Free space on the Tart volume is under 60 GB, or `df` did not answer.
- `image build failed: ...`. See section 4.
- `tart is hung (...)`. See section 5.
- `N starts failed in a row; last: ...`. Three failed starts in a row. Read the log.

The watchdog Worker sends these, from the same ntfy topic. Each one starts with `macOS runner:`:

- `down. SWM_MACOS_RUNNER set to macos-latest; stuck runs cancelled for re-run.` Two checks in a row found no healthy runner.
- `recovered. SWM_MACOS_RUNNER set to mimolette-macos.` The runner is healthy again.
- `online. SWM_MACOS_RUNNER was unset, now mimolette-macos.` The variable did not exist, and the watchdog created it.
- `held. SWM_MACOS_RUNNER=<value>; the watchdog leaves it alone.` A hold. Sent once.
- `watchdog skipping: <cause>`. Three ticks in a row were skipped. The variable is left alone.
- `watchdog ok: ticks are running again.` after a skipping alert.
- `drill of the watchdog alert path. No action needed.` A drill (`docs/runbooks/nos-runner.md`, section 8).

**An image rebuild sends a `down` and a `recovered` alert.** This is expected. The runner has one slot, and it is offline
while the image builds (about 15 minutes) or while an update waits (up to 900 s). Two checks 10 minutes apart can both find
no runner, so the watchdog fails over to `macos-latest`, then moves back after the runner returns. Between the two alerts
new jobs run on GitHub-hosted runners, and a queued job is cancelled and re-run there. A gap between jobs
(teardown, clone, boot) is shorter than 10 minutes and does not trigger it. Treat a `down` that follows an
`image ... is missing; building it` log line as this, not as a fault.

**Lost-run re-runs.** A restart of the supervisor (an update, `kickstart`, a logout) stops the job on the runner.
The watchdog finds such a run and re-runs its failed jobs once. It sends no alert: a re-run after a restart is routine
and the restart is already visible. The Worker logs `lost runner re-run: <repo>#<run id>` (and `... re-run failed: ...`).
A run counts as lost when all of these hold:

- It is attempt 1, ended in `failure`, ran in the same repo as its head (not a fork), and its actor is not `dependabot[bot]`.
- A job on the `mimolette-macos` label failed with no failed step. A real test failure has a failed step and is not re-run.
  A cancelled run, and a job that the fork guard denied, are not re-run either.

At most one re-run per run: attempt 2 is never re-run. The watchdog looks 6 hours back, a few repos per tick.
It keeps its checked runs in the KV key `swm-macos:lostChecked`, with a `_cursor` field (the repo rotation cursor).
Entries are dropped after 6 hours. To see a re-run, read the Worker's logs, or look for attempt 2 on the run.
This rule was written from a guess about how GitHub marks a stopped job, and the restart drill is its first proof.

The log is `~/Library/Logs/swm-macos-runner.log`. Key lines:

- `runner ... handed its JIT config`: the runner may be idle or busy; it is waiting for a job or running one (`job=1`).
- `update pending; waiting ...` / `update installed or withdrawn` / `update still pending after ...`: the supervisor held a pass for the updater.
- `update pending and runner N idle ...` / `runner ... ended idle for the pending update`: an idle runner made way for an update.
- `runner N idle for S s (limit L s); ending VM ...` / `runner ... ended idle after SWM_IDLE_MAX_S`: a runner waited `SWM_IDLE_MAX_S` (default 3600, `0` disables) after its JIT handoff with no job, so the supervisor deregistered it and starts a fresh VM. Not a failure. `idle past SWM_IDLE_MAX_S but runner N not deleted (HTTP 422 ...)` means it was running a job and keeps it; that line shows once per runner. The limit is checked every `SWM_UPDATE_IDLE_CHECK_S`, so `SWM_UPDATE_IDLE_CHECK_S=0` turns it off too.
- `runner ... finished its job`: a job ended.
- `pass failed (<kind>, try N): ...`: a failed pass and why.
- `fails in a row; next pass in N s`: the supervisor is backing off.
- `sweep: removing leftover VM ...`: it deleted a VM an earlier run left. Normal after a stop.
- `stopping on SIGTERM`: someone stopped the job.

## 8. Cleanup of the spike files and the internal image copy

Andrew's OK is needed first. The spike left two things on MIMOLETTE's internal disk:

- A copy of the base image in `~/.tart` (about 33 GB). `TART_HOME` is now on the external disk, so the copy is not used.
- Test files in `~/.local/state/tart-spike/`.

List both before you remove anything:

```bash
TART_HOME="$HOME/.tart" tart list
du -sh "$HOME/.tart"
ls -la "$HOME/.local/state/tart-spike/"
```

Check that the list shows only spike images and nothing the supervisor uses. Then delete each VM or image by the name `tart list` printed:

```bash
TART_HOME="$HOME/.tart" tart delete <name>
```

Delete the spike files with `rm` on the names `ls` printed, then remove the empty folder with `rmdir`.
The supervisor's own images are in `/Volumes/extra-vieille/Caches/tart`. Do not touch them.

## 9. Routing

A workflow that runs on this pool uses this `runs-on`, word for word. Forks and Dependabot go to GitHub-hosted runners.
Everything else uses the pool variable, then GitHub-hosted:

```yaml
runs-on: ${{ (((github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository) || github.actor == 'dependabot[bot]' || github.event.pull_request.user.login == 'dependabot[bot]') && 'macos-latest') || vars.SWM_MACOS_RUNNER || 'macos-latest' }}
```

Why each part is there:

- **`github.event_name == 'pull_request' && head.repo.full_name != github.repository`.** A pull request from a fork must not run
  code on MIMOLETTE. The event-name test keeps a `push` (which has no PR head) from reading as a fork.
- **A deleted fork.** When the fork is gone, `head.repo` is null. It compares unequal, so the run goes hosted. That is the safe side.
- **`github.actor == 'dependabot[bot]'`.** Dependabot runs go hosted. `github.actor` stays the same on a re-run,
  so a re-run of a Dependabot run stays hosted too.
- **`github.event.pull_request.user.login == 'dependabot[bot]'`.** This catches the case that `actor` misses:
  Andrew pushing to a Dependabot branch. Each of the two tests catches a case the other misses.
  The same pair is in `github-workflows/.github/workflows/dependabot-auto-merge.yml`.
- **`&& 'macos-latest'`.** When any of the above holds, the run is hosted, whatever the variable says.
- **`|| vars.SWM_MACOS_RUNNER`.** Otherwise the variable picks the runner, so a failover or a hold works with no workflow change.
- **`|| 'macos-latest'`.** The variable is unset: hosted. This is the fail-safe.

Do not use this expression in a workflow that triggers on `pull_request_target` or `workflow_run`. In those events
`github.event.pull_request` is not the fork's head, so the test is not a safe guard. The fork-guard hook on the VM
(`scripts/swm-macos-runner/guest/`) is a second layer and does not replace it.

## 10. The watchdog App

The Worker uses its own GitHub App for this pool, `swm-runner-watchdog`, so a leaked key reaches only its permissions.
Andrew creates it in the GitHub UI (smartwatermelon org, Settings, Developer settings, GitHub Apps):

1. Name `swm-runner-watchdog`. Webhook off. "Only on this account".
2. Permissions, and nothing else: Organization **Self-hosted runners: Read**, Organization **Variables: Read and write**,
   Repository **Actions: Read and write** (Metadata read is automatic).
   There is no Checks read: the lost-run test uses the jobs API only.
3. Install it on smartwatermelon, **All repositories**. A smaller selection gives fewer repos and no error.
4. Note the App ID and the installation ID (from the installation URL), generate a private key, then follow
   `docs/runbooks/nos-runner.md` section 3 (convert the key) and section 7 (the three `SWM_*` secrets).

Check the key by minting a token only through the Worker. Never read `swm-macos:token`: it holds a live installation token.
