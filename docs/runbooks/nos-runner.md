# NOS runner: install, operate, undo

Private nightowlstudiollc CI jobs run on MIMOLETTE, in one Apple container VM per job.
The `NOS_RUNNER` org variable picks the runner label: `mimolette` or `ubuntu-latest`.
A supervisor on MIMOLETTE keeps two runner slots up. A Cloudflare Worker, the watchdog,
checks every 10 minutes and moves the variable to `ubuntu-latest` when the runner is down.
The same Worker also watches the smartwatermelon macOS pool, on its own cron (section 7).
Design: `docs/superpowers/specs/2026-11-10-nos-self-hosted-runner-design.md`.

## 1. The two GitHub Apps

Andrew creates both in the GitHub UI and installs them on nightowlstudiollc only.

| App | Permissions | Key lives in |
|---|---|---|
| `nos-runner` (App ID 5703224, installation 180668548) | org: Self-hosted runners write, Variables write | MIMOLETTE login Keychain |
| `nos-runner-watchdog` | org: Self-hosted runners read, Variables write; repos: Actions write | Worker secret |
| `swm-runner-watchdog` (smartwatermelon, for the macOS pool) | org: Self-hosted runners read, Variables write; repos: Actions write | Worker secrets `SWM_*` |

`swm-runner-watchdog` has the same permissions as `nos-runner-watchdog`, and no more.
It is installed on smartwatermelon, not nightowlstudiollc. Its setup is in `docs/runbooks/swm-macos-runner.md` (section 10).

A leaked key reaches only that App's permissions.

Install each watchdog App on **All repositories** of its org. With a smaller selection,
the watchdog sees fewer repos and reports no error.

## 2. Store the supervisor key in the Keychain

Back up and verify the MIMOLETTE login Keychain before any change, and verify it after.

The supervisor reads the key from Keychain item `nos-runner-app-key`, account `nightowlstudiollc`.
The item holds the PEM as base64 text, on one line.

1. Back up the login Keychain and confirm the backup opens.
2. Make the base64 text of the downloaded PEM. Do not paste the PEM in chat.
3. Add the item in Keychain Access. The `security -w` prompt cuts text at 128 characters, so do not use it.
4. Check the item. This prints nothing when the key is a valid private key:

   ```bash
   security find-generic-password -s nos-runner-app-key -a nightowlstudiollc -w | base64 -d | openssl pkey -noout
   ```

   If macOS asks whether `security` may read the item, choose **Always Allow**.
   The supervisor reads it under launchd, where a prompt would block it with no window (not yet verified).
5. Verify the Keychain again, then delete the PEM file.

## 3. Prepare the watchdog keys

The Worker needs each key as PKCS8. Convert each PEM once.

NOS:

```bash
openssl pkcs8 -topk8 -nocrypt -in nos-runner-watchdog.pem -out nos-runner-watchdog.pkcs8.pem
```

smartwatermelon (macOS pool):

```bash
openssl pkcs8 -topk8 -nocrypt -in swm-runner-watchdog.*.pem -out swm-runner-watchdog.pkcs8.pem
op document create swm-runner-watchdog.pkcs8.pem --title swm-runner-watchdog-pkcs8 --vault Automation
```

Set the contents as the Worker secret `APP_KEY_PKCS8` (NOS) or `SWM_APP_KEY_PKCS8` (macOS) (section 7).
Keep the PEM until the secret works, then delete both files.

## 4. First install on MIMOLETTE

Run these in a terminal on MIMOLETTE, in a GUI login session.

1. Clone dev-env to the path the updater uses. Use HTTPS: the repo is
   public, and the updater pulls under launchd with no SSH agent.

   ```bash
   git clone https://github.com/smartwatermelon/dev-env ~/.local/share/dev-env
   ```

