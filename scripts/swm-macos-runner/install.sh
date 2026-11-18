#!/bin/bash
# Install or refresh the smartwatermelon macOS runner LaunchAgent (login user, not root).
set -uo pipefail
unset CDPATH
# Bash 5.2 treats & in a replacement as the match; these values are literal.
shopt -u patsub_replacement 2>/dev/null || true

ID_BIN="${ID_BIN:-id}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
INSTALL_BIN="${INSTALL_BIN:-install}"
RM_BIN="${RM_BIN:-rm}"
GIT_BIN="${GIT_BIN:-git}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC="${HOME}/.local/libexec/swm-macos-runner"
AGENTS="${HOME}/Library/LaunchAgents"
ENV_FILE="${SWM_ENV_FILE:-${HOME}/.config/nos-runner/env}"
LABEL="com.smartwatermelon.swm-macos-runner"
PLIST="${AGENTS}/${LABEL}.plist"
UPD_LABEL="com.smartwatermelon.swm-macos-runner-update"
UPD_PLIST="${AGENTS}/${UPD_LABEL}.plist"
# Matches ExitTimeOut in the plist (300 s); bootout returns while the job drains.
EXIT_TIMEOUT=300

die() {
  echo "install: $*" >&2
  exit 1
}

# xml_esc TEXT: escape the five XML characters (& first).
xml_esc() {
  local t="$1"
  t="${t//&/&amp;}"
  t="${t//</&lt;}"
  t="${t//>/&gt;}"
  t="${t//\"/&quot;}"
  t="${t//\'/&apos;}"
  printf '%s' "${t}"
}

uid="$("${ID_BIN}" -u)" || exit 1
[[ "${uid}" != "0" ]] || die "run as the login user, not root"

# TART_HOME comes from config.sh in the source tree, never hard-coded here.
tart_home="$(bash -c 'source "$1/config.sh" && printf "%s" "${TART_HOME}"' _ "${HERE}")" || die "cannot read ${HERE}/config.sh"
[[ -n "${tart_home}" ]] || die "TART_HOME is empty"

topic=""
if [[ -f "${ENV_FILE}" ]]; then topic="$(sed -n 's/^NTFY_TOPIC=//p' "${ENV_FILE}" | sed -n 1p)"; fi
ntfy_env=""
if [[ -n "${topic}" ]]; then
  [[ "${topic}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "NTFY_TOPIC in ${ENV_FILE} has characters outside A-Za-z0-9_.-"
  ntfy_env="$(printf '    <key>NTFY_TOPIC</key>\n    <string>%s</string>' "$(xml_esc "${topic}")")"
else
  echo "install: warning: no NTFY_TOPIC in ${ENV_FILE}; alerts will not be sent" >&2
fi

# The updater plist gets the topic only (its alerts); the supervisor knobs below are not for it.
upd_env="${ntfy_env}"

# SWM_<NAME>_S=<secs> env-file lines go into the plist; other SWM_ lines are refused.
if [[ -f "${ENV_FILE}" ]]; then
  knob_keys=" "
  while IFS= read -r line || [[ -n "${line}" ]]; do
    bare="${line#"${line%%[![:space:]]*}"}"
    bare="${bare#export }"
    [[ "${bare}" == SWM_* ]] || continue
    [[ "${line}" =~ ^(SWM_[A-Z_]+_S)=([0-9]+)$ ]] || die "${ENV_FILE}: '${line}' is not SWM_<NAME>_S=<seconds>"
    [[ "${knob_keys}" != *" ${BASH_REMATCH[1]} "* ]] || die "${ENV_FILE}: ${BASH_REMATCH[1]} is set twice"
    knob_keys="${knob_keys}${BASH_REMATCH[1]} "
    ntfy_env="${ntfy_env:+${ntfy_env}$'\n'}$(printf '    <key>%s</key>\n    <string>%s</string>' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
  done <"${ENV_FILE}"
fi

x_libexec="$(xml_esc "${LIBEXEC}")"
x_home="$(xml_esc "${HOME}")"
x_tart="$(xml_esc "${tart_home}")"

# render TEMPLATE OUT [ENV]: fill the @TOKEN@ placeholders; ENV (default: the topic and knobs) replaces @NTFY_ENV@.
render() {
  local line env="${3-${ntfy_env}}"
  : >"$2"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "@NTFY_ENV@" ]]; then
      if [[ -n "${env}" ]]; then printf '%s\n' "${env}" >>"$2"; fi
      continue
    fi
    line="${line//@LIBEXEC@/${x_libexec}}"
    line="${line//@HOME@/${x_home}}"
    line="${line//@TART_HOME@/${x_tart}}"
    printf '%s\n' "${line}" >>"$2"
  done <"$1"
}

rendered="$(mktemp -d "${TMPDIR:-/tmp}/swm-install.XXXXXX")" || die "cannot create a temp directory"
trap '"${RM_BIN}" -rf "${rendered:?}"' EXIT

