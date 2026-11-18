#!/bin/bash
# macOS runner supervisor (launchd, gui/501): one Tart VM per job, one slot. Never writes SWM_MACOS_RUNNER.

# Usage: supervisor.sh run (loop until SIGTERM) | once (one pass, for tests) | test-alert (one drill alert).
set -uo pipefail
unset CDPATH

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "${HERE}/config.sh"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"
# install.sh copies github-app.sh next to this script; in the repo it lives in nos-runner/.
_gh_app="${HERE}/github-app.sh"
[[ -f "${_gh_app}" ]] || _gh_app="${HERE}/../nos-runner/github-app.sh"
# shellcheck source=../nos-runner/github-app.sh
. "${_gh_app}"

# launchd PATH is minimal, so prefer the Homebrew binary when it exists.
_default_bin() {
  if [[ -x "/opt/homebrew/bin/$1" ]]; then echo "/opt/homebrew/bin/$1"; else echo "$1"; fi
}
: "${TART_BIN:=$(_default_bin tart)}"
: "${DF_BIN:=df}"
: "${JQ_BIN:=$(_default_jq)}"
: "${SWM_BUILD_BIN:=${HERE}/image/build-image.sh}"
# build-image.sh reads these from the environment.
export TART_BIN KILL_BIN SWM_IMAGE
# github-app.sh: the swm-runner key, never the NOS one.
GH_APP_KEY_SERVICE=swm-runner-app-key
GH_APP_KEY_ACCOUNT=smartwatermelon
export GH_APP_KEY_SERVICE GH_APP_KEY_ACCOUNT

GUEST_JOB=/usr/local/libexec/swm-runner/run-job.sh
VM_RE='^mimolette-macos-[0-9]+$'
SLOT_FILE="${SWM_STATE_DIR}/slot"
NOS_API_STATUS_FILE="${SWM_STATE_DIR}/api.status"
OUT_FILE="${SWM_STATE_DIR}/tart.out"
START_MARK="${SWM_STATE_DIR}/vm-start"
# update.sh writes this while it holds a new version back for a busy slot.
UPDATE_PENDING="${SWM_STATE_DIR}/update-pending"
NOS_TOKEN=""
TOKEN_AT=0
SL_NAME=""
SL_ID=""
SL_FAILS=0
SL_ALERT=""
SL_JOB=0
KIND=""
REASON=""
HUNG=0
VM=""
STOP=0
ABORT_OK=0
SLEEP_PID=""
API_CODE=000

running() { [[ "${STOP}" -eq 0 ]]; }
now() { date +%s; }
api_code() { API_CODE="$(cat "${NOS_API_STATUS_FILE}" 2>/dev/null)" || API_CODE=000; }

# Slot state: name= VM, id= runner to deregister, fails=, alert= last KIND alerted, job= 1 while a job may run.
slot_save() {
  printf 'name=%s\nid=%s\nfails=%s\nalert=%s\njob=%s\n' "${SL_NAME}" "${SL_ID}" "${SL_FAILS}" "${SL_ALERT}" "${SL_JOB}" >"${SLOT_FILE}"
}
slot_load() {
  local k v
  SL_NAME=""
  SL_ID=""
  SL_FAILS=0
  SL_ALERT=""
  SL_JOB=0
  [[ -f "${SLOT_FILE}" ]] || return 0
  while IFS='=' read -r k v; do
    case "${k}" in
      name) SL_NAME="${v}" ;;
      id) SL_ID="${v}" ;;
      fails) [[ "${v}" =~ ^[0-9]+$ ]] && SL_FAILS="${v}" ;;
      alert) SL_ALERT="${v}" ;;
      job) SL_JOB="${v:-0}" ;;
      *) ;;
    esac
  done <"${SLOT_FILE}"
}

