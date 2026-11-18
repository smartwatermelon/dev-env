# smartwatermelon macOS runner: install, operate, undo

smartwatermelon macOS CI jobs run on MIMOLETTE, in one Tart VM per job, one job at a time.
A workflow opts in with `runs-on: ${{ vars.SWM_MACOS_RUNNER || 'macos-latest' }}`.
The `SWM_MACOS_RUNNER` org variable picks the runner label:

| Value | Where jobs run |
|---|---|
| unset | GitHub-hosted `macos-latest` (the fail-safe) |
| `mimolette-macos` | This runner |
| `macos-26` | GitHub-hosted `macos-26`. This is the hold value (section 6) |

The supervisor never writes `SWM_MACOS_RUNNER`. You set it by hand.
Design: `docs/superpowers/specs/2026-11-17-swm-macos-tart-runner-design.md`.

Run every step in a terminal on MIMOLETTE, in a GUI login session.
launchd starts the supervisor in `gui/<uid>`, so Tart runs there too, never through ssh.

## 1. Credentials

- The GitHub App is `swm-runner`: App ID 5807971, installation 183107042.
  It is already installed on smartwatermelon.
- Its key is in the MIMOLETTE login Keychain: service `swm-runner-app-key`, account `smartwatermelon`.
  The item holds the PEM as base64 text on one line.
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
- If `install.sh` fails, the version stays unmarked and the next run tries again.
- The updater never reloads itself. When a change touches its own plist, run `install.sh` by hand.
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

**Release.** Send jobs to this runner:

```bash
gh variable set SWM_MACOS_RUNNER --org smartwatermelon --visibility all --body mimolette-macos
```

Unset the variable to go back to `macos-latest`:

```bash
gh variable delete SWM_MACOS_RUNNER --org smartwatermelon
```

**Full stop.** Hold first, so no job waits for a runner that is gone. Then stop the job:

```bash
launchctl bootout gui/$(id -u)/com.smartwatermelon.swm-macos-runner
```

A running job finishes its teardown first (up to about 230 s). The plist stays, so a login or `install.sh` starts it again.
To remove it for good, delete `~/Library/LaunchAgents/com.smartwatermelon.swm-macos-runner.plist` after the bootout.
Stop the updater too (section 3a): the next time it installs new code, `install.sh` loads the supervisor again.

There is no watchdog for this runner yet. If the supervisor is down while the variable says `mimolette-macos`, jobs wait. Hold first.

## 7. Alerts and logs

All alerts go to the NOS ntfy topic and start with `macOS runner:`:

- `pf LAN block not confirmed: ...`. No VM runs until the guard's ok files confirm the block. Check `/var/log/nos-runner-pf.log`.
- `disk check failed: ...`. Free space on the Tart volume is under 60 GB, or `df` did not answer.
- `image build failed: ...`. See section 4.
- `tart is hung (...)`. See section 5.
- `N starts failed in a row; last: ...`. Three failed starts in a row. Read the log.

The log is `~/Library/Logs/swm-macos-runner.log`. Key lines:

- `runner ... handed its JIT config`: the runner may be idle or busy; it is waiting for a job or running one (`job=1`).
- `update pending; waiting ...` / `update installed or withdrawn` / `update still pending after ...`: the supervisor held a pass for the updater.
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
