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
pass in quick on bridge100 inet proto udp from 192.168.64.0/24 to 192.168.64.1 port = 53
pass in quick on bridge100 inet proto tcp from 192.168.64.0/24 to 192.168.64.1 port = 53
block drop in quick on bridge100 inet from 192.168.64.0/24 to <nos_private>
block drop in quick on bridge100 inet6 from any to fc00::/7
block drop in quick on bridge100 inet6 from any to fe80::/10
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
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
enable_count() { grep -c '^-E$' "${WORK}/state/calls"; }

echo "-- pf_guard_writes_ok_only_when_rules_listed"
reset
good_rules
rc=0
run || rc=$?
check "exit 0 with all 5 rules listed" test "${rc}" -eq 0
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
check "exit 1 with 4 rules listed" test "${rc}" -eq 1
check_not "no ok file with 4 rules" test -f "${WORK}/ok"

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
