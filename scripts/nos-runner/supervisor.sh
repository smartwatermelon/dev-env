#!/bin/bash
# NOS runner supervisor (launchd, gui/501): keeps ephemeral runner VMs up; a failed self-check sets NOS_RUNNER=ubuntu-latest.

# Usage: supervisor.sh run (loop until SIGTERM) | once (one pass, for tests) | test-alert (one drill alert).
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
CTR_OUT="${NOS_STATE_DIR}/container.out"
NOS_TOKEN=""
TOKEN_AT=0
HAVE_TOKEN=0
SL_NAME=""
SL_ID=""
SL_FAILS=0
SL_STARTED=0
RUNNING=""
LS_OK=0
KIND=""
REASON=""
STOP=0
RESTART=0
SLEEP_PID=""
API_CODE=000

# running: true until SIGTERM/SIGINT (STOP) or SIGHUP (RESTART). Both end a pass the same way: nothing new is minted or started.
running() { [[ "${STOP}" -eq 0 && "${RESTART}" -eq 0 ]]; }

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s supervisor: %s\n' "${ts}" "$*" >&2
}
now() { date +%s; }
# api_code: set API_CODE to the last HTTP status (000 when unknown).
api_code() { API_CODE="$(cat "${NOS_API_STATUS_FILE}" 2>/dev/null)" || API_CODE=000; }

# notify MSG: always returns 0, since callers end with it; NOTIFY_OK=1 only when ntfy accepted MSG.
notify() {
  NOTIFY_OK=0
  if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "warning: NTFY_TOPIC is unset; alert not sent: $1"
    return 0
  fi
  if [[ ! "${NTFY_TOPIC}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    log "warning: NTFY_TOPIC has characters outside A-Za-z0-9_.-; alert not sent: $1"
    return 0
  fi
  # The URL goes to curl on stdin so the topic never shows in ps.
  if printf 'url = "%s/%s"\n' "${NTFY_BASE}" "${NTFY_TOPIC}" | "${CURL_BIN}" -fsS --max-time 20 -K - -d "$1" >/dev/null 2>&1; then
    NOTIFY_OK=1
  else
    log "ntfy delivery failed"
  fi
  return 0
}

# bounded SECS CMD...: run CMD in the background (stdout to CTR_OUT); kill it after SECS; return its status or 124.

# macOS bash 3.2 has no timeout(1). The 0.1 s poll lets a TERM trap run while CMD is still going.
bounded() {
  local secs="$1" pid ticks=0 rc=0
  shift
  "$@" >"${CTR_OUT}" 2>/dev/null &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${ticks}" -ge $((secs * 10)) ]]; then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      log "timed out after ${secs} s: ${1##*/} ${2:-}"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${pid}" 2>/dev/null || rc=$?
  return "${rc}"
}
ctr() { bounded "${NOS_CONTAINER_TIMEOUT}" "${CONTAINER_BIN}" "$@"; }

# Installation tokens last 60 min; mint a new one after 50. A failed mint alerts once, until a mint works again.
ensure_token() {
  local t mark="${NOS_STATE_DIR}/token-alerted"
  t="$(now)"
  if [[ -n "${NOS_TOKEN}" && $((t - TOKEN_AT)) -lt 3000 ]]; then return 0; fi
  if ! NOS_TOKEN="$(app_token "${NOS_APP_ID}" "${NOS_INSTALLATION_ID}")"; then
    NOS_TOKEN=""
    log "cannot mint an installation token"
    if [[ ! -f "${mark}" ]]; then
      : >"${mark}"
      notify "NOS runner: supervisor cannot mint a GitHub App token; it cannot start runners or set NOS_RUNNER"
    fi
    return 1
  fi
  TOKEN_AT="${t}"
  if [[ -f "${mark}" ]]; then
    "${RM_BIN}" -f "${mark}"
    notify "NOS runner: supervisor can mint GitHub App tokens again"
  fi
}

# Slot state, one file per slot: name= VM (empty: none), id= runner to deregister, fails=, started= epoch.

# slot_put N NAME ID FAILS STARTED
slot_put() { printf 'name=%s\nid=%s\nfails=%s\nstarted=%s\n' "$2" "$3" "$4" "$5" >"${NOS_STATE_DIR}/slot-$1"; }
# slot_load N: read the slot file into SL_NAME, SL_ID, SL_FAILS, SL_STARTED (no subshell).
slot_load() {
  local k v f="${NOS_STATE_DIR}/slot-$1"
  SL_NAME=""
  SL_ID=""
  SL_FAILS=0
  SL_STARTED=0
  [[ -f "${f}" ]] || return 0
  while IFS='=' read -r k v; do
    case "${k}" in
      name) SL_NAME="${v}" ;;
      id) SL_ID="${v}" ;;
      fails) SL_FAILS="${v:-0}" ;;
      started) SL_STARTED="${v:-0}" ;;
      *) ;;
    esac
  done <"${f}"
}

