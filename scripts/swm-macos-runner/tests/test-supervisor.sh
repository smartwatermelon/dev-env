#!/usr/bin/env bash
# supervisor.sh under /bin/bash with stub tart, curl, security, openssl, df, rm, kill and build: one slot, JIT on stdin, sweep, alerts.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN NOS_TOKEN NOS_API_STATUS_FILE GITHUB_API_URL TART_HOME NTFY_BASE NTFY_TOPIC JQ_BIN
unset GH_APP_KEY_SERVICE GH_APP_KEY_ACCOUNT TART_BIN CURL_BIN DF_BIN RM_BIN KILL_BIN
for v in $(env | sed -n 's/^\(SWM_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "${v}"; done

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../supervisor.sh"
WORK="${TMPDIR:-/tmp}/swm-sup-test-$$"
BIN="${WORK}/bin"
S="${WORK}/s"
mkdir -p "${BIN}"
trap '/bin/rm -rf "${WORK}"' EXIT

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
# check_is NAME WANT GOT: pass when GOT equals WANT.
check_is() {
  if [[ "$3" == "$2" ]]; then _pass "$1"; else _fail "$1 (got '$3', want '$2')"; fi
}
# count PATTERN FILE: matching lines (0 when the file is missing).
count() {
  if [[ ! -f "$2" ]]; then
    echo 0
    return
  fi
  grep -c -E -e "$1" "$2" || true
}
slot() { sed -n "s/^$1=//p" "${S}/state/slot" 2>/dev/null; }

GB=1048576
IMG=swm-macos-runner-2.338.2-aaaaaaaaaaaa

# tart stub: env STUB_* picks behavior; run stays up until stop removes its up-NAME file.
cat >"${BIN}/tart" <<'STUB'
#!/usr/bin/env bash
S="${STUB_S}"
printf '%s\n' "$*" >>"${S}/tart.argv"
echo "$$" >>"${S}/pids"
hang() {
  local i=0
  while [[ "${i}" -lt 300 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
}
cmd="$1"
shift
case "${cmd}" in
  list)
    echo "tart list" >>"${S}/order.log"
    [[ -z "${STUB_LIST_HANG:-}" ]] || hang
    [[ -z "${STUB_LIST_FAIL:-}" ]] || exit 1
    cat "${S}/vms" ;;
  clone)
    echo "tart clone" >>"${S}/order.log"
    [[ -z "${STUB_CLONE_HANG:-}" ]] || hang
    echo "$2" >>"${S}/vms" ;;
  run)
    for a in "$@"; do name="${a}"; done
    : >"${S}/up-${name}"
    echo "$$" >"${S}/run-pid"
    while [[ -f "${S}/up-${name}" || -n "${STUB_RUN_STUCK:-}" ]]; do sleep 0.1; done ;;
  ip)
    echo "tart ip" >>"${S}/order.log"
    [[ -z "${STUB_NO_IP:-}" ]] || exit 1
    echo 192.168.65.2 ;;
  exec)
    if [[ "$1" == -i ]]; then
      echo "tart exec-i" >>"${S}/order.log"
      cat >>"${S}/exec-stdin"
      echo >>"${S}/exec-stdin"
      cat "${S}/state/slot" >"${S}/slot-during-job"
      : >"${S}/in-job"
      [[ -z "${STUB_JOB_HANG:-}" ]] || hang
      [[ -z "${STUB_JOB_FAIL:-}" ]] || exit 1
    else
      echo "tart exec" >>"${S}/order.log"
      [[ -z "${STUB_NOT_READY:-}" ]] || exit 1
    fi ;;
  stop)
    echo "tart stop" >>"${S}/order.log"
    [[ -z "${STUB_STOP_FAIL:-}" ]] || exit 1
    /bin/rm -f "${S}/up-$1" ;;
  delete)
    echo "tart delete" >>"${S}/order.log"
    grep -vxF -- "$1" "${S}/vms" >"${S}/vms.new"
    cat "${S}/vms.new" >"${S}/vms" ;;