2. Install the pf guard once, as root. It blocks job VMs from the LAN.
   The guard runs every 60 s and loads the NOS anchors and the Tart anchors (`swm-tart.pf`, `swm-tart-v6.pf`)
   for the smartwatermelon macOS runner:

   ```bash
   sudo /bin/bash ~/.local/share/dev-env/scripts/nos-runner/net/install-pf.sh
   ```

3. Install the LaunchAgents as the login user, not root:

   ```bash
   /bin/bash ~/.local/share/dev-env/scripts/nos-runner/install.sh
   ```

The image builds on first install. This takes about 3 minutes.

The ntfy topic is a secret. Never commit it.
Put `NTFY_TOPIC=<topic>` in `~/.config/nos-runner/env` (mode 0600),
or pass `NTFY_TOPIC` as an environment variable to `install.sh`, which saves it there.
Without a topic, `install.sh` warns and no alerts go out.

After a reboot, the supervisor needs a GUI login before `container` runs.
Until someone logs in, the Worker sees no runner and falls back to GitHub-hosted runners.

## 5. Updates

The updater LaunchAgent runs every 600 s. It pulls the clone and runs `install.sh` when `scripts/nos-runner/` changed.

- **Script change.** The supervisor restarts on SIGHUP. It finishes its pass and exits.
  The variable and the VMs are untouched, so there is no failover and no alert.
- **Image change.** The image tag is `nos-runner:<RUNNER_VERSION>-<hash>`. The hash covers every file
  in `scripts/nos-runner/image/`, so any change there (not only a version bump) builds a new image.
  `install.sh` builds it first, then writes the tag to `image.tag` in libexec, where the supervisor reads it.
  That is a script change, so the restart is SIGHUP and there is no failover.
  Old image tags are not removed. Remove them by hand when disk is low.
- **Plist change.** `install.sh` runs `bootout` and `bootstrap`. Before `bootout` it writes
  `~/.local/state/nos-runner/planned-stop`, so the supervisor's SIGTERM keeps `NOS_RUNNER` and sends no alert.
  The marker is removed once the job is gone, and the supervisor ignores one older than its shutdown window.
  If `bootstrap` then fails, the watchdog sees the runner offline and fails over.
- **Any other SIGTERM** (`launchctl bootout` by hand, a logout) fails over to `ubuntu-latest`, then recovers:
  the supervisor's "set to ubuntu-latest … Reason: supervisor stopped" alert, then the watchdog's "recovered" alert.
  During a hold, the supervisor leaves the variable alone. Recovery can take up to about 160 minutes.
  To end it sooner, see "After a manual fix" in section 6.
- **Updater plist change.** A job cannot reload itself. The updater logs
  "updater plist changed; run install.sh by hand" and sends one alert. Run `install.sh` by hand (section 4, step 3).
- **Failed updates alert.** A pass fails when the git fetch or fast-forward fails, the revision cannot be read, or `install.sh` fails.
  The updater counts consecutive failed passes in `~/.local/state/nos-runner/update-fails`.
  At 6 (one hour) it sends one `NOS runner: the updater has failed 6 passes in a row. Last failure: ...` alert and writes `update-alerted`; later failures stay quiet.
  The first good pass after that sends `NOS runner: the updater works again.` and clears both files.
  `NOS_UPDATE_ALERT_AFTER` overrides the threshold, but `install.sh` does not carry it into the plist: a hand edit of the plist lasts only until the next `install.sh`. A failed ntfy delivery is retried on the next failed or good pass.
  The updater needs `NTFY_TOPIC` in its plist, which `install.sh` now writes from the env file.
  The updater cannot reload its own plist, so one hand run of `install.sh` (section 4, step 3) is needed to turn the alert on.
  Until then the updater logs `NTFY_TOPIC is unset` and sends nothing.
- On a quiet night the supervisor restarts each slot about hourly (`NOS_IDLE_MAX_S`). That is normal.
- A pf rule change needs `install-pf.sh` again with sudo. The updater never touches root files.

## 6. Hold, release and full stop

Setting `NOS_RUNNER=ubuntu-latest` is not a lasting undo.
The watchdog sees a healthy runner and moves the variable back to `mimolette` after healthy checks.

