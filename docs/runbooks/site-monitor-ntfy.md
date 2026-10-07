# Site monitor: install the ntfy topic

The site monitor (`.github/workflows/site-monitor.yml`, dev-env#193) pushes
alerts to an [ntfy.sh](https://ntfy.sh) topic. It reads the topic from the
repository secret `NTFY_TOPIC`. Until that secret exists, every run still
writes the `site-down` issue, then fails: a monitor that cannot alert must not
read green.

An ntfy.sh topic has no password. Anyone who knows the name can read and post
to it, so the name is the secret. These steps keep it out of chat, terminal
scrollback, and logs.

## 1. Create the topic and install the secret

Run this on your Mac. It prints nothing.

```bash
topic="nos-sites-$(openssl rand -hex 12)"
printf '%s' "$topic" | gh secret set NTFY_TOPIC --repo smartwatermelon/dev-env
printf '%s\n' "$topic" | pbcopy
unset topic
```

- `gh secret set` reads the value from stdin, so it never appears in argv or
  shell history.
- The topic is now on the clipboard for step 2 only.

## 2. Subscribe on the iPhone

1. Open the ntfy app and tap **+**.
2. Paste the topic. Keep the server as `ntfy.sh`.
3. Tap **Subscribe**.
4. Open the subscription's settings. If the app offers it, turn on critical
   alerts (or "override Do Not Disturb") for this subscription only. Priority 5
   alerts then sound even with the phone silenced.
5. Clear the clipboard: copy any other text.

## 3. Test

The workflow must be on `main` first: `gh workflow run` cannot start a
workflow that exists only on a branch.

Prove a push reaches the phone. This sends one priority-5 test push and
skips the site checks:

```bash
gh workflow run site-monitor.yml --repo smartwatermelon/dev-env -f test-push=true
```

Then run the monitor itself:

```bash
gh workflow run site-monitor.yml --repo smartwatermelon/dev-env
gh run list --workflow site-monitor.yml --repo smartwatermelon/dev-env --limit 1
```

When every site passes, a run sends nothing and exits 0.

## 4. Trigger from MIMOLETTE

GitHub's scheduler never fired the workflow's cron: no scheduled run in the
4 hours after merge, on `*/15` or on the off-peak `7,22,37,52`. So a launchd
job on MIMOLETTE, which is always on, starts the workflow every 15 minutes
through the API (`scripts/site-monitor/dispatch-monitor.sh`). The cron stays
in the workflow as a backup; the concurrency group keeps two runs from racing.

### Create the token

Create a fine-grained token at GitHub > Settings > Developer settings >
Fine-grained tokens:

- Resource owner: `smartwatermelon`.
- Repository access: only `smartwatermelon/dev-env`.
- Permissions: **Actions: Read and write**. Nothing else.
- Expiration: the longest allowed. Put the date in your calendar.

Copy it, then run this on the Mac where it is on the clipboard. It prints
nothing and keeps the token out of argv and shell history:

```bash
pbpaste | ssh mimolette.local 'umask 077; mkdir -p ~/.config/site-monitor; cat > ~/.config/site-monitor/dispatch-token'
```

Then clear the clipboard: copy any other text.

### Install the job

On MIMOLETTE, with `~/Developer/dev-env` on an up-to-date `main`:

```bash
plist=com.smartwatermelon.site-monitor-dispatch.plist
cp ~/Developer/dev-env/scripts/site-monitor/launchd/"$plist" ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/"$plist"
launchctl kickstart "gui/$(id -u)/com.smartwatermelon.site-monitor-dispatch"
tail -1 ~/Library/Logs/site-monitor-dispatch.log
```

The last line should say `dispatched site-monitor.yml`, and a new
`workflow_dispatch` run appears in `gh run list --workflow site-monitor.yml`.

The job runs at minutes 2, 17, 32 and 47. The script runs from the clone, so a
`git pull` there updates it; a change to the plist needs `launchctl bootout`
and the steps above again.

To replace an installed job, remove it first:

```bash
launchctl bootout "gui/$(id -u)/com.smartwatermelon.site-monitor-dispatch"
```

### Why the job runs `/bin/bash`

On MIMOLETTE, `~/Developer` is a symlink to an external disk
(`/Volumes/extra-vieille/Workspaces`). When launchd runs a script there, macOS
asks the interpreter for access to a removable volume. The first install ran
Homebrew bash: on 2026-10-07 it waited on an Allow dialog for about 11 minutes and
dispatched nothing. A grant for Homebrew bash is tied to its Cellar path and
code hash, so each `brew upgrade` of bash brings the dialog back and the job
hangs again with no error.

macOS `/bin/bash` (3.2) has Full Disk Access on MIMOLETTE, granted during the
initial setup, which covers the external disk. Its path and signature do not
change with Homebrew. So:

- Keep `dispatch-monitor.sh` compatible with bash 3.2. The tests run every
  case under `/bin/bash` too, on any Mac.
- Do not remove `/bin/bash` from Full Disk Access on MIMOLETTE. Without it the
  job hangs on a dialog that nobody sees.

If the log stops growing, look for a pending dialog on MIMOLETTE's screen and
check `launchctl print "gui/$(id -u)/com.smartwatermelon.site-monitor-dispatch"`:
`state = running` for minutes means it is stuck.

### What this does not cover

If MIMOLETTE is off, or the token expires, no run starts and nothing alerts.
A failed dispatch only writes to `~/Library/Logs/site-monitor-dispatch.log`.

## What each alert means

- **Priority 5, `Site down:`.** The first failure. The `site-down` issue opens.
- **Priority 5, `Site failures changed:`.** The set of failing sites or checks
  changed.
- **Priority 5, `Still down:`.** The same failures, 6 hours after the last
  alert.
- **Priority 3, `Sites recovered`.** Everything passes again. The issue closes.

Tapping an alert opens the issue. A run with the same failures less than
6 hours after the last alert updates the issue and sends nothing.

## How the monitor works

`scripts/site-monitor/run-monitor.sh` checks two things for each entry in
`scripts/site-monitor/sites.json`:

1. `baseline-check.sh` against the production URL.
2. The latest `netlify-site-checks / site-check` check-run on the HEAD of the
   repository's default branch. `failure`, `timed_out`, `cancelled` and
   `startup_failure` count as failures. An in-progress or absent run does not,
   because some repositories do not have the caller workflow yet.

A check-run the token cannot read is a fault, not "absent". A fault fails the
run but sends no push. GitHub's failed-run email covers it. A fault never
closes the issue, and a check that was failing stays failing until it can be
read again. The time of the last push advances only after ntfy accepts it.

The alert state is one open issue with the `site-down` label and the
`<!-- site-monitor:v1 -->` marker. The issue body also records the failing set
and the time of the last push, so each run can compare against the previous
one. The run exits nonzero whenever anything fails.

Environment variables:

- `GH_TOKEN`: `issues: write` on `MONITOR_REPO`.
- `MONITOR_TOKEN_<OWNER>`: a per-owner app token with Checks read. The owner
  is upper-cased, with `-` as `_`.
- `NTFY_TOPIC`: the secret topic. When it is empty, the run writes the issue,
  then fails.
- `BASELINE_CHECK`: the path to `baseline-check.sh`.
- `MONITOR_REPO` (default `smartwatermelon/dev-env`), `SITES_FILE`,
  `RUN_URL`, and `MONITOR_NOW` (epoch seconds, for tests).

## Rotating the topic

Repeat steps 1 and 2, then unsubscribe from the old topic in the app.

## Notes

- **Cost.** Actions minutes are free for this repository because it is public.
  The monitor runs 96 times a day.
- **Schedules stop after 60 days of inactivity.** GitHub disables scheduled
  workflows in a public repository after 60 days with no repository activity.
  Re-enable it under Actions > Site Monitor. This affects only the backup
  cron; the MIMOLETTE trigger uses `workflow_dispatch`.
- **The baseline check comes from `smartwatermelon/github-workflows`** at tag
  `netlify-site-checks-v1` (`netlify/baseline-check.sh`). The checkout step
  fails until that tag exists.
- **Credentials for check-runs** are the digest app's, minted per owner: see
  `docs/runbooks/dependabot-digest-credentials.md`.
