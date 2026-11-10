#!/bin/bash
# NOS runner supervisor (launchd, gui/501): keeps ephemeral runner VMs up; a failed self-check sets NOS_RUNNER=ubuntu-latest.

# Usage: supervisor.sh run (loop until SIGTERM) | supervisor.sh once (one pass, for tests).
set -uo pipefail
unset CDPATH

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/config.sh
source "${HERE}/config.sh"
# shellcheck source=SCRIPTDIR/github-app.sh
source "${HERE}/github-app.sh"

# launchd PATH is minimal, so prefer the Homebrew binary when it exists.
_default_bin() {
  if [[ -x "/opt/homebrew/bin/$1" ]]; then echo "/opt/homebrew/bin/$1"; else echo "$1"; fi
}
CONTAINER_BIN="${CONTAINER_BIN:-$(_default_bin container)}"
CURL_BIN="${CURL_BIN:-curl}"
DF_BIN="${DF_BIN:-df}"
RM_BIN="${RM_BIN:-rm}"
JQ_BIN="${JQ_BIN:-$(_default_jq)}"

# The supervisor only ever writes this value. The Cloudflare Worker is the only writer of mimolette.
VAR_BODY='{"name":"NOS_RUNNER","value":"ubuntu-latest","visibility":"private"}'
VAR_PATH="/orgs/${NOS_ORG}/actions/variables/NOS_RUNNER"
NOS_API_STATUS_FILE="${NOS_STATE_DIR}/api.status"
NOS_TOKEN=""
TOKEN_AT=0
RUNNING=""
REASON=""
STOP=0
SLEEP_PID=""
API_CODE=000

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s supervisor: %s\n' "${ts}" "$*" >&2
}
# api_code: set API_CODE to the last HTTP status (000 when unknown).
api_code() { API_CODE="$(cat "${NOS_API_STATUS_FILE}" 2>/dev/null)" || API_CODE=000; }

# Installation tokens last 60 min; mint a new one after 50.
ensure_token() {
  local now
  now="$(date +%s)"
  if [[ -n "${NOS_TOKEN}" && $((now - TOKEN_AT)) -lt 3000 ]]; then return 0; fi
  if ! NOS_TOKEN="$(app_token "${NOS_APP_ID}" "${NOS_INSTALLATION_ID}")"; then
    NOS_TOKEN=""
    log "cannot mint an installation token"
    return 1
  fi
  TOKEN_AT="${now}"
}

# Slot state: one file per slot with name=, id= and fails= lines.
slot_file() { printf '%s/slot-%s' "${NOS_STATE_DIR}" "$1"; }
slot_get() {
  local f
  f="$(slot_file "$1")"
  [[ -f "${f}" ]] || return 0
  sed -n "s/^$2=//p" "${f}" | head -n 1
}
slot_put() { printf 'name=%s\nid=%s\nfails=%s\n' "$2" "$3" "$4" >"$(slot_file "$1")"; }

