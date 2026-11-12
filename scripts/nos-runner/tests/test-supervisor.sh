#!/usr/bin/env bash
# supervisor.sh under /bin/bash with stub container, curl, df, rm, security, openssl, launchctl: slots, JIT handoff, failover.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN NOS_TOKEN GITHUB_API_URL NOS_IMAGE NOS_API_STATUS_FILE
unset NOS_ORG NOS_SLOTS NOS_CPUS NOS_MEMORY NOS_LABEL NOS_MIN_FREE_GB NTFY_BASE JQ_BIN NOS_CONTAINER_TIMEOUT

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../supervisor.sh"
WORK="${TMPDIR:-/tmp}/nos-runner-sup-test-$$"
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
# check_eq NAME WANT CMD...: pass when CMD prints WANT.
check_eq() {
  local name="$1" want="$2" got
  shift 2
  got="$("$@")"
  if [[ "${got}" == "${want}" ]]; then _pass "${name}"; else _fail "${name} (got '${got}', want '${want}')"; fi
}
# count PATTERN FILE: matching lines (0 when the file is missing).
count() {
  if [[ ! -f "$2" ]]; then
    echo 0
    return
  fi
  grep -c -E -e "$1" "$2" || true
}

GB=1048576

# container stub (container 1.7.1 formats): ls lists a buildkit VM plus $S/running; run records the env file; stop drops the name.
cat >"${BIN}/container" <<STUB
#!/usr/bin/env bash
S="${S}"
echo "\$*" >>"\${S}/container.argv"
echo "container \$*" >>"\${S}/order.log"
case "\$1" in
  ls)
    [[ -z "\${STUB_LS_FAIL:-}" ]] || exit 1
    [[ -z "\${STUB_LS_HANG:-}" ]] || exec sleep 30
    [[ -z "\${STUB_LS_SLEEP:-}" ]] || sleep "\${STUB_LS_SLEEP}"
    [[ -z "\${STUB_LS_EMPTY:-}" ]] || exit 0
    echo "\${STUB_LS_HEADER:-ID IMAGE OS ARCH STATE IP CPUS MEMORY STARTED}"
    echo "buildkit moby/buildkit:latest linux arm64 running \${STUB_BUILDKIT_IP:-192.168.64.3/24} 2 2048MB 2026-11-10T10:00:00Z"
    if [[ -f "\${S}/running" ]]; then
      while read -r n; do
        [[ -n "\${n}" ]] && echo "\${n} nos-runner:2.338.2 linux arm64 running \${STUB_VM_IP-192.168.64.2/24} 4 4096MB 2026-11-10T10:00:00Z"
      done <"\${S}/running"
    fi
    ;;
  image)
    [[ "\$2" == inspect && -z "\${STUB_IMAGE_MISSING:-}" ]] || exit 1
    echo '[{}]'
    ;;
  run)
    name=""
    envf=""
    prev=""
    for a in "\$@"; do
      if [[ "\${prev}" == --name ]]; then name="\${a}"; fi
      if [[ "\${prev}" == --env-file ]]; then envf="\${a}"; fi
      prev="\${a}"
    done
    echo "\${envf}" >>"\${S}/envfile.paths"
    if [[ -f "\${envf}" ]]; then
      ls -l "\${envf}" | cut -c1-10 >>"\${S}/envfile.mode"
      cat "\${envf}" >>"\${S}/envfile.content"
    else
      echo missing >>"\${S}/envfile.mode"
    fi
    [[ -z "\${STUB_RUN_FAIL:-}" ]] || exit 1
    [[ -n "\${STUB_RUN_EXITS:-}" ]] || echo "\${name}" >>"\${S}/running"
    echo "\${name}"
    ;;
  stop)
    shift
    [[ -z "\${STUB_STOP_FAIL:-}" ]] || exit 1
    for n in "\$@"; do
      grep -vxF -e "\${n}" "\${S}/running" >"\${S}/running.tmp" || true
      cat "\${S}/running.tmp" >"\${S}/running"
    done
    ;;
esac
STUB

# curl stub: routes by method and URL; the org variable lives in $S/var.value (no file = 404).
cat >"${BIN}/curl" <<STUB
#!/usr/bin/env bash
S="${S}"
echo "\$*" >>"\${S}/curl.argv"
method=""
data=""
url=""
hdr_stdin=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -X) method="\$2"; shift 2 ;;
    -d | --data) data="\$2"; shift 2 ;;
    -H) [[ "\$2" == @- ]] && hdr_stdin=1; shift 2 ;;
    -K) url="\$(sed -n 's/^url = "\(.*\)"\$/\1/p')"; shift 2 ;;
    -w | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
if [[ "\${hdr_stdin}" -eq 1 ]]; then cat >>"\${S}/curl.stdin"; fi
case "\${url}" in
  https://ntfy.sh/*)
    echo "\${url} \${data}" >>"\${S}/ntfy.log"
    exit 0
    ;;
