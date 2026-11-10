#!/bin/bash
# Run once with sudo: install the pf guard and its LaunchDaemon. update.sh never touches these root files.
set -uo pipefail
unset CDPATH

ID_BIN="${ID_BIN:-id}"
INSTALL_BIN="${INSTALL_BIN:-install}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
INSTALL_ROOT="${INSTALL_ROOT:-/}"
INSTALL_ROOT="${INSTALL_ROOT%/}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.nightowlstudio.nos-runner-pf"
LIBEXEC="${INSTALL_ROOT}/usr/local/libexec/nos-runner"
PLIST="${INSTALL_ROOT}/Library/LaunchDaemons/${LABEL}.plist"

uid="$("${ID_BIN}" -u)" || exit 1
if [[ "${uid}" != "0" ]]; then
  echo "install-pf: run as root (sudo)" >&2
  exit 1
fi

"${INSTALL_BIN}" -d -o root -g wheel -m 0755 "${LIBEXEC}" || exit 1
"${INSTALL_BIN}" -d -o root -g wheel -m 0755 "${PLIST%/*}" || exit 1
"${INSTALL_BIN}" -o root -g wheel -m 0755 "${HERE}/pf-guard.sh" "${LIBEXEC}/pf-guard.sh" || exit 1
"${INSTALL_BIN}" -o root -g wheel -m 0644 "${HERE}/nos-runner.pf" "${LIBEXEC}/nos-runner.pf" || exit 1
"${INSTALL_BIN}" -o root -g wheel -m 0644 "${HERE}/${LABEL}.plist" "${PLIST}" || exit 1

# bootout fails when the daemon is not loaded yet; that is fine.
"${LAUNCHCTL_BIN}" bootout "system/${LABEL}" >/dev/null 2>&1 || true
"${LAUNCHCTL_BIN}" bootstrap system "${PLIST}" || exit 1
echo "install-pf: installed; guard runs now and every 300 s"