# Deploy check (Task 9): `container ls` prints a header, then one running container per line with its ID (= --name) first.
is_running() {
  printf '%s\n' "${RUNNING}" | awk -v n="$1" 'NR > 1 && $1 == n { f = 1 } END { exit !f }'
}
# Deploy check (Task 9): `container image inspect REF` exits 0 only when the image exists.
image_exists() { [[ -n "${NOS_IMAGE}" ]] && "${CONTAINER_BIN}" image inspect "${NOS_IMAGE}" >/dev/null 2>&1; }
free_gb() { "${DF_BIN}" -Pk "${NOS_DISK_PATH}" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'; }
pf_ok_fresh() {
  local hit
  [[ -f "${NOS_PF_OK_FILE}" ]] || return 1
  hit="$(find "${NOS_PF_OK_FILE}" -mmin -10 2>/dev/null)" || return 1
  [[ -n "${hit}" ]]
}

slots_ok() {
  local n f
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    f="$(slot_get "${n}" fails)"
    if [[ "${f:-0}" -ge 3 ]]; then return 1; fi
  done
  return 0
}

# selfcheck: return 1 and set REASON on the first failed check.
selfcheck() {
  local gb
  if ! RUNNING="$("${CONTAINER_BIN}" ls 2>/dev/null)"; then
    REASON="container apiserver does not answer"
    return 1
  fi
  if ! image_exists; then
    REASON="image ${NOS_IMAGE:-<unset>} is missing"
    return 1
  fi
  gb="$(free_gb)"
  if [[ ! "${gb}" =~ ^[0-9]+$ ]] || [[ "${gb}" -lt "${NOS_MIN_FREE_GB}" ]]; then
    REASON="free disk ${gb:-unknown} GB is below ${NOS_MIN_FREE_GB} GB"
    return 1
  fi
  if ! pf_ok_fresh; then
    REASON="pf ok file ${NOS_PF_OK_FILE} is missing or older than 10 min"
    return 1
  fi
  if ! slots_ok; then
    REASON="a slot failed 3 starts in a row"
    return 1
  fi
  return 0
}

delete_runner() {
  [[ -n "$1" ]] || return 0
  if [[ -z "${NOS_TOKEN}" ]]; then
    log "runner $1: delete skipped, no installation token; it stays registered"
    return 1
  fi
  if ! gh_api DELETE "/orgs/${NOS_ORG}/actions/runners/$1" >/dev/null 2>&1; then
    # 404: the ephemeral runner is already gone, which is normal after a job.
    api_code
    [[ "${API_CODE}" == 404 ]] || log "runner $1: delete failed (HTTP ${API_CODE})"
  fi
}

notify() {
  if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "warning: NTFY_TOPIC is unset; alert not sent: $1"
    return 0
  fi
  "${CURL_BIN}" -fsS --max-time 20 -d "$1" "${NTFY_BASE}/${NTFY_TOPIC}" >/dev/null 2>&1 || log "ntfy delivery failed"
}

# set_ubuntu REASON: write NOS_RUNNER=ubuntu-latest unless GET shows it already. Alert only after a good write.
set_ubuntu() {
  local resp cur=""
  ensure_token || return 1
  if resp="$(gh_api GET "${VAR_PATH}" 2>/dev/null)"; then
    cur="$(printf '%s' "${resp}" | "${JQ_BIN}" -r '.value // empty' 2>/dev/null)"
    if [[ "${cur}" == ubuntu-latest ]]; then return 0; fi
  else
    api_code
    [[ "${API_CODE}" == 404 ]] || log "GET NOS_RUNNER failed (HTTP ${API_CODE}); writing anyway"
  fi
  if ! gh_api PATCH "${VAR_PATH}" "${VAR_BODY}" >/dev/null 2>&1; then
    api_code
    if [[ "${API_CODE}" != 404 ]] ||
      ! gh_api POST "/orgs/${NOS_ORG}/actions/variables" "${VAR_BODY}" >/dev/null 2>&1; then
      api_code
      log "cannot set NOS_RUNNER=ubuntu-latest (HTTP ${API_CODE})"
      return 1
    fi
  fi
  log "NOS_RUNNER set to ubuntu-latest (was ${cur:-unset}): $1"
  notify "NOS runner: NOS_RUNNER set to ubuntu-latest (was ${cur:-unset}). Reason: $1"
}

# Stop every slot and deregister its runner. Fail counts reset, so a later pass retries once the cause clears.
stop_slots() {
  local n name id
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    name="$(slot_get "${n}" name)"
    id="$(slot_get "${n}" id)"
    if [[ -n "${name}" ]]; then
      "${CONTAINER_BIN}" stop "${name}" >/dev/null 2>&1 || log "slot ${n}: container stop ${name} failed"
      delete_runner "${id}"
    fi
    slot_put "${n}" "" "" 0
  done
}

failover() {
  log "self-check failed: $1"
  set_ubuntu "$1"
  stop_slots
}

# start_slot N: mint a JIT config and run one VM. The JIT goes in a 0600 env file, never argv; the file goes right after.
start_slot() {
  local n="$1" fails name body resp id jit envf rc=0
  fails="$(slot_get "${n}" fails)"
  fails="${fails:-0}"
  name="mimolette-${n}-$(date +%s)"
  body="$(printf '{"name":"%s","runner_group_id":1,"labels":["%s"],"work_folder":"_work"}' "${name}" "${NOS_LABEL}")"
  if ! resp="$(gh_api POST "/orgs/${NOS_ORG}/actions/runners/generate-jitconfig" "${body}" 2>/dev/null)"; then
    api_code
    log "slot ${n}: generate-jitconfig failed (HTTP ${API_CODE})"
    slot_put "${n}" "" "" $((fails + 1))
    return 1
  fi
  id="$(printf '%s' "${resp}" | "${JQ_BIN}" -er '.runner.id' 2>/dev/null)" || id=""
  jit="$(printf '%s' "${resp}" | "${JQ_BIN}" -er '.encoded_jit_config' 2>/dev/null)" || jit=""
  resp=""
  if [[ -z "${id}" || -z "${jit}" ]]; then
    log "slot ${n}: generate-jitconfig reply lacks runner.id or encoded_jit_config"
    delete_runner "${id}"
    slot_put "${n}" "" "" $((fails + 1))
    return 1
  fi
  envf="${NOS_STATE_DIR}/jit-${n}.env"
  "${RM_BIN}" -f "${envf}"
  if (umask 077 && printf 'NOS_JIT=%s\n' "${jit}" >"${envf}"); then
    "${CONTAINER_BIN}" run -d --rm --name "${name}" -c "${NOS_CPUS}" -m "${NOS_MEMORY}" \
      --env-file "${envf}" "${NOS_IMAGE}" >/dev/null || rc=$?
  else
    rc=1
  fi
  "${RM_BIN}" -f "${envf}"
  jit=""
  if [[ "${rc}" -ne 0 ]]; then
    log "slot ${n}: container run failed (try $((fails + 1)))"
    delete_runner "${id}"
    slot_put "${n}" "" "" $((fails + 1))
    return 1
  fi
  slot_put "${n}" "${name}" "${id}" 0
  log "slot ${n}: started ${name} (runner ${id})"
}

tend_slots() {
  local n name id
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    name="$(slot_get "${n}" name)"
    id="$(slot_get "${n}" id)"
    if [[ -n "${name}" ]] && is_running "${name}"; then continue; fi
    if [[ -n "${name}" ]]; then
      log "slot ${n}: ${name} exited"
      delete_runner "${id}"
    fi
    start_slot "${n}" || true
  done
}

cmd_once() {
  (umask 077 && mkdir -p "${NOS_STATE_DIR}") || {
    log "cannot create ${NOS_STATE_DIR}"
    return 1
  }
  ensure_token || return 1
  if ! selfcheck; then
    failover "${REASON}"
    return 1
  fi
  tend_slots
  if ! slots_ok; then
    failover "a slot failed 3 starts in a row"
    return 1
  fi
  return 0
}

# Running VMs are left alone on SIGTERM: their jobs finish, and the next start adopts them through the slot files.
cmd_run() {
  trap 'STOP=1; [[ -z "${SLEEP_PID}" ]] || kill "${SLEEP_PID}" 2>/dev/null' TERM INT
  while [[ "${STOP}" -eq 0 ]]; do
    cmd_once || true
    [[ "${STOP}" -eq 0 ]] || break
    sleep "${NOS_INTERVAL}" &
    SLEEP_PID=$!
    wait "${SLEEP_PID}" 2>/dev/null
    SLEEP_PID=""
API_CODE=000
  done
  log "stopping: switching NOS_RUNNER to ubuntu-latest"
  set_ubuntu "supervisor stopped" || log "could not set NOS_RUNNER on shutdown"
  exit 0
}

case "${1:-}" in
  run) cmd_run ;;
  once)
    cmd_once
    exit $?
    ;;
  *)
    echo "usage: supervisor.sh run|once" >&2
    exit 2
    ;;
esac