esac
echo "\${method} \${url} \${data}" >>"\${S}/requests.log"
echo "curl \${method} \${url}" >>"\${S}/order.log"
echo "\${method} \${url} \${data}" >>"${WORK}/all-requests.log"
reply() { printf '%s\n%s' "\$1" "\$2"; }
setvar() { printf '%s' "\${data}" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' >"\${S}/var.value"; }
case "\${method} \${url}" in
  "POST "*/app/installations/*/access_tokens)
    if [[ -n "\${STUB_TOKEN_FAIL:-}" ]]; then reply '{"message":"boom"}' 500; else reply '{"token":"ghs_stubtok"}' 201; fi
    ;;
  "GET "*/actions/runners/*)
    id="\${url##*/}"
    if grep -qx "\${id}" "\${S}/busy" 2>/dev/null; then b=true; else b=false; fi
    reply "{\"id\":\${id},\"busy\":\${b}}" 200
    ;;
  "POST "*/actions/runners/generate-jitconfig)
    n=\$((\$(cat "\${S}/jit.n" 2>/dev/null || echo 0) + 1))
    echo "\${n}" >"\${S}/jit.n"
    id=\$((100 + n))
    reply "{\"runner\":{\"id\":\${id},\"name\":\"x\"},\"encoded_jit_config\":\"JITSECRET-\${id}\"}" 201
    ;;
  "GET "*/actions/variables/NOS_RUNNER)
    if [[ -f "\${S}/var.value" ]]; then
      reply "{\"name\":\"NOS_RUNNER\",\"value\":\"\$(cat "\${S}/var.value")\"}" 200
    else
      reply '{"message":"Not Found"}' 404
    fi
    ;;
  "PATCH "*/actions/variables/NOS_RUNNER)
    if [[ -n "\${STUB_PATCH_FAIL:-}" ]]; then reply '{"message":"boom"}' 500; exit 0; fi
    if [[ -f "\${S}/var.value" ]]; then setvar; reply '' 204; else reply '{"message":"Not Found"}' 404; fi
    ;;
  "POST "*/actions/variables) setvar; reply '' 201 ;;
  "DELETE "*/actions/runners/*)
    if [[ -n "\${STUB_DELETE_FAIL:-}" ]]; then
      reply '{"message":"boom"}' 500
    elif grep -qx "\${url##*/}" "\${S}/gone" 2>/dev/null; then
      reply '{"message":"Not Found"}' 404
    else
      reply '' 204
    fi
    ;;
  *) reply '{"message":"unexpected"}' 500 ;;
esac
STUB

# df stub: POSIX output; available KB from STUB_DF_AVAIL_KB (default 100 GB).
cat >"${BIN}/df" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/df.argv"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3s1 500000000 1 \${STUB_DF_AVAIL_KB:-$((100 * GB))} 50% /"
STUB

# rm stub: logs, and deletes only paths inside this test's state dir.
cat >"${BIN}/rm" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/rm.argv"
for a in "\$@"; do
  case "\${a}" in
    "${S}"/*) [[ -f "\${a}" ]] && /bin/rm -f -- "\${a}" ;;
  esac
done
exit 0
STUB

cat >"${BIN}/security" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/security.argv"
printf '%s' 'STUBKEY' | base64
STUB
cat >"${BIN}/openssl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/openssl.argv"
if [[ "\$1" == base64 ]]; then base64 | tr -d '\n'; exit 0; fi
printf 'SIGNATURE'
STUB
cat >"${BIN}/launchctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${S}/launchctl.argv"
STUB
chmod +x "${BIN}"/*

export PATH="${BIN}:${PATH}"
export CONTAINER_BIN="${BIN}/container" CURL_BIN="${BIN}/curl" DF_BIN="${BIN}/df" RM_BIN="${BIN}/rm"
export SECURITY_BIN="${BIN}/security" OPENSSL_BIN="${BIN}/openssl" LAUNCHCTL_BIN="${BIN}/launchctl"
export NOS_STATE_DIR="${S}/state" NOS_PF_OK_FILE="${S}/pf.ok" NOS_DISK_PATH="${S}" NTFY_TOPIC=stubtopic
export NOS_INTERVAL=60

# reset [VAR_VALUE]: fresh state; pf ok file fresh; the org variable set (default mimolette).
reset() {
  /bin/rm -rf "${S}"
  mkdir -p "${S}"
  touch "${S}/pf.ok"
  printf '%s' "${1-mimolette}" >"${S}/var.value"
}
sup() { /bin/bash "${SCRIPT}" "$@" 2>>"${S}/sup.err"; }
runs() { count '^run ' "${S}/container.argv"; }

echo "-- starts_two_slots_when_healthy"
reset
sup once
check_eq "starts_two_slots_when_healthy: two container runs" 2 runs
check "starts_two_slots_when_healthy: slot 1 name" grep -qE '^run .*--name mimolette-1-[0-9]+ ' "${S}/container.argv"
check "starts_two_slots_when_healthy: slot 2 name" grep -qE '^run .*--name mimolette-2-[0-9]+ ' "${S}/container.argv"
check "starts_two_slots_when_healthy: flags and image" \
  grep -qE '^run -d --rm --name mimolette-1-[0-9]+ -c 4 -m 4g --env-file [^ ]+ nos-runner:2\.338\.2-[0-9a-f]{12}$' "${S}/container.argv"
check "starts_two_slots_when_healthy: jit body" grep -qE \
  '^POST .*/orgs/nightowlstudiollc/actions/runners/generate-jitconfig \{"name":"mimolette-1-[0-9]+","runner_group_id":1,"labels":\["mimolette"\],"work_folder":"_work"\}$' \
  "${S}/requests.log"