esac
exit 0
STUB

# curl stub: ntfy goes to ntfy.log (and one log for the whole file); GitHub calls route by method and URL.
cat >"${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
S="${STUB_S}"
printf '%s\n' "$*" >>"${S}/curl.argv"
method=GET
data=""
url=""
hdr=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d | --data) data="$2"; shift 2 ;;
    -H) [[ "$2" == @- ]] && hdr=1; shift 2 ;;
    -K) url="$(sed -n 's/^url = "\(.*\)"$/\1/p')"; shift 2 ;;
    -w | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "${hdr}" -eq 1 ]]; then cat >>"${S}/curl.stdin"; fi
case "${url}" in
  http://ntfy.stub/*)
    printf '%s\n' "${data}" >>"${S}/ntfy.log"
    printf '%s\n' "${data}" >>"${STUB_NTFY_ALL}"
    [[ -z "${STUB_NTFY_FAIL:-}" ]] || exit 22
    exit 0 ;;
esac
printf '%s %s %s\n' "${method}" "${url}" "${data}" >>"${S}/requests.log"
printf '%s %s %s\n' "${method}" "${url}" "${data}" >>"${STUB_REQ_ALL}"
echo "curl ${method} ${url##*/}" >>"${S}/order.log"
reply() { printf '%s\n%s' "$1" "$2"; }
case "${method} ${url}" in
  "POST "*/app/installations/*/access_tokens)
    if [[ -n "${STUB_TOKEN_FAIL:-}" ]]; then reply '{"message":"boom"}' 500; else reply '{"token":"ghs_stubtok"}' 201; fi ;;
  "POST "*/actions/runners/generate-jitconfig)
    reply '{"runner":{"id":4242,"name":"x"},"encoded_jit_config":"JITSECRET-4242"}' 201 ;;
  "DELETE "*/actions/runners/*)
    if [[ -n "${STUB_DELETE_FAIL:-}" ]]; then reply '{"message":"boom"}' 500; else reply '' 204; fi ;;
  *) reply '{"message":"unexpected"}' 500 ;;
esac
STUB

cat >"${BIN}/df" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_S}/df.argv"
if [[ -n "${STUB_DF_HANG:-}" ]]; then
  i=0
  while [[ "${i}" -lt 300 ]]; do sleep 0.1; i=$((i + 1)); done
fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk5s1 2000000000 1 ${STUB_DF_AVAIL_KB:-104857600} 10% /Volumes/extra-vieille"
STUB

# rm stub: logs; deletes only files inside this test's state.
cat >"${BIN}/rm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_S}/rm.argv"
for a in "$@"; do
  case "${a}" in "${STUB_S}"/*) [[ -f "${a}" ]] && /bin/rm -f -- "${a}" ;; esac
done
exit 0
STUB

# kill stub: logs; signals only pids the stub tart recorded.
cat >"${BIN}/kill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_S}/kill.argv"
for a in "$@"; do
  case "${a}" in -*) continue ;; esac
  if grep -qx -- "${a}" "${STUB_S}/pids" 2>/dev/null; then kill -9 "${a}" 2>/dev/null; fi
done
exit 0
STUB

cat >"${BIN}/build" <<'STUB'
#!/usr/bin/env bash
echo "build ${SWM_IMAGE:-} ${TART_BIN:-}" >>"${STUB_S}/build.log"
echo "build" >>"${STUB_S}/order.log"
[[ -z "${STUB_BUILD_FAIL:-}" ]] || exit 1
echo "${SWM_IMAGE}" >>"${STUB_S}/vms"
STUB

cat >"${BIN}/security" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_S}/security.argv"
printf '%s' 'STUBKEY' | base64
STUB
cat >"${BIN}/openssl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_S}/openssl.argv"
if [[ "$1" == base64 ]]; then base64 | tr -d '\n'; exit 0; fi
printf 'SIGNATURE'
STUB
chmod +x "${BIN}"/*

export PATH="${BIN}:${PATH}"
export STUB_S="${S}" STUB_NTFY_ALL="${WORK}/ntfy-all.log" STUB_REQ_ALL="${WORK}/requests-all.log"
export TART_BIN="${BIN}/tart" CURL_BIN="${BIN}/curl" DF_BIN="${BIN}/df" RM_BIN="${BIN}/rm" KILL_BIN="${BIN}/kill"
export SECURITY_BIN="${BIN}/security" OPENSSL_BIN="${BIN}/openssl" SWM_BUILD_BIN="${BIN}/build"
export SWM_STATE_DIR="${S}/state" SWM_PF_OK_FILE="${S}/pf.ok" SWM_PF_OK_FILE_V6="${S}/pf6.ok" TART_HOME="${S}/tart"
export SWM_IMAGE="${IMG}" NTFY_TOPIC=stubtopic NTFY_BASE=http://ntfy.stub GITHUB_API_URL=https://api.stub
export SWM_CLONE_LIMIT_S=2 SWM_IP_LIMIT_S=1 SWM_EXEC_LIMIT_S=2 SWM_STOP_LIMIT_S=2 SWM_DELETE_LIMIT_S=2 SWM_LIST_LIMIT_S=2
export SWM_DF_LIMIT_S=1 SWM_READY_LIMIT_S=1 SWM_READY_STEP_S=0.2 SWM_V6_LIMIT_S=1 SWM_V6_STEP_S=0.2
export SWM_JOB_MAX_S=20 SWM_BUILD_LIMIT_S=5 SWM_INTERVAL_S=0.2 SWM_BACKOFF_S=30

# reset: fresh state; both ok files fresh (v6 dated in the future, so newer than any VM start); image present.
reset() {
  /bin/rm -rf "${S}"
  mkdir -p "${S}/tart"
  touch "${S}/pf.ok"
  touch -t 209901010000 "${S}/pf6.ok"
  printf '%s\nother-vm\n' "${IMG}" >"${S}/vms"
}
sup() { /bin/bash "${SCRIPT}" "$@" 2>>"${S}/sup.err"; }
# order: the call sequence, one token per call (tart run is async, so it is not in order.log).
order() { tr '\n' '|' <"${S}/order.log"; }
clones() { count '^clone ' "${S}/tart.argv"; }
jits() { count 'generate-jitconfig' "${S}/requests.log"; }
mints() { count 'access_tokens' "${S}/requests.log"; }
alerts() { count "$1" "${S}/ntfy.log"; }
vm_name() { sed -n 's/^clone [^ ]* \(mimolette-macos-[0-9]*\)$/\1/p' "${S}/tart.argv" | tail -n 1; }

# bg_run [ENV=VAL...]: start `supervisor.sh run` in the background; sets pid.
bg_run() {
  env "$@" /bin/bash "${SCRIPT}" run 2>>"${S}/sup.err" &
  pid=$!
}
# wait_for FILE [LINES]: poll up to 10 s until FILE has at least LINES lines (default 1).
wait_for() {
  local i=0
  while [[ "$(count . "$1")" -lt "${2:-1}" && "${i}" -lt 100 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
}
# end_pid SIG: send SIG, wait up to 10 s, kill -9 after; sets exited (0 = in time) and rc.
end_pid() {
  local i=0
  kill "-$1" "${pid}" 2>/dev/null
  while kill -0 "${pid}" 2>/dev/null && [[ "${i}" -lt 100 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  exited=0
  if kill -0 "${pid}" 2>/dev/null; then
    kill -9 "${pid}" 2>/dev/null
    exited=1
  fi
  rc=0
  wait "${pid}" 2>/dev/null || rc=$?
}

echo "-- happy path order"
reset
sup once
rc=$?
check "happy: exit 0" test "${rc}" -eq 0
vm="$(vm_name)"
check "happy: VM name is mimolette-macos-<epoch>" grep -qE '^mimolette-macos-[0-9]{10,}$' <<<"${vm}"
check_is "happy: call order" \
  "tart list|tart clone|tart ip|tart exec|curl POST access_tokens|curl POST generate-jitconfig|tart exec-i|tart stop|tart delete|curl DELETE 4242|" "$(order)"
check "happy: clone from SWM_IMAGE" grep -qx "clone ${IMG} ${vm}" "${S}/tart.argv"
check "happy: run headless" grep -qx "run --no-graphics ${vm}" "${S}/tart.argv"
check "happy: ip wait" grep -qx "ip --wait 1 ${vm}" "${S}/tart.argv"
check "happy: readiness exec" grep -qx "exec ${vm} /usr/bin/true" "${S}/tart.argv"
check "happy: job exec" grep -qx "exec -i ${vm} /bin/bash /usr/local/libexec/swm-runner/run-job.sh" "${S}/tart.argv"
check "happy: JIT request body" grep -qxF \
  "POST https://api.stub/orgs/smartwatermelon/actions/runners/generate-jitconfig {\"name\":\"${vm}\",\"runner_group_id\":1,\"labels\":[\"mimolette-macos\"],\"work_folder\":\"_work\"}" \
  "${S}/requests.log"
check "happy: token for installation 183107042" grep -q '^POST https://api.stub/app/installations/183107042/access_tokens ' "${S}/requests.log"
check "happy: swm-runner Keychain item" grep -q -- '-s swm-runner-app-key -a smartwatermelon -w' "${S}/security.argv"
check "happy: VM deleted" grep -qx "delete ${vm}" "${S}/tart.argv"
check "happy: runner deleted" grep -q '^DELETE https://api.stub/orgs/smartwatermelon/actions/runners/4242 ' "${S}/requests.log"
check_is "happy: guest got the JIT on stdin" JITSECRET-4242 "$(cat "${S}/exec-stdin")"
check "happy: job=1 during the job" grep -qx 'job=1' "${S}/slot-during-job"
check "happy: id= recorded during the job" grep -qx 'id=4242' "${S}/slot-during-job"
check "happy: name= recorded during the job" grep -qx "name=${vm}" "${S}/slot-during-job"
check_is "happy: slot cleared" "///0/0" "$(slot name)/$(slot id)/$(slot alert)/$(slot job)/$(slot fails)"
check_is "happy: no alert" 0 "$(count . "${S}/ntfy.log")"
check_is "happy: df checked on TART_HOME" 1 "$(count "${S}/tart" "${S}/df.argv")"
check_not "happy: no build when the image is listed" test -e "${S}/build.log"

echo "-- JIT string absent from tart argv log and supervisor log"
check_not "secret: JIT not in tart argv" grep -q JITSECRET "${S}/tart.argv"
check_not "secret: JIT not in supervisor log" grep -q JITSECRET "${S}/sup.err"
check_not "secret: JIT not in any argv log" grep -q JITSECRET "${S}"/*.argv
check_not "secret: JIT not in any state file" grep -rq JITSECRET "${S}/state"
check_not "secret: token not in any argv log" grep -q ghs_stubtok "${S}"/*.argv
check_not "secret: token not in supervisor log" grep -q ghs_stubtok "${S}/sup.err"
check "secret: token went to curl on stdin" grep -qx 'Authorization: Bearer ghs_stubtok' "${S}/curl.stdin"

echo "-- orphan VM and recorded id swept first"
reset
printf 'mimolette-macos-1111111111\n' >>"${S}/vms"
mkdir -p "${S}/state"
printf 'name=mimolette-macos-1111111111\nid=999\nfails=0\nalert=\njob=1\n' >"${S}/state/slot"
sup once
check_is "orphan: sweep runs before the clone" \
  "tart list|tart stop|tart delete|curl POST access_tokens|curl DELETE 999|tart clone|" "$(sed -n 1,6p "${S}/order.log" | tr '\n' '|')"
check "orphan: orphan stopped" grep -qx 'stop mimolette-macos-1111111111' "${S}/tart.argv"
check "orphan: orphan deleted" grep -qx 'delete mimolette-macos-1111111111' "${S}/tart.argv"
check_is "orphan: one token minted" 1 "$(mints)"
check_is "orphan: slot ran after the sweep" 1 "$(jits)"
reset
mkdir -p "${S}/state"
printf 'name=\nid=999\nfails=0\nalert=\njob=0\n' >"${S}/state/slot"
STUB_DELETE_FAIL=1 sup once
rc=$?
check "orphan: failed runner DELETE fails the pass" test "${rc}" -ne 0
check_is "orphan: no clone while id= is still registered" 0 "$(clones)"
check_is "orphan: id= kept for retry" 999 "$(slot id)"
check_is "orphan: fails=1" 1 "$(slot fails)"

echo "-- pf ok stale -> no mint, one pf alert"
reset
touch -t 200001010000 "${S}/pf.ok"
sup once
rc=$?
sup once
check "pf: exit non-zero" test "${rc}" -ne 0
check_is "pf: no mint" 0 "$(mints)"
check_is "pf: no clone" 0 "$(clones)"
check_is "pf: one pf alert over two passes" 1 "$(alerts 'pf LAN block')"
check_is "pf: one alert in all" 1 "$(count . "${S}/ntfy.log")"
check_is "pf: fails=2" 2 "$(slot fails)"
check_is "pf: alert=pf" pf "$(slot alert)"
reset
/bin/rm -f "${S}/pf.ok"
sup once
check_is "pf: missing ok file is a pf alert" 1 "$(alerts 'pf LAN block')"

echo "-- df hang -> disk alert, no mint"
reset
SECONDS=0
STUB_DF_HANG=1 sup once
took="${SECONDS}"
check "df: pass ended within the bound" test "${took}" -lt 8
check_is "df: one disk alert" 1 "$(alerts 'disk check failed')"
check_is "df: no mint" 0 "$(mints)"
check_is "df: no clone" 0 "$(clones)"
reset
STUB_DF_AVAIL_KB=$((59 * GB)) sup once
check_is "df: 59 GB free is a disk alert" 1 "$(alerts 'disk check failed')"
check_is "df: 59 GB free, no clone" 0 "$(clones)"

echo "-- image missing -> build runs; build fails -> build alert"
reset
printf 'other-vm\n' >"${S}/vms"
sup once
rc=$?
check "build: exit 0 after a good build" test "${rc}" -eq 0
check "build: build got SWM_IMAGE and TART_BIN" grep -qx "build ${IMG} ${BIN}/tart" "${S}/build.log"
check "build: build ran before the clone" test "$(grep -n '^build' "${S}/order.log" | cut -d: -f1)" -lt "$(grep -n '^tart clone' "${S}/order.log" | cut -d: -f1)"
check_is "build: slot ran" 1 "$(jits)"
reset
printf 'other-vm\n' >"${S}/vms"
STUB_BUILD_FAIL=1 sup once
check_is "build: failed build alerts" 1 "$(alerts 'image build failed')"
check_is "build: failed build, no clone" 0 "$(clones)"
check_is "build: failed build, no mint" 0 "$(mints)"

echo "-- clone hangs -> tart-hung alert, no JIT request"
reset
STUB_CLONE_HANG=1 sup once
STUB_CLONE_HANG=1 sup once
check_is "clone hang: one tart-hung alert over two passes" 1 "$(alerts 'tart is hung')"
check_is "clone hang: no mint" 0 "$(mints)"
check_is "clone hang: no JIT request" 0 "$(jits)"
check "clone hang: half-cloned VM deleted" grep -qE '^delete mimolette-macos-[0-9]+$' "${S}/tart.argv"
check_is "clone hang: fails=2" 2 "$(slot fails)"

echo "-- no IP within limit -> VM deleted, no JIT request, fails=1"
reset
STUB_NO_IP=1 sup once
vm="$(vm_name)"
check "no ip: VM stopped" grep -qx "stop ${vm}" "${S}/tart.argv"
check "no ip: VM deleted" grep -qx "delete ${vm}" "${S}/tart.argv"
check_is "no ip: no JIT request" 0 "$(jits)"
check_is "no ip: no mint" 0 "$(mints)"
check_is "no ip: fails=1" 1 "$(slot fails)"
check_is "no ip: no alert before 3 fails" 0 "$(count . "${S}/ntfy.log")"
check_is "no ip: name= cleared" "" "$(slot name)"

echo "-- exec not ready in time -> VM deleted, no JIT request"
reset
# 2 s, not 1: the deadline has 1 s granularity, so 1 s can allow a single try.
STUB_NOT_READY=1 SWM_READY_LIMIT_S=2 sup once
vm="$(vm_name)"
check "not ready: exec retried" test "$(count "^exec ${vm} /usr/bin/true$" "${S}/tart.argv")" -ge 2
check "not ready: VM deleted" grep -qx "delete ${vm}" "${S}/tart.argv"
check_is "not ready: no JIT request" 0 "$(jits)"
check_is "not ready: fails=1" 1 "$(slot fails)"

echo "-- v6 ok not fresh in time -> VM deleted, no JIT request"
reset
touch -t 200001010000 "${S}/pf6.ok"
sup once
vm="$(vm_name)"
check "v6: VM deleted" grep -qx "delete ${vm}" "${S}/tart.argv"
check_is "v6: no JIT request" 0 "$(jits)"
check_is "v6: no mint" 0 "$(mints)"
check_is "v6: fails=1" 1 "$(slot fails)"
check_is "v6: one pf alert" 1 "$(alerts 'pf LAN block.*IPv6')"

echo "-- exec fails after mint -> runner DELETEd, VM deleted, fails=1"
reset
STUB_JOB_FAIL=1 sup once
rc=$?
vm="$(vm_name)"
check "job fail: exit non-zero" test "${rc}" -ne 0
check "job fail: runner deleted" grep -q '^DELETE .*/actions/runners/4242 ' "${S}/requests.log"
check "job fail: VM deleted" grep -qx "delete ${vm}" "${S}/tart.argv"
check_is "job fail: fails=1" 1 "$(slot fails)"
check_is "job fail: job=0" 0 "$(slot job)"
check_is "job fail: id= cleared" "" "$(slot id)"