# Verified on container 1.7.1: `container ls` prints a header, then one VM per row with its name (--name) in column 1.
listed() { printf '%s\n' "${RUNNING}" | awk -v n="$1" 'NR > 1 && $1 == n { f = 1 } END { exit !f }'; }
listed_ours() { printf '%s\n' "${RUNNING}" | awk 'NR > 1 && $1 ~ /^mimolette-/ { print $1 }'; }
# refresh_ls: LS_OK=1 only when ls exits 0 and its output starts with the ID header; anything else is an apiserver fault.
refresh_ls() {
  local first="" rest
  LS_OK=0
  ctr ls || return 0
  read -r first rest <"${CTR_OUT}" || true
  if [[ "${first}" != ID ]]; then
    log "container ls printed no ID header; treating the apiserver as down"
    return 0
  fi
  RUNNING="$(cat "${CTR_OUT}")"
  LS_OK=1
}
free_gb() { "${DF_BIN}" -Pk "${NOS_DISK_PATH}" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'; }
pf_ok_fresh() {
  local hit
  [[ -f "${NOS_PF_OK_FILE}" ]] || return 1
  hit="$(find "${NOS_PF_OK_FILE}" -mmin -10 2>/dev/null)" || return 1
  [[ -n "${hit}" ]]
}

# bad_vm_ip: print "NAME IP" for the first mimolette-* VM whose IPv4 (IP column) is outside 192.168.64.0/24.

# Verified IP form: 192.168.64.3/24. A row with no IPv4 there (no IP yet) is logged, not a failure. No IP column fails.
bad_vm_ip() {
  printf '%s\n' "${RUNNING}" | awk '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == "IP") c = i; if (!c) { print "header no-IP-column"; exit } next }
    $1 !~ /^mimolette-/ { next }
    $c !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { print $1 > "/dev/stderr"; next }
    $c !~ /^192\.168\.64\.[0-9]+(\/[0-9]+)?$/ { print $1 " " $c; exit }' 2>"${CTR_OUT}.noip"
  local noip=""
  if [[ -s "${CTR_OUT}.noip" ]]; then noip="$(tr '\n' ' ' <"${CTR_OUT}.noip")" || noip="?"; fi
  if [[ -n "${noip}" ]]; then log "VM with no IPv4 address in container ls yet: ${noip}"; fi
}
SUBNET_MARK="${NOS_STATE_DIR}/subnet-bad"
SUBNET_NEW=0

# local_check: no token needed. On failure set KIND (pf | apiserver | other) and REASON. pf wins: it is the LAN guard.
local_check() {
  local gb bad=""
  refresh_ls
  KIND=""
  SUBNET_NEW=0
  if ! pf_ok_fresh; then
    KIND=pf
    REASON="pf ok file ${NOS_PF_OK_FILE} is missing or older than 10 min"
  elif [[ "${LS_OK}" -ne 1 ]]; then
    KIND=apiserver
    REASON="container apiserver does not answer (container ls failed or timed out)"
  elif [[ -f "${SUBNET_MARK}" ]] || {
    bad="$(bad_vm_ip)"
    [[ -n "${bad}" ]]
  }; then
    # Sticky: VMs started on the next pass would reach the LAN again. Remove the marker by hand once the network is fixed.
    if [[ -n "${bad}" ]]; then
      SUBNET_NEW=1
      printf '%s\n' "${bad}" >"${SUBNET_MARK}" || log "cannot write ${SUBNET_MARK}; the next pass may start VMs again"
    else
      bad="$(cat "${SUBNET_MARK}")" || bad="?"
    fi
    KIND=pf
    REASON="VM ${bad} is outside 192.168.64.0/24, which the pf rules cover; remove ${SUBNET_MARK} once fixed"
    if [[ "${bad}" == "header no-IP-column" ]]; then REASON="container ls has no IP column; remove ${SUBNET_MARK} once checked"; fi
  elif ! running; then
    : # SIGTERM or SIGHUP: skip the slower checks; cmd_once returns next.
  elif [[ -z "${NOS_IMAGE}" ]] || ! ctr image inspect "${NOS_IMAGE}"; then
    KIND=other
    REASON="image ${NOS_IMAGE:-<unset>} is missing"
  else
    gb="$(free_gb)"
    if [[ ! "${gb}" =~ ^[0-9]+$ ]] || [[ "${gb}" -lt "${NOS_MIN_FREE_GB}" ]]; then
      KIND=other
      REASON="free disk ${gb:-unknown} GB is below ${NOS_MIN_FREE_GB} GB"
    fi
  fi
  [[ -z "${KIND}" ]]
}

slots_ok() {
  local n
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    slot_load "${n}"
    if [[ "${SL_FAILS}" -ge 3 ]]; then return 1; fi
  done
  return 0
}
reset_fails() {
  local n
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    slot_load "${n}"
    slot_put "${n}" "${SL_NAME}" "${SL_ID}" 0 "${SL_STARTED}"
  done
}

# reconcile (needs a good ls): a gone VM gets an exited-N marker; deregister_pending judges the start from the DELETE result.

# An unnamed mimolette-* VM is stopped, so no more than NOS_SLOTS run.
reconcile() {
  local n name t known=" " c ours
  t="$(now)"
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    slot_load "${n}"
    name="${SL_NAME}"
    [[ -n "${name}" ]] || continue
    if listed "${name}"; then
      known="${known}${name} "
      if [[ -f "${NOS_STATE_DIR}/dropped-${n}" ]] && stop_slot "${n}"; then
        "${RM_BIN}" -f "${NOS_STATE_DIR}/dropped-${n}"
        refresh_ls
      fi
      continue
    fi
    "${RM_BIN}" -f "${NOS_STATE_DIR}/dropped-${n}"
    log "slot ${n}: ${name} exited after $((t - SL_STARTED)) s"
    : >"${NOS_STATE_DIR}/exited-${n}"
    slot_put "${n}" "" "${SL_ID}" "${SL_FAILS}" "${SL_STARTED}"
  done
  ours="$(listed_ours)" || ours=""
  for c in ${ours}; do
    [[ "${known}" == *" ${c} "* ]] && continue
    log "stopping ${c}: running, but no slot names it"
    ctr stop "${c}" || log "container stop ${c} failed"
  done
}

# stop_slot N: clear name= only once the VM is gone (stop succeeded, or ls no longer lists it). id= stays to deregister.
stop_slot() {
  local n="$1" name
  slot_load "${n}"
  name="${SL_NAME}"
  [[ -n "${name}" ]] || return 0
  if ! ctr stop "${name}"; then
    refresh_ls
    if [[ "${LS_OK}" -ne 1 ]] || listed "${name}"; then
      log "slot ${n}: container stop ${name} failed; will retry"
      return 1
    fi
  fi
  log "slot ${n}: stopped ${name}"
  # The VM is gone, so a dropped-N marker would wrongly stop the next VM in this slot.
  "${RM_BIN}" -f "${NOS_STATE_DIR}/dropped-${n}"
  slot_load "${n}"
  slot_put "${n}" "" "${SL_ID}" "${SL_FAILS}" "${SL_STARTED}"
}

# runner_idle ID: true only when GitHub says busy=false, or the runner is gone (404). Unknown counts as busy.
runner_idle() {
  local resp busy
  [[ -n "$1" && "${HAVE_TOKEN}" -eq 1 ]] || return 1
  if ! resp="$(gh_api GET "/orgs/${NOS_ORG}/actions/runners/$1" 2>/dev/null)"; then
    api_code
    [[ "${API_CODE}" == 404 ]]
    return
  fi
  busy="$(printf '%s' "${resp}" | "${JQ_BIN}" -r '.busy' 2>/dev/null)" || return 1
  [[ "${busy}" == false ]]
}

stop_all_slots() {
  local n
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do stop_slot "${n}" || true; done
}
# Busy VMs finish their job; the runner is ephemeral, so it exits after it.
stop_idle_slots() {
  local n name
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    slot_load "${n}"
    name="${SL_NAME}"
    [[ -n "${name}" ]] || continue
    if runner_idle "${SL_ID}"; then
      # Cannot stop (apiserver down): delete the idle runner so the Worker sees it offline. A later good pass stops the VM.
      if ! stop_slot "${n}" && [[ "${HAVE_TOKEN}" -eq 1 ]] && delete_runner "${SL_ID}"; then
        : >"${NOS_STATE_DIR}/dropped-${n}"
        log "slot ${n}: ${name} could not be stopped; runner ${SL_ID} deleted, VM to stop on a later pass"
      fi
    else
      log "slot ${n}: ${name} is busy or unknown; left running"
    fi
  done
}

# delete_runner ID: 0 when deleted (API_CODE 2xx) or already gone (API_CODE 404).
delete_runner() {
  [[ -n "$1" ]] || return 0
  if [[ -z "${NOS_TOKEN:-}" ]]; then
    log "runner $1: delete skipped, no installation token; will retry"
    return 1
  fi
  gh_api DELETE "/orgs/${NOS_ORG}/actions/runners/$1" >/dev/null 2>&1
  api_code
  [[ "${API_CODE}" =~ ^(2[0-9][0-9]|404)$ ]] && return 0
  log "runner $1: delete failed (HTTP ${API_CODE}); will retry"
  return 1
}
# deregister_pending: delete runners whose VM is gone (name= empty, id= set). A failed DELETE keeps id= for retry.

# After a VM exit, DELETE 404 means the runner took a job and removed itself (fails=0); 2xx means it died before one.
deregister_pending() {
  local n id fails mark
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    slot_load "${n}"
    id="${SL_ID}"
    [[ -n "${id}" && -z "${SL_NAME}" ]] || continue
    delete_runner "${id}" || continue
    fails="${SL_FAILS}"
    mark="${NOS_STATE_DIR}/exited-${n}"
    if [[ -f "${mark}" ]]; then
      if [[ "${API_CODE}" == 404 ]]; then
        fails=0
      else
        fails=$((fails + 1))
        log "slot ${n}: runner ${id} was still registered after its VM exited; failed start ${fails}"
      fi
      "${RM_BIN}" -f "${mark}"
    fi
    slot_put "${n}" "" "" "${fails}" "${SL_STARTED}"
  done
}

# set_ubuntu REASON: write ubuntu-latest only over mimolette or an unset/empty value; any other value is a manual hold.

# Alert only after a good write. A failed GET (not 404) still writes: the value is unknown.
set_ubuntu() {
  local resp cur=""
  ensure_token || return 1
  if resp="$(gh_api GET "${VAR_PATH}" 2>/dev/null)"; then
    cur="$(printf '%s' "${resp}" | "${JQ_BIN}" -r '.value // empty' 2>/dev/null)"
    if [[ "${cur}" == ubuntu-latest ]]; then return 0; fi
    if [[ -n "${cur}" && "${cur}" != mimolette ]]; then
      log "NOS_RUNNER held at ${cur}; not changed: $1"
      return 0
    fi
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

# remote_failover REASON: needs a token; later passes retry while the failure lasts. Returns 1 if NOS_RUNNER was not set.
remote_failover() {
  local rc=0
  [[ "${HAVE_TOKEN}" -eq 1 ]] || return 1
  set_ubuntu "$1" || rc=1
  deregister_pending
  return "${rc}"
}

# failover_idle REASON: set NOS_RUNNER first, then stop and deregister idle VMs. Returns 1 if NOS_RUNNER was not set.
failover_idle() {
  local rc=1
  if [[ "${HAVE_TOKEN}" -eq 1 ]] && set_ubuntu "$1"; then rc=0; fi
  stop_idle_slots
  if [[ "${HAVE_TOKEN}" -eq 1 ]]; then deregister_pending; fi
  return "${rc}"
}

# drop_minted N ID FAILS: deregister a runner minted for a VM that did not start. A failed delete keeps id= for retry.
drop_minted() {
  local id="$2"
  if delete_runner "${id}"; then id=""; fi
  slot_put "$1" "" "${id}" "$3" 0
}

# start_slot N: mint a JIT config and run one VM. The JIT goes in a 0600 env file, never argv; the file goes right after.
start_slot() {
  local n="$1" fails name body resp id jit envf t rc=0 stopped=0
  running || return 1
  slot_load "${n}"
  fails="${SL_FAILS}"
  t="$(now)"
  name="mimolette-${n}-${t}"
  body="$(printf '{"name":"%s","runner_group_id":1,"labels":["%s"],"work_folder":"_work"}' "${name}" "${NOS_LABEL}")"
  running || return 1
  if ! resp="$(gh_api POST "/orgs/${NOS_ORG}/actions/runners/generate-jitconfig" "${body}" 2>/dev/null)"; then
    api_code
    log "slot ${n}: generate-jitconfig failed (HTTP ${API_CODE})"
    # A GitHub-side error (5xx, 429, no reply) is not a failed start; the next pass retries.
    case "${API_CODE}" in 000 | 429 | 5[0-9][0-9]) ;; *) fails=$((fails + 1)) ;; esac
    slot_put "${n}" "" "" "${fails}" 0
    return 1
  fi
  id="$(printf '%s' "${resp}" | "${JQ_BIN}" -er '.runner.id' 2>/dev/null)" || id=""
  jit="$(printf '%s' "${resp}" | "${JQ_BIN}" -er '.encoded_jit_config' 2>/dev/null)" || jit=""
  resp=""
  if ! running; then
    jit=""
    drop_minted "${n}" "${id}" "${fails}"
    return 1
  fi
  if [[ -z "${id}" || -z "${jit}" ]]; then
    log "slot ${n}: generate-jitconfig reply lacks runner.id or encoded_jit_config"
    drop_minted "${n}" "${id}" $((fails + 1))
    return 1
  fi
  envf="${NOS_STATE_DIR}/jit-${n}.env"
  "${RM_BIN}" -f "${envf}"
  if ! (umask 077 && printf 'NOS_JIT=%s\n' "${jit}" >"${envf}"); then
    rc=1
  elif ! running; then
    stopped=1
  else
    ctr run -d --rm --name "${name}" -c "${NOS_CPUS}" -m "${NOS_MEMORY}" --env-file "${envf}" "${NOS_IMAGE}" || rc=$?
  fi
  "${RM_BIN}" -f "${envf}"
  jit=""
  if [[ "${stopped}" -eq 1 ]]; then
    drop_minted "${n}" "${id}" "${fails}"
    return 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    # A timed-out run may still have booted the VM; the next reconcile stops it as unnamed.
    log "slot ${n}: container run failed (rc ${rc}, try $((fails + 1)))"
    drop_minted "${n}" "${id}" $((fails + 1))
    return 1
  fi
  # fails= stays until deregister_pending sees this runner take a job (see there).
  slot_put "${n}" "${name}" "${id}" "${fails}" "${t}"
  log "slot ${n}: started ${name} (runner ${id})"
}