check_eq "starts_two_slots_when_healthy: no variable write" 0 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"
check_eq "starts_two_slots_when_healthy: no alert" 0 count . "${S}/ntfy.log"
sup once
check_eq "starts_two_slots_when_healthy: second pass starts nothing" 2 runs

echo "-- restarts_slot_after_container_exits"
reset
sup once
slot1="$(grep -o 'mimolette-1-[0-9]*' "${S}/running")"
grep -vxF -e "${slot1}" "${S}/running" >"${S}/running.tmp"
cat "${S}/running.tmp" >"${S}/running"
sup once
check_eq "restarts_slot_after_container_exits: one more run" 3 runs
last_run="$(grep '^run ' "${S}/container.argv" | tail -n 1)"
check "restarts_slot_after_container_exits: the new run is slot 1" grep -qE -e '--name mimolette-1-' <<<"${last_run}"
check "restarts_slot_after_container_exits: old runner deleted" grep -qE '^DELETE .*/orgs/nightowlstudiollc/actions/runners/101 ' "${S}/requests.log"
check_eq "restarts_slot_after_container_exits: two running" 2 count . "${S}/running"

echo "-- container_run_has_no_mount_or_volume_flags"
check "container_run_has_no_mount_or_volume_flags: runs were made" grep -q '^run ' "${S}/container.argv"
check_not "container_run_has_no_mount_or_volume_flags" \
  grep -qE -e '^run .*( )(-v|--volume|--mount)( |=|$)' "${S}/container.argv"

echo "-- jit_not_in_argv"
check "jit_not_in_argv: env file held NOS_JIT" grep -qx 'NOS_JIT=JITSECRET-101' "${S}/envfile.content"
check_not "jit_not_in_argv: no argv carries the JIT" grep -q JITSECRET "${S}"/*.argv
check_eq "jit_not_in_argv: env file was mode 600" -rw------- sort -u "${S}/envfile.mode"
gone=0
while read -r f; do
  [[ -e "${f}" ]] && gone=1
  grep -q -e "${f}" "${S}/rm.argv" || gone=1
done <"${S}/envfile.paths"
check "jit_not_in_argv: env files removed with RM_BIN" test "${gone}" -eq 0
check_not "jit_not_in_argv: token not in argv" grep -q ghs_stubtok "${S}"/*.argv

echo "-- selfcheck_failure_stops_slots_and_deregisters"
reset
sup once
echo 102 >"${S}/busy"
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "selfcheck_failure_stops_slots_and_deregisters: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check "selfcheck_failure_stops_slots_and_deregisters: PATCH body" grep -qxF \
  'PATCH https://api.github.com/orgs/nightowlstudiollc/actions/variables/NOS_RUNNER {"name":"NOS_RUNNER","value":"ubuntu-latest","visibility":"private"}' \
  "${S}/requests.log"
check_eq "selfcheck_failure_stops_slots_and_deregisters: one alert" 1 count . "${S}/ntfy.log"
check "selfcheck_failure_stops_slots_and_deregisters: alert URL" grep -q '^https://ntfy.sh/stubtopic ' "${S}/ntfy.log"
check "selfcheck_failure_stops_slots_and_deregisters: busy checked" grep -qE '^GET .*/orgs/nightowlstudiollc/actions/runners/101 ' "${S}/requests.log"
check "selfcheck_failure_stops_slots_and_deregisters: idle slot 1 stopped" grep -qE '^stop mimolette-1-[0-9]+$' "${S}/container.argv"
check_not "selfcheck_failure_stops_slots_and_deregisters: busy slot 2 left" grep -qE '^stop mimolette-2-' "${S}/container.argv"
check "selfcheck_failure_stops_slots_and_deregisters: runner 101 deleted" grep -qE '^DELETE .*/orgs/nightowlstudiollc/actions/runners/101 ' "${S}/requests.log"
check_not "selfcheck_failure_stops_slots_and_deregisters: runner 102 kept" grep -qE '^DELETE .*/actions/runners/102 ' "${S}/requests.log"
check_eq "selfcheck_failure_stops_slots_and_deregisters: no new slot" 2 runs
patch_at="$(grep -n '^curl PATCH .*/variables/NOS_RUNNER' "${S}/order.log" | head -n 1 | cut -d: -f1)"
stop_at="$(grep -n '^container stop mimolette-1-' "${S}/order.log" | head -n 1 | cut -d: -f1)"
check "selfcheck_failure_stops_slots_and_deregisters: variable set before idle stop" test "${patch_at:-999}" -lt "${stop_at:-0}"
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "selfcheck_failure_stops_slots_and_deregisters: still one alert" 1 count . "${S}/ntfy.log"
check_eq "selfcheck_failure_stops_slots_and_deregisters: one variable write" \
  1 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"
STUB_DF_AVAIL_KB=$((20 * GB)) sup once
check_eq "selfcheck_failure_stops_slots_and_deregisters: 20 GB restarts the stopped slot only" 3 runs