echo "-- 3 fails -> one start alert, backoff"
reset
bg_run STUB_NO_IP=1 SWM_INTERVAL_S=0
wait_for "${S}/ntfy.log"
sleep 1.5
passes="$(count '^list' "${S}/tart.argv")"
check_is "backoff: three passes, then the backoff holds the fourth" 3 "${passes}"
check_is "backoff: one start alert" 1 "$(alerts 'starts failed in a row')"
check_is "backoff: fails=3" 3 "$(slot fails)"
SECONDS=0
end_pid TERM
check "backoff: SIGTERM ends the backoff sleep" test "${exited}${rc}" = 00
check "backoff: exit within 5 s" test "${SECONDS}" -lt 5
STUB_NO_IP=1 sup once
check_is "backoff: fourth fail, still one start alert" 1 "$(alerts 'starts failed in a row')"

echo "-- success after fails -> recovered alert, fails=0"
sup once
check_is "recovered: one recovered alert" 1 "$(alerts 'recovered')"
check_is "recovered: fails=0" 0 "$(slot fails)"
check_is "recovered: alert= cleared" "" "$(slot alert)"
sup once
check_is "recovered: no second recovered alert" 1 "$(alerts 'recovered')"
reset
STUB_NO_IP=1 sup once
sup once
check_is "recovered: one fail without an alert, then success: no alert" 0 "$(count . "${S}/ntfy.log")"
check_is "recovered: fails reset" 0 "$(slot fails)"