tend_slots() {
  local n ours
  for ((n = 1; n <= NOS_SLOTS; n += 1)); do
    running || return 0
    slot_load "${n}"
    [[ -z "${SL_NAME}" ]] || continue
    # A start would overwrite id=; deregister_pending must delete the old runner first.
    if [[ -n "${SL_ID}" ]]; then
      log "slot ${n}: runner ${SL_ID} is still registered; not restarting until it is deleted"
      continue
    fi
    ours="$(listed_ours | grep -c . || true)"
    if [[ "${ours}" -ge "${NOS_SLOTS}" ]]; then
      log "slot ${n}: ${ours} mimolette VMs already listed; not starting another"
      continue
    fi
    if start_slot "${n}"; then
      slot_load "${n}"
      RUNNING="${RUNNING}"$'\n'"${SL_NAME}"
    fi
  done
}

cmd_once() {
  local ok=1
  (umask 077 && mkdir -p "${NOS_STATE_DIR}") || {
    log "cannot create ${NOS_STATE_DIR}"
    return 1
  }
  local_check || ok=0
  if [[ "${LS_OK}" -eq 1 ]]; then reconcile; fi
  # The LAN guard may be off: stop every VM now, before anything that needs the network or a token.
  if [[ "${ok}" -eq 0 && "${KIND}" == pf ]]; then stop_all_slots; fi
  # The marker blocks every start until removed by hand; say so once, even when NOS_RUNNER needs no write.
  if [[ "${SUBNET_NEW}" -eq 1 ]]; then notify "NOS runner: ${REASON}"; fi
  running || return 1
  HAVE_TOKEN=0
  if ensure_token; then HAVE_TOKEN=1; fi
  running || return 1
  if [[ "${ok}" -eq 0 ]]; then
    log "self-check failed: ${REASON}"
    if [[ "${KIND}" == pf ]]; then
      remote_failover "${REASON}" || true
    else
      failover_idle "${REASON}" || true
    fi
    return 1
  fi
  running || return 1
  if [[ "${HAVE_TOKEN}" -ne 1 ]]; then
    log "no installation token; no new slots this pass"
    return 1
  fi
  deregister_pending
  running || return 1
  if ! slots_ok; then
    log "self-check failed: a slot failed 3 starts in a row"
    # Keep the counts until NOS_RUNNER is set, so the next pass retries the failover.
    if failover_idle "a slot failed 3 starts in a row"; then reset_fails; fi
    return 1
  fi
  tend_slots
  if ! slots_ok; then
    log "self-check failed: a slot failed 3 starts in a row"
    # Keep the counts until NOS_RUNNER is set, so the next pass retries the failover.
    if failover_idle "a slot failed 3 starts in a row"; then reset_fails; fi
    return 1
  fi
  return 0
}