echo "-- no_alert_when_var_already_ubuntu"
reset ubuntu-latest
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "no_alert_when_var_already_ubuntu: no alert" 0 count . "${S}/ntfy.log"
check "no_alert_when_var_already_ubuntu: GET was made" grep -q '^GET .*/actions/variables/NOS_RUNNER' "${S}/requests.log"
check_eq "no_alert_when_var_already_ubuntu: no write" 0 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"

echo "-- hold_value_never_overwritten"
reset ubuntu-24.04
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "hold_value_never_overwritten: self-check keeps the hold" ubuntu-24.04 cat "${S}/var.value"
check_eq "hold_value_never_overwritten: self-check writes nothing" 0 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"
check_eq "hold_value_never_overwritten: self-check sends no alert" 0 count . "${S}/ntfy.log"
check "hold_value_never_overwritten: logged" grep -q 'held at ubuntu-24.04' "${S}/sup.err"
reset ubuntu-24.04
env /bin/bash "${SCRIPT}" run 2>>"${S}/sup.err" &
pid=$!
n=0
for _ in $(seq 100); do
  n="$(runs)"
  [[ "${n}" -lt 2 ]] || break
  sleep 0.1
done
kill -TERM "${pid}" 2>/dev/null
wait "${pid}" 2>/dev/null || true
check_eq "hold_value_never_overwritten: slots ran before SIGTERM" 2 runs
check_eq "hold_value_never_overwritten: SIGTERM keeps the hold" ubuntu-24.04 cat "${S}/var.value"
check_eq "hold_value_never_overwritten: SIGTERM writes nothing" 0 count '^(PATCH|POST) .*/actions/variables' "${S}/requests.log"
check_eq "hold_value_never_overwritten: SIGTERM sends no alert" 0 count . "${S}/ntfy.log"
check_eq "hold_value_never_overwritten: SIGTERM still stops idle slots" 2 count '^stop mimolette-' "${S}/container.argv"
reset ''
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "hold_value_never_overwritten: an empty value is written" ubuntu-latest cat "${S}/var.value"

echo "-- variable_missing_uses_post"
reset
/bin/rm -f "${S}/var.value"
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check "variable_missing_uses_post: PATCH tried" grep -q '^PATCH .*/actions/variables/NOS_RUNNER ' "${S}/requests.log"
check "variable_missing_uses_post: POST made" grep -qxF \
  'POST https://api.github.com/orgs/nightowlstudiollc/actions/variables {"name":"NOS_RUNNER","value":"ubuntu-latest","visibility":"private"}' \
  "${S}/requests.log"
check_eq "variable_missing_uses_post: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check_eq "variable_missing_uses_post: one alert" 1 count . "${S}/ntfy.log"

echo "-- no_ntfy_topic_warns"
reset
NTFY_TOPIC='' STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "no_ntfy_topic_warns: variable still written" ubuntu-latest cat "${S}/var.value"
check_eq "no_ntfy_topic_warns: no ntfy call" 0 count . "${S}/ntfy.log"
check "no_ntfy_topic_warns: stderr warning" grep -q 'NTFY_TOPIC' "${S}/sup.err"

# bg_run [ENV=VAL...]: start `supervisor.sh run` in the background; sets pid.
bg_run() {
  env "$@" /bin/bash "${SCRIPT}" run 2>>"${S}/sup.err" &
  pid=$!
}
# wait_runs N: poll up to 10 s until N container runs are logged.
wait_runs() {
  local i=0 n=0
  while [[ "${n}" -lt "$1" && "${i}" -lt 100 ]]; do
    sleep 0.1
    ((i += 1))
    n="$(runs)"
  done
}
# wait_ls: poll up to 10 s until the supervisor has called container ls.
wait_ls() {
  local i=0
  while ! grep -q '^ls' "${S}/container.argv" 2>/dev/null && [[ "${i}" -lt 100 ]]; do
    sleep 0.1
    ((i += 1))
  done
}
# end_pid [SIG]: send SIG (default TERM), wait up to 15 s, kill -9 after; sets exited (0 = in time) and rc.
end_pid() {
  local i=0
  if [[ -n "${1:-}" ]]; then kill "-$1" "${pid}" 2>/dev/null; fi
  while kill -0 "${pid}" 2>/dev/null && [[ "${i}" -lt 150 ]]; do
    sleep 0.1
    ((i += 1))
  done
  exited=0
  if kill -0 "${pid}" 2>/dev/null; then
    kill -9 "${pid}" 2>/dev/null
    exited=1
  fi
  rc=0
  wait "${pid}" 2>/dev/null || rc=$?
}

echo "-- sigterm_sets_ubuntu_then_exits"
reset
bg_run
wait_runs 2
check_eq "sigterm_sets_ubuntu_then_exits: run started slots" 2 runs
end_pid TERM
check "sigterm_sets_ubuntu_then_exits: exited within 15 s" test "${exited}" -eq 0
check "sigterm_sets_ubuntu_then_exits: exit 0" test "${rc}" -eq 0
check_eq "sigterm_sets_ubuntu_then_exits: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check_eq "sigterm_sets_ubuntu_then_exits: one alert" 1 count . "${S}/ntfy.log"
check_eq "sigterm_sets_ubuntu_then_exits: idle slots stopped" 2 count '^stop mimolette-' "${S}/container.argv"