**Hold.** Set the org variable `NOS_RUNNER` to `ubuntu-24.04`.
CI runs on GitHub-hosted runners. The watchdog sends one `held` alert and leaves the variable alone.
Any value other than `mimolette`, `ubuntu-latest` or unset counts as a hold.
The supervisor also leaves a hold alone: a self-check failure or a SIGTERM does not change it.

**Release.** Set `NOS_RUNNER` to `ubuntu-latest`.
The watchdog moves it back to `mimolette` after healthy checks.

**After a manual fix.** After you repair the runner by hand, do not wait for the watchdog to recover. Do this:

1. Confirm both slots are up. The supervisor log shows `started mimolette-N-…` for each slot,
   or the org runners page lists 2 idle `mimolette` runners.
2. Run this in your own terminal. Agents cannot write org variables:

   ```bash
   gh variable set NOS_RUNNER --org nightowlstudiollc --body mimolette
   ```

3. Expect no "recovered" alert, because the watchdog sees a change it did not make and resets its miss and good counts.
   If the runners are unhealthy, the watchdog fails over again after 2 bad checks (about 20 minutes).

**Full stop.** Do all three, in this order:

1. Hold: set `NOS_RUNNER=ubuntu-24.04`.
2. Stop both LaunchAgents. The hold stays set:

   ```bash
   launchctl bootout "gui/$(id -u)/com.nightowlstudio.nos-runner"
   launchctl bootout "gui/$(id -u)/com.nightowlstudio.nos-runner-update"
   ```

3. Disable the Worker cron (section 7, step 5).

## 7. Deploy the watchdog Worker

One Worker watches both pools. Each pool has its own cron, so each tick gets its own subrequest and CPU budget:

| Pool | Cron | Variable | KV keys | App secrets |
|---|---|---|---|---|
| NOS | `*/10 * * * *` | `NOS_RUNNER` | unprefixed: `state`, `token`, `pendingReruns`, `skips`, `drill` | `APP_ID`, `INSTALLATION_ID`, `APP_KEY_PKCS8` |
| smartwatermelon macOS | `5,15,25,35,45,55 * * * *` | `SWM_MACOS_RUNNER` | prefixed `swm-macos:` | `SWM_APP_ID`, `SWM_INSTALLATION_ID`, `SWM_APP_KEY_PKCS8` |

`NTFY_TOPIC` and `NTFY_TOKEN` are shared. The macOS pool's alert texts start with `macOS runner:`.
The two crons never fire in the same minute. `scheduled()` picks the pool from `event.cron` and matches it exactly.
A tick with no cron (a manual run) is the NOS pool. A cron that no pool owns logs `unknown cron` and does nothing.

Deploy with wrangler (it calls the Cloudflare API), never the dashboard. Run each command
from `workers/nos-runner-watchdog/`, logged in to the nightowlstudio account (`npx wrangler@4 whoami`).
First deployed 2026-11-12. The macOS pool was added after that.

1. The KV namespace `nos-runner-watchdog-state` exists. Its ID is in `wrangler.toml`, binding `STATE`.
   To make a new one: `npx wrangler@4 kv namespace create nos-runner-watchdog-state`, then update the ID.
2. Check the account's Cron Trigger count before the first deploy with two crons: the Free plan allows 5 across the account.
   This Worker now uses 2. Count the others in the dashboard (Workers and Pages). It must be 4 or fewer before the deploy.