# tt LIMIT ARGS...: one bounded tart call; a time-out sets HUNG (the removable-volume TCC hang shows this way).
tt() {
  local lim="$1" rc=0
  shift
  bounded "${lim}" "${TART_BIN}" "$@" || rc=$?
  if [[ "${rc}" -eq 124 ]]; then HUNG=1; fi
  return "${rc}"
}
# set_fail KIND REASON: record why the pass failed; returns 1 so callers can end with it.
set_fail() {
  KIND="$1"
  REASON="$2"
  return 1
}

# Installation tokens last 60 min and a job may last 6 h: mint again after 50 min.
ensure_token() {
  local t
  t="$(now)"
  if [[ -n "${NOS_TOKEN}" && $((t - TOKEN_AT)) -lt 3000 ]]; then return 0; fi
  if ! NOS_TOKEN="$(app_token "${SWM_APP_ID}" "${SWM_INSTALLATION_ID}")"; then
    NOS_TOKEN=""
    log "cannot mint a swm-runner installation token"
    return 1
  fi
  TOKEN_AT="${t}"
}
# delete_runner ID: 0 when deleted (2xx) or already gone (404).
delete_runner() {
  [[ -n "$1" ]] || return 0
  ensure_token || return 1
  gh_api DELETE "/orgs/${SWM_ORG}/actions/runners/$1" >/dev/null 2>&1
  api_code
  [[ "${API_CODE}" =~ ^(2[0-9][0-9]|404)$ ]] && return 0
  log "runner $1: delete failed (HTTP ${API_CODE}); will retry"
  return 1
}

# destroy_vm NAME: stop, then delete. Refuses any name that is not one of ours.
destroy_vm() {
  if [[ ! "$1" =~ ${VM_RE} ]]; then
    log "refusing to delete VM '$1': not mimolette-macos-<epoch>"
    return 1
  fi
  tt "${SWM_STOP_LIMIT_S}" stop "$1" || true
  if [[ -n "${RUN_PID}" && "$1" == "${VM}" ]]; then wait_run || true; fi
  if ! tt "${SWM_DELETE_LIMIT_S}" delete "$1"; then
    log "could not delete VM $1"
    return 1
  fi
  log "deleted VM $1"
}

# list_vms: local VM names into VMS.
list_vms() {
  VMS=""
  SWM_OUT="${OUT_FILE}" tt "${SWM_LIST_LIMIT_S}" list --source local --quiet || return 1
  VMS="$(cat "${OUT_FILE}")"
}

# sweep: delete every mimolette-macos-* VM and deregister the recorded runner. No slot starts until both are gone.
sweep() {
  local v left=0
  SL_JOB=0
  slot_save
  list_vms || set_fail start "tart list failed" || return 1
  while IFS= read -r v; do
    [[ "${v}" =~ ${VM_RE} ]] || continue
    log "sweep: removing leftover VM ${v}"
    destroy_vm "${v}" || left=1
  done <<<"${VMS}"
  if [[ "${left}" -eq 1 ]]; then set_fail start "a leftover mimolette-macos VM could not be deleted" || return 1; fi
  SL_NAME=""
  if [[ -n "${SL_ID}" ]]; then
    delete_runner "${SL_ID}" || {
      slot_save
      set_fail start "runner ${SL_ID} from the last slot is still registered" || return 1
    }
    SL_ID=""
  fi
  slot_save
}

# update_wait: wait up to SWM_UPDATE_WAIT_S for update.sh to install; SIGTERM ends it.
update_wait() {
  local deadline t
  [[ -e "${UPDATE_PENDING}" ]] || return 0
  t="$(now)"
  deadline=$((t + SWM_UPDATE_WAIT_S))
  log "update pending; waiting up to ${SWM_UPDATE_WAIT_S} s for update.sh to install it"
  while running; do
    if [[ ! -e "${UPDATE_PENDING}" ]]; then
      log "update installed or withdrawn; continuing"
      return 0
    fi
    t="$(now)"
    if [[ "${t}" -ge "${deadline}" ]]; then
      log "update still pending after ${SWM_UPDATE_WAIT_S} s; continuing"
      return 0
    fi
    sleep "${SWM_UPDATE_POLL_S}" &
    SLEEP_PID=$!
    wait "${SLEEP_PID}" 2>/dev/null
    SLEEP_PID=""
  done
  return 1
}