echo "-- sigterm_stops_idle_keeps_busy"
reset
echo 102 >"${S}/busy"
bg_run
wait_runs 2
end_pid TERM
check "sigterm_stops_idle_keeps_busy: exited" test "${exited}${rc}" = 00
check "sigterm_stops_idle_keeps_busy: idle slot 1 stopped" grep -qE '^stop mimolette-1-' "${S}/container.argv"
check_not "sigterm_stops_idle_keeps_busy: busy slot 2 left" grep -qE '^stop mimolette-2-' "${S}/container.argv"
check "sigterm_stops_idle_keeps_busy: runner 101 deleted" grep -qE '^DELETE .*/actions/runners/101 ' "${S}/requests.log"
check_not "sigterm_stops_idle_keeps_busy: runner 102 kept" grep -qE '^DELETE .*/actions/runners/102 ' "${S}/requests.log"
check "sigterm_stops_idle_keeps_busy: slot 2 state kept" grep -qE '^name=mimolette-2-' "${S}/state/slot-2"

echo "-- sigterm_mid_pass_starts_no_vm"
reset
bg_run STUB_LS_SLEEP=2
wait_ls
end_pid TERM
check "sigterm_mid_pass_starts_no_vm: exited within 15 s, exit 0" test "${exited}${rc}" = 00
check_eq "sigterm_mid_pass_starts_no_vm: no VM started" 0 runs
check_eq "sigterm_mid_pass_starts_no_vm: no JIT minted" 0 count 'generate-jitconfig' "${S}/requests.log"
check_eq "sigterm_mid_pass_starts_no_vm: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"

echo "-- hup_exits_without_failover"
reset
bg_run
wait_runs 2
end_pid HUP
check "hup_exits_without_failover: exited within 15 s" test "${exited}" -eq 0
check "hup_exits_without_failover: exit 0" test "${rc}" -eq 0
check_eq "hup_exits_without_failover: variable untouched" mimolette cat "${S}/var.value"
check_eq "hup_exits_without_failover: no PATCH" 0 count '^curl PATCH' "${S}/order.log"
check_eq "hup_exits_without_failover: no ntfy" 0 count . "${S}/ntfy.log"
check_eq "hup_exits_without_failover: no stop" 0 count '^stop ' "${S}/container.argv"
check_eq "hup_exits_without_failover: no DELETE" 0 count '^DELETE' "${S}/requests.log"
check "hup_exits_without_failover: slot state kept" grep -qE '^name=mimolette-1-' "${S}/state/slot-1"

echo "-- hup_mid_pass_mints_and_starts_nothing"
reset
bg_run STUB_LS_SLEEP=2
wait_ls
end_pid HUP
check "hup_mid_pass: exited within 15 s, exit 0" test "${exited}${rc}" = 00
check_eq "hup_mid_pass: no VM started" 0 runs
check_eq "hup_mid_pass: no JIT minted" 0 count 'generate-jitconfig' "${S}/requests.log"
check_eq "hup_mid_pass: variable untouched" mimolette cat "${S}/var.value"

echo "-- ntfy_topic_not_in_argv"
reset
STUB_DF_AVAIL_KB=$((19 * GB)) sup once || true
check_eq "ntfy_topic_not_in_argv: alert sent" 1 count . "${S}/ntfy.log"
check_not "ntfy_topic_not_in_argv: topic absent from curl argv" grep -q stubtopic "${S}/curl.argv"
check "ntfy_topic_not_in_argv: curl reads its config from stdin" grep -q -- '-K -' "${S}/curl.argv"

echo "-- container_ls_hang_is_apiserver_failure"
reset
pid=""
NOS_CONTAINER_TIMEOUT=1 STUB_LS_HANG=1 /bin/bash "${SCRIPT}" once 2>>"${S}/sup.err" &
pid=$!
end_pid
check "container_ls_hang_is_apiserver_failure: pass ended within the bound" test "${exited}" -eq 0
check_eq "container_ls_hang_is_apiserver_failure: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check_eq "container_ls_hang_is_apiserver_failure: no VM started" 0 runs
check "container_ls_hang_is_apiserver_failure: logged as apiserver" grep -q 'apiserver does not answer' "${S}/sup.err"

echo "-- vm_ip_outside_subnet_is_pf_failure"
reset
sup once
echo 102 >"${S}/busy"
STUB_VM_IP=10.0.5.2/24 sup once || true
check_eq "vm_ip_outside_subnet_is_pf_failure: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check "vm_ip_outside_subnet_is_pf_failure: idle slot 1 stopped" grep -qE '^stop mimolette-1-' "${S}/container.argv"
check "vm_ip_outside_subnet_is_pf_failure: busy slot 2 stopped too" grep -qE '^stop mimolette-2-' "${S}/container.argv"
check "vm_ip_outside_subnet_is_pf_failure: logged with the IP" grep -q '10.0.5.2/24' "${S}/sup.err"
check "vm_ip_outside_subnet_is_pf_failure: alert names the subnet" grep -q '192.168.64.0/24' "${S}/ntfy.log"
check "vm_ip_outside_subnet_is_pf_failure: marker kept" test -f "${S}/state/subnet-bad"
sup once || true
check_eq "vm_ip_outside_subnet_is_pf_failure: marker blocks new VMs" 2 runs
check_eq "vm_ip_outside_subnet_is_pf_failure: no second alert" 1 count . "${S}/ntfy.log"
/bin/rm -f "${S}/state/subnet-bad"
sup once
check_eq "vm_ip_outside_subnet_is_pf_failure: starts again once the marker is removed" 4 runs

