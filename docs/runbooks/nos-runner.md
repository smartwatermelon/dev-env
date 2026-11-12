# NOS runner: install, operate, undo

Private nightowlstudiollc CI jobs run on MIMOLETTE, in one Apple container VM per job.
The `NOS_RUNNER` org variable picks the runner label: `mimolette` or `ubuntu-latest`.
A supervisor on MIMOLETTE keeps two runner slots up. A Cloudflare Worker, the watchdog,
checks every 10 minutes and moves the variable to `ubuntu-latest` when the runner is down.
Design: `docs/superpowers/specs/2026-11-10-nos-self-hosted-runner-design.md`.

## 1. The two GitHub Apps

Andrew creates both in the GitHub UI and installs them on nightowlstudiollc only.

| App | Permissions | Key lives in |
|---|---|---|
| `nos-runner` (App ID 5703224, installation 180668548) | org: Self-hosted runners write, Variables write | MIMOLETTE login Keychain |
| `nos-runner-watchdog` | org: Self-hosted runners read, Variables write; repos: Actions write | Worker secret |

A leaked key reaches only that App's permissions.

Install `nos-runner-watchdog` on **All repositories**. With a smaller selection,
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

## 3. Prepare the watchdog key

The Worker needs the key as PKCS8. Convert the PEM once:

```bash
openssl pkcs8 -topk8 -nocrypt -in nos-runner-watchdog.pem -out nos-runner-watchdog.pkcs8.pem
```

Set the contents as the Worker secret `APP_KEY_PKCS8` (section 7). Delete both files afterward.

## 4. First install on MIMOLETTE

Run these in a terminal on MIMOLETTE, in a GUI login session.

1. Clone dev-env to the path the updater uses. Use HTTPS: the repo is
   public, and the updater pulls under launchd with no SSH agent.

   ```bash
   git clone https://github.com/smartwatermelon/dev-env ~/.local/share/dev-env
   ```

2. Install the pf guard once, as root. It blocks job VMs from the LAN:

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
  The new tag changes the plist.
- **Plist change**, for example an image change. `install.sh` builds the image first, then runs `bootout` and `bootstrap`.
  This fails over to `ubuntu-latest`, then recovers: the supervisor's "set to ubuntu-latest … Reason: supervisor
  stopped" alert, then the watchdog's "recovered" alert. During a hold, the supervisor leaves the variable alone.
  Old image tags are not removed. Remove them by hand when disk is low.
- **Updater plist change.** A job cannot reload itself. The updater logs
  "updater plist changed; run install.sh by hand" and sends one alert. Run `install.sh` by hand (section 4, step 3).
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

**Full stop.** Do all three, in this order:

1. Hold: set `NOS_RUNNER=ubuntu-24.04`.
2. Stop both LaunchAgents. The hold stays set:

   ```bash
   launchctl bootout "gui/$(id -u)/com.nightowlstudio.nos-runner"
   launchctl bootout "gui/$(id -u)/com.nightowlstudio.nos-runner-update"
   ```

3. Disable the Worker cron (section 7, step 5).

## 7. Deploy the watchdog Worker

Deploy with wrangler (it calls the Cloudflare API), never the dashboard. Run each command
from `workers/nos-runner-watchdog/`, logged in to the nightowlstudio account (`npx wrangler@4 whoami`).
First deployed 2026-11-12.

1. The KV namespace `nos-runner-watchdog-state` exists. Its ID is in `wrangler.toml`, binding `STATE`.
   To make a new one: `npx wrangler@4 kv namespace create nos-runner-watchdog-state`, then update the ID.
2. Upload the Worker and its cron: `npx wrangler@4 deploy`. The cron `*/10 * * * *` comes from `wrangler.toml`.
   `workers_dev = false`, so the Worker has no public URL.
3. Set the five secrets from 1Password, piped so they never print:

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
4. Check a scheduled run: `npx wrangler@4 kv key list --binding STATE --remote` lists `state` after the first tick.
   Never `kv key get token`: that key holds a live installation token.
5. To stop the watchdog (full stop), set `crons = []` in `wrangler.toml` and run `npx wrangler@4 triggers deploy`.
   Restore `crons = ["*/10 * * * *"]` and run it again to start. (Not yet tested.)

## 8. Alerts

All alerts go to the ntfy topic.

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

- `was still registered`: a runner stayed registered after its VM exited. The VM died before its job, and counts as a failed start. Three failed starts in a row fail over.
- `NOS_RUNNER set to ubuntu-latest`: the supervisor failed over. The reason follows.
- `stopping: switching NOS_RUNNER`: the supervisor got SIGTERM.
- `held at <value>; not changed`: a manual hold is set, so the supervisor did not fail over the variable.
- `could not be stopped; runner … deleted`: the container apiserver did not answer. The idle runner was removed
  from GitHub, and the next pass with a working `container ls` stops the VM.
- `no IPv4 address in container ls yet`: a VM has no IP yet. Normal for a few seconds after a start.
- `ntfy delivery failed`: an alert did not send. Check the topic and the network.
- `updater plist changed`: run `install.sh` by hand.
- `git pull failed; will retry` (update log): the clone is behind. The updater retries.
