#!/bin/bash
# Install or refresh the NOS runner LaunchAgents (login user, not root). Clone dev-env to ~/.local/share/dev-env first.
set -uo pipefail
unset CDPATH
# Bash 5.2 treats & in a replacement as the match; these values are literal.
shopt -u patsub_replacement 2>/dev/null || true

ID_BIN="${ID_BIN:-id}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
CP_BIN="${CP_BIN:-cp}"
MV_BIN="${MV_BIN:-mv}"
RM_BIN="${RM_BIN:-rm}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC="${HOME}/.local/libexec/nos-runner"
AGENTS="${HOME}/Library/LaunchAgents"
ENV_FILE="${NOS_ENV_FILE:-${HOME}/.config/nos-runner/env}"
SUP_LABEL="com.nightowlstudio.nos-runner"
UPD_LABEL="com.nightowlstudio.nos-runner-update"
# Files the supervisor and updater run from libexec. Nothing under a volume path: launchd hits a hidden TCC prompt there.
RUNTIME_FILES="supervisor.sh config.sh github-app.sh update.sh"

die() {
  echo "install: $*" >&2
  exit 1
}

uid="$("${ID_BIN}" -u)" || exit 1
[[ "${uid}" != "0" ]] || die "run as the login user, not root"

# Values come from config.sh in the source tree, never hard-coded here.
cfg="$(bash -c 'source "$1/config.sh" && printf "%s\n%s\n" "${NOS_SHUTDOWN_MAX_S}" "${NOS_IMAGE}"' _ "${HERE}")" || die "cannot read ${HERE}/config.sh"
exit_timeout="$(printf '%s\n' "${cfg}" | sed -n 1p)"
nos_image="$(printf '%s\n' "${cfg}" | sed -n 2p)"
[[ "${exit_timeout}" =~ ^[0-9]+$ ]] || die "NOS_SHUTDOWN_MAX_S is not a number: ${exit_timeout}"
[[ -n "${nos_image}" ]] || die "NOS_IMAGE is empty; ${HERE}/image/Containerfile has no ARG RUNNER_VERSION"

# NTFY_TOPIC comes from the env file so the update job renders the same plist. An env value is saved there first.
if [[ -n "${NTFY_TOPIC:-}" ]]; then
  [[ "${NTFY_TOPIC}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "NTFY_TOPIC has characters outside A-Za-z0-9_.-"
  (umask 077 && mkdir -p "${ENV_FILE%/*}" && printf 'NTFY_TOPIC=%s\n' "${NTFY_TOPIC}" >"${ENV_FILE}") || die "cannot write ${ENV_FILE}"
fi
topic=""
if [[ -f "${ENV_FILE}" ]]; then topic="$(sed -n 's/^NTFY_TOPIC=//p' "${ENV_FILE}" | sed -n 1p)"; fi
ntfy_env=""
if [[ -n "${topic}" ]]; then
  [[ "${topic}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "NTFY_TOPIC in ${ENV_FILE} has characters outside A-Za-z0-9_.-"
  ntfy_env="$(printf '    <key>NTFY_TOPIC</key>\n    <string>%s</string>' "${topic}")"
else
  echo "install: warning: no NTFY_TOPIC (set it or write NTFY_TOPIC=... to ${ENV_FILE}); alerts will not be sent" >&2
fi

STATE_DIR="${NOS_STATE_DIR:-${HOME}/.local/state/nos-runner}"
PENDING="${STATE_DIR}/pending"
mkdir -p "${LIBEXEC}" "${AGENTS}" "${HOME}/Library/Logs" "${PENDING}" || die "cannot create install directories"
# Rendered plists live here; the trap needs it to exist before the first possible exit.
rendered="$(mktemp -d "${TMPDIR:-/tmp}/nos-install.XXXXXX")" || die "cannot create a temp directory"
trap '"${RM_BIN}" -rf "${rendered:?}"' EXIT
# A marker in ${PENDING} records an action that must still happen, so a failed run is finished by the next one.

# put_file SRC DST MODE: temp file plus mv (new inode). Sets PUT=1 when DST changed.
put_file() {
  local src="$1" dst="$2" mode="$3" tmp
  PUT=0
  if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then return 0; fi
  tmp="$(mktemp "${dst}.XXXXXX")" || die "cannot create a temp file next to ${dst}"
  "${CP_BIN}" "${src}" "${tmp}" || {
    "${RM_BIN}" -f "${tmp}"
    die "cannot copy ${src}"
  }
  chmod "${mode}" "${tmp}" || die "cannot chmod ${tmp}"
  "${MV_BIN}" -f "${tmp}" "${dst}" || die "cannot replace ${dst}"
  PUT=1
}

# render TEMPLATE OUT: fill the @TOKEN@ placeholders.
render() {
  local line
  : >"$2"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "@NTFY_ENV@" ]]; then
      if [[ -n "${ntfy_env}" ]]; then printf '%s\n' "${ntfy_env}" >>"$2"; fi
      continue
    fi
    line="${line//@LIBEXEC@/${LIBEXEC}}"
    line="${line//@HOME@/${HOME}}"
    line="${line//@NOS_IMAGE@/${nos_image}}"
    line="${line//@EXIT_TIMEOUT@/${exit_timeout}}"
    printf '%s\n' "${line}" >>"$2"
  done <"$1"
}

for f in ${RUNTIME_FILES}; do
  put_file "${HERE}/${f}" "${LIBEXEC}/${f}" 0755
  # update.sh is read fresh on every updater run, so only the supervisor's own files need a restart.
  if [[ "${PUT}" == 1 && "${f}" != "update.sh" ]]; then : >"${PENDING}/restart"; fi
done

domain="gui/${uid}"

rc=0
sup_booted=0
# load LABEL: bootout (a not-loaded job is fine), then bootstrap. Clears the marker only when bootstrap works.
load() {
  "${LAUNCHCTL_BIN}" bootout "${domain}/$1" >/dev/null 2>&1 || true
  if "${LAUNCHCTL_BIN}" bootstrap "${domain}" "${AGENTS}/$1.plist"; then
    "${RM_BIN}" -f "${PENDING}/load-$1"
    if [[ "$1" == "${SUP_LABEL}" ]]; then sup_booted=1; fi
  else
    echo "install: launchctl bootstrap failed for $1; rerun install.sh" >&2
    rc=1
  fi
}

for label in "${SUP_LABEL}" "${UPD_LABEL}"; do
  render "${HERE}/launchd/${label}.plist" "${rendered}/${label}.plist" || die "cannot render ${label}.plist"
  put_file "${rendered}/${label}.plist" "${AGENTS}/${label}.plist" 0600
  if [[ "${PUT}" == 1 ]]; then : >"${PENDING}/load-${label}"; fi
  if [[ -e "${PENDING}/load-${label}" ]]; then load "${label}"; fi
done

# Bootstrapping the supervisor already starts the new code; otherwise a pending restart needs kickstart -k.
if [[ -e "${PENDING}/restart" ]]; then
  if [[ "${sup_booted}" == 1 ]]; then
    "${RM_BIN}" -f "${PENDING}/restart"
  elif [[ ! -e "${PENDING}/load-${SUP_LABEL}" ]]; then
    if "${LAUNCHCTL_BIN}" kickstart -k "${domain}/${SUP_LABEL}"; then
      "${RM_BIN}" -f "${PENDING}/restart"
    else
      echo "install: launchctl kickstart failed; rerun install.sh" >&2
      rc=1
    fi
  fi
fi
exit "${rc}"
