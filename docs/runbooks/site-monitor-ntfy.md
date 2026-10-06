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
  Re-enable it under Actions > Site Monitor.
- **The baseline check comes from `smartwatermelon/github-workflows`** at tag
  `netlify-site-checks-v1` (`netlify/baseline-check.sh`). The checkout step
  fails until that tag exists.
- **Credentials for check-runs** are the digest app's, minted per owner: see
  `docs/runbooks/dependabot-digest-credentials.md`.
