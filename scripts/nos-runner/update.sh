#!/bin/bash
# Updater LaunchAgent job (every 600 s): update the clone, run install.sh when scripts/nos-runner/ changed. Always exits 0.
# After NOS_UPDATE_ALERT_AFTER (default 6) failed passes in a row it sends one ntfy alert, and one more when a pass succeeds again.
set -uo pipefail
unset CDPATH

GIT_BIN="${GIT_BIN:-git}"
BASH_BIN="${BASH_BIN:-/bin/bash}"
RM_BIN="${RM_BIN:-rm}"
CURL_BIN="${CURL_BIN:-curl}"
NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
CLONE="${NOS_CLONE:-${HOME}/.local/share/dev-env}"
STATE_DIR="${NOS_STATE_DIR:-${HOME}/.local/state/nos-runner}"
MARK="${STATE_DIR}/installed-rev"
# Consecutive failed passes, and a marker that the failure alert went out (so later failures stay quiet).
FAILS="${STATE_DIR}/update-fails"
ALERTED="${STATE_DIR}/update-alerted"
ALERT_AFTER="${NOS_UPDATE_ALERT_AFTER:-6}"

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s update: %s\n' "${ts}" "$*" >&2
}

# notify MSG: always returns 0; NOTIFY_OK=1 only when ntfy accepted MSG. Same contract as notify in supervisor.sh.
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
    log "NOS_UPDATE_ALERT_AFTER is not a positive number; using 6"
    alert_after=6
  fi
  if [[ "${n}" -ge "${alert_after}" && ! -e "${ALERTED}" ]]; then
    notify "NOS runner: the updater has failed ${n} passes in a row. Last failure: $1"
    if [[ "${NOTIFY_OK}" -eq 1 ]]; then (umask 077 && : >"${ALERTED}") || log "cannot write ${ALERTED}"; fi
  fi
}

# pass_ok: a pass that ended up to date or installed. Clears the count; sends one recovery alert if a failure alert went out.
pass_ok() {
  "${RM_BIN}" -f "${FAILS}"
  if [[ -e "${ALERTED}" ]]; then
    notify "NOS runner: the updater works again."
    if [[ "${NOTIFY_OK}" -eq 1 ]]; then "${RM_BIN}" -f "${ALERTED}"; fi
  fi
}

main() {
  # Not `git pull`: the swm updater runs in the same second, and two pulls
  # collide on FETCH_HEAD. Any failure retries.
  if ! "${GIT_BIN}" -C "${CLONE}" fetch --quiet --no-write-fetch-head origin >/dev/null 2>&1 ||
    ! "${GIT_BIN}" -C "${CLONE}" merge --quiet --ff-only origin/main >/dev/null 2>&1; then
    pass_failed "git update failed"
    return 0
  fi

  # The last commit that touched scripts/nos-runner/ is the version to install; the mark file records what is installed.
  local rev have
  rev="$("${GIT_BIN}" -C "${CLONE}" log -1 --format=%H -- scripts/nos-runner 2>/dev/null)" || rev=""
  if [[ -z "${rev}" ]]; then
    pass_failed "cannot read the scripts/nos-runner revision"
    return 0
  fi
  have="$(cat "${MARK}" 2>/dev/null)" || have=""
  if [[ "${rev}" == "${have}" ]]; then
    pass_ok
    return 0
  fi

  log "scripts/nos-runner changed (${have:-none} -> ${rev}); running install.sh"
  if NOS_FROM_UPDATER=1 "${BASH_BIN}" "${CLONE}/scripts/nos-runner/install.sh"; then
    (umask 077 && mkdir -p "${STATE_DIR}" && printf '%s\n' "${rev}" >"${MARK}") || log "cannot write ${MARK}"
    pass_ok
  else
    pass_failed "install.sh failed"
  fi
  return 0
}

# One line, so bash has parsed it all before install.sh can replace this file.
main; exit 0