echo "-- vm_ip_rules"
reset
sup once
STUB_BUILDKIT_IP=10.0.5.3/24 sup once
check_eq "vm_ip_rules: a non-mimolette VM elsewhere is ignored" mimolette cat "${S}/var.value"
STUB_VM_IP=192.168.64.77 sup once
check_eq "vm_ip_rules: an address without a prefix inside the subnet passes" mimolette cat "${S}/var.value"
STUB_VM_IP=192.168.640.2/24 sup once || true
check_eq "vm_ip_rules: 192.168.640.x is outside" ubuntu-latest cat "${S}/var.value"
reset
sup once
STUB_VM_IP='' sup once
check_eq "vm_ip_rules: a VM with no IP yet is not a failure" mimolette cat "${S}/var.value"
check "vm_ip_rules: a VM with no IP is logged" grep -q 'no IPv4 address' "${S}/sup.err"

reset
sup once
STUB_LS_HEADER="ID IMAGE OS ARCH STATE ADDR CPUS MEMORY STARTED" sup once || true
check_eq "vm_ip_rules: a header with no IP column fails closed" ubuntu-latest cat "${S}/var.value"
check "vm_ip_rules: no IP column stops the VMs" grep -qE '^stop mimolette-1-' "${S}/container.argv"
check "vm_ip_rules: no IP column has its own reason" grep -q "has no IP column" "${S}/ntfy.log"

echo "-- three_failed_slot_starts_is_selfcheck_failure"
reset
STUB_RUN_FAIL=1 sup once || true
STUB_RUN_FAIL=1 sup once || true
check_eq "three_failed_slot_starts_is_selfcheck_failure: two failures do not switch" mimolette cat "${S}/var.value"
check_eq "three_failed_slot_starts_is_selfcheck_failure: no alert after two" 0 count . "${S}/ntfy.log"
STUB_RUN_FAIL=1 sup once || true
check_eq "three_failed_slot_starts_is_selfcheck_failure: third failure switches" ubuntu-latest cat "${S}/var.value"
check_eq "three_failed_slot_starts_is_selfcheck_failure: one alert" 1 count . "${S}/ntfy.log"
check_eq "three_failed_slot_starts_is_selfcheck_failure: failed runners deleted" \
  6 count '^DELETE .*/actions/runners/' "${S}/requests.log"
left=0
while read -r f; do [[ -e "${f}" ]] && left=1; done <"${S}/envfile.paths"
check "three_failed_slot_starts_is_selfcheck_failure: env files removed on failure" test "${left}" -eq 0

echo "-- failed_failover_write_keeps_fail_counts"
reset
STUB_RUN_FAIL=1 sup once || true
STUB_RUN_FAIL=1 sup once || true
STUB_RUN_FAIL=1 STUB_PATCH_FAIL=1 sup once || true
check_eq "failed_failover_write_keeps_fail_counts: write failed" mimolette cat "${S}/var.value"
check "failed_failover_write_keeps_fail_counts: count kept" grep -qx 'fails=3' "${S}/state/slot-1"
sup once || true
check_eq "failed_failover_write_keeps_fail_counts: next pass retries the failover" ubuntu-latest cat "${S}/var.value"
check_eq "failed_failover_write_keeps_fail_counts: no start on that pass" 6 runs

echo "-- stale_or_missing_pf_ok_file_starts_no_slot"
reset
/bin/rm -f "${S}/pf.ok"
sup once || true
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: missing starts no slot" 0 runs
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: missing switches to ubuntu" ubuntu-latest cat "${S}/var.value"
reset
touch -t 202001010000 "${S}/pf.ok"
sup once || true
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: stale starts no slot" 0 runs
check_eq "stale_or_missing_pf_ok_file_starts_no_slot: stale switches to ubuntu" ubuntu-latest cat "${S}/var.value"

echo "-- other self-checks"
reset
STUB_LS_FAIL=1 sup once || true
check_eq "apiserver_down_is_selfcheck_failure" ubuntu-latest cat "${S}/var.value"
reset
STUB_IMAGE_MISSING=1 sup once || true
check_eq "missing_image_is_selfcheck_failure" ubuntu-latest cat "${S}/var.value"
check_eq "missing_image_starts_no_slot" 0 runs