pf_ok_fresh() {
  local hit
  [[ -f "${SWM_PF_OK_FILE}" ]] || return 1
  hit="$(find "${SWM_PF_OK_FILE}" -mmin -10 2>/dev/null)" || return 1
  [[ -n "${hit}" ]]
}
# self_checks: pf, then disk, then the image (built here when missing).
self_checks() {
  local gb
  pf_ok_fresh || set_fail pf "ok file ${SWM_PF_OK_FILE} is missing or older than 10 min" || return 1
  gb=""
  if SWM_OUT="${OUT_FILE}" bounded "${SWM_DF_LIMIT_S}" "${DF_BIN}" -Pk "${SWM_DISK_PATH}"; then
    gb="$(awk 'NR == 2 { print int($4 / 1048576) }' "${OUT_FILE}")"
  fi
  if [[ ! "${gb}" =~ ^[0-9]+$ ]]; then set_fail disk "df on ${SWM_DISK_PATH} failed or timed out" || return 1; fi
  if [[ "${gb}" -lt "${SWM_MIN_FREE_GB}" ]]; then
    set_fail disk "${gb} GB free on ${SWM_DISK_PATH}, below ${SWM_MIN_FREE_GB} GB" || return 1
  fi
  if [[ -n "${SWM_IMAGE}" ]] && grep -qxF -- "${SWM_IMAGE}" <<<"${VMS}"; then return 0; fi
  running || return 1
  log "image ${SWM_IMAGE:-<unset>} is missing; building it"
  ABORT_OK=1
  bounded "${SWM_BUILD_LIMIT_S}" /bin/bash "${SWM_BUILD_BIN}" || {
    ABORT_OK=0
    set_fail build "image ${SWM_IMAGE:-<unset>} could not be built" || return 1
  }
  ABORT_OK=0
}

# probe ready|v6: the guest agent answers | the IPv6 ok file is newer than this VM's start.
probe() {
  case "$1" in
    # Not tt: an exec time-out while the guest boots is a slow start, not a hung tart.
    ready) bounded "${SWM_EXEC_LIMIT_S}" "${TART_BIN}" exec "${VM}" /usr/bin/true ;;
    v6) [[ -f "${SWM_PF_OK_FILE_V6}" && "${SWM_PF_OK_FILE_V6}" -nt "${START_MARK}" ]] ;;
    *) return 1 ;;
  esac
}
# wait_until LIMIT STEP PROBE: retry probe PROBE every STEP s until it succeeds or LIMIT s pass.
wait_until() {
  local deadline t
  t="$(now)"
  deadline=$((t + $1))
  while running; do
    probe "$3" && return 0
    t="$(now)"
    [[ "${t}" -lt "${deadline}" ]] || return 1
    sleep "$2"
  done
  return 1
}

# start_vm: clone and boot VM, wait for its IP, its guest agent and the IPv6 block.
start_vm() {
  local ip
  running || return 1
  # From here to the end of the job, SIGTERM ends the tart call in progress; teardown then runs.
  ABORT_OK=1
  VM="mimolette-macos-$(now)"
  SL_NAME="${VM}"
  slot_save
  tt "${SWM_CLONE_LIMIT_S}" clone "${SWM_IMAGE}" "${VM}" || set_fail start "tart clone failed" || return 1
  running || return 1
  : >"${START_MARK}"
  # run stays up until the VM stops: the ip wait bounds its start, wait_run its end.
  "${TART_BIN}" run --no-graphics "${VM}" </dev/null >/dev/null 2>&1 &
  RUN_PID=$!
  # A few seconds over the --wait, so tart's own limit fires first.
  SWM_OUT="${OUT_FILE}" tt $((SWM_IP_LIMIT_S + 10)) ip --wait "${SWM_IP_LIMIT_S}" "${VM}" ||
    set_fail start "no IP within ${SWM_IP_LIMIT_S} s" || return 1
  # The pf rules cover only this subnet: any other address means the LAN block may not apply to this VM.
  ip="$(tr -d '[:space:]' <"${OUT_FILE}")"
  if [[ ! "${ip}" =~ ^192\.168\.65\.[0-9]+$ ]]; then
    log "VM ${VM} has IP '${ip}', outside 192.168.65.0/24"
    set_fail pf "VM ${VM} has IP '${ip}', not on the guarded 192.168.65.0/24" || return 1
  fi
  wait_until "${SWM_READY_LIMIT_S}" "${SWM_READY_STEP_S}" ready ||
    set_fail start "tart exec not ready within ${SWM_READY_LIMIT_S} s" || return 1
  wait_until "${SWM_V6_LIMIT_S}" "${SWM_V6_STEP_S}" v6 ||
    set_fail pf "IPv6 ok file ${SWM_PF_OK_FILE_V6} not renewed within ${SWM_V6_LIMIT_S} s of the VM start" || return 1
}

