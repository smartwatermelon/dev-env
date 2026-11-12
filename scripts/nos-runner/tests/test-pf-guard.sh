#!/usr/bin/env bash
# pf-guard.sh with a stub pfctl: when the ok file is written, and when a stale one is removed.
set -uo pipefail
unset CDPATH
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}
check_not() {
  local name="$1"
  shift
  if "$@"; then _fail "${name}"; else _pass "${name}"; fi
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../net/pf-guard.sh"
WORK="${TMPDIR:-/tmp}/nos-pfguard-test-$$"
mkdir -p "${WORK}/bin"
trap 'rm -rf "${WORK:?}"' EXIT

# pfctl stub: files in $PF_STATE choose what each query prints; every call is logged.
cat >"${WORK}/bin/pfctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PF_STATE}/calls"
# Record whether the ok file exists at each call, to prove a good run never removes it.
if [[ -e "${NOS_PF_OK_FILE}" ]]; then echo present >>"${PF_STATE}/okseen"; else echo absent >>"${PF_STATE}/okseen"; fi
case "$*" in
"-a com.apple/nos-runner-v6 -f "*) [[ -f "${PF_STATE}/v6-fail" ]] && exit 1; exit 0 ;;
"-a com.apple/nos-runner -f "*) [[ -f "${PF_STATE}/load-fail" ]] && exit 1; exit 0 ;;
"-s info")
  if [[ -f "${PF_STATE}/enabled" ]]; then echo "Status: Enabled for 1 days"; else echo "Status: Disabled"; fi ;;
"-E")
  [[ -f "${PF_STATE}/no-enable" ]] || touch "${PF_STATE}/enabled"
  printf 'pf enabled\nToken : 424242\n' >&2 ;;
"-a com.apple/nos-runner -s rules") cat "${PF_STATE}/rules" 2>/dev/null ;;
"-s rules")
  if [[ -f "${PF_STATE}/main" ]]; then cat "${PF_STATE}/main"; else
    printf 'scrub-anchor "com.apple/*" all fragment reassemble\nanchor "com.apple/*" all\n'
  fi ;;
esac
STUB
# mv stub: logs, then delegates (all paths are under ${WORK}).
cat >"${WORK}/bin/mv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PF_STATE}/mv"
exec /bin/mv "$@"
STUB
chmod +x "${WORK}/bin/pfctl" "${WORK}/bin/mv"

