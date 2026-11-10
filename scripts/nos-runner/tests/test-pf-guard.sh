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
case "$*" in
"-a com.apple/nos-runner-v6 -f "*) [[ -f "${PF_STATE}/v6-fail" ]] && exit 1; exit 0 ;;
"-a com.apple/nos-runner -f "*) [[ -f "${PF_STATE}/load-fail" ]] && exit 1; exit 0 ;;
"-s info")
  if [[ -f "${PF_STATE}/enabled" ]]; then echo "Status: Enabled for 1 days"; else echo "Status: Disabled"; fi ;;
"-E")
  touch "${PF_STATE}/enabled"
  printf 'pf enabled\nToken : 424242\n' >&2 ;;
"-a com.apple/nos-runner -s rules") cat "${PF_STATE}/rules" 2>/dev/null ;;
esac
STUB
chmod +x "${WORK}/bin/pfctl"

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
  PF_STATE="${WORK}/state" PFCTL_BIN="${WORK}/bin/pfctl" NOS_PF_RULES="${WORK}/nos-runner.pf" \
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

exit "${fail}"