# run_job: mint last, so a VM that never boots leaves no registration behind. The JIT reaches tart on fd 3 (a pipe).
run_job() {
  local body resp jit id rc=0
  running || return 1
  ensure_token || set_fail start "cannot mint a swm-runner token" || return 1
  body="$(printf '{"name":"%s","runner_group_id":1,"labels":["%s"],"work_folder":"_work"}' "${VM}" "${SWM_LABEL}")"
  if ! resp="$(gh_api POST "/orgs/${SWM_ORG}/actions/runners/generate-jitconfig" "${body}" 2>/dev/null)"; then
    api_code
    set_fail start "generate-jitconfig failed (HTTP ${API_CODE})" || return 1
  fi
  id="$(printf '%s' "${resp}" | "${JQ_BIN}" -er '.runner.id' 2>/dev/null)" || id=""
  jit="$(printf '%s' "${resp}" | "${JQ_BIN}" -er '.encoded_jit_config' 2>/dev/null)" || jit=""
  resp=""
  SL_ID="${id}"
  slot_save
  if [[ -z "${id}" || -z "${jit}" ]]; then
    jit=""
    set_fail start "generate-jitconfig reply lacks runner.id or encoded_jit_config" || return 1
  fi
  SL_JOB=1
  slot_save
  log "runner ${VM} (id ${id}) handed its JIT config"
  exec 3< <(printf '%s' "${jit}")
  jit=""
  ABORT_OK=1
  running && SWM_IN=/dev/fd/3 bounded "${SWM_JOB_MAX_S}" "${TART_BIN}" exec -i "${VM}" /bin/bash "${GUEST_JOB}" || rc=$?
  ABORT_OK=0
  exec 3<&-
  SL_JOB=0
  slot_save
  if [[ "${STOP}" -eq 1 ]]; then return 1; fi
  # An idle JIT runner reaches SWM_JOB_MAX_S every 6 h: neutral, so it never counts as a fail or a recovery.
  if [[ "${rc}" -eq 124 ]]; then
    log "runner ${VM} reached SWM_JOB_MAX_S (${SWM_JOB_MAX_S} s); not counted"
    return 0
  fi
  [[ "${rc}" -eq 0 ]] || set_fail start "runner exited with status ${rc}" || return 1
  # The job ran to the end: only now is the runner known good.
  SL_FAILS=0
  if [[ -n "${SL_ALERT}" ]]; then
    notify "macOS runner: recovered; runner ${VM} ran a job again (last alert: ${SL_ALERT})"
    SL_ALERT=""
  fi
  slot_save
  log "runner ${VM} finished its job"
}

# teardown: stop and delete the VM, deregister the runner; a failed DELETE keeps id= for the next sweep.
teardown() {
  ABORT_OK=0
  if [[ -n "${VM}" ]]; then
    if destroy_vm "${VM}"; then SL_NAME=""; fi
    VM=""
  fi
  RUN_PID=""
  if [[ -n "${SL_ID}" ]] && delete_runner "${SL_ID}"; then SL_ID=""; fi
  SL_JOB=0
  slot_save
}

