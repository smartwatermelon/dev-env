#!/bin/bash
# Remove agentro and the files install.sh wrote (as root): uninstall.sh --yes
set -uo pipefail
unset CDPATH

ID_BIN="${ID_BIN:-/usr/bin/id}"
SYSADMINCTL_BIN="${SYSADMINCTL_BIN:-/usr/sbin/sysadminctl}"
DSCL_BIN="${DSCL_BIN:-/usr/bin/dscl}"
DSEDITGROUP_BIN="${DSEDITGROUP_BIN:-/usr/sbin/dseditgroup}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
RM_BIN="${RM_BIN:-/bin/rm}"
RMDIR_BIN="${RMDIR_BIN:-/bin/rmdir}"
PKILL_BIN="${PKILL_BIN:-/usr/bin/pkill}"
INSTALL_ROOT="${INSTALL_ROOT:-}"
INSTALL_ROOT="${INSTALL_ROOT%/}"

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/config.sh
. "${HERE}/config.sh" || exit 1
U="${AGENT_RO_USER}"

die() {
  echo "uninstall: $*" >&2
  exit 1
}
say() { echo "uninstall: $*"; }

[[ "${1:-}" == "--yes" ]] || die "this deletes user ${U} and its home; re-run with --yes"
uid="$("${ID_BIN}" -u)" || exit 1
[[ "${uid}" == "0" ]] || die "run as root (sudo)"

"${LAUNCHCTL_BIN}" bootout "system/${AGENT_RO_LABEL}" >/dev/null 2>&1 || true
# Exact paths only; no globs, no recursive delete.
for f in \
  "${AGENT_RO_PLIST}" \
  "${AGENT_RO_SUDOERS}" \
  "${AGENT_RO_SSHD_CONF}" \
  "${AGENT_RO_KEYS_DIR}/authorized_keys" \
  "${AGENT_RO_LIBEXEC}/gate" \
  "${AGENT_RO_LIBEXEC}/sweep.sh" \
  "${AGENT_RO_LIBEXEC}/config.sh"; do
  "${RM_BIN}" -f "${INSTALL_ROOT}${f}" || die "cannot remove ${f}"
done
for d in "${AGENT_RO_KEYS_DIR}" "${AGENT_RO_LIBEXEC}"; do
  [[ ! -d "${INSTALL_ROOT}${d}" ]] || "${RMDIR_BIN}" "${INSTALL_ROOT}${d}" || say "warning: ${d} is not empty; left in place"
done
check="$("${SSHD_BIN}" -t 2>&1)" || die "sshd -t fails after removal: ${check}"

if "${ID_BIN}" "${U}" >/dev/null 2>&1; then
  # Processes and launchd jobs agentro started outlive its keys; stop them.
  auid="$("${ID_BIN}" -u "${U}")" || die "cannot read uid of ${U}"
  "${LAUNCHCTL_BIN}" bootout "user/${auid}" >/dev/null 2>&1 || true
  "${LAUNCHCTL_BIN}" bootout "gui/${auid}" >/dev/null 2>&1 || true
  "${PKILL_BIN}" -KILL -u "${U}" || true
  "${SYSADMINCTL_BIN}" -deleteUser "${U}" || die "sysadminctl -deleteUser failed"
fi
if "${DSCL_BIN}" . -read "/Groups/${U}" >/dev/null 2>&1; then
  "${DSEDITGROUP_BIN}" -o delete "${U}" || die "cannot delete group ${U}"
fi
say "removed ${U}. The sweep log and state in ${AGENT_RO_OWNER_HOME} are left for you to read."