good_rules() {
  cat >"${WORK}/state/rules" <<'R'
pass in quick inet proto udp from 192.168.64.0/24 to 192.168.64.1 port = 53 keep state
pass in quick inet proto tcp from 192.168.64.0/24 to 192.168.64.1 port = 53 flags S/SA keep state
block drop in quick inet from 192.168.64.0/24 to <nos_private>
R
}
reset() {
  rm -rf "${WORK:?}/state" "${WORK:?}/ok" "${WORK:?}/token"
  mkdir -p "${WORK}/state"
  printf 'rule\n' >"${WORK}/nos-runner.pf"
}
run() {
  PF_STATE="${WORK}/state" PFCTL_BIN="${WORK}/bin/pfctl" MV_BIN="${WORK}/bin/mv" NOS_PF_RULES="${WORK}/nos-runner.pf" \
    NOS_PF_OK_FILE="${WORK}/ok" NOS_PF_TOKEN_FILE="${WORK}/token" bash "${SCRIPT}" >"${WORK}/out" 2>"${WORK}/err"
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
enable_count() { grep -c '^-E$' "${WORK}/state/calls"; }

echo "-- pf_guard_writes_ok_only_when_rules_listed"
reset
good_rules
rc=0
run || rc=$?
check "exit 0 with all 3 rules listed" test "${rc}" -eq 0
check "ok file written" test -f "${WORK}/ok"
mode="$(mode_of "${WORK}/ok")"
check "ok file mode 0644" test "${mode}" = 644
n="$(enable_count)"
check "pf was disabled: -E run once" test "${n}" -eq 1
tok="$(cat "${WORK}/token")"
tmode="$(mode_of "${WORK}/token")"
check "pf token value saved" test "${tok}" = 424242
check "pf token file mode 0600" test "${tmode}" = 600
run || true
n="$(enable_count)"
check "second run with pf enabled does not run -E again" test "${n}" -eq 1

reset
good_rules
touch "${WORK}/state/enabled"
sed -i.bak '$d' "${WORK}/state/rules"
rc=0
run || rc=$?
check "exit 1 with 2 rules listed" test "${rc}" -eq 1
check_not "no ok file with 2 rules" test -f "${WORK}/ok"

reset
touch "${WORK}/state/enabled"
rc=0
run || rc=$?
check "exit 1 with no rules listed" test "${rc}" -eq 1
check_not "no ok file with no rules listed" test -f "${WORK}/ok"

reset
good_rules
touch "${WORK}/state/load-fail"
run || true
check_not "no ok file when the anchor load fails" test -f "${WORK}/ok"

echo "-- pf_guard_v6_load_is_best_effort"
reset
good_rules
run || true
check "v6 rules loaded into their own anchor" grep -q '^-a com.apple/nos-runner-v6 -f ' "${WORK}/state/calls"
touch "${WORK}/state/v6-fail"
rc=0
run || rc=$?
check "exit 0 when only the v6 load fails" test "${rc}" -eq 0
check "ok file written when only the v6 load fails" test -f "${WORK}/ok"
check "stderr warns about v6" grep -q 'v6' "${WORK}/err"

echo "-- shipped rules do not name an interface"
check_not "nos-runner.pf has no 'on bridge100'" grep -q 'on bridge100' "${HERE}/../net/nos-runner.pf"
file_rules="$(grep -cE '^(pass|block) ' "${HERE}/../net/nos-runner.pf")"
check "nos-runner.pf has 1 pass line + 1 block line" test "${file_rules}" -eq 2
check "v6 file binds bridge100" grep -q 'on bridge100 inet6' "${HERE}/../net/nos-runner-v6.pf"

echo "-- pf_guard_removes_ok_file_when_rules_missing"
reset
good_rules
touch "${WORK}/state/enabled"
run || true
check "precondition: ok file exists after a good run" test -f "${WORK}/ok"
: >"${WORK}/state/rules"
rc=0
run || rc=$?
check "exit 1 after anchor is emptied" test "${rc}" -eq 1
check_not "stale ok file removed" test -f "${WORK}/ok"
good_rules
rm -f "${WORK:?}/nos-runner.pf"
touch "${WORK}/ok"
run || true
check_not "stale ok file removed when the rules file is missing" test -f "${WORK}/ok"

echo "-- pf_guard_never_removes_ok_file_on_a_good_run"
reset
good_rules
touch "${WORK}/state/enabled" "${WORK}/ok"
rc=0
run || rc=$?
check "good run exits 0" test "${rc}" -eq 0
seen="$(grep -c . "${WORK}/state/okseen" || true)"
check "ok file presence recorded at each pfctl call" test "${seen}" -gt 0
check_not "ok file never absent during a good run" grep -qx absent "${WORK}/state/okseen"
check "ok file still there after the run" test -f "${WORK}/ok"
check "ok file written by mv (atomic)" grep -qF -- "${WORK}/ok" "${WORK}/state/mv"
check_not "no temp file left" test -e "${WORK}/ok.tmp"
touch -t 202001010000 "${WORK}/ok"
run || true
fresh="$(find "${WORK}/ok" -mmin -10)"
check "good run refreshes the ok file mtime" test -n "${fresh}"
: >"${WORK}/state/rules"
rc=0
run || rc=$?
check "failed run exits 1" test "${rc}" -eq 1
check_not "failed run removes the ok file" test -f "${WORK}/ok"

echo "-- pf_guard_requires_main_ruleset_anchor"
reset
good_rules
touch "${WORK}/state/enabled" "${WORK}/ok"
printf 'scrub-anchor "com.apple/*" all fragment reassemble\npass all\n' >"${WORK}/state/main"
rc=0
run || rc=$?
check "exit 1 when the main ruleset has only scrub-anchor" test "${rc}" -eq 1
check_not "no ok file without anchor com.apple/*" test -f "${WORK}/ok"
check "says the main ruleset lacks the anchor" grep -q 'main ruleset' "${WORK}/err"
: >"${WORK}/state/main"
touch "${WORK}/ok"
run || true
check_not "no ok file with an empty main ruleset" test -f "${WORK}/ok"

echo "-- pf_guard_requires_pf_enabled"
reset
good_rules
touch "${WORK}/ok"
# pfctl -E that does not enable pf: Status stays Disabled.
touch "${WORK}/state/no-enable"
rc=0
run || rc=$?
check "exit 1 when pf stays disabled" test "${rc}" -eq 1
check_not "no ok file while pf is disabled" test -f "${WORK}/ok"

exit "${fail}"