# alert_text KIND REASON: the ntfy message; each one starts "macOS runner:".
alert_text() {
  case "$1" in
    pf) echo "macOS runner: pf LAN block not confirmed: $2. No VM runs until it is." ;;
    disk) echo "macOS runner: disk check failed: $2" ;;
    build) echo "macOS runner: image build failed: $2" ;;
    tart-hung) echo "macOS runner: tart is hung ($2). The removable-volume TCC prompt may need Allow." ;;
    *) echo "macOS runner: ${SL_FAILS} starts failed in a row; last: $2" ;;
  esac
}
# fail_pass: count the fail; alert once per change of KIND. start alerts only after 3 fails.
fail_pass() {
  # A time-out anywhere in the pass beats the generic start KIND, so a hang does not flap between the two.
  if [[ "${KIND}" == start && "${HUNG}" -eq 1 ]]; then KIND=tart-hung; fi
  SL_FAILS=$((SL_FAILS + 1))
  log "pass failed (${KIND}, try ${SL_FAILS}): ${REASON}"
  if [[ "${KIND}" != "${SL_ALERT}" ]] && [[ "${KIND}" != start || "${SL_FAILS}" -ge 3 ]]; then
    notify "$(alert_text "${KIND}" "${REASON}")"
    SL_ALERT="${KIND}"
  fi
  slot_save
}

cmd_once() {
  local ok=1
  (umask 077 && mkdir -p "${SWM_STATE_DIR}") || {
    log "cannot create ${SWM_STATE_DIR}"
    return 1
  }
  KIND=""
  REASON=""
  HUNG=0
  VM=""
  slot_load
  if sweep && running && update_wait && self_checks && start_vm && run_job; then ok=0; fi
  teardown
  if [[ "${STOP}" -eq 1 ]]; then
    log "stopped mid-pass; slot cleaned up"
    return 1
  fi
  if [[ "${ok}" -ne 0 ]]; then
    fail_pass
    return 1
  fi
  return 0
}

# On SIGTERM: end the abortable tart call or build at once; the pass then tears the slot down.
cmd_run() {
  local pause
  trap 'STOP=1
    [[ -z "${SLEEP_PID}" ]] || kill "${SLEEP_PID}" 2>/dev/null
    [[ "${ABORT_OK}" -ne 1 ]] || abort_bounded' TERM INT
  while running; do
    cmd_once || true
    running || break
    slot_load
    pause="${SWM_INTERVAL_S}"
    if [[ "${SL_FAILS}" -ge 3 ]]; then
      pause="${SWM_BACKOFF_S}"
      log "${SL_FAILS} fails in a row; next pass in ${pause} s"
    fi
    sleep "${pause}" &
    SLEEP_PID=$!
    wait "${SLEEP_PID}" 2>/dev/null
    SLEEP_PID=""
  done
  log "stopping on SIGTERM"
  exit 0
}

# test-alert: one drill alert; touches no VM or slot. Exit 0 only when ntfy accepted it.
cmd_test_alert() {
  local f="${SWM_ENV_FILE:-${HOME}/.config/nos-runner/env}" at
  if [[ -z "${NTFY_TOPIC:-}" && -f "${f}" ]]; then
    NTFY_TOPIC="$(sed -n 's/^NTFY_TOPIC=//p' "${f}" | sed -n 1p)"
  fi
  if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "test-alert: no NTFY_TOPIC in the environment or ${f}"
    return 1
  fi
  at="$(date '+%H:%M')" || at="?"
  notify "macOS runner: drill of the supervisor alert path (${at}). No action needed."
  notify_ok || return 1
  log "test-alert: sent"
}

case "${1:-}" in
  run) cmd_run ;;
  once)
    cmd_once
    exit $?
    ;;
  test-alert)
    cmd_test_alert
    exit $?
    ;;
  *)
    echo "usage: supervisor.sh run|once|test-alert" >&2
    exit 2
    ;;
esac