echo "-- ls_without_header_is_apiserver_failure"
reset
sup once
printf '101\n102\n' >"${S}/busy"
STUB_LS_EMPTY=1 sup once || true
check_eq "ls_without_header_is_apiserver_failure: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check "ls_without_header_is_apiserver_failure: logged" grep -q 'no ID header' "${S}/sup.err"
check "ls_without_header_is_apiserver_failure: slot 1 state kept" grep -qE '^name=mimolette-1-' "${S}/state/slot-1"
check "ls_without_header_is_apiserver_failure: slot 2 state kept" grep -qE '^name=mimolette-2-' "${S}/state/slot-2"
check_eq "ls_without_header_is_apiserver_failure: no VM started" 2 runs
check_not "ls_without_header_is_apiserver_failure: no exit markers" test -e "${S}/state/exited-1"

echo "-- apiserver_down_deregisters_idle_runners"
reset
sup once
echo 102 >"${S}/busy"
STUB_LS_FAIL=1 STUB_STOP_FAIL=1 sup once || true
check_eq "apiserver_down_deregisters_idle_runners: variable is ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check "apiserver_down_deregisters_idle_runners: idle runner 101 deleted" grep -qE '^DELETE .*/orgs/nightowlstudiollc/actions/runners/101 ' "${S}/requests.log"
check_not "apiserver_down_deregisters_idle_runners: busy runner 102 kept" grep -qE '^DELETE .*/actions/runners/102 ' "${S}/requests.log"
check "apiserver_down_deregisters_idle_runners: slot 1 VM name kept" grep -qE '^name=mimolette-1-' "${S}/state/slot-1"
check "apiserver_down_deregisters_idle_runners: slot 2 VM name kept" grep -qE '^name=mimolette-2-' "${S}/state/slot-2"
check_eq "apiserver_down_deregisters_idle_runners: one alert" 1 count . "${S}/ntfy.log"
STUB_LS_FAIL=1 STUB_STOP_FAIL=1 sup once || true
check_eq "apiserver_down_deregisters_idle_runners: second down pass sends no alert" 1 count . "${S}/ntfy.log"
check_eq "apiserver_down_deregisters_idle_runners: no VM started while down" 2 runs
stops="$(count '^stop mimolette-1-' "${S}/container.argv")"
sup once || true
check_eq "apiserver_down_deregisters_idle_runners: healthy pass stops the dropped VM" $((stops + 1)) count '^stop mimolette-1-' "${S}/container.argv"
check_not "apiserver_down_deregisters_idle_runners: busy VM left running" grep -qE '^stop mimolette-2-' "${S}/container.argv"
check_eq "apiserver_down_deregisters_idle_runners: slot 1 gets a fresh runner" 3 runs
check "apiserver_down_deregisters_idle_runners: slot 1 has the new runner" grep -qx 'id=103' "${S}/state/slot-1"
check_not "apiserver_down_deregisters_idle_runners: marker cleared" test -e "${S}/state/dropped-1"

echo "-- three_exits_with_runner_registered_trip_selfcheck"
reset
for _ in 1 2 3; do STUB_RUN_EXITS=1 sup once || true; done
check_eq "three_exits_with_runner_registered_trip_selfcheck: two failed starts do not switch" mimolette cat "${S}/var.value"
check "three_exits_with_runner_registered_trip_selfcheck: DELETE 204 counted" grep -qx 'fails=2' "${S}/state/slot-1"
STUB_RUN_EXITS=1 sup once || true
check_eq "three_exits_with_runner_registered_trip_selfcheck: third switches" ubuntu-latest cat "${S}/var.value"
check_eq "three_exits_with_runner_registered_trip_selfcheck: no start on that pass" 6 runs
check_eq "three_exits_with_runner_registered_trip_selfcheck: one alert" 1 count . "${S}/ntfy.log"

echo "-- short_job_runner_gone_is_good_start"
reset
for _ in 1 2 3 4 5; do
  seq 101 120 >"${S}/gone"
  STUB_RUN_EXITS=1 sup once || true
done
check_eq "short_job_runner_gone_is_good_start: fast exits after a job never switch" mimolette cat "${S}/var.value"
check "short_job_runner_gone_is_good_start: fails stays 0" grep -qx 'fails=0' "${S}/state/slot-1"
check_eq "short_job_runner_gone_is_good_start: slots restart every pass" 10 runs

echo "-- unknown_delete_result_keeps_count"
reset
STUB_RUN_EXITS=1 sup once || true
STUB_RUN_EXITS=1 STUB_DELETE_FAIL=1 sup once || true
check "unknown_delete_result_keeps_count: fails unchanged" grep -qx 'fails=0' "${S}/state/slot-1"
check "unknown_delete_result_keeps_count: id kept" grep -qx 'id=101' "${S}/state/slot-1"
check "unknown_delete_result_keeps_count: marker kept" test -f "${S}/state/exited-1"
sup once
check "unknown_delete_result_keeps_count: next pass counts it" grep -qx 'fails=1' "${S}/state/slot-1"

