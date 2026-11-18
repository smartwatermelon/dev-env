#!/bin/bash
# Updater LaunchAgent job (every 600 s): pull the clone and run install.sh when the runner code changed and no job runs. Always exits 0.
set -uo pipefail
unset CDPATH

GIT_BIN="${GIT_BIN:-git}"
BASH_BIN="${BASH_BIN:-/bin/bash}"
RM_BIN="${RM_BIN:-rm}"
CLONE="${SWM_CLONE:-${HOME}/.local/share/dev-env}"
STATE_DIR="${SWM_STATE_DIR:-${HOME}/.local/state/swm-macos-runner}"
MARK="${STATE_DIR}/installed"
SLOT_FILE="${STATE_DIR}/slot"
# Tells an idle supervisor to hold off starting a VM until this install is done.
PENDING="${STATE_DIR}/update-pending"

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s update: %s\n' "${ts}" "$*" >&2
}

main() {
  # A pull failure (network down, the NOS updater holding the clone's lock) is not an error: retry next interval.
  if ! "${GIT_BIN}" -C "${CLONE}" pull --ff-only >/dev/null 2>&1; then
    log "git pull failed; will retry"
    return 0
  fi

  # Version: the last commit touching the runner code or the github-app.sh it borrows from nos-runner/.
  local rev have job k v
  rev="$("${GIT_BIN}" -C "${CLONE}" log -1 --format=%H -- scripts/swm-macos-runner scripts/nos-runner/github-app.sh 2>/dev/null)" || rev=""
  if [[ -z "${rev}" ]]; then
    log "cannot read the scripts/swm-macos-runner revision"
    return 0
  fi
  have="$(cat "${MARK}" 2>/dev/null)" || have=""
  if [[ "${rev}" == "${have}" ]]; then
    "${RM_BIN}" -f "${PENDING}"
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
    log "new version ${rev} but a job is running; waiting"
    (umask 077 && mkdir -p "${STATE_DIR}" && : >"${PENDING}") || log "cannot write ${PENDING}"
    return 0
  fi

  log "runner code changed (${have:-none} -> ${rev}); running install.sh"
  # SWM_FROM_UPDATER: install.sh must not bootout this job from inside itself.
  if SWM_FROM_UPDATER=1 "${BASH_BIN}" "${CLONE}/scripts/swm-macos-runner/install.sh"; then
    (umask 077 && mkdir -p "${STATE_DIR}" && printf '%s\n' "${rev}" >"${MARK}") || log "cannot write ${MARK}"
    "${RM_BIN}" -f "${PENDING}"
  else
    log "install.sh failed; will retry"
  fi
  return 0
}

# One line, so bash has parsed it all before install.sh can replace this file.
main; exit 0