3. Set the secrets before the deploy when you add a pool, so the old code ignores them.
   Set the five NOS secrets from 1Password, piped so they never print:

   ```bash
   printf '%s' <app-id> | npx wrangler@4 secret put APP_ID
   printf '%s' <installation-id> | npx wrangler@4 secret put INSTALLATION_ID
   op document get nos-runner-watchdog-pkcs8 --vault Automation | npx wrangler@4 secret put APP_KEY_PKCS8
   op read op://Automation/nos-runner-ntfy-topic/password | tr -d '\n' | npx wrangler@4 secret put NTFY_TOPIC
   op read op://Automation/nos-runner-ntfy-token/password | tr -d '\n' | npx wrangler@4 secret put NTFY_TOKEN
   ```

   The watchdog App is ID 5732501, installation 181333652. The ntfy topic is only for this runner.
   `NTFY_TOKEN` is an access token for the paid ntfy.sh account (Supporter tier).
   Without it, ntfy.sh counts Worker posts against one quota shared by all of Cloudflare and returns 429.
   Even with it, ntfy.sh drops about half of the connections from Workers (HTTP 522 after about 20 s),
   so the Worker tries each alert up to 3 times (measured 2026-11-12).

   Set the three macOS secrets:

   ```bash
   printf '%s' <app-id> | npx wrangler@4 secret put SWM_APP_ID
   printf '%s' <installation-id> | npx wrangler@4 secret put SWM_INSTALLATION_ID
   op document get swm-runner-watchdog-pkcs8 --vault Automation | npx wrangler@4 secret put SWM_APP_KEY_PKCS8
   ```

   A macOS pool with any of its three secrets missing stays silent: it logs `pool swm-macos not configured`,
   makes no KV write and sends no alert. So a partial set, or a deploy before the secrets, is safe but also does nothing.
   Only the macOS pool is quiet this way. The NOS pool keeps its alert path, so a lost NOS secret still shows as `watchdog skipping`.
4. Upload the Worker and both crons: `npm test && npx wrangler@4 deploy`.
   The output lists both crons under the triggers. They come from `wrangler.toml`.
   `workers_dev = false`, so the Worker has no public URL.
5. Check both pools after 20 minutes: `npx wrangler@4 kv key list --binding STATE --remote` lists `state` and `swm-macos:state`.
   - Never `kv key get token` or `kv key get swm-macos:token`: those keys hold live installation tokens.
   - **NOS tick at a `:x0` minute.** After a deploy that changes the crons, check that a NOS tick at a `:00`, `:10`, ... minute still runs and updates `state`
     (watch `npx wrangler@4 tail` through one such minute, then check that `kv key get state --binding STATE --remote` shows the current `lastVar`).
     Cron dispatch matches `event.cron` exactly, and a mismatch would make the NOS pool fall silent.
   - If `SWM_MACOS_RUNNER` is unset, about 20 minutes after the deploy the watchdog creates it as `mimolette-macos`
     and sends `macOS runner: online ...`. That is expected. No workflow reads the variable until a pilot switches to it.
6. To stop one pool (full stop), take its cron out of `wrangler.toml` and run `npx wrangler@4 triggers deploy`.
   The other pool keeps running.
   - NOS: remove `"*/10 * * * *"` from `crons`.
   - macOS: remove `"5,15,25,35,45,55 * * * *"` from `crons`.

   To stop both, set `crons = []`. Put the crons back and run the command again to start. (Not yet tested.)
   A stopped watchdog does not move a variable back, so hold the variable first (section 6, and section 6 of the macOS runbook).

## 8. Alerts

All alerts go to the ntfy topic. The topic also carries the smartwatermelon macOS runner's alerts, which start with `macOS runner:`
(`docs/runbooks/swm-macos-runner.md`, section 7, lists them).
The list below is the NOS pool. The macOS pool sends the same kinds, with its own texts.

- **down.** The runner failed its checks. `NOS_RUNNER` is now `ubuntu-latest`. Runs stuck on `mimolette` are cancelled and re-run on GitHub.
- **recovered.** `NOS_RUNNER` is back on `mimolette` after healthy checks.
- **online.** `NOS_RUNNER` was unset and is now `mimolette`.
- **held.** `NOS_RUNNER` has a manual hold value. Sent once. The watchdog does nothing until you release the hold.
- **watchdog skipping: …** Three ticks in a row were skipped; the alert names the cause. The variable is left alone.
- **watchdog ok.** Ticks run again after a "watchdog skipping" alert.