render "${HERE}/launchd/${LABEL}.plist" "${rendered}/${LABEL}.plist" || die "cannot render ${LABEL}.plist"
if grep -q '@[A-Z_]*@' "${rendered}/${LABEL}.plist"; then die "an unfilled placeholder is left in ${LABEL}.plist"; fi
render "${HERE}/launchd/${UPD_LABEL}.plist" "${rendered}/${UPD_LABEL}.plist" "${upd_env}" || die "cannot render ${UPD_LABEL}.plist"
if grep -q '@[A-Z_]*@' "${rendered}/${UPD_LABEL}.plist"; then die "an unfilled placeholder is left in ${UPD_LABEL}.plist"; fi

domain="gui/${uid}"
# Stop the old job first: bash reads a script as it runs. Bootout returns mid-drain; wait up to 330 s.
"${LAUNCHCTL_BIN}" bootout "${domain}/${LABEL}" >/dev/null 2>&1 || true
gone=0
for ((i = 0; i < EXIT_TIMEOUT + 30; i += 1)); do
  if ! "${LAUNCHCTL_BIN}" print "${domain}/${LABEL}" >/dev/null 2>&1; then
    gone=1
    break
  fi
  "${SLEEP_BIN}" 1
done
if [[ "${gone}" != 1 ]]; then echo "install: ${LABEL} still loaded after bootout; trying bootstrap anyway" >&2; fi

# Everything the supervisor runs lives on the internal disk: launchd hits a hidden TCC prompt under /Volumes.
"${INSTALL_BIN}" -d -m 0755 "${LIBEXEC}" "${LIBEXEC}/image" "${LIBEXEC}/guest" "${AGENTS}" "${HOME}/Library/Logs" || die "cannot create install directories"
# put SRC DST MODE
put() { "${INSTALL_BIN}" -m "$3" "$1" "$2" || die "cannot install $2"; }
# github-app.sh lives in nos-runner/ in the repo; the supervisor finds it next to itself once installed.
put "${HERE}/supervisor.sh" "${LIBEXEC}/supervisor.sh" 0755
put "${HERE}/config.sh" "${LIBEXEC}/config.sh" 0644
put "${HERE}/lib.sh" "${LIBEXEC}/lib.sh" 0644
put "${HERE}/../nos-runner/github-app.sh" "${LIBEXEC}/github-app.sh" 0644
for f in "${HERE}/image/"*.sh; do put "${f}" "${LIBEXEC}/image/${f##*/}" 0755; done
# config.sh hashes ${LIBEXEC}/guest into the image name, so guest/ must be installed whole.
for f in "${HERE}/guest/"*; do put "${f}" "${LIBEXEC}/guest/${f##*/}" 0755; done
# update.sh runs as one parsed line (main; exit 0), so a replaced file is not re-read mid-run.
put "${HERE}/update.sh" "${LIBEXEC}/update.sh" 0755
put "${rendered}/${LABEL}.plist" "${PLIST}" 0600
put "${rendered}/${UPD_LABEL}.plist" "${UPD_PLIST}" 0600

"${LAUNCHCTL_BIN}" bootstrap "${domain}" "${PLIST}" || die "launchctl bootstrap failed; rerun install.sh"
echo "install: ${LABEL} loaded. The first start builds the image (about 15 min)." >&2

# Booting the updater out from inside its own job would kill this script, so the updater run only writes the files.
if [[ "${SWM_FROM_UPDATER:-}" == 1 ]]; then
  echo "install: ${UPD_LABEL} not reloaded from the updater; run install.sh by hand if its plist changed" >&2
  exit 0
fi
# Record this version so the updater's first run does not restart the supervisor and cut a build short.
state_dir="${SWM_STATE_DIR:-${HOME}/.local/state/swm-macos-runner}"
if rev="$("${GIT_BIN}" -C "${HERE}/../.." log -1 --format=%H -- scripts/swm-macos-runner scripts/nos-runner/github-app.sh 2>/dev/null)" && [[ -n "${rev}" ]]; then
  (umask 077 && mkdir -p "${state_dir}" && printf '%s\n' "${rev}" >"${state_dir}/installed") || echo "install: cannot write ${state_dir}/installed" >&2
fi
"${LAUNCHCTL_BIN}" bootout "${domain}/${UPD_LABEL}" >/dev/null 2>&1 || true
for ((i = 0; i < 30; i += 1)); do
  if ! "${LAUNCHCTL_BIN}" print "${domain}/${UPD_LABEL}" >/dev/null 2>&1; then break; fi
  "${SLEEP_BIN}" 1
done
"${LAUNCHCTL_BIN}" bootstrap "${domain}" "${UPD_PLIST}" || die "launchctl bootstrap of the updater failed; rerun install.sh"
echo "install: ${UPD_LABEL} loaded (every 600 s)." >&2