echo "-- pf_stale_stops_all_without_token"
reset
sup once
echo 102 >"${S}/busy"
touch -t 202001010000 "${S}/pf.ok"
STUB_TOKEN_FAIL=1 sup once || true
check "pf_stale_stops_all_without_token: slot 1 stopped" grep -qE '^stop mimolette-1-' "${S}/container.argv"
check "pf_stale_stops_all_without_token: busy slot 2 stopped too" grep -qE '^stop mimolette-2-' "${S}/container.argv"
check_eq "pf_stale_stops_all_without_token: no variable write without a token" mimolette cat "${S}/var.value"
check_eq "pf_stale_stops_all_without_token: token failure alerted" 1 count 'token' "${S}/ntfy.log"
sup once || true
check_eq "pf_stale_stops_all_without_token: retry sets ubuntu-latest" ubuntu-latest cat "${S}/var.value"
check "pf_stale_stops_all_without_token: retry deletes runner 101" grep -qE '^DELETE .*/actions/runners/101 ' "${S}/requests.log"
check "pf_stale_stops_all_without_token: retry deletes runner 102" grep -qE '^DELETE .*/actions/runners/102 ' "${S}/requests.log"
check_eq "pf_stale_stops_all_without_token: no VM started" 2 runs

echo "-- token_failure_alerts_once"
reset
STUB_TOKEN_FAIL=1 sup once || true
STUB_TOKEN_FAIL=1 sup once || true
check_eq "token_failure_alerts_once: one alert" 1 count . "${S}/ntfy.log"
check_eq "token_failure_alerts_once: no VM started" 0 runs
sup once
check_eq "token_failure_alerts_once: recovers" 2 runs

echo "-- stop_failure_keeps_slot_state"
reset
sup once
touch -t 202001010000 "${S}/pf.ok"
STUB_STOP_FAIL=1 sup once || true
check "stop_failure_keeps_slot_state: slot 1 name kept" grep -qE '^name=mimolette-1-' "${S}/state/slot-1"
check "stop_failure_keeps_slot_state: slot 2 name kept" grep -qE '^name=mimolette-2-' "${S}/state/slot-2"
check_not "stop_failure_keeps_slot_state: runner not deleted while VM lives" grep -qE '^DELETE .*/actions/runners/101 ' "${S}/requests.log"
touch "${S}/pf.ok"
sup once
check_eq "stop_failure_keeps_slot_state: listed VMs get no second VM" 2 runs

echo "-- unnamed_mimolette_vm_is_stopped"
reset
sup once
echo mimolette-9-1 >>"${S}/running"
sup once
check "unnamed_mimolette_vm_is_stopped: orphan stopped" grep -qx 'stop mimolette-9-1' "${S}/container.argv"
check_not "unnamed_mimolette_vm_is_stopped: buildkit untouched" grep -q 'buildkit' "${S}/container.argv"
check_eq "unnamed_mimolette_vm_is_stopped: no extra VM" 2 runs

echo "-- never_more_than_nos_slots_vms"
reset
sup once
slot1="$(grep -o 'mimolette-1-[0-9]*' "${S}/running")"
grep -vxF -e "${slot1}" "${S}/running" >"${S}/running.tmp"
cat "${S}/running.tmp" >"${S}/running"
echo mimolette-9-1 >>"${S}/running"
STUB_STOP_FAIL=1 sup once || true
check_eq "never_more_than_nos_slots_vms: orphan holds the slot, no start" 2 runs

echo "-- failed_delete_blocks_restart"
reset
sup once
slot1="$(grep -o 'mimolette-1-[0-9]*' "${S}/running")"
grep -vxF -e "${slot1}" "${S}/running" >"${S}/running.tmp"
cat "${S}/running.tmp" >"${S}/running"
STUB_DELETE_FAIL=1 sup once || true
check_eq "failed_delete_blocks_restart: no new VM while runner 101 is registered" 2 runs
check "failed_delete_blocks_restart: id kept for retry" grep -qx 'id=101' "${S}/state/slot-1"
sup once
check_eq "failed_delete_blocks_restart: retry deletes 101" 2 count '^DELETE .*/actions/runners/101 ' "${S}/requests.log"
check_eq "failed_delete_blocks_restart: then slot 1 restarts" 3 runs

echo "-- failed_start_keeps_undeleted_runner"
reset
STUB_RUN_FAIL=1 STUB_DELETE_FAIL=1 sup once || true
check "failed_start_keeps_undeleted_runner: id kept for retry" grep -qx 'id=101' "${S}/state/slot-1"
sup once
check_eq "failed_start_keeps_undeleted_runner: retry deletes 101" 2 count '^DELETE .*/actions/runners/101 ' "${S}/requests.log"
check "failed_start_keeps_undeleted_runner: slot 1 then starts" grep -qE '^name=mimolette-1-' "${S}/state/slot-1"

echo "-- never_writes_mimolette"
writes="$(grep -E '^(PATCH|POST) [^ ]*/actions/variables' "${WORK}/all-requests.log")"
check "never_writes_mimolette: variable writes were logged" test -n "${writes}"
check_not "never_writes_mimolette" grep -q mimolette <<<"${writes}"
check_not "never_writes_mimolette: launchctl unused" test -e "${S}/launchctl.argv"

echo "-- config"
img="$(
  unset NOS_IMAGE
  # shellcheck source=SCRIPTDIR/../config.sh
  source "${HERE}/../config.sh"
  echo "${NOS_IMAGE}"
)"
check "image_tag_from_containerfile" grep -qE '^nos-runner:2\.338\.2-[0-9a-f]{12}$' <<<"${img}"

exit "${fail}"