The supervisor also sends its own alerts:

- It set `NOS_RUNNER` to `ubuntu-latest`, with the reason.
- It cannot mint a GitHub App token, and later, that it can mint them again.
- A VM is outside `192.168.64.0/24`, which the pf rules cover. Every VM is stopped, and no VM starts
  until you fix the container network and delete `~/.local/state/nos-runner/subnet-bad`.

**Alert drill.** Test both alert paths without failing anything:

- Supervisor, on MIMOLETTE: `/bin/bash ~/.local/libexec/nos-runner/supervisor.sh test-alert`.
  It sends "NOS runner drill: supervisor alert path" and exits 0 only when ntfy accepted it.
  It reads the topic from `~/.config/nos-runner/env` and touches no VM, slot or variable.
- Watchdog, from `workers/nos-runner-watchdog/`: `npx wrangler@4 kv key put drill 1 --binding STATE --remote`.
  The next tick sends "NOS runner drill: watchdog alert path", then deletes `drill`.
  Read the result with `npx wrangler@4 kv key get drill-result --binding STATE --remote`: `ok` and `tries` (1 to 3).
  KV reads can lag a write by about 2 minutes.
- Watchdog, macOS pool: the same, with the prefixed keys:
  `npx wrangler@4 kv key put swm-macos:drill 1 --binding STATE --remote`.
  The next macOS tick (up to about 10 minutes) sends "macOS runner: drill of the watchdog alert path. No action needed."
  Read `npx wrangler@4 kv key get swm-macos:drill-result --binding STATE --remote`.
  The NOS pool must send no new alert. A plain `drill` key belongs to NOS, and the macOS tick does not touch it.

**Recovery backoff.** After repeated outages, recovery waits longer each time:
20, then 40, then 80, then 160 minutes.
One stable hour resets the backoff.

## 9. Logs

On MIMOLETTE:

- `~/Library/Logs/nos-runner.log`: the supervisor.
- `~/Library/Logs/nos-runner-update.log`: the updater.
- `/var/log/nos-runner-pf.log`: the pf guard (root). It logs every failed check,
  and says when pf was disabled or the anchor was empty before it loaded the rules.

```bash
tail -n 100 ~/Library/Logs/nos-runner.log
tail -n 50 ~/Library/Logs/nos-runner-update.log
```

Key lines to look for:

- `was still registered after its VM exited; deleted`: normal after a job. GitHub keeps a JIT runner listed for a while,
  so the supervisor deletes it. A VM exit is not a failed start: a runner that dies before its job is not detected yet.
- `slot N: runner ID idle for S s (limit L s); restarting`: the runner waited longer than `NOS_IDLE_MAX_S` (default 3600, `0` disables)
  for a job, so the supervisor deleted it and stops the VM. A fresh VM starts in its place. One slot restarts per pass.
  A `delete failed (HTTP 422)` line instead means the runner had just taken a job; the VM keeps running.
- `container run failed`: a failed start. Three in a row fail over.
- `NOS_RUNNER set to ubuntu-latest`: the supervisor failed over. The reason follows.
- `stopping: switching NOS_RUNNER`: the supervisor got SIGTERM.
- `held at <value>; not changed`: a manual hold is set, so the supervisor did not fail over the variable.
- `could not be stopped; runner … deleted`: the container apiserver did not answer. The idle runner was removed
  from GitHub, and the next pass with a working `container ls` stops the VM.
- `no IPv4 address in container ls yet`: a VM has no IP yet. Normal for a few seconds after a start.
- `ntfy delivery failed`: an alert did not send. Check the topic and the network.
- `updater plist changed`: run `install.sh` by hand.
- `git update failed; will retry` (update log): the fetch or the fast-forward failed, so the clone is behind. The updater retries. If it repeats, run `git -C ~/.local/share/dev-env fetch origin` and `git -C ~/.local/share/dev-env merge --ff-only origin/main` by hand to see the error.
