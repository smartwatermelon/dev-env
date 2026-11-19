#!/bin/bash
# Updater LaunchAgent job (every 600 s): update the clone and run install.sh when the runner code changed and no job runs. Always exits 0.
# After SWM_UPDATE_ALERT_AFTER (default 6) failed passes in a row it sends one ntfy alert, and one more when a pass succeeds again.
set -uo pipefail
unset CDPATH

GIT_BIN="${GIT_BIN:-git}"
BASH_BIN="${BASH_BIN:-/bin/bash}"
RM_BIN="${RM_BIN:-rm}"
CURL_BIN="${CURL_BIN:-curl}"
NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
CLONE="${SWM_CLONE:-${HOME}/.local/share/dev-env}"
STATE_DIR="${SWM_STATE_DIR:-${HOME}/.local/state/swm-macos-runner}"
MARK="${STATE_DIR}/installed"
SLOT_FILE="${STATE_DIR}/slot"
# Tells an idle supervisor to hold off starting a VM until this install is done.
PENDING="${STATE_DIR}/update-pending"
# Consecutive failed passes, and a marker that the failure alert went out (so later failures stay quiet).
FAILS="${STATE_DIR}/update-fails"
ALERTED="${STATE_DIR}/update-alerted"
ALERT_AFTER="${SWM_UPDATE_ALERT_AFTER:-6}"
# PENDING holds the epoch it was first written; one alert once it is older than this, marked by PENDING_ALERTED.
PENDING_ALERT_S="${SWM_UPDATE_PENDING_ALERT_S:-21600}"
PENDING_ALERTED="${STATE_DIR}/update-pending-alerted"

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s update: %s\n' "${ts}" "$*" >&2
}

# notify MSG: always returns 0; NOTIFY_OK=1 only when ntfy accepted MSG. Same contract as notify in lib.sh, which this job does not source.
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

# pass_failed REASON: count the failed pass; alert once when the count reaches the threshold.
pass_failed() {
  local n alert_after="${ALERT_AFTER}"
  log "$1; will retry"
  n="$(cat "${FAILS}" 2>/dev/null)" || n=0
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1))
  (umask 077 && mkdir -p "${STATE_DIR}" && printf '%s\n' "${n}" >"${FAILS}") || log "cannot write ${FAILS}"
  if [[ ! "${alert_after}" =~ ^[0-9]+$ ]] || [[ "${alert_after}" -lt 1 ]]; then
    log "SWM_UPDATE_ALERT_AFTER is not a positive number; using 6"
    alert_after=6
  fi
  if [[ "${n}" -ge "${alert_after}" && ! -e "${ALERTED}" ]]; then
    notify "macOS runner: the updater has failed ${n} passes in a row. Last failure: $1"
    if [[ "${NOTIFY_OK}" -eq 1 ]]; then (umask 077 && : >"${ALERTED}") || log "cannot write ${ALERTED}"; fi
  fi
}

# pass_ok: a pass that ended up to date or installed. Clears the count; sends one recovery alert if a failure alert went out.
pass_ok() {
  "${RM_BIN}" -f "${FAILS}"
  if [[ -e "${ALERTED}" ]]; then
    notify "macOS runner: the updater works again."
    if [[ "${NOTIFY_OK}" -eq 1 ]]; then "${RM_BIN}" -f "${ALERTED}"; fi
  fi
}

# pending_since: the epoch in PENDING; writes the current one when the file is missing or holds no number.
pending_since() {
  local s
  s="$(cat "${PENDING}" 2>/dev/null)" || s=""
  if [[ ! "${s}" =~ ^[0-9]+$ ]]; then
    s="$(date +%s)"
    (umask 077 && mkdir -p "${STATE_DIR}" && printf '%s\n' "${s}" >"${PENDING}") || log "cannot write ${PENDING}"
  fi
  printf '%s' "${s}"
}

# pending_backstop: after every pass. One alert when PENDING is older than the limit; its marker goes with PENDING.
pending_backstop() {
  local since t age limit="${PENDING_ALERT_S}"
  if [[ ! -e "${PENDING}" ]]; then
    if [[ -e "${PENDING_ALERTED}" ]]; then "${RM_BIN}" -f "${PENDING_ALERTED}"; fi
    return 0
  fi
  if [[ ! "${limit}" =~ ^[0-9]+$ ]] || [[ "${limit}" -lt 1 ]]; then
    log "SWM_UPDATE_PENDING_ALERT_S is not a positive number; using 21600"
    limit=21600
  fi
  since="$(pending_since)"
  t="$(date +%s)"
  age=$((t - since))
  if [[ "${age}" -ge "${limit}" && ! -e "${PENDING_ALERTED}" ]]; then
    notify "macOS runner: an update has been pending for $((age / 3600)) h $((age % 3600 / 60)) min and has not installed. See the supervisor and updater logs."
    if [[ "${NOTIFY_OK}" -eq 1 ]]; then (umask 077 && : >"${PENDING_ALERTED}") || log "cannot write ${PENDING_ALERTED}"; fi
  fi
}

main() {
  # Not `git pull`: the NOS updater runs in the same second, and two pulls
  # collide on FETCH_HEAD. Any failure retries.
  if ! "${GIT_BIN}" -C "${CLONE}" fetch --quiet --no-write-fetch-head origin >/dev/null 2>&1 ||
    ! "${GIT_BIN}" -C "${CLONE}" merge --quiet --ff-only origin/main >/dev/null 2>&1; then
    pass_failed "git update failed"
    return 0
  fi

  # Version: the last commit touching the runner code or the github-app.sh it borrows from nos-runner/.
  local rev have job k v
  rev="$("${GIT_BIN}" -C "${CLONE}" log -1 --format=%H -- scripts/swm-macos-runner scripts/nos-runner/github-app.sh 2>/dev/null)" || rev=""
  if [[ -z "${rev}" ]]; then
    pass_failed "cannot read the scripts/swm-macos-runner revision"
    return 0
  fi
  have="$(cat "${MARK}" 2>/dev/null)" || have=""
  if [[ "${rev}" == "${have}" ]]; then
    "${RM_BIN}" -f "${PENDING}"
    pass_ok
    return 0
  fi

  # install.sh restarts the supervisor, which would end a running job. Wait for job=0 (no slot file: no job).
  job=0
  if [[ -f "${SLOT_FILE}" ]]; then
    while IFS='=' read -r k v; do
      if [[ "${k}" == "job" ]]; then job="${v:-0}"; fi
    done <"${SLOT_FILE}"
  fi
  if [[ "${job}" != 0 ]]; then
    # Waiting is neither a failure nor a success: the failure count stays as it is.
    log "new version ${rev} but a job is running; waiting"
    # Written once, so its epoch tells the backstop how long the wait is.
    pending_since >/dev/null
    return 0
  fi

  log "runner code changed (${have:-none} -> ${rev}); running install.sh"
  # SWM_FROM_UPDATER: install.sh must not bootout this job from inside itself.
  if SWM_FROM_UPDATER=1 "${BASH_BIN}" "${CLONE}/scripts/swm-macos-runner/install.sh"; then
    (umask 077 && mkdir -p "${STATE_DIR}" && printf '%s\n' "${rev}" >"${MARK}") || log "cannot write ${MARK}"
    "${RM_BIN}" -f "${PENDING}"
    pass_ok
  else
    pass_failed "install.sh failed"
  fi
  return 0
}

# One line, so bash has parsed it all before install.sh can replace this file.
main; pending_backstop; exit 0
