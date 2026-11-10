#!/bin/bash
# Root guard (LaunchDaemon, every 300 s): load the LAN-block anchor, confirm pf is on, write the ok file only if all is well.
set -uo pipefail
unset CDPATH

PFCTL_BIN="${PFCTL_BIN:-/sbin/pfctl}"
RM_BIN="${RM_BIN:-rm}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOS_PF_RULES="${NOS_PF_RULES:-${HERE}/nos-runner.pf}"
NOS_PF_OK_FILE="${NOS_PF_OK_FILE:-/var/run/nos-runner-pf.ok}"
NOS_PF_TOKEN_FILE="${NOS_PF_TOKEN_FILE:-/var/run/nos-runner-pf.token}"
ANCHOR="com.apple/nos-runner"

fail() {
  "${RM_BIN}" -f "${NOS_PF_OK_FILE}"
  echo "pf-guard: $1" >&2
  exit 1
}

# A stale ok file must never outlive a failed check.
"${RM_BIN}" -f "${NOS_PF_OK_FILE}"

[[ -r "${NOS_PF_RULES}" ]] || fail "rules file missing: ${NOS_PF_RULES}"
"${PFCTL_BIN}" -a "${ANCHOR}" -f "${NOS_PF_RULES}" >/dev/null 2>&1 || fail "cannot load rules into anchor ${ANCHOR}"

info="$("${PFCTL_BIN}" -s info 2>/dev/null)" || fail "pfctl -s info failed"
if ! grep -q '^Status: Enabled' <<<"${info}"; then
  # Take one enable reference; keep its token (root only) so a later run does not take another.
  enable_out="$("${PFCTL_BIN}" -E 2>&1)" || fail "pfctl -E failed"
  token="$(sed -n 's/^Token *: *//p' <<<"${enable_out}" | head -n 1)"
  if [[ -n "${token}" ]]; then
    (umask 077 && printf '%s\n' "${token}" >"${NOS_PF_TOKEN_FILE}") || fail "cannot save pf token"
  fi
  info="$("${PFCTL_BIN}" -s info 2>/dev/null)" || fail "pfctl -s info failed"
  grep -q '^Status: Enabled' <<<"${info}" || fail "pf is not enabled"
fi

rules="$("${PFCTL_BIN}" -a "${ANCHOR}" -s rules 2>/dev/null)" || fail "cannot read anchor ${ANCHOR}"
# The file expands to 2 pass rules (udp, tcp) and 3 block rules (v4, two v6 prefixes).
pass_n="$(grep -c '^pass in quick on bridge100' <<<"${rules}")"
block_n="$(grep -c '^block drop in quick on bridge100' <<<"${rules}")"
total_n="$(grep -cE '^(pass|block) ' <<<"${rules}")"
[[ "${pass_n}" -eq 2 && "${block_n}" -eq 3 && "${total_n}" -eq 5 ]] ||
  fail "anchor ${ANCHOR} lists pass=${pass_n} block=${block_n} total=${total_n}, want 2/3/5"

(umask 022 && : >"${NOS_PF_OK_FILE}") || fail "cannot write ${NOS_PF_OK_FILE}"
exit 0
