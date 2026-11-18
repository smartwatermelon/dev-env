#!/bin/bash
# Root guard (LaunchDaemon, every 60 s): load the NOS and swm Tart LAN-block anchors; write each set's ok files only if all is well.
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
SWM_PF_RULES="${SWM_PF_RULES:-${HERE}/swm-tart.pf}"
SWM_PF_RULES_V6="${SWM_PF_RULES_V6:-${HERE}/swm-tart-v6.pf}"
SWM_PF_OK_FILE="${SWM_PF_OK_FILE:-/var/run/swm-tart-pf.ok}"
SWM_PF_OK_FILE_V6="${SWM_PF_OK_FILE_V6:-/var/run/swm-tart-pf-v6.ok}"
SWM_ANCHOR="com.apple/swm-tart"
SWM_ANCHOR_V6="com.apple/swm-tart-v6"

OK_TMP="${NOS_PF_OK_FILE}.tmp"
SWM_OK_TMP="${SWM_PF_OK_FILE}.tmp"
SWM_OK_TMP_V6="${SWM_PF_OK_FILE_V6}.tmp"

# A stale ok file must never outlive a failed check. A good run never removes it: the supervisor would stop busy VMs.
# Each set removes only its own ok files, so a swm failure never stops the NOS runner and the reverse.
fail_nos() {
  "${RM_BIN}" -f "${NOS_PF_OK_FILE}" "${OK_TMP}"
  echo "pf-guard: $1" >&2
  return 1
}
fail_swm() {
  "${RM_BIN}" -f "${SWM_PF_OK_FILE}" "${SWM_OK_TMP}" "${SWM_PF_OK_FILE_V6}" "${SWM_OK_TMP_V6}"
  echo "pf-guard: $1" >&2
  return 1
}
# Only the v6 ok file: the v6 load is best effort, so it must not take the v4 ok file with it.
warn_swm_v6() {
  "${RM_BIN}" -f "${SWM_PF_OK_FILE_V6}" "${SWM_OK_TMP_V6}"
  echo "pf-guard: warning: $1" >&2
}

# Temp file plus mv: an ok file is replaced in one step and is never missing.
write_ok() {
  (umask 022 && : >"$2") || return 1
  "${MV_BIN}" -f "$2" "$1" || return 1
}

# pf must be on for either set. One enable (and one token) serves both.
info="$("${PFCTL_BIN}" -s info 2>/dev/null)" || info=""
if [[ -z "${info}" ]]; then
  fail_nos "pfctl -s info failed" || true
  fail_swm "pfctl -s info failed" || true
  exit 1
fi
if ! grep -q '^Status: Enabled' <<<"${info}"; then
  echo "pf-guard: pf was disabled; enabling it" >&2
  pf_fail() {
    fail_nos "$1" || true
    fail_swm "$1" || true
    exit 1
  }
  # Take one enable reference; keep its token (root only) so a later run does not take another.
  enable_out="$("${PFCTL_BIN}" -E 2>&1)" || pf_fail "pfctl -E failed"
  token="$(sed -n 's/^Token *: *//p' <<<"${enable_out}" | head -n 1)"
  if [[ -n "${token}" ]]; then
    (umask 077 && printf '%s\n' "${token}" >"${NOS_PF_TOKEN_FILE}") || pf_fail "cannot save pf token"
  fi
  info="$("${PFCTL_BIN}" -s info 2>/dev/null)" || pf_fail "pfctl -s info failed"
  grep -q '^Status: Enabled' <<<"${info}" || pf_fail "pf is not enabled"
fi