echo "-- SIGTERM mid-job -> VM stopped and deleted, runner DELETEd"
reset
bg_run STUB_JOB_HANG=1
wait_for "${S}/in-job"
end_pid TERM
vm="$(vm_name)"
check "sigterm: exited within 10 s, exit 0" test "${exited}${rc}" = 00
check "sigterm: job exec killed through KILL_BIN" grep -qE '^-9 [0-9]+$' "${S}/kill.argv"
check "sigterm: VM stopped" grep -qx "stop ${vm}" "${S}/tart.argv"
check "sigterm: VM deleted" grep -qx "delete ${vm}" "${S}/tart.argv"
check "sigterm: runner deleted" grep -q '^DELETE .*/actions/runners/4242 ' "${S}/requests.log"
check_is "sigterm: no second VM" 1 "$(clones)"
check_is "sigterm: job=0" 0 "$(slot job)"
check_is "sigterm: shutdown is not a failure" 0 "$(slot fails)"
check_is "sigterm: no alert" 0 "$(count . "${S}/ntfy.log")"

echo "-- tart run that ignores stop is killed"
reset
STUB_RUN_STUCK=1 sup once
check "stuck run: run pid killed through KILL_BIN" grep -qx -- "-9 $(cat "${S}/run-pid")" "${S}/kill.argv"
check "stuck run: logged" grep -q 'tart run did not exit' "${S}/sup.err"