# On SIGTERM: switch the fleet, then stop and deregister idle VMs. Busy VMs finish; the next start adopts them.
cmd_run() {
  trap 'STOP=1; [[ -z "${SLEEP_PID}" ]] || kill "${SLEEP_PID}" 2>/dev/null' TERM INT
  # SIGHUP (install.sh after a script change): leave without failover; slot state stays and KeepAlive respawns the new code.
  trap 'RESTART=1; [[ -z "${SLEEP_PID}" ]] || kill "${SLEEP_PID}" 2>/dev/null' HUP
  (umask 077 && mkdir -p "${NOS_STATE_DIR}") || exit 1
  # A SIGKILL mid-start can leave a JIT file behind.
  "${RM_BIN}" -f "${NOS_STATE_DIR}"/jit-*.env
  while running; do
    cmd_once || true
    running || break
    sleep "${NOS_INTERVAL}" &
    SLEEP_PID=$!
    wait "${SLEEP_PID}" 2>/dev/null
    SLEEP_PID=""
  done
  if [[ "${STOP}" -eq 0 ]]; then
    log "restarting on SIGHUP: no failover, slot state kept"
    exit 0
  fi
  log "stopping: switching NOS_RUNNER to ubuntu-latest"
  HAVE_TOKEN=0
  if ensure_token; then HAVE_TOKEN=1; fi
  set_ubuntu "supervisor stopped" || log "could not set NOS_RUNNER on shutdown"
  refresh_ls
  stop_idle_slots
  deregister_pending
  exit 0
}

# test-alert: one drill alert; touches no VM, slot or variable. Exit 0 only when ntfy accepted it.

# By hand NTFY_TOPIC is not set, so read the env file install.sh writes.
cmd_test_alert() {
  local f="${NOS_ENV_FILE:-${HOME}/.config/nos-runner/env}" at
  if [[ -z "${NTFY_TOPIC:-}" && -f "${f}" ]]; then
    NTFY_TOPIC="$(sed -n 's/^NTFY_TOPIC=//p' "${f}" | sed -n 1p)"
  fi
  if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "test-alert: no NTFY_TOPIC in the environment or ${f}"
    return 1
  fi

  at="$(date '+%H:%M')" || at="?"
  notify "NOS runner drill: supervisor alert path (${at}). No action needed."
  if [[ "${NOTIFY_OK}" -ne 1 ]]; then return 1; fi
  log "test-alert: sent"
}

case "${1:-}" in
  run) cmd_run ;;
  test-alert)
    cmd_test_alert
    exit $?
    ;;
  once)
    cmd_once
    exit $?
    ;;
  *)
    echo "usage: supervisor.sh run|once|test-alert" >&2
    exit 2
    ;;
esac