check_nos() {
  [[ -r "${NOS_PF_RULES}" ]] || { fail_nos "rules file missing: ${NOS_PF_RULES}"; return 1; }
  local before rules main pass_n block_n total_n
  before="$("${PFCTL_BIN}" -a "${ANCHOR}" -s rules 2>/dev/null)" || before=""
  [[ -n "${before}" ]] || echo "pf-guard: anchor ${ANCHOR} was empty before this load" >&2
  "${PFCTL_BIN}" -a "${ANCHOR}" -f "${NOS_PF_RULES}" >/dev/null 2>&1 || { fail_nos "cannot load rules into anchor ${ANCHOR}"; return 1; }

  # IPv6 rules name bridge100, which may not exist yet. A failed load is a warning only; the next run retries.
  "${PFCTL_BIN}" -a "${ANCHOR_V6}" -f "${NOS_PF_RULES_V6}" >/dev/null 2>&1 ||
    echo "pf-guard: warning: v6 rules not loaded into ${ANCHOR_V6} (bridge100 missing?)" >&2

  rules="$("${PFCTL_BIN}" -a "${ANCHOR}" -s rules 2>/dev/null)" || { fail_nos "cannot read anchor ${ANCHOR}"; return 1; }
  # The file expands to 2 pass rules (udp, tcp) and 1 block rule (IPv4).
  pass_n="$(grep -c '^pass in quick inet ' <<<"${rules}")"
  block_n="$(grep -c '^block drop in quick inet ' <<<"${rules}")"
  total_n="$(grep -cE '^(pass|block) ' <<<"${rules}")"
  [[ "${pass_n}" -eq 2 && "${block_n}" -eq 1 && "${total_n}" -eq 3 ]] ||
    { fail_nos "anchor ${ANCHOR} lists pass=${pass_n} block=${block_n} total=${total_n}, want 2/1/3"; return 1; }

  # The anchor rules apply only while the main ruleset still evaluates com.apple/* (another pfctl -f could drop it).
  main="$("${PFCTL_BIN}" -s rules 2>/dev/null)" || { fail_nos "cannot read the main ruleset"; return 1; }
  grep -q '^anchor "com.apple/\*"' <<<"${main}" || { fail_nos "main ruleset has no anchor \"com.apple/*\""; return 1; }

  write_ok "${NOS_PF_OK_FILE}" "${OK_TMP}" || { fail_nos "cannot replace ${NOS_PF_OK_FILE}"; return 1; }
}

check_swm() {
  [[ -r "${SWM_PF_RULES}" ]] || { fail_swm "rules file missing: ${SWM_PF_RULES}"; return 1; }
  local rules rules6 main pass_n block_n total_n
  "${PFCTL_BIN}" -a "${SWM_ANCHOR}" -f "${SWM_PF_RULES}" >/dev/null 2>&1 || { fail_swm "cannot load rules into anchor ${SWM_ANCHOR}"; return 1; }

  rules="$("${PFCTL_BIN}" -a "${SWM_ANCHOR}" -s rules 2>/dev/null)" || { fail_swm "cannot read anchor ${SWM_ANCHOR}"; return 1; }
  # The file expands to 2 pass rules (udp, tcp) and 1 block rule (IPv4).
  pass_n="$(grep -c '^pass in quick inet ' <<<"${rules}")"
  block_n="$(grep -c '^block drop in quick inet ' <<<"${rules}")"
  total_n="$(grep -cE '^(pass|block) ' <<<"${rules}")"
  [[ "${pass_n}" -eq 2 && "${block_n}" -eq 1 && "${total_n}" -eq 3 ]] ||
    { fail_swm "anchor ${SWM_ANCHOR} lists pass=${pass_n} block=${block_n} total=${total_n}, want 2/1/3"; return 1; }

  main="$("${PFCTL_BIN}" -s rules 2>/dev/null)" || { fail_swm "cannot read the main ruleset"; return 1; }
  grep -q '^anchor "com.apple/\*"' <<<"${main}" || { fail_swm "main ruleset has no anchor \"com.apple/*\""; return 1; }

  write_ok "${SWM_PF_OK_FILE}" "${SWM_OK_TMP}" || { fail_swm "cannot replace ${SWM_PF_OK_FILE}"; return 1; }

  # v6 names bridge101. The file loads while the interface is absent, so a failure is a warning that clears only the v6 ok file.
  if ! "${PFCTL_BIN}" -a "${SWM_ANCHOR_V6}" -f "${SWM_PF_RULES_V6}" >/dev/null 2>&1; then
    warn_swm_v6 "v6 rules not loaded into ${SWM_ANCHOR_V6}"
    return 0
  fi
  rules6="$("${PFCTL_BIN}" -a "${SWM_ANCHOR_V6}" -s rules 2>/dev/null)" || rules6=""
  # The destination list expands to 2 block rules and no pass rule.
  pass_n="$(grep -c '^pass ' <<<"${rules6}")"
  block_n="$(grep -c '^block drop in quick on bridge101 inet6 ' <<<"${rules6}")"
  total_n="$(grep -cE '^(pass|block) ' <<<"${rules6}")"
  if [[ "${pass_n}" -ne 0 || "${block_n}" -ne 2 || "${total_n}" -ne 2 ]]; then
    warn_swm_v6 "anchor ${SWM_ANCHOR_V6} lists pass=${pass_n} block=${block_n} total=${total_n}, want 0/2/2"
    return 0
  fi
  write_ok "${SWM_PF_OK_FILE_V6}" "${SWM_OK_TMP_V6}" || warn_swm_v6 "cannot replace ${SWM_PF_OK_FILE_V6}"
  return 0
}

# Run both sets even if the first fails, so one set's fault never hides the other's ok files.
rc=0
check_nos || rc=1
check_swm || rc=1
exit "${rc}"
