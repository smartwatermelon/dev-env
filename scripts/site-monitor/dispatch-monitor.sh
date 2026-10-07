#!/usr/bin/env bash
# Starts site-monitor.yml via the API. launchd on MIMOLETTE runs it every 15 min (dev-env#193); see the site-monitor runbook.
set -uo pipefail
unset CDPATH

REPO="${MONITOR_REPO:-smartwatermelon/dev-env}"
WORKFLOW='site-monitor.yml'
TOKEN_FILE="${DISPATCH_TOKEN_FILE:-${HOME}/.config/site-monitor/dispatch-token}"
API="${GITHUB_API_URL:-https://api.github.com}"

export TZ=UTC
# printf %(...)T is a bash builtin; -1 means now.
log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T dispatch-monitor: %s\n' -1 "$*"; }

if [[ ! -r "${TOKEN_FILE}" ]]; then
  log "cannot read ${TOKEN_FILE}" >&2
  exit 2
fi
token="$(tr -d '[:space:]' <"${TOKEN_FILE}")"
if [[ -z "${token}" ]]; then
  log "${TOKEN_FILE} is empty" >&2
  exit 2
fi

# The header goes in on stdin, so the token never appears in argv (visible to ps) or in this log.
if ! out="$(printf 'Authorization: Bearer %s\n' "${token}" | curl -sS --fail-with-body --max-time 30 --retry 2 \
  -X POST -H @- \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  --data '{"ref":"main"}' \
  "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" 2>&1)"; then
  log "dispatch failed: ${out:0:300}" >&2
  exit 1
fi
log "dispatched ${WORKFLOW} on ${REPO}@main"
