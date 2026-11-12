#!/bin/bash
# Root guard (LaunchDaemon, every 300 s): load the LAN-block anchor, confirm pf is on, write the ok file only if all is well.
set -uo pipefail
unset CDPATH

PFCTL_BIN="${PFCTL_BIN:-/sbin/pfctl}"
RM_BIN="${RM_BIN:-rm}"
MV_BIN="${MV_BIN:-mv}"
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOS_PF_RULES="${NOS_PF_RULES:-${HERE}/nos-runner.pf}"
NOS_PF_OK_FILE="${NOS_PF_OK_FILE:-/var/run/nos-runner-pf.ok}"
NOS_PF_TOKEN_FILE="${NOS_PF_TOKEN_FILE:-/var/run/nos-runner-pf.token}"
NOS_PF_RULES_V6="${NOS_PF_RULES_V6:-${HERE}/nos-runner-v6.pf}"
ANCHOR="com.apple/nos-runner"
ANCHOR_V6="com.apple/nos-runner-v6"

OK_TMP="${NOS_PF_OK_FILE}.tmp"

# A stale ok file must never outlive a failed check. A good run never removes it: the supervisor would stop busy VMs.
fail() {
  "${RM_BIN}" -f "${NOS_PF_OK_FILE}" "${OK_TMP}"
  echo "pf-guard: $1" >&2
  exit 1
}

[[ -r "${NOS_PF_RULES}" ]] || fail "rules file missing: ${NOS_PF_RULES}"
before="$("${PFCTL_BIN}" -a "${ANCHOR}" -s rules 2>/dev/null)" || before=""
[[ -n "${before}" ]] || echo "pf-guard: anchor ${ANCHOR} was empty before this load" >&2
"${PFCTL_BIN}" -a "${ANCHOR}" -f "${NOS_PF_RULES}" >/dev/null 2>&1 || fail "cannot load rules into anchor ${ANCHOR}"

# IPv6 rules name bridge100, which may not exist yet. A failed load is a warning only; the next run retries.
"${PFCTL_BIN}" -a "${ANCHOR_V6}" -f "${NOS_PF_RULES_V6}" >/dev/null 2>&1 ||
  echo "pf-guard: warning: v6 rules not loaded into ${ANCHOR_V6} (bridge100 missing?)" >&2

info="$("${PFCTL_BIN}" -s info 2>/dev/null)" || fail "pfctl -s info failed"
if ! grep -q '^Status: Enabled' <<<"${info}"; then
  echo "pf-guard: pf was disabled; enabling it" >&2
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
# The file expands to 2 pass rules (udp, tcp) and 1 block rule (IPv4).
pass_n="$(grep -c '^pass in quick inet ' <<<"${rules}")"
block_n="$(grep -c '^block drop in quick inet ' <<<"${rules}")"
total_n="$(grep -cE '^(pass|block) ' <<<"${rules}")"
[[ "${pass_n}" -eq 2 && "${block_n}" -eq 1 && "${total_n}" -eq 3 ]] ||
  fail "anchor ${ANCHOR} lists pass=${pass_n} block=${block_n} total=${total_n}, want 2/1/3"

# The anchor rules apply only while the main ruleset still evaluates com.apple/* (another pfctl -f could drop it).
main="$("${PFCTL_BIN}" -s rules 2>/dev/null)" || fail "cannot read the main ruleset"
grep -q '^anchor "com.apple/\*"' <<<"${main}" || fail "main ruleset has no anchor \"com.apple/*\""

# Temp file plus mv: the ok file is replaced in one step and is never missing.
(umask 022 && : >"${OK_TMP}") || fail "cannot write ${OK_TMP}"
"${MV_BIN}" -f "${OK_TMP}" "${NOS_PF_OK_FILE}" || fail "cannot replace ${NOS_PF_OK_FILE}"
exit 0