echo "-- never deletes a VM outside mimolette-macos-*"
reset
printf '%s\n' swm-macos-runner-2.0.0-bbbbbbbbbbbb mimolette-1-1700000000 mimolette-macos-abc xmimolette-macos-1 \
  mimolette-macos-1-x mimolette-macos-2222222222 >>"${S}/vms"
sup once
STUB_CLONE_HANG=1 sup once
STUB_NO_IP=1 sup once
STUB_JOB_FAIL=1 sup once
bad="$(awk '($1 == "delete" || $1 == "stop") && $2 !~ /^mimolette-macos-[0-9]+$/' "${S}/tart.argv")"
check_is "outside: every stop and delete names mimolette-macos-<digits>" "" "${bad}"
for keep in "${IMG}" other-vm swm-macos-runner-2.0.0-bbbbbbbbbbbb mimolette-1-1700000000 mimolette-macos-abc \
  xmimolette-macos-1 mimolette-macos-1-x; do
  check "outside: ${keep} kept" grep -qxF -- "${keep}" "${S}/vms"
done
check_not "outside: the orphan mimolette-macos-2222222222 deleted" grep -qx mimolette-macos-2222222222 "${S}/vms"

echo "-- test-alert"
reset
printf 'NTFY_TOPIC=stubtopic\n' >"${S}/env"
NTFY_TOPIC='' SWM_ENV_FILE="${S}/env" sup test-alert
rc=$?
check "test-alert: exit 0" test "${rc}" -eq 0
check_is "test-alert: one alert" 1 "$(count . "${S}/ntfy.log")"
check_is "test-alert: touches no VM" 0 "$(count . "${S}/tart.argv")"
NTFY_TOPIC='' SWM_ENV_FILE="${S}/env" STUB_NTFY_FAIL=1 sup test-alert
rc=$?
check "test-alert: exit non-zero when ntfy fails" test "${rc}" -ne 0

echo "-- every alert starts 'macOS runner:'; never writes a variable"
check "alerts: some were sent" test "$(count . "${STUB_NTFY_ALL}")" -gt 5
check_is "alerts: all start 'macOS runner: '" "$(count . "${STUB_NTFY_ALL}")" "$(count '^macOS runner: ' "${STUB_NTFY_ALL}")"
check_is "variables: no /actions/variables request in any case" 0 "$(count '/actions/variables' "${STUB_REQ_ALL}")"

exit "${fail}"
