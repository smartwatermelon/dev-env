#!/bin/bash
# Updater LaunchAgent job (every 600 s): pull the clone, run install.sh when scripts/nos-runner/ changed. Always exits 0.
set -uo pipefail
unset CDPATH

GIT_BIN="${GIT_BIN:-git}"
BASH_BIN="${BASH_BIN:-/bin/bash}"
CLONE="${NOS_CLONE:-${HOME}/.local/share/dev-env}"
STATE_DIR="${NOS_STATE_DIR:-${HOME}/.local/state/nos-runner}"
MARK="${STATE_DIR}/installed-rev"

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s update: %s\n' "${ts}" "$*" >&2
}

# A pull failure (network down, diverged clone) is not an error: log it and try again next interval.
if ! "${GIT_BIN}" -C "${CLONE}" pull --ff-only >/dev/null 2>&1; then
  log "git pull failed; will retry"
  exit 0
fi

# The last commit that touched scripts/nos-runner/ is the version to install; the mark file records what is installed.
rev="$("${GIT_BIN}" -C "${CLONE}" log -1 --format=%H -- scripts/nos-runner 2>/dev/null)" || rev=""
if [[ -z "${rev}" ]]; then
  log "cannot read the scripts/nos-runner revision"
  exit 0
fi
have="$(cat "${MARK}" 2>/dev/null)" || have=""
if [[ "${rev}" == "${have}" ]]; then exit 0; fi

log "scripts/nos-runner changed (${have:-none} -> ${rev}); running install.sh"
if "${BASH_BIN}" "${CLONE}/scripts/nos-runner/install.sh"; then
  (umask 077 && mkdir -p "${STATE_DIR}" && printf '%s\n' "${rev}" >"${MARK}") || log "cannot write ${MARK}"
else
  log "install.sh failed; will retry"
fi
exit 0
